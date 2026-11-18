#!/usr/bin/env bash
###############################################################################
# deploy-ecs.sh
#
# End-to-end deploy of the ECS (Linux containers on Fargate) variant:
#   1. Deploy the build stack (cfn-otel-demo-ecs-build.yaml): ECR repos + CodeBuild.
#   2. Zip app/ + buildspec.yml and upload it to the build stack's source bucket.
#   3. Run CodeBuild to build and push the .NET 10 images with a new immutable tag.
#   4. Resolve the pushed image digests.
#   5. Deploy the ECS infra stack (cfn-otel-demo-ecs-infra.yaml) with image@digest URIs.
#
# No local Docker is needed: images are built in AWS CodeBuild.
#
# Usage:
#   ./deploy-ecs.sh --profile <profile> --region us-west-2 \
#       [--vpc vpc-xxx --subnet subnet-aaa --subnet2 subnet-bbb --prefix-list pl-xxxx] \
#       [--stack otel-demo-ecs] [--build-stack otel-demo-ecs-build] [--secret <value>] \
#       [--tag <image-tag>] [--repo-prefix otel-demo] [--build-only]
#
# If --vpc/--subnet/--subnet2/--prefix-list are omitted, the script auto-discovers
# the default VPC, two public subnets in different AZs, and the CloudFront
# origin-facing managed prefix list for the region.
#
# If --secret is omitted a high-entropy OriginSecretHeader is generated in-memory
# and passed straight to CloudFormation. It is NOT written to disk.
###############################################################################
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-us-west-2}"
STACK="otel-demo-ecs"
BUILD_STACK="otel-demo-ecs-build"
REPO_PREFIX="otel-demo"
VPC="" ; SUBNET="" ; SUBNET2="" ; PREFIX_LIST="" ; SECRET=""
TAG="net10-$(date -u +%Y%m%d%H%M%S)"
BUILD_ONLY="false"
POLL_MAX=90 ; POLL_SLEEP=20   # 30 min build budget

log(){ printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die(){ printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --stack) STACK="$2"; shift 2;;
    --build-stack) BUILD_STACK="$2"; shift 2;;
    --repo-prefix) REPO_PREFIX="$2"; shift 2;;
    --vpc) VPC="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --subnet2) SUBNET2="$2"; shift 2;;
    --prefix-list) PREFIX_LIST="$2"; shift 2;;
    --secret) SECRET="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --build-only) BUILD_ONLY="true"; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done
[[ -n "$PROFILE" ]] || die "--profile is required (or set AWS_PROFILE)"
AWS=(aws --profile "$PROFILE" --region "$REGION")

# ----------------------------- 1. build stack --------------------------------
# Earlier versions of this sample created the ECR repos outside CloudFormation. If they still
# exist and the build stack does not own them, the stack create would fail; stop with a clear hint.
if ! "${AWS[@]}" cloudformation describe-stacks --stack-name "$BUILD_STACK" >/dev/null 2>&1; then
  for r in "$REPO_PREFIX-frontend" "$REPO_PREFIX-backend"; do
    if "${AWS[@]}" ecr describe-repositories --repository-names "$r" >/dev/null 2>&1; then
      die "ECR repo '$r' already exists outside the build stack. Delete it (aws ecr delete-repository --repository-name $r --force) or pass a different --repo-prefix."
    fi
  done
fi
log "Deploying build stack '$BUILD_STACK' (ECR repos + CodeBuild)..."
"${AWS[@]}" cloudformation deploy \
  --template-file "$DIR/cfn-otel-demo-ecs-build.yaml" \
  --stack-name "$BUILD_STACK" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides RepoPrefix="$REPO_PREFIX" \
  || die "build stack deploy failed (see CloudFormation events)"

bout(){ "${AWS[@]}" cloudformation describe-stacks --stack-name "$BUILD_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
BUCKET=$(bout SourceBucketName)
PROJECT=$(bout BuildProjectName)
FRONTEND_REPO=$(bout FrontendRepoUri)
BACKEND_REPO=$(bout BackendRepoUri)

# ----------------------------- 2. upload source ------------------------------
log "Packaging app/ + buildspec.yml..."
ZIP="$(mktemp -d)/app-source.zip"
python3 - "$DIR" "$ZIP" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(root, "buildspec.yml"), "buildspec.yml")
    for base, dirs, files in os.walk(os.path.join(root, "app")):
        dirs[:] = [d for d in dirs if d not in ("bin", "obj")]
        for f in files:
            p = os.path.join(base, f)
            z.write(p, os.path.relpath(p, root))
PY
"${AWS[@]}" s3 cp "$ZIP" "s3://$BUCKET/source/app-source.zip" --only-show-errors

# ----------------------------- 3. CodeBuild ----------------------------------
log "Starting CodeBuild '$PROJECT' (tag $TAG)..."
BUILD_ID=$("${AWS[@]}" codebuild start-build --project-name "$PROJECT" \
  --environment-variables-override "name=IMAGE_TAG,value=$TAG,type=PLAINTEXT" \
  --query 'build.id' --output text)
for ((i=1; i<=POLL_MAX; i++)); do
  STATUS=$("${AWS[@]}" codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)
  [[ "$STATUS" != "IN_PROGRESS" ]] && break
  sleep "$POLL_SLEEP"
done
[[ "$STATUS" == "SUCCEEDED" ]] || die "CodeBuild $BUILD_ID finished with status $STATUS (see /codebuild logs)"
log "CodeBuild succeeded."

# ----------------------------- 4. digests ------------------------------------
digest(){ "${AWS[@]}" ecr describe-images --repository-name "${1#*/}" \
  --image-ids "imageTag=$TAG" --query 'imageDetails[0].imageDigest' --output text; }
FRONTEND_IMAGE="$FRONTEND_REPO@$(digest "$FRONTEND_REPO")"
BACKEND_IMAGE="$BACKEND_REPO@$(digest "$BACKEND_REPO")"
log "Images: $FRONTEND_IMAGE / $BACKEND_IMAGE"
[[ "$BUILD_ONLY" == "true" ]] && { log "--build-only: skipping ECS infra deploy."; exit 0; }

# ----------------------------- 5. ECS infra stack ----------------------------
if [[ -z "$VPC" ]]; then
  log "Auto-discovering default VPC + 2 public subnets + CloudFront prefix list..."
  VPC=$("${AWS[@]}" ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  SUBS=()
  while IFS= read -r _sub; do
    [[ -n "$_sub" ]] && SUBS+=("$_sub")
  done < <("${AWS[@]}" ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC" Name=map-public-ip-on-launch,Values=true \
    --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text | sort -k2 | awk '!seen[$2]++{print $1}')
  SUBNET="${SUBS[0]:-}" ; SUBNET2="${SUBS[1]:-}"
  PREFIX_LIST=$("${AWS[@]}" ec2 describe-managed-prefix-lists \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
fi
[[ -n "$VPC" && -n "$SUBNET" && -n "$SUBNET2" && -n "$PREFIX_LIST" ]] \
  || die "could not resolve network params (VPC=$VPC SUBNET=$SUBNET SUBNET2=$SUBNET2 PL=$PREFIX_LIST)"
[[ -n "$SECRET" ]] || SECRET=$(openssl rand -base64 24)   # in-memory only, never written to disk

log "Deploying ECS infra stack '$STACK'..."
"${AWS[@]}" cloudformation deploy \
  --template-file "$DIR/cfn-otel-demo-ecs-infra.yaml" \
  --stack-name "$STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId="$VPC" SubnetId1="$SUBNET" SubnetId2="$SUBNET2" \
    CloudFrontPrefixListId="$PREFIX_LIST" OriginSecretHeader="$SECRET" \
    FrontendImageUri="$FRONTEND_IMAGE" BackendImageUri="$BACKEND_IMAGE" \
  || die "ECS infra stack deploy failed (see CloudFormation events)"

URL=$("${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue" --output text)
log "Done. Frontend: $URL"

#!/usr/bin/env bash
###############################################################################
# deploy-and-bootstrap.sh
#
# Deploys the otel-demo-ec2 infrastructure stack (cfn-otel-demo-ec2-infra.yaml)
# and then runs the in-stack SSM bootstrap document against the backend and
# frontend instances to install IIS + .NET 8 + ASP.NET Core Hosting Bundle (ANCM)
# + CloudWatch Agent (Application Signals) + ADOT .NET auto-instrumentation and
# publish the demo app.
#
# WHY THIS IS A SCRIPT (and not AWS::SSM::Association resources in the template):
# The ~1-hour app bootstrap, when wired as a stack-managed Association with
# WaitForSuccessTimeoutSeconds, makes CloudFormation block on the install and
# ROLL BACK THE ENTIRE STACK (RDS, instances, ALB, CloudFront) if the bootstrap
# does not converge in time. Decoupling the app bootstrap from the stack
# lifecycle keeps infra creation fast and reliable, and a bootstrap hiccup no
# longer destroys the infrastructure. Ship this script alongside the template.
#
# The template still CREATES the SSM Document (BootstrapDocument); this script
# merely INVOKES it (same parameters the Associations used) via send-command.
#
# Usage:
#   ./deploy-and-bootstrap.sh \
#       --profile o11y-backup --region us-west-2 \
#       --vpc vpc-xxx --subnet subnet-aaa --subnet2 subnet-bbb \
#       --prefix-list pl-xxxx [--stack otel-demo-ec2] [--secret <value>] \
#       [--skip-deploy] [--role backend|frontend|both]
#
# If --vpc/--subnet/--subnet2/--prefix-list are omitted, the script auto-discovers
# the default VPC, two public subnets in different AZs, and the CloudFront
# origin-facing managed prefix list for the region.
#
# If --secret is omitted a high-entropy OriginSecretHeader is generated in-memory
# and passed straight to CloudFormation. It is NOT written to disk; the deployed
# stack (CloudFront OriginCustomHeaders + ALB listener rule) holds the value.
###############################################################################
set -euo pipefail

# ----------------------------- defaults --------------------------------------
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-us-west-2}"
STACK="otel-demo-ec2"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cfn-otel-demo-ec2-infra.yaml"
VPC="" ; SUBNET="" ; SUBNET2="" ; PREFIX_LIST="" ; SECRET=""
SKIP_DEPLOY="false" ; ROLE="both"
BOOTSTRAP_TIMEOUT=3600   # seconds the SSM command is allowed to run on the box
POLL_MAX=120             # poll iterations
POLL_SLEEP=30            # seconds between polls (120*30 = 60 min budget)

log(){ printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die(){ printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- arg parse -------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --stack) STACK="$2"; shift 2;;
    --template) TEMPLATE="$2"; shift 2;;
    --vpc) VPC="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --subnet2) SUBNET2="$2"; shift 2;;
    --prefix-list) PREFIX_LIST="$2"; shift 2;;
    --secret) SECRET="$2"; shift 2;;
    --skip-deploy) SKIP_DEPLOY="true"; shift;;
    --role) ROLE="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done
[[ -n "$PROFILE" ]] || die "--profile is required (or set AWS_PROFILE)"
AWS=(aws --profile "$PROFILE" --region "$REGION")

# ----------------------------- deploy ----------------------------------------
if [[ "$SKIP_DEPLOY" != "true" ]]; then
  [[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

  if [[ -z "$VPC" ]]; then
    log "Auto-discovering default VPC + 2 public subnets + CloudFront prefix list..."
    VPC=$("${AWS[@]}" ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
    # Portable (bash 3.2 / macOS): read lines into SUBS without `mapfile` (bash 4+ only).
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

  if [[ -z "$SECRET" ]]; then
    SECRET=$(openssl rand -base64 24)
    # Generated in-memory only and passed straight to CloudFormation as the
    # OriginSecretHeader parameter. Deliberately NOT written to disk: the value
    # is never read back by this script, and the deployed stack (CloudFront
    # OriginCustomHeaders + ALB listener rule) is the source of truth.
    log "Generated OriginSecretHeader (in-memory; not written to disk)"
  fi

  log "Deploying stack '$STACK' (VPC=$VPC subnets=$SUBNET,$SUBNET2 pl=$PREFIX_LIST)"
  "${AWS[@]}" cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      VpcId="$VPC" SubnetId="$SUBNET" SubnetId2="$SUBNET2" \
      CloudFrontPrefixListId="$PREFIX_LIST" OriginSecretHeader="$SECRET" \
    || die "stack deploy failed (see CloudFormation events)"
  log "Stack deploy complete."
fi

# ----------------------------- read stack outputs ----------------------------
log "Reading stack outputs + resources..."
get_out(){ "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

BACKEND_ID=$(get_out BackendInstanceId)
FRONTEND_ID=$(get_out FrontendInstanceId)
DB_ENDPOINT=$(get_out DatabaseEndpoint)
BACKEND_IP=$(get_out BackendPrivateIp)
FRONTEND_URL=$(get_out FrontendURL)
DOC_NAME=$("${AWS[@]}" cloudformation describe-stack-resource --stack-name "$STACK" \
  --logical-resource-id BootstrapDocument --query 'StackResourceDetail.PhysicalResourceId' --output text)
SECRET_ARN=$("${AWS[@]}" cloudformation describe-stack-resource --stack-name "$STACK" \
  --logical-resource-id DBSecret --query 'StackResourceDetail.PhysicalResourceId' --output text)

[[ -n "$BACKEND_ID" && -n "$FRONTEND_ID" && -n "$DOC_NAME" ]] \
  || die "missing stack outputs (backend=$BACKEND_ID frontend=$FRONTEND_ID doc=$DOC_NAME)"
log "backend=$BACKEND_ID frontend=$FRONTEND_ID db=$DB_ENDPOINT doc=$DOC_NAME"

# ----------------------------- wait for SSM online ---------------------------
wait_ssm_online(){
  local iid="$1" i
  for ((i=0;i<40;i++)); do
    local ping
    ping=$("${AWS[@]}" ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$iid" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    [[ "$ping" == "Online" ]] && { log "SSM online: $iid"; return 0; }
    sleep 15
  done
  die "instance $iid never came Online in SSM"
}

# ----------------------------- run bootstrap via SSM --------------------------
# $1=instance-id  $2=json params file
run_bootstrap(){
  local iid="$1" params_file="$2" role="$3"
  log "Starting bootstrap on $role ($iid) via SSM document $DOC_NAME ..."
  local cid
  cid=$("${AWS[@]}" ssm send-command \
    --document-name "$DOC_NAME" \
    --instance-ids "$iid" \
    --timeout-seconds "$BOOTSTRAP_TIMEOUT" \
    --cli-input-json "file://$params_file" \
    --query 'Command.CommandId' --output text) || die "send-command failed for $role"
  log "$role command id: $cid — polling (budget ~$((POLL_MAX*POLL_SLEEP/60)) min)"
  local i status
  for ((i=0;i<POLL_MAX;i++)); do
    status=$("${AWS[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$iid" \
      --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) log "$role bootstrap SUCCESS"; return 0;;
      Failed|Cancelled|TimedOut|Undeliverable|Terminated)
        log "$role bootstrap $status — last output:"
        "${AWS[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$iid" \
          --query '{Status:Status,Code:ResponseCode,Out:StandardOutputContent,Err:StandardErrorContent}' --output json | tail -c 4000
        die "$role bootstrap did not succeed ($status)";;
      *) printf '  [%s] %s: %s\n' "$(date -u +%H:%M:%S)" "$role" "$status"; sleep "$POLL_SLEEP";;
    esac
  done
  die "$role bootstrap timed out after $((POLL_MAX*POLL_SLEEP/60)) min"
}

# Build SSM parameter JSON (avoids inline --parameters PowerShell quoting issues).
mk_backend_params(){
  # Resolve the RDS password LOCALLY (modern AWS CLI) and pass it in as DbPassword.
  # The on-box AWSPowerShell module is too stale to unmarshal the Secrets Manager
  # 200 response (Get-SECSecretValue throws AmazonUnmarshallingException), so the
  # bootstrap document no longer fetches the secret itself.
  local pw
  pw=$("${AWS[@]}" secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
        --query 'SecretString' --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
  [[ -n "$pw" ]] || die "could not resolve DB password from $SECRET_ARN"
  # Write params via python to safely JSON-escape the password.
  python3 - "$DB_ENDPOINT" "$SECRET_ARN" "$pw" "$REGION" > /tmp/ssm-backend-params.json <<'PY'
import json, sys
dbe, arn, pw, region = sys.argv[1:5]
print(json.dumps({"Parameters": {
    "Role": ["backend"],
    "DbEndpoint": [dbe],
    "SecretArn": [arn],
    "DbPassword": [pw],
    "ServiceName": ["otel-demo-backend"],
    "Region": [region],
}}))
PY
  echo /tmp/ssm-backend-params.json
}
mk_frontend_params(){
  cat > /tmp/ssm-frontend-params.json <<JSON
{ "Parameters": {
    "Role": ["frontend"],
    "BackendIp": ["$BACKEND_IP"],
    "ServiceName": ["otel-demo-frontend"],
    "Region": ["$REGION"]
} }
JSON
  echo /tmp/ssm-frontend-params.json
}

# ----------------------------- orchestrate -----------------------------------
# Backend first: the frontend proxies to the backend's private IP.
if [[ "$ROLE" == "both" || "$ROLE" == "backend" ]]; then
  wait_ssm_online "$BACKEND_ID"
  run_bootstrap "$BACKEND_ID" "$(mk_backend_params)" backend
fi
if [[ "$ROLE" == "both" || "$ROLE" == "frontend" ]]; then
  wait_ssm_online "$FRONTEND_ID"
  run_bootstrap "$FRONTEND_ID" "$(mk_frontend_params)" frontend
fi

log "DONE. Frontend URL: $FRONTEND_URL"
cat <<EOF

Next verification (CloudFront can take 5-15 min to fully propagate):
  curl -sS $FRONTEND_URL
  curl -sS $FRONTEND_URL/api/orders      # expect 3 seeded orders (JSON)
Telemetry (allow a few minutes after first requests):
  CloudWatch > Application Signals > Services  (otel-demo-frontend, otel-demo-backend)
  CloudWatch > X-Ray traces                    (frontend -> backend -> SQL)
EOF

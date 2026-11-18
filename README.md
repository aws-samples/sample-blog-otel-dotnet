# Observability for .NET applications: migrate and modernize across EC2, ECS and on-prem

Companion sample code for the blog post *"Observability for .NET applications: migrate and modernize across EC2, ECS and on-prem"*. It deploys a
small two-tier .NET 10 (LTS) order application and instruments it with the **AWS Distro for
OpenTelemetry (ADOT) .NET auto-instrumentation** — no application code changes — sending traces
and metrics to **CloudWatch Application Signals** and **AWS X-Ray**.

> **DEMO / SAMPLE ONLY — not hardened for production.** See the "Security and supply-chain
> notes" section before reusing any of this.

## What it deploys

Two CloudFormation variants of the same application:

| Template | Compute | Summary |
|---|---|---|
| `cfn-otel-demo-ec2-infra.yaml` | Windows Server 2022 EC2 + IIS | Frontend + Backend on IIS, Amazon RDS for SQL Server, fronted by CloudFront. Bootstrapped over SSM. |
| `cfn-otel-demo-ecs-infra.yaml` | Linux containers on ECS Fargate | Containerized frontend/backend with a CloudWatch Agent sidecar. Images come from the build stack below. |
| `cfn-otel-demo-ecs-build.yaml` | AWS CodeBuild + Amazon ECR | Builds the .NET 10 container images from `app/` (no local Docker needed) and pushes them with immutable tags. |

Both are fronted by CloudFront over public HTTPS using the default `*.cloudfront.net`
certificate (no custom domain / ACM cert required).

Architecture (EC2 variant):

```
Browser ──HTTPS──> CloudFront ──HTTP (origin, prefix-list + secret header)──> ALB
                                                                               │
                                                        ┌──────────────────────┴───────────┐
                                                        │                                   │
                                                  Frontend (IIS)  ──HTTP──>  Backend (IIS)  ──TLS──> RDS SQL Server
                                                        │                        │
                                                        └── ADOT .NET ──OTLP──> CloudWatch Agent ──> Application Signals / X-Ray
```

## Prerequisites

- An AWS account with permissions for VPC, EC2, RDS, IAM, CloudFront, and SSM.
- An existing VPC with two public subnets in different AZs.
- AWS CLI v2 configured (the examples use a named profile and `us-west-2`).

## Deploy

The EC2 variant separates **infrastructure** (CloudFormation) from the **app bootstrap**
(an `AWS::SSM::Document` run over SSM by `deploy-and-bootstrap.sh`). This keeps the ~1-hour
Windows/IIS/.NET bootstrap out of the stack's critical path and makes it re-runnable.

```bash
./deploy-and-bootstrap.sh \
  --profile <your-profile> --region us-west-2
```

Re-run only the app bootstrap against an existing stack (idempotent):

```bash
./deploy-and-bootstrap.sh --profile <your-profile> --region us-west-2 \
  --skip-deploy --role backend      # or: --role frontend
```

> **Note:** the app bootstrap lives in the template as an `AWS::SSM::Document`. Editing the
> template YAML does **not** change what runs until the template is redeployed (CloudFormation
> replaces the document with a new version/name). A re-bootstrap then picks up the change.
> Always confirm a bootstrap actually ran your new code by checking the SSM command's
> `StandardOutputContent`, not just its `Success` status.

### ECS variant

`deploy-ecs.sh` deploys the build stack, uploads `app/` to its source bucket, builds and pushes
the images in CodeBuild with a new immutable tag, resolves the image digests, and deploys the
ECS infra stack with `image@sha256` URIs. No local Docker is required.

```bash
./deploy-ecs.sh --profile <your-profile> --region us-west-2
```

Rebuild the images only (for example after an app change): `./deploy-ecs.sh ... --build-only`.

## Verify

```bash
curl -sS https://<distribution>.cloudfront.net/api/health    # {"status":"healthy",...}
curl -sS https://<distribution>.cloudfront.net/api/orders     # seeded orders (JSON)
```

- **Application Signals → Service Map**: frontend → backend, with latency/throughput/error
  rates per edge.
- **X-Ray → Traces**: the distributed waterfall frontend → backend → SQL query.
- **CloudWatch → Logs**: IIS access logs and Windows event logs collected by the CloudWatch
  Agent.

Confirm the backend→RDS connection is encrypted and validated:

```sql
SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID;  -- expect TRUE
```

## Cleanup

Both variants are deployed as a single CloudFormation stack, so teardown is a stack delete.
This removes all billable resources (EC2/ECS, RDS, ALB/CloudFront, VPC additions, IAM roles,
log groups) created by the template.

```bash
# EC2 variant (default stack name used by deploy-and-bootstrap.sh)
aws cloudformation delete-stack --stack-name otel-demo-ec2 \
  --profile <your-profile> --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name otel-demo-ec2 \
  --profile <your-profile> --region us-west-2

# ECS variant: delete the infra stack first, then the build stack (ECR repos + CodeBuild)
aws cloudformation delete-stack --stack-name otel-demo-ecs \
  --profile <your-profile> --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name otel-demo-ecs \
  --profile <your-profile> --region us-west-2
aws cloudformation delete-stack --stack-name otel-demo-ecs-build \
  --profile <your-profile> --region us-west-2
```

Notes:
- **RDS:** if you enabled deletion protection or final snapshots on the DB, the delete will
  stall until you disable protection / allow the snapshot. Check the stack events if a delete
  hangs on the database resource.
- **ECR repositories:** the `otel-demo-frontend` / `otel-demo-backend` repos are owned by the
  build stack (`EmptyOnDelete: true`), so deleting `otel-demo-ecs-build` removes them and their
  images. The build stack's source bucket is versioned; empty it first if the delete reports
  `BucketNotEmpty`.
- **CloudWatch log groups** with a retention policy are removed with the stack; verify none
  remain if you want to stop all charges.

## Security and supply-chain notes

This sample was reviewed with a security scanner (Holmes). The decisions below are intentional
and documented inline in the template:

### Database TLS (fixed)
The backend connects to RDS SQL Server with **validated** TLS, not blind trust. The bootstrap
imports the Amazon RDS global CA bundle into the Windows `LocalMachine\Root` store (splitting
the multi-cert PEM so every cert imports on Windows Server 2022) and the connection string uses
`Encrypt=true;TrustServerCertificate=false` with the RDS **FQDN** (so the hostname matches the
cert). Validation is provable: a connection to the RDS **IP** is correctly rejected with
*"The target principal name is incorrect."*

### Pinned dependencies
- **.NET SDK** pinned to `10.0.404` (not `-Channel 10.0`).
- **ASP.NET Core Hosting Bundle** pinned to `10.0.15`, with a SHA512 integrity check against
  Microsoft's official release metadata; the bootstrap aborts on mismatch.
- **ECS container base images** pinned by tag and digest: `mcr.microsoft.com/dotnet/sdk:10.0.404`
  and `mcr.microsoft.com/dotnet/aspnet:10.0.15`. Containers run as the image's non-root `app` user.
- **ADOT .NET init image (ECS)** pinned to `v1.15.0` by digest (same release as the EC2 path;
  .NET 10 support requires ADOT .NET v1.12.0 or later).
- **ADOT .NET module** pinned to release **`v1.15.0`** with the vendor-published SHA256
  integrity check (`AWS.Otel.DotNet.Auto.psm1.sha256`); the bootstrap aborts on mismatch.

### Documented suppressions (fetch-then-execute from first-party endpoints)
Two bootstrap downloads use vendor "latest"/unversioned endpoints and are suppressed with
justification rather than pinned, because they are official first-party endpoints over HTTPS
with no vendor-published per-artifact hash:
- `dotnet-install.ps1` from `https://dot.net/v1/` (Microsoft's official installer; the SDK
  *payload* it installs is pinned to `10.0.404`).
- The CloudWatch Agent MSI from the regional `amazoncloudwatch-agent-<region>` S3 `latest`
  path, **EC2 bootstrap only**. (A self-computed hash was deliberately **not** embedded — it
  would only attest a one-time download, not AWS's publication.) The **on-prem** bootstrap
  (`bootstrap-onprem.ps1`) does not use `latest`: it pins the MSI to version
  `1.300073.2b1889` (`-CwAgentVersion`) and aborts unless the MSI's Authenticode signature is
  `Valid` and issued to *Amazon Web Services, Inc.*

For production: vendor/mirror these artifacts into an internal store and verify against
organization-controlled hashes.

## Known caveat — database node shows as `UnknownRemoteService` in the map

In the Application Signals service map, the SQL/RDS node appears as `UnknownRemoteService`
(typed `Database::SQL`) rather than the RDS endpoint name. The SQL spans are captured correctly
(query text, `db.system = microsoft.sql_server`, latency); the `Microsoft.Data.SqlClient`
instrumentation simply does not emit the `net.peer.name`/`server.address` attribute that
Application Signals uses to name the remote node, so it falls back to a generic label. This is
cosmetic — traces, the frontend→backend→SQL path, and all query/latency data are intact, and it
is unrelated to the TLS configuration. To surface the RDS endpoint name, either enable
`EnableConnectionLevelAttributes` on the SqlClient instrumentation (a small code change) or
relabel the node with an ADOT Collector attributes processor (no app code).

## Repository layout

```
cfn-otel-demo-ec2-infra.yaml    CloudFormation: Windows EC2 + IIS + RDS variant
cfn-otel-demo-ecs-infra.yaml    CloudFormation: Linux ECS Fargate variant
deploy-and-bootstrap.sh         Deploys the stack and runs the app bootstrap over SSM
cfn-otel-demo-ecs-build.yaml    CloudFormation: ECR repos + CodeBuild image build (ECS variant)
buildspec.yml                   CodeBuild build spec (builds/pushes both images)
deploy-ecs.sh                   ECS end-to-end: build stack -> CodeBuild -> ECS infra stack
app/frontend/                   ECS frontend: .NET 10 minimal API + Dockerfile
app/backend/                    ECS backend: .NET 10 minimal API + Dockerfile (fetches RDS CA bundle at build)
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

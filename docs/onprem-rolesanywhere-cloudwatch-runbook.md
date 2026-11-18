# On‑Premises Observability with IAM Roles Anywhere (Windows)

Run the otel‑demo app on an **on‑premises Windows host** (IIS) and send **metrics, logs, and
distributed traces** to CloudWatch (X‑Ray + Application Signals) using an **X.509 client
certificate** via **IAM Roles Anywhere** — **no long‑lived AWS access keys** on the host.

This follows the same shape as the EC2 path: one **CloudFormation template** for the AWS‑side
resources, and one **bootstrap script** that configures the host and publishes the app.

| Artifact | Purpose |
|---|---|
| `cfn-otel-demo-onprem-rolesanywhere.yaml` | Trust anchor + IAM role + Roles Anywhere profile |
| `bootstrap-onprem.ps1` | Host bootstrap: IIS, .NET, agent, ADOT, app, credential refresh |

> **DEMO / SAMPLE.** Replace the ARNs, account IDs, and CA with your own. See *Hardening*.

---

## Architecture

```
X.509 client cert ─► IAM Roles Anywhere (trust anchor + profile) ─► IAM role
        │
 aws_signing_helper ─► temp creds (1h) ─► refresh-creds.ps1 (sched, 30m) ─► .aws\credentials (static)
        │
 Frontend (IIS :80) ──HTTP──► Backend (IIS :5000, in‑memory)
        └── ADOT .NET (zero‑code) ──OTLP:4316──► CloudWatch Agent ──► X‑Ray + Application Signals
```

The backend is the **no‑database** variant (`app/backend-nodb/`): same `/api/*` surface, orders
held in memory, so the distributed frontend → backend trace forms without a database.

---

## Prerequisites

The on‑prem host must have these **before** running the bootstrap. The script verifies them and
aborts with a clear message if any are missing — it does **not** install them.

| Prerequisite | Notes |
|---|---|
| **Windows x64** (Server 2019/2022 or Windows 10/11) | Admin PowerShell 5.1+ |
| **IIS** enabled | Web server role + management console |
| **.NET 10 SDK** (`10.0.404`) | Builds/publishes the app on the host |
| **ASP.NET Core 10 Hosting Bundle** (`10.0.15`) | Installs the **ASP.NET Core Module** for IIS + the shared runtime — required for IIS to host .NET 10 |
| Outbound HTTPS (443) | To AWS (`*.amazonaws.com`, `rolesanywhere.amazonaws.com`) and GitHub (ADOT release asset) |

Install the prerequisites (elevated PowerShell), if not already present:

```powershell
# IIS + management console
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole -All

# .NET 10 SDK (pinned)
Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile "$env:TEMP\dotnet-install.ps1"
& "$env:TEMP\dotnet-install.ps1" -Version 10.0.404 -InstallDir "C:\Program Files\dotnet"

# ASP.NET Core 10 Hosting Bundle (pinned) — provides the IIS ASP.NET Core Module
Invoke-WebRequest -Uri "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/10.0.15/dotnet-hosting-10.0.15-win.exe" -OutFile "$env:TEMP\dotnet-hosting-win.exe"
Start-Process "$env:TEMP\dotnet-hosting-win.exe" -ArgumentList "/quiet /norestart" -Wait
iisreset /restart
```

Verify:

```powershell
dotnet --list-sdks                              # 10.0.404
dotnet --list-runtimes | Select-String AspNet   # Microsoft.AspNetCore.App 10.0.15
Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole | Select State   # Enabled
```

You also need, as described below: an **X.509 client certificate + CA**, the deployed
**CloudFormation stack**, and the **`app/`** directory copied to the host.

### Certificate (AWS Private CA)

Use **AWS Private CA** to issue the host's client certificate — fully AWS‑native, no
self‑signed CA to manage, and the IAM Roles Anywhere trust anchor points straight at the CA.

1. **Create a Private CA** (ROOT for a demo; a short‑lived SUBORDINATE in production) and
   activate it. Console: *AWS Private CA → Create CA*. CLI / full walkthrough:
   https://docs.aws.amazon.com/privateca/latest/userguide/create-CA.html

2. **Issue the host certificate** — generate the key + CSR **on the on‑prem host** so the
   private key never leaves it, then have the Private CA sign it:

   ```powershell
   # on the on-prem host
   openssl genrsa -out C:\otel-onprem\server.key 2048
   openssl req -new -key C:\otel-onprem\server.key -subj "/CN=otel-onprem-host" -out C:\otel-onprem\server.csr

   $certArn = (aws acm-pca issue-certificate --certificate-authority-arn <PrivateCaArn> `
     --csr fileb://C:\otel-onprem\server.csr --signing-algorithm SHA256WITHRSA `
     --validity Type=DAYS,Value=7 --query CertificateArn --output text)

   aws acm-pca get-certificate --certificate-authority-arn <PrivateCaArn> `
     --certificate-arn $certArn --query Certificate --output text > C:\otel-onprem\server.pem
   ```

   `issue-certificate` reference:
   https://docs.aws.amazon.com/cli/latest/reference/acm-pca/issue-certificate.html

3. Copy the `app/` directory to `C:\otel-demo\src\`. Keep `server.key` off version control.

> Prefer the fully-managed pattern? See *Securing AWS IAM Roles Anywhere with a private
> certificate*: https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/iam-roles-anywhere-private-ca.html

---

## Step 1 — Deploy the AWS resources (CloudFormation)

Pass the **Private CA ARN** (from the Certificate prerequisite above) — the Roles Anywhere
trust anchor references the CA directly.

```bash
aws cloudformation deploy \
  --template-file cfn-otel-demo-onprem-rolesanywhere.yaml \
  --stack-name otel-demo-onprem-rolesanywhere \
  --parameter-overrides PrivateCaArn=<PrivateCaArn> \
  --capabilities CAPABILITY_IAM \
  --region us-west-2

aws cloudformation describe-stacks --stack-name otel-demo-onprem-rolesanywhere \
  --region us-west-2 --query 'Stacks[0].Outputs'     # TrustAnchorArn, ProfileArn, RoleArn
```

The role is granted `CloudWatchAgentServerPolicy` + `AWSXrayWriteOnlyAccess`, which cover
metrics, logs, X‑Ray, and Application Signals.

---

## Step 2 — Bootstrap the host (one script)

In an **elevated** PowerShell on the on‑prem host, with the three stack outputs:

```powershell
.\bootstrap-onprem.ps1 `
  -TrustAnchorArn <TrustAnchorArn> `
  -ProfileArn     <ProfileArn> `
  -RoleArn        <RoleArn> `
  -CertPath C:\otel-onprem\server.pem -KeyPath C:\otel-onprem\server.key `
  -AppSourcePath C:\otel-demo\src
```

The script is idempotent and performs, in order (it first verifies the prerequisites above and
aborts if IIS, the .NET SDK, or the Hosting Bundle are missing):

1. Install the **Roles Anywhere signing helper** and register **`OTelRefreshCreds`** — a
   SYSTEM scheduled task that mints temporary credentials from the certificate every 30 minutes
   and writes them to the agent's credentials file (no long‑lived keys).
2. Install + configure the **CloudWatch agent**: metrics, Windows event logs, IIS access logs,
   and the **Application Signals / OTLP traces** receiver (port `4316`).
3. Install the pinned **ADOT .NET** auto‑instrumentation (SHA256‑verified) and
   `Register-OpenTelemetryForIIS`.
4. Publish the **frontend** and **no‑DB backend** and host them as two IIS sites
   (`otel-frontend` :80, `otel-backend` :5000), each in its own app pool with a distinct
   `OTEL_SERVICE_NAME` set via `web.config`.

---

## Step 3 — Generate traffic

Browse to `http://localhost/` and click **Load Test**, or:

```powershell
Invoke-RestMethod http://localhost/api/orders          # frontend -> backend (traced)
1..30 | % { try { Invoke-RestMethod ("http://localhost/api/orders/" + (Get-Random -Max 3)) | Out-Null } catch {} }
```

---

## Step 4 — Verify in AWS (≈1–3 min)

```bash
# Metrics
aws cloudwatch list-metrics --namespace OTelOnPremDemo --region us-west-2

# Logs
aws logs describe-log-groups --log-group-name-prefix /otel-onprem-demo --region us-west-2

# Traces — the distributed frontend -> backend waterfall
aws xray get-trace-summaries --region us-west-2 \
  --start-time "$(date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%S)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --filter-expression 'service("otel-demo-frontend") AND service("otel-demo-backend")' \
  --query 'length(TraceSummaries)'
```

Console:
- **CloudWatch → Application Signals → Services / Service Map** — `otel-demo-frontend` and
  `otel-demo-backend` with the edge between them.
- **X‑Ray → Traces** — open any trace: the backend segment is a child of the frontend's
  outbound call (the distributed waterfall).
- **CloudWatch → Logs** — `/otel-onprem-demo/windows/*` and `/otel-onprem-demo/iis-access`.

---

## Hardening (before using beyond a demo)

- The demo creates a **ROOT** Private CA for simplicity; in production use a short‑lived
  **SUBORDINATE** CA chained to your org root, and the `SHORT_LIVED_CERTIFICATE` usage mode.
- Scope the IAM role to only the log groups / namespace you use; add a Roles Anywhere profile
  session policy and a trust‑policy condition on the certificate subject.
- ACL the cert/key so only `SYSTEM` (and admins) can read them. The credentials file holds live
  temporary creds in the LocalSystem profile dir — keep it off any shared location.
- AWS Private CA (ACM PCA) incurs a monthly charge — delete the CA (and this stack) when done.

---

## Cleanup

```powershell
Unregister-ScheduledTask -TaskName "OTelRefreshCreds" -Confirm:$false
Import-Module WebAdministration
Remove-Website -Name otel-frontend; Remove-Website -Name otel-backend
& "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a stop
```
```bash
aws cloudformation delete-stack --stack-name otel-demo-onprem-rolesanywhere --region us-west-2
```

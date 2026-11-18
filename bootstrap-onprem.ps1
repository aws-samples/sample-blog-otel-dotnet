#requires -RunAsAdministrator
<#
.SYNOPSIS
  On-premises Windows bootstrap for the otel-demo app with IAM Roles Anywhere.

.DESCRIPTION
  The on-prem analogue of the EC2 SSM bootstrap document. Run ONCE on the
  on-premises Windows host after deploying cfn-otel-demo-onprem-rolesanywhere.yaml.
  Idempotent: safe to re-run.

  PREREQUISITES (operator installs these first; the script verifies and aborts if missing):
    - Windows x64 with IIS enabled
    - .NET 10 SDK (to publish the app on the host)
    - ASP.NET Core 10 Hosting Bundle (ASP.NET Core Module for IIS + shared runtime)

  The script then configures, in order:

    1. IAM Roles Anywhere signing helper + a scheduled credential refresh
       (mints temporary creds from the X.509 cert -> static credentials file;
       NO long-lived AWS keys on the host)
    2. CloudWatch agent config: metrics + Windows event logs + IIS access logs
       + Application Signals / OTLP traces receiver (port 4316)
    3. ADOT .NET zero-code auto-instrumentation (SHA256-pinned) registered for IIS
    4. Publishes the frontend + no-DB backend and hosts them as two IIS sites,
       each with its own OTEL_SERVICE_NAME via web.config

  Result: metrics, logs, and distributed frontend -> backend traces flow to
  CloudWatch (X-Ray + Application Signals), authenticated by the certificate.

.PARAMETER TrustAnchorArn
  Roles Anywhere trust anchor ARN (stack output).
.PARAMETER ProfileArn
  Roles Anywhere profile ARN (stack output).
.PARAMETER RoleArn
  IAM role ARN (stack output).
.PARAMETER Region
  AWS region (default us-west-2).
.PARAMETER CertPath / KeyPath
  Paths to the X.509 client certificate and private key on the host.
.PARAMETER AppSourcePath
  Path to the app/ directory (containing frontend/ and backend-nodb/).

.EXAMPLE
  .\bootstrap-onprem.ps1 `
    -TrustAnchorArn arn:aws:rolesanywhere:us-west-2:111122223333:trust-anchor/xxxx `
    -ProfileArn     arn:aws:rolesanywhere:us-west-2:111122223333:profile/yyyy `
    -RoleArn        arn:aws:iam::111122223333:role/zzzz `
    -CertPath C:\otel-onprem\server.pem -KeyPath C:\otel-onprem\server.key `
    -AppSourcePath C:\otel-demo\src
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$TrustAnchorArn,
  [Parameter(Mandatory)] [string]$ProfileArn,
  [Parameter(Mandatory)] [string]$RoleArn,
  [string]$Region = "us-west-2",
  [string]$CertPath = "C:\otel-onprem\server.pem",
  [string]$KeyPath  = "C:\otel-onprem\server.key",
  [string]$AppSourcePath = "C:\otel-demo\src",

  # Pinned ADOT .NET release (keep in sync with the EC2 path / README).
  [string]$AdotModuleUrl    = "https://github.com/aws-observability/aws-otel-dotnet-instrumentation/releases/download/v1.15.0/AWS.Otel.DotNet.Auto.psm1",
  [string]$AdotModuleSha256 = "62a2b2e9cc24963608fe07f738c1bc6e4d853e42197ce4966c384ee6413eef3c",

  # Pinned CloudWatch Agent build (tested version; never the floating '/latest/' path).
  # Integrity: the MSI's Authenticode signature must be Valid and issued to Amazon Web Services, Inc.
  [string]$CwAgentVersion = "1.300073.2b1889"
)

$ErrorActionPreference = "Stop"
function Log($m){ Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor Cyan }

$Base       = "C:\otel-onprem"
$DemoRoot   = "C:\otel-demo"
$SitesRoot  = Join-Path $DemoRoot "sites"
$HelperExe  = Join-Path $Base "aws_signing_helper.exe"
$CwCtl      = "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1"
$CwDir      = "C:\ProgramData\Amazon\AmazonCloudWatchAgent"
$SysAwsCred = "C:\Windows\System32\config\systemprofile\.aws\credentials"
$AdminAwsCred = "C:\Users\Administrator\.aws\credentials"
New-Item -ItemType Directory -Force -Path $Base,$DemoRoot,$SitesRoot | Out-Null

# ---------------------------------------------------------------------------
Log "Prerequisite check (IIS, .NET SDK, ASP.NET Core Hosting Bundle must be preinstalled)"
# ---------------------------------------------------------------------------
# These are operator prerequisites (see the runbook), NOT installed by this script.
$prereqErrors = @()

if ((Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -EA 0).State -ne "Enabled") {
  $prereqErrors += "IIS is not enabled. Enable IIS + the ASP.NET Core Module (Hosting Bundle) first."
}
if (-not (Get-Command dotnet -EA 0)) {
  $prereqErrors += "The .NET SDK is not on PATH. Install the .NET 10 SDK first."
}
# ASP.NET Core shared runtime (installed by the Hosting Bundle) is required for IIS to host .NET.
if ((Get-Command dotnet -EA 0) -and -not (& dotnet --list-runtimes 2>$null | Select-String "Microsoft.AspNetCore.App 10\.")) {
  $prereqErrors += "ASP.NET Core 10 runtime not found. Install the ASP.NET Core 10 Hosting Bundle first."
}
# AspNetCoreModuleV2 present? (installed by the Hosting Bundle; required for IIS hosting)
if (-not (Test-Path 'C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll') -and
    -not (Test-Path 'C:\Windows\System32\inetsrv\aspnetcorev2.dll')) {
  $prereqErrors += "ASP.NET Core Module V2 not found. Install the ASP.NET Core Hosting Bundle (it installs the IIS module)."
}
if ($prereqErrors.Count) {
  Write-Host "`nMissing prerequisites:`n" -ForegroundColor Red
  $prereqErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  throw "Install the prerequisites above (see the runbook's Prerequisites section), then re-run."
}
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")

# ---------------------------------------------------------------------------
Log "1/4  Roles Anywhere signing helper + credential refresh (no long-lived keys)"
# ---------------------------------------------------------------------------
if (-not (Test-Path $HelperExe)) {
  Invoke-WebRequest -Uri "https://rolesanywhere.amazonaws.com/releases/1.5.0/X86_64/Windows/aws_signing_helper.exe" -OutFile $HelperExe -UseBasicParsing
}
foreach ($f in @($CertPath,$KeyPath)) { if (-not (Test-Path $f)) { throw "Missing certificate/key: $f" } }
icacls $CertPath /grant "SYSTEM:(R)" | Out-Null
icacls $KeyPath  /grant "SYSTEM:(R)" | Out-Null

# refresh-creds.ps1 : mint temp creds from the cert, write them as STATIC creds
# (both [default] and [AmazonCloudWatchAgent], to both the LocalSystem and the
# generated-TOML credential paths) so every agent output plugin resolves them.
$refresh = Join-Path $Base "refresh-creds.ps1"
@"
`$ErrorActionPreference = "Stop"
`$cpArgs = @("credential-process","--certificate","$CertPath","--private-key","$KeyPath",
            "--trust-anchor-arn","$TrustAnchorArn","--profile-arn","$ProfileArn","--role-arn","$RoleArn")
`$c = (& "$HelperExe" @cpArgs | ConvertFrom-Json)
`$block = @(
  "[default]","aws_access_key_id = `$(`$c.AccessKeyId)","aws_secret_access_key = `$(`$c.SecretAccessKey)","aws_session_token = `$(`$c.SessionToken)","region = $Region","",
  "[AmazonCloudWatchAgent]","aws_access_key_id = `$(`$c.AccessKeyId)","aws_secret_access_key = `$(`$c.SecretAccessKey)","aws_session_token = `$(`$c.SessionToken)","region = $Region"
)
`$text = (`$block -join "`r`n") + "`r`n"
foreach (`$t in @("$SysAwsCred","$AdminAwsCred")) {
  `$d = Split-Path `$t; if (-not (Test-Path `$d)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null }
  [System.IO.File]::WriteAllText(`$t, `$text)
}
"@ | Set-Content -Path $refresh -Encoding ASCII

& $refresh   # seed immediately

# scheduled refresh every 30 min (creds are 1 hour) as SYSTEM, also at startup
$act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File $refresh"
$trg = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
$trg2 = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "OTelRefreshCreds" -Action $act -Trigger @($trg,$trg2) -Principal $prn -Force | Out-Null

# ---------------------------------------------------------------------------
Log "2/4  CloudWatch agent (metrics + logs + Application Signals / OTLP traces)"
# ---------------------------------------------------------------------------
if (-not (Get-Service AmazonCloudWatchAgent -EA 0)) {
  # Version-pinned download from AWS's regional CloudWatch Agent bucket over HTTPS, then a
  # vendor-attested integrity check (Authenticode signature by Amazon Web Services, Inc.)
  # before install. A self-computed hash is deliberately not embedded: it would only attest
  # our own one-time download, not AWS's publication. PROD: mirror the reviewed MSI into an
  # internal artifact store and verify against an organization-controlled hash.
  $msi = "$env:TEMP\amazon-cloudwatch-agent.msi"
  $cwUrl = "https://amazoncloudwatch-agent-$Region.s3.$Region.amazonaws.com/windows/amd64/$CwAgentVersion/amazon-cloudwatch-agent.msi"
  Invoke-WebRequest -Uri $cwUrl -OutFile $msi -UseBasicParsing
  $sig = Get-AuthenticodeSignature -FilePath $msi
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O="?Amazon Web Services, Inc\.') {
    Remove-Item $msi -Force -EA 0
    throw "CloudWatch Agent MSI integrity check FAILED: signature status '$($sig.Status)', signer '$($sig.SignerCertificate.Subject)'"
  }
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
  Remove-Item $msi -Force -EA 0
}
# minimal common-config: use the [default] profile from the credentials file
[System.IO.File]::WriteAllText((Join-Path $CwDir "common-config.toml"),
  "# credentials: [default] profile in LocalSystem .aws\credentials (refresh-creds.ps1)`r`n")

$agentCfg = Join-Path $CwDir "otel-onprem-config-traces.json"
@'
{
  "agent": { "metrics_collection_interval": 60,
             "logfile": "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent\\Logs\\amazon-cloudwatch-agent.log" },
  "traces": { "traces_collected": { "application_signals": {} } },
  "logs": {
    "metrics_collected": { "application_signals": {} },
    "logs_collected": {
      "files": { "collect_list": [
        { "file_path": "C:\\inetpub\\logs\\LogFiles\\W3SVC1\\*.log", "log_group_name": "/otel-onprem-demo/iis-access", "log_stream_name": "otel-onprem-laptop" }
      ] },
      "windows_events": { "collect_list": [
        { "event_name": "Application", "event_levels": ["ERROR","WARNING","INFORMATION"], "log_group_name": "/otel-onprem-demo/windows/application", "log_stream_name": "otel-onprem-laptop" },
        { "event_name": "System", "event_levels": ["ERROR","WARNING"], "log_group_name": "/otel-onprem-demo/windows/system", "log_stream_name": "otel-onprem-laptop" }
      ] }
    }
  },
  "metrics": {
    "namespace": "OTelOnPremDemo",
    "metrics_collected": {
      "LogicalDisk": { "measurement": ["% Free Space"], "resources": ["*"] },
      "Memory": { "measurement": ["% Committed Bytes In Use"] },
      "Processor": { "measurement": ["% Processor Time"], "resources": ["_Total"] }
    }
  }
}
'@ | Set-Content -Path $agentCfg -Encoding ASCII
& $CwCtl -a fetch-config -m onPremise -s -c "file:$agentCfg" | Out-Null

# ---------------------------------------------------------------------------
Log "3/4  ADOT .NET auto-instrumentation (SHA256-pinned) + register for IIS"
# ---------------------------------------------------------------------------
$mod = Join-Path $Base "AWS.Otel.DotNet.Auto.psm1"
Invoke-WebRequest -Uri $AdotModuleUrl -OutFile $mod -UseBasicParsing
$actual = (Get-FileHash $mod -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $AdotModuleSha256) { throw "ADOT module integrity check FAILED: expected $AdotModuleSha256 got $actual" }
Import-Module $mod -Force
if (-not (Test-Path 'C:\Program Files\AWS Distro for OpenTelemetry AutoInstrumentation\net\net10.0\OpenTelemetry.Api.dll')) {
  Install-OpenTelemetryCore
}
Register-OpenTelemetryForIIS

# ---------------------------------------------------------------------------
Log "4/4  Publish apps + host as two IIS sites (per-site OTEL_SERVICE_NAME)"
# ---------------------------------------------------------------------------
dotnet publish (Join-Path $AppSourcePath "frontend\Frontend.csproj")     -c Release -o (Join-Path $SitesRoot "frontend") | Out-Null
dotnet publish (Join-Path $AppSourcePath "backend-nodb\BackendApi.csproj") -c Release -o (Join-Path $SitesRoot "backend")  | Out-Null

# web.config per site: ADOT OTEL_* env + frontend BACKEND_URL + distinct service names.
function Write-SiteWebConfig($path,$dll,$service,[bool]$isFrontend){
  $extra = if ($isFrontend) { '          <environmentVariable name="BACKEND_URL" value="http://localhost:5000" />' + "`r`n" } else { "" }
  @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\$dll" stdoutLogEnabled="true" stdoutLogFile=".\logs\stdout" hostingModel="inprocess">
        <environmentVariables>
$extra          <environmentVariable name="OTEL_SERVICE_NAME" value="$service" />
          <environmentVariable name="OTEL_RESOURCE_ATTRIBUTES" value="deployment.environment=onprem:otel-demo,host.name=$env:COMPUTERNAME,aws.deployment.platform=on-premises" />
          <environmentVariable name="OTEL_EXPORTER_OTLP_PROTOCOL" value="http/protobuf" />
          <environmentVariable name="OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" value="http://localhost:4316/v1/traces" />
          <environmentVariable name="OTEL_AWS_APPLICATION_SIGNALS_EXPORTER_ENDPOINT" value="http://localhost:4316/v1/metrics" />
          <environmentVariable name="OTEL_AWS_APPLICATION_SIGNALS_ENABLED" value="true" />
          <environmentVariable name="OTEL_METRICS_EXPORTER" value="none" />
          <environmentVariable name="OTEL_LOGS_EXPORTER" value="none" />
          <environmentVariable name="OTEL_DOTNET_AUTO_TRACES_HTTP_ROUTE_BASED_SPAN_NAMES" value="true" />
        </environmentVariables>
      </aspNetCore>
    </system.webServer>
  </location>
</configuration>
"@ | Set-Content -Path $path -Encoding UTF8
}
Write-SiteWebConfig (Join-Path $SitesRoot "frontend\web.config") "Frontend.dll"  "otel-demo-frontend" $true
Write-SiteWebConfig (Join-Path $SitesRoot "backend\web.config")  "BackendApi.dll" "otel-demo-backend"  $false

Import-Module WebAdministration
if (Get-Website -Name "Default Web Site" -EA 0) { Remove-Website -Name "Default Web Site" }
foreach ($s in @(
    @{ Name="otel-frontend"; Path=(Join-Path $SitesRoot "frontend"); Port=80 },
    @{ Name="otel-backend";  Path=(Join-Path $SitesRoot "backend");  Port=5000 })) {
  if (-not (Get-WebAppPoolState -Name $s.Name -EA 0)) { New-WebAppPool -Name $s.Name -Force | Out-Null }
  Set-ItemProperty "IIS:\AppPools\$($s.Name)" -Name managedRuntimeVersion -Value ""   # No Managed Code
  if (Get-Website -Name $s.Name -EA 0) { Remove-Website -Name $s.Name }
  New-Website -Name $s.Name -PhysicalPath $s.Path -ApplicationPool $s.Name -Port $s.Port -Force | Out-Null
  icacls $s.Path /grant "IIS AppPool\$($s.Name):(OI)(CI)(RX)" /T | Out-Null
}
iisreset /restart | Out-Null

Log "DONE. Generate traffic, then view CloudWatch > Application Signals and X-Ray."
Write-Host "  Frontend : http://localhost/           (click 'Load Test')"
Write-Host "  Health   : http://localhost/health  |  http://localhost:5000/api/health"

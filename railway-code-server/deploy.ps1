# Railway code-server deploy script (Windows PowerShell)
# Usage: .\deploy.ps1 [-Password "secret"] [-SudoPassword "secret2"]
#
# Requires the railway CLI (v5.35.1) on PATH.
param(
	[string]$Password = "",
	[string]$SudoPassword = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# 1. Ensure we're linked to the code-server service
railway link -s code-server 2>&1 | Out-Host

# 2. Set runtime variables (skip empty)
if ($Password) {
	railway variable set "PASSWORD=$Password" 2>&1 | Out-Host
}
if ($SudoPassword) {
	railway variable set "SUDO_PASSWORD=$SudoPassword" 2>&1 | Out-Host
}
railway variable set "DEFAULT_WORKSPACE=/config/workspace" 2>&1 | Out-Host
railway variable set "TZ=Etc/UTC" 2>&1 | Out-Host

# 3. Create/attach volume at /config (persistence)
railway volume add --mount-path /config 2>&1 | Out-Host

# 4. Generate a public domain
railway domain 2>&1 | Out-Host

# 5. Upload and deploy this folder (Dockerfile builds on Railway)
railway up 2>&1 | Out-Host

Write-Host ""
Write-Host "Done. Open the generated *.up.railway.app URL and sign in with PASSWORD." -ForegroundColor Green

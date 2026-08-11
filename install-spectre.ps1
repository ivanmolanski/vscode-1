# Install Spectre-mitigated CRT libraries for MSVC toolsets 14.29 and 14.50
# on the Visual Studio Community 2026 instance. Fixes MSB8040 for node-gyp
# native addons (@vscode/*) which force SpectreMitigation in their binding.gyp.
# Run this in an ELEVATED PowerShell (right-click -> Run as Administrator),
# or from an elevated terminal: powershell -ExecutionPolicy Bypass -File .\install-spectre.ps1
# https://learn.microsoft.com/en-us/cpp/build/reference/qspectre?view=msvc-170
$ErrorActionPreference = 'Stop'
$installer = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe'
$installPath = 'C:\Program Files\Microsoft Visual Studio\18\Community'

if (-not (Test-Path $installer)) {
    throw "VS Installer not found at $installer"
}
if (-not (Test-Path $installPath)) {
    throw "VS instance not found at $installPath"
}

Write-Host "[1/1] Installing Spectre mitigation libraries for MSVC 14.29 + 14.50 (this can take several minutes)..." -ForegroundColor Cyan

& $installer modify `
    --installPath $installPath `
    --add 'Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64.Spectre' `
    --add 'Microsoft.VisualStudio.Component.VC.14.50.x86.x64.Spectre' `
    --quiet --norestart

$exit = $LASTEXITCODE
if ($exit -eq 0) {
    Write-Host "SUCCESS: Spectre libraries installed." -ForegroundColor Green
} else {
    Write-Host "Installer exited with code $exit" -ForegroundColor Red
}
exit $exit

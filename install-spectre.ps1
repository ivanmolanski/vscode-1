# Install Spectre-mitigated CRT libraries for MSVC toolsets 14.29, 14.51 and 14.52
# on the Visual Studio Community 2026 instance. Fixes MSB8040 for node-gyp
# native addons (@vscode/*) which force SpectreMitigation in their binding.gyp.
# Just run it: powershell -ExecutionPolicy Bypass -File .\install-spectre.ps1
# It relaunches itself elevated (you'll get a UAC "Yes / No" prompt).
# https://learn.microsoft.com/en-us/cpp/build/reference/qspectre?view=msvc-170
$ErrorActionPreference = 'Stop'

# --- Self-elevate: relaunch this script as Administrator ----------------------
# The VS Installer requires elevation; instead of failing, pop the UAC prompt.
$principal = New-Object Security.Principal.WindowsPrincipal(
	[Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $principal.IsInRole(
	[Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
	$elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
		'-NoProfile',
		'-ExecutionPolicy', 'Bypass',
		'-File', "`"$PSCommandPath`""
	) -Wait -PassThru
	exit $elevated.ExitCode
}

$installer = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe'
$installPath = 'C:\Program Files\Microsoft Visual Studio\18\Community'

if (-not (Test-Path $installer)) {
	throw "VS Installer not found at $installer"
}
if (-not (Test-Path $installPath)) {
	throw "VS instance not found at $installPath"
}

Write-Host "[1/1] Installing Spectre mitigation libraries for MSVC 14.29 + 14.51 + 14.52 (this can take several minutes)..." -ForegroundColor Cyan

& $installer modify `
	--installPath $installPath `
	--add 'Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64.Spectre' `
	--add 'Microsoft.VisualStudio.Component.VC.14.51.x86.x64.Spectre' `
	--add 'Microsoft.VisualStudio.Component.VC.14.52.x86.x64.Spectre' `
	--quiet --norestart

$exit = $LASTEXITCODE
if ($null -eq $exit) { $exit = -1 }
switch ($exit) {
	0 {
		Write-Host "SUCCESS: Spectre libraries installed." -ForegroundColor Green
	}
	740 {
		Write-Host "ERROR: the VS Installer requires elevation (exit 740). Re-run the script and click 'Yes' on the UAC prompt." -ForegroundColor Red
	}
	5007 {
		Write-Host "ERROR: the VS Installer reported unmet requirements (exit 5007)." -ForegroundColor Red
	}
	{ $_ -in 1641, 3010 } {
		Write-Host "SUCCESS: Spectre libraries installed. A reboot is required for the change to take full effect." -ForegroundColor Yellow
	}
	default {
		Write-Host "Installer exited with code $exit (see https://learn.microsoft.com/en-us/visualstudio/installation/use-command-line-parameters-to-install-visual-studio#error-codes)" -ForegroundColor Red
	}
}
# Preserve installer statuses: 1641/3010 (reboot required) are surfaced as
# distinct statuses rather than being coerced to 0, so callers can detect them.
exit $exit

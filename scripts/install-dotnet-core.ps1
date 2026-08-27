# Installs the .NET SDK 10 (LTS) via Microsoft's own official installer exe,
# not winget/Chocolatey - this project's images are offline-applied and don't
# carry the App Installer/Store plumbing winget depends on, and Chocolatey was
# already considered and set aside for this project (see CLAUDE.md's Phase 4
# "Research first" note) for the same "no live-bootstrapped package manager"
# reason. Same pattern as install-sql-server.ps1: download a real Microsoft
# bootstrapper, run its own documented silent-install switches, verify.
#
# Unlike iis/ad-ds/sql-server, this role is NOT Server-only - the SDK
# installer and its /install /quiet /norestart switches are identical on
# Windows Server 2022/2025 and Windows 11 (confirmed against Microsoft's own
# "Install .NET on Windows" doc), so there's no OS branching here the way
# install-iis.ps1 needs.
#
# Download URL: https://aka.ms/dotnet/10.0/dotnet-sdk-win-x64.exe is
# Microsoft's own stable, channel-based aka.ms redirect (same aka.ms/builds.
# dotnet.microsoft.com mechanism documented in Microsoft's dotnet-install
# script docs) - verified live before writing this script, not assumed: it
# 301-redirects to https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.400/
# dotnet-sdk-10.0.400-win-x64.exe. Always resolves to the latest 10.0.x SDK
# build, so this script doesn't need updating every time .NET 10 gets serviced.
$ErrorActionPreference = "Stop"

$installerUrl = "https://aka.ms/dotnet/10.0/dotnet-sdk-win-x64.exe"
$installerPath = "C:\Windows\Temp\dotnet-sdk-10-win-x64.exe"

Write-Host "Downloading .NET SDK 10 installer..."
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

Write-Host "Running .NET SDK 10 installer (silent)..."
$proc = Start-Process -FilePath $installerPath -ArgumentList @(
    "/install",
    "/quiet",
    "/norestart"
) -Wait -PassThru

# Per Microsoft's own installer docs: 0 = success, 3010 = success but a
# restart is recommended (not required for the SDK to be usable) - this
# project's Packer pipeline already reboots once after run-services.ps1
# regardless (see verify-post-reboot.ps1), so 3010 needs no special handling
# here beyond not treating it as a failure.
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw ".NET SDK 10 installer failed with exit code $($proc.ExitCode)"
}
if ($proc.ExitCode -eq 3010) {
    Write-Host ".NET SDK 10 installed - a restart is recommended (exit code 3010)."
}

Write-Host "Verifying .NET SDK 10 installed..."
$dotnetExe = "C:\Program Files\dotnet\dotnet.exe"
if (-not (Test-Path $dotnetExe)) {
    throw "dotnet.exe not found at $dotnetExe after install"
}

# Invoke the installer's own path directly rather than the bare `dotnet`
# alias - the machine PATH was just updated by the installer, but this
# script's own already-running PowerShell process won't see that change
# until a new session starts.
$sdks = & $dotnetExe --list-sdks 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "'dotnet --list-sdks' failed (exit code $LASTEXITCODE): $sdks"
}
if (-not ($sdks -match '^10\.')) {
    throw "No .NET 10 SDK found in 'dotnet --list-sdks' output: $sdks"
}

Write-Host ".NET SDK 10 installed and verified: $sdks"

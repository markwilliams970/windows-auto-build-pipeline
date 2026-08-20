# Phase 3 orchestrator: reads services.yaml and, for each listed role, runs
# the matching scripts\install-<role>.ps1 if present. Deliberately no YAML
# module dependency - services.yaml's shape (a flat list under one key) is
# simple enough for a plain regex parser. Packer's HCL provisioners can't
# conditionally skip based on a runtime variable, so this one script (always
# invoked) is what actually decides which roles run - see CLAUDE.md's
# Service Selection note.
param(
    [string]$ServicesYamlPath = "C:\Windows\Temp\services.yaml",
    [string]$ScriptsDir = "C:\Windows\Temp\scripts",
    # Only meaningful to install-ad.ps1; passed through generically via
    # environment rather than as a role-specific orchestrator parameter, so
    # this script doesn't need special-case knowledge of any one role.
    [string]$DomainName = "corp.example.internal"
)

$ErrorActionPreference = "Stop"

$env:AD_DOMAIN_NAME = $DomainName

if (-not (Test-Path $ServicesYamlPath)) {
    throw "services.yaml not found at $ServicesYamlPath"
}

$roles = Get-Content $ServicesYamlPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '^-\s*([A-Za-z0-9_-]+)\s*(#.*)?$') {
        $Matches[1]
    }
}

if (-not $roles -or $roles.Count -eq 0) {
    Write-Host "No services selected in $ServicesYamlPath - bare Windows Server build."
    exit 0
}

Write-Host "Services selected: $($roles -join ', ')"

# windows-auto-build-pipeline addition (not present in the sibling project):
# AD DS and the app-server roles (IIS/SQL Server) are mutually exclusive
# profiles here - a domain controller build should never also carry IIS or
# SQL Server, and vice versa. Enforced here as defense-in-depth (the primary
# gate is a host-side pre-check in dev/run-phase3-test.sh, which fails fast
# before a VM is even booted) in case services.yaml is ever hand-edited or
# this script is invoked some other way.
$domainControllerRoles = @("ad-ds")
$appServerRoles = @("iis", "sql-server")
$selectedDomainControllerRoles = $roles | Where-Object { $domainControllerRoles -contains $_ }
$selectedAppServerRoles = $roles | Where-Object { $appServerRoles -contains $_ }
if ($selectedDomainControllerRoles -and $selectedAppServerRoles) {
    throw "services.yaml selects mutually exclusive roles: domain-controller role(s) [$($selectedDomainControllerRoles -join ', ')] cannot be combined with app-server role(s) [$($selectedAppServerRoles -join ', ')]."
}

# services.yaml role names don't all mechanically map to "install-<role>.ps1"
# (ad-ds -> install-ad.ps1, per CLAUDE.md's repo structure) - explicit
# exceptions here, falling back to the plain convention for everything else.
$roleScriptOverrides = @{
    "ad-ds" = "install-ad.ps1"
}

$failedRoles = @()
foreach ($role in $roles) {
    $scriptName = if ($roleScriptOverrides.ContainsKey($role)) { $roleScriptOverrides[$role] } else { "install-$role.ps1" }
    $scriptPath = Join-Path $ScriptsDir $scriptName
    if (-not (Test-Path $scriptPath)) {
        Write-Host "WARNING: no install script found for role '$role' (expected $scriptPath) - skipping"
        continue
    }
    Write-Host "=== Installing role: $role ==="
    try {
        & $scriptPath
        Write-Host "=== Role '$role' completed successfully ==="
    } catch {
        Write-Host "ERROR: role '$role' failed: $_"
        $failedRoles += $role
    }
}

if ($failedRoles.Count -gt 0) {
    throw "One or more roles failed to install: $($failedRoles -join ', ')"
}

Write-Host "All selected roles installed successfully."

# Phase 4 tool installer (PHASE4_TOOLS_INSTALLER_PLAN.md). Runs from the mounted delivery ISO
# built by image-apply/install-tools.sh, which stages each installer under a normalized filename
# (7zip.msi, putty.msi, winscp.exe, notepadplusplus.msi, chrome.msi, datadog-agent.msi) so this
# script never needs to glob-match an unpredictable, version-numbered upstream filename - only
# datadog-agent's tools.yaml-pinned version varies at the CRUD-idempotency level (see Install-Tool
# below); the other five always install whichever version install-tools.sh happened to fetch this
# run - see the plan doc's A.1/A.3 revision for why these five are deliberately not pinned.
#
# Deliberately no YAML module dependency - tools.yaml's shape (a flat list plus one small nested
# block) is simple enough for a plain regex/section parser, matching run-services.ps1's own
# established convention for services.yaml.
#
# Detection NEVER uses Win32_Product (querying it silently reconfigures every MSI-installed
# product on the machine - a real, documented side effect, not a style preference; see the plan
# doc's A.1/A.4). Registry Uninstall-key scanning is used instead, adopted from PSAppDeployToolkit's
# own established pattern.
param(
    [string]$ToolsYamlPath = (Join-Path $PSScriptRoot "tools.yaml"),
    [string]$ToolsDir      = $PSScriptRoot,
    [ValidateSet("Install", "Uninstall", "Status")]
    [string]$Mode = "Install",
    [string]$ApiKey = $env:DD_API_KEY
)

$ErrorActionPreference = "Stop"

$ToolSpecs = @{
    "7zip" = @{
        File          = "7zip.msi"
        Type          = "msi"
        InstallArgs   = "/qn /norestart"
        DetectPattern = "^7-Zip"
    }
    "putty" = @{
        File          = "putty.msi"
        Type          = "msi"
        InstallArgs   = "/quiet /norestart"
        DetectPattern = "^PuTTY"
    }
    "winscp" = @{
        File            = "winscp.exe"
        Type            = "inno"
        InstallArgs     = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS"
        UninstallArgs   = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
        DetectPattern   = "^WinSCP"
    }
    "notepadplusplus" = @{
        File          = "notepadplusplus.msi"
        Type          = "msi"
        InstallArgs   = "/qn /norestart"
        DetectPattern = "^Notepad\+\+"
    }
    "chrome" = @{
        File          = "chrome.msi"
        Type          = "msi"
        InstallArgs   = "/qn /norestart NOGOOGLEUPDATEPING=1"
        DetectPattern = "^Google Chrome$"
    }
    "datadog-agent" = @{
        File          = "datadog-agent.msi"
        Type          = "msi"
        InstallArgs   = "/qn /norestart REBOOT=ReallySuppress"
        DetectPattern = "^Datadog Agent$"
    }
}

# --- tools.yaml parsing: flat "tools:" list + one nested "datadog:" block (agent_version/site/tags) ---
# Mirrors run-services.ps1's own plain-regex approach for services.yaml, extended with simple
# section tracking since tools.yaml has one more level of structure than services.yaml does.
function Read-ToolsYaml {
    param([string]$Path)

    if (-not (Test-Path $Path)) { throw "tools.yaml not found at $Path" }

    $tools = New-Object System.Collections.Generic.List[string]
    $tags = New-Object System.Collections.Generic.List[string]
    $agentVersion = $null
    $site = $null
    $section = $null

    foreach ($raw in Get-Content $Path) {
        $trimmed = $raw.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }

        if ($raw -match '^tools:\s*$') { $section = "tools"; continue }
        if ($raw -match '^datadog:\s*$') { $section = "datadog"; continue }
        if ($raw -match '^[^\s#]') { $section = $null; continue }  # some other top-level key - stop attributing indented lines to the prior section

        if ($section -eq "tools") {
            if ($trimmed -match '^-\s*([A-Za-z0-9_-]+)\s*(#.*)?$') { $tools.Add($Matches[1]) }
        } elseif ($section -eq "datadog") {
            if ($trimmed -match '^agent_version:\s*"?([^"#]+?)"?\s*(#.*)?$') { $agentVersion = $Matches[1].Trim() }
            elseif ($trimmed -match '^site:\s*"?([^"#]+?)"?\s*(#.*)?$') { $site = $Matches[1].Trim() }
            elseif ($trimmed -match '^tags:\s*$') { }
            elseif ($trimmed -match '^-\s*"?([^"#]+?)"?\s*(#.*)?$') { $tags.Add($Matches[1].Trim()) }
        }
    }

    return @{
        Tools        = $tools
        AgentVersion = $agentVersion
        Site         = $site
        Tags         = ($tags -join ",")
    }
}

# --- CRUD engine ------------------------------------------------------------------------------

function Get-ToolStatus {
    # Read. Registry Uninstall-key scan - see this file's own header for why Win32_Product is
    # never used here. All six tools install system-wide, so HKCU paths aren't needed.
    param([string]$DetectPattern)

    $match = Get-ItemProperty -Path @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -match $DetectPattern } |
        Select-Object -First 1

    if (-not $match) { return $null }
    return @{
        DisplayName     = $match.DisplayName
        DisplayVersion  = $match.DisplayVersion
        UninstallString = $match.UninstallString
    }
}

function Install-Tool {
    # Create/Update, idempotent. Two different idempotency rules (see PHASE4_TOOLS_INSTALLER_PLAN.md
    # B.3): the five floating-latest tools skip if ANY version is already present (re-running this
    # script is a no-op for them, never a forced upgrade); datadog-agent skips only if the present
    # version exactly matches tools.yaml's pinned agent_version, otherwise reinstalls to converge
    # (relying on the MSI engine's own upgrade-in-place behavior for a same-UpgradeCode product).
    param(
        [string]$Name,
        [hashtable]$Spec,
        [string]$AgentVersion,
        [string]$Site,
        [string]$Tags,
        [string]$ApiKey
    )

    $status = Get-ToolStatus -DetectPattern $Spec.DetectPattern

    if ($Name -eq "datadog-agent") {
        if ($status -and $status.DisplayVersion -eq $AgentVersion) {
            Write-Host "[$Name] already at pinned version $($status.DisplayVersion) - skipping"
            return
        }
        if ($status) {
            Write-Host "[$Name] present at $($status.DisplayVersion), pinned version is $AgentVersion - reinstalling to converge"
        }
    } elseif ($status) {
        Write-Host "[$Name] already present (version $($status.DisplayVersion)) - skipping"
        return
    }

    $installerPath = Join-Path $ToolsDir $Spec.File
    if (-not (Test-Path $installerPath)) { throw "[$Name] installer not found at $installerPath" }

    Write-Host "[$Name] installing from $installerPath"
    switch ($Spec.Type) {
        "msi" {
            $extraArgs = ""
            if ($Name -eq "datadog-agent") {
                $extraArgs = " APIKEY=`"$ApiKey`" SITE=`"$Site`""
                if ($Tags) { $extraArgs += " TAGS=`"$Tags`"" }
            }
            $argList = "/i `"$installerPath`" $($Spec.InstallArgs)$extraArgs"
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $argList -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "[$Name] msiexec failed with exit $($proc.ExitCode)" }
        }
        "inno" {
            $proc = Start-Process -FilePath $installerPath -ArgumentList $Spec.InstallArgs -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "[$Name] installer failed with exit $($proc.ExitCode)" }
        }
        default { throw "[$Name] unknown installer type '$($Spec.Type)'" }
    }

    Start-Sleep -Seconds 3
    $postStatus = Get-ToolStatus -DetectPattern $Spec.DetectPattern
    if (-not $postStatus) { throw "[$Name] installed but not found in the registry afterward - install may have silently failed" }
    Write-Host "[$Name] installed: version $($postStatus.DisplayVersion)"
}

function Uninstall-Tool {
    # Delete, idempotent: skips with a logged reason if already absent.
    param([string]$Name, [hashtable]$Spec)

    $status = Get-ToolStatus -DetectPattern $Spec.DetectPattern
    if (-not $status) {
        Write-Host "[$Name] already absent - nothing to do"
        return
    }

    Write-Host "[$Name] uninstalling (was version $($status.DisplayVersion))"
    if ($Spec.Type -eq "msi") {
        if ($status.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
            $productCode = $Matches[0]
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru
        } else {
            throw "[$Name] could not parse a product code from UninstallString '$($status.UninstallString)'"
        }
    } else {
        $exePath = $status.UninstallString.Trim('"')
        $uninstallArgs = if ($Spec.UninstallArgs) { $Spec.UninstallArgs } else { $Spec.InstallArgs }
        $proc = Start-Process -FilePath $exePath -ArgumentList $uninstallArgs -Wait -PassThru
    }
    if ($proc.ExitCode -ne 0) { throw "[$Name] uninstall failed with exit $($proc.ExitCode)" }

    Start-Sleep -Seconds 3
    if (Get-ToolStatus -DetectPattern $Spec.DetectPattern) { throw "[$Name] still present in the registry after uninstall" }
    Write-Host "[$Name] uninstalled"
}

# --- orchestrator, same shape as run-services.ps1 (parse, loop, collect failures, throw once) ---

$config = Read-ToolsYaml -Path $ToolsYamlPath

if ($Mode -eq "Status") {
    foreach ($name in $ToolSpecs.Keys) {
        $status = Get-ToolStatus -DetectPattern $ToolSpecs[$name].DetectPattern
        if ($status) { Write-Host "[$name] PRESENT version=$($status.DisplayVersion)" }
        else { Write-Host "[$name] ABSENT" }
    }
    exit 0
}

if ($config.Tools.Count -eq 0) {
    Write-Host "No tools selected in $ToolsYamlPath"
    exit 0
}

# Defense-in-depth: image-apply/install-tools.sh already checks this host-side before ever
# booting the VM (fails loud before boot, per PHASE4_TOOLS_INSTALLER_PLAN.md's Phase C decision
# #3) - this guest-side check mirrors run-services.ps1's own domain-controller/app-server
# mutual-exclusion check, which is also enforced in two places for the same reason (defense in
# depth in case this script is ever invoked directly, bypassing install-tools.sh).
if ($Mode -eq "Install" -and $config.Tools -contains "datadog-agent" -and -not $ApiKey) {
    throw "datadog-agent is listed in tools.yaml but no API key was supplied (-ApiKey / `$env:DD_API_KEY) - refusing to install unconfigured"
}

Write-Host "Tools selected (${Mode}): $($config.Tools -join ', ')"

$failed = New-Object System.Collections.Generic.List[string]
foreach ($name in $config.Tools) {
    if (-not $ToolSpecs.ContainsKey($name)) {
        Write-Host "WARNING: no installer spec for tool '$name' - skipping"
        continue
    }
    Write-Host "=== ${Mode}: $name ==="
    try {
        if ($Mode -eq "Install") {
            Install-Tool -Name $name -Spec $ToolSpecs[$name] -AgentVersion $config.AgentVersion -Site $config.Site -Tags $config.Tags -ApiKey $ApiKey
        } else {
            Uninstall-Tool -Name $name -Spec $ToolSpecs[$name]
        }
        Write-Host "=== ${Mode} '$name' completed successfully ==="
    } catch {
        Write-Host "ERROR: ${Mode} '$name' failed: $_"
        $failed.Add($name)
    }
}

if ($failed.Count -gt 0) {
    throw "One or more tools failed to $($Mode.ToLower()): $($failed -join ', ')"
}

Write-Host "All selected tools ${Mode}ed successfully."

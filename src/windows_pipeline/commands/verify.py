"""`windows-pipeline verify <host_id> [--checks connectivity,roles,virtio,tools]`

Each check group is a small, self-contained PowerShell snippet sent over
WinRM - the same shape every image-apply/*.sh script already uses
(winrm_ps), not a framework. Phase 5 research (see PHASE5 design discussion)
found no WinRM/Windows-guest verification framework (Goss, Testinfra, Chef
InSpec) worth adopting here: all three are really just DSL wrappers over the
same WinRM+PowerShell/WMI checks this project's own scripts already do by
hand, so adopting one would add a real runtime dependency for no functional
gain. What's adopted from that research instead is *convention*, not
tooling: a consistent CheckResult (name/passed/detail) per check so results
aggregate the way a framework's own report would, without the framework.

- connectivity: hostname/OS identity - the fast baseline every other group
  implicitly depends on already having WinRM up.
- roles: detects whichever of AD DS/IIS/SQL Server is actually present and
  checks it the same way this project's own build pipeline already does
  (project_documentation/PHASE3_ENGINEERING_LOG.md's own success bar - NTDS/DNS/ADWS + a real
  Get-ADDomain call; W3SVC + HTTP 200; MSSQLSERVER + a real SA login and
  SELECT 1) - not gated on services.yaml, since verify may run long after
  build time against a VM whose provisioning history isn't in front of it.
- virtio: the same Stage 2 checks inject-virtio-spice.sh's own live-verify
  already performs (disk online, VirtIO NIC up, QXL display OK, vdservice
  running) - copied, not reinvented.
- tools: the same registry DetectPattern scan install-tools.ps1's own
  Get-ToolStatus uses (copied directly, kept in sync via the comment below -
  re-invoking install-tools.ps1 itself isn't an option here since it's only
  ever staged onto a transient delivery ISO during install-tools.sh's own
  build-time session, never left on the guest afterward), plus the Datadog
  Agent bar from CLAUDE.md's "Datadog Validation Requirements": service
  exists, service running, status command runs. Full connectivity/host
  registration can't be confirmed without a real API key - CLAUDE.md already
  notes this was never exercised even at install time; verify says so
  explicitly rather than claiming more than it checked.
"""

from __future__ import annotations

import json
import sys
from dataclasses import asdict

from windows_pipeline.libvirt_util import domain_exists, domain_state
from windows_pipeline.util import now_iso
from windows_pipeline.winrm_util import CheckResult, VMUnreachableError, connect, run_ps

ALL_GROUPS = ["connectivity", "roles", "virtio", "tools"]

# Kept in sync by hand with scripts/install-tools.ps1's own $ToolSpecs - see that file's
# header for why registry Uninstall-key scanning is used instead of Win32_Product.
TOOL_DETECT_PATTERNS = {
    "7zip": "^7-Zip",
    "putty": "^PuTTY",
    "winscp": "^WinSCP",
    "notepadplusplus": "^Notepad\\+\\+",
    "chrome": "^Google Chrome$",
    "datadog-agent": "^Datadog Agent$",
}


def _check_connectivity(session) -> list[CheckResult]:
    r = run_ps(
        session,
        "Get-CimInstance Win32_OperatingSystem | "
        "Select-Object -ExpandProperty Caption; "
        "hostname",
    )
    if r.returncode != 0:
        return [CheckResult("winrm", False, r.stderr.decode(errors="replace").strip() or "run_ps failed")]
    lines = [l for l in r.stdout.decode(errors="replace").splitlines() if l.strip()]
    caption = lines[0] if lines else "?"
    hostname = lines[1] if len(lines) > 1 else "?"
    return [
        CheckResult("winrm", True, "connected"),
        CheckResult("os_caption", True, caption),
        CheckResult("hostname", True, hostname),
    ]


def _check_roles(session) -> list[CheckResult]:
    # Two real bugs found testing this against a live VM (2026-09-05), both fixed here:
    #
    # 1. PowerShell's `ConvertTo-Json` serializes ServiceControllerStatus as its
    #    underlying int (4, not "Running") on Windows PowerShell 5.1 - there's no
    #    -EnumsAsStrings switch before PowerShell 7. String-comparing the result
    #    to "Running" would always be False. Fixed by stringifying Status in the
    #    PS script itself, before it ever reaches ConvertTo-Json.
    # 2. pywinrm's run_ps can report a non-zero status_code even when the
    #    pipeline fully executed and produced valid stdout - `-ErrorAction
    #    SilentlyContinue` on service names that don't exist still leaves a
    #    non-terminating error record that appears to influence the exit code,
    #    with no actual error in the CLIXML stderr. Gating on returncode alone
    #    discarded real, valid data. Fixed by trusting successfully-parsed JSON
    #    stdout regardless of returncode, and only falling back to returncode
    #    for the empty/unparseable case.
    r = run_ps(
        session,
        "Get-Service NTDS,DNS,ADWS,W3SVC,MSSQLSERVER -ErrorAction SilentlyContinue | "
        "Select-Object Name,@{N='Status';E={$_.Status.ToString()}} | ConvertTo-Json -Compress",
    )
    raw = r.stdout.decode(errors="replace").strip()
    if not raw:
        if r.returncode != 0:
            return [CheckResult("roles", False, r.stderr.decode(errors="replace").strip() or "no output, non-zero exit")]
        return [CheckResult("roles", True, "no server roles detected (expected for Windows 11 / a bare server)")]
    try:
        services = json.loads(raw)
    except json.JSONDecodeError:
        return [CheckResult("roles", False, f"could not parse Get-Service output: {raw!r}")]
    if isinstance(services, dict):
        services = [services]
    present = {s["Name"]: s["Status"] for s in services}

    if not present:
        return [CheckResult("roles", True, "no server roles detected (expected for Windows 11 / a bare server)")]

    results: list[CheckResult] = []

    if "NTDS" in present:
        ad_ok = all(present.get(svc) == "Running" for svc in ("NTDS", "DNS", "ADWS") if svc in present)
        r2 = run_ps(session, "(Get-ADDomain).DNSRoot")
        domain_root = r2.stdout.decode(errors="replace").strip()
        results.append(
            CheckResult(
                "ad-ds",
                ad_ok and bool(domain_root),
                f"NTDS/DNS/ADWS={ {k: present.get(k) for k in ('NTDS', 'DNS', 'ADWS') if k in present} }, "
                f"Get-ADDomain.DNSRoot={domain_root!r}",
            )
        )

    if "W3SVC" in present:
        w3svc_ok = present.get("W3SVC") == "Running"
        r2 = run_ps(session, "(Invoke-WebRequest -Uri http://localhost -UseBasicParsing).StatusCode")
        status = r2.stdout.decode(errors="replace").strip()
        results.append(CheckResult("iis", w3svc_ok and status == "200", f"W3SVC={present.get('W3SVC')}, HTTP={status or 'no response'}"))

    if "MSSQLSERVER" in present:
        sql_ok = present.get("MSSQLSERVER") == "Running"
        # Matches scripts/install-sql-server.ps1's own distinct SA password (never the OS
        # Administrator password) - see CLAUDE.md's Server 2019 Phase E entry for why.
        r2 = run_ps(
            session,
            "$ErrorActionPreference='Stop'; "
            "Add-Type -AssemblyName 'System.Data'; "
            "$c = New-Object System.Data.SqlClient.SqlConnection("
            "\"Server=localhost;User Id=sa;Password=ChangeMe-Lab123!;TrustServerCertificate=True\"); "
            "$c.Open(); "
            "$cmd = $c.CreateCommand(); $cmd.CommandText = 'SELECT 1'; "
            "$cmd.ExecuteScalar(); $c.Close()",
        )
        select_result = r2.stdout.decode(errors="replace").strip()
        results.append(CheckResult("sql-server", sql_ok and select_result == "1", f"MSSQLSERVER={present.get('MSSQLSERVER')}, SELECT 1={select_result or 'failed'}"))

    return results


def _check_virtio(session) -> list[CheckResult]:
    r = run_ps(
        session,
        "$disk = (Get-Disk -Number 0).OperationalStatus; "
        "$nic = (Get-NetAdapter | Where-Object { $_.InterfaceDescription -like 'Red Hat VirtIO*' } | "
        "Select-Object -First 1).Status; "
        "$qxl = (Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like 'Red Hat QXL*' } | "
        "Select-Object -First 1).Status; "
        "$vd = (Get-Service vdservice -ErrorAction SilentlyContinue).Status; "
        "\"$disk|$nic|$qxl|$vd\"",
    )
    # Same class of bug fixed in _check_roles: Get-Service vdservice -ErrorAction
    # SilentlyContinue on a possibly-missing service can leave pywinrm reporting a
    # non-zero status_code with fully valid stdout - trust the parsed output, only
    # fall back to returncode/stderr when stdout is actually empty.
    raw = r.stdout.decode(errors="replace").strip()
    if not raw:
        return [CheckResult("virtio", False, r.stderr.decode(errors="replace").strip() or "no output")]
    parts = raw.split("|")
    disk, nic, qxl, vd = (parts + ["?"] * 4)[:4]
    return [
        CheckResult("disk_online", disk == "Online", f"Get-Disk -Number 0 -> {disk}"),
        CheckResult("nic_up", nic == "Up", f"VirtIO NIC -> {nic}"),
        CheckResult("qxl_ok", qxl == "OK", f"QXL display -> {qxl}"),
        CheckResult("vdservice_running", vd == "Running", f"vdservice -> {vd}"),
    ]


def _check_tools(session) -> list[CheckResult]:
    pattern_json = json.dumps(TOOL_DETECT_PATTERNS)
    r = run_ps(
        session,
        f"$patterns = '{pattern_json}' | ConvertFrom-Json; "
        "$result = @{}; "
        "foreach ($p in $patterns.PSObject.Properties) { "
        "  $match = Get-ItemProperty -Path "
        "    'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*', "
        "    'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' "
        "    -ErrorAction SilentlyContinue | "
        "    Where-Object { $_.DisplayName -and $_.DisplayName -match $p.Value } | "
        "    Select-Object -First 1; "
        "  $result[$p.Name] = if ($match) { $match.DisplayVersion } else { $null } "
        "}; "
        "$result | ConvertTo-Json -Compress",
    )
    if r.returncode != 0:
        return [CheckResult("tools", False, r.stderr.decode(errors="replace").strip())]
    try:
        versions = json.loads(r.stdout.decode(errors="replace").strip() or "{}")
    except json.JSONDecodeError:
        return [CheckResult("tools", False, "could not parse tool status output")]

    results = [
        CheckResult(name, versions.get(name) is not None, f"version {versions.get(name)}" if versions.get(name) else "not installed")
        for name in TOOL_DETECT_PATTERNS
    ]

    if versions.get("datadog-agent"):
        r2 = run_ps(
            session,
            "$svc = (Get-Service datadogagent -ErrorAction SilentlyContinue).Status; "
            "$statusExit = (Start-Process -FilePath 'C:\\Program Files\\Datadog\\Datadog Agent\\bin\\agent.exe' "
            "-ArgumentList 'status' -NoNewWindow -Wait -PassThru).ExitCode; "
            "\"$svc|$statusExit\"",
        )
        parts = r2.stdout.decode(errors="replace").strip().split("|")
        svc_status, status_exit = (parts + ["?", "?"])[:2]
        results.append(
            CheckResult(
                "datadog-agent-service",
                svc_status == "Running",
                f"service={svc_status}, 'agent status' exit={status_exit} "
                "(connectivity/host-registration not checked - needs a real DD_API_KEY, "
                "per CLAUDE.md's own noted gap)",
            )
        )

    return results


CHECK_FUNCS = {
    "connectivity": _check_connectivity,
    "roles": _check_roles,
    "virtio": _check_virtio,
    "tools": _check_tools,
}


def cmd_verify(args, ctx) -> int:
    host_id = args.host_id
    try:
        record = ctx.store.load(host_id)
    except KeyError:
        print(f"ERROR: no tracked VM with id '{host_id}'", file=sys.stderr)
        return 1

    if not domain_exists(host_id) or domain_state(host_id) != "running":
        print(
            f"ERROR: '{host_id}' is not a running libvirt domain - "
            f"run 'windows-pipeline start {host_id}' first",
            file=sys.stderr,
        )
        return 1

    groups = args.checks.split(",") if args.checks else ALL_GROUPS
    unknown = set(groups) - set(ALL_GROUPS)
    if unknown:
        print(f"ERROR: unknown check group(s): {sorted(unknown)} - valid: {ALL_GROUPS}", file=sys.stderr)
        return 1

    try:
        session = connect(host_id)
    except VMUnreachableError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    all_results: dict[str, list[CheckResult]] = {}
    for group in groups:
        all_results[group] = CHECK_FUNCS[group](session)

    overall_passed = all(r.passed for results in all_results.values() for r in results)

    if args.format == "json":
        print(json.dumps({g: [asdict(r) for r in rs] for g, rs in all_results.items()}, indent=2))
    else:
        for group, results in all_results.items():
            print(f"=== {group} ===")
            for r in results:
                mark = "PASS" if r.passed else "FAIL"
                print(f"  [{mark}] {r.name}: {r.detail}")
        print(f"\nOverall: {'PASS' if overall_passed else 'FAIL'}")

    record.last_verified_at = now_iso()
    record.last_verify_result = {
        "passed": overall_passed,
        "groups": {g: [asdict(r) for r in rs] for g, rs in all_results.items()},
    }
    ctx.store.save(record)

    return 0 if overall_passed else 1

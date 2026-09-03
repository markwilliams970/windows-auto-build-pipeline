# `../iso_cache/` Inventory

A point-in-time record of the shared binary-media cache this project (and its sibling,
`../windows-server-vm-automation/`) depend on — see `CLAUDE.md`'s "Relationship to
`../windows-server-vm-automation/`" section for why this cache lives one level above both repos'
git trees rather than inside either one. This file exists because the cache itself is **not**
git-tracked (it's binary install media, multi-GB each) — this is the durable, version-controlled
record of what was cached, when, and from where, in case the cache directory itself is ever lost,
moved, or needs reproducing on a fresh host.

**Snapshot date: 2026-09-02.** Regenerate rather than hand-edit when the cache changes — see
"How to regenerate" at the bottom.

## Contents

| File | Size | SHA-256 | Source | ETag / checked | Consuming script(s) |
|---|---|---|---|---|---|
| `2022-SERVER_EVAL_x64FRE_en-us.iso` | 5,044,094,976 B (~4.7 GiB) | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` | `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US` | `0xC5A0AE6FD398BA773151588CD215E1CFF7FD1C6109783EFA84680CA07C72E2EF`, checked 2026-07-22T14:08:40Z | `image-apply/lib/common.sh` (`os_win_iso server2022`) |
| `2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` | 8,152,356,864 B (~7.6 GiB) | `7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51` | `https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us` | `0x60A8C190FBB54AF58E40BA049FF290D098101E0EAD343CE912A1DC685219BE85`, checked 2026-07-22T17:19:11Z | `image-apply/lib/common.sh` (`os_win_iso server2025`) |
| `win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso` | 7,092,807,680 B (~6.6 GiB) | `a61adeab895ef5a4db436e0a7011c92a2ff17bb0357f58b13bbc4062e535e7b9` | `https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x809&culture=en-gb&country=gb` | `0x5D39BC26BFBF0F5A916E9A770FBFD27239D9551D22F50C172A973EB16FD2258F`, checked 2026-07-22T18:04:47Z | `image-apply/lib/common.sh` (`os_win_iso windows11`), `image-apply/build-iso-noprompt.sh` |
| `2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` | 5,652,088,832 B (~5.3 GiB) | `6dae072e7f78f4ccab74a45341de0d6e2d45c39be25f1f5920a2ab4f51d7bcbb` | `https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2019` (Standard edition, ISO) | **no ETag/fwlink** — this source is gated behind Microsoft's registration form (name/email/company), unlike every other row here; acquired manually by the user in a browser session 2026-09-02, not via a scriptable `curl`/fwlink. See `project_documentation/WINDOWS_SERVER_2019_RESEARCH_PLAN.md` Finding 3 for the full explanation and this project's own decision to accept manual acquisition rather than a non-Microsoft mirror. | not yet wired — `image-apply/lib/common.sh` has no `server2019` case yet (Phase D, not started); WIM edition index directly verified 2026-09-02 via `wimlib-imagex info` (index 2 = `ServerStandardEval`, Server Desktop Experience — matches the 2022/2025 convention) |
| `virtio-win-0.1.285.iso` | 789,645,312 B (~753 MiB) | `e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331` | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` | checked 2026-07-22T14:08:40Z (resolved name: `virtio-win-0.1.285.iso`) | `image-apply/lib/common.sh` (`VIRTIO_WIN_ISO`), `image-apply/make-bootable.sh`, `image-apply/inject-virtio-spice.sh` |
| `spice-guest-tools-latest.exe` | 10,136,459 B (~9.7 MiB) | `b5be0754802bcd7f7fe0ccdb877f8a6224ba13a2af7d84eb087a89b3b0237da2` | `https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe` | downloaded 2026-08-23T07:02:06-06:00 (no ETag-based freshness check yet — see "Known gap" below) | `image-apply/inject-virtio-spice.sh` |

**Total cache size: ~25 GiB** (`du -sh ../iso_cache/` → 25G, 2026-09-02, after adding the Server 2019
ISO).

**All six checksums independently re-verified against their `.sha256` sidecars** at the time this
file was written (`sha256sum` run directly against each cached file, not just read from the sidecar)
— confirmed byte-for-byte matching, not assumed. This is the same "verify before trusting" standard
`CLAUDE.md`'s Engineering Standards section calls for elsewhere in this project. (The Server 2019
ISO's checksum was computed fresh at cache time, 2026-09-02, rather than re-verified against a
pre-existing sidecar — there was no prior sidecar to check it against.)

## Re-download links, verified live 2026-08-23

Every source link below was checked with a real request (`curl -sL -o /dev/null -w '%{http_code}
%{url_effective}'`) on the date above, not just copied from the `.meta` sidecars — all five
resolved `HTTP 200`. The "resolves to" column is the *actual* final download URL after following
Microsoft's/the vendor's own redirect, useful for a direct `curl`/`wget` without needing a browser.
**The Server 2019 ISO is deliberately not in this table** — per the Contents table above, its
source is gated behind a human-facing registration form, not a scriptable fwlink, so there is no
`curl`-checkable re-download URL to record here. Re-acquiring it requires repeating the manual
registration step, not re-running a link check.

| File | Fetch this URL | Resolves to (checked 2026-08-23) |
|---|---|---|
| `2022-SERVER_EVAL_x64FRE_en-us.iso` | `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US` | `.../SERVER_EVAL_x64FRE_en-us.iso` (no build number in the filename itself — see caution below) |
| `2025-...SERVER_EVAL_x64FRE_en-us.iso` | `https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us` | `.../26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` — **same build number as what's cached**, confirmed matching |
| `win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso` | `https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x809&culture=en-gb&country=gb` | `.../26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso` — **see the caution immediately below, this is not confirmed to match what's cached** |
| `virtio-win-0.1.285.iso` | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` | `.../archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso` — **same version as what's cached**, confirmed matching |
| `spice-guest-tools-latest.exe` | `https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe` | same URL, no redirect (it's a permanent "latest" filename, not versioned — see "Known gap" below) |

**Real, live caution, not a hypothetical risk — the Windows 11 fwlink has already moved on.** The
cached `win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso` was downloaded 2026-07-22; today's re-check
of the same fwlink resolves to a build carrying `26200.6584.250915-1905.25h2` in its filename — a
25H2 servicing baseline. The cached file's own name doesn't preserve a build number, so this isn't
proof the two are byte-different, but the presence of `25h2` in today's resolution and the
one-month gap make it likely they are. **This is a concrete, dated instance of exactly the
"WIM image index" brittleness risk `CLAUDE.md`'s Engineering Standards section documents** — this
fwlink is Microsoft's own rolling "current eval build" pointer, not a pinned release, so it will
keep moving over time by design. **Do not treat "re-download via this link" as a drop-in
replacement for the currently-cached file without re-verifying the WIM edition index
(`os_wim_index` in `image-apply/lib/common.sh`) against whatever it actually downloads** — a newer
build could reorder or rename editions inside the WIM, exactly the failure mode already flagged as
unverified-by-default in `CLAUDE.md`.

## Known gap

`spice-guest-tools-latest.exe` was cached ad hoc during Phase 3A work
(`project_documentation/WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`) and doesn't yet follow this project's established
ETag-based freshness-check convention the way the four Microsoft/Red Hat sources above do — it was a
one-time download with a plain "downloaded" timestamp, not a versioned/pinned filename the way
`virtio-win-0.1.285.iso` is. Since the upstream filename is always `spice-guest-tools-latest.exe`
(a rolling "latest" pointer, not a versioned release), the existing per-OS-ISO convention
(version-keyed filename) doesn't map cleanly onto it as-is. Worth a real decision later (pin to a
specific release if spice-space.org offers one, or add an explicit re-check-on-a-schedule
convention for "latest"-style artifacts) — not resolved here, just flagged so it isn't mistaken for
an oversight nobody noticed.

## How to regenerate

```bash
cd ../iso_cache
ls -la
sha256sum *.iso *.exe   # cross-check against each file's own .sha256 sidecar
for f in *.meta; do echo "=== $f ==="; cat "$f"; done
du -sh .
```

Update the table above from that output, bump the snapshot date, and note anything that changed
(new file, removed file, a checksum that no longer matches its sidecar — that would itself be worth
investigating before assuming it's just a benign re-download).

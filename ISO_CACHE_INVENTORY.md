# `../iso_cache/` Inventory

A point-in-time record of the shared binary-media cache this project (and its sibling,
`../windows-server-vm-automation/`) depend on — see `CLAUDE.md`'s "Relationship to
`../windows-server-vm-automation/`" section for why this cache lives one level above both repos'
git trees rather than inside either one. This file exists because the cache itself is **not**
git-tracked (it's binary install media, multi-GB each) — this is the durable, version-controlled
record of what was cached, when, and from where, in case the cache directory itself is ever lost,
moved, or needs reproducing on a fresh host.

**Snapshot date: 2026-08-23.** Regenerate rather than hand-edit when the cache changes — see
"How to regenerate" at the bottom.

## Contents

| File | Size | SHA-256 | Source | ETag / checked | Consuming script(s) |
|---|---|---|---|---|---|
| `2022-SERVER_EVAL_x64FRE_en-us.iso` | 5,044,094,976 B (~4.7 GiB) | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` | `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US` | `0xC5A0AE6FD398BA773151588CD215E1CFF7FD1C6109783EFA84680CA07C72E2EF`, checked 2026-07-22T14:08:40Z | `image-apply/lib/common.sh` (`os_win_iso server2022`) |
| `2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` | 8,152,356,864 B (~7.6 GiB) | `7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51` | `https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us` | `0x60A8C190FBB54AF58E40BA049FF290D098101E0EAD343CE912A1DC685219BE85`, checked 2026-07-22T17:19:11Z | `image-apply/lib/common.sh` (`os_win_iso server2025`) |
| `win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso` | 7,092,807,680 B (~6.6 GiB) | `a61adeab895ef5a4db436e0a7011c92a2ff17bb0357f58b13bbc4062e535e7b9` | `https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x809&culture=en-gb&country=gb` | `0x5D39BC26BFBF0F5A916E9A770FBFD27239D9551D22F50C172A973EB16FD2258F`, checked 2026-07-22T18:04:47Z | `image-apply/lib/common.sh` (`os_win_iso windows11`), `image-apply/build-iso-noprompt.sh` |
| `virtio-win-0.1.285.iso` | 789,645,312 B (~753 MiB) | `e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331` | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` | checked 2026-07-22T14:08:40Z (resolved name: `virtio-win-0.1.285.iso`) | `image-apply/lib/common.sh` (`VIRTIO_WIN_ISO`), `image-apply/make-bootable.sh`, `image-apply/inject-virtio-spice.sh` |
| `spice-guest-tools-latest.exe` | 10,136,459 B (~9.7 MiB) | `b5be0754802bcd7f7fe0ccdb877f8a6224ba13a2af7d84eb087a89b3b0237da2` | `https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe` | downloaded 2026-08-23T07:02:06-06:00 (no ETag-based freshness check yet — see "Known gap" below) | `image-apply/inject-virtio-spice.sh` |

**Total cache size: ~20 GiB** (`du -sh ../iso_cache/` → 20G, 2026-08-23).

**All five checksums independently re-verified against their `.sha256` sidecars** at the time this
file was written (`sha256sum` run directly against each cached file, not just read from the sidecar)
— confirmed byte-for-byte matching, not assumed. This is the same "verify before trusting" standard
`CLAUDE.md`'s Engineering Standards section calls for elsewhere in this project.

## Known gap

`spice-guest-tools-latest.exe` was cached ad hoc during Phase 3A work
(`WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`) and doesn't yet follow this project's established
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

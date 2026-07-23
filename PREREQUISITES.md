# Prerequisites

Non-standard host tooling this project needs beyond what the sibling project
(`../windows-server-vm-automation/`) already required. If you've set that project up on this host,
everything in "Already present via the sibling project" below should already be installed — only
the "New for this project" table needs anything done.

All package names below were verified against this host's actual `dpkg`/`apt` state (Ubuntu Noble),
not assumed from memory — see `CLAUDE.md`'s "verify before trusting" standard.

---

## New for this project

| Tool(s) provided | apt package | Used for |
|---|---|---|
| `sgdisk` | `gdisk` | GPT partitioning of the target disk image, directly from the host, no boot required |
| `mkfs.ntfs` / `mkntfs` | `ntfs-3g` | Formatting the primary partition; `ntfs-3g` itself (FUSE driver) also provides the mount capability used to write into it afterward |
| `wimlib-imagex` | `wimtools` | `wimapply` — applying the Windows image (`.wim`) to the formatted NTFS partition, offline |
| `hivexsh`, `hivexget`, `hivexml` | `libhivex-bin` | Reading/writing Windows registry hives offline (BCD store construction, driver-injection registry edits) |
| `hivexregedit` | `libwin-hivex-perl` | **Not included in `libhivex-bin`** — this is a separate Perl-bindings package. `hivexregedit` specifically is what BCD-SYS (see below) uses to apply `.reg`-style edits to an offline hive. Easy to miss: installing only `libhivex-bin` leaves `hivexregedit` still missing. |

Install both in one shot:

```
sudo apt-get install -y gdisk ntfs-3g wimtools libhivex-bin libwin-hivex-perl
```

(`sudo` here needs an interactive terminal/password — if running through an agent session without
one, this is a command to hand to a human to run directly, not something to retry non-interactively.)

### `nbd` kernel module — not a package, a runtime `modprobe`

`qemu-nbd` (below) needs the `nbd` kernel module loaded to expose a qcow2 file as a `/dev/nbdN`
block device. It's built into the stock kernel package on this host (confirmed via `modinfo nbd`)
but isn't loaded by default:

```
sudo modprobe nbd max_part=8
```

`max_part=8` (or similar) matters — without it, the kernel won't enumerate `/dev/nbd0p1`,
`/dev/nbd0p2`, etc. for the partitions inside the attached image, only the whole-disk device.

### BCD-SYS — not a package at all, a vendored git clone

[`jpz4085/BCD-SYS`](https://github.com/jpz4085/BCD-SYS) (GPL-3.0) is the tool this project uses to
build the Windows BCD store and boot files directly from Linux — see
`PHASE2_BOOTSTRAP_ARCHITECTURE.md`. It isn't packaged for any distro; clone it directly:

```
git clone https://github.com/jpz4085/BCD-SYS.git tools/vendor/BCD-SYS
```

Depends on the `hivexsh`/`hivexregedit`/`setfattr`/`fatattr` family above, plus `qemu-utils` (next
section) for its VHDX-specific code path (not needed for this project's plain-partition use case).
`fatattr` isn't installed yet — check for it separately if BCD-SYS's own preflight complains; not
confirmed necessary for our specific invocation as of this writing.

---

## Already present via the sibling project (verified on this host, not re-installed)

| Tool(s) | apt package | Notes |
|---|---|---|
| `qemu-nbd` | `qemu-utils` | Already required by the sibling project's forensic-mounting use case |
| `qemu-system-x86_64` | `qemu-system-x86` | Core virtualization |
| `virsh` | `libvirt-clients` | |
| `virt-install` | `virtinst` | |
| `parted` | `parted` | Sibling project already depends on this; `sgdisk` (above) is this project's addition for cleaner scripted GPT layouts |
| `python3` | (base install) | Used as-is (stdlib only) by `tools/qmp-screenshot.py` — no extra packages needed |

---

## Quick verification

```bash
for c in sgdisk mkfs.ntfs wimlib-imagex hivexsh hivexregedit qemu-nbd qemu-system-x86_64 virsh virt-install; do
  command -v "$c" >/dev/null 2>&1 && echo "$c: OK" || echo "$c: MISSING"
done
lsmod | grep -q '^nbd' && echo "nbd module: loaded" || echo "nbd module: not loaded (modprobe nbd max_part=8)"
test -x tools/vendor/BCD-SYS/Linux/bcd-sys.sh && echo "BCD-SYS: present" || echo "BCD-SYS: not cloned yet"
```

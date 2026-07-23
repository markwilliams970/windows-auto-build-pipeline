This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION."** This is the actual current state of the investigation: what's solved,
   what's not, what was tried and failed (with root causes where we found them), and the specific
   next action already agreed on. Don't skip this to save time — it exists precisely so nothing in
   it has to be re-derived, and re-deriving it burned a full session already.
2. `CLAUDE.md` — project goals, architectural principles (no golden image, ever — the eval-media
   expiration reasoning is a hard constraint), tool responsibilities, and the phased development
   plan. Its Phase 2 status line and the "Do not reuse" note under "Relationship to
   `../windows-server-vm-automation/`" both have update markers pointing back at the engineering
   log — read those two spots specifically even if skimming the rest.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — the design reasoning that led to trying BCD-SYS first. Now
   labeled historical context (it has its own update marker at the top) — BCD-SYS's core claim
   (avoids WinPE entirely) was confirmed true for bootability specifically, but driver injection
   needed WinPE anyway, which changes the calculus. Read for the reasoning, not as current
   direction.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand

**Solved:** making an offline-applied Windows Server 2025 disk boot at all, via UEFI/OVMF, with
zero exposure to the sibling project's "press any key" landmine — confirmed **twice**, by two
independent mechanisms (BCD-SYS, and separately real `bcdboot` run from a self-built WinPE
session). Either works. This was the project's single biggest open risk at the start and it's
retired.

**Not solved:** clearing `INACCESSIBLE_BOOT_DEVICE (0x7B)` — the boot-critical VirtIO storage
driver isn't recognized yet. Three attempts failed:
- Two offline `hivex`/`hivexregedit` registry-injection attempts (CriticalDeviceDatabase, then
  CriticalDeviceDatabase+DriverDatabase together), both following `virt-v2v`'s own production
  recipe byte-for-byte, both producing byte-identical `0x7B` failures. Root cause never determined
  — there's no boot-time equivalent of a log file for this one.
- One `DISM /Add-Driver` (and even plain `/Get-Drivers`) attempt run from a working, self-built
  WinPE session. This one **was** precisely root-caused via the real `dism.log`: DISM's
  out-of-process `dismhost.exe` COM-hosting mechanism fails to activate (`0x80004002`,
  `DismCreateObjectInHostFromCLSID`) when servicing an *applied* (not mounted-WIM) offline image
  from this specific WinPE environment. Not a driver-content problem — ruled out hardware ID
  mismatch, missing embedded signature, and missing DISM provider DLLs, all with direct evidence,
  not assumption.

**The live lead, not yet attempted:** this project exists because the sibling project's
*interactive Setup.exe*, booted from `media=cdrom`, hits the UEFI landmine on Server 2025/Windows
11 media. This session proved that landmine is specific to **CD-ROM boot**, not to Setup.exe
itself — a self-built WinPE-style boot medium attached as a **plain disk** boots cleanly, no
landmine, confirmed directly. That fix applies equally to `boot.wim` **index 2** ("Microsoft
Windows Setup"), not just index 1 (plain WinPE, which is what was actually tested). If so, the
right move is very likely: **stop hand-rolling driver injection, and let Setup.exe do it via the
sibling project's own already-validated-for-Server-2022 `autounattend.xml`/`DriverPaths`
mechanism**, invoked explicitly (`setup.exe /unattend:<path>`) from our own scripted WinPE session
rather than relying on Setup's removable-media autodetection. Full detail, including the specific
untested assumptions this rests on, is in the engineering log's Finding 15.

---

## What to do first this session

1. Confirm you've read the engineering log's resumption section, then **decide with me** whether
   to pursue the Setup.exe pivot now, or the fallback (kernel debugging via `ntoseye`, already
   installed at `~/.local/bin/ntoseye`, to get a definitive `analyze`/`drivers` diagnosis of the
   `0x7B` — that thread was left mid-setup, with `bcdedit`'s debug flags possibly not actually
   applied yet; see the log for the specific loose end, likely a missing `drvload` call in the
   script that set them up).
2. If pursuing the Setup.exe pivot: rebuild the WinPE-style boot medium using `boot.wim` **index
   2** instead of index 1 (same recipe as before: `wimapply` to a real NTFS partition, BCD-SYS,
   then patch in the three WinPE-mode BCD boolean elements — `26000010`, `26000022`, `260000b0`,
   all documented with exact byte values in Finding 11), pull the sibling project's
   `autounattend.xml` template (`../windows-server-vm-automation/packer/answer_files/autounattend.xml.pkrtpl`)
   and adapt it for explicit invocation, and test end to end. Watch it via
   `tools/qmp-screenshot.py`/`tools/qmp-watch.sh`, not a VNC viewer.
3. Either way: **check what's ephemeral before assuming it's still there.** Everything under
   `/tmp/` from the last session (extracted `efi/`/`boot.wim`, viostor/NetKVM driver files, the
   `libpython3.10` workaround for `ntoseye`) is gone. Everything under this project's own
   `image-apply/output/` persisted (`win2025-test.qcow2`, `winpe-boot.qcow2`, and a pile of
   throwaway `OVMF_VARS_*.fd` copies worth cleaning up whenever convenient — harmless clutter, not
   urgent).

---

## Process reminders (still not optional)

- **Research first — search for existing tooling or a documented mechanism before building
  anything new.** See `CLAUDE.md`'s "Research-first discipline" section. This is exactly how
  BCD-SYS, the `virt-v2v` driver-injection pattern, and `ntoseye` were all found instead of
  reinvented — and exactly the discipline that turned "no such interface supported" from a dead
  end into a precisely understood architectural fact via the real `dism.log`.
- **Verify before trusting.** Don't assume a BCD element ID, a hardware ID, or a mechanism's
  behavior — decode a real reference, extract directly, or test it, the way every finding in the
  engineering log actually got confirmed.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go — including dead ends.** Two of this
  project's three driver-injection attempts failed; both are recorded in as much detail as the one
  that got root-caused, because "we tried X, it didn't work, here's why we think" is exactly as
  valuable as a clean success for not re-treading the same ground.
- **Phase gating still applies**: no Phase 3 (service-layer/role-provisioning) work starts until
  Server 2025, Server 2022, *and* Windows 11 have each independently bootstrapped through Phase 2.
  Server 2025 is still the only one attempted so far.

---

## Still-open question from the very first session — never resolved, still pending

This directory still isn't a git repository. Every finding in the engineering log, every script in
`tools/`, and both multi-GB disk images under `image-apply/output/` currently exist with no version
history and no rollback safety. Ask before initializing one (and whether as its own repo or
something else) — don't assume either way, same as originally asked.

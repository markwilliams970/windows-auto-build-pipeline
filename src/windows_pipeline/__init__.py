"""windows-pipeline: unified CLI for the windows-auto-build-pipeline lifecycle.

Phase 5 (CLAUDE.md) consolidates what used to be separate entry points
(build.sh, register-vm.sh, and the not-yet-built verify/destroy workflows)
into one installable tool with real state tracking, so a VM's host-side
identity (unique, generated at `create` time) and its guest-side NetBIOS
ComputerName (fixed per OS, decoupled from the host identity) are never
conflated.

This package is an orchestration layer only. The actual heavy lifting
(partitioning, wimlib apply, bcdboot, Packer, driver injection, tool
install) stays exactly where it already was and was already proven -
image-apply/*.sh, packer/boot-and-provision.pkr.hcl - invoked as
subprocesses, not reimplemented in Python.
"""

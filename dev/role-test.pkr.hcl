# Phase 3 fast-iteration harness - NOT the production build pipeline (that
# still needs image-apply/'s real scripts formalized, per
# PHASE2_ENGINEERING_LOG.md's Session 13 next-steps - a separate, not-yet-made
# decision). This boots a disposable copy-on-write overlay on top of one of
# Phase 2's own confirmed-good, WinRM-reachable reference disks
# (image-apply/output/win2022-session12.qcow2 / win2025-session11.qcow2) so
# role-script iteration never has to repeat Phase 2's ~20 minute offline-apply
# + bootstrap sequence, and never risks the one known-good disk per OS. Same
# use_backing_file pattern as ../../windows-server-vm-automation/dev/role-test.pkr.hcl
# (see CLAUDE.md's "reuse the pattern, not necessarily the exact files" note),
# pointed at this project's own artifacts instead of a separately-maintained
# dev/baseline/ copy - both reference disks already live in image-apply/output/
# and are already gitignored there.
packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "target_os" {
  type        = string
  description = "Which Phase 2 reference disk to test against."
  validation {
    condition     = contains(["server2022", "server2025"], var.target_os)
    error_message = "The target_os variable must be \"server2022\" or \"server2025\" - Windows 11 gets none of Phase 3's roles, see CLAUDE.md."
  }
}

# Always passed as an absolute path by run-phase3-test.sh.
variable "services_yaml_path" {
  type        = string
  default     = ""
  description = "Absolute path to the services.yaml to test. Always set by run-phase3-test.sh - do not rely on this default."
}

variable "domain_name" {
  type    = string
  default = "corp.example.internal"
}

# Matches image-apply/unattend-server2022.xml / unattend-server2025.xml's
# AdministratorPassword - NOT the sibling project's "ChangeMe-Lab123!"
# convention, since these two disks' local Administrator password was
# already set differently by Phase 2's own unattend.xml. Same disposable-lab
# placeholder standard either way - not treated as a real secret.
variable "admin_password" {
  type      = string
  default   = "TestP@ssw0rd123"
  sensitive = true
}

variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

# Copied fresh per run by run-phase3-test.sh (one per target_os, so two
# concurrent/sequential runs against different OSes never collide).
variable "efivars_scratch" {
  type    = string
  default = ""
}

variable "headless" {
  type    = bool
  default = true
}

# Per-OS baseline disk + its known-good checksum (computed directly from the
# actual files in image-apply/output/, not assumed) - keeps this one file
# working for both target OSes instead of needing a near-duplicate per OS,
# per Session 12/13's own finding that the underlying tooling is already
# OS-agnostic.
locals {
  os_config = {
    server2022 = {
      qcow2    = "${path.root}/../image-apply/output/win2022-session12.qcow2"
      checksum = "sha256:f3556c6e22ea0f1ea7e56fe71c69cecb21a0a2b6a2bd9eac2e54910fee79e3ae"
    }
    server2025 = {
      qcow2    = "${path.root}/../image-apply/output/win2025-session11.qcow2"
      checksum = "sha256:4f451da300b8f2cddf2ce3966c418a37d680595404827a4ab668e074c4d0c5f8"
    }
  }
  baseline_qcow2    = local.os_config[var.target_os].qcow2
  baseline_checksum = local.os_config[var.target_os].checksum
}

source "qemu" "role_test" {
  vm_name          = "phase3-${var.target_os}.qcow2"
  output_directory = "${path.root}/output/vm-${var.target_os}"

  disk_image       = true
  use_backing_file = true
  iso_url          = "file://${local.baseline_qcow2}"
  iso_checksum     = local.baseline_checksum

  headless = var.headless

  cpus   = 4
  # Matches the sibling project's own bumped default (was 8192, raised after
  # a combined-role test failed at the sql-server step) - avoid re-discovering
  # that same resource-pressure lesson here.
  memory = 16384

  accelerator  = "kvm"
  machine_type = "q35"
  # Root cause of a real observed failure, not a defensive default: this
  # plugin's cpu_model defaults to nothing at all, which leaves QEMU on its
  # generic x86_64 "qemu64" baseline CPU under KVM instead of the host's real
  # CPU. Confirmed via PACKER_LOG=1 that Packer's own generated
  # qemu-system-x86_64 invocation never passed -cpu - and confirmed via a
  # side-by-side ad hoc qemu-system-x86_64 + QMP screendump repro of that
  # exact command line that adding -cpu host alone took a server2025 boot
  # that had twice failed to bring up WinRM within 15 minutes down to
  # WinRM answering correctly in under 2 minutes. HashiCorp's own docs
  # recommend "host" under a hypervisor for exactly this reason.
  cpu_model = "host"

  # Deliberately "virtio" (-> virtio-blk-pci), NOT "virtio-scsi" like the
  # sibling project's dev harness uses. This project's offline viostor driver
  # injection (tools/gen-viostor-ddb-reg.py) was registered against a real
  # virtio-blk-pci hardware ID (VEN_1AF4&DEV_1001, confirmed via QMP
  # query-pci - see PHASE2_ENGINEERING_LOG.md Finding 12/around line 692) and
  # every boot in the engineering log attached the target disk as
  # virtio-blk-pci specifically. virtio-scsi presents a different device
  # entirely and would reintroduce INACCESSIBLE_BOOT_DEVICE.
  disk_interface = "virtio"
  net_device     = "virtio-net"
  format         = "qcow2"

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efivars_scratch

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  # Bumped from 10m after a real observed timeout against server2025 that
  # turned out to be a false alarm - a diagnostic ad hoc qemu-system-x86_64 +
  # QMP screendump boot of the same disk immediately after confirmed WinRM
  # was actually up and answering correctly; the Packer run just started
  # right after an 18-minute SQL Server build finished, likely genuine host
  # resource contention, not a broken disk. See CLAUDE.md's QMP screendump
  # convention for how this was diagnosed.
  winrm_timeout  = "15m"
  winrm_insecure = true
  winrm_use_ssl  = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "10m"
}

build {
  name    = "phase3-role-test"
  sources = ["source.qemu.role_test"]

  provisioner "file" {
    source      = var.services_yaml_path
    destination = "C:/Windows/Temp/services.yaml"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "C:/Windows/Temp/scripts"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\run-services.ps1 -DomainName '${var.domain_name}'"]
  }

  # Unconditional, same as the sibling project's dev harness: Packer can't
  # conditionally include a provisioner based on a runtime variable (only
  # ad-ds actually needs this reboot). Cheap no-op otherwise.
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # No-ops unless install-ad.ps1's marker file is present.
  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\verify-post-reboot.ps1"]
  }
}

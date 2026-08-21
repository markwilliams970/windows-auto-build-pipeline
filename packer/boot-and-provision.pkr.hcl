# Production build step 7-8: boots the disk image-apply/*.sh just built (offline
# partitioned/applied/made-bootable/specialized - no ISO, no boot_command, no interactive
# install of any kind) and hands off to the reused role-provisioning layer over WinRM.
#
# This is the production counterpart to dev/role-test.pkr.hcl - that harness boots a
# disposable copy-on-write overlay on top of a protected reference disk for fast
# iteration; this one boots the actual just-built disk directly (no backing file - every
# real build applies the WIM fresh, per CLAUDE.md's "Ephemeral Infrastructure, Still"
# principle), so there is no reference disk to protect here.
#
# cpu_model = "host" is set from the start - PHASE3_ENGINEERING_LOG.md Finding 1 found
# that omitting it (the qemu builder's own default) leaves QEMU on a generic, feature-
# minimal CPU model that Windows Server 2025 could not reliably bring WinRM up under
# within any reasonable timeout, even though Server 2022 tolerated it. Carrying this
# forward from the start avoids re-discovering that failure here.
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
  description = "Which OS this build is for - informational/for output naming only; the disk itself is already fully built by image-apply/*.sh by the time this runs."
  validation {
    condition     = contains(["server2022", "server2025", "windows11"], var.target_os)
    error_message = "The target_os variable must be \"server2022\", \"server2025\", or \"windows11\"."
  }
}

variable "source_qcow2" {
  type        = string
  description = "Absolute path to the disk apply-unattend.sh just finished (partitioned, wimapply'd, bootable, specialized). Always set by build.sh."
}

variable "services_yaml_path" {
  type        = string
  default     = ""
  description = "Absolute path to the services.yaml to apply. Empty means a bare build with no roles - valid and expected for windows11, which gets none of Phase 3's roles."
}

variable "domain_name" {
  type    = string
  default = "corp.example.internal"
}

# Matches image-apply/unattend-*.xml's own AdministratorPassword - same disposable-lab
# placeholder standard as the rest of this project, not treated as a real secret.
variable "admin_password" {
  type      = string
  default   = "TestP@ssw0rd123"
  sensitive = true
}

variable "disk_size_mb" {
  type        = number
  description = "Must match the size partition-disk.sh actually created (image-apply/lib/common.sh's os_disk_size_gb, in MB). Always set by build.sh."
}

variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

variable "headless" {
  type    = bool
  default = true
}

source "qemu" "boot_and_provision" {
  vm_name          = "${var.target_os}.qcow2"
  output_directory = "${path.root}/output/${var.target_os}"

  disk_image = true
  iso_url    = "file://${var.source_qcow2}"
  # The qemu builder requires a checksum even for a local disk_image source; "none" is
  # its own documented escape hatch for exactly this case - the source disk is this
  # build's own just-built, single-use artifact, not something with a stable checksum to
  # pin the way image-apply/*.sh's dev-harness reference disks are.
  iso_checksum = "none"

  headless = var.headless

  cpus      = 4
  memory    = 16384
  disk_size = var.disk_size_mb

  accelerator  = "kvm"
  machine_type = "q35"
  cpu_model    = "host"

  # Matches image-apply/make-bootable.sh's virtio-blk-pci target-disk attachment and the
  # offline-injected viostor DriverDatabase registration - see dev/role-test.pkr.hcl's
  # own comment for why "virtio-scsi" would break this.
  disk_interface = "virtio"
  net_device     = "virtio-net"
  format         = "qcow2"

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = "${path.root}/output/${var.target_os}-efivars.fd"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = "15m"
  winrm_insecure = true
  winrm_use_ssl  = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "10m"
}

build {
  name    = "boot-and-provision"
  sources = ["source.qemu.boot_and_provision"]

  provisioner "file" {
    source      = var.services_yaml_path != "" ? var.services_yaml_path : "${path.root}/../services.yaml"
    destination = "C:/Windows/Temp/services.yaml"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "C:/Windows/Temp/scripts"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\run-services.ps1 -DomainName '${var.domain_name}'"]
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\verify-post-reboot.ps1"]
  }
}

# The vSphere image build.
#
# Every input is a variable with no default. A build that falls back to a
# built-in value when a caller forgets one is not deterministic, and the value it
# falls back to is usually someone else's environment.
#
# This configuration is validated in CI and has never been executed. `packer
# validate` resolves references and checks the configuration; it says nothing
# about vCenter connectivity, media reachability, boot behaviour, or whether the
# build converts to a template.

packer {
  # Pinned. A plugin that moves under a running configuration changes what is
  # built without changing anything in this repository.
  required_version = "1.15.4"

  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "= 1.4.2"
    }
  }
}

# ---------------------------------------------------------------------------
# Platform. Environment-specific, and deliberately absent from recipeDigest:
# two sites building one recipe must reach the same identity.
# ---------------------------------------------------------------------------

variable "vcenter_server" {
  type        = string
  description = "vCenter to build against."
}

variable "vcenter_username" {
  type        = string
  description = "Account used to create and seal the build VM."
}

variable "vcenter_password" {
  type        = string
  sensitive   = true
  description = "Injected at runtime. Never committed, never logged."
}

variable "vcenter_insecure_connection" {
  type        = bool
  description = "Stated explicitly rather than defaulted, so accepting an unverified certificate is always a decision someone made."
}

variable "datacenter" {
  type        = string
  description = "Datacenter the build VM is created in."
}

variable "cluster" {
  type        = string
  description = "Cluster the build VM runs on."
}

variable "datastore" {
  type        = string
  description = "Datastore backing the build VM."
}

variable "network" {
  type        = string
  description = "Port group the build VM attaches to."
}

variable "folder" {
  type        = string
  description = "Folder the build VM and the sealed artifact are placed in."
}

# ---------------------------------------------------------------------------
# Identity of this run and this candidate.
# ---------------------------------------------------------------------------

variable "run_id" {
  type        = string
  description = "Canonical UUID correlating this build's evidence."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.run_id))
    error_message = "The run_id must be a lowercase canonical UUID."
  }
}

variable "candidate_name" {
  type        = string
  description = "Name recorded against the artifact. Display metadata only; identity is the vCenter instance, the managed object reference, and the instance UUID."
}

# ---------------------------------------------------------------------------
# Inputs the build consumes. media_path is the path Assert-QualifiedMedia
# returned, which is media whose digest was recomputed at this boundary.
# ---------------------------------------------------------------------------

variable "media_path" {
  type        = string
  description = "Datastore path to media already re-verified at the build's input boundary."
}

variable "answer_file_path" {
  type        = string
  description = "The rendered answer file. It holds a working credential for as long as it exists and is removed by the renderer on every exit path."
}

variable "tools_source_dir" {
  type        = string
  description = "Guest-side modules uploaded to the build VM."
}

variable "guest_scripts_dir" {
  type        = string
  description = "Guest phase entry scripts."
}

variable "contracts_source_dir" {
  type        = string
  description = "Contracts uploaded so the guest can validate its own evidence."
}

variable "evidence_output_dir" {
  type        = string
  description = "Where retrieved guest evidence is written on the host."
}

# ---------------------------------------------------------------------------
# Virtual hardware. These are recipe inputs: firmware, secure boot, and a vTPM
# change what installs and what the installed system can require.
# ---------------------------------------------------------------------------

variable "hardware_version" {
  type        = number
  description = "Virtual hardware version."
}

variable "firmware" {
  type        = string
  description = "efi or efi-secure. BIOS is not offered: a Windows desktop image built without UEFI cannot later require secure boot."

  validation {
    condition     = contains(["efi", "efi-secure"], var.firmware)
    error_message = "The firmware must be efi or efi-secure."
  }
}

variable "virtual_tpm" {
  type        = bool
  description = "Whether the build VM carries a virtual TPM."
}

variable "disk_controller_type" {
  type        = string
  description = "Disk controller. pvscsi unless something requires otherwise."
}

variable "disk_size_gb" {
  type        = number
  description = "System disk size."

  validation {
    condition     = var.disk_size_gb >= 40
    error_message = "The disk_size_gb must be at least 40, because Windows plus servicing does not fit in less."
  }
}

variable "cpus" {
  type        = number
  description = "Virtual CPUs for the build."
}

variable "memory_mb" {
  type        = number
  description = "Memory for the build."
}

# ---------------------------------------------------------------------------
# Guest access during construction.
# ---------------------------------------------------------------------------

variable "build_username" {
  type        = string
  description = "Account the answer file creates, used to provision. Disabled or rotated before sealing."
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Injected at runtime. Matches the value rendered into the answer file."
}

locals {
  guest_root       = "C:/vdi-iac-build"
  tools_target     = "${local.guest_root}/tools"
  guest_target     = "${local.guest_root}/guest"
  contracts_target = "${local.guest_root}/contracts"
  evidence_name    = "guest-evidence.json"
}

source "vsphere-iso" "windows" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection

  datacenter = var.datacenter
  cluster    = var.cluster
  datastore  = var.datastore
  folder     = var.folder

  vm_name       = var.candidate_name
  guest_os_type = "windows9Server64Guest"

  # Hardware, stated rather than inherited from a template.
  vm_version           = var.hardware_version
  firmware             = var.firmware
  vTPM                 = var.virtual_tpm
  CPUs                 = var.cpus
  RAM                  = var.memory_mb
  disk_controller_type = [var.disk_controller_type]

  storage {
    disk_size             = var.disk_size_gb * 1024
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.network
    network_card = "vmxnet3"
  }

  # The media this build was authorised to use, and the answer file that drives
  # it. The answer file travels as removable media rather than being typed at
  # the boot prompt, so the credential never appears in a boot command.
  iso_paths = [var.media_path]

  cd_files = [var.answer_file_path]
  cd_label = "OEMDRV"

  # WinRM rather than SSH: the guest is Windows, and provisioning runs
  # PowerShell. The password is the one rendered into the answer file.
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_timeout  = "4h"

  # Packer owns the shutdown, exactly as it owns the restart boundary. A guest
  # script that shut itself down would race the sealing step.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"packer build shutdown\""
  shutdown_timeout = "30m"

  # Sealing. The artifact is converted to a template, which is what makes it
  # immutable: a template cannot be powered on and modified in place.
  convert_to_template = true
}

build {
  name    = "windows-candidate"
  sources = ["source.vsphere-iso.windows"]

  # 1. Deliver the guest-side code and the contracts it validates against.
  provisioner "file" {
    source      = "${var.tools_source_dir}/"
    destination = "${local.tools_target}/"
  }

  provisioner "file" {
    source      = "${var.guest_scripts_dir}/"
    destination = "${local.guest_target}/"
  }

  provisioner "file" {
    source      = "${var.contracts_source_dir}/"
    destination = "${local.contracts_target}/"
  }

  # 2. Pre-generalization checks, before anything is removed. Running them after
  #    generalization would check a machine that no longer exists.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Import-Module '${local.tools_target}/AnswerFile.psm1' -Force",
      "$residue = Get-SetupResidue -SystemDrive 'C:/'",
      "Write-Host \"pre-generalization: setup residue copies found: $($residue.Count)\""
    ]
  }

  # 3. Remove the answer-file copies setup left behind. Each retains the
  #    administrator password in plain text, so this happens before the image is
  #    generalized and long before it is sealed.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Import-Module '${local.tools_target}/AnswerFile.psm1' -Force",
      "$outcome = Remove-SetupResidue -SystemDrive 'C:/'",
      "if (-not $outcome.Clean) { throw \"Answer-file residue remains: $($outcome.Remaining -join ', ')\" }",
      "Write-Host 'credential-residue: clear'"
    ]
  }

  # 4. Retrieve evidence before anything destructive. A failing provisioner
  #    stops the ones after it, so evidence collected later may never be.
  provisioner "file" {
    direction   = "download"
    source      = "${local.guest_root}/${local.evidence_name}"
    destination = "${var.evidence_output_dir}/${local.evidence_name}"
  }

  # 5. Generalize. After this the guest has no machine identity, so nothing that
  #    needs one may run afterwards.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Write-Host 'generalization: running sysprep'",
      "& \"$env:SystemRoot/System32/Sysprep/Sysprep.exe\" /generalize /oobe /quiet /quit",
      "Write-Host 'generalization: complete'"
    ]
  }
}

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
# Inputs the build consumes. media_url is the path Assert-QualifiedMedia
# returned -- media whose digest was recomputed at this boundary -- and Packer
# verifies the same file again against media_checksum before uploading it.
#
# The guest-side directories an earlier draft declared are gone: nothing in this
# configuration provisions a guest yet, and an input nothing consumes is
# scaffolding for a stage that has not been written.
# ---------------------------------------------------------------------------

variable "media_url" {
  type        = string
  description = "Path or URL to the media whose digest was recomputed at the build's input boundary. Packer verifies it again against media_checksum before uploading, so the bytes this build consumes are the bytes that were verified."
}

variable "media_checksum" {
  type        = string
  description = "The expected digest, algorithm-prefixed, from the qualification record. Established in version control before runtime, never computed from the artifact at build time."

  validation {
    condition     = can(regex("^sha(256|384|512):[0-9a-f]+$", var.media_checksum))
    error_message = "The media_checksum must be algorithm-prefixed lowercase hex, for example sha256:abcd."
  }
}

variable "winrm_bootstrap_path" {
  type        = string
  description = "The script the answer file's first-logon command runs to create the WinRM listener. Carries no credential."
}

variable "answer_file_path" {
  type        = string
  description = "The rendered answer file. It holds a working credential for as long as it exists and is removed by the renderer on every exit path."
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
  description = "Virtual CPUs. A recipe input: it is covered by recipeDigest, because installer behaviour and the resulting configuration can differ with it."
}

variable "memory_mb" {
  type        = number
  description = "Memory. A recipe input for the same reason as cpus, and because page file sizing follows from it."
}

variable "guest_os_type" {
  type        = string
  description = "The vSphere guest OS identifier. A recipe input: it changes the device model vSphere presents to setup. Restricted to Windows desktop identifiers, since the artifact is a desktop image."

  validation {
    condition     = contains(["windows9_64Guest", "windows11_64Guest"], var.guest_os_type)
    error_message = "The guest_os_type must be a Windows desktop identifier: windows9_64Guest or windows11_64Guest."
  }
}

# ---------------------------------------------------------------------------
# Guest access during construction.
# ---------------------------------------------------------------------------

variable "build_username" {
  type        = string
  description = "Account the answer file configures, supplied by ConvertTo-BuildVariableSet from the answer-file declaration so the two cannot disagree. Disabled or rotated before sealing, which is stage 5 work."
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Injected at runtime. Matches the value rendered into the answer file."
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

  vm_name = var.candidate_name

  # Parameterised, not hard-coded. It was windows9Server64Guest -- a Windows
  # Server identifier -- while the artifact this repository builds is a desktop
  # image. Which desktop identifier is correct for a given media release needs
  # lab confirmation; both permitted values are desktop ones.
  guest_os_type = var.guest_os_type

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

  # iso_url with a checksum, not iso_paths. The host re-verified a local file at
  # the build's input boundary; iso_paths would name a datastore artifact that
  # nothing here has seen, so the bytes verified would not be the bytes vSphere
  # consumes. This way Packer verifies the same file against the same expected
  # digest before uploading it.
  iso_url      = var.media_url
  iso_checksum = var.media_checksum

  cd_files = [var.answer_file_path, var.winrm_bootstrap_path]
  cd_label = "OEMDRV"

  # WinRM rather than SSH: the guest is Windows, and provisioning runs
  # PowerShell. The listener is created by the answer file's first-logon
  # command; a fresh installation has none, and without it the build completes
  # setup and then sits unreachable until this times out.
  #
  # HTTPS with a self-signed certificate. The build VM is transient and its
  # certificate cannot belong to any trust chain, so accepting it is a bounded
  # exception -- the alternative is a plaintext listener carrying the
  # administrator password on the wire.
  # NTLM stated explicitly. Packer defaults to Basic authentication, and the
  # bootstrap disables Basic on the listener, so without this the communicator
  # and the listener disagree about how to authenticate and the build fails at
  # connection with an error that describes neither cause.
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_use_ntlm = true
  winrm_port     = 5986
  winrm_timeout  = "4h"

  # The answer file and the script its first-logon command runs. Both travel as
  # removable media: a credential typed at a boot prompt is visible to anything
  # watching the console and is recorded in the configuration itself.
  #
  # A boot_command is not used today. It is not prohibited -- a bounded,
  # non-secret key sequence may prove necessary to start the installer, and
  # whether it is needed is lab-validated. What must never appear in one is a
  # credential.

  # Packer owns the shutdown, exactly as it owns the restart boundary. A guest
  # script that shut itself down would race the sealing step.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"packer build shutdown\""
  shutdown_timeout = "30m"

  # Template conversion is OFF, deliberately, and stays off until stage 5.
  #
  # Converting makes an artifact immutable, which is exactly why it must not
  # happen here. At this point in the build the VM still holds an enabled build
  # account with a known password, a WinRM listener reachable on the network,
  # and whatever answer-file residue setup left behind -- and it has not been
  # generalized, so it also carries a machine identity. Sealing that state
  # produces an immutable artifact nobody can fix and which a later stage might
  # find and treat as a candidate.
  #
  # Stage 5 turns this on only behind the gates that make it safe: the build
  # credential disabled or rotated, residue removed, generalization complete, a
  # shutdown observed rather than assumed, and positive sealing evidence. Those
  # gates are implemented in BuildEvidence.psm1 and are not invoked from here.
  convert_to_template = false
}

build {
  name    = "windows-candidate"
  sources = ["source.vsphere-iso.windows"]

  # STAGE 4 IS SOURCE AND BUILD CONFIGURATION ONLY.
  #
  # This build constructs a VM from qualified media and an unattended answer
  # file, and stops there. It deliberately contains no provisioners, because
  # everything that would follow belongs to later stages and none of it is
  # implemented:
  #
  #   - guest provisioning: the Increment 2 transfer bundle, its verification,
  #     installation, and evidence, are not wired in here yet. An earlier draft
  #     downloaded guest-evidence.json, which nothing in this configuration
  #     creates, so the build could not have reached generalization at all;
  #   - credential disable or rotation before sealing;
  #   - setup-residue removal inside the guest;
  #   - pre-generalization checks, generalization, and an observed shutdown;
  #   - provenance emission binding recipeDigest, runId, and the artifact.
  #
  # Those are stages 5 and 6. Listing them here rather than leaving the file
  # silent means the gap is visible to whoever opens it next, and a provisioner
  # added above this comment is a deliberate act rather than an accident.
  #
  # convert_to_template stays on the source: it is what makes the artifact
  # immutable once a build does complete. Confirming a seal, and refusing to
  # call anything a candidate without the full phase sequence, is stage 5 work
  # already implemented in BuildEvidence.psm1 and not invoked from here.
  provisioner "powershell" {
    use_pwsh = false
    inline = [
      "Write-Host 'stage 4: construction only. No guest provisioning is configured.'"
    ]
  }
}

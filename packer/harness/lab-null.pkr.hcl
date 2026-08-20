# Lab harness for guest package provisioning.
#
# The null builder connects to an externally supplied disposable Windows host and
# runs provisioners against it. It creates no image and produces no artifact,
# which lets transfer, execution, the restart boundary, validation, evidence
# retrieval, and cleanup all be exercised without deciding anything about image
# construction. The vSphere builder, base-image selection, media handling, and
# sealing belong to Increment 3, where several of them depend on the unresolved
# base-image decision in section 36 of the charter.
#
# This harness mutates a machine it did not create and cannot dispose of. Every
# safeguard below exists because "disposable" is a description of intent, and
# intent is not a control.
#
# Windows paths are written with forward slashes throughout. Windows accepts
# them, and a backslash-escaped path in a committed file reads as a UNC prefix to
# the repository's content scanner.

packer {
  required_version = "1.15.4"
}

variable "guest_host" {
  type        = string
  description = "Address of the disposable Windows target. No default: an unset target must be an error, never a fallback to something that happens to be reachable."
}

variable "guest_username" {
  type        = string
  description = "Account used for WinRM. No default."
}

variable "guest_password" {
  type        = string
  sensitive   = true
  description = "Password for the WinRM account. Supplied at runtime and never committed."
}

variable "acknowledge_destructive_lab_run" {
  type        = bool
  description = "Must be set to true by the operator. This harness installs software on the target, so an unacknowledged run is refused rather than defaulted."
}

variable "lab_marker_path" {
  type        = string
  description = "File on the target holding the lab nonce, placed there beforehand."
}

variable "lab_marker_nonce" {
  type        = string
  sensitive   = true
  description = "Value the marker must contain. Supplied independently of the target address, so the target has to prove it is the intended machine rather than the configuration asserting it."
}

variable "run_id" {
  type        = string
  description = "Canonical lowercase UUID from the orchestrator, correlating host and guest evidence."
}

variable "bundle_path" {
  type        = string
  description = "Host directory holding the verified-only bundle."
}

variable "descriptor_sha256" {
  type        = string
  description = "Expected digest of the bundle descriptor, delivered out of band through the environment rather than inside the bundle. A descriptor that carried its own expected digest would authenticate itself."
}

variable "guest_staging_root" {
  type        = string
  default     = "C:/vdi-iac-lab"
  description = "Guest directory the bundle is uploaded beneath. Host-controlled and passed in; never read or derived from the uploaded descriptor, because cleanup has to work after descriptor tampering."
}

variable "evidence_output_dir" {
  type        = string
  description = "Host directory that retrieved guest evidence is written to."
}

variable "tools_source_dir" {
  type        = string
  description = "Host directory holding the PowerShell modules the guest phase needs."
}

variable "guest_scripts_dir" {
  type        = string
  description = "Host directory holding the guest entry script."
}

locals {
  run_root      = "${var.guest_staging_root}/run-${var.run_id}"
  bundle_target = "${var.guest_staging_root}/run-${var.run_id}/bundle-${var.run_id}"
  tools_target  = "${var.guest_staging_root}/run-${var.run_id}/tools"
  guest_target  = "${var.guest_staging_root}/run-${var.run_id}/guest"
  evidence_name = "guest-evidence.json"

  # The guest wrapper returns this when packages failed for reasons the run is
  # designed to report. Packer accepts it so retrieval and cleanup still run, and
  # the host evaluator fails the build afterwards from the retrieved evidence.
  # Any other non-zero code is a genuine provisioner failure and stays a failure.
  logical_failure_exit_code = 200
}

source "null" "lab" {
  communicator   = "winrm"
  winrm_host     = var.guest_host
  winrm_username = var.guest_username
  winrm_password = var.guest_password
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "20m"
}

build {
  name    = "guest-provisioning-lab"
  sources = ["source.null.lab"]

  # 1. Preflight. Read-only, and first: it asks the target to prove it is the
  #    intended machine before anything is uploaded, executed, or restarted.
  provisioner "powershell" {
    use_pwsh = true
    environment_vars = [
      "VDIIAC_MARKER_PATH=${var.lab_marker_path}",
      "VDIIAC_MARKER_NONCE=${var.lab_marker_nonce}",
      "VDIIAC_ACKNOWLEDGED=${var.acknowledge_destructive_lab_run}"
    ]
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "if ($env:VDIIAC_ACKNOWLEDGED -ne 'true') { throw 'This run installs software on the target. Set acknowledge_destructive_lab_run to true to proceed.' }",
      "if (-not (Test-Path -LiteralPath $env:VDIIAC_MARKER_PATH -PathType Leaf)) { throw \"Lab marker not found at $env:VDIIAC_MARKER_PATH. Refusing to touch a machine that has not identified itself.\" }",
      "$observed = (Get-Content -LiteralPath $env:VDIIAC_MARKER_PATH -Raw).Trim()",
      "if ($observed -cne $env:VDIIAC_MARKER_NONCE) { throw 'Lab marker nonce does not match. This is not the intended target.' }",
      "Write-Host 'preflight: target identified'"
    ]
  }

  # 2. Guest staging, created only after the target identified itself.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "New-Item -ItemType Directory -Path '${local.run_root}' -Force | Out-Null",
      "New-Item -ItemType Directory -Path '${local.tools_target}' -Force | Out-Null",
      "New-Item -ItemType Directory -Path '${local.guest_target}' -Force | Out-Null"
    ]
  }

  # 3. Upload. The bundle carries only packages that passed host verification.
  provisioner "file" {
    source      = "${var.tools_source_dir}/"
    destination = "${local.tools_target}/"
  }

  provisioner "file" {
    source      = "${var.guest_scripts_dir}/"
    destination = "${local.guest_target}/"
  }

  provisioner "file" {
    source      = "${var.bundle_path}/"
    destination = "${local.bundle_target}/"
  }

  # 4. Install. The expected descriptor digest arrives through the environment,
  #    which is the same channel that delivers this script: an attacker able to
  #    rewrite it is already executing code here, so the bundle is no longer the
  #    weak point.
  provisioner "powershell" {
    use_pwsh         = true
    valid_exit_codes = [0, 200]
    environment_vars = [
      "VDIIAC_DESCRIPTOR_SHA256=${var.descriptor_sha256}",
      "VDIIAC_RUN_ID=${var.run_id}"
    ]
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "& '${local.guest_target}/Invoke-GuestPhase.ps1' -BundlePath '${local.bundle_target}' -ToolsPath '${local.tools_target}' -Phase install -EvidencePath '${local.run_root}/install-${local.evidence_name}'"
    ]
  }

  # 5. The restart boundary. Packer owns it; installation logic reports that a
  #    restart is required and never triggers one. Unconditional, so validation
  #    always runs in the same machine state regardless of manifest content.
  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # 6. Validation, on the far side of the restart.
  provisioner "powershell" {
    use_pwsh         = true
    valid_exit_codes = [0, 200]
    environment_vars = [
      "VDIIAC_DESCRIPTOR_SHA256=${var.descriptor_sha256}",
      "VDIIAC_RUN_ID=${var.run_id}"
    ]
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "& '${local.guest_target}/Invoke-GuestPhase.ps1' -BundlePath '${local.bundle_target}' -ToolsPath '${local.tools_target}' -Phase validate -EvidencePath '${local.run_root}/validate-${local.evidence_name}'"
    ]
  }

  # 7. Evidence retrieval, before cleanup. Cleanup can fail, and evidence
  #    collected afterwards may be gone.
  provisioner "file" {
    direction   = "download"
    source      = "${local.run_root}/install-${local.evidence_name}"
    destination = "${var.evidence_output_dir}/install-${local.evidence_name}"
  }

  provisioner "file" {
    direction   = "download"
    source      = "${local.run_root}/validate-${local.evidence_name}"
    destination = "${var.evidence_output_dir}/validate-${local.evidence_name}"
  }

  # 8. Guest cleanup. The target is derived from the host-controlled staging root
  #    and the run identifier, never from the uploaded descriptor.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "Import-Module '${local.tools_target}/GuestProvisioning.psm1' -Force",
      "$outcome = Remove-GuestBundle -StagingRoot '${local.run_root}' -RunId '${var.run_id}'",
      "Write-Host \"guest cleanup: $outcome\"",
      "Remove-Item -LiteralPath '${local.run_root}' -Recurse -Force -ErrorAction SilentlyContinue"
    ]
  }

  # Runs only when a provisioner failed, and only when the build is invoked with
  # -on-error=run-cleanup-provisioner. Declaring it is not enough: under the
  # default -on-error=cleanup it never executes, which is the failure this exists
  # to prevent. Cleanup here is attempted, never guaranteed -- if the communicator
  # is gone, guest staging cannot be removed, and evidence saying otherwise would
  # be false.
  error-cleanup-provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "Write-Host 'error cleanup: attempting guest staging removal'",
      "Remove-Item -LiteralPath '${local.run_root}' -Recurse -Force -ErrorAction SilentlyContinue",
      "if (Test-Path -LiteralPath '${local.run_root}') { Write-Host 'error cleanup: staging still present' } else { Write-Host 'error cleanup: staging removed' }"
    ]
  }
}

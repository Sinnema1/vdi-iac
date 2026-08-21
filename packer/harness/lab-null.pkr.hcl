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

  validation {
    # Validated here, before it reaches a path. This value names the run
    # directory the harness later removes recursively, so an arbitrary string
    # would be a deletion target rather than an identifier.
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.run_id))
    error_message = "The run identifier must be a canonical lowercase UUID."
  }
}

variable "bundle_path" {
  type        = string
  description = "Host directory holding the verified-only bundle."
}

variable "descriptor_sha256" {
  type        = string
  description = "Expected digest of the bundle descriptor, delivered out of band through the environment rather than inside the bundle. A descriptor that carried its own expected digest would authenticate itself."
}

variable "cleanup_nonce" {
  type      = string
  sensitive = true

  description = <<-EOT
    A value generated fresh for this invocation, distinct from run_id, and written
    into the ownership sentinel only after the run directory is reserved.

    run_id alone cannot serve: a colliding run refuses the existing directory and
    never writes a sentinel, so the error path would find the *previous* run's
    sentinel and delete a directory this invocation does not own. Reproduced
    before this existed. Cleanup therefore requires the sentinel to contain this
    invocation's nonce exactly.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32,64}$", var.cleanup_nonce))
    error_message = "The cleanup nonce must be 32 to 64 lowercase hexadecimal characters."
  }
}

variable "contracts_source_dir" {
  type        = string
  description = "Host directory holding the committed schemas. The guest validates its own evidence before the restart gate reads it."
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

  # Written only after the target identified itself and the run directory was
  # reserved. Cleanup refuses to remove anything without it, so a run that never
  # got past preflight cannot have its error path delete a directory it does not
  # own.
  sentinel_path    = "${var.guest_staging_root}/run-${var.run_id}/.owned-by-this-run"
  contracts_target = "${var.guest_staging_root}/run-${var.run_id}/contracts"

  # Written by the guest wrapper when a phase could not complete -- an installer
  # that may still be running, for instance. Its presence stops the build before
  # the restart.
  halt_path = "${var.guest_staging_root}/run-${var.run_id}/.halt"

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
      "if ($PSVersionTable.PSVersion -lt [version]'7.4.0') { throw \"The guest phase needs PowerShell 7.4.0 or later; this target has $($PSVersionTable.PSVersion).\" }",
      "Write-Host 'preflight: target identified'"
    ]
  }

  # 2. Guest staging, created only after the target identified itself.
  #
  #    Reserved rather than adopted: -Force would take over a directory another
  #    run owns, and this one deletes its run directory recursively at the end.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "New-Item -ItemType Directory -Path '${var.guest_staging_root}' -Force | Out-Null",
      "if (Test-Path -LiteralPath '${local.run_root}') { throw 'Run directory already exists on the target. Refusing to reuse a run identifier.' }",
      "New-Item -ItemType Directory -Path '${local.run_root}' | Out-Null",
      "New-Item -ItemType Directory -Path '${local.tools_target}' | Out-Null",
      "New-Item -ItemType Directory -Path '${local.guest_target}' | Out-Null",
      "New-Item -ItemType Directory -Path '${local.contracts_target}' | Out-Null",
      "Set-Content -LiteralPath '${local.sentinel_path}' -Value '${var.cleanup_nonce}' -NoNewline",
      "Write-Host 'staging: run directory reserved'"
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
    source      = "${var.contracts_source_dir}/"
    destination = "${local.contracts_target}/"
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
      "VDIIAC_RUN_ID=${var.run_id}",
      "VDIIAC_HALT_PATH=${local.halt_path}"
    ]
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "& '${local.guest_target}/Invoke-GuestPhase.ps1' -BundlePath '${local.bundle_target}' -ToolsPath '${local.tools_target}' -Phase install -EvidencePath '${local.run_root}/install-${local.evidence_name}'"
    ]
  }

  # 5. Install evidence is retrieved before the restart, not after the whole
  #    run. A phase that cannot complete stops the build at the next step, and a
  #    failing provisioner prevents the ones after it from running -- so evidence
  #    collected later would never be collected at all.
  provisioner "file" {
    direction   = "download"
    source      = "${local.run_root}/install-${local.evidence_name}"
    destination = "${var.evidence_output_dir}/install-${local.evidence_name}"
  }

  # 6. The restart gate.
  #
  #    Authorization is positive and comes from the install evidence, decided by
  #    Test-RestartAuthorization rather than by script inline here: the rules are
  #    then testable behaviorally instead of by reading this file. The halt
  #    marker is a supplementary signal, because writing it can fail and a gate
  #    that permits a reboot whenever a file is absent is fail-open.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Import-Module '${local.tools_target}/GuestProvisioning.psm1' -Force",
      "$decision = Test-RestartAuthorization -EvidencePath '${local.run_root}/install-${local.evidence_name}' -RunId '${var.run_id}' -SchemaPath '${local.contracts_target}/evidence-envelope-2.schema.json' -HaltMarkerPath '${local.halt_path}'",
      "if (-not $decision.Authorized) { throw \"Restart refused: $($decision.ReasonCode).\" }",
      "Write-Host 'gate: install completed, restart may proceed'"
    ]
  }

  # 7. The restart boundary. Packer owns it; installation logic reports that a
  #    restart is required and never triggers one. Unconditional, so validation
  #    always runs in the same machine state regardless of manifest content.
  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # 8. Validation, on the far side of the restart.
  provisioner "powershell" {
    use_pwsh         = true
    valid_exit_codes = [0, 200]
    environment_vars = [
      "VDIIAC_DESCRIPTOR_SHA256=${var.descriptor_sha256}",
      "VDIIAC_RUN_ID=${var.run_id}",
      "VDIIAC_HALT_PATH=${local.halt_path}"
    ]
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "& '${local.guest_target}/Invoke-GuestPhase.ps1' -BundlePath '${local.bundle_target}' -ToolsPath '${local.tools_target}' -Phase validate -EvidencePath '${local.run_root}/validate-${local.evidence_name}'"
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "${local.run_root}/validate-${local.evidence_name}"
    destination = "${var.evidence_output_dir}/validate-${local.evidence_name}"
  }

  # 9. Guest cleanup. The target is derived from the host-controlled staging root
  #    and the run identifier, never from the uploaded descriptor, and it is
  #    refused outright unless this run's ownership sentinel is present.
  provisioner "powershell" {
    use_pwsh = true
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "Import-Module '${local.tools_target}/GuestProvisioning.psm1' -Force",
      "$result = Invoke-GuestCleanup -StagingRoot '${local.run_root}' -RunId '${var.run_id}' -SentinelPath '${local.sentinel_path}' -ExpectedNonce '${var.cleanup_nonce}'",
      "Write-Host \"guest cleanup: $($result.BundleOutcome)\"",
      "if (Test-Path -LiteralPath '${local.run_root}') { Write-Host 'guest cleanup: run directory still present' } else { Write-Host 'guest cleanup: run directory removed' }"
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
      # Gated on the same sentinel as normal cleanup. Without it this path could
      # run after a failed preflight -- a target that never identified itself --
      # and delete a directory belonging to something else entirely.
      "Import-Module '${local.tools_target}/GuestProvisioning.psm1' -Force -ErrorAction SilentlyContinue",
      "if (-not (Get-Command Invoke-GuestCleanup -ErrorAction SilentlyContinue)) { Write-Host 'error cleanup: tools unavailable, leaving the target untouched'; exit 0 }",
      # Content, not mere presence. A colliding run never writes a sentinel, so
      # presence alone would authorize deleting the directory the *previous* run
      # owns -- reproduced, with its witness file destroyed.
      "$result = Invoke-GuestCleanup -StagingRoot '${local.run_root}' -RunId '${var.run_id}' -SentinelPath '${local.sentinel_path}' -ExpectedNonce '${var.cleanup_nonce}' -ErrorPath",
      "if (-not $result.Authorized) { Write-Host 'error cleanup: sentinel missing or from another invocation, leaving the target untouched'; exit 0 }",
      "if ($result.RootRemoved) { Write-Host 'error cleanup: staging removed' } else { Write-Host 'error cleanup: staging still present' }"
    ]
  }
}

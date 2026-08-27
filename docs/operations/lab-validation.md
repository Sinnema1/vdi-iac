# Disposable-target lab validation

The first execution of the image build. Everything in this repository up to this
point is CI-proven against test doubles; nothing has touched vSphere, VMware
Tools, WinRM, or Sysprep. This run is what turns that into evidence.

**Expect the first attempt to fail.** The useful outcome is a specific failure
with a readable reason, not a sealed candidate. Plan for several attempts.

## What the run does, and where it can leave things

The build creates a VM, installs Windows unattended, provisions the qualified
packages, validates them after a restart, runs the pre-generalization checks,
clears the credential residue, and hands off to a detached finalizer. Packer
then waits for the guest to power itself off. Sealing runs on the host
afterwards and converts the powered-off VM to a template.

Two deliberate behaviours will look like problems and are not:

- **A failed finalizer leaves the VM powered on.** Packer waits out
  `shutdown_timeout` and fails. That is the fail-closed design working, and the
  machine is left for you to inspect.
- **A failed build is not cleaned up.** `-on-error=abort` is deliberate:
  deleting the machine would destroy the thing the reconciliation record points
  at. Removing it is a separate decision you make.

## Preflight

### Platform

- A vCenter instance, and a cluster, datastore, port group, and folder you are
  willing to have machines created and destroyed in.
- A network that reaches the build VM on **TCP 5986**. The guest is unreachable
  before its first logon completes, so a firewall that blocks this looks
  identical to a failed bootstrap.
- PowerCLI installed on the host that runs the seal.

### Media and packages

- Windows installation media on a path the build host can read.
- Its checksum, obtained **independently of the artifact** — from the vendor's
  published checksum page, not from a file beside the download. The contract
  refuses a citation that is a filesystem path.
- The VMware Tools installer, at the exact version you will declare, staged
  under the package source root the manifest references.

### Values you must supply

None of these can be guessed, and three of them will fail the run if wrong:

| Value | Where | Consequence if wrong |
| --- | --- | --- |
| `vmwareToolsVersion` | manifest, recipe tooling, builder | The prerequisite gate refuses the build after installing correctly |
| `guest_os_type` | `windows9_64Guest` or `windows11_64Guest` | vSphere presents the wrong device model to setup |
| media edition, index, architecture, language | media reference | The pre-generalization identity check fails after a full install |

The Tools version must be the **file version of `vmtoolsd.exe`** as installed,
compared exactly. Install Tools on a throwaway VM first and read it, rather than
taking it from a release note.

### Outstanding before the first run

- **Windows System Image Manager validation of the answer file.** Nothing in
  this repository parses component names or checks configuration-pass placement,
  so a component in the wrong pass satisfies every check here and then hangs
  setup at a prompt. This is the single most likely first failure.

## Credentials

Both are read from the environment and cleared as they are read. Neither is ever
a parameter, a `-var`, or a var-file entry — the entry point refuses a var file
that assigns either.

```bash
export VDIIAC_BUILD_PASSWORD='...'
export VDIIAC_VCENTER_PASSWORD='...'
```

The vCenter account needs, scoped to the build folder: create and delete virtual
machines, modify configuration, convert to template, and read and write advanced
settings (`guestinfo.*`). The build account is the built-in Administrator, whose
password is the one above; it is disabled during finalization.

## Invocation

```bash
pwsh ./scripts/ci/Invoke-ImageBuild.ps1 -WhatIf -MediaReferencePath ./packer/media/windows-baseline.media.json -MediaRoot /path/to/media -ManifestPath ./packer/manifests/example-baseline-v2.json -AnswerFileDeclarationPath ./packer/unattended/autounattend.template.json -PackageSourceRoot /path/to/packages -VarFile ./packer/builds/lab.auto.pkrvars.hcl -WorkRoot /path/to/work -CandidateName windows-candidate-001 -VCenterServer vcenter.example -VCenterUsername builder@example -InsecureConnection $false -Hardware @{ HardwareVersion=21; Firmware='efi-secure'; SecureBoot=$true; DiskControllerType='pvscsi'; DiskSizeGb=80; VirtualTpm=$true; Cpus=4; MemoryMb=8192; GuestOsType='windows11_64Guest' } -Tooling @{ PackerVersion='1.15.4'; PluginVersions=@{ vsphere='1.4.2' }; VMwareToolsVersion='12.5.0' } -BuildLogic @{ PackerConfigDigests=@{}; ProvisioningScriptDigests=@{}; GuestContractVersion=2 }
```

Run it with `-WhatIf` first. That qualifies the media, assembles the bundle,
computes the recipe digest, and stops before creating anything — which catches
a wrong checksum, a missing package, or a disagreeing Tools version in seconds
rather than after a Windows install.

Then remove `-WhatIf`.

## Reading the outcome

| Exit | Meaning |
| --- | --- |
| 0 | Sealed candidate. `image-build-evidence.json` is in the evidence directory |
| 1 | No candidate. A `pre-seal` or `seal-unconfirmed` record says why |
| 2 | Refused before starting: a missing secret, an unavailable module, a var file carrying a secret |
| 3 | **Worst case.** Something may exist on the platform and no durable record was written. Reconcile by hand |

Evidence is written under the run directory: the media qualification record, the
recipe input, the retrieved guest phase documents, the finalization attestation,
and the final image-build record.

## When it fails

Work outward from where it stopped.

**Setup never completes, or sits at a prompt.** The answer file. Attach the
console; SIM validation is outstanding and this is what it looks like.

**Setup completes and Packer never connects.** The bootstrap: the `OEMDRV`
volume was not found, the listener was not created, or 5986 is blocked. The
machine is up and reachable by console.

**The build fails at the Tools gate.** The declared version does not equal
`vmtoolsd.exe`'s file version. The message names both.

**The build waits and then times out at shutdown.** The finalizer refused, and
the machine is deliberately still running. Read
`C:/vdi-iac-build/finalization.log` on the guest — it is removed only on the
path that succeeds, so if the machine is up, the log is there.

**The seal refuses.** The reason code names which check. `attestation_missing`
means the finalizer never published; `vm_not_powered_off` means Packer returned
before the guest went down; `vm_not_resolved` means the run annotation is not on
the machine.

## Cleaning up

Machines are left deliberately. Once you have read the evidence, remove the
build VM and any template the run created — this repository does not delete
them, on purpose.

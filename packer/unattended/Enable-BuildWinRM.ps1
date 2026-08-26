#Requires -Version 5.1
<#
.SYNOPSIS
    Makes a freshly installed build VM reachable by the Packer communicator.

.DESCRIPTION
    Runs once, as a first-logon command from the answer file. A fresh
    installation has no WinRM listener, so without this the build finishes setup
    and then sits unreachable until the communicator times out -- a failure that
    looks like a network problem and is not.

    HTTPS with a self-signed certificate, not plaintext. The build VM is
    transient and its certificate cannot belong to any trust chain, so the
    realistic alternative is an unencrypted listener carrying the administrator
    password on the wire for the length of the build. Packer is told to accept
    the self-signed certificate; that exception is bounded to a machine that
    exists for one build and is generalized before it becomes an image.

    Windows PowerShell 5.1, deliberately: this runs before anything has been
    provisioned, and PowerShell 7 is not present on a fresh installation.

    Not yet lab-validated. Nothing here has run against a real Windows setup.
#>

$ErrorActionPreference = 'Stop'

# A certificate for this machine only, replaced on every build.
$certificate = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME `
    -CertStoreLocation 'Cert:\LocalMachine\My'

# Remove any listener setup may have created, so the configuration below is the
# only one present rather than one of several with unclear precedence.
Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue |
    Where-Object { $_.Keys -contains 'Transport=HTTP' -or $_.Keys -contains 'Transport=HTTPS' } |
    ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }

New-Item -Path 'WSMan:\localhost\Listener' -Transport HTTPS -Address * `
    -CertificateThumbPrint $certificate.Thumbprint -Force | Out-Null

# Negotiate stays on and Basic stays off: Basic would send the password
# reversibly encoded, and the listener's certificate is not independently
# trusted, so the transport is not a reason to weaken authentication.
Set-Item -Path 'WSMan:\localhost\Service\Auth\Basic' -Value $false
Set-Item -Path 'WSMan:\localhost\Service\Auth\Negotiate' -Value $true
Set-Item -Path 'WSMan:\localhost\Service\AllowUnencrypted' -Value $false

netsh advfirewall firewall add rule name="WinRM HTTPS (build)" `
    dir=in action=allow protocol=TCP localport=5986 | Out-Null

Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM

Write-Output "WinRM HTTPS listener ready on $env:COMPUTERNAME"

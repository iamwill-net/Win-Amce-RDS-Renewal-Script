<#
.SYNOPSIS
    win-acme installation script: applies a renewed certificate to every RDS role
    (Gateway, Web Access, Connection Broker SSO + Publishing) and, if present,
    updates the RD Web Client broker certificate and republishes the client.

.DESCRIPTION
    Intended to be called by win-acme's "script" installation step, which runs
    after every successful issue/renewal. Run on the RD Connection Broker, or on an
    RD Gateway / Web Access server in the deployment (broker is auto-detected).

    Ways to supply the certificate:
      0. No parameters: uses the newest valid Let's Encrypt cert in LocalMachine\My.
      1. -Thumbprint '{CertThumbprint}'
         Cert must be in LocalMachine\My with an exportable private key
         (set Store.CertificateStore.PrivateKeyExportable = true in win-acme settings.json).
      2. -PfxPath '{CacheFile}' -PfxPassword '{CachePassword}'
         Uses win-acme's cached PFX directly; no exportable key needed.

    Setup: place this file in the "Scripts" folder inside the win-acme folder (next to
    wacs.exe). In the interactive win-acme menu choose the installation step
    "Start external script or program", enter the path as:
        Scripts\Update-RDSCertificate.ps1
    and leave the parameters blank.

.EXAMPLE
    wacs.exe --source manual --host rds.school.sch.uk --store certificatestore `
        --installation script --script "C:\win-acme\Scripts\Update-RDSCertificate.ps1"
#>
[CmdletBinding(DefaultParameterSetName = 'Thumbprint')]
param(
    # Optional: if omitted, the newest Let's Encrypt cert in LocalMachine\My is used
    [Parameter(ParameterSetName = 'Thumbprint')]
    [string]$Thumbprint,

    [Parameter(Mandatory, ParameterSetName = 'Pfx')]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Pfx')]
    [string]$PfxPassword = '',

    # Optional: if omitted, auto-detected (this machine if it is a broker, otherwise
    # read from the local "RDS Management Servers" group, e.g. when run on an RD Gateway/Web server)
    [string]$ConnectionBroker,

    [string]$LogPath = "$env:ProgramData\win-acme\Update-RDSCertificate.log"
)

$ErrorActionPreference = 'Stop'
$workDir = Join-Path $env:TEMP ("rdscert_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

try {
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    Import-Module RemoteDesktop

    # --- Find the Connection Broker -------------------------------------------------
    if (-not $ConnectionBroker) {
        $localFqdn = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
        if (Get-Service -Name RDMS -ErrorAction SilentlyContinue) {
            $ConnectionBroker = $localFqdn      # this server is the broker
        }
        else {
            # When a server joins a deployment, the broker's computer account is added to
            # its local "RDS Management Servers" group (e.g. DOMAIN\BROKER01$)
            $candidates = Get-LocalGroupMember -Group 'RDS Management Servers' -ErrorAction SilentlyContinue |
                ForEach-Object { ($_.Name -split '\\')[-1].TrimEnd('$') }
            foreach ($name in $candidates) {
                try {
                    $fqdn = [System.Net.Dns]::GetHostEntry($name).HostName
                    Get-RDServer -ConnectionBroker $fqdn | Out-Null   # confirm it answers as a broker
                    $ConnectionBroker = $fqdn
                    break
                }
                catch { Write-Log "Candidate broker $name did not respond: $($_.Exception.Message)" }
            }
            if (-not $ConnectionBroker) {
                throw "Could not detect the Connection Broker. Re-run with -ConnectionBroker <broker FQDN>"
            }
        }
        Write-Log "Auto-detected Connection Broker: $ConnectionBroker"
    }

    # --- Get the certificate into a PFX we know the password for -----------------
    if ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
        # win-acme uses the WebHosting store by default when IIS is installed, otherwise My
        $stores = 'Cert:\LocalMachine\WebHosting', 'Cert:\LocalMachine\My' | Where-Object { Test-Path $_ }
        $allCerts = Get-ChildItem $stores
        if ($Thumbprint) {
            $Thumbprint = $Thumbprint.Replace(' ', '').ToUpper()
            $cert = $allCerts | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
            if (-not $cert) { throw "Certificate $Thumbprint not found in $($stores -join ', ')" }
        }
        else {
            # No parameters given: pick the newest valid Let's Encrypt cert with a private key
            $cert = $allCerts |
                Where-Object { $_.HasPrivateKey -and $_.Issuer -match "O=Let's Encrypt" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotBefore -Descending | Select-Object -First 1
            if (-not $cert) { throw "No valid Let's Encrypt certificate found in $($stores -join ', ')" }
            Write-Log "No thumbprint supplied - auto-selected newest Let's Encrypt cert from $($cert.PSParentPath -replace '.*::')"
        }
        $PfxPassword = [guid]::NewGuid().ToString()
        $PfxPath = Join-Path $workDir 'rds.pfx'
        Export-PfxCertificate -Cert $cert -FilePath $PfxPath `
            -Password (ConvertTo-SecureString $PfxPassword -AsPlainText -Force) | Out-Null
    }
    else {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $PfxPassword)
    }
    $securePw = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
    Write-Log "Applying certificate $($cert.Subject) [$($cert.Thumbprint)] expires $($cert.NotAfter) via broker $ConnectionBroker"

    # --- RDS deployment roles (Server Manager > RDS > Tasks > Certificates) -----
    $servers = Get-RDServer -ConnectionBroker $ConnectionBroker
    $deployed = $servers.Roles
    $rolesToSet = @('RDRedirector', 'RDPublishing')           # broker roles, always present
    if ($deployed -contains 'RDS-WEB-ACCESS') { $rolesToSet += 'RDWebAccess' }
    if ($deployed -contains 'RDS-GATEWAY')    { $rolesToSet += 'RDGateway' }

    foreach ($role in $rolesToSet) {
        Write-Log "Set-RDCertificate -Role $role"
        Set-RDCertificate -Role $role -ImportPath $PfxPath -Password $securePw `
            -ConnectionBroker $ConnectionBroker -Force
    }

    # --- RD Web Client -----------------------------------------------------------
    $cerBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $webServers = ($servers | Where-Object { $_.Roles -contains 'RDS-WEB-ACCESS' }).Server

    $webClientBlock = {
        param([byte[]]$CerBytes)
        if (-not (Get-Module -ListAvailable -Name RDWebClientManagement)) { return 'Web client module not installed - skipped' }
        Import-Module RDWebClientManagement
        if (-not (Get-RDWebClientPackage)) { return 'No web client package installed - skipped' }
        $cerPath = Join-Path $env:TEMP ("rdbroker_" + [guid]::NewGuid().ToString('N') + '.cer')
        [System.IO.File]::WriteAllBytes($cerPath, $CerBytes)
        try {
            Import-RDWebClientBrokerCert $cerPath
            Publish-RDWebClientPackage -Type Production -Latest
            'Web client broker cert imported and package published'
        }
        finally { Remove-Item $cerPath -Force -ErrorAction SilentlyContinue }
    }

    foreach ($web in $webServers) {
        $isLocal = $web.Split('.')[0] -ieq $env:COMPUTERNAME
        $result = if ($isLocal) { & $webClientBlock $cerBytes }
                  else { Invoke-Command -ComputerName $web -ScriptBlock $webClientBlock -ArgumentList (, $cerBytes) }
        Write-Log "[$web] $result"
    }

    Write-Log 'Completed successfully'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1   # non-zero so win-acme flags the renewal as failed and emails you
}
finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

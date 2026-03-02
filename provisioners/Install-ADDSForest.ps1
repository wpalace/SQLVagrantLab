<#
.SYNOPSIS
    Promotes the server to a Domain Controller.

.DESCRIPTION
    For the first DC (Mode='Forest'): Creates a new AD DS forest + domain.
    For subsequent DCs (Mode='Replica'): Adds this server as a replica DC.
    Vagrant is configured with 'reboot: true' so the VM restarts after promotion.

.PARAMETER DomainName
    Fully qualified domain name (e.g. test.dev).

.PARAMETER AdminPassword
    DSRM safe-mode administrator password.

.PARAMETER Mode
    'Forest' (create new forest) or 'Replica' (join existing domain as DC).
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][ValidateSet('Forest','Replica')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> [Install-ADDSForest] Mode=$Mode Domain=$DomainName" -ForegroundColor Cyan

# ── Idempotency: skip if already a DC ────────────────────────────────────────
# DomainRole: 0=Standalone WS, 1=Member WS, 2=Standalone Srv, 3=Member Srv,
#             4=Backup DC, 5=Primary DC
$role = (Get-WmiObject Win32_ComputerSystem).DomainRole
if ($role -ge 4) {
    Write-Host "  Already a Domain Controller (role=$role) -- skipping promotion." -ForegroundColor Yellow
    exit 0
}

$secPassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

# ── Install Windows Features ──────────────────────────────────────────────────

Write-Host '  Installing AD-Domain-Services + DNS...'
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
Import-Module ADDSDeployment

# ── Promote to DC ─────────────────────────────────────────────────────────────

if ($Mode -eq 'Forest') {
    Write-Host "  Creating new AD forest: $DomainName"
    $forestParams = @{
        DomainName                    = $DomainName
        DomainNetBiosName             = ($DomainName.Split('.')[0].ToUpper())
        SafeModeAdministratorPassword = $secPassword
        InstallDns                    = $true
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Install-ADDSForest @forestParams
} else {
    Write-Host "  Joining $DomainName as replica DC..."
    # Wait for the forest DC to be reachable before promoting
    $deadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Connection -ComputerName $DomainName -Count 1 -Quiet) -and (Get-Date) -lt $deadline) {
        Write-Host '    Waiting for forest DC...'
        Start-Sleep 15
    }

    $credential = New-Object System.Management.Automation.PSCredential(
        "$($DomainName.Split('.')[0].ToUpper())\Administrator", $secPassword)

    $replicaParams = @{
        DomainName                    = $DomainName
        SafeModeAdministratorPassword = $secPassword
        Credential                    = $credential
        InstallDns                    = $true
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Install-ADDSDomainController @replicaParams
}

Write-Host "  ✅  DC promotion complete. Vagrant will reboot now." -ForegroundColor Green

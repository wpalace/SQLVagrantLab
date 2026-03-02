<#
.SYNOPSIS
    Creates the lab domain administrator account in Active Directory.

.DESCRIPTION
    Runs on the forest root DC after promotion and reboot.
    Creates a dedicated admin account (not the built-in Administrator),
    adds it to Domain Admins, and sets the password to never expire
    (appropriate for a throwaway lab environment).

.PARAMETER DomainName
    FQDN of the domain (e.g. test.dev).

.PARAMETER AdminUser
    Username for the lab admin account (e.g. admin).

.PARAMETER AdminPassword
    Password for the lab admin account.
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> [New-LabAdminAccount] Creating '$AdminUser' in $DomainName" -ForegroundColor Cyan

Import-Module ActiveDirectory

$secPassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

# ── Create user if it doesn't exist ──────────────────────────────────────────

if (-not (Get-ADUser -Filter "SamAccountName -eq '$AdminUser'" -ErrorAction SilentlyContinue)) {
    New-ADUser `
        -SamAccountName       $AdminUser `
        -UserPrincipalName    "$AdminUser@$DomainName" `
        -Name                 $AdminUser `
        -GivenName            'Lab' `
        -Surname              'Admin' `
        -DisplayName          'Lab Administrator' `
        -AccountPassword      $secPassword `
        -ChangePasswordAtLogon $false `
        -PasswordNeverExpires  $true `
        -Enabled              $true `
        -Description          'SqlVagrantLab administrator account'
    Write-Host "  Created user: $AdminUser"
} else {
    Write-Host "  User '$AdminUser' already exists — updating password"
    Set-ADAccountPassword -Identity $AdminUser -NewPassword $secPassword -Reset
}

# ── Add to Domain Admins and Enterprise Admins ────────────────────────────────

foreach ($group in @('Domain Admins', 'Enterprise Admins', 'Schema Admins')) {
    $grp = Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue
    if ($grp) {
        $members = Get-ADGroupMember $grp | Select-Object -ExpandProperty SamAccountName
        if ($AdminUser -notin $members) {
            Add-ADGroupMember -Identity $grp -Members $AdminUser
            Write-Host "  Added to: $group"
        }
    }
}

Write-Host "  ✅  Lab admin account '$AdminUser@$DomainName' is ready." -ForegroundColor Green

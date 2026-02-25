#Requires -Version 7.0
<#
.SYNOPSIS
    Master turnkey deployment script for the SqlVagrantLab.

.DESCRIPTION
    Reads config.yaml, validates pre-built Packer .box files exist, generates
    a Vagrantfile from the ERB template, and runs 'vagrant up'.

.PARAMETER ConfigPath
    Path to the YAML topology file. Defaults to config.yaml in the script dir.

.PARAMETER WhatIf
    Generates the Vagrantfile and prints a plan but does NOT run 'vagrant up'.

.PARAMETER Provider
    Vagrant provider to use: qemu (default) or hyperv.

.EXAMPLE
    pwsh -File Deploy-Lab.ps1
    pwsh -File Deploy-Lab.ps1 -ConfigPath ./config.yaml -WhatIf -Verbose
    pwsh -File Deploy-Lab.ps1 -Provider hyperv
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.yaml'),
    [ValidateSet('qemu', 'hyperv')]
    [string]$Provider = 'qemu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Module bootstrap ──────────────────────────────────────────────────────────

function Ensure-Module ([string]$Name) {
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Installing module: $Name"
        Install-Module $Name -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $Name -Force
}

Ensure-Module 'powershell-yaml'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step  ([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    ([string]$m) { Write-Host "  ✅  $m" -ForegroundColor Green }
function Write-Err   ([string]$m) { Write-Host "  ❌  $m" -ForegroundColor Red; throw $m }

# Expands ~ in paths
function Resolve-TildePath ([string]$p) { $p -replace '^~', $HOME }

# ── 1. Parse YAML ─────────────────────────────────────────────────────────────

Write-Step "Parsing config: $ConfigPath"

if (-not (Test-Path $ConfigPath)) {
    Write-Err "Config file not found: $ConfigPath"
}

$raw = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

$global = $raw.global
$domainName = $global.domain_name ?? 'test.dev'
$adminUser = $global.admin_user ?? 'admin'
$adminPassword = $global.admin_password ?? 'P@ssw0rd'
$boxLibrary = Resolve-TildePath ($global.box_library_path ?? '~/vagrant-boxes')

Write-Ok "Domain    : $domainName"
Write-Ok "Admin user: $adminUser"
Write-Ok "Box lib   : $boxLibrary"

# ── 2. Validate box library ───────────────────────────────────────────────────

Write-Step 'Validating Packer .box files...'

$boxErrors = [System.Collections.Generic.List[string]]::new()

foreach ($region in $raw.regions) {
    foreach ($node in $region.nodes) {
        $osVer = $node.os_version.ToString()
        # All nodes (DC and SQL) now use the SQL-inclusive box image.
        # DC nodes declare sql_version in config.yaml; the SQL service is
        # disabled at first boot by Disable-SqlServer.ps1.
        if (-not $node['sql_version']) {
            Write-Err "Node '$($node.hostname)' is missing 'sql_version' in config.yaml. All nodes must declare sql_version."
        }
        $sqlVer = $node.sql_version.ToString()
        $boxName = "win${osVer}-sql${sqlVer}"
        $boxPath = Join-Path $boxLibrary "${boxName}.box"

        if (-not (Test-Path $boxPath)) {
            $boxErrors.Add("MISSING box for $($node.hostname): $boxPath")
        }
        else {
            Write-Ok "$($node.hostname) -> $boxName"
        }
        # Attach box info to node for use in generation
        $node['_box_name'] = $boxName
        $node['_box_path'] = $boxPath
    }
}

if ($boxErrors.Count -gt 0) {
    Write-Host ''
    Write-Host '  The following .box files are missing:' -ForegroundColor Red
    $boxErrors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host "  Run 'packer build' for each missing combination first." -ForegroundColor Yellow
    throw 'Missing box files — aborting.'
}

# ── 3. Ensure vagrant-qemu plugin ────────────────────────────────────────────

if ($Provider -eq 'qemu') {
    Write-Step 'Checking vagrant-qemu plugin...'
    $plugins = & vagrant plugin list 2>&1
    if ($plugins -notmatch 'vagrant-qemu') {
        Write-Host '  Installing vagrant-qemu...'
        & vagrant plugin install vagrant-qemu
    }
    else {
        Write-Ok 'vagrant-qemu installed'
    }
}

# ── 3b. Ensure vagrant-reload plugin ─────────────────────────────────────────
# vagrant-reload provides the `type: "reload"` provisioner used to reboot
# Windows VMs safely (avoids the SSH-channel reboot issue with reboot:true).

Write-Step 'Checking vagrant-reload plugin...'
$plugins = & vagrant plugin list 2>&1
if ($plugins -notmatch 'vagrant-reload') {
    Write-Host '  Installing vagrant-reload...'
    & vagrant plugin install vagrant-reload
}
else {
    Write-Ok 'vagrant-reload installed'
}

# ── 4. Build template data model ──────────────────────────────────────────────

Write-Step 'Building topology model...'

# Identify the first DomainController node (forest root)
$allNodes = $raw.regions | ForEach-Object { $_.nodes }
$forestDC = $allNodes | Where-Object { $_.role -eq 'DomainController' } | Select-Object -First 1
$forestDcIp = $forestDC.static_ip

Write-Ok "Forest DC : $($forestDC.hostname) @ $forestDcIp"

$regions = & {
    # SSH ports: 50022, 50023, ... — one unique port per VM across all regions
    $nodeIndex = 0
    foreach ($region in $raw.regions) {
        $network = $region.network   # e.g. 192.168.10.0/24
        $prefix = $network.Split('/')[1]
        $baseIp = $network.Split('/')[0]
        $octets = $baseIp.Split('.') | ForEach-Object { [int]$_ }
        $gateway = "$($octets[0]).$($octets[1]).$($octets[2]).1"
        # Compute netmask from prefix length
        $mask = ([System.Net.IPAddress]([uint32]::MaxValue -shl (32 - [int]$prefix) -band [uint32]::MaxValue)).GetAddressBytes() | ForEach-Object { $_ } | Join-String -Separator '.'

        # @() ensures a single-node region stays a JSON array (not a bare object)
        $nodes = @(foreach ($node in $region.nodes) {
                $dcMode = if ($node.role -eq 'DomainController') {
                    if ($node.static_ip -eq $forestDcIp) { 'Forest' } else { 'Replica' }
                }
                else { '' }

                [ordered]@{
                    hostname   = $node.hostname
                    role       = $node.role
                    static_ip  = $node.static_ip
                    box_name   = $node['_box_name']
                    box_path   = $node['_box_path']
                    cpus       = $node.cpus ?? 2
                    memory_mb  = $node.memory_mb ?? 2048
                    dns_server = $forestDcIp
                    dc_mode    = $dcMode
                    primary    = ($node.static_ip -eq $forestDcIp).ToString().ToLower()
                    ssh_port   = 50022 + $nodeIndex
                    winrm_port = 55985 + $nodeIndex   # WinRM HTTP port forwarded per-VM
                }
                $nodeIndex++
            })

        [ordered]@{
            name          = $region.name
            network       = $network
            netmask       = $mask
            prefix_length = $prefix
            gateway       = $gateway
            nodes         = $nodes
        }
    } # end foreach region
} # end & scriptblock

# ── 5. Render Vagrantfile from ERB template ───────────────────────────────────

Write-Step 'Generating Vagrantfile...'

$erbPath = Join-Path $PSScriptRoot 'vagrant/Vagrantfile.erb'
$vagrantPath = Join-Path $PSScriptRoot 'Vagrantfile'
$providerLib = "vagrant/lib/provider_$Provider"

# Resolve Ruby binary — prefer Vagrant's embedded Ruby (works even when PATH
# is stripped by sudo), fall back to system ruby if present.
$vagrantRuby = '/opt/vagrant/embedded/bin/ruby'
$rubyBin = if (Test-Path $vagrantRuby) {
    $vagrantRuby
}
elseif ($systemRuby = (Get-Command ruby -ErrorAction SilentlyContinue)?.Source) {
    $systemRuby
}
else {
    Write-Err 'Ruby not found. Vagrant embedded Ruby expected at /opt/vagrant/embedded/bin/ruby.'
}
Write-Verbose "Using Ruby: $rubyBin"

# Use Ruby to render the ERB template (Ruby is bundled with Vagrant)
$rubyScript = @"
require 'erb'
require 'json'

data = JSON.parse(STDIN.read)

@config_path  = data['config_path']
@provider_lib = data['provider_lib']
@domain_name  = data['domain_name']
@admin_user   = data['admin_user']
@admin_password = data['admin_password']
@forest_dc_ip = data['forest_dc_ip']
@regions      = data['regions'].map { |r|
  r.transform_keys(&:to_sym).tap { |rh|
    rh[:nodes] = rh[:nodes].map { |n| n.transform_keys(&:to_sym) }
  }
}

template = File.read('$($erbPath -replace '\\','/')')
result   = ERB.new(template, trim_mode: '<>').result(binding)
print result
"@

$templateData = [ordered]@{
    config_path    = $ConfigPath
    provider_lib   = $providerLib
    domain_name    = $domainName
    admin_user     = $adminUser
    admin_password = $adminPassword
    forest_dc_ip   = $forestDcIp
    # @() ensures a single-region config stays a JSON array (not a bare object)
    regions        = @($regions)
} | ConvertTo-Json -Depth 10

$vagrantContent = $templateData | & $rubyBin -e $rubyScript
if ($LASTEXITCODE -ne 0) { throw 'ERB rendering failed' }

if ($PSCmdlet.ShouldProcess($vagrantPath, 'Write Vagrantfile')) {
    Set-Content -Path $vagrantPath -Value $vagrantContent -Encoding Utf8
    Write-Ok "Vagrantfile written: $vagrantPath"
}
else {
    Write-Host "`n--- Vagrantfile preview ---`n" -ForegroundColor Yellow
    Write-Host $vagrantContent
    Write-Host "`n--- End preview ---`n" -ForegroundColor Yellow
}

# ── 6. Print deployment plan ──────────────────────────────────────────────────

Write-Host ''
Write-Host "$('─' * 60)" -ForegroundColor DarkGray
Write-Host ' Deployment Plan' -ForegroundColor White
Write-Host "$('─' * 60)" -ForegroundColor DarkGray
Write-Host " Domain  : $domainName" -ForegroundColor White
Write-Host " Provider: $Provider"   -ForegroundColor White
Write-Host ''
foreach ($r in $regions) {
    Write-Host "  Region: $($r.name)  [$($r.network)]" -ForegroundColor Magenta
    foreach ($n in $r.nodes) {
        $badge = if ($n.role -eq 'DomainController') { '[DC]' } else { '[SQL]' }
        Write-Host "    $badge $($n.hostname.PadRight(12)) $($n.static_ip.PadRight(18)) Box: $($n.box_name)"
    }
}
Write-Host "$('─' * 60)`n" -ForegroundColor DarkGray

# ── 7. Execute vagrant up ─────────────────────────────────────────────────────

if (-not $WhatIfPreference) {
    Write-Step "Running: vagrant up --provider=$Provider --no-parallel"
    & vagrant up --provider=$Provider --no-parallel
    if ($LASTEXITCODE -ne 0) { throw "vagrant up failed with exit code $LASTEXITCODE" }
    Write-Host "`n  Lab is up! Use 'vagrant ssh <hostname>' to connect.`n" -ForegroundColor Green
}
else {
    Write-Host '  [-WhatIf] vagrant up skipped.' -ForegroundColor Yellow
}

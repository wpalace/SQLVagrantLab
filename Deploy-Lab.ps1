#Requires -Version 7.0
<#
.SYNOPSIS
    Master turnkey deployment script for the SqlVagrantLab.

.DESCRIPTION
    Reads config.yaml, validates pre-built Packer .box files exist, generates
    a Vagrantfile from the ERB template, runs 'vagrant up' (networking + boot
    only — no Vagrant provisioners), then calls the SSH-based provisioner
    scripts for each node role in dependency order.

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
    $regionIndex = 0
    foreach ($region in $raw.regions) {
        $network = $region.network   # e.g. 192.168.10.0/24
        $prefix = $network.Split('/')[1]
        $baseIp = $network.Split('/')[0]
        $octets = $baseIp.Split('.') | ForEach-Object { [int]$_ }
        $gateway = "$($octets[0]).$($octets[1]).$($octets[2]).1"
        # Compute netmask from prefix length using bitwise shifts (avoids the
        # IPAddress constructor byte-order reversal on x86 / little-endian hosts).
        $maskInt = if ([int]$prefix -eq 0) { 0 } else { [uint32]::MaxValue -shl (32 - [int]$prefix) }
        $mask = "$(($maskInt -shr 24) -band 255).$(($maskInt -shr 16) -band 255).$(($maskInt -shr 8) -band 255).$($maskInt -band 255)"

        # @() ensures a single-node region stays a JSON array (not a bare object)
        $nodes = @(foreach ($node in $region.nodes) {
                $dcMode = if ($node.role -eq 'DomainController') {
                    if ($node.static_ip -eq $forestDcIp) { 'Forest' } else { 'Replica' }
                }
                else { '' }

                $ipBytes = [System.Net.IPAddress]::Parse($node.static_ip).GetAddressBytes()
                $mac = "52:54:$($ipBytes[0].ToString('x2')):$($ipBytes[1].ToString('x2')):$($ipBytes[2].ToString('x2')):$($ipBytes[3].ToString('x2'))"

                [ordered]@{
                    hostname   = $node.hostname
                    role       = $node.role
                    static_ip  = $node.static_ip
                    mac_address= $mac
                    box_name   = $node['_box_name']
                    box_path   = $node['_box_path']
                    cpus       = $node.cpus ?? 2
                    memory_mb  = $node.memory_mb ?? 2048
                    dns_server = $forestDcIp
                    dc_mode    = $dcMode
                    primary    = ($node.static_ip -eq $forestDcIp).ToString().ToLower()
                }
                $nodeIndex++
            })

        [ordered]@{
            name          = $region.name
            network       = $network
            bridge        = "br$regionIndex"   # Linux bridge for this region (br0, br1, …)
            netmask       = $mask
            prefix_length = $prefix
            gateway       = $gateway
            nodes         = $nodes
        }
        $regionIndex++
    } # end foreach region
} # end & scriptblock

# ── 5. Remove orphaned Vagrant nodes ──────────────────────────────────────────

Write-Step 'Checking for removed VMs...'
$configuredHosts = $allNodes | Select-Object -ExpandProperty hostname
$vagrantDir = Join-Path $PSScriptRoot '.vagrant/machines'
if (Test-Path $vagrantDir) {
    $existingMachines = Get-ChildItem -Path $vagrantDir -Directory | Select-Object -ExpandProperty Name
    $orphans = $existingMachines | Where-Object { $_ -notin $configuredHosts }
    
    foreach ($orphan in $orphans) {
        Write-Host "  🗑️  Orphaned VM detected: $orphan. Destroying..." -ForegroundColor Yellow
        
        # We run destroy *before* the Vagrantfile is regenerated so Vagrant still knows about it
        & vagrant destroy $orphan -f
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ⚠️  Failed to cleanly destroy $orphan. Forcibly cleaning Vagrant state..." -ForegroundColor Red
        } else {
            Write-Ok "Cleanly destroyed $orphan"
        }
        
        $orphanDir = Join-Path $vagrantDir $orphan
        if (Test-Path $orphanDir) {
            Remove-Item -Path $orphanDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (@($orphans).Count -eq 0) {
        Write-Ok 'No orphaned VMs found'
    }
} else {
    Write-Ok 'No existing Vagrant state found'
}

# ── 6. Render Vagrantfile from ERB template ───────────────────────────────────

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

# ── 7. Print deployment plan ──────────────────────────────────────────────────

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

# ── 8. Execute vagrant up (networking + boot only) ───────────────────────────

if (-not $WhatIfPreference) {
    # ── 8. Pre-flight: verify bridge IPs are free ──────────────────────────────
    # A rogue QEMU process from a previous run can hold the IP even after
    # 'vagrant destroy'. Fail fast here if the IP responds to ping.
    Write-Step 'Pre-flight: checking bridge IPs are free...'
    $allNodes = $regions | ForEach-Object { $_.nodes }
    $ipErrors = @()
    foreach ($n in $allNodes) {
        $ip = $n.static_ip
        $ping = Test-Connection -ComputerName $ip -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            $ipErrors += "  IP $ip ($($n.hostname)) is already responding to ping!"
        } else {
            Write-Ok "  IP $ip ($($n.hostname)) is free"
        }
    }
    if ($ipErrors.Count -gt 0) {
        Write-Host "`n  ⚠️  Warning: one or more IPs are already active:" -ForegroundColor Yellow
        $ipErrors | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        Write-Host "`n  Proceeding anyway..." -ForegroundColor Yellow
    }

    # ── 9. Execute vagrant up (networking + boot only) ───────────────────────────

    Write-Step "Running: vagrant up --provider=$Provider --no-parallel"
    & vagrant up --provider=$Provider --no-parallel
    if ($LASTEXITCODE -ne 0) { throw "vagrant up failed with exit code $LASTEXITCODE" }
    Write-Ok 'All VMs are up and reachable via SSH'

    # ── 8. SSH-based provisioning (DC nodes first, in topology order) ─────────
    #
    # Vagrant has NO provisioners. All guest configuration is performed here
    # by calling Provision-DomainController.ps1 (and future role scripts) over
    # SSH using sshpass. Forest DCs must be provisioned before Replica DCs.

    $provisionerScript = Join-Path $PSScriptRoot 'scripts\Provision-DomainController.ps1'
    $provisionersDir   = Join-Path $PSScriptRoot 'provisioners'

    # Gather DC nodes in topology order (forest root first, replicas after)
    $dcNodes = foreach ($r in $regions) {
        foreach ($n in $r.nodes) {
            if ($n.role -eq 'DomainController') {
                [pscustomobject]@{
                    Region = $r
                    Node   = $n
                }
            }
        }
    }
    # Stable sort: Forest before Replica
    $dcNodes = $dcNodes | Sort-Object { if ($_.Node.dc_mode -eq 'Forest') { 0 } else { 1 } }

    foreach ($entry in $dcNodes) {
        $r = $entry.Region
        $n = $entry.Node

        Write-Step "Provisioning DC: $($n.hostname) [$($n.dc_mode)] at $($n.static_ip)"

        $provArgs = @{
            FilePath     = 'pwsh'
            ArgumentList = @(
                '-File', $provisionerScript,
                '-Hostname',        $n.hostname,
                '-StaticIP',        $n.static_ip,
                '-PrefixLength',    $r.prefix_length,
                '-Gateway',         $r.gateway,
                '-DnsServer',       $n.dns_server,
                '-DomainName',      $domainName,
                '-AdminUser',       $adminUser,
                '-AdminPassword',   $adminPassword,
                '-DcMode',          $n.dc_mode,
                '-ProvisionersDir', $provisionersDir
            )
            NoNewWindow  = $true
            PassThru     = $true
            Wait         = $true
        }

        $proc = Start-Process @provArgs
        if ($proc.ExitCode -ne 0) {
            throw "Provisioning failed for $($n.hostname) (exit $($proc.ExitCode))"
        }

        Write-Ok "$($n.hostname) provisioning complete"
    }

    Write-Host ''
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    Write-Host '  All Domain Controllers provisioned.' -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    Write-Host ''

    # ── 11. SSH-based provisioning — SQL Server nodes ──────────────────────────
    #
    # Runs after all DC nodes are fully provisioned (domain is live).
    # Each SQL node: rename → static IP → domain join → CompleteImage → dbatools.

    $sqlScript = Join-Path $PSScriptRoot 'scripts\Provision-SqlServer.ps1'

    $sqlNodes = foreach ($r in $regions) {
        foreach ($n in $r.nodes) {
            if ($n.role -eq 'SQLServer') {
                [pscustomobject]@{ Region = $r; Node = $n }
            }
        }
    }

    $logsDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

    $sqlProcesses = @()

    foreach ($entry in $sqlNodes) {
        $r = $entry.Region
        $n = $entry.Node

        $logFile = Join-Path $logsDir "provision-$($n.hostname).log"
        $errFile = Join-Path $logsDir "provision-$($n.hostname).err"
        Write-Step "Provisioning SQL in background: $($n.hostname) at $($n.static_ip)"
        Write-Host "  ℹ️   Watch logs: tail -f `"$logFile`" `"$errFile`"" -ForegroundColor Cyan

        $sqlArgs = @{
            FilePath               = 'pwsh'
            ArgumentList           = @(
                '-File', $sqlScript,
                '-Hostname',        $n.hostname,
                '-StaticIP',        $n.static_ip,
                '-PrefixLength',    $r.prefix_length,
                '-Gateway',         $r.gateway,
                '-DcIpAddress',     $n.dns_server,
                '-DomainName',      $domainName,
                '-AdminUser',       $adminUser,
                '-AdminPassword',   $adminPassword,
                '-ProvisionersDir', $provisionersDir
            )
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $logFile
            RedirectStandardError  = $errFile
        }

        $proc = Start-Process @sqlArgs
        $sqlProcesses += [pscustomobject]@{
            Hostname = $n.hostname
            Process  = $proc
            LogFile  = $logFile
        }
    }

    if ($sqlProcesses.Count -gt 0) {
        Write-Host "`n  Waiting for all SQL provisioning processes to complete..." -ForegroundColor Cyan

        $pending = @()
        $pending += $sqlProcesses
        $failedNodes = @()

        while ($pending.Count -gt 0) {
            Start-Sleep -Seconds 5
            # Traverse array backwards to safely build the new list of remaining processes
            $stillPending = @()
            for ($i = 0; $i -lt $pending.Count; $i++) {
                $p = $pending[$i]
                if ($p.Process.HasExited) {
                    if ($p.Process.ExitCode -ne 0) {
                        Write-Host "    ❌  $($p.Hostname) provisioning failed (exit $($p.Process.ExitCode)). See $($p.LogFile)" -ForegroundColor Red
                        $failedNodes += $p.Hostname
                    } else {
                        Write-Ok "$($p.Hostname) provisioning complete"
                    }
                } else {
                    $stillPending += $p
                }
            }
            $pending = $stillPending
        }

        if ($failedNodes.Count -gt 0) {
            throw "SQL provisioning failed for nodes: $($failedNodes -join ', ')"
        }
    }

    Write-Host ''
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    Write-Host '  Lab deployment complete!' -ForegroundColor Green
    Write-Host "  Use 'vagrant ssh <hostname>' to connect." -ForegroundColor Green
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  [-WhatIf] vagrant up and provisioning skipped.' -ForegroundColor Yellow
}

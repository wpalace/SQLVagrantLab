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
    Write-Step "Starting background WinRM workaround job..."
    $sshPorts = @()
    foreach ($r in $regions) { foreach ($n in $r.nodes) { $sshPorts += $n.ssh_port } }
    
    $logFile = Join-Path $PWD 'WinRM-SSH-Workaround.log'
    Write-Step "Logging background SSH task to $logFile"

    $WinRMJob = Start-Job -ScriptBlock {
        param([string]$PortsStr, [string]$LogFile)
        [int[]]$Ports = $PortsStr -split ',' | Where-Object { $_ -ne '' }
        $resolved = @{}
        $maxRetries = 200 # Roughly ~33 minutes of trying per port
        $attempts = @{}

        Add-Content -Path $LogFile -Value "`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====== STARTED BACKGROUND SSH JOB FOR PORTS: $($Ports -join ',') ======"

        while ($resolved.Count -lt $Ports.Count) {
            Start-Sleep -Seconds 10
            foreach ($port in $Ports) {
                if (-not $attempts.ContainsKey($port)) { $attempts[$port] = 0 }
                if (-not $resolved.ContainsKey($port) -and $attempts[$port] -lt $maxRetries) {
                    $attempts[$port]++
                    $cmdTxt = 'powershell.exe -Command "New-ItemProperty -Path ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWORD -Force; Restart-Service WinRM"'
                    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    Add-Content -Path $LogFile -Value "[$ts] Attempting SSH on port $port (Attempt $($attempts[$port])/$maxRetries)..."
                    
                    try {
                        # Capture verbose SSH output (stderr and stdout combined) along with command execution
                        $sshpassCmd = "sshpass -p 'vagrant' ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p $port vagrant@localhost $cmdTxt"
                        Add-Content -Path $LogFile -Value "[$ts] Executing: $sshpassCmd"
                        
                        $output = Invoke-Expression "$sshpassCmd 2>&1"
                        $exitCode = $LASTEXITCODE
                        
                        $outputStr = [string]($output -join "`n")
                        Add-Content -Path $LogFile -Value "[$ts] (Port $port) Exit Code: $exitCode`nOutput:`n$outputStr"
                        
                        # SSH can return 0 sometimes if it failed to resolve or connect in weird scenarios, so we ensure it succeeded.
                        if ($exitCode -eq 0 -and $outputStr -notmatch "Connection refused" -and $outputStr -notmatch "Connection timed out") {
                            $resolved[$port] = $true
                            Add-Content -Path $LogFile -Value "[$ts] ---> WINRM FIX SUCCESSFULLY APPLIED FOR PORT $port <---"
                        }
                    }
                    catch {
                        Add-Content -Path $LogFile -Value "[$ts] (Port $port) Internal script error: $_"
                    }
                }
            }
        }
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====== ALL SSH TASKS COMPLETED. EXITING ====== `n"
    } -ArgumentList ($sshPorts -join ','), $logFile

    try {
        Write-Step "Running: vagrant up --provider=$Provider --no-parallel"
        & vagrant up --provider=$Provider --no-parallel
        if ($LASTEXITCODE -ne 0) { throw "vagrant up failed with exit code $LASTEXITCODE" }
        Write-Host "`n  Lab is up! Use 'vagrant ssh <hostname>' to connect.`n" -ForegroundColor Green
    }
    finally {
        Write-Verbose "Stopping WinRM background job..."
        Stop-Job $WinRMJob -ErrorAction SilentlyContinue
        Remove-Job $WinRMJob -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host '  [-WhatIf] vagrant up skipped.' -ForegroundColor Yellow
}

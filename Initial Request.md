# SqlVagrantLab — Complete Project Specification

## Project Overview & Success Criteria

Build an automated, multi-region SQL Server lab that deploys entirely from a single YAML configuration file. The project targets a Linux host machine running QEMU/KVM.

**Success Criteria:**
- **Functional Accuracy:** The deployed lab must exactly match the desired state defined in `config.yaml` (regions, nodes, roles, IPs, OS/SQL versions).
- **Turnkey Execution:** A single script (`Deploy-Lab.ps1`) handles the entire deployment after prerequisites are met.
- **High-Speed Deployment:** VMs are created from pre-built Packer `.box` files — SQL Server binaries are pre-staged at image build time via `PrepareImage`, so VM boot is fast and offline-capable.
- **Provider Abstraction:** The Vagrant provider is swappable (QEMU ↔ Hyper-V ↔ GCP future) through a single flag without touching provisioning logic.

---

## Technical Stack

| Layer | Technology |
|---|---|
| **Virtualization** | QEMU/KVM (primary); Hyper-V stub included |
| **VM Orchestration** | HashiCorp Vagrant + `vagrant-qemu` plugin |
| **Image Building** | HashiCorp Packer ≥ 1.10.0 (HCL2 templates) |
| **Scripting** | PowerShell 7.5.1 (`pwsh`) — host and guest |
| **SQL Automation** | `dbatools` PowerShell module (≥ 2.0.0) |
| **YAML Parsing** | `powershell-yaml` PS module |
| **Vagrantfile Generation** | Ruby ERB template rendered by Deploy-Lab.ps1 using the Ruby bundled with Vagrant |
| **Guest Communicator** | OpenSSH (not WinRM) — baked into every Packer image |
| **OS Options** | Windows Server 2022, Windows Server 2025 (Evaluation ISOs) |
| **SQL Options** | SQL Server 2022 Developer, SQL Server 2025 Developer |

---

## Repository Layout

```
SqlVagrantLab/
├── Install-Prerequisites.ps1      # One-time host setup script
├── Deploy-Lab.ps1                 # Master deployment script
├── config.yaml                    # Lab topology — single source of truth
│
├── packer/
│   ├── windows-sql.pkr.hcl        # Packer HCL2 template (parameterized)
│   ├── vagrant_box_template.rb    # Embedded Vagrantfile inside each .box
│   ├── answer_files/
│   │   ├── win2022/Autounattend.xml
│   │   └── win2025/Autounattend.xml
│   ├── scripts/
│   │   ├── configure-openssh.ps1  # Installs + hardens OpenSSH during Packer build
│   │   └── prepare-image.ps1      # Runs SQL PrepareImage + Sysprep
│   └── variables/
│       ├── win2022-sql2022.pkrvars.hcl
│       ├── win2022-sql2025.pkrvars.hcl
│       ├── win2025-sql2022.pkrvars.hcl
│       └── win2025-sql2025.pkrvars.hcl
│
├── vagrant/
│   ├── Vagrantfile.erb            # ERB template; rendered at deploy time
│   └── lib/
│       ├── provider_qemu.rb       # QEMU configure_provider() implementation
│       └── provider_hyperv.rb     # Hyper-V stub (raises NotImplementedError)
│
└── provisioners/                  # PowerShell scripts run by Vagrant post-boot
    ├── Set-StaticIP.ps1
    ├── Set-Hostname.ps1
    ├── Install-ADDSForest.ps1
    ├── New-LabAdminAccount.ps1
    ├── Join-Domain.ps1
    ├── Complete-SqlImage.ps1
    └── Configure-SqlServer.ps1
```

---

## Configuration Schema (`config.yaml`)

```yaml
global:
  domain_name: test.dev           # FQDN — default: test.dev
  admin_user: admin               # Domain admin username — default: admin
  admin_password: "P@ssw0rd"     # Used for domain admin, sa, and service accounts
  box_library_path: "/opt/vagrant-boxes"   # Host path where .box files are stored
  media_path: "/root/packer-media"         # Host path where ISOs live

regions:
  - name: RegionA
    network: 192.168.10.0/24      # Each region gets its own isolated subnet
    nodes:
      - hostname: dc01
        role: DomainController    # "DomainController" or "SQLServer"
        os_version: "2022"        # "2022" or "2025"
        static_ip: 192.168.10.10
        cpus: 2
        memory_mb: 2048

      - hostname: sql01
        role: SQLServer
        os_version: "2022"
        sql_version: "2022"       # "2022" or "2025" — Developer Edition only
        static_ip: 192.168.10.20
        cpus: 4
        memory_mb: 4096

  # - name: RegionB              # Additional regions can be uncommented/added
  #   ...
```

**Box naming convention:** `win{os_version}-sql{sql_version}` for SQL nodes (e.g. `win2022-sql2022`), `win{os_version}-dc` for domain controller nodes. The box files live at `{box_library_path}/{box_name}.box`.

**Domain controller detection:** The first `DomainController` node found (scanning regions top-to-bottom) becomes the forest root DC. All other DC nodes are promoted as replica DCs. All SQL nodes join the domain after the forest DC is up.

---

## Phase 1: One-Time Host Setup (`Install-Prerequisites.ps1`)

Run once on the Linux host with `sudo pwsh -File Install-Prerequisites.ps1`.

**Installs (in order):**
1. QEMU/KVM + utilities (`qemu-system-x86`, `qemu-utils`, `libvirt-daemon-system`, etc.) — adds the invoking user to the `kvm` and `libvirt` groups
2. HashiCorp Packer (via official HashiCorp apt/dnf repo)
3. HashiCorp Vagrant (via official HashiCorp apt/dnf repo)
4. `vagrant-qemu` Vagrant plugin
5. PowerShell 7.5.1 (`pwsh`) via Microsoft package repo
6. `powershell-yaml` PowerShell module

**Downloads ISOs to `~/packer-media` (default):**
- Windows Server 2022 Evaluation ISO (`WinServer2022Eval.iso`)
- Windows Server 2025 Evaluation ISO (`WinServer2025Eval.iso`)
- SQL Server 2022 Developer ISO (`SQLServer2022-Dev.iso`)
- SQL Server 2025 Developer ISO (`SQLServer2025-Dev.iso`) — via bootstrapper `.exe` (Windows-only; on Linux, the bootstrapper is downloaded and the user is given manual instructions to run it on Windows or via Wine)

**Flags:** `-MediaPath <dir>` (override ISO download location), `-SkipDownloads` (skip downloads if ISOs already present), `-DryRun` (preview only).

Prints a readiness summary at the end; exits non-zero if anything is missing.

---

## Phase 2: Packer Image Builds

### Packer Template (`packer/windows-sql.pkr.hcl`)

**Plugins required:** `hashicorp/qemu ≥ 1.1.0`, `hashicorp/vagrant ≥ 1.1.0`

**Key QEMU source settings (hard-won, must be preserved):**
- `machine_type = "pc"` (i440fx) — **NOT `q35`**. q35 has no ISA floppy controller, so the `-fda` flag is ignored and Windows PE never reads `Autounattend.xml`.
- `disk_interface = "ide"` — **NOT `virtio-scsi`**. Windows PE has no built-in virtio-scsi driver and cannot see the disk.
- `accelerator = "kvm"` — requires `/dev/kvm` access on the host.
- `net_device = "e1000"` — more compatible than virtio-net during OS install.
- `communicator = "winrm"` — WinRM is used *only* during the Packer build phase. The finished image uses OpenSSH at runtime.
- `winrm_username = "vagrant"`, `winrm_password = "vagrant"`, `winrm_timeout = "90m"`
- `boot_command = ["<wait5s>"]` — minimal; Windows autoinstall is driven by `Autounattend.xml` on the floppy.

**Floppy contents (injected via `-fda`):**
- `answer_files/win{os_version}/Autounattend.xml`
- `scripts/configure-openssh.ps1`
- `scripts/prepare-image.ps1`

**SQL ISO delivery:** mounted as a second CD-ROM via `qemuargs`:
```hcl
qemuargs = [["-drive", "file=${var.sql_iso_path},media=cdrom,index=1,readonly=on"]]
```
The SQL ISO is typically visible inside Windows as drive `E:`.

**Build steps:**
1. `configure-openssh.ps1` — installs OpenSSH Server, sets PowerShell 7 as the default SSH shell, seeds the Vagrant insecure public key, opens TCP 22 in Windows Firewall, hardens `sshd_config`.
2. `prepare-image.ps1` — runs `setup.exe /ACTION=PrepareImage /FEATURES=SQLEngine,FullText,Conn /INSTANCEID=MSSQLSERVER /INSTANCENAME=MSSQLSERVER`, then runs Sysprep (`/generalize /oobe /shutdown /quiet`). Packer captures the shutdown.
3. **Post-processor:** `vagrant` post-processor packages the `.qcow2` as a `.box` file at `{output_dir}/{box_name}.box`, using `vagrant_box_template.rb` as the embedded Vagrantfile (sets `communicator = "ssh"`).

### Variable Files (`packer/variables/`)

One `.pkrvars.hcl` file per OS×SQL combination:

```hcl
# win2025-sql2022.pkrvars.hcl example
os_version   = "2025"
sql_version  = "2022"
box_name     = "win2025-sql2022"
os_iso_path  = "/root/packer-media/WinServer2025Eval.iso"
sql_iso_path = "/root/packer-media/SQLServer2022-Dev.iso"
output_dir   = "/opt/vagrant-boxes"
cpus         = 4
memory_mb    = 4096
```

**Build command:**
```bash
cd packer/
packer init .
packer build -var-file=variables/win2022-sql2022.pkrvars.hcl .
```

---

## Phase 3: Lab Deployment (`Deploy-Lab.ps1`)

**Command:**
```powershell
pwsh -File Deploy-Lab.ps1                             # default: QEMU provider
pwsh -File Deploy-Lab.ps1 -Provider hyperv            # Hyper-V provider
pwsh -File Deploy-Lab.ps1 -WhatIf                    # Preview only, no vagrant up
pwsh -File Deploy-Lab.ps1 -ConfigPath ./my-lab.yaml  # Custom config file
```

**Steps performed by `Deploy-Lab.ps1`:**

1. **Parse `config.yaml`** using the `powershell-yaml` module (auto-installed if missing).
2. **Validate `.box` files** — for every node in every region, compute the expected box name and verify `{box_library_path}/{box_name}.box` exists. Abort with a helpful error listing all missing boxes if any are absent.
3. **Check `vagrant-qemu` plugin** — install it automatically if not present (QEMU provider only).
4. **Build topology model** — compute netmask from CIDR prefix, compute gateway (`.1` address of each subnet), identify the forest root DC (first DomainController node), classify each DC as `Forest` or `Replica`.
5. **Render `Vagrantfile`** — serializes the topology model to JSON, pipes it into a Ruby one-liner that loads and renders `vagrant/Vagrantfile.erb` via ERB. The rendered Vagrantfile is written to the project root.
6. **Print deployment plan** — human-readable table of regions, nodes, IPs, and box names.
7. **Run `vagrant up --provider={Provider}`** (skipped if `-WhatIf`).

---

## Phase 4: VM Provisioning (Vagrant)

The generated Vagrantfile applies these provisioners **in order** to every VM:

### Common (all roles)

| Step | Script | Notes |
|---|---|---|
| 1 | `Set-StaticIP.ps1` | Identifies the non-NAT NIC (excludes `10.0.2.x`), removes DHCP, assigns static IP/gateway/DNS |
| 2 | `Set-Hostname.ps1` | `Rename-Computer`; Vagrant triggers a reboot (`reboot: true`) |

### Domain Controller nodes

| Step | Script | Notes |
|---|---|---|
| 3a | `Install-ADDSForest.ps1` | Installs `AD-Domain-Services` + `DNS` Windows features; promotes to DC.<br>**Forest mode:** `Install-ADDSForest` with `WinThreshold` forest/domain mode.<br>**Replica mode:** waits up to 10 min for the forest DC (ICMP + LDAP:389), then `Install-ADDSDomainController`. Vagrant reboots. |
| 3b | `New-LabAdminAccount.ps1` | *(Forest DC only)* Creates the `admin` user in AD, adds to Domain Admins + Enterprise Admins + Schema Admins, sets password-never-expires. |

### SQL Server nodes

| Step | Script | Notes |
|---|---|---|
| 3a | `Join-Domain.ps1` | Waits up to 10 min for DC reachability (ICMP + LDAP:389 ping), updates DNS to point at DC IP, calls `Add-Computer`. Vagrant reboots. |
| 3b | `Complete-SqlImage.ps1` | Locates `setup.exe` under `%ProgramFiles%\Microsoft SQL Server\*\Setup Bootstrap\*\`. Runs `/ACTION=CompleteImage /EDITION=Developer /INSTANCENAME=MSSQLSERVER` with the domain service account and `sa` password. Restarts `MSSQLSERVER` service. |
| 3c | `Configure-SqlServer.ps1` | Installs `dbatools` (Scope AllUsers) if absent. Calls:<br>• `Enable-DbaTcpIp` (port 1433)<br>• `Set-DbaFirewallRule -Type AllSqlServices`<br>• `Set-DbaMaxMemory` (auto-calculated safe limit)<br>• `Test-DbaSpn` → `Register-DbaSpn` for missing SPNs<br>• `Restart-DbaService` (Engine)<br>• `Get-DbaService` health check (throws if Engine not Running) |

---

## Provider Abstraction

The provider is abstracted via the `configure_provider(machine, opts)` Ruby function:

- **`vagrant/lib/provider_qemu.rb`** — active QEMU implementation. Uses `vagrant-qemu` plugin with `q35` machine type + OVMF UEFI firmware (searches common distro paths; falls back to SeaBIOS with a warning). Enables KVM via `-enable-kvm` extra arg.
- **`vagrant/lib/provider_hyperv.rb`** — stub. Raises `NotImplementedError` to prevent accidental use before Hyper-V networking is fully designed.

Switching providers requires only changing the `-Provider` flag on `Deploy-Lab.ps1`. The ERB template selects the correct `require_relative "lib/provider_{provider}"` line automatically.

---

## Networking Architecture

- Each region gets a dedicated **host-only private network** with its own `/24` subnet.
- The gateway is always the `.1` address of the subnet (e.g. `192.168.10.1`).
- All VMs in a region have a static IP assigned by `Set-StaticIP.ps1` on first boot.
- All non-DC nodes point their DNS at the forest root DC's IP.
- Cross-region routing within QEMU relies on standard QEMU networking; future work may require explicit routing rules for cross-region AD replication.

---

## Known Constraints & Important Notes

- **QEMU `machine_type = "pc"`:** The Packer build uses the older i440fx machine type (not q35) because q35 lacks an ISA floppy controller, which is required to deliver `Autounattend.xml` to Windows PE via Packer's `-fda` mechanism.
- **`disk_interface = "ide"`:** Windows PE cannot see virtio-scsi disks without a driver injection step. IDE is used to keep the image build simple.
- **WinRM → OpenSSH transition:** Packer communicates with the build VM via WinRM. The finished boxes use OpenSSH exclusively — there is no WinRM dependency at Vagrant runtime.
- **SQL 2025 ISO bootstrapper:** The SQL Server 2025 Developer Edition ISO requires a Windows bootstrapper `.exe` to download. On Linux hosts, `Install-Prerequisites.ps1` downloads the bootstrapper and prints instructions for running it on Windows (or via Wine).
- **`/ACTION=PrepareImage` + `/ACTION=CompleteImage` pattern:** SQL Server binaries are staged during Packer (PrepareImage), then finalized with the real hostname and domain account after the VM is named and domain-joined (CompleteImage). This is what makes pre-built images work across arbitrary domain names and hostnames.
- **Sysprep:** Runs at the end of `prepare-image.ps1`. Do not invoke `Start-Process -Wait` for Sysprep — Packer detects the shutdown directly.
- **`vagrant-qemu` plugin version:** Ensure a compatible version with your Vagrant release. The plugin is auto-installed by `Deploy-Lab.ps1` if missing.
- **KVM access:** The host user must be in the `kvm` group. `Install-Prerequisites.ps1` handles this, but a logout/login is required before the group membership takes effect.

---

## End-to-End Walkthrough (Ideal Happy Path)

```bash
# 1. Clone the repo on a Linux host with KVM support
git clone <repo> SqlVagrantLab && cd SqlVagrantLab

# 2. One-time host setup (installs all tools + downloads ISOs)
sudo pwsh -File Install-Prerequisites.ps1
# Log out and back in for kvm group membership to take effect

# 3. Build required Packer images (run once per OS×SQL combination needed)
cd packer
packer init .
packer build -var-file=variables/win2022-sql2022.pkrvars.hcl .
packer build -var-file=variables/win2022-dc.pkrvars.hcl .   # DC-only box (no SQL)
cd ..

# 4. Edit config.yaml to define your desired topology

# 5. Deploy the lab
pwsh -File Deploy-Lab.ps1

# 6. Connect
vagrant ssh dc01
vagrant ssh sql01

# 7. Tear down
vagrant destroy -f
```

---

## Future Roadmap

- **Hyper-V provider:** Implement `vagrant/lib/provider_hyperv.rb` (virtual switch naming, networking).
- **GCP provider:** Port image builds to `packer-plugin-googlecompute`; adapt Vagrant to use a GCP provider.
- **Multi-region AD routing:** Explicit cross-region routes for replica DC replication traffic.
- **AG/FCI:** Add Always On Availability Group or Failover Cluster Instance topology options to `config.yaml`.
- **Windows-hosted build:** Support running `Deploy-Lab.ps1` from a Windows host with Hyper-V as the first-class provider.
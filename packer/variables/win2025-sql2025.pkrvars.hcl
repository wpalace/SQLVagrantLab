# packer/variables/win2025-sql2025.pkrvars.hcl
# Packer variable overrides for Windows Server 2025 + SQL Server 2025 Developer

os_version  = "2025"
sql_version = "2025"
box_name    = "win2025-sql2025"

os_iso_path  = "/opt/packer-media/WinServer2025Eval.iso"
sql_iso_path = "/opt/packer-media/SQLServer2025-Dev.iso"

os_iso_checksum = ""

cpus      = 4
memory_mb = 4096

output_dir = "/opt/vagrant-boxes"

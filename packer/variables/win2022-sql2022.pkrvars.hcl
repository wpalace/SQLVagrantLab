# packer/variables/win2022-sql2022.pkrvars.hcl
# Packer variable overrides for Windows Server 2022 + SQL Server 2022 Developer

os_version  = "2022"
sql_version = "2022"
box_name    = "win2022-sql2022"

# Update these paths to match your host's media directory (see Install-Prerequisites.ps1)
os_iso_path  = "/opt/packer-media/WinServer2022Eval.iso"
sql_iso_path = "/opt/packer-media/SQLServer2022-Dev.iso"

# Optional: populate after first download with: (Get-FileHash <file> -Algorithm SHA256).Hash
os_iso_checksum = ""

# VM sizing during Packer build (can differ from runtime sizing in config.yaml)
cpus      = 4
memory_mb = 4096

# Output location — must match box_library_path in config.yaml
output_dir = "/opt/vagrant-boxes"

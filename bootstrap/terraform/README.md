# SQLVagrantLab Terraform Deployment

This directory contains the Terraform configuration required to deploy the SQLVagrantLab Ubuntu host VM onto Google Cloud Platform. 

The deployment process involves two primary stages: 
1. **Initialization:** Creating remote GCS buckets to store Terraform state securely, hold your raw ISO files for Packer, and store exported VM snapshots.
2. **Provisioning:** Deploying the actual GCP networking infrastructure and Ubuntu 24.04 VM. The VM uses a custom startup script to automatically configure RDP, PowerShell, clone the lab codebase, and pull down your ISO files.

---

## Deployment Steps

### Step 1: Initialize Cloud Storage Buckets
Before you can run Terraform, you must create the remote state and artifact buckets. A helper script is provided to automate this.

Auth with your GCP credentials, then run the oneshot initialization script, passing it your active GCP Project ID:
```bash
./oneshot/init.sh <your-gcp-project-id>
```
> **Note:** This script automatically generates two files: `backend.tfvars` (containing your state bucket details) and `terraform.tfvars` (containing your ISO/Snapshot bucket names for Terraform variables).

### Step 2: Upload Your Local ISOs
To allow Packer to build the Windows and SQL Server images on the headless cloud VM, you need to upload your `.iso` files to the newly created GCP bucket. 

Run the automated upload script, pointing it to the local directory where your ISO files live:
```bash
./scripts/upload_isos.sh /opt/packer-media/
```

### Step 3: Initialize Terraform
Initialize the Terraform working directory, instructing it to use the `backend.tfvars` configuration generated in Step 1:
```bash
terraform init -upgrade -backend-config=backend.tfvars
```

### Step 4: Apply the Infrastructure
Review the deployment plan and apply the configuration to build the VM:
```bash
terraform apply 
```

---

## Connecting to the Lab Environment

Once `terraform apply` finishes, it will output the public IP address of your new VM. 

**Wait 3-5 minutes** for the automated background bootstrap script to finish installing dependencies, configuring XRDP, and downloading your ISOs.

Then, you can connect using any standard RDP client (like Remmina or Microsoft Remote Desktop):
- **Address:** `<VM_PUBLIC_IP>`
- **Username:** `labuser`
- **Password:** `P@ssw0rd`

Open up exactly where you left off by launching the pre-installed PowerShell Core terminal and running `Install-Prerequisites.ps1` from the `/home/labuser/SQLVagrantLab` directory!

---

## Snapshots and Restoration

If you wish to take snapshots of your running environment, or deploy a fresh environment from a previously exported snapshot archive, please see the [Snapshots Documentation](../snapshots/README.md).

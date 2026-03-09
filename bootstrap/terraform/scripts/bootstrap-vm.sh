#!/usr/bin/env bash
set -e

# Log all output from the startup script
exec > >(tee -a /var/log/bootstrap-vm.log) 2>&1

echo "==== Starting SQLVagrantLab VM Bootstrap ===="

# 1. Update and install basic prerequisites
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wget curl git unzip xrdp xfce4 xfce4-goodies qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils dnsmasq

# CREATE USER FIRST to ensure home directory exists
if ! id "labuser" &>/dev/null; then
    useradd -m -s /bin/bash labuser
fi
# Set the password for labuser to P@ssw0rd so RDP works out of the box
echo "labuser:P@ssw0rd" | chpasswd

# Configure xrdp to use xfce4 now that the home directory exists
echo "xfce4-session" > /home/labuser/.xsession
chown labuser:labuser /home/labuser/.xsession

# Add labuser to necessary groups including sudo
usermod -aG sudo,libvirt,kvm labuser

# Enable Password Authentication for SSH
# We inject a drop-in config for ssh so we don't mess up existing configs
# Naming it 01- ensures it overrides other drop-ins like 50-cloud-init
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/01-labuser-password-auth.conf
systemctl restart ssh

# Restart xrdp and ensure it has access to ssl certificates
adduser xrdp ssl-cert || true
systemctl enable xrdp
systemctl restart xrdp

# 2. Install PowerShell Core
echo "Installing PowerShell Core..."
# Update the list of packages
apt-get update
# Install pre-requisite packages.
apt-get install -y wget apt-transport-https software-properties-common
# Get the version of Ubuntu
source /etc/os-release
# Download the Microsoft repository GPG keys
wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"
# Register the Microsoft repository GPG keys
dpkg -i packages-microsoft-prod.deb
# Delete the the Microsoft repository GPG keys file
rm packages-microsoft-prod.deb
# Update the list of packages after we added packages.microsoft.com
apt-get update
# Install PowerShell
apt-get install -y powershell

# 3. Clone the SQLVagrantLab repository
echo "Cloning SQLVagrantLab repository..."
su - labuser -c "git clone https://github.com/wpalace/SQLVagrantLab.git /home/labuser/SQLVagrantLab"

# 4. Download ISOs from GCS bucket
echo "Downloading ISOs from gs://${iso_bucket_name}..."
# Create the target directory
su - labuser -c "mkdir -p /home/labuser/SQLVagrantLab/packer/"
# Use gsutil to copy the ISOs, running as labuser but using the VM's service account credentials
su - labuser -c "gsutil -m cp gs://${iso_bucket_name}/*.iso /home/labuser/SQLVagrantLab/packer/" || echo "Warning: No ISOs found or download failed."

echo "==== Bootstrapping Complete ===="

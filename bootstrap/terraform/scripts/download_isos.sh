#!/usr/bin/env bash
set -e

# SQLVagrantLab ISO Downloader
# This script must be run on the provisioned SQLVagrantLab VM.
# It automatically finds the attached ISO bucket and downloads the ISOs.

echo "Looking up your assigned SQLVagrantLab ISO bucket..."
ISO_BUCKET_NAME=$(gcloud storage ls 2>/dev/null | grep -o 'gs://sqlvagrantlab-isos-[a-zA-Z0-9-]*' | head -n 1 | tr -d '/' || true)

if [ -z "$ISO_BUCKET_NAME" ]; then
    echo "Error: Could not automatically detect the ISO bucket for this project."
    echo "Please ensure the VM has the correct service account attached."
    exit 1
fi

# We strip the gs:// prefix if grep left it, though grep only caught the domain.
# Actually, the grep grabbed gs://... so let's format it.
# The previous grep grabbed exactly gs://bucket-name, and tr removed the slashes.
# Let's clean that up to be sure.
ISO_BUCKET_NAME=$(gcloud storage ls 2>/dev/null | grep -o 'gs://sqlvagrantlab-isos-[a-zA-Z0-9-]*' | head -n 1)

echo "Found bucket: ${ISO_BUCKET_NAME}"

TARGET_DIR="/opt/packer-media"
echo "Creating target directory ${TARGET_DIR}..."
sudo mkdir -p "${TARGET_DIR}"
sudo chown -R $USER:$USER "${TARGET_DIR}"

echo "Downloading ISOs..."
gsutil -m cp "${ISO_BUCKET_NAME}/*.iso" "${TARGET_DIR}/"

echo "Download complete! ISOs are available in ${TARGET_DIR}."

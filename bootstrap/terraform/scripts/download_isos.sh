#!/usr/bin/env bash
set -e

# SQLVagrantLab ISO Downloader
# This script must be run on the provisioned SQLVagrantLab VM.
# It automatically reads the assigned ISO bucket from the GCP instance metadata.

echo "Looking up your assigned SQLVagrantLab ISO bucket from Instance Metadata..."
ISO_BUCKET_NAME=$(curl -s -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/iso-bucket-name" || true)

if [ -z "$ISO_BUCKET_NAME" ]; then
    echo "Error: Could not retrieve the ISO bucket name from instance metadata."
    echo "Please ensure the VM was provisioned with the 'iso-bucket-name' metadata tag."
    exit 1
fi

echo "Found bucket: ${ISO_BUCKET_NAME}"

TARGET_DIR="/opt/packer-media"
echo "Creating target directory ${TARGET_DIR}..."
sudo mkdir -p "${TARGET_DIR}"
sudo chown -R $USER:$USER "${TARGET_DIR}"

echo "Downloading ISOs..."
gsutil -m cp "gs://${ISO_BUCKET_NAME}/*.iso" "${TARGET_DIR}/"

echo "Download complete! ISOs are available in ${TARGET_DIR}."

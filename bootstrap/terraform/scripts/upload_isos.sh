#!/usr/bin/env bash
set -e

# SQLVagrantLab ISO Uploader
# This script finds the ISO files in a specified directory and uploads them
# to the GCP bucket initialized for this project.

if [ "$#" -ne 1 ]; then
  echo "Usage: ./upload_isos.sh <path_to_iso_directory>"
  echo "Example: ./upload_isos.sh /home/user/Downloads/ISOs"
  exit 1
fi

ISO_DIR=$1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TFVARS_FILE="${SCRIPT_DIR}/../terraform.tfvars"

# Read ISO bucket name from the terraform.tfvars variables file if it exists
if [ -f "${TFVARS_FILE}" ]; then
    ISO_BUCKET_NAME=$(grep 'iso_bucket_name' "${TFVARS_FILE}" | cut -d'"' -f2)
else
    echo "Error: ${TFVARS_FILE} not found. Please run oneshot/init.sh first."
    exit 1
fi

if [ -z "$ISO_BUCKET_NAME" ]; then
    echo "Error: Could not determine ISO bucket name from ${TFVARS_FILE}."
    exit 1
fi

echo "Looking for .iso files in ${ISO_DIR}..."

# Find all .iso files in the specified directory
ISO_FILES=$(find "${ISO_DIR}" -maxdepth 1 -type f -name "*.iso" 2>/dev/null)

if [ -z "$ISO_FILES" ]; then
    echo "Error: No .iso files found in ${ISO_DIR}."
    exit 1
fi

echo "Found the following ISO files:"
echo "$ISO_FILES"
echo ""

# Upload to GCS
for iso_file in $ISO_FILES; do
    iso_filename=$(basename "$iso_file")
    echo "Uploading ${iso_filename} to gs://${ISO_BUCKET_NAME}/..."
    gcloud storage cp "${iso_file}" "gs://${ISO_BUCKET_NAME}/${iso_filename}"
done

echo ""
echo "Upload successful!"
echo "ISOs are now available in gs://${ISO_BUCKET_NAME}/."

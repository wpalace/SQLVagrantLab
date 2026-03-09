#!/usr/bin/env bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: ./export-snapshot-to-bucket.sh <snapshot-name>"
  echo "Example: ./export-snapshot-to-bucket.sh lab-base-installed"
  exit 1
fi

SNAPSHOT_NAME=$1

# Parse terraform.tfvars to find the snapshot bucket name
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TFVARS_FILE="${SCRIPT_DIR}/../terraform/terraform.tfvars"

if [ -f "${TFVARS_FILE}" ]; then
    SNAPSHOT_BUCKET_NAME=$(grep 'snapshot_bucket_name' "${TFVARS_FILE}" | cut -d'"' -f2)
else
    echo "Error: ${TFVARS_FILE} not found. Ensure you ran oneshot/init.sh."
    exit 1
fi

if [ -z "$SNAPSHOT_BUCKET_NAME" ]; then
    echo "Error: snapshot_bucket_name not found in ${TFVARS_FILE}"
    exit 1
fi

# To export a snapshot to GCS, GCP requires us to first create an image from it
IMAGE_NAME="${SNAPSHOT_NAME}-image"

echo "Creating temporary image '${IMAGE_NAME}' from snapshot '${SNAPSHOT_NAME}'..."
gcloud compute images create ${IMAGE_NAME} --source-snapshot=${SNAPSHOT_NAME}

echo "Exporting image '${IMAGE_NAME}' to gs://${SNAPSHOT_BUCKET_NAME}/${SNAPSHOT_NAME}.tar.gz..."
echo "Note: This process may take a while depending on the size of the disk..."

# This exports the image to the bucket as a compressed tar file
gcloud compute images export \
  --destination-uri="gs://${SNAPSHOT_BUCKET_NAME}/${SNAPSHOT_NAME}.tar.gz" \
  --image=${IMAGE_NAME}

echo "Cleaning up temporary image '${IMAGE_NAME}'..."
gcloud compute images delete ${IMAGE_NAME} --quiet

echo "Export complete! Your snapshot is safely archived in the bucket."

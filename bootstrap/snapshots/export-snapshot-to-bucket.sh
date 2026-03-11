#!/usr/bin/env bash
set -e

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: ./export-snapshot-to-bucket.sh <snapshot-name> [project-id]"
  echo "Example: ./export-snapshot-to-bucket.sh lab-base-installed my-gcp-project"
  exit 1
fi

SNAPSHOT_NAME=$1
PROJECT_ID=$2

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project)
fi

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

# Ensure cleanup of the temporary image even if the script fails midway
function cleanup() {
  echo "Cleaning up temporary image '${IMAGE_NAME}' (if it exists)..."
  gcloud compute images delete ${IMAGE_NAME} --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

# If a previous run failed and left the image behind, it will prevent creation
if gcloud compute images describe ${IMAGE_NAME} --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Found orphaned image '${IMAGE_NAME}' from a previous failed run. Removing it..."
  gcloud compute images delete ${IMAGE_NAME} --project="${PROJECT_ID}" --quiet
fi

echo "Creating temporary image '${IMAGE_NAME}' from snapshot '${SNAPSHOT_NAME}'..."
gcloud compute images create ${IMAGE_NAME} --project="${PROJECT_ID}" --source-snapshot=${SNAPSHOT_NAME}

echo "Exporting image '${IMAGE_NAME}' to gs://${SNAPSHOT_BUCKET_NAME}/${SNAPSHOT_NAME}.tar.gz..."
echo "Note: This process may take a while depending on the size of the disk..."

# This exports the image to the bucket as a compressed tar file
gcloud compute images export \
  --project="${PROJECT_ID}" \
  --destination-uri="gs://${SNAPSHOT_BUCKET_NAME}/${SNAPSHOT_NAME}.tar.gz" \
  --image=${IMAGE_NAME}

echo "Export complete! Your snapshot is safely archived in the bucket."

#!/usr/bin/env bash
set -e

# SQLVagrantLab remote state initialization script
# This script creates a Google Cloud Storage bucket for Terraform state
# and writes out a 'backend.tfvars' file for Terraform to use.

if [ -z "$1" ]; then
  echo "Usage: ./init.sh <project_id>"
  echo "Example: ./init.sh my-gcp-project-123"
  exit 1
fi

PROJECT_ID=$1
REGION="us-central1"

# Check if buckets for this project already exist
echo "Checking for existing SQLVagrantLab buckets..."
EXISTING_BUCKET=$(gcloud storage ls --project="${PROJECT_ID}" 2>/dev/null | grep -o 'gs://sqlvagrantlab-tfstate-[a-zA-Z0-9-]*' | head -n 1 || true)

if [ -n "$EXISTING_BUCKET" ]; then
  # Extract the random suffix from the existing bucket name
  # gs://sqlvagrantlab-tfstate-project-id-SUFFIX/ -> SUFFIX
  RANDOM_SUFFIX=$(echo "$EXISTING_BUCKET" | sed -E "s|gs://sqlvagrantlab-tfstate-${PROJECT_ID}-||" | tr -d '/')
  echo "Found existing environment with suffix: ${RANDOM_SUFFIX}. Reusing existing buckets."
  CREATE_BUCKETS=false
else
  # Create a unique bucket name by appending a random string
  echo "No existing environment found. Generating new suffix..."
  RANDOM_SUFFIX=$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)
  CREATE_BUCKETS=true
fi

BUCKET_NAME="sqlvagrantlab-tfstate-${PROJECT_ID}-${RANDOM_SUFFIX}"
ISO_BUCKET_NAME="sqlvagrantlab-isos-${PROJECT_ID}-${RANDOM_SUFFIX}"
SNAPSHOT_BUCKET_NAME="sqlvagrantlab-snapshots-${PROJECT_ID}-${RANDOM_SUFFIX}"

if [ "$CREATE_BUCKETS" = true ]; then
  echo "Creating GCS bucket: ${BUCKET_NAME} in ${REGION} for project ${PROJECT_ID}..."

  # Create the bucket using gcloud
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access

  # Remove soft-delete retention period immediately
  gcloud storage buckets update "gs://${BUCKET_NAME}" --clear-soft-delete

  echo "Creating GCS bucket: ${ISO_BUCKET_NAME} for ISOs..."

  gcloud storage buckets create "gs://${ISO_BUCKET_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access

  # Remove soft-delete retention period immediately
  gcloud storage buckets update "gs://${ISO_BUCKET_NAME}" --clear-soft-delete

  echo "Creating GCS bucket: ${SNAPSHOT_BUCKET_NAME} for Snapshots..."

  gcloud storage buckets create "gs://${SNAPSHOT_BUCKET_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access

  # Remove soft-delete retention period immediately
  gcloud storage buckets update "gs://${SNAPSHOT_BUCKET_NAME}" --clear-soft-delete
else
  echo "Skipping bucket creation logic..."
fi

# Write out the backend variables file
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
BACKEND_FILE="${SCRIPT_DIR}/../backend.tfvars"
echo "bucket = \"${BUCKET_NAME}\"" > "${BACKEND_FILE}"
echo "prefix = \"terraform/state\"" >> "${BACKEND_FILE}"

# Write out a generic variables file for Terraform to use for the ISO bucket
TFVARS_FILE="${SCRIPT_DIR}/../terraform.tfvars"
echo "iso_bucket_name = \"${ISO_BUCKET_NAME}\"" > "${TFVARS_FILE}"
echo "snapshot_bucket_name = \"${SNAPSHOT_BUCKET_NAME}\"" >> "${TFVARS_FILE}"
echo "project_id = \"${PROJECT_ID}\"" >> "${TFVARS_FILE}"

echo ""
echo "Successfully created remote state bucket!"
echo "A backend configuration file has been written to: bootstrap/terraform/backend.tfvars"
echo ""
echo "To initialize Terraform with this remote backend, run:"
echo "  cd .."
echo "  terraform init -backend-config=backend.tfvars"

#!/usr/bin/env bash
set -e

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: ./restore-snapshot.sh <snapshot-name> [project-id]"
  echo "Example: ./restore-snapshot.sh lab-base-installed my-gcp-project"
  exit 1
fi

SNAPSHOT_NAME=$1
INSTANCE_NAME="sqlvagrantlab-host"
PROJECT_ID=$2

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project)
fi

# Find the zone for the instance
ZONE=$(gcloud compute instances list --project="${PROJECT_ID}" --filter="name=${INSTANCE_NAME}" --format="value(zone)" | awk -F/ '{print $NF}')

if [ -z "$ZONE" ]; then
  echo "Error: Instance ${INSTANCE_NAME} not found in project ${PROJECT_ID}."
  exit 1
fi

# Find the current boot disk attached to the instance
OLD_DISK=$(gcloud compute instances describe ${INSTANCE_NAME} --project="${PROJECT_ID}" --zone=${ZONE} --format="value(disks[0].source)" | awk -F/ '{print $NF}')
NEW_DISK="${INSTANCE_NAME}-restored-$(date +%s)"

echo "Stopping instance ${INSTANCE_NAME}..."
gcloud compute instances stop ${INSTANCE_NAME} --project="${PROJECT_ID}" --zone=${ZONE}

echo "Creating new disk '${NEW_DISK}' from snapshot '${SNAPSHOT_NAME}'..."
gcloud compute disks create ${NEW_DISK} \
  --project="${PROJECT_ID}" \
  --source-snapshot=${SNAPSHOT_NAME} \
  --zone=${ZONE} \
  --type=pd-balanced

echo "Detaching old boot disk (${OLD_DISK}) from ${INSTANCE_NAME}..."
gcloud compute instances detach-disk ${INSTANCE_NAME} --project="${PROJECT_ID}" --disk=${OLD_DISK} --zone=${ZONE}

echo "Attaching new boot disk to ${INSTANCE_NAME}..."
gcloud compute instances attach-disk ${INSTANCE_NAME} \
  --project="${PROJECT_ID}" \
  --disk=${NEW_DISK} \
  --zone=${ZONE} \
  --boot

echo "Starting instance ${INSTANCE_NAME}..."
gcloud compute instances start ${INSTANCE_NAME} --project="${PROJECT_ID}" --zone=${ZONE}

echo "Restore complete! VM is back online."
echo "Note: The old disk (${OLD_DISK}) is still available in your GCP project if you need to recover anything from it."

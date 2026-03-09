#!/usr/bin/env bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: ./restore-snapshot.sh <snapshot-name>"
  echo "Example: ./restore-snapshot.sh lab-base-installed"
  exit 1
fi

SNAPSHOT_NAME=$1
INSTANCE_NAME="sqlvagrantlab-host"

# Find the zone for the instance
ZONE=$(gcloud compute instances list --filter="name=${INSTANCE_NAME}" --format="value(zone)" | awk -F/ '{print $NF}')

if [ -z "$ZONE" ]; then
  echo "Error: Instance ${INSTANCE_NAME} not found."
  exit 1
fi

# Find the current boot disk attached to the instance
OLD_DISK=$(gcloud compute instances describe ${INSTANCE_NAME} --zone=${ZONE} --format="value(disks[0].source)" | awk -F/ '{print $NF}')
NEW_DISK="${INSTANCE_NAME}-restored-$(date +%s)"

echo "Stopping instance ${INSTANCE_NAME}..."
gcloud compute instances stop ${INSTANCE_NAME} --zone=${ZONE}

echo "Creating new disk '${NEW_DISK}' from snapshot '${SNAPSHOT_NAME}'..."
gcloud compute disks create ${NEW_DISK} \
  --source-snapshot=${SNAPSHOT_NAME} \
  --zone=${ZONE} \
  --type=pd-balanced

echo "Detaching old boot disk (${OLD_DISK}) from ${INSTANCE_NAME}..."
gcloud compute instances detach-disk ${INSTANCE_NAME} --disk=${OLD_DISK} --zone=${ZONE}

echo "Attaching new boot disk to ${INSTANCE_NAME}..."
gcloud compute instances attach-disk ${INSTANCE_NAME} \
  --disk=${NEW_DISK} \
  --zone=${ZONE} \
  --boot

echo "Starting instance ${INSTANCE_NAME}..."
gcloud compute instances start ${INSTANCE_NAME} --zone=${ZONE}

echo "Restore complete! VM is back online."
echo "Note: The old disk (${OLD_DISK}) is still available in your GCP project if you need to recover anything from it."

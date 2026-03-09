#!/usr/bin/env bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: ./take-snapshot.sh <snapshot-name>"
  echo "Example: ./take-snapshot.sh lab-base-installed"
  exit 1
fi

SNAPSHOT_NAME=$1
INSTANCE_NAME="sqlvagrantlab-host"
PROJECT_ID=$(gcloud config get-value project)

# Find the zone for the instance
ZONE=$(gcloud compute instances list --filter="name=${INSTANCE_NAME}" --format="value(zone)" | awk -F/ '{print $NF}')

if [ -z "$ZONE" ]; then
  echo "Error: Instance ${INSTANCE_NAME} not found in project ${PROJECT_ID}."
  exit 1
fi

# Find the boot disk name
BOOT_DISK=$(gcloud compute instances describe ${INSTANCE_NAME} --zone=${ZONE} --format="value(disks[0].source)" | awk -F/ '{print $NF}')

echo "Taking snapshot of ${BOOT_DISK} (instance ${INSTANCE_NAME}) in zone ${ZONE}..."
gcloud compute disks snapshot ${BOOT_DISK} \
  --zone=${ZONE} \
  --snapshot-names=${SNAPSHOT_NAME} \
  --description="Snapshot taken by take-snapshot.sh"

echo "Snapshot '${SNAPSHOT_NAME}' created successfully."

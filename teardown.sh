#!/bin/bash
# teardown.sh — Slingshot VM Teardown
# Removes a VM and all resources created by deploy_full.sh / setup.sh
set -e

MANAGED_SA="slingshot-manager@slingshot-managed-services.iam.gserviceaccount.com"
STATE_BUCKET="slingshot-states"

echo ""
echo "========================================"
echo "  Slingshot VM Teardown"
echo "========================================"
echo ""

# ─── STEP 1: SELECT PROJECT ───────────────────────────────────────────────────

echo "Fetching your GCP projects..."
mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" 2>/dev/null)

if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "ERROR: No GCP projects found. Please ensure you are logged in."
  exit 1
fi

echo ""
echo "Your available projects:"
for i in "${!PROJECTS[@]}"; do
  echo "  [$((i+1))] ${PROJECTS[$i]}"
done
echo ""

read -rp "Enter the number of the project: " PROJECT_NUM
PROJECT_INDEX=$((PROJECT_NUM - 1))

if [ "$PROJECT_INDEX" -lt 0 ] || [ "$PROJECT_INDEX" -ge "${#PROJECTS[@]}" ]; then
  echo "ERROR: Invalid selection."
  exit 1
fi

USER_PROJECT="${PROJECTS[$PROJECT_INDEX]}"
echo "Selected project: $USER_PROJECT"
gcloud config set project "$USER_PROJECT" --quiet

# ─── STEP 2: SELECT VM ────────────────────────────────────────────────────────

echo ""
echo "Fetching VMs in project '$USER_PROJECT'..."
mapfile -t VMS < <(gcloud compute instances list --project="$USER_PROJECT" --format="value(name)" 2>/dev/null)

if [ ${#VMS[@]} -eq 0 ]; then
  echo "ERROR: No VMs found in project '$USER_PROJECT'."
  exit 1
fi

if [ ${#VMS[@]} -eq 1 ]; then
  VM_NAME="${VMS[0]}"
  echo "Found VM: $VM_NAME"
else
  echo ""
  echo "Available VMs:"
  for i in "${!VMS[@]}"; do
    echo "  [$((i+1))] ${VMS[$i]}"
  done
  echo ""
  read -rp "Enter the number of the VM to delete: " VM_NUM
  VM_INDEX=$((VM_NUM - 1))
  if [ "$VM_INDEX" -lt 0 ] || [ "$VM_INDEX" -ge "${#VMS[@]}" ]; then
    echo "ERROR: Invalid selection."
    exit 1
  fi
  VM_NAME="${VMS[$VM_INDEX]}"
fi

echo "Selected VM: $VM_NAME"

# ─── STEP 3: CONFIRM ─────────────────────────────────────────────────────────

echo ""
echo "=========================================================="
echo "  WARNING: This will permanently delete:"
echo "  - VM: $VM_NAME"
echo "  - Stop schedule policy"
echo "  - Snapshot schedule policy"
echo "  - Cloud Scheduler start job"
echo "  - IAM binding for Slingshot Manager"
echo "  - GCS config file"
echo "=========================================================="
echo ""
read -rp "Type the VM name to confirm deletion: " CONFIRM

if [ "$CONFIRM" != "$VM_NAME" ]; then
  echo "Name does not match. Aborting."
  exit 1
fi

# ─── STEP 4: DETECT ZONE ─────────────────────────────────────────────────────

echo ""
echo ">>> Detecting VM zone..."

VM_ZONE=$(gcloud compute instances list \
  --project="$USER_PROJECT" \
  --filter="name=$VM_NAME" \
  --format="value(zone)" 2>/dev/null | awk -F'/' '{print $NF}')

if [ -z "$VM_ZONE" ]; then
  echo "ERROR: Could not determine zone for VM '$VM_NAME'."
  exit 1
fi
echo "Found in zone: $VM_ZONE"

# ─── STEP 5: DERIVE IDENTIFIERS ──────────────────────────────────────────────

echo ""
echo ">>> Identifying client..."
while [ -z "$NT_USER" ]; do
  read -rp "NinjaTrader username: " NT_USER
done
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)
echo "Client hash: $CLIENT_HASH"
STOP_POLICY="sched-${CLIENT_HASH}-${VM_NAME:0:46}"
SNAPSHOT_POLICY="slingshot-backup-${VM_NAME}-${CLIENT_HASH}"
JOB_NAME="slingshot-vm-start-$CLIENT_HASH"

DISK_NAME=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(disks[0].source)" | awk -F'/' '{print $NF}')

# ─── STEP 6: DETACH AND DELETE STOP SCHEDULE ─────────────────────────────────

echo ""
echo ">>> Removing stop schedule..."

ATTACHED_POLICY=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(resourcePolicies[0])" 2>/dev/null | awk -F'/' '{print $NF}')

if [ -n "$ATTACHED_POLICY" ]; then
  echo "Detaching policy: $ATTACHED_POLICY"
  gcloud compute instances remove-resource-policies "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$USER_PROJECT" \
    --resource-policies="$ATTACHED_POLICY" \
    --quiet
  gcloud compute resource-policies delete "$ATTACHED_POLICY" \
    --region=us-central1 \
    --project="$USER_PROJECT" \
    --quiet 2>/dev/null || true
  echo "Stop schedule removed."
else
  echo "No stop schedule attached."
fi

# Also clean up the named stop policy if it exists independently
gcloud compute resource-policies delete "$STOP_POLICY" \
  --region=us-central1 \
  --project="$USER_PROJECT" \
  --quiet 2>/dev/null || true

# ─── STEP 7: DETACH AND DELETE SNAPSHOT SCHEDULE ─────────────────────────────

echo ""
echo ">>> Removing snapshot schedule..."

if gcloud compute resource-policies describe "$SNAPSHOT_POLICY" \
    --region=us-central1 \
    --project="$USER_PROJECT" \
    --quiet 2>/dev/null; then
  gcloud compute disks remove-resource-policies "$DISK_NAME" \
    --zone="$VM_ZONE" \
    --project="$USER_PROJECT" \
    --resource-policies="$SNAPSHOT_POLICY" \
    --quiet 2>/dev/null || true
  gcloud compute resource-policies delete "$SNAPSHOT_POLICY" \
    --region=us-central1 \
    --project="$USER_PROJECT" \
    --quiet
  echo "Snapshot schedule removed."
else
  echo "No snapshot schedule found."
fi

# ─── STEP 8: DELETE VM ───────────────────────────────────────────────────────

echo ""
echo ">>> Deleting VM: $VM_NAME..."
gcloud compute instances delete "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --quiet
echo "VM deleted."

# ─── STEP 9: DELETE CLOUD SCHEDULER JOB ──────────────────────────────────────

echo ""
echo ">>> Removing Cloud Scheduler start job..."
if gcloud scheduler jobs describe "$JOB_NAME" \
    --location=us-central1 \
    --project="$USER_PROJECT" \
    --quiet 2>/dev/null; then
  gcloud scheduler jobs delete "$JOB_NAME" \
    --location=us-central1 \
    --project="$USER_PROJECT" \
    --quiet
  echo "Scheduler job removed."
else
  echo "No scheduler job found."
fi

# ─── DONE ─────────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "  Teardown complete for '$VM_NAME'."
echo "========================================"
echo ""

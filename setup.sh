#!/bin/bash
# setup.sh — Slingshot VM Manager Setup
# Run this in GCP Cloud Shell

set -e

MANAGED_PROJECT="slingshot-managed-services"
MANAGED_SA="slingshot-manager@slingshot-managed-services.iam.gserviceaccount.com"
FUNCTION_NAME="slingshot-vm-manager"
FUNCTION_URL="https://slingshot-vm-manager-aliasnpt5a-uc.a.run.app"
STATE_BUCKET="slingshot-states"
ZONE_PRIORITY=("us-central1-a" "us-central1-b" "us-central1-f")

echo ""
echo "========================================"
echo "  Slingshot VM Manager Setup"
echo "========================================"
echo ""

# ─── STEP 0: VERIFY AUTH ──────────────────────────────────────────────────────

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -z "$ACTIVE_ACCOUNT" ]; then
  echo "Session expired. Re-authenticating..."
  gcloud auth login --no-launch-browser
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
fi
echo "Authenticated as: $ACTIVE_ACCOUNT"

# ─── STEP 1: SELECT PROJECT ───────────────────────────────────────────────────

echo ""
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

read -rp "Enter the number of the project your VM is in: " PROJECT_NUM
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
  echo "Multiple VMs found:"
  for i in "${!VMS[@]}"; do
    echo "  [$((i+1))] ${VMS[$i]}"
  done
  echo ""
  read -rp "Enter the number of your VM: " VM_NUM
  VM_INDEX=$((VM_NUM - 1))
  if [ "$VM_INDEX" -lt 0 ] || [ "$VM_INDEX" -ge "${#VMS[@]}" ]; then
    echo "ERROR: Invalid selection."
    exit 1
  fi
  VM_NAME="${VMS[$VM_INDEX]}"
fi

echo "Selected VM: $VM_NAME"

# ─── STEP 3: AUTO-DETECT VM CONFIG ───────────────────────────────────────────

echo ""
echo "Reading VM configuration..."

# Find which zone the VM is in
VM_ZONE=""
for ZONE in "${ZONE_PRIORITY[@]}"; do
  if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$USER_PROJECT" &>/dev/null; then
    VM_ZONE="$ZONE"
    break
  fi
done

if [ -z "$VM_ZONE" ]; then
  echo "ERROR: Could not find VM '$VM_NAME' in any us-central1 zone."
  exit 1
fi

echo "Zone: $VM_ZONE"

# Get machine type
MACHINE_TYPE=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(machineType)" | awk -F'/' '{print $NF}')
echo "Machine type: $MACHINE_TYPE"

# Get disk name
DISK_NAME=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(disks[0].source)" | awk -F'/' '{print $NF}')
echo "Disk: $DISK_NAME"

# Get static IP name
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

STATIC_IP_NAME=$(gcloud compute addresses list \
  --project="$USER_PROJECT" \
  --filter="address=$EXTERNAL_IP" \
  --format="value(name)" 2>/dev/null)

if [ -z "$STATIC_IP_NAME" ]; then
  echo "WARNING: No static IP found for this VM. External IP may change after migration."
  STATIC_IP_NAME=""
else
  echo "Static IP: $STATIC_IP_NAME ($EXTERNAL_IP)"
fi

# Get NT username from metadata if available
NT_USER=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(metadata.items[windows-startup-script-ps1])" 2>/dev/null \
  | grep -oP '(?<=Start-Process -FilePath \$exePath -ArgumentList ")[^@]+@[^ ]+' \
  | head -1 || true)

if [ -z "$NT_USER" ]; then
  echo ""
  read -rp "Enter your NinjaTrader username (email): " NT_USER
fi

echo "NinjaTrader user: $NT_USER"

# Calculate client hash
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)
echo "Client hash: $CLIENT_HASH"

# Get user project number and compute service account
PROJECT_NUMBER=$(gcloud projects describe "$USER_PROJECT" --format="value(projectNumber)")
USER_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "User service account: $USER_SA"

# ─── STEP 4: GRANT SLINGSHOT MANAGER ACCESS TO USER PROJECT ──────────────────

echo ""
echo "Granting Slingshot Manager access to project '$USER_PROJECT'..."
gcloud projects add-iam-policy-binding "$USER_PROJECT" \
  --member="serviceAccount:$MANAGED_SA" \
  --role="roles/compute.instanceAdmin.v1" \
  --quiet
echo "Access granted."

# ─── STEP 5: GRANT USER SERVICE ACCOUNT PERMISSION TO INVOKE CENTRAL FUNCTION─

echo ""
echo "Granting invoker permission on central function..."
gcloud functions add-invoker-policy-binding $FUNCTION_NAME \
  --region=us-central1 \
  --member="serviceAccount:${USER_SA}" \
  --project=$MANAGED_PROJECT
echo "Invoker permission granted."

# ─── STEP 6: DETACH AND REPLACE VM SCHEDULE ──────────────────────────────────

echo ""
echo "Configuring VM stop schedule..."

STOP_POLICY="sched-${CLIENT_HASH}-${VM_NAME}"

# Detach any existing resource policies from the VM
EXISTING_POLICY=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(resourcePolicies[0])" 2>/dev/null | awk -F'/' '{print $NF}')

if [ -n "$EXISTING_POLICY" ]; then
  echo "Detaching existing schedule: $EXISTING_POLICY"
  gcloud compute instances remove-resource-policies "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$USER_PROJECT" \
    --resource-policies="$EXISTING_POLICY" \
    --quiet

  # Delete the old policy
  echo "Deleting old policy: $EXISTING_POLICY"
  gcloud compute resource-policies delete "$EXISTING_POLICY" \
    --region=us-central1 \
    --project="$USER_PROJECT" \
    --quiet 2>/dev/null || true
fi

# Delete stop policy if it already exists (for re-runs)
gcloud compute resource-policies delete "$STOP_POLICY" \
  --region=us-central1 \
  --project="$USER_PROJECT" \
  --quiet 2>/dev/null || true

# Create stop-only policy
echo "Creating stop-only schedule (7:00 AM Pacific, Mon-Fri)..."
gcloud compute resource-policies create instance-schedule "$STOP_POLICY" \
  --region=us-central1 \
  --vm-stop-schedule="0 7 * * 1-5" \
  --timezone="America/Los_Angeles" \
  --project="$USER_PROJECT" \
  --quiet

# Attach to VM
gcloud compute instances add-resource-policies "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --resource-policies="$STOP_POLICY" \
  --quiet

echo "Stop schedule attached: 7:00 AM Pacific, Mon-Fri."

# ─── STEP 7: WRITE CONFIG TO GCS ─────────────────────────────────────────────

echo ""
echo "Saving VM configuration..."
CONFIG_PATH="gs://$STATE_BUCKET/clients/client_$CLIENT_HASH/vm_config.json"

cat > /tmp/vm_config.json << EOF
{
  "vm_name": "$VM_NAME",
  "project": "$USER_PROJECT",
  "zone": "$VM_ZONE",
  "machine_type": "$MACHINE_TYPE",
  "disk_name": "$DISK_NAME",
  "static_ip_name": "$STATIC_IP_NAME",
  "region": "us-central1",
  "nt_user": "$NT_USER",
  "client_hash": "$CLIENT_HASH"
}
EOF

gsutil cp /tmp/vm_config.json "$CONFIG_PATH"
echo "Config saved to $CONFIG_PATH"

# ─── STEP 8: CREATE CLOUD SCHEDULER JOB ──────────────────────────────────────

echo ""
echo "Creating Cloud Scheduler job..."

# Enable scheduler API in user project if not already enabled
gcloud services enable cloudscheduler.googleapis.com \
  --project="$USER_PROJECT" --quiet

JOB_NAME="slingshot-vm-start-$CLIENT_HASH"

# Delete existing job if present
gcloud scheduler jobs delete "$JOB_NAME" \
  --location=us-central1 \
  --project="$USER_PROJECT" \
  --quiet 2>/dev/null || true

gcloud scheduler jobs create http "$JOB_NAME" \
  --location=us-central1 \
  --schedule="45 5 * * 1-5" \
  --time-zone="America/Los_Angeles" \
  --uri="$FUNCTION_URL" \
  --message-body="{\"client_hash\":\"$CLIENT_HASH\"}" \
  --headers="Content-Type=application/json" \
  --oidc-service-account-email="$USER_SA" \
  --project="$USER_PROJECT" \
  --quiet

echo "Scheduler job created: $JOB_NAME"

# ─── STEP 8B: CREATE DAILY SNAPSHOT SCHEDULE ─────────────────────────────────

echo ""
echo "Creating daily disk snapshot schedule..."

# Policy name is unique per VM name + user hash
SNAPSHOT_POLICY="slingshot-backup-${VM_NAME}-${CLIENT_HASH}"

# Check if policy already exists
EXISTING_SNAPSHOT=$(gcloud compute resource-policies describe "$SNAPSHOT_POLICY" \
  --region=us-central1 \
  --project="$USER_PROJECT" \
  --format="value(name)" 2>/dev/null || true)

if [ -n "$EXISTING_SNAPSHOT" ]; then
  echo "Snapshot policy already exists, skipping creation."
else
  gcloud compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" \
    --region=us-central1 \
    --max-retention-days=3 \
    --on-source-disk-delete=keep-auto-snapshots \
    --daily-schedule \
    --start-time=07:05 \
    --project="$USER_PROJECT" \
    --quiet

  gcloud compute disks add-resource-policies "$DISK_NAME" \
    --zone="$VM_ZONE" \
    --resource-policies="$SNAPSHOT_POLICY" \
    --project="$USER_PROJECT" \
    --quiet

  echo "Snapshot schedule created: daily at 7:05 AM, 3 days retention."
fi

# ─── STEP 9: CLEANUP ─────────────────────────────────────────────────────────

echo ""
rm -f /tmp/vm_config.json
echo "========================================"
echo "  Setup complete!"
echo "  VM '$VM_NAME' will start at 5:45 AM"
echo "  Pacific time, Monday through Friday."
echo "  VM '$VM_NAME' will stop at 7:00 AM"
echo "  Pacific time, Monday through Friday."
echo "  Daily backup snapshot at 7:05 AM."
echo "========================================"
echo ""

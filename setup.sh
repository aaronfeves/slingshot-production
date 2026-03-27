#!/bin/bash
# setup.sh — Slingshot VM Manager Setup v2.3
# Run this in GCP Cloud Shell

set -e

MANAGED_PROJECT="slingshot-managed-services"
MANAGED_SA="slingshot-manager@slingshot-managed-services.iam.gserviceaccount.com"
FUNCTION_URL="https://slingshot-vm-manager-aliasnpt5a-uc.a.run.app"
STATE_BUCKET="slingshot-states"

# ─── PASSWORD VALIDATION FUNCTIONS ───────────────────────────────────────────

validate_windows_password() {
    local pass="$1"
    local length=${#pass}
    local score=0

    if [ "$length" -lt 8 ]; then
        echo "Password must be at least 8 characters long."
        return 1
    fi

    echo "$pass" | grep -q '[A-Z]' && ((score++))
    echo "$pass" | grep -q '[a-z]' && ((score++))
    echo "$pass" | grep -q '[0-9]' && ((score++))
    echo "$pass" | grep -q '[^a-zA-Z0-9]' && ((score++))

    if [ "$score" -lt 3 ]; then
        echo "Password must contain at least 3 of the following: uppercase letters, lowercase letters, numbers, special characters."
        return 1
    fi

    return 0
}

prompt_password_confirmed() {
    local prompt="$1"
    local validate="$2"
    local result=""

    if [ "$validate" == "windows" ]; then
        echo "Requirements: 8+ characters, must include 3 of: uppercase, lowercase, numbers, special characters" >&2
    fi

    while true; do
        echo "$prompt:" >&2
        read -s pass1; echo "" >&2
        echo "Confirm $prompt:" >&2
        read -s pass2; echo "" >&2

        if [ "$pass1" != "$pass2" ]; then
            echo "Passwords do not match. Please try again." >&2
            continue
        fi

        if [ "$validate" == "windows" ]; then
            if ! validate_windows_password "$pass1"; then
                echo "Please try again." >&2
                continue
            fi
        fi

        result="$pass1"
        break
    done

    echo "$result"
}

echo ""
echo "========================================"
echo "  Slingshot VM Manager Setup v2.3"
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

VM_ZONE=$(gcloud compute instances list \
  --project="$USER_PROJECT" \
  --filter="name=$VM_NAME" \
  --format="value(zone)" 2>/dev/null | awk -F'/' '{print $NF}')

if [ -z "$VM_ZONE" ]; then
  echo "ERROR: Could not determine zone for VM '$VM_NAME'."
  exit 1
fi

VM_REGION=$(echo "$VM_ZONE" | sed 's/-[a-z]$//')
echo "Zone: $VM_ZONE  |  Region: $VM_REGION"

MACHINE_TYPE=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(machineType)" | awk -F'/' '{print $NF}')
echo "Machine type: $MACHINE_TYPE"

DISK_NAME=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(disks[0].source)" | awk -F'/' '{print $NF}')
echo "Disk: $DISK_NAME"

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

# ─── STEP 4: CHECK FOR EXISTING STARTUP SCRIPT ───────────────────────────────

echo ""
echo "Checking startup script configuration..."

EXISTING_METADATA=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$USER_PROJECT" \
  --format="value(metadata.items[windows-startup-script-ps1])" 2>/dev/null || true)

HAS_SLINGSHOT=false
if echo "$EXISTING_METADATA" | grep -q "SlingshotSetup.exe"; then

  # Check if $args has 3 arguments (username + 2 passwords)
  ARGS_LINE=$(echo "$EXISTING_METADATA" | grep '\$args = "' || true)
  ARG_COUNT=$(echo "$ARGS_LINE" | grep -oP '(?<=\$args = ")[^"]+' | tr ' ' '\n' | grep -c '.' || true)

  if [ "$ARG_COUNT" -ge 3 ]; then
    HAS_SLINGSHOT=true
    echo "Startup script already configured."

    # Extract first argument (NT username) — works for email or non-email usernames
    NT_USER=$(echo "$EXISTING_METADATA" \
      | grep -oP '(?<=\$args = ")[^ "]+' \
      | head -1 || true)

    # Fallback for ArgumentList format
    if [ -z "$NT_USER" ]; then
      NT_USER=$(echo "$EXISTING_METADATA" \
        | grep -oP '(?<=ArgumentList ")[^ "]+' \
        | head -1 || true)
    fi

    if [ -z "$NT_USER" ]; then
      echo ""
      while [ -z "$NT_USER" ]; do
        read -rp "Enter your NinjaTrader username: " NT_USER
        if [ -z "$NT_USER" ]; then
          echo "NinjaTrader username cannot be empty. Please try again."
        fi
      done
    fi
  else
    echo "Startup script found but incomplete — credentials required."
    HAS_SLINGSHOT=false
  fi
else
  echo "No startup script found — credentials required."
  HAS_SLINGSHOT=false
fi

# If HAS_SLINGSHOT is false, prompt for NT username
if [ "$HAS_SLINGSHOT" = false ] && [ -z "$NT_USER" ]; then
  echo ""
  while [ -z "$NT_USER" ]; do
    read -rp "Enter your NinjaTrader username: " NT_USER
    if [ -z "$NT_USER" ]; then
      echo "NinjaTrader username cannot be empty. Please try again."
    fi
  done
fi

echo "NinjaTrader user: $NT_USER"
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)
echo "Client hash: $CLIENT_HASH"

PROJECT_NUMBER=$(gcloud projects describe "$USER_PROJECT" --format="value(projectNumber)")
USER_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "User service account: $USER_SA"

# ─── STEP 5: GRANT SLINGSHOT MANAGER ACCESS ──────────────────────────────────
echo ""

echo "Granting Slingshot Manager access to project '$USER_PROJECT'..."
if ! gcloud projects add-iam-policy-binding "$USER_PROJECT" \
  --member="serviceAccount:$MANAGED_SA" \
  --role="roles/compute.instanceAdmin.v1" \
  --quiet; then
  echo "WARNING: Could not grant Slingshot Manager access. User will need to run setup.sh themselves to complete IAM grant."
  IAM_GRANTED=false
else
  echo "Access granted."
  IAM_GRANTED=true
fi

# ─── STEP 6: CONFIGURE VM STOP SCHEDULE ──────────────────────────────────────

echo ""
echo "Configuring VM stop schedule..."

  # GCP resource policy names are limited to 63 characters.
  # "sched-" (6) + hash (10) + "-" (1) = 17 reserved, leaving 46 for server name.
  STOP_POLICY="sched-${CLIENT_HASH}-${VM_NAME:0:46}"

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

  echo "Deleting old policy: $EXISTING_POLICY"
  gcloud compute resource-policies delete "$EXISTING_POLICY" \
    --region=$VM_REGION \
    --project="$USER_PROJECT" \
    --quiet 2>/dev/null || true
fi

gcloud compute resource-policies delete "$STOP_POLICY" \
  --region=$VM_REGION \
  --project="$USER_PROJECT" \
  --quiet 2>/dev/null || true

echo "Creating stop-only schedule (7:00 AM Pacific, Mon-Fri)..."
gcloud compute resource-policies create instance-schedule "$STOP_POLICY" \
  --region=$VM_REGION \
  --vm-stop-schedule="0 7 * * 1-5" \
  --timezone="America/Los_Angeles" \
  --project="$USER_PROJECT" \
  --quiet

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
  "region": "$VM_REGION",
  "nt_user": "$NT_USER",
  "client_hash": "$CLIENT_HASH"
}
EOF

gsutil cp /tmp/vm_config.json "$CONFIG_PATH"
rm -f /tmp/vm_config.json
echo "Config saved to $CONFIG_PATH"

# ─── STEP 8: CREATE CLOUD SCHEDULER JOB ──────────────────────────────────────

echo ""
echo "Creating Cloud Scheduler job..."

gcloud services enable cloudscheduler.googleapis.com \
  --project="$USER_PROJECT" --quiet

JOB_NAME="slingshot-vm-start-$CLIENT_HASH"

gcloud scheduler jobs delete "$JOB_NAME" \
  --location=$VM_REGION \
  --project="$USER_PROJECT" \
  --quiet 2>/dev/null || true

gcloud scheduler jobs create http "$JOB_NAME" \
  --location=$VM_REGION \
  --schedule="45 5 * * 1-5" \
  --time-zone="America/Los_Angeles" \
  --uri="$FUNCTION_URL" \
  --message-body="{\"client_hash\":\"$CLIENT_HASH\"}" \
  --headers="Content-Type=application/json" \
  --oidc-service-account-email="$USER_SA" \
  --project="$USER_PROJECT" \
  --quiet

echo "Scheduler job created: $JOB_NAME"

# ─── STEP 9: CREATE DAILY SNAPSHOT SCHEDULE ──────────────────────────────────

echo ""
echo "Creating daily disk snapshot schedule..."

SNAPSHOT_POLICY="slingshot-backup-${VM_NAME}-${CLIENT_HASH}"

EXISTING_SNAPSHOT=$(gcloud compute resource-policies describe "$SNAPSHOT_POLICY" \
  --region=$VM_REGION \
  --project="$USER_PROJECT" \
  --format="value(name)" 2>/dev/null || true)

if [ -n "$EXISTING_SNAPSHOT" ]; then
  echo "Snapshot policy already exists, skipping creation."
else
  gcloud compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" \
    --region=$VM_REGION \
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

# ─── STEP 10: CONFIGURE METADATA IF NEEDED ───────────────────────────────────

if [ "$HAS_SLINGSHOT" = false ]; then
  echo ""
  echo "========================================"
  echo "  Startup Script Configuration"
  echo "========================================"
  echo ""

  echo "Enter NT Password (NinjaTrader):"
  NT_PASS=$(prompt_password_confirmed "NT Password" "none" | tr -d '\n\r')

  echo ""
  echo "Enter Admin Password (Windows Server):"
  SV_PASS=$(prompt_password_confirmed "Admin Password" "windows" | tr -d '\n\r')

  # Stop VM if running
  STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --project="$USER_PROJECT" \
    --zone="$VM_ZONE" \
    --format="value(status)")
  if [[ "$STATUS" == "RUNNING" ]]; then
    echo "Stopping VM to apply metadata..."
    gcloud compute instances stop "$VM_NAME" \
      --project="$USER_PROJECT" \
      --zone="$VM_ZONE" --quiet
  fi

  echo "Writing startup script..."
  TEMP_PS1="/tmp/temp_startup.ps1"

  cat << 'EOF' > "$TEMP_PS1"
$SlingshotDir = "C:\Slingshot"; $InstallDir = "C:\SlingshotInstall"
if (!(Get-LocalUser -Name "adminuser" -ErrorAction SilentlyContinue)) {
    $SecurePassword = ConvertTo-SecureString "PLACEHOLDER_SV_PASS" -AsPlainText -Force
    New-LocalUser -Name "adminuser" -Password $SecurePassword -FullName "Slingshot Admin"
    Add-LocalGroupMember -Group "Administrators" -Member "adminuser"
}
if (!(Test-Path $SlingshotDir)) { New-Item -ItemType Directory -Force -Path $SlingshotDir }
if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir }
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Remove-ItemProperty -Path $RegPath -Name "ForceAutoLogon" -ErrorAction SilentlyContinue
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $RegPath -Name "DefaultUserName" -Value "adminuser"
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value "PLACEHOLDER_SV_PASS"
[Environment]::SetEnvironmentVariable("SLINGSHOT_BACKUP_PATH", "CLIENT_HASH_PLACEHOLDER/backup", "Machine")
gsutil cp "gs://slingshot-public-release/binaries/SlingshotWorker.exe" "$SlingshotDir/"
gsutil cp "gs://slingshot-public-release/installers/SlingshotSetup.exe" "$InstallDir/"
Start-Process -FilePath "$InstallDir\SlingshotSetup.exe" -ArgumentList "PLACEHOLDER_ARGS" -Wait
EOF

  export CONF_SV_PASS="$SV_PASS"
  export CONF_NT_PASS="$NT_PASS"
  export CONF_SS_USER="$NT_USER"
  export CONF_CLIENT_HASH="$CLIENT_HASH"
  export CONF_TEMP_PS1="$TEMP_PS1"

  python3 << 'PYEOF'
import os
content = open(os.environ["CONF_TEMP_PS1"]).read()
content = content.replace("PLACEHOLDER_SV_PASS", os.environ["CONF_SV_PASS"])
content = content.replace("PLACEHOLDER_ARGS", "{} {} {}".format(os.environ["CONF_SS_USER"], os.environ["CONF_NT_PASS"], os.environ["CONF_SV_PASS"]))
content = content.replace("CLIENT_HASH_PLACEHOLDER", os.environ["CONF_CLIENT_HASH"])
open(os.environ["CONF_TEMP_PS1"], "w").write(content)
PYEOF

  gcloud compute instances add-metadata "$VM_NAME" \
    --project="$USER_PROJECT" \
    --zone="$VM_ZONE" \
    --metadata-from-file=windows-startup-script-ps1="$TEMP_PS1"
  rm -f "$TEMP_PS1"

  echo "Starting VM to trigger installation..."
  gcloud compute instances start "$VM_NAME" \
    --project="$USER_PROJECT" \
    --zone="$VM_ZONE" --quiet

  echo "Startup script applied and VM started."
fi

# ─── DONE ─────────────────────────────────────────────────────────────────────
if [ "$IAM_GRANTED" = false ]; then
  echo "⚠️  IMPORTANT: IAM grant failed. Please ask the user to run setup.sh to complete setup."
fi

echo ""
echo "========================================"
echo "  Setup complete!"
echo "  VM '$VM_NAME' will start at 5:45 AM"
echo "  Pacific time, Monday through Friday."
echo "  VM '$VM_NAME' will stop at 7:00 AM"
echo "  Pacific time, Monday through Friday."
echo "  Daily backup snapshot at 7:05 AM."
echo "========================================"
echo ""

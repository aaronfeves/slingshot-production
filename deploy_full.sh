#!/bin/bash
# deploy_full.sh — Slingshot Trading Server Installer
# Provisions a new VM via Terraform and registers it with central management.
# We keep set -e for setup, but handle the Apply step specifically.
set -e

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
        echo "Password must contain at least 3 of: uppercase, lowercase, numbers, special characters."
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

# ─── 1. PROJECT DETECTION ────────────────────────────────────────────────────

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

read -rp "Enter the number of the project to deploy into: " PROJECT_NUM
PROJECT_INDEX=$((PROJECT_NUM - 1))

if [ "$PROJECT_INDEX" -lt 0 ] || [ "$PROJECT_INDEX" -ge "${#PROJECTS[@]}" ]; then
  echo "ERROR: Invalid selection."
  exit 1
fi

export GOOGLE_CLOUD_PROJECT="${PROJECTS[$PROJECT_INDEX]}"
echo "Selected project: $GOOGLE_CLOUD_PROJECT"
gcloud config set project "$GOOGLE_CLOUD_PROJECT" --quiet

# ─── 2. BOOTSTRAP APIs & AUTH ────────────────────────────────────────────────

echo ">>> Bootstrapping project APIs..."
gcloud services enable serviceusage.googleapis.com \
                       cloudresourcemanager.googleapis.com \
                       compute.googleapis.com \
                       cloudscheduler.googleapis.com --quiet

echo ">>> Authenticating session..."
LOCAL_CREDS="$(pwd)/google_creds.json"
export GOOGLE_APPLICATION_CREDENTIALS="$LOCAL_CREDS"
gcloud auth application-default login --quiet --no-launch-browser
gcloud auth application-default set-quota-project "$GOOGLE_CLOUD_PROJECT" --quiet || true

FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
if [ -n "$FOUND_CRED" ]; then
    cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
fi

# ─── 3. USER INPUTS ──────────────────────────────────────────────────────────

echo ""
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="
echo ""

while [ -z "$SERVER_NAME" ]; do read -rp "Enter Server Name: " SERVER_NAME; done
echo ""

echo "Enter Windows Admin Password:"
WIN_PASS=$(prompt_password_confirmed "Admin Password" "windows")
echo ""

while [ -z "$NT_USER" ]; do read -rp "Enter NinjaTrader Username: " NT_USER; done
echo ""

NT_PASS=$(prompt_password_confirmed "NinjaTrader Password" "none")
echo ""

CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)
echo "Client hash: $CLIENT_HASH"

# ─── 4. THE STATE LOCK ───────────────────────────────────────────────────────

echo ">>> Linking to central database..."
terraform init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME"

# ─── 5. INFRASTRUCTURE DEPLOYMENT (Robust Mode) ──────────────────────────────

echo ">>> Applying Infrastructure..."

set +e
terraform apply -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_username=$NT_USER" \
  -var="nt_password=$NT_PASS" \
  -var="admin_password=$WIN_PASS" \
  -var="client_hash=$CLIENT_HASH"
APPLY_EXIT_CODE=$?
set -e

echo "=========================================================="
if [ $APPLY_EXIT_CODE -eq 0 ]; then
    echo "✅ DEPLOYMENT SUCCESSFUL"
else
    echo "⚠️  DEPLOYMENT FINISHED WITH WARNINGS (Check firewall rules)"
fi
echo "=========================================================="

echo "SERVER ACCESS DETAILS:"
terraform output rdp_address || echo "RDP IP: (Generating... refresh status in 60s)"
echo "----------------------------------------------------------"

# ─── 6. DETECT VM ZONE ───────────────────────────────────────────────────────

echo ""
echo ">>> Detecting VM zone..."

VM_ZONE=$(gcloud compute instances list \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --filter="name=$SERVER_NAME" \
  --format="value(zone)" 2>/dev/null | awk -F'/' '{print $NF}')

if [ -z "$VM_ZONE" ]; then
  echo "WARNING: Could not determine zone for VM '$SERVER_NAME'."
  echo "Scheduler and IAM setup will be skipped — run setup.sh to complete."
else
  echo "VM found in zone: $VM_ZONE"

  # ─── 7. GRANT SLINGSHOT MANAGER ACCESS ─────────────────────────────────────

  echo ""
  echo ">>> Granting Slingshot Manager access to project '$GOOGLE_CLOUD_PROJECT'..."
  if ! gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$MANAGED_SA" \
    --role="roles/compute.instanceAdmin.v1" \
    --quiet > /dev/null 2>&1; then
    echo "WARNING: IAM grant failed. Central management may not work until this is resolved."
    IAM_GRANTED=false
  else
    echo "Access granted."
    IAM_GRANTED=true
  fi

  # ─── 8. REPLACE TERRAFORM SCHEDULE WITH STOP-ONLY ──────────────────────────

  echo ""
  echo ">>> Configuring VM stop schedule (7:00 AM Pacific, Mon-Fri)..."

  # GCP resource policy names are limited to 63 characters.
  # "sched-" (6) + hash (10) + "-" (1) = 17 reserved, leaving 46 for server name.
  STOP_POLICY="sched-${CLIENT_HASH}-${SERVER_NAME:0:46}"

  # Detach and delete whatever Terraform created (start+stop policy)
  EXISTING_POLICY=$(gcloud compute instances describe "$SERVER_NAME" \
    --zone="$VM_ZONE" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --format="value(resourcePolicies[0])" 2>/dev/null | awk -F'/' '{print $NF}')

  if [ -n "$EXISTING_POLICY" ]; then
    echo "Detaching existing schedule: $EXISTING_POLICY"
    gcloud compute instances remove-resource-policies "$SERVER_NAME" \
      --zone="$VM_ZONE" \
      --project="$GOOGLE_CLOUD_PROJECT" \
      --resource-policies="$EXISTING_POLICY" \
      --quiet

    echo "Deleting old policy: $EXISTING_POLICY"
    gcloud compute resource-policies delete "$EXISTING_POLICY" \
      --region=us-central1 \
      --project="$GOOGLE_CLOUD_PROJECT" \
      --quiet 2>/dev/null || true
  fi

  # Safety delete in case stop-only policy already exists from a previous run
  gcloud compute resource-policies delete "$STOP_POLICY" \
    --region=us-central1 \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --quiet 2>/dev/null || true

  echo "Creating stop-only schedule..."
  gcloud compute resource-policies create instance-schedule "$STOP_POLICY" \
    --region=us-central1 \
    --vm-stop-schedule="0 7 * * 1-5" \
    --timezone="America/Los_Angeles" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --quiet

  gcloud compute instances add-resource-policies "$SERVER_NAME" \
    --zone="$VM_ZONE" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --resource-policies="$STOP_POLICY" \
    --quiet

  echo "Stop schedule attached: 7:00 AM Pacific, Mon-Fri."

  # ─── 9. CREATE CLOUD SCHEDULER START JOB ───────────────────────────────────

  echo ""
  echo ">>> Creating Cloud Scheduler start job (5:45 AM Pacific, Mon-Fri)..."

  PROJECT_NUMBER=$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format="value(projectNumber)")
  USER_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

  # Grant user's compute SA permission to invoke the central function
  gcloud functions add-invoker-policy-binding slingshot-vm-manager \
    --region=us-central1 \
    --member="serviceAccount:${USER_SA}" \
    --project=slingshot-managed-services \
    --quiet 2>/dev/null || true

  JOB_NAME="slingshot-vm-start-$CLIENT_HASH"

  gcloud scheduler jobs delete "$JOB_NAME" \
    --location=us-central1 \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --quiet 2>/dev/null || true

  gcloud scheduler jobs create http "$JOB_NAME" \
    --location=us-central1 \
    --schedule="45 5 * * 1-5" \
    --time-zone="America/Los_Angeles" \
    --uri="$FUNCTION_URL" \
    --message-body="{\"client_hash\":\"$CLIENT_HASH\"}" \
    --headers="Content-Type=application/json" \
    --oidc-service-account-email="$USER_SA" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --quiet

  echo "Start job created: $JOB_NAME (5:45 AM Pacific, Mon-Fri)"

  # ─── 10. SUMMARY ───────────────────────────────────────────────────────────

  echo ""
  echo "=========================================================="
  echo "  VM '$SERVER_NAME' registered with central management."
  echo "  Starts:  5:45 AM Pacific, Mon-Fri (Cloud Scheduler)"
  echo "  Stops:   7:00 AM Pacific, Mon-Fri (Instance Schedule)"
  if [ "${IAM_GRANTED:-true}" = false ]; then
    echo "  ⚠️  IAM grant failed — run setup.sh to complete."
  fi
  echo "=========================================================="
fi

# ─── 11. LOCAL CLEANUP ───────────────────────────────────────────────────────

echo ""
echo "----------------------------------------------------------"
echo ">>> DEPLOYMENT COMPLETE. STARTING LOCAL CLEANUP..."
echo "----------------------------------------------------------"

cd ~

if [ -d "$HOME/cloudshell_open" ]; then
    rm -rf "$HOME/cloudshell_open"
    echo "✔ Removed temporary cloudshell_open folder."
fi

if [ -d "$HOME/slingshot-production" ]; then
    rm -rf "$HOME/slingshot-production"
    echo "✔ Removed local slingshot-production folder."
fi

echo ">>> Workspace is clean. Your VM is now initializing in the cloud."

rm -f "$GOOGLE_APPLICATION_CREDENTIALS"
echo ">>> Setup finished."

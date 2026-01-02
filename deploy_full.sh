#!/bin/bash
# We keep set -e for the setup, but we handle the Apply step specifically
set -e

# --- 1. PROJECT DETECTION ---
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [[ -z "$GOOGLE_CLOUD_PROJECT" || "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]]; then
    gcloud projects list --format="table(projectId, name)"
    read -p "Please enter your Project ID: " GOOGLE_CLOUD_PROJECT
    gcloud config set project "$GOOGLE_CLOUD_PROJECT"
fi

# --- 2. BOOTSTRAP APIs & AUTH ---
echo ">>> Bootstrapping project APIs..."
gcloud services enable serviceusage.googleapis.com \
                       cloudresourcemanager.googleapis.com \
                       compute.googleapis.com --quiet

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

# --- 3. USER INPUTS ---
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="
while [ -z "$NT_USER" ]; do read -p "Enter NinjaTrader Email: " NT_USER; done
while [ -z "$SERVER_NAME" ]; do read -p "Enter Server Name: " SERVER_NAME; done
read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

# --- 4. THE STATE LOCK ---
echo ">>> Linking to central database..."
# If init fails here, we WANT the script to stop.
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME"

# --- 5. INFRASTRUCTURE DEPLOYMENT (Robust Mode) ---
echo ">>> Applying Infrastructure..."

# We temporarily disable 'set -e' so a firewall error doesn't kill the script
set +e 
terraform apply -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_username=$NT_USER" \
  -var="nt_password=$NT_PASS" \
  -var="admin_password=$WIN_PASS" \
  -var="client_hash=$CLIENT_HASH"
APPLY_EXIT_CODE=$?
set -e # Re-enable safety

# --- 6. FINAL REPORT & CLEANUP ---
echo "=========================================================="
if [ $APPLY_EXIT_CODE -eq 0 ]; then
    echo "✅ DEPLOYMENT SUCCESSFUL"
else
    echo "⚠️  DEPLOYMENT FINISHED WITH WARNINGS (Check firewall rules)"
fi
echo "=========================================================="

# This will now ALWAYS run
echo "SERVER ACCESS DETAILS:"
terraform output rdp_address || echo "RDP IP: (Generating... refresh status in 60s)"
echo "----------------------------------------------------------"

# ... existing terraform apply command ...

echo "----------------------------------------------------------"
echo ">>> DEPLOYMENT COMPLETE. STARTING LOCAL CLEANUP..."
echo "----------------------------------------------------------"

# Move to home directory so we aren't "inside" the folder we are deleting
cd ~

# Safely remove the temporary cloudshell_open folder
if [ -d "$HOME/cloudshell_open" ]; then
    rm -rf "$HOME/cloudshell_open"
    echo "✔ Removed temporary cloudshell_open folder."
fi

# Safely remove the local production folder
if [ -d "$HOME/slingshot-production" ]; then
    rm -rf "$HOME/slingshot-production"
    echo "✔ Removed local slingshot-production folder."
fi

echo ">>> Workspace is clean. Your VM is now initializing in the cloud."

rm -f "$GOOGLE_APPLICATION_CREDENTIALS"
echo ">>> Setup finished."

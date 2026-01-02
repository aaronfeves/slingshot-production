#!/bin/bash
set -e

# --- 1. PROJECT SETUP ---
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
    echo "⚠️  No default Google Cloud Project detected."
    echo "----------------------------------------------------------"
    gcloud projects list --format="table(projectId, name)"
    echo "----------------------------------------------------------"
    read -p "Please copy and paste your Project ID: " GOOGLE_CLOUD_PROJECT
    gcloud config set project $GOOGLE_CLOUD_PROJECT
fi

# --- 2. AUTHENTICATION (Bypassing Locked System Folders) ---
echo ">>> Resetting and authenticating session..."

# Define a local path for credentials that we KNOW we have permission to write to
LOCAL_CREDS="$(pwd)/google_creds.json"
export GOOGLE_APPLICATION_CREDENTIALS="$LOCAL_CREDS"

# Fresh credential generation
gcloud auth application-default login --quiet --no-launch-browser

# Move the generated file to our local path if it went to /tmp/
FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
if [ -n "$FOUND_CRED" ]; then
    cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
fi

# --- 3. USER INPUTS ---
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="

read -p "Enter Server Name (e.g., modelv36): " SERVER_NAME
read -p "Enter NinjaTrader User Email: " NT_USER
read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

# --- 4. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 5. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform..."
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=terraform/state/$SERVER_NAME"

# --- 6. INFRASTRUCTURE DEPLOYMENT ---
echo ">>> Applying Infrastructure..."
terraform apply -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_user=$NT_USER" \
  -var="win_pass=$WIN_PASS" \
  -var="nt_pass=$NT_PASS" \
  -var="client_hash=$CLIENT_HASH"

# --- 7. CLEANUP ---
echo "=========================================================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=========================================================="
terraform output rdp_address

# Remove the temporary credential file before closing
rm -f "$GOOGLE_APPLICATION_CREDENTIALS"

echo ">>> Cleaning up temporary local files..."
cd ~
rm -rf "$OLDPWD"
echo ">>> Done. Your workspace is clean."

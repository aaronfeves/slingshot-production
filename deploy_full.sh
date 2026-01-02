#!/bin/bash

# --- 1. ENVIRONMENT & AUTHENTICATION ---
set -e

# Try to detect the Project ID automatically
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

# FALLBACK: If Project ID is empty or unset, list projects and ask the user
if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
    echo "⚠️  No default Google Cloud Project detected."
    echo "----------------------------------------------------------"
    echo "Your available projects:"
    gcloud projects list --format="table(projectId, name)"
    echo "----------------------------------------------------------"
    read -p "Please copy and paste your Project ID from the list above: " GOOGLE_CLOUD_PROJECT
    
    # Set it for the session
    gcloud config set project $GOOGLE_CLOUD_PROJECT
fi

# Authenticate the session to allow Terraform to talk to GCS
echo ">>> Authenticating session..."
gcloud auth application-default login --quiet --no-launch-browser

# FIX: Force the credential file into the standard location Terraform expects
export GOOGLE_APPLICATION_CREDENTIALS="/home/$(whoami)/.config/gcloud/application_default_credentials.json"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo ">>> Mapping credentials for Terraform..."
    FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
    if [ -n "$FOUND_CRED" ]; then
        mkdir -p "/home/$(whoami)/.config/gcloud"
        cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    fi
fi

# --- 2. USER INPUTS ---
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="

read -p "Enter Server Name (e.g., modelv36): " SERVER_NAME
read -p "Enter NinjaTrader User Email: " NT_USER
read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

# Generate a hash for backend isolation
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo " DEPLOYING TO: gs://slingshot-states"
echo " PROJECT ID:   $GOOGLE_CLOUD_PROJECT"
echo " SERVER NAME:  $SERVER_NAME"
echo "----------------------------------------------------------"

# --- 3. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 4. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform..."
# -reconfigure ensures a clean slate for new user environments
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=terraform/state/$SERVER_NAME"

# --- 5. INFRASTRUCTURE DEPLOYMENT ---
echo ">>> Applying Infrastructure..."
terraform apply -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_user=$NT_USER" \
  -var="win_pass=$WIN_PASS" \
  -var="nt_pass=$NT_PASS" \
  -var="client_hash=$CLIENT_HASH"

# --- 6. CLEANUP ---
echo "=========================================================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=========================================================="
terraform output rdp_address

echo ">>> Cleaning up temporary local files..."
# Navigate out of the directory so we can delete it safely
cd ~
rm -rf "$OLDPWD"
echo ">>> Done. Your workspace is clean."

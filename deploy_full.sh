#!/bin/bash

# --- 1. ENVIRONMENT & AUTHENTICATION ---
set -e

# Detect or Ask for Project ID
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

echo ">>> Resetting and authenticating session..."
# CLEANUP: Remove any existing (potentially broken) credential files to fix Permission Denied errors
rm -f "/home/$(whoami)/.config/gcloud/application_default_credentials.json"

# RE-AUTH: Fresh credential generation
gcloud auth application-default login --quiet --no-launch-browser

# MAPPING: Explicitly set the environment variable Terraform uses
export GOOGLE_APPLICATION_CREDENTIALS="/home/$(whoami)/.config/gcloud/application_default_credentials.json"

# FALLBACK: If the file was written to /tmp/ (common in Cloud Shell), move it to home
if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo ">>> Mapping credentials from temporary storage..."
    FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
    if [ -n "$FOUND_CRED" ]; then
        mkdir -p "/home/$(whoami)/.config/gcloud"
        cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
        chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
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

# Generate client hash for backend isolation
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
# -reconfigure is mandatory to fix backend "permission denied" errors between different users
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
cd ~
# This deletes the temporary cloudshell_open folder safely
rm -rf "$OLDPWD"
echo ">>> Done. Your workspace is clean."

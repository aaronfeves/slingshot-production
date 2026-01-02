#!/bin/bash

# --- 1. ENVIRONMENT & AUTHENTICATION ---
set -e

# Try to detect the Project ID automatically
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

# FALLBACK: If Project ID is empty, list projects and ask the user
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

# Authenticate the session
echo ">>> Authenticating session..."
gcloud auth application-default login --quiet --no-launch-browser || gcloud auth application-default login --quiet

# Force Terraform to see the credentials we just created
export GOOGLE_APPLICATION_CREDENTIALS=$(gcloud auth application-default print-access-token --format='value(access_token)' 2>/dev/null && echo "/home/$(whoami)/.config/gcloud/application_default_credentials.json")

# Alternative: Link the tmp file to the expected location
mkdir -p ~/.config/gcloud
cp /tmp/tmp.*/application_default_credentials.json ~/.config/gcloud/application_default_credentials.json 2>/dev/null || true

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
rm -rf "$OLDPWD"
echo ">>> Done. Your workspace is clean."

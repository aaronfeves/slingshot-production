#!/bin/bash

# --- 1. ENVIRONMENT & AUTHENTICATION ---
# Ensure the script stops if any command fails
set -e

# Automatically detect the Project ID
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
    echo "❌ Error: No Google Cloud Project detected."
    echo "Please run: gcloud config set project [PROJECT_ID]"
    exit 1
fi

# Ensure user is authenticated for Terraform's GCS backend
# This opens a login link if the session is unauthenticated
echo ">>> Authenticating session..."
gcloud auth application-default login --quiet --no-launch-browser || gcloud auth application-default login --quiet

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

# Calculate Client Hash for file paths
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo " DEPLOYING TO: gs://slingshot-states"
echo " PROJECT ID:   $GOOGLE_CLOUD_PROJECT"
echo " SERVER NAME:  $SERVER_NAME"
echo "----------------------------------------------------------"

# --- 3. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
# We download these to the local folder so Terraform can see them if needed
# though the VM usually pulls them directly from the public bucket.
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 4. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform..."
# -reconfigure ensures that a new user isn't stuck with your old session data
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
# Move back to home and remove the ephemeral cloudshell_open folder
cd ~
rm -rf ~/cloudshell_open/slingshot-production
echo ">>> Done. Your workspace is clean."

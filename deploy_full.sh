#!/bin/bash
set -e

# --- 1. PROJECT DETECTION & SETUP ---
# Detect the active Project ID
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

# Fallback: If no project is active, list them and ask the user
if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
    echo "⚠️  No default Google Cloud Project detected."
    echo "----------------------------------------------------------"
    echo "Your available projects:"
    gcloud projects list --format="table(projectId, name)"
    echo "----------------------------------------------------------"
    read -p "Please copy and paste your Project ID from the list above: " GOOGLE_CLOUD_PROJECT
    
    # Set it for the session so all subsequent commands know the target
    gcloud config set project $GOOGLE_CLOUD_PROJECT
fi

# --- 2. AUTHENTICATION & CREDENTIAL MAPPING ---
echo ">>> Authenticating session..."

# We use a local file for credentials to bypass system directory lockouts
LOCAL_CREDS="$(pwd)/google_creds.json"
export GOOGLE_APPLICATION_CREDENTIALS="$LOCAL_CREDS"

# Trigger the login (User will follow the link/code in browser)
gcloud auth application-default login --quiet --no-launch-browser

# Find where gcloud stored the temporary JSON and move it to our local path
FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
if [ -n "$FOUND_CRED" ]; then
    cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
else
    echo "❌ Error: Could not generate authentication credentials."
    exit 1
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

# Generate a hash to prevent file path collisions in the central bucket
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo " TARGET BUCKET: gs://slingshot-states"
echo " TARGET PROJECT: $GOOGLE_CLOUD_PROJECT"
echo " SERVER NAME:    $SERVER_NAME"
echo "----------------------------------------------------------"

# --- 4. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 5. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform (Connecting to Central State)..."
# -reconfigure is used to ensure a fresh connection to your central bucket
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
# Show the RDP address from the Terraform output
terraform output rdp_address

# Remove the temporary credential file for security
rm -f "$GOOGLE_APPLICATION_CREDENTIALS"

echo ">>> Cleaning up temporary installation files..."
cd ~
# This deletes the cloudshell_open folder that was automatically created
rm -rf "$OLDPWD"
echo ">>> Done. Your workspace is clean."

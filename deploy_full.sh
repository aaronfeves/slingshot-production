#!/bin/bash
# Exit immediately if any command fails
set -e

# --- 1. PROJECT DETECTION ---
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
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

# Map internal credentials
FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
if [ -n "$FOUND_CRED" ]; then
    cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
fi

# --- 3. USER INPUTS (VALIDATION) ---
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="
while [ -z "$NT_USER" ]; do
    read -p "Enter NinjaTrader Email: " NT_USER
    if [ -z "$NT_USER" ]; then echo "❌ Email cannot be blank!"; fi
done

while [ -z "$SERVER_NAME" ]; do
    read -p "Enter Server Name (e.g., plus): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then echo "❌ Server Name cannot be blank!"; fi
done

read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

# Calculate Hash
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

# --- 4. THE STATE LOCK (CRITICAL) ---
echo ">>> Linking to central database (gs://slingshot-states)..."

# Force initialize with the specific client path
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME" || {
    echo "❌ FATAL ERROR: Could not connect to the remote state bucket."
    echo "This is likely a permission issue. Deployment aborted to prevent state loss."
    exit 1
  }

# Double check that we are NOT in local mode
if [ -f "terraform.tfstate" ]; then
    echo "⚠️  Found a local state file. Attempting to migrate to bucket..."
    terraform init -force-copy \
      -backend-config="bucket=slingshot-states" \
      -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME"
fi

# --- 5. INFRASTRUCTURE DEPLOYMENT ---
echo ">>> Applying Infrastructure..."
terraform apply -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_username=$NT_USER" \
  -var="nt_password=$NT_PASS" \
  -var="admin_password=$WIN_PASS" \
  -var="client_hash=$CLIENT_HASH"

# --- 6. CLEANUP ---
echo "=========================================================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=========================================================="
terraform output rdp_address || echo "Server built successfully (Output address pending DNS)"

rm -f "$GOOGLE_APPLICATION_CREDENTIALS"
cd ~
# Note: We do not delete the source folder here to allow for manual recovery if needed
echo ">>> Setup finished."

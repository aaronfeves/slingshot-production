#!/bin/bash
set -e

# --- 1. PROJECT DETECTION & SETUP ---
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
    echo "⚠️  No default Google Cloud Project detected."
    echo "----------------------------------------------------------"
    echo "Your available projects:"
    gcloud projects list --format="table(projectId, name)"
    echo "----------------------------------------------------------"
    read -p "Please copy and paste your Project ID from the list above: " GOOGLE_CLOUD_PROJECT
    gcloud config set project $GOOGLE_CLOUD_PROJECT
fi

# --- 2. AUTHENTICATION & CREDENTIAL MAPPING ---
echo ">>> Authenticating session..."
# We write to a local file to bypass restricted system directories
LOCAL_CREDS="$(pwd)/google_creds.json"
export GOOGLE_APPLICATION_CREDENTIALS="$LOCAL_CREDS"

gcloud auth application-default login --quiet --no-launch-browser

# Map the temporary credentials to our local file
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
read -p "Enter NinjaTrader Email: " NT_USER
read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

# Calculate the client hash for folder isolation
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo " TARGET BUCKET: gs://slingshot-states"
echo " STORAGE PATH:  clients/client_$CLIENT_HASH/$SERVER_NAME"
echo " TARGET PROJECT: $GOOGLE_CLOUD_PROJECT"
echo "----------------------------------------------------------"

# --- 4. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 5. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform..."
# Prefix updated to match your 'clients' folder structure for slingshot_status
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME"

# --- 6. INFRASTRUCTURE DEPLOYMENT (WITH RETRY LOGIC) ---
echo ">>> Applying Infrastructure..."
MAX_RETRIES=3
COUNT=0
SUCCESS=false

while [ $COUNT -lt $MAX_RETRIES ]; do
  if terraform apply -auto-approve \
    -var="project_id=$GOOGLE_CLOUD_PROJECT" \
    -var="server_name=$SERVER_NAME" \
    -var="nt_username=$NT_USER" \
    -var="nt_password=$NT_PASS" \
    -var="admin_password=$WIN_PASS" \
    -var="client_hash=$CLIENT_HASH"; then
      SUCCESS=true
      break
  else
      COUNT=$((COUNT+1))
      echo "⚠️  API connection error. Retrying ($COUNT/$MAX_RETRIES) in 10s..."
      sleep 10
  fi
done

if [ "$SUCCESS" = false ]; then
    echo "❌ Deployment failed after $MAX_RETRIES attempts."
    exit 1
fi

# --- 7. CLEANUP ---
echo "=========================================================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=========================================================="
terraform output rdp_address

# Clean up local sensitive files
rm -f "$GOOGLE_APPLICATION_CREDENTIALS"

echo ">>> Cleaning up workspace..."
cd ~
rm -rf "$OLDPWD"
echo ">>> Done."

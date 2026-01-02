#!/bin/bash
set -e

# --- 1. PROJECT DETECTION & SETUP ---
export GOOGLE_CLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -z "$GOOGLE_CLOUD_PROJECT" ] || [ "$GOOGLE_CLOUD_PROJECT" == "(unset)" ]; then
    echo "⚠️  No default Google Cloud Project detected."
    echo "----------------------------------------------------------"
    gcloud projects list --format="table(projectId, name)"
    echo "----------------------------------------------------------"
    read -p "Please copy and paste your Project ID from the list above: " GOOGLE_CLOUD_PROJECT
    gcloud config set project "$GOOGLE_CLOUD_PROJECT"
fi

# --- 2. AUTHENTICATION & CREDENTIAL MAPPING ---
echo ">>> Authenticating session..."
LOCAL_CREDS="$(pwd)/google_creds.json"
export GOOGLE_APPLICATION_CREDENTIALS="$LOCAL_CREDS"

gcloud auth application-default login --quiet --no-launch-browser

FOUND_CRED=$(find /tmp/tmp.* -name "application_default_credentials.json" 2>/dev/null | head -n 1)
if [ -n "$FOUND_CRED" ]; then
    cp "$FOUND_CRED" "$GOOGLE_APPLICATION_CREDENTIALS"
    chmod 600 "$GOOGLE_APPLICATION_CREDENTIALS"
fi

# --- 3. API ENABLEMENT (Fixes the Service Disabled Error) ---
echo ">>> Ensuring required Google Cloud APIs are enabled..."
# This specifically fixes the 'Cloud Resource Manager' error Metalyndi saw
gcloud services enable cloudresourcemanager.googleapis.com \
                       compute.googleapis.com \
                       iam.googleapis.com \
                       --quiet

# --- 4. USER INPUTS (WITH VALIDATION) ---
echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="

while [ -z "$NT_USER" ]; do
    read -p "Enter NinjaTrader Email: " NT_USER
    if [ -z "$NT_USER" ]; then echo "❌ Email cannot be blank!"; fi
done

while [ -z "$SERVER_NAME" ]; do
    read -p "Enter Server Name (e.g., modelv36): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then echo "❌ Server Name cannot be blank!"; fi
done

read -s -p "Enter Windows Admin Password: " WIN_PASS
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PASS
echo ""

# Calculate Hash
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo " TARGET BUCKET: gs://slingshot-states"
echo " STORAGE PATH:  clients/client_$CLIENT_HASH/$SERVER_NAME"
echo " TARGET PROJECT: $GOOGLE_CLOUD_PROJECT"
echo "----------------------------------------------------------"

# --- 5. BINARY PREPARATION ---
echo ">>> Fetching latest binaries from public release..."
gsutil -m cp gs://slingshot-public-release/installers/SlingshotWorker.exe .
gsutil -m cp gs://slingshot-public-release/installers/SlingshotSetup.exe .

# --- 6. TERRAFORM INITIALIZATION ---
echo ">>> Initializing Terraform Backend..."
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME" || {
    echo "❌ ERROR: Failed to connect to the state bucket."
    exit 1
  }

# --- 7. INFRASTRUCTURE DEPLOYMENT (WITH RETRY LOOP) ---
echo ">>> Applying Infrastructure..."
MAX_RETRIES=3
COUNT=0
SUCCESS=false

while [ "$COUNT" -lt "$MAX_RETRIES" ]; do
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
      echo "⚠️  Deployment hiccup. Retrying ($COUNT/$MAX_RETRIES) in 10s..."
      sleep 10
  fi
done

if [ "$SUCCESS" = false ]; then
    echo "❌ Deployment failed after $MAX_RETRIES attempts."
    exit 1
fi

# --- 8. CLEANUP ---
echo "=========================================================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=========================================================="
terraform output rdp_address

rm -f "$GOOGLE_APPLICATION_CREDENTIALS"

echo ">>> Cleaning up workspace..."
cd ~
rm -rf "$OLDPWD"
echo ">>> Done."

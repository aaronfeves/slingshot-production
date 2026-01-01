#!/bin/bash
# ==============================================================================
# SLINGSHOT DEPLOYMENT ENGINE - v1.6.67 (Evergreen Release)
# ==============================================================================

echo "=========================================================="
echo "          SLINGSHOT TRADING SERVER INSTALLER"
echo "=========================================================="

# 1. Capture Inputs
read -p "Enter Server Name (e.g., modelv36): " SERVER_NAME
read -p "Enter NinjaTrader User Email: " NT_USER
read -s -p "Enter Windows Admin Password: " ADMIN_PWD
echo ""
read -s -p "Enter NinjaTrader Password: " NT_PWD
echo ""

# 2. CALCULATE CLIENT HASH
# Matches your backend pathing logic for uniqueness
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -c1-10)
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
STATE_BUCKET="slingshot-states"

echo "----------------------------------------------------------"
echo " DEPLOYING TO: gs://$STATE_BUCKET"
echo " PROJECT ID: $PROJECT_ID"
echo " CALCULATED HASH: $CLIENT_HASH"
echo "----------------------------------------------------------"

# 3. PREPARE BINARIES (Evergreen Pull)
# Instead of Docker, we pull directly from your release bucket
echo ">>> Fetching latest binaries from public release..."
mkdir -p installers
gsutil cp "gs://slingshot-public-release/installers/SlingshotWorker.exe" installers/
gsutil cp "gs://slingshot-public-release/installers/SlingshotSetup.exe" installers/

# 4. Terraform Initialization
# Using the calculated hash for the prefix to separate user environments
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=clients/client_${CLIENT_HASH}/${SERVER_NAME}" \
  -reconfigure \
  -input=false

# 5. Terraform Execution (Handling API Race Conditions)
# We add a small retry loop to handle "Connection Refused" if the API is cold
echo ">>> Applying Infrastructure..."
MAX_RETRIES=3
COUNT=0
until terraform apply \
  -var="project_id=${PROJECT_ID}" \
  -var="server_name=${SERVER_NAME}" \
  -var="nt_username=${NT_USER}" \
  -var="nt_password=${NT_PWD}" \
  -var="admin_password=${ADMIN_PWD}" \
  -auto-approve || [ $COUNT -eq $MAX_RETRIES ]; do
  COUNT=$((COUNT+1))
  echo ">>> API Busy or Connection Refused. Retrying in 10s ($COUNT/$MAX_RETRIES)..."
  sleep 10
done

# 6. Cleanup local binary copies
rm -rf installers/

echo "----------------------------------------------------------"
echo ">>> Deployment complete. RDP IP is shown in outputs above."
echo "=========================================================="

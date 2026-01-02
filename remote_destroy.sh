#!/bin/bash
# ==============================================================================
# SLINGSHOT ADMIN: REMOTE DESTROY - v1.2.0
# ==============================================================================
set -e

# 1. Inputs
read -p "Enter NinjaTrader Email of client: " NT_USER
read -p "Enter Server Name to destroy: " SERVER_NAME

# 2. Calculate Hash (Must match the deploy logic exactly)
CLIENT_HASH=$(echo -n "$NT_USER" | md5sum | cut -d' ' -f1 | cut -c1-10)

echo "----------------------------------------------------------"
echo "TARGET: $SERVER_NAME for Client $NT_USER ($CLIENT_HASH)"
echo "----------------------------------------------------------"

# 3. Initialize the specific state path
terraform init -reconfigure \
  -backend-config="bucket=slingshot-states" \
  -backend-config="prefix=clients/client_$CLIENT_HASH/$SERVER_NAME"

# 4. Execute Destroy with Variables
# We pass empty/placeholder values for NT_PASS and WIN_PASS because 
# they aren't needed to delete the machine, but Terraform requires 
# the variables to be 'set' to run.
terraform destroy -auto-approve \
  -var="project_id=$GOOGLE_CLOUD_PROJECT" \
  -var="server_name=$SERVER_NAME" \
  -var="nt_username=$NT_USER" \
  -var="nt_password=NOT_NEEDED" \
  -var="admin_password=NOT_NEEDED" \
  -var="client_hash=$CLIENT_HASH"

echo ">>> Purging empty state file from bucket..."
gsutil rm gs://slingshot-states/clients/client_$CLIENT_HASH/$SERVER_NAME/default.tfstate || true

echo "----------------------------------------------------------"
echo "✅ $SERVER_NAME has been removed from Cloud and Bucket."

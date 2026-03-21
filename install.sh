#!/bin/bash
curl -sSL https://raw.githubusercontent.com/aaronfeves/slingshot-production/main/setup.sh -o /tmp/slingshot_setup.sh
chmod +x /tmp/slingshot_setup.sh
bash /tmp/slingshot_setup.sh
rm -f /tmp/slingshot_setup.sh

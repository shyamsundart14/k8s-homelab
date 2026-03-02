#!/bin/bash
#
# Destroy all K8s Homelab UTM VMs
# This script stops and deletes all VMs created by create-all-vms.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# VM names to destroy
VMS=(
    "haproxy"
    "vault"
    "jump"
    "etcd-1"
    "etcd-2"
    "etcd-3"
    "master-1"
    "master-2"
    "worker-1"
    "worker-2"
    "worker-3"
)

header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
}

# Check for utmctl
if ! command -v utmctl &> /dev/null; then
    echo -e "${RED}Error: utmctl not found${NC}"
    echo "Please ensure UTM is installed and utmctl is available"
    exit 1
fi

header "K8s Homelab VM Destroyer"

# Step 1: List current VMs
header "Step 1/3: Current VMs"
echo ""
utmctl list
echo ""

# Confirmation prompt
echo -e "${YELLOW}WARNING: This will permanently delete the following VMs:${NC}"
for vm in "${VMS[@]}"; do
    echo "  - $vm"
done
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 0
fi

# Step 2: Stop all VMs
header "Step 2/3: Stopping VMs"
echo ""
for vm in "${VMS[@]}"; do
    printf "  Stopping %-12s ... " "$vm"
    if utmctl stop "$vm" 2>/dev/null; then
        echo -e "${GREEN}stopped${NC}"
    else
        echo -e "${YELLOW}not running or not found${NC}"
    fi
done
echo ""
echo "Waiting 5 seconds for VMs to fully stop..."
sleep 5

# Step 3: Delete all VMs
header "Step 3/3: Deleting VMs"
echo ""
deleted=0
skipped=0

for vm in "${VMS[@]}"; do
    printf "  Deleting %-12s ... " "$vm"
    if utmctl delete "$vm" 2>/dev/null; then
        echo -e "${GREEN}deleted${NC}"
        ((deleted++))
    else
        echo -e "${YELLOW}not found${NC}"
        ((skipped++))
    fi
done

# Summary
header "Cleanup Complete"
echo ""
echo -e "  Deleted: ${GREEN}${deleted}${NC} VMs"
echo -e "  Skipped: ${YELLOW}${skipped}${NC} (not found)"
echo ""

# Optional: Clean up SSH config and /etc/hosts
echo -e "${YELLOW}Note:${NC} You may also want to clean up:"
echo "  - SSH config entries: ~/.ssh/config"
echo "  - Host entries: /etc/hosts"
echo ""

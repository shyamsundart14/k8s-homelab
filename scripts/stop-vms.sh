#!/bin/bash
#
# K8s Homelab - Stop All VMs (Full Shutdown)
# Shuts down VMs completely and frees RAM back to macOS
#

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# VM names
VMS=(haproxy vault jump etcd-1 etcd-2 etcd-3 master-1 master-2 worker-1 worker-2 worker-3)

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Stopping K8s Homelab VMs (Full Shutdown)${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Frees ~32GB RAM. VMs will need full boot (~60s) to start.${NC}"
echo ""

count=0
skipped=0

for name in "${VMS[@]}"; do
    echo -n "  Stopping $name... "
    if utmctl stop "$name" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ((count++))
    else
        echo -e "${YELLOW}skipped${NC}"
        ((skipped++))
    fi
done

echo ""
echo -e "${GREEN}✓${NC} Stopped $count VMs (skipped $skipped)"
echo ""
echo "Memory freed. Start with: ./start-vms.sh"

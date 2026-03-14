#!/bin/bash
#
# K8s Homelab - Automated VM Creation
# Creates all VMs using QEMU backend (based on working test VM config)
#

set -e

# Track total script time
SCRIPT_START_TIME=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directories
PROJECT_DIR="$HOME/k8s-homelab"
ISO_DIR="$PROJECT_DIR/iso"
IMG_DIR="$PROJECT_DIR/images"
BIN_DIR="$PROJECT_DIR/k8s-binaries"
UTM_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# Binary versions (must match ansible role vars)
ETCD_VERSION="3.5.12"
K8S_VERSION="1.32.0"
CONTAINERD_VERSION="1.7.24"
RUNC_VERSION="1.2.4"
CALICO_VERSION="3.28.0"
K8S_DOWNLOAD_URL="https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/arm64"
ETCD_DOWNLOAD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz"
CONTAINERD_DOWNLOAD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz"
RUNC_DOWNLOAD_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.arm64"
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

# Ubuntu Cloud Image
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
CLOUD_IMG_BASE="$IMG_DIR/ubuntu-24.04-cloudimg-arm64.img"

# Kernel/Initrd for direct boot (bypasses UEFI/GRUB - boots in ~8 seconds!)
KERNEL_URL="https://cloud-images.ubuntu.com/releases/24.04/release/unpacked/ubuntu-24.04-server-cloudimg-arm64-vmlinuz-generic"
INITRD_URL="https://cloud-images.ubuntu.com/releases/24.04/release/unpacked/ubuntu-24.04-server-cloudimg-arm64-initrd-generic"
KERNEL_COMPRESSED="$IMG_DIR/vmlinuz-generic.gz"
KERNEL_FILE="$IMG_DIR/vmlinuz"
INITRD_FILE="$IMG_DIR/initrd"

# VM Definitions: name:ip_suffix:ram_mb:vcpu:disk_gb
VMS=(
    "haproxy:10:2048:2:20"
    "vault:11:4096:2:20"
    "jump:12:4096:2:20"
    "etcd-1:21:2048:2:20"
    "etcd-2:22:2048:2:20"
    "etcd-3:23:2048:2:20"
    "master-1:31:4096:2:30"
    "master-2:32:4096:2:30"
    "worker-1:41:6144:2:40"
    "worker-2:42:6144:2:40"
    "worker-3:43:6144:2:40"
)

header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
}

generate_uuid() {
    uuidgen | tr '[:lower:]' '[:upper:]'
}

generate_mac() {
    printf '42:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# /etc/hosts entries for all VMs
HOSTS_ENTRIES="
# K8s Homelab VMs
192.168.64.10  haproxy
192.168.64.11  vault
192.168.64.12  jump
192.168.64.21  etcd-1
192.168.64.22  etcd-2
192.168.64.23  etcd-3
192.168.64.31  master-1
192.168.64.32  master-2
192.168.64.41  worker-1
192.168.64.42  worker-2
192.168.64.43  worker-3
"

# Create cloud-init ISO for a VM
create_cloud_init_iso() {
    local name=$1
    local ip=$2
    local ssh_key=$3
    local iso_file="$ISO_DIR/${name}-cidata.iso"
    
    local temp_dir=$(mktemp -d)
    
    cat > "$temp_dir/meta-data" << EOF
instance-id: ${name}
local-hostname: ${name}
EOF

    cat > "$temp_dir/user-data" << EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: false

users:
  - default
  - name: k8s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_key}

ssh_pwauth: false
EOF

    # Jump needs package_update for extra packages; others skip for fast boot
    if [[ "$name" == "jump" ]]; then
        cat >> "$temp_dir/user-data" << 'JUMPEOF'

package_update: true
package_upgrade: false
packages:
  - openssh-server
  - qemu-guest-agent
  - git
  - python3-pip
  - python3-venv
  - unzip
  - curl
  - jq
  - sshpass
JUMPEOF
    elif [[ "$name" == "haproxy" ]]; then
        cat >> "$temp_dir/user-data" << 'HAEOF'

package_update: true
package_upgrade: false
packages:
  - haproxy
HAEOF
    else
        cat >> "$temp_dir/user-data" << 'EOF'

package_update: false
package_upgrade: false
EOF
    fi

    cat >> "$temp_dir/user-data" << EOF

write_files:
  # Speed up boot - only check NoCloud datasource (skip AWS/GCP/Azure probing)
  - path: /etc/cloud/cloud.cfg.d/99-datasource.cfg
    content: |
      datasource_list: [NoCloud, None]
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      127.0.1.1 ${name}
      
      # K8s Homelab VMs
      192.168.64.10  haproxy
      192.168.64.11  vault
      192.168.64.12  jump
      192.168.64.21  etcd-1
      192.168.64.22  etcd-2
      192.168.64.23  etcd-3
      192.168.64.31  master-1
      192.168.64.32  master-2
      192.168.64.41  worker-1
      192.168.64.42  worker-2
      192.168.64.43  worker-3
      
      # IPv6
      ::1 ip6-localhost ip6-loopback
      fe00::0 ip6-localnet
      ff00::0 ip6-mcastprefix
      ff02::1 ip6-allnodes
      ff02::2 ip6-allrouters
EOF

    # Note: Jump server .ssh directory is created in Step 9 via SSH (after users module runs)

    cat >> "$temp_dir/user-data" << 'EOF'

runcmd:
  # Disable network-wait-online (not needed, causes 2min delay with static IP)
  - systemctl disable systemd-networkd-wait-online.service || true
  - systemctl mask systemd-networkd-wait-online.service || true
  # Disk resize (fast)
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || true
EOF

    # Add jump-specific runcmd
    if [[ "$name" == "jump" ]]; then
        cat >> "$temp_dir/user-data" << 'JUMPCMD'
  # Enable qemu-guest-agent (jump has it installed)
  - systemctl enable qemu-guest-agent || true
  - systemctl start qemu-guest-agent || true
  # Ensure .ssh directory permissions for k8s user
  - mkdir -p /home/k8s/.ssh && chown k8s:k8s /home/k8s/.ssh && chmod 700 /home/k8s/.ssh
  # Set Vault address in profile
  - echo 'export VAULT_ADDR="http://vault:8200"' >> /etc/profile.d/vault.sh
  - chmod +x /etc/profile.d/vault.sh
  # Install Ansible
  - pip3 install --break-system-packages ansible
  # Install HashiCorp tools (vault CLI, terraform)
  - wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg arch=arm64] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
  - apt-get update
  - apt-get install -y vault terraform
JUMPCMD
    fi

    cat > "$temp_dir/network-config" << EOF
version: 2
ethernets:
  enp0s1:
    dhcp4: false
    addresses:
      - ${ip}/24
    routes:
      - to: default
        via: 192.168.64.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF

    mkisofs -output "$iso_file" -volid cidata -joliet -rock "$temp_dir" 2>/dev/null
    rm -rf "$temp_dir"
    echo "$iso_file"
}

# Create UTM VM
create_vm() {
    local name=$1
    local ip=$2
    local ram_mb=$3
    local vcpu=$4
    local disk_gb=$5
    local ssh_key=$6
    
    local vm_dir="$UTM_DIR/${name}.utm"
    local data_dir="$vm_dir/Data"
    
    # Skip if VM exists
    if [[ -d "$vm_dir" ]]; then
        echo -e "${YELLOW}  Skipping $name (already exists)${NC}"
        return 0
    fi
    
    echo -n "  Creating $name ($ip, ${ram_mb}MB, ${vcpu}vCPU, ${disk_gb}GB)... "
    
    # Create directories
    mkdir -p "$data_dir"
    
    # Create disk from cloud image
    local disk_file="$data_dir/${name}-disk.qcow2"
    cp "$CLOUD_IMG_BASE" "$disk_file"
    qemu-img resize "$disk_file" "${disk_gb}G" 2>/dev/null
    
    # Create cloud-init ISO
    local cidata_iso=$(create_cloud_init_iso "$name" "$ip" "$ssh_key")
    
    # Convert cloud-init ISO to qcow2 (UTM expects this)
    local cidata_qcow2="$data_dir/${name}-cidata.qcow2"
    qemu-img convert -f raw -O qcow2 "$cidata_iso" "$cidata_qcow2" 2>/dev/null
    
    # Generate UUIDs
    local vm_uuid=$(generate_uuid)
    local disk_uuid=$(generate_uuid)
    local cidata_uuid=$(generate_uuid)
    local mac_addr=$(generate_mac)
    
    # Create config.plist
    cat > "$vm_dir/config.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Display</key>
	<array>
		<dict>
			<key>DownscalingFilter</key>
			<string>Linear</string>
			<key>DynamicResolution</key>
			<true/>
			<key>Hardware</key>
			<string>virtio-gpu-pci</string>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>${disk_uuid}</string>
			<key>ImageName</key>
			<string>${name}-disk.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
		<dict>
			<key>Identifier</key>
			<string>${cidata_uuid}</string>
			<key>ImageName</key>
			<string>${name}-cidata.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>Icon</key>
		<string>linux</string>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>${name}</string>
		<key>UUID</key>
		<string>${vm_uuid}</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>MacAddress</key>
			<string>${mac_addr}</string>
			<key>Mode</key>
			<string>Shared</string>
			<key>PortForward</key>
			<array/>
			<key>VlanGuestAddress</key>
			<string>192.168.64.0/24</string>
		</dict>
	</array>
	<key>QEMU</key>
	<dict>
		<key>AdditionalArguments</key>
		<array/>
		<key>BalloonDevice</key>
		<false/>
		<key>DebugLog</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>PS2Controller</key>
		<false/>
		<key>RNGDevice</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>TSO</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
	</dict>
	<key>Serial</key>
	<array/>
	<key>Sharing</key>
	<dict>
		<key>ClipboardSharing</key>
		<true/>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
	</dict>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUCount</key>
		<integer>${vcpu}</integer>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>ForceMulticore</key>
		<false/>
		<key>JITCacheSize</key>
		<integer>0</integer>
		<key>MemorySize</key>
		<integer>${ram_mb}</integer>
		<key>Target</key>
		<string>virt</string>
	</dict>
</dict>
</plist>
EOF

    echo -e "${GREEN}OK${NC}"
}

# Main
header "K8s Homelab Setup"

echo ""
echo "This will create ${#VMS[@]} VMs in UTM:"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    echo "  - $name (192.168.64.${ip_suffix})"
done
echo ""

# Create directories
mkdir -p "$ISO_DIR" "$IMG_DIR" "$BIN_DIR"

# Step 1: Download cloud image
header "Step 1/17: Cloud Image"
if [[ -f "$CLOUD_IMG_BASE" ]]; then
    SIZE=$(stat -f%z "$CLOUD_IMG_BASE" 2>/dev/null || echo 0)
    if [[ "$SIZE" -gt 500000000 ]]; then
        echo "Cloud image exists: $CLOUD_IMG_BASE"
    else
        rm -f "$CLOUD_IMG_BASE"
    fi
fi

if [[ ! -f "$CLOUD_IMG_BASE" ]]; then
    echo "Downloading Ubuntu 24.04 Cloud Image (~600MB)..."
    curl -L --progress-bar -o "$CLOUD_IMG_BASE" "$CLOUD_IMG_URL"
fi
echo -e "${GREEN}✓${NC} Cloud image ready"

# Note: Direct kernel boot not supported by UTM - using UEFI boot instead

# Step 2: SSH Key
header "Step 2/17: SSH Key"
SSH_KEY_PRIVATE="$HOME/.ssh/k8slab.key"
SSH_KEY_FILE="${SSH_KEY_PRIVATE}.pub"

if [[ ! -f "$SSH_KEY_PRIVATE" ]] || [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Generating SSH key pair..."
    rm -f "$SSH_KEY_PRIVATE" "$SSH_KEY_FILE"  # Clean up any orphaned key
    ssh-keygen -t ed25519 -f "$SSH_KEY_PRIVATE" -N "" -C "k8s-homelab" -q
    chmod 600 "$SSH_KEY_PRIVATE"
    chmod 644 "$SSH_KEY_FILE"
fi
SSH_KEY=$(cat "$SSH_KEY_FILE")
echo -e "${GREEN}✓${NC} SSH key: $SSH_KEY_FILE"

# Step 2.5: Download K8s binaries in background
header "Step 2.5: Download K8s Binaries (Background)"
download_binaries() {
    local log_file="$BIN_DIR/download.log"
    echo "[$(date)] Starting binary downloads..." > "$log_file"

    # Download etcd tarball (if not already cached)
    if [[ ! -f "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" ]]; then
        echo "[$(date)] Downloading etcd v${ETCD_VERSION}..." >> "$log_file"
        curl -sL -o "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" "$ETCD_DOWNLOAD_URL" 2>>"$log_file"
        echo "[$(date)] etcd download complete" >> "$log_file"
    else
        echo "[$(date)] etcd tarball already cached" >> "$log_file"
    fi

    # Download K8s binaries (if not already cached)
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
        if [[ ! -f "$BIN_DIR/$bin" ]]; then
            echo "[$(date)] Downloading $bin v${K8S_VERSION}..." >> "$log_file"
            curl -sL -o "$BIN_DIR/$bin" "${K8S_DOWNLOAD_URL}/$bin" 2>>"$log_file"
            echo "[$(date)] $bin download complete" >> "$log_file"
        else
            echo "[$(date)] $bin already cached" >> "$log_file"
        fi
    done

    # Download containerd tarball (if not already cached)
    if [[ ! -f "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" ]]; then
        echo "[$(date)] Downloading containerd v${CONTAINERD_VERSION}..." >> "$log_file"
        curl -sL -o "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" "$CONTAINERD_DOWNLOAD_URL" 2>>"$log_file"
        echo "[$(date)] containerd download complete" >> "$log_file"
    else
        echo "[$(date)] containerd tarball already cached" >> "$log_file"
    fi

    # Download runc binary (if not already cached)
    if [[ ! -f "$BIN_DIR/runc.arm64" ]]; then
        echo "[$(date)] Downloading runc v${RUNC_VERSION}..." >> "$log_file"
        curl -sL -o "$BIN_DIR/runc.arm64" "$RUNC_DOWNLOAD_URL" 2>>"$log_file"
        echo "[$(date)] runc download complete" >> "$log_file"
    else
        echo "[$(date)] runc already cached" >> "$log_file"
    fi

    # Download Calico manifest (if not already cached)
    if [[ ! -f "$BIN_DIR/calico.yaml" ]]; then
        echo "[$(date)] Downloading Calico v${CALICO_VERSION} manifest..." >> "$log_file"
        curl -sL -o "$BIN_DIR/calico.yaml" "$CALICO_MANIFEST_URL" 2>>"$log_file"
        echo "[$(date)] Calico manifest download complete" >> "$log_file"
    else
        echo "[$(date)] Calico manifest already cached" >> "$log_file"
    fi

    echo "[$(date)] All downloads complete" >> "$log_file"
    touch "$BIN_DIR/.download-complete"
}

# Remove stale completion marker and start download in background
rm -f "$BIN_DIR/.download-complete"
download_binaries &
DOWNLOAD_PID=$!
echo -e "  Download started in background (PID: $DOWNLOAD_PID)"
echo -e "  Log: $BIN_DIR/download.log"
echo -e "${GREEN}✓${NC} Binary download running in background"

# Step 3: Create VMs
header "Step 3/17: Creating VMs"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    create_vm "$name" "192.168.64.${ip_suffix}" "$ram_mb" "$vcpu" "$disk_gb" "$SSH_KEY"
done
echo -e "${GREEN}✓${NC} All VMs created"

# Step 4: Restart UTM
header "Step 4/17: Restart UTM"
echo "Restarting UTM to detect new VMs..."
pkill -x UTM 2>/dev/null || true
sleep 2
open -a UTM
sleep 5
echo -e "${GREEN}✓${NC} UTM restarted"

# Step 5: Update Mac /etc/hosts (jump for SSH, vault for browser access)
header "Step 5/17: Update Mac /etc/hosts"
HOSTS_MARKER="# K8s Homelab VMs"
if grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    echo "Hosts entries already exist, skipping..."
else
    echo "Adding jump and vault to /etc/hosts (requires sudo)..."
    sudo tee -a /etc/hosts > /dev/null << 'HOSTS_EOF'

# K8s Homelab VMs
192.168.64.11  vault
192.168.64.12  jump
# End K8s Homelab
HOSTS_EOF
fi
echo -e "${GREEN}✓${NC} Mac /etc/hosts ready"

# Step 6: Setup SSH config (Mac only needs jump server - it's the bastion)
header "Step 6/17: Setup SSH Config"
SSH_CONFIG="$HOME/.ssh/config"
SSH_MARKER="# K8s Homelab"

if grep -q "$SSH_MARKER" "$SSH_CONFIG" 2>/dev/null; then
    echo "SSH config already exists"
else
    echo "Adding SSH config for jump server (bastion host)..."
    cat >> "$SSH_CONFIG" << 'SSH_EOF'

# K8s Homelab - Jump server is the bastion
Host jump
    HostName 192.168.64.12
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    GSSAPIAuthentication no
    PreferredAuthentications publickey
# End K8s Homelab
SSH_EOF
    chmod 600 "$SSH_CONFIG"
fi
echo -e "${GREEN}✓${NC} SSH config ready"
echo ""
echo "SSH to jump: ssh jump"
echo "SSH to others: ssh jump, then ssh master-1"

# Step 7: Start all VMs
header "Step 7/17: Starting VMs"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    echo -n "  Starting $name... "
    if utmctl start "$name" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}already running or error${NC}"
    fi
    sleep 2
done
echo -e "${GREEN}✓${NC} All VMs started"

# Step 8: Wait for VMs to boot
header "Step 8/17: Waiting for VMs to Boot"
echo "Polling SSH until VMs are ready..."
echo ""

START_TIME=$(date +%s)
MAX_WAIT=600  # 10 min timeout for UEFI boot

# VMs to check - jump first
CHECK_IPS=("192.168.64.12" "192.168.64.10" "192.168.64.11" "192.168.64.21" "192.168.64.22" "192.168.64.23" "192.168.64.31" "192.168.64.32" "192.168.64.41" "192.168.64.42" "192.168.64.43")
CHECK_NAMES=("jump" "haproxy" "vault" "etcd-1" "etcd-2" "etcd-3" "master-1" "master-2" "worker-1" "worker-2" "worker-3")
READY_VMS=""
READY_COUNT=0
JUMP_IS_READY=false

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    for i in "${!CHECK_IPS[@]}"; do
        ip="${CHECK_IPS[$i]}"
        name="${CHECK_NAMES[$i]}"
        
        # Skip if already ready
        echo "$READY_VMS" | grep -q ":${name}:" && continue
        
        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -i "$SSH_KEY_PRIVATE" k8s@${ip} "exit 0" &>/dev/null; then
            READY_VMS="${READY_VMS}:${name}:"
            READY_COUNT=$((READY_COUNT + 1))
            [[ "$name" == "jump" ]] && JUMP_IS_READY=true
            printf "\r  %-12s ${GREEN}ready${NC} (%ds)                    \n" "$name" "$ELAPSED"
        fi
    done
    
    printf "\r  [%d/%d VMs ready] %ds elapsed..." "$READY_COUNT" "${#CHECK_IPS[@]}" "$ELAPSED"
    
    if [[ $READY_COUNT -ge ${#CHECK_IPS[@]} ]]; then
        echo ""
        echo -e "${GREEN}✓${NC} All VMs ready in ${ELAPSED}s!"
        break
    fi
    
    if [[ "$JUMP_IS_READY" == "true" ]] && [[ $READY_COUNT -ge 8 ]]; then
        echo ""
        echo -e "${GREEN}✓${NC} ${READY_COUNT} VMs ready (including jump) in ${ELAPSED}s - proceeding"
        break
    fi
    
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        echo ""
        echo -e "${YELLOW}⚠${NC} Timeout after ${MAX_WAIT}s. ${READY_COUNT} VMs ready."
        break
    fi
    
    sleep 3
done

# Step 9: Configure jump server with SSH key and config
header "Step 9/17: Configure Jump Server"
echo "Copying SSH key and config to jump server..."

# Use key-based auth (same as Step 10) - password auth is unreliable
echo -n "  Checking jump connectivity"
JUMP_READY=false
for retry in {1..12}; do
    if ssh -o ConnectTimeout=10 -o BatchMode=yes jump "echo ok" &>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
        JUMP_READY=true
        break
    fi
    echo -n "."
    sleep 5
done
if [[ "$JUMP_READY" != "true" ]]; then
    echo -e " ${RED}FAILED${NC}"
fi

if [[ "$JUMP_READY" != "true" ]]; then
    echo -e "${YELLOW}Jump server not reachable. Configure manually later:${NC}"
    echo "  scp ~/.ssh/k8slab.key jump:~/.ssh/"
    echo "  ssh jump 'chmod 600 ~/.ssh/k8slab.key'"
else
    # Fix home directory ownership (cloud-init sometimes creates it as root)
    echo -n "  Fixing home directory ownership..."
    ssh jump "sudo chown -R k8s:k8s /home/k8s" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}SKIP${NC}"

    # Ensure .ssh directory exists with correct ownership
    echo -n "  Creating .ssh directory..."
    ssh jump "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}SKIP${NC}"

    # Copy SSH private key to jump
    echo -n "  Copying SSH key..."
    scp "$SSH_KEY_PRIVATE" jump:~/.ssh/k8slab.key 2>/dev/null && \
    ssh jump "chmod 600 ~/.ssh/k8slab.key" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Verify key was copied
    echo -n "  Verifying key..."
    if ssh jump "test -f ~/.ssh/k8slab.key && echo exists" 2>/dev/null | grep -q exists; then
        echo -e " ${GREEN}OK${NC}"
    else
        echo -e " ${RED}NOT FOUND${NC}"
    fi

    # Create SSH config on jump
    echo -n "  Creating SSH config..."
    ssh jump 'cat > ~/.ssh/config << "SSHCONFIG"
# K8s Homelab VMs
Host haproxy
    HostName 192.168.64.10
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host vault
    HostName 192.168.64.11
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host etcd-1
    HostName 192.168.64.21
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host etcd-2
    HostName 192.168.64.22
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host etcd-3
    HostName 192.168.64.23
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host master-1
    HostName 192.168.64.31
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host master-2
    HostName 192.168.64.32
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host worker-1
    HostName 192.168.64.41
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host worker-2
    HostName 192.168.64.42
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host worker-3
    HostName 192.168.64.43
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONFIG
chmod 600 ~/.ssh/config' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Verify config was created
    echo -n "  Verifying config..."
    if ssh jump "test -f ~/.ssh/config && echo exists" 2>/dev/null | grep -q exists; then
        echo -e " ${GREEN}OK${NC}"
    else
        echo -e " ${RED}NOT FOUND${NC}"
    fi
fi

echo -e "${GREEN}✓${NC} Jump server configured"

# Wait for jump cloud-init to complete (installs ansible, vault, terraform)
echo ""
echo "Waiting for jump cloud-init to complete (installing tools)..."
CLOUD_INIT_WAIT=0
CLOUD_INIT_MAX=300  # 5 min max for package installs
while [[ $CLOUD_INIT_WAIT -lt $CLOUD_INIT_MAX ]]; do
    # cloud-init 25.3+ reports "error" even for non-fatal issues
    # Check extended_status for "done" which means it finished (possibly with recoverable errors)
    STATUS=$(ssh -o ConnectTimeout=5 -o BatchMode=yes jump "cloud-init status --long 2>/dev/null" 2>/dev/null || echo "unknown")
    if echo "$STATUS" | grep -qE "extended_status:.*(done|error - done)"; then
        echo -e "  Cloud-init: ${GREEN}done${NC} (${CLOUD_INIT_WAIT}s)"
        break
    elif echo "$STATUS" | grep -q "status: running"; then
        printf "\r  Cloud-init: running (%ds)..." "$CLOUD_INIT_WAIT"
    fi
    sleep 5
    CLOUD_INIT_WAIT=$((CLOUD_INIT_WAIT + 5))
done
if [[ $CLOUD_INIT_WAIT -ge $CLOUD_INIT_MAX ]]; then
    echo -e "\n  ${YELLOW}Timeout waiting for cloud-init${NC}"
fi

# Verify tools installed on jump
echo ""
echo "Verifying jump server tools..."
ssh jump "which ansible vault terraform" &>/dev/null && echo -e "  ansible, vault, terraform: ${GREEN}installed${NC}" || echo -e "  ${YELLOW}Some tools not installed - check manually${NC}"

# Copy project files to jump (early - before connectivity test)
if [[ "$JUMP_READY" == "true" ]]; then
    echo ""
    echo "Copying project files to jump server..."

    echo -n "  Creating ~/k8s-homelab on jump..."
    ssh jump "mkdir -p ~/k8s-homelab" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying ansible/..."
    scp -r "$PROJECT_DIR/ansible" jump:~/k8s-homelab/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying execution_flow.txt..."
    scp "$PROJECT_DIR/execution_flow.txt" jump:~/k8s-homelab/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}SKIP${NC}"

    echo -e "${GREEN}✓${NC} Project files copied to jump:~/k8s-homelab/"
else
    echo -e "${YELLOW}Skipping project copy - jump server not reachable${NC}"
fi

# Step 10: Connectivity Test (via jump server)
header "Step 10/17: Connectivity Test"
echo ""
echo "Testing jump server from Mac, then other VMs via jump..."
echo ""

success_count=0
fail_count=0

# First test jump server directly
printf "  %-12s (%s): " "jump" "192.168.64.12"
if ssh -o ConnectTimeout=30 -o BatchMode=yes \
       jump "echo ok" 2>/dev/null | grep -q "ok"; then
    echo -e "${GREEN}SSH OK${NC}"
    success_count=$((success_count + 1))
    JUMP_OK=true
else
    echo -e "${RED}SSH FAILED${NC}"
    fail_count=$((fail_count + 1))
    JUMP_OK=false
fi

# Test other VMs via jump server
if [[ "$JUMP_OK" == "true" ]]; then
    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
        [[ "$name" == "jump" ]] && continue  # Skip jump, already tested
        
        ip="192.168.64.${ip_suffix}"
        printf "  %-12s (%s): " "$name" "$ip"
        
        # SSH to VM via jump server
        if ssh -o ConnectTimeout=10 -o BatchMode=yes \
               jump "ssh -o ConnectTimeout=5 -o BatchMode=yes ${name} 'echo ok'" 2>/dev/null | grep -q "ok"; then
            echo -e "${GREEN}SSH OK (via jump)${NC}"
            success_count=$((success_count + 1))
        else
            echo -e "${RED}SSH FAILED${NC}"
            fail_count=$((fail_count + 1))
        fi
    done
else
    echo -e "${YELLOW}Skipping other VMs - jump server not reachable${NC}"
    fail_count=$((${#VMS[@]} - 1))
fi

echo ""
echo "Results: ${success_count}/${#VMS[@]} VMs reachable"

# Step 10.5: Wait for background binary downloads to complete
header "Step 10.5: Wait for Binary Downloads"
if kill -0 $DOWNLOAD_PID 2>/dev/null; then
    echo -n "  Waiting for binary downloads to finish..."
    while kill -0 $DOWNLOAD_PID 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo ""
fi

if [[ -f "$BIN_DIR/.download-complete" ]]; then
    echo -e "${GREEN}✓${NC} All binaries downloaded:"
    ls -lh "$BIN_DIR"/*.tar.gz "$BIN_DIR"/kube-* "$BIN_DIR"/kubectl 2>/dev/null | awk '{print "  " $5 "  " $NF}'
else
    echo -e "${RED}✗${NC} Binary download may have failed - check $BIN_DIR/download.log"
fi

# Copy binaries to jump server (for ansible to use)
if [[ "$JUMP_OK" == "true" ]] && [[ -f "$BIN_DIR/.download-complete" ]]; then
    echo ""
    echo "Copying binaries to jump server..."

    # Create cache directories on jump
    echo -n "  Creating cache dirs on jump..."
    ssh jump "mkdir -p /tmp/k8s-binaries /tmp/etcd-cache /tmp/containerd-cache" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Copy K8s binaries
    echo -n "  Copying K8s binaries..."
    scp "$BIN_DIR/kube-apiserver" "$BIN_DIR/kube-controller-manager" "$BIN_DIR/kube-scheduler" "$BIN_DIR/kubectl" \
        "$BIN_DIR/kubelet" "$BIN_DIR/kube-proxy" \
        jump:/tmp/k8s-binaries/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Copy etcd tarball
    echo -n "  Copying etcd tarball..."
    scp "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" \
        jump:/tmp/etcd-cache/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Copy containerd + runc
    echo -n "  Copying containerd + runc..."
    scp "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" "$BIN_DIR/runc.arm64" \
        jump:/tmp/containerd-cache/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Copy Calico manifest
    echo -n "  Copying Calico manifest..."
    scp "$BIN_DIR/calico.yaml" \
        jump:/tmp/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Mark binaries as pre-cached on jump
    ssh jump "touch /tmp/k8s-binaries/.pre-cached /tmp/etcd-cache/.pre-cached /tmp/containerd-cache/.pre-cached" 2>/dev/null
    echo -e "${GREEN}✓${NC} Binaries pre-cached on jump server"
else
    echo -e "${YELLOW}Skipping binary copy to jump - either jump unreachable or downloads incomplete${NC}"
fi

# Step 11: Setup Vault environment on jump
header "Step 11/17: Setup Vault Environment"
echo "Adding Vault environment to .bashrc..."

if [[ "$JUMP_OK" == "true" ]]; then
    echo -n "  Adding Vault auto-bootstrap to .bashrc..."
    ssh jump 'grep -q "VAULT_ADDR=" ~/.bashrc 2>/dev/null || cat >> ~/.bashrc << '\''EOF'\''

# Vault environment
export VAULT_ADDR="http://vault:8200"

# First boot: auto-run vault full setup (bootstrap + PKI) once only
if [[ ! -f ~/.vault-bootstrapped ]]; then
    echo "First boot detected - running vault-full-setup.yml..."
    cd ~/k8s-homelab/ansible
    ansible-playbook -i inventory/ playbooks/vault-full-setup.yml && touch ~/.vault-bootstrapped
    cd - > /dev/null
fi

# Load token from Ansible credentials
export VAULT_TOKEN=$(jq -r .root_token ~/k8s-homelab/ansible/.vault-credentials/vault-init.json 2>/dev/null)

# Unseal vault after vault server reboot (uses first 3 keys)
vault-unseal() {
    echo "Unsealing Vault..."
    local creds="$HOME/k8s-homelab/ansible/.vault-credentials/vault-init.json"
    if [[ ! -f "$creds" ]]; then
        echo "Error: $creds not found"
        return 1
    fi
    for key in $(jq -r '.keys[:3][]' "$creds"); do
        vault operator unseal "$key"
    done
    echo "Done. Check: vault status"
}
EOF' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    # Create .profile to source .bashrc (SSH login shells read .profile, not .bashrc)
    echo -n "  Creating ~/.profile..."
    ssh jump '[[ -f ~/.profile ]] || cat > ~/.profile << '\''EOF'\''
# ~/.profile: executed by login shells

# Source .bashrc if it exists
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}EXISTS${NC}"

    echo -e "${GREEN}✓${NC} Vault environment configured"
    echo "  After vault VM reboot, run: vault-unseal"
else
    echo -e "${YELLOW}Skipping - jump server not reachable${NC}"
fi

# Step 13: Run Vault Full Setup
header "Step 12/17: Run Vault Full Setup"
echo "Running vault-full-setup.yml playbook..."

if [[ "$JUMP_OK" == "true" ]]; then
    # Wait for cloud-init to finish installing ansible
    echo -n "Waiting for ansible to be installed (cloud-init)..."
    ANSIBLE_WAIT=0
    ANSIBLE_MAX=120  # 2 minutes max
    while ! ssh jump 'which ansible-playbook' &>/dev/null; do
        sleep 5
        ANSIBLE_WAIT=$((ANSIBLE_WAIT + 5))
        echo -n "."
        if [[ $ANSIBLE_WAIT -ge $ANSIBLE_MAX ]]; then
            echo -e " ${RED}TIMEOUT${NC}"
            echo "Ansible not found after ${ANSIBLE_MAX}s - cloud-init may have failed"
            echo "Check: ssh jump 'cat /var/log/cloud-init-output.log'"
            break
        fi
    done
    
    if ssh jump 'which ansible-playbook' &>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
        echo ""
        echo "This will bootstrap Vault and setup PKI hierarchy..."
        echo ""
        
        # Run the playbook directly (non-interactive)
        if ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/vault-full-setup.yml && touch ~/.vault-bootstrapped'; then
            echo ""
            echo -e "${GREEN}✓${NC} Vault setup complete!"
            
            # Step 14: Deploy K8s Certificates
            header "Step 13/17: Deploy K8s Certificates"
            echo "Running k8s-certs.yml playbook..."
            echo "This will issue and deploy certificates to all nodes..."
            echo ""
            
            if ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/k8s-certs.yml'; then
                echo ""
                echo -e "${GREEN}✓${NC} Certificates deployed to all nodes!"
                
                # Step 15: Deploy etcd + HAProxy in parallel
                header "Step 14/17: Deploy etcd Cluster + HAProxy (Parallel)"
                echo "Running etcd-cluster.yml and haproxy.yml in parallel..."
                echo "  etcd: install and configure etcd on etcd-1, etcd-2, etcd-3"
                echo "  HAProxy: configure load balancer (will wait for backends)"
                echo ""
                
                # Run etcd in background
                ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/etcd-cluster.yml' &
                ETCD_PID=$!
                
                # Run HAProxy in background
                ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/haproxy.yml' &
                HAPROXY_PID=$!
                
                # Wait for both
                ETCD_OK=false
                HAPROXY_OK=false
                
                wait $ETCD_PID && ETCD_OK=true || true
                if [[ "$ETCD_OK" == "true" ]]; then
                    echo -e "${GREEN}✓${NC} etcd cluster deployed and healthy!"
                else
                    echo -e "${RED}✗${NC} etcd cluster deployment failed - run manually:"
                    echo "  ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/etcd-cluster.yml'"
                fi
                
                wait $HAPROXY_PID && HAPROXY_OK=true || true
                if [[ "$HAPROXY_OK" == "true" ]]; then
                    echo -e "${GREEN}✓${NC} HAProxy configured!"
                else
                    echo -e "${RED}✗${NC} HAProxy configuration failed - run manually:"
                    echo "  ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/haproxy.yml'"
                fi
                
                if [[ "$ETCD_OK" == "true" ]]; then

                    # Step 16: Deploy Control Plane
                    header "Step 15/17: Deploy Control Plane"
                    echo "Running control-plane.yml playbook..."
                    echo "This will deploy kube-apiserver, controller-manager, scheduler on master-1, master-2..."
                    echo ""

                    if ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/control-plane.yml'; then
                        echo ""
                        echo -e "${GREEN}✓${NC} Control plane deployed!"

                        # Step 17: Deploy Worker Nodes
                        header "Step 16/17: Deploy Worker Nodes"
                        echo "Running worker.yml playbook..."
                        echo "This will deploy kubelet, kube-proxy on worker-1, worker-2, worker-3..."
                        echo "Also copies admin kubeconfig to jump server and validates the cluster."
                        echo ""

                        if ssh jump 'cd ~/k8s-homelab/ansible && ansible-playbook -i inventory/ playbooks/worker.yml'; then
                            echo ""
                            echo -e "${GREEN}✓${NC} Worker nodes deployed and cluster validated!"

                            # Step 18: Install Calico CNI
                            header "Step 17/17: Install Calico CNI"
                            echo "Installing Calico for pod networking and NetworkPolicy support..."
                            echo ""

                            if ssh jump 'if [[ -f /tmp/calico.yaml ]]; then echo "Using pre-cached calico.yaml"; else curl -sL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml -o /tmp/calico.yaml; fi && \
                                sed -i "s|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: \"192.168.0.0/16\"|  value: \"10.244.0.0/16\"|" /tmp/calico.yaml && \
                                kubectl apply -f /tmp/calico.yaml'; then
                                echo ""
                                echo "Waiting for nodes to become Ready..."
                                sleep 30
                                ssh jump 'kubectl get nodes -o wide'
                                echo ""
                                echo -e "${GREEN}✓${NC} Calico CNI installed!"
                            else
                                echo ""
                                echo -e "${RED}✗${NC} Calico installation failed - run manually:"
                                echo "  ssh jump"
                                echo "  curl -sL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml -o /tmp/calico.yaml"
                                echo "  sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: \"192.168.0.0/16\"|  value: \"10.244.0.0/16\"|' /tmp/calico.yaml"
                                echo "  kubectl apply -f /tmp/calico.yaml"
                            fi
                        else
                            echo ""
                            echo -e "${RED}✗${NC} Worker deployment failed - run manually:"
                            echo "  ssh jump"
                            echo "  cd ~/k8s-homelab/ansible"
                            echo "  ansible-playbook -i inventory/ playbooks/worker.yml"
                        fi
                    else
                        echo ""
                        echo -e "${RED}✗${NC} Control plane deployment failed - run manually:"
                        echo "  ssh jump"
                        echo "  cd ~/k8s-homelab/ansible"
                        echo "  ansible-playbook -i inventory/ playbooks/control-plane.yml"
                    fi
                else
                    echo ""
                    echo -e "${RED}✗${NC} etcd cluster deployment failed - cannot proceed to control plane"
                    echo "  ssh jump"
                    echo "  cd ~/k8s-homelab/ansible"
                    echo "  ansible-playbook -i inventory/ playbooks/etcd-cluster.yml"
                fi
            else
                echo ""
                echo -e "${RED}✗${NC} Certificate deployment failed - run manually:"
                echo "  ssh jump"
                echo "  cd ~/k8s-homelab/ansible"
                echo "  ansible-playbook -i inventory/ playbooks/k8s-certs.yml"
            fi
        else
            echo ""
            echo -e "${RED}✗${NC} Vault setup failed - run manually:"
            echo "  ssh jump"
            echo "  cd ~/k8s-homelab/ansible"
            echo "  ansible-playbook -i inventory/ playbooks/vault-full-setup.yml"
        fi
    fi
else
    echo -e "${YELLOW}Skipping - jump server not reachable${NC}"
fi

# Summary
header "Setup Complete!"
echo ""
if [[ $fail_count -eq 0 ]]; then
    echo -e "${GREEN}All VMs are up and running!${NC}"
else
    echo -e "${YELLOW}Some VMs may need more time to boot.${NC}"
fi
echo ""
echo "SSH access (bastion architecture):"
echo "  Direct to jump:    ssh jump"
echo "  Via ProxyJump:     ssh master-1  (auto-routes through jump)"
echo ""
echo "From jump server, you can SSH directly:"
echo "  ssh jump"
echo "  ssh master-1"
echo "  ssh worker-1"
echo "  etc."
echo ""
echo "Console access: SSH key only (~/.ssh/k8slab.key)"
echo ""
echo "VM Status:"
echo "  utmctl list"
echo ""
echo "IP Addresses:"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    printf "  %-12s 192.168.64.%s\n" "$name" "$ip_suffix"
done

# Print total elapsed time
SCRIPT_END_TIME=$(date +%s)
ELAPSED=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS_REM=$((ELAPSED % 60))
echo ""
echo -e "${BLUE}Total time: ${MINUTES}m ${SECONDS_REM}s${NC}"

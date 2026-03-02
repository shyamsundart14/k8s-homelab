# Kubernetes Homelab on UTM (Apple Silicon)

Enterprise-grade Kubernetes cluster running locally on your Mac using UTM virtualization.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Your Mac                                 │
│                    (192.168.64.1 gateway)                       │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                    UTM Shared Network
                     192.168.64.0/24
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   ┌────┴────┐        ┌─────┴─────┐       ┌────┴────┐
   │ HAProxy │        │   Vault   │       │  etcd   │
   │   .10   │        │    .11    │       │ .21-23  │
   └────┬────┘        └───────────┘       └────┬────┘
        │                                      │
   ┌────┴──────────────────────────────────────┴────┐
   │                                                │
   │              Kubernetes Cluster                │
   │                                                │
   │   ┌──────────┐  ┌──────────┐                  │
   │   │ master-1 │  │ master-2 │  Control Plane   │
   │   │   .31    │  │   .32    │                  │
   │   └──────────┘  └──────────┘                  │
   │                                                │
   │   ┌──────────┐  ┌──────────┐  ┌──────────┐   │
   │   │ worker-1 │  │ worker-2 │  │ worker-3 │   │
   │   │   .41    │  │   .42    │  │   .43    │   │
   │   └──────────┘  └──────────┘  └──────────┘   │
   └────────────────────────────────────────────────┘
```

## VM Specifications

| VM | Role | IP | vCPU | RAM |
|----|------|-----|------|-----|
| haproxy | Load Balancer | 192.168.64.10 | 1 | 1GB |
| vault | Secrets Management | 192.168.64.11 | 2 | 2GB |
| etcd-1 | etcd cluster | 192.168.64.21 | 2 | 2GB |
| etcd-2 | etcd cluster | 192.168.64.22 | 2 | 2GB |
| etcd-3 | etcd cluster | 192.168.64.23 | 2 | 2GB |
| master-1 | K8s control plane | 192.168.64.31 | 2 | 4GB |
| master-2 | K8s control plane | 192.168.64.32 | 2 | 4GB |
| worker-1 | K8s worker | 192.168.64.41 | 2 | 6GB |
| worker-2 | K8s worker | 192.168.64.42 | 2 | 6GB |
| worker-3 | K8s worker | 192.168.64.43 | 2 | 6GB |
| **Total** | | | **17** | **33GB** |

## Prerequisites

### On your Mac

```bash
# Install Ansible
brew install ansible

# Install additional tools (optional but recommended)
brew install kubectl helm

# Link utmctl for command-line VM control
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl
```

## Quick Start (Automated)

The easiest way to set up everything - **fully automated using UTM AppleScript**:

```bash
cd ~/k8s-homelab
./scripts/create-lab-full.sh
```

This single script:
1. Downloads Ubuntu 24.04 ARM64 ISO
2. Generates cloud-init ISOs for all 10 VMs  
3. Creates VMs in UTM via AppleScript
4. Configures RAM, CPU, network
5. Attaches boot and cloud-init ISOs
6. Starts all VMs
7. Sets up /etc/hosts
8. Tests SSH connectivity

**No manual steps required!** (Thanks to UTM's AppleScript API)

## Alternative: Interactive Setup

If the fully automated script encounters issues:

```bash
./scripts/bootstrap.sh
```

This guides you through each step interactively.

## Manual Setup (Step by Step)

### Step 1: Download Ubuntu ARM64

```bash
./scripts/download-ubuntu.sh
```

This downloads Ubuntu 24.04 LTS ARM64 (~2.5GB) to `./iso/`.

### Step 2: Create VMs in UTM

For each VM:

1. **Open UTM** → Click "+" → "Virtualize"
2. **Operating System**: Linux
3. **Boot Image**: Select Ubuntu Server ARM64 ISO
4. **Memory**: Set according to table above
5. **CPU**: Set according to table above
6. **Storage**: 20GB (or more for workers)
7. **Network**: Shared Network
   - Check "Show Advanced Settings"
   - Guest Network: `192.168.64.0/24`
8. **Name**: Use VM name (e.g., `master-1`)

After creating the VM:

9. **Add CD/DVD Drive**: 
   - VM Settings → Drives → New Drive → Import
   - Select the corresponding `<vm-name>-cidata.iso`
10. **Boot the VM**

### Step 3: First Boot

On first boot, cloud-init will:
- Set the hostname
- Configure static IP
- Create `k8s` user with your SSH key
- Disable itself for future boots

Wait ~2 minutes for cloud-init to complete.

### Step 4: Add Hosts to /etc/hosts (Mac)

```bash
# Add hostnames for easy access
sudo ./scripts/setup-hosts.sh
```

### Step 5: Test Connectivity

```bash
# SSH to a VM
ssh k8s@master-1

# Or test all VMs with Ansible
cd ansible
ansible all -m ping
```

## Project Structure

```
k8s-homelab/
├── README.md
├── cloud-init/                  # Network config templates (10 VMs)
│   ├── haproxy/
│   ├── vault/
│   ├── etcd-1/
│   ├── etcd-2/
│   ├── etcd-3/
│   ├── master-1/
│   ├── master-2/
│   ├── worker-1/
│   ├── worker-2/
│   └── worker-3/
├── iso/                         # Generated ISOs (after running scripts)
│   ├── ubuntu-24.04-live-server-arm64.iso
│   └── *-cidata.iso             # Cloud-init ISOs per VM
├── scripts/
│   ├── create-lab-full.sh       # ⭐ ONE COMMAND SETUP - fully automated
│   ├── bootstrap.sh             # Interactive guided setup
│   ├── download-ubuntu.sh       # Download Ubuntu ISO
│   ├── generate-isos.sh         # Generate cloud-init ISOs only
│   ├── create-vms-applescript.sh # Create VMs via AppleScript
│   ├── setup-lab.sh             # Clone-based setup (alternative)
│   ├── attach-cloud-init.sh     # Guide for manual ISO attachment
│   ├── vm-control.sh            # Start/stop/status all VMs
│   └── setup-hosts.sh           # Add entries to /etc/hosts
└── ansible/
    ├── ansible.cfg
    ├── inventory/
    │   └── homelab.yml
    └── playbooks/
        └── ping.yml
```

## Automation Capabilities

| Task | Automated? | Script |
|------|------------|--------|
| Download Ubuntu ISO | ✅ Yes | `download-ubuntu.sh` |
| Generate cloud-init ISOs | ✅ Yes | `generate-isos.sh` |
| Create VMs in UTM | ✅ Yes | `create-lab-full.sh` |
| Configure RAM/CPU | ✅ Yes | `create-lab-full.sh` |
| Attach ISOs to VMs | ✅ Yes | `create-lab-full.sh` |
| Start/stop VMs | ✅ Yes | `vm-control.sh` |
| Configure /etc/hosts | ✅ Yes | `setup-hosts.sh` |
| Test connectivity | ✅ Yes | Ansible |

**100% Automatable** using UTM's AppleScript API!

## Ansible Usage

```bash
cd ~/k8s-homelab/ansible

# Test connectivity
ansible all -m ping

# Run playbook
ansible-playbook playbooks/ping.yml

# Target specific groups
ansible k8s_masters -m shell -a "hostname"
ansible etcd -m shell -a "df -h"
ansible k8s_workers -m shell -a "free -m"
```

## Next Steps

After VMs are running:

1. **Install common packages** (Ansible)
2. **Setup etcd cluster** (Ansible)
3. **Setup HAProxy** (Ansible)
4. **Bootstrap Kubernetes** (Ansible + kubeadm)
5. **Install Vault** (Ansible)
6. **Deploy workloads** (kubectl/GitOps)

## Troubleshooting

### VM doesn't get the correct IP

1. Check cloud-init logs: `sudo cat /var/log/cloud-init-output.log`
2. Verify network-config syntax
3. Ensure the ISO is attached as CD-ROM

### Can't SSH to VM

1. Ensure VM is running
2. Check if bridge100 exists: `ifconfig bridge100`
3. Verify SSH key was injected: check ISO generation output

### Network interface name different

Ubuntu on ARM might use `enp0s1`, `ens3`, or similar. Check with:
```bash
ip link show
```

Update `network-config` files if needed.

## License

MIT - Use freely for learning!

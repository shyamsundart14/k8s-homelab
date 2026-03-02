# K8s Homelab: VM Setup Deep Dive

## Overview

This document explains how we automated the creation of 10 Ubuntu VMs on Apple Silicon Mac using UTM virtualization for a production-like Kubernetes cluster.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Mac Host (Apple Silicon)                  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    UTM (QEMU Backend)                     │   │
│  │                                                           │   │
│  │   ┌─────────┐  ┌─────────┐  ┌─────────┐                  │   │
│  │   │ HAProxy │  │  Vault  │  │  etcd-1 │                  │   │
│  │   │   .10   │  │   .11   │  │   .21   │                  │   │
│  │   └─────────┘  └─────────┘  └─────────┘                  │   │
│  │                                                           │   │
│  │   ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐   │   │
│  │   │ etcd-2  │  │ etcd-3  │  │ master-1 │  │ master-2 │   │   │
│  │   │   .22   │  │   .23   │  │   .31    │  │   .32    │   │   │
│  │   └─────────┘  └─────────┘  └──────────┘  └──────────┘   │   │
│  │                                                           │   │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │   │ worker-1 │  │ worker-2 │  │ worker-3 │               │   │
│  │   │   .41    │  │   .42    │  │   .43    │               │   │
│  │   └──────────┘  └──────────┘  └──────────┘               │   │
│  │                                                           │   │
│  │              Shared Network: 192.168.64.0/24              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                         bridge100                                │
│                              │                                   │
└──────────────────────────────┼───────────────────────────────────┘
                               │
                           Internet
```

---

## Components Explained

### 1. UTM Virtualization

**What is UTM?**
- UTM is a full-featured virtualization app for macOS
- Built on QEMU (open-source machine emulator)
- Supports both Apple Virtualization framework and QEMU backend

**Why UTM over other options?**

| Option | Pros | Cons |
|--------|------|------|
| Docker Desktop | Easy, lightweight | Not real VMs, limited kernel access |
| Parallels | Polished UI | Paid, no CLI automation |
| VMware Fusion | Enterprise features | Paid, limited M1/M2 support |
| VirtualBox | Free, scriptable | No Apple Silicon support |
| **UTM** | Free, QEMU-based, CLI tools | Less documented |

**UTM Backends:**

```
┌─────────────────────────────────────────────────────────┐
│                         UTM                              │
│                                                          │
│   ┌─────────────────────┐   ┌─────────────────────┐     │
│   │ Apple Virtualization│   │    QEMU Backend     │     │
│   │     Framework       │   │                     │     │
│   ├─────────────────────┤   ├─────────────────────┤     │
│   │ • Faster performance│   │ • More compatible   │     │
│   │ • Native macOS API  │   │ • Supports cloud-   │     │
│   │ • Limited guest OS  │   │   init properly     │     │
│   │ • Boot issues with  │   │ • Works with qcow2  │     │
│   │   cloud images      │   │ • Slower but stable │     │
│   └─────────────────────┘   └─────────────────────┘     │
│                                                          │
│   We use QEMU backend because Apple Virtualization      │
│   failed to boot Ubuntu cloud images properly            │
└─────────────────────────────────────────────────────────┘
```

---

### 2. Ubuntu Cloud Images

**Why Cloud Images instead of ISO?**

| Approach | Process | Time |
|----------|---------|------|
| Live ISO | Download → Boot → Click through installer → Reboot | 20-30 min/VM |
| **Cloud Image** | Download → Configure cloud-init → Boot ready | 2-3 min/VM |

**What is a Cloud Image?**
- Pre-installed, minimal Ubuntu system
- Designed for cloud providers (AWS, GCP, Azure)
- Uses cloud-init for first-boot configuration
- Format: qcow2 (QEMU Copy-On-Write)

**Download URL:**
```
https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img
```

The `arm64` suffix is critical for Apple Silicon (M1/M2/M3 chips).

---

### 3. Cloud-Init

**What is Cloud-Init?**
Cloud-init is the industry standard for early-stage initialization of cloud instances. It runs on first boot and configures the VM based on metadata you provide.

**Cloud-Init Data Sources:**
```
┌─────────────────────────────────────────────────────────┐
│                    Cloud-Init                            │
│                                                          │
│   Searches for configuration in order:                   │
│                                                          │
│   1. Cloud Provider Metadata Service (169.254.169.254)  │
│   2. Config Drive (labeled "cidata" or "CIDATA")        │  ← We use this
│   3. NoCloud (local files)                              │
│   4. Fallback to DHCP                                   │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**Our Cloud-Init ISO Structure:**
```
cloud-init.iso (volume label: cidata)
├── meta-data          # Instance identification
├── user-data          # Main configuration (users, packages, etc.)
└── network-config     # Static IP configuration
```

**meta-data** (YAML):
```yaml
instance-id: master-1
local-hostname: master-1
```
- `instance-id`: Unique identifier; changing this triggers re-initialization
- `local-hostname`: Sets the VM's hostname

**user-data** (YAML with #cloud-config header):
```yaml
#cloud-config
hostname: master-1
manage_etc_hosts: true

users:
  - name: k8s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $6$rounds=4096$xyz...    # Hashed password
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... k8slab

write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      192.168.64.10 haproxy
      192.168.64.31 master-1
      ...

package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent
```

Key sections:
- `users`: Create user with SSH key and sudo access
- `write_files`: Write /etc/hosts for hostname resolution
- `packages`: Install packages on first boot
- `runcmd`: Run commands after boot

**network-config** (Netplan format):
```yaml
version: 2
ethernets:
  enp0s1:
    dhcp4: false
    addresses:
      - 192.168.64.31/24
    routes:
      - to: default
        via: 192.168.64.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
```

The interface name `enp0s1` is consistent across all UTM/QEMU VMs with VirtIO networking.

---

### 4. Creating the Cloud-Init ISO

**The Challenge:**
Cloud-init expects an ISO filesystem with specific format. macOS's `hdiutil` creates HFS+ format which cloud-init doesn't recognize.

**Failed Approach (hdiutil):**
```bash
# This creates HFS+ format - DOES NOT WORK with cloud-init
hdiutil makehybrid -iso -joliet -o cloud-init.iso ./cloud-init-dir/
```

**Working Approach (mkisofs/genisoimage):**
```bash
# Install cdrtools (provides mkisofs)
brew install cdrtools

# Create ISO9660 format with "cidata" volume label
mkisofs -output cloud-init.iso \
        -volid cidata \           # Critical: cloud-init looks for this label
        -joliet \
        -rock \
        ./cloud-init-dir/
```

The `-volid cidata` flag is essential - cloud-init searches for drives labeled "cidata" or "CIDATA".

---

### 5. UTM VM Configuration

**UTM stores VMs as bundles:**
```
~/Library/Containers/com.utmapp.UTM/Data/Documents/
└── master-1.utm/
    ├── config.plist        # VM configuration
    ├── Data/
    │   ├── disk.qcow2      # Main disk image
    │   └── cloud-init.iso  # Cloud-init configuration
    └── ...
```

**Key config.plist settings:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- Use QEMU backend, not Apple Virtualization -->
    <key>Backend</key>
    <string>QEMU</string>
    
    <!-- VM Display Name -->
    <key>Name</key>
    <string>master-1</string>
    
    <!-- System Configuration -->
    <key>System</key>
    <dict>
        <key>Architecture</key>
        <string>aarch64</string>          <!-- ARM64 for Apple Silicon -->
        
        <key>CPU</key>
        <dict>
            <key>Count</key>
            <integer>2</integer>           <!-- vCPUs -->
        </dict>
        
        <key>Memory</key>
        <integer>4096</integer>            <!-- RAM in MB -->
        
        <key>BootDevice</key>
        <string></string>                  <!-- Empty = boot from first disk -->
    </dict>
    
    <!-- UEFI Boot (required for ARM64) -->
    <key>QEMU</key>
    <dict>
        <key>UEFIBoot</key>
        <true/>
    </dict>
    
    <!-- Drives Configuration -->
    <key>Drives</key>
    <array>
        <!-- Main OS Disk -->
        <dict>
            <key>ImageName</key>
            <string>disk.qcow2</string>
            <key>ImageType</key>
            <string>Disk</string>
            <key>Interface</key>
            <string>VirtIO</string>        <!-- Fast paravirtualized disk -->
        </dict>
        
        <!-- Cloud-Init ISO -->
        <dict>
            <key>ImageName</key>
            <string>cloud-init.iso</string>
            <key>ImageType</key>
            <string>CD</string>
            <key>Interface</key>
            <string>USB</string>           <!-- USB interface for CD -->
        </dict>
    </array>
    
    <!-- Network Configuration -->
    <key>Network</key>
    <array>
        <dict>
            <key>Mode</key>
            <string>Shared</string>        <!-- NAT with host connectivity -->
            <key>Hardware</key>
            <string>virtio-net-pci</string>
        </dict>
    </array>
</dict>
</plist>
```

**Critical Settings Explained:**

| Setting | Value | Why |
|---------|-------|-----|
| `Backend` | `QEMU` | Apple Virtualization fails to boot cloud images |
| `Architecture` | `aarch64` | Apple Silicon is ARM64 |
| `UEFIBoot` | `true` | ARM64 requires UEFI, not legacy BIOS |
| `Disk Interface` | `VirtIO` | Paravirtualized for performance |
| `CD Interface` | `USB` | Cloud-init detects USB drives reliably |
| `Network Mode` | `Shared` | NAT with internet + host access |

---

### 6. Network Configuration

**UTM Network Modes:**

```
┌─────────────────────────────────────────────────────────┐
│                    Network Modes                         │
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   Shared    │  │   Bridged   │  │  Host Only  │      │
│  ├─────────────┤  ├─────────────┤  ├─────────────┤      │
│  │ • NAT mode  │  │ • Direct    │  │ • Isolated  │      │
│  │ • VMs get   │  │   network   │  │ • No        │      │
│  │   192.168.  │  │   access    │  │   internet  │      │
│  │   64.x IPs  │  │ • Gets real │  │ • VM-to-VM  │      │
│  │ • Internet  │  │   LAN IP    │  │   only      │      │
│  │   access    │  │ • Needs     │  │             │      │
│  │ • Host can  │  │   physical  │  │             │      │
│  │   reach VMs │  │   NIC       │  │             │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│        ↑                                                 │
│    We use this                                          │
└─────────────────────────────────────────────────────────┘
```

**Shared Network Details:**
- Creates `bridge100` interface on Mac
- Subnet: 192.168.64.0/24
- Gateway: 192.168.64.1 (Mac acts as router)
- DHCP: Available but we use static IPs
- NAT: Outbound traffic is translated

**IP Address Scheme:**
```
192.168.64.0/24

.1          Gateway (Mac bridge100)
.10         HAProxy (Load Balancer)
.11         Vault (Secrets Management)
.21-.23     etcd cluster (3 nodes)
.31-.32     Kubernetes masters (2 nodes)
.41-.43     Kubernetes workers (3 nodes)
```

---

### 7. Automation Script Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    create-all-vms.sh                         │
│                                                              │
│  Step 1: Check Dependencies                                  │
│  ├── Verify UTM installed                                   │
│  ├── Verify utmctl available                                │
│  ├── Verify mkisofs available                               │
│  └── Verify qemu-img available                              │
│                          ↓                                   │
│  Step 2: Download Cloud Image                               │
│  ├── Check if already downloaded                            │
│  └── curl Ubuntu 24.04 ARM64 cloud image                    │
│                          ↓                                   │
│  Step 3: Generate SSH Key                                   │
│  ├── Check if ~/.ssh/k8slab.key exists                      │
│  └── ssh-keygen -t ed25519 if not                           │
│                          ↓                                   │
│  Step 4: Create VMs (loop for each VM)                      │
│  ├── Create VM directory structure                          │
│  ├── Copy and resize base image (qemu-img)                  │
│  ├── Generate meta-data YAML                                │
│  ├── Generate user-data YAML (with /etc/hosts)              │
│  ├── Generate network-config YAML                           │
│  ├── Create cloud-init ISO (mkisofs)                        │
│  ├── Generate config.plist                                  │
│  └── Register VM with UTM (utmctl)                          │
│                          ↓                                   │
│  Step 5: Update Mac /etc/hosts                              │
│  └── Add entries for all VM hostnames                       │
│                          ↓                                   │
│  Step 6: Setup SSH Config                                   │
│  └── Add Host entries to ~/.ssh/config                      │
│                          ↓                                   │
│  Step 7: Start All VMs                                      │
│  └── utmctl start <vm-name> for each                        │
│                          ↓                                   │
│  Step 8: Wait for Boot                                      │
│  └── Sleep 600 seconds for cloud-init to complete           │
│                          ↓                                   │
│  Step 9: Connectivity Test                                  │
│  └── SSH to each VM to verify access                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

### 8. Troubleshooting Journey

During development, we encountered several issues:

**Issue 1: Apple Virtualization Boot Failure**
```
Error: "Failed to load Boot0001 EFI boot option"
```
- **Cause**: Apple Virtualization framework has stricter requirements
- **Solution**: Switch to QEMU backend in config.plist

**Issue 2: Cloud-Init Not Finding Datasource**
```
Error: "No datasource found"
```
- **Cause**: hdiutil creates HFS+ format ISOs, not ISO9660
- **Solution**: Use mkisofs with `-volid cidata`

**Issue 3: Network Interface Name Discovery**
```
Error: No IP address assigned
```
- **Cause**: Initially unsure which interface name Linux would use
- **Solution**: Verified `enp0s1` is consistent for UTM/QEMU with VirtIO networking

**Issue 4: ICMP (Ping) Blocked**
```
$ ping 8.8.8.8
# Times out
```
- **Cause**: UTM's NAT blocks ICMP by default
- **Solution**: Not a real problem - TCP/UDP works fine, K8s doesn't need ICMP

---

### 9. Key Files Reference

```
~/k8s-homelab/
├── images/
│   └── ubuntu-24.04-cloudimg-arm64.img    # Downloaded base image
├── scripts/
│   └── create-all-vms.sh                  # Main automation script
└── docs/
    └── 01-vm-setup-explained.md           # This document

~/.ssh/
├── k8slab.key                             # Private key for VMs
├── k8slab.key.pub                         # Public key (in cloud-init)
└── config                                 # SSH config with VM entries

/etc/hosts                                 # Updated with VM hostnames

~/Library/Containers/com.utmapp.UTM/Data/Documents/
├── master-1.utm/                          # VM bundle
│   ├── config.plist
│   └── Data/
│       ├── disk.qcow2
│       └── cloud-init.iso
├── master-2.utm/
├── worker-1.utm/
...
```

---

### 10. Commands Reference

**UTM CLI (utmctl):**
```bash
# List all VMs
utmctl list

# Start a VM
utmctl start master-1

# Stop a VM
utmctl stop master-1

# Delete a VM
utmctl delete master-1
```

**QEMU Image Management:**
```bash
# Create disk from base image with new size
qemu-img create -f qcow2 -F qcow2 -b base.img disk.qcow2 30G

# Check image info
qemu-img info disk.qcow2
```

**SSH Access:**
```bash
# Using SSH config (recommended)
ssh master-1

# Manual with key
ssh -i ~/.ssh/k8slab.key k8s@192.168.64.31
```

---

## Summary

| Component | Technology | Purpose |
|-----------|------------|---------|
| Hypervisor | UTM + QEMU | Run VMs on Apple Silicon |
| Guest OS | Ubuntu 24.04 Cloud Image | Pre-built, minimal system |
| Bootstrap | Cloud-Init | Zero-touch VM configuration |
| Config Drive | ISO9660 (mkisofs) | Deliver cloud-init data |
| Network | Shared (NAT) | Internet + host connectivity |
| Disk | qcow2 + VirtIO | Efficient copy-on-write storage |

**Result:** 10 production-like VMs created in ~5 minutes, fully automated, with static IPs, SSH access, and hostname resolution.

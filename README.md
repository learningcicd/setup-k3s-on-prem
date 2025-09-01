# K3s High Availability Installation Guide

A comprehensive guide for deploying K3s Kubernetes clusters with high availability, MetalLB load balancing, and proxy support for on-premises environments.

## 🏗️ Architecture Overview

This installation script creates a production-ready K3s cluster with:

- **High Availability**: Multiple master nodes with etcd clustering
- **MetalLB Load Balancer**: For LoadBalancer services in on-premises environments
- **Automatic Backups**: Scheduled etcd snapshots every 12 hours
- **Proxy Support**: Corporate firewall and proxy compatibility
- **Security**: Traefik disabled, custom service mesh ready

## 📋 Prerequisites

### System Requirements

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| **CPU** | 2 cores | 4+ cores | More cores for master nodes |
| **RAM** | 2GB | 4GB+ | Additional RAM for workloads |
| **Storage** | 20GB | 50GB+ | Includes space for etcd snapshots |
| **Network** | 1Gbps | 10Gbps | Stable connection between nodes |

### Supported Operating Systems

- Ubuntu 18.04+ (LTS recommended)
- Debian 9+
- CentOS 7+ / RHEL 7+
- SUSE Linux Enterprise Server 15+
- Architecture: x86_64, ARM64

### Network Prerequisites

#### Required Ports

| Port | Protocol | Source | Destination | Purpose |
|------|----------|--------|-------------|---------|
| 6443 | TCP | Workers, External | Masters | Kubernetes API server |
| 2379 | TCP | Masters | Masters | etcd client requests |
| 2380 | TCP | Masters | Masters | etcd peer communication |
| 10250 | TCP | Masters | All nodes | Kubelet API |
| 8472 | UDP | All nodes | All nodes | Flannel VXLAN (CNI) |
| 30000-32767 | TCP | External | All nodes | NodePort services (optional) |

#### Firewall Configuration

```bash
# CentOS/RHEL with firewalld
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=2379/tcp
sudo firewall-cmd --permanent --add-port=2380/tcp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=8472/udp
sudo firewall-cmd --reload
```

### Network Planning

#### IP Address Ranges

Plan your network ranges to avoid conflicts:

```yaml
# Default Configuration
Cluster CIDR: 10.42.0.0/16    # Pod IP addresses
Service CIDR: 10.43.0.0/16    # Service IP addresses
MetalLB Range: 192.168.1.240-192.168.1.250  # LoadBalancer IPs

# Customizable via script parameters
--metallb-range "YOUR_RANGE"
```

#### DNS Requirements

- All nodes should be able to resolve each other by hostname
- Or maintain proper `/etc/hosts` entries
- External DNS access for downloading components (unless using proxy)

## 🚀 Installation Guide

### Build Script

```bash
#!/bin/bash

# Configuration variables
MASTER_IP="173.224.122.95"
TOKEN_FILE="/tmp/k3s-node-token"

# Proxy configuration (set these if behind corporate proxy)
HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.cluster.local"

# MetalLB IP range (adjust for your network)
METALLB_IP_RANGE="192.168.1.240-192.168.1.250"
INSTALL_METALLB=true

# Function to display usage
show_usage() {
    echo "========================================"
    echo "   K3s Simple Installation Script      "
    echo "   with MetalLB + Proxy Support        "
    echo "========================================"
    echo ""
    echo "Usage: $0 [OPTIONS] MODE"
    echo ""
    echo "Modes:"
    echo "  --master          Install as master node"
    echo "  --worker          Install as worker node (requires --token)"
    echo ""
    echo "Options:"
    echo "  --master-ip IP           Master node IP address (default: $MASTER_IP)"
    echo "  --token TOKEN            K3s join token (required for --worker)"
    echo "  --metallb-range RANGE    MetalLB IP range (default: $METALLB_IP_RANGE)"
    echo "  --skip-metallb           Skip MetalLB installation"
    echo "  --http-proxy URL         HTTP proxy URL"
    echo "  --https-proxy URL        HTTPS proxy URL"
    echo "  --no-proxy LIST          No proxy list (default: internal ranges)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install master node"
    echo "  $0 --master"
    echo ""
    echo "  # Install master without MetalLB"
    echo "  $0 --master --skip-metallb"
    echo ""
    echo "  # Install master with custom MetalLB range"
    echo "  $0 --master --metallb-range '10.0.1.100-10.0.1.110'"
    echo ""
    echo "  # Install worker node"
    echo "  $0 --worker --token TOKEN --master-ip 192.168.1.10"
    echo ""
    echo "  # Install with proxy support and no MetalLB"
    echo "  $0 --master --skip-metallb --http-proxy http://proxy:8080 --https-proxy http://proxy:8080"
    echo ""
}

# Function to setup proxy environment
setup_proxy() {
    if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
        echo "[INFO] Configuring proxy settings..."
        
        # Set environment variables
        export http_proxy="$HTTP_PROXY"
        export https_proxy="$HTTPS_PROXY"
        export HTTP_PROXY="$HTTP_PROXY"
        export HTTPS_PROXY="$HTTPS_PROXY"
        export no_proxy="$NO_PROXY"
        export NO_PROXY="$NO_PROXY"
        
        # Configure apt proxy
        if [ -n "$HTTP_PROXY" ]; then
            echo "Acquire::http::Proxy \"$HTTP_PROXY\";" | sudo tee /etc/apt/apt.conf.d/01proxy
            echo "Acquire::https::Proxy \"$HTTPS_PROXY\";" | sudo tee -a /etc/apt/apt.conf.d/01proxy
        fi
        
        # Configure Docker/containerd proxy (for K3s)
        sudo mkdir -p /etc/systemd/system/k3s.service.d
        cat <<EOF | sudo tee /etc/systemd/system/k3s.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=$HTTP_PROXY"
Environment="HTTPS_PROXY=$HTTPS_PROXY"
Environment="NO_PROXY=$NO_PROXY"
EOF
    fi
}

# Function to install MetalLB
install_metallb() {
    echo "[INFO] Installing MetalLB load balancer..."
    
    # Install MetalLB
    sudo k3s kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
    
    # Wait for MetalLB to be ready
    echo "[INFO] Waiting for MetalLB to be ready..."
    sudo k3s kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=90s
    
    # Create IP address pool
    cat <<EOF | sudo k3s kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
    
    echo "[SUCCESS] MetalLB installed with IP range: $METALLB_IP_RANGE"
}

# Function to install Helm (useful for future deployments)
install_helm() {
    if ! command -v helm &> /dev/null; then
        echo "[INFO] Installing Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        echo "[SUCCESS] Helm installed successfully"
    else
        echo "[INFO] Helm already installed"
    fi
}

# Function to perform common system setup
common_setup() {
    echo "[INFO] Performing common system setup..."
    sudo swapoff -a
    sudo sed -i '/swap/d' /etc/fstab

    # Setup proxy if needed
    setup_proxy

    # Update system
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y curl apt-transport-https openssl
}

# Function to configure firewall and final settings
final_configuration() {
    echo "[INFO] Applying final configurations..."

    # Configure firewall rules (if ufw is installed)
    if command -v ufw &> /dev/null; then
        sudo ufw allow 6443/tcp   # K3s API server
        sudo ufw allow 10250/tcp  # Kubelet
        echo "[INFO] Firewall rules configured"
    fi

    # Create useful aliases
    cat <<EOF | sudo tee /etc/profile.d/k3s-aliases.sh
alias k='k3s kubectl'
alias kgp='k3s kubectl get pods'
alias kgs='k3s kubectl get services'
alias kgn='k3s kubectl get nodes'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF
}

# Function to install master node
install_master() {
    echo "[INFO] Installing K3s as MASTER (Traefik disabled)..."
    
    common_setup
    
    # Install K3s with basic configuration
    if [ "$INSTALL_METALLB" = true ]; then
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
            --disable=traefik \
            --disable=servicelb \
            --write-kubeconfig-mode=644" sh -
    else
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
            --disable=traefik \
            --write-kubeconfig-mode=644" sh -
    fi
    
    # Save token for worker nodes
    echo "[INFO] Saving cluster configuration..."
    sudo cat /var/lib/rancher/k3s/server/node-token | sudo tee $TOKEN_FILE
    sudo chmod 644 $TOKEN_FILE
    
    # Wait for K3s to be ready
    echo "[INFO] Waiting for K3s to be ready..."
    until sudo k3s kubectl get nodes &> /dev/null; do
        echo "Waiting for K3s API server..."
        sleep 5
    done
    
    # Install MetalLB if requested
    if [ "$INSTALL_METALLB" = true ]; then
        install_metallb
    else
        echo "[INFO] Skipping MetalLB installation (using K3s ServiceLB)"
    fi
    
    # Install Helm for future use
    install_helm
    
    # Final configuration
    final_configuration
    
    # Display cluster information
    echo ""
    echo "[SUCCESS] Master node installed successfully!"
    echo "========================================="
    echo "Cluster Information:"
    if [ "$INSTALL_METALLB" = true ]; then
        echo "- MetalLB LoadBalancer enabled"
    else
        echo "- K3s ServiceLB enabled (NodePort/LoadBalancer)"
    fi
    echo "- Helm package manager installed"
    echo "- Single master node (non-HA)"
    echo ""
    echo "To add WORKER nodes, use:"
    echo "$0 --worker --token \$(sudo cat $TOKEN_FILE) --master-ip $MASTER_IP"
    echo ""
    echo "Join token: $(sudo cat $TOKEN_FILE 2>/dev/null || echo 'Check /tmp/k3s-node-token')"
    echo "========================================="
}

# Function to install worker node
install_worker() {
    if [ -z "$NODE_TOKEN" ]; then
        echo "[ERROR] --token is required for --worker mode"
        echo "Use --help for usage information"
        exit 1
    fi
    
    echo "[INFO] Installing K3s as WORKER..."
    
    common_setup
    
    curl -sfL https://get.k3s.io | \
    K3S_URL="https://$MASTER_IP:6443" \
    K3S_TOKEN="$NODE_TOKEN" sh -
    
    final_configuration
    
    echo "[SUCCESS] Worker node joined cluster."
}

# Parse command line arguments
MODE=""
NODE_TOKEN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --master)
            MODE="master"
            shift
            ;;
        --worker)
            MODE="worker"
            shift
            ;;
        --master-ip)
            MASTER_IP="$2"
            shift 2
            ;;
        --token)
            NODE_TOKEN="$2"
            shift 2
            ;;
        --skip-metallb)
            INSTALL_METALLB=false
            shift
            ;;
        --metallb-range)
            METALLB_IP_RANGE="$2"
            shift 2
            ;;
        --http-proxy)
            HTTP_PROXY="$2"
            shift 2
            ;;
        --https-proxy)
            HTTPS_PROXY="$2"
            shift 2
            ;;
        --no-proxy)
            NO_PROXY="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if mode is specified
if [ -z "$MODE" ]; then
    echo "[ERROR] No mode specified"
    show_usage
    exit 1
fi

# Execute based on mode
case $MODE in
    master)
        install_master
        ;;
    worker)
        install_worker
        ;;
    *)
        echo "[ERROR] Invalid mode: $MODE"
        show_usage
        exit 1
        ;;
esac

echo ""
echo "[SUCCESS] Installation completed!"
echo "Useful commands:"
echo "- Check cluster status: k3s kubectl get nodes"
echo "- View all pods: k3s kubectl get pods -A"
if [ "$INSTALL_METALLB" = true ]; then
    echo "- Check MetalLB: k3s kubectl get pods -n metallb-system"
else
    echo "- Check ServiceLB: k3s kubectl get svc (NodePort services)"
fi
echo ""
echo "Reload your shell or run: source /etc/profile.d/k3s-aliases.sh"
```

### Download and Prepare Script

```bash
# Download the script
curl -O https://raw.githubusercontent.com/your-repo/k3s-ha-install.sh
chmod +x k3s-ha-install.sh

# View help
./k3s-ha-install.sh --help
```

### Deployment Scenarios

#### Scenario 1: Single Master (Development)

```bash
# Install single master node
./k3s-ha-install.sh --master

```

#### Scenario 3: Corporate Environment with Proxy

```bash
# Install with proxy support
./k3s-ha-install.sh --master \
    --http-proxy "http://proxy.company.com:8080" \
    --https-proxy "http://proxy.company.com:8080" \
    --metallb-range "172.16.10.100-172.16.10.110"
```

## 🔧 Script Parameters Reference

### Required Parameters

| Parameter | Description | Required For | Example |
|-----------|-------------|--------------|---------|
| `--master` | Install as first master | First master only | `--master` |
| `--worker` | Install as worker node | Worker nodes only | `--worker` |
| `--token` | K3s join token | Workers, HA masters | `--token abc123...` |
| `--secret` | Cluster secret | HA masters only | `--secret def456...` |

### Optional Parameters

| Parameter | Default | Description | Example |
|-----------|---------|-------------|---------|
| `--master-ip` | 173.224.122.95 | Master node IP address | `--master-ip 192.168.1.10` |
| `--metallb-range` | 192.168.1.240-250 | MetalLB IP range | `--metallb-range 10.0.1.100-10.0.1.110` |
| `--http-proxy` | None | HTTP proxy URL | `--http-proxy http://proxy:8080` |
| `--https-proxy` | None | HTTPS proxy URL | `--https-proxy http://proxy:8080` |
| `--no-proxy` | Internal ranges | No proxy list | `--no-proxy localhost,10.0.0.0/8` |

## 📊 Post-Installation Verification

### Cluster Health Checks

```bash
# Check all nodes
k3s kubectl get nodes -o wide

# Check system pods
k3s kubectl get pods -A

# Check MetalLB status
k3s kubectl get pods -n metallb-system

# Check etcd cluster health (on masters)
k3s kubectl get endpoints kube-scheduler -n kube-system -o yaml
```







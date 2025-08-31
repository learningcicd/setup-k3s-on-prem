#!/bin/bash

# Configuration variables
MASTER_IP=""
TOKEN_FILE="/tmp/k3s-node-token"
KUBECONFIG_FILE="/etc/rancher/k3s/k3s.yaml"

# Proxy configuration (set these if behind corporate proxy)
HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY=""

# MetalLB IP range (adjust for your network)
METALLB_IP_RANGE=""

# High Availability configuration
CLUSTER_SECRET=""
EXTERNAL_DB=""  # Optional: external database for HA (e.g., "postgres://user:pass@host:5432/k3s")

# Function to display usage
show_usage() {
    echo "========================================"
    echo "   K3s HA Installation Script          "
    echo "   with MetalLB + Proxy Support        "
    echo "========================================"
    echo ""
    echo "Usage: $0 [OPTIONS] MODE"
    echo ""
    echo "Modes:"
    echo "  --master          Install as first master node"
    echo "  --master-ha       Install as additional master node (requires --token and --secret)"
    echo "  --worker          Install as worker node (requires --token)"
    echo ""
    echo "Options:"
    echo "  --master-ip IP           Master node IP address (default: $MASTER_IP)"
    echo "  --token TOKEN            K3s join token (required for --master-ha and --worker)"
    echo "  --secret SECRET          Cluster secret (required for --master-ha)"
    echo "  --metallb-range RANGE    MetalLB IP range (default: $METALLB_IP_RANGE)"
    echo "  --http-proxy URL         HTTP proxy URL"
    echo "  --https-proxy URL        HTTPS proxy URL"
    echo "  --no-proxy LIST          No proxy list (default: internal ranges)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install first master node"
    echo "  $0 --master"
    echo ""
    echo "  # Install additional master with proxy"
    echo "  $0 --master-ha --token TOKEN --secret SECRET --http-proxy http://proxy:8080"
    echo ""
    echo "  # Install worker node"
    echo "  $0 --worker --token TOKEN --master-ip 192.168.1.10"
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

# Function to configure high availability
configure_ha() {
    echo "[INFO] Configuring high availability settings..."
    
    # Create cluster secret if not provided
    if [ -z "$CLUSTER_SECRET" ]; then
        CLUSTER_SECRET=$(openssl rand -base64 32)
        echo "[INFO] Generated cluster secret: $CLUSTER_SECRET"
        echo "IMPORTANT: Save this secret for additional master nodes!"
    fi
    
    # Configure etcd snapshot settings for backup
    cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 10
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
EOF
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
        sudo ufw allow 2379/tcp   # ETCD client
        sudo ufw allow 2380/tcp   # ETCD peer
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

# Function to install first master node
install_master() {
    echo "[INFO] Installing K3s as FIRST MASTER (Traefik disabled)..."
    
    common_setup
    configure_ha
    
    # Install K3s with HA configuration
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
        --disable=traefik \
        --disable=servicelb \
        --cluster-secret=$CLUSTER_SECRET \
        --write-kubeconfig-mode=644 \
        --etcd-snapshot-schedule-cron='0 */12 * * *' \
        --etcd-snapshot-retention=10" sh -
    
    # Save tokens and configuration
    echo "[INFO] Saving cluster configuration..."
    sudo cat /var/lib/rancher/k3s/server/node-token | sudo tee $TOKEN_FILE
    sudo chmod 644 $TOKEN_FILE
    
    # Wait for K3s to be ready
    echo "[INFO] Waiting for K3s to be ready..."
    until sudo k3s kubectl get nodes &> /dev/null; do
        echo "Waiting for K3s API server..."
        sleep 5
    done
    
    # Install MetalLB
    install_metallb
    
    # Install Helm for future use
    install_helm
    
    # Final configuration
    final_configuration
    
    # Display cluster information
    echo ""
    echo "[SUCCESS] First master node installed successfully!"
    echo "========================================="
    echo "Cluster Information:"
    echo "- MetalLB LoadBalancer enabled"
    echo "- Helm package manager installed"
    echo "- ETCD snapshots configured (every 12 hours)"
    echo "- Cluster Secret: $CLUSTER_SECRET"
    echo ""
    echo "For ADDITIONAL MASTER nodes, use:"
    echo "$0 --master-ha --token \$(sudo cat $TOKEN_FILE) --secret $CLUSTER_SECRET --master-ip $MASTER_IP"
    echo ""
    echo "For WORKER nodes, use:"
    echo "$0 --worker --token \$(sudo cat $TOKEN_FILE) --master-ip $MASTER_IP"
    echo "========================================="
}

# Function to install additional master node
install_master_ha() {
    if [ -z "$NODE_TOKEN" ] || [ -z "$CLUSTER_SECRET" ]; then
        echo "[ERROR] --token and --secret are required for --master-ha mode"
        echo "Use --help for usage information"
        exit 1
    fi
    
    echo "[INFO] Installing K3s as ADDITIONAL MASTER..."
    
    common_setup
    
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
        --disable=traefik \
        --disable=servicelb \
        --server=https://$MASTER_IP:6443 \
        --token=$NODE_TOKEN \
        --cluster-secret=$CLUSTER_SECRET \
        --write-kubeconfig-mode=644" sh -
    
    final_configuration
    
    echo "[SUCCESS] Additional master node joined cluster."
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
        --master-ha)
            MODE="master-ha"
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
        --secret)
            CLUSTER_SECRET="$2"
            shift 2
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
    master-ha)
        install_master_ha
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
echo "- Check MetalLB: k3s kubectl get pods -n metallb-system"
echo ""
echo "Reload your shell or run: source /etc/profile.d/k3s-aliases.sh"

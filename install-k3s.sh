#!/bin/bash

# Configuration variables
MASTER_IP=""
METALLB_IP_RANGE=""
INSTALL_METALLB=false

# Proxy configuration (set these if behind corporate proxy)
HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY=""

# Function to detect OS and set appropriate commands
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        echo "[ERROR] Cannot detect OS version"
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update && apt upgrade -y"
            PKG_INSTALL="apt install -y"
            FIREWALL_CMD="ufw"
            ;;
        rhel|centos|rocky|almalinux|fedora)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf update -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MANAGER="yum"
                PKG_UPDATE="yum update -y"
                PKG_INSTALL="yum install -y"
            fi
            FIREWALL_CMD="firewalld"
            ;;
        *)
            echo "[WARNING] Unsupported OS: $OS. Attempting with dnf/yum..."
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf update -y"
            PKG_INSTALL="dnf install -y"
            FIREWALL_CMD="firewalld"
            ;;
    esac
    
    echo "[INFO] Detected OS: $OS $OS_VERSION"
    echo "[INFO] Using package manager: $PKG_MANAGER"
}
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
    echo "  --cleanup         Uninstall K3s and cleanup system"
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
    echo "  # Cleanup/uninstall K3s"
    echo "  $0 --cleanup"
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
        
        # Configure apt/yum proxy
        if [ -n "$HTTP_PROXY" ]; then
            if [ "$PKG_MANAGER" = "apt" ]; then
                echo "Acquire::http::Proxy \"$HTTP_PROXY\";" | sudo tee /etc/apt/apt.conf.d/01proxy
                echo "Acquire::https::Proxy \"$HTTPS_PROXY\";" | sudo tee -a /etc/apt/apt.conf.d/01proxy
            else
                # For RHEL/CentOS/Fedora
                echo "proxy=$HTTP_PROXY" | sudo tee -a /etc/yum.conf
            fi
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

# Function to cleanup/uninstall K3s
cleanup_k3s() {
    echo "[INFO] Starting K3s cleanup and uninstallation..."
    echo ""
    
    # Ask for confirmation
    read -p "This will completely remove K3s and all associated data. Continue? [y/N]: " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "[INFO] Cleanup cancelled."
        exit 0
    fi
    
    echo "[INFO] Proceeding with cleanup..."
    echo ""
    
    # Step 1: Stop K3s service
    echo "[INFO] Stopping K3s service..."
    if systemctl is-active --quiet k3s; then
        sudo systemctl stop k3s
        echo "✅ K3s service stopped"
    else
        echo "ℹ️  K3s service not running"
    fi
    
    # Step 2: Run K3s uninstall script (if it exists)
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        echo "[INFO] Running K3s uninstall script..."
        sudo /usr/local/bin/k3s-uninstall.sh
        echo "✅ K3s uninstall script completed"
    elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        echo "[INFO] Running K3s agent uninstall script..."
        sudo /usr/local/bin/k3s-agent-uninstall.sh
        echo "✅ K3s agent uninstall script completed"
    else
        echo "ℹ️  No K3s uninstall script found, proceeding with manual cleanup"
    fi
    
    # Step 3: Remove K3s binaries
    echo "[INFO] Removing K3s binaries..."
    sudo rm -f /usr/local/bin/k3s
    sudo rm -f /usr/local/bin/crictl
    sudo rm -f /usr/local/bin/ctr
    echo "✅ K3s binaries removed"
    
    # Step 4: Remove K3s data directories
    echo "[INFO] Removing K3s data directories..."
    sudo rm -rf /etc/rancher/k3s
    sudo rm -rf /var/lib/rancher/k3s
    sudo rm -rf /var/lib/kubelet
    sudo rm -rf /var/lib/cni
    sudo rm -rf /var/log/pods
    sudo rm -rf /var/log/containers
    echo "✅ K3s data directories removed"
    
    # Step 5: Remove systemd service files
    echo "[INFO] Removing systemd service files..."
    sudo rm -f /etc/systemd/system/k3s.service
    sudo rm -f /etc/systemd/system/k3s-agent.service
    sudo rm -rf /etc/systemd/system/k3s.service.d
    sudo rm -rf /etc/systemd/system/k3s-agent.service.d
    sudo systemctl daemon-reload
    echo "✅ Systemd service files removed"
    
    # Step 6: Remove network interfaces
    echo "[INFO] Cleaning up network interfaces..."
    # Remove CNI interfaces
    for iface in $(ip link show | grep -E "(cni|flannel|veth)" | awk -F: '{print $2}' | tr -d ' '); do
        if [ -n "$iface" ]; then
            sudo ip link delete "$iface" 2>/dev/null || true
        fi
    done
    
    # Remove bridge interfaces
    for bridge in $(ip link show type bridge | grep -E "(cni|k3s)" | awk -F: '{print $2}' | tr -d ' '); do
        if [ -n "$bridge" ]; then
            sudo ip link delete "$bridge" 2>/dev/null || true
        fi
    done
    echo "✅ Network interfaces cleaned"
    
    # Step 7: Remove CNI configuration
    echo "[INFO] Removing CNI configuration..."
    sudo rm -rf /etc/cni/net.d
    sudo rm -rf /opt/cni/bin
    echo "✅ CNI configuration removed"
    
    # Step 8: Clean up iptables rules
    echo "[INFO] Cleaning up iptables rules..."
    # Remove K3s-related chains and rules
    sudo iptables -t nat -F K3S-NODEPORTS 2>/dev/null || true
    sudo iptables -t nat -F K3S-POSTROUTING 2>/dev/null || true
    sudo iptables -t filter -F K3S-FIREWALL 2>/dev/null || true
    sudo iptables -t nat -X K3S-NODEPORTS 2>/dev/null || true
    sudo iptables -t nat -X K3S-POSTROUTING 2>/dev/null || true
    sudo iptables -t filter -X K3S-FIREWALL 2>/dev/null || true
    
    # Flush and remove KUBE-* chains
    for table in filter nat mangle; do
        for chain in $(sudo iptables -t $table -L | grep "^Chain KUBE-" | awk '{print $2}'); do
            sudo iptables -t $table -F "$chain" 2>/dev/null || true
            sudo iptables -t $table -X "$chain" 2>/dev/null || true
        done
    done
    echo "✅ iptables rules cleaned"
    
    # Step 9: Remove configuration files and aliases
    echo "[INFO] Removing configuration files..."
    sudo rm -f /etc/profile.d/k3s-aliases.sh
    
    # Remove proxy configurations based on what was likely set
    sudo rm -f /etc/apt/apt.conf.d/01proxy
    
    # Remove yum/dnf proxy configuration (be careful not to break existing config)
    if [ -f /etc/yum.conf ]; then
        sudo sed -i '/^proxy=/d' /etc/yum.conf 2>/dev/null || true
    fi
    
    echo "✅ Configuration files removed"
    
    # Step 10: Remove any leftover mount points
    echo "[INFO] Cleaning up mount points..."
    # Unmount any remaining kubelet mounts
    for mount in $(mount | grep kubelet | awk '{print $3}'); do
        sudo umount "$mount" 2>/dev/null || true
    done
    
    # Unmount any remaining container mounts
    for mount in $(mount | grep -E "(containers|pods)" | awk '{print $3}'); do
        sudo umount "$mount" 2>/dev/null || true
    done
    echo "✅ Mount points cleaned"
    
    # Step 11: Remove containers and images (if containerd is still running)
    echo "[INFO] Cleaning up containers and images..."
    if command -v crictl &> /dev/null; then
        sudo crictl rmi --all 2>/dev/null || true
        sudo crictl rm --all 2>/dev/null || true
    fi
    echo "✅ Container cleanup attempted"
    
    # Step 12: Clean up any remaining processes
    echo "[INFO] Stopping any remaining K3s processes..."
    sudo pkill -f k3s 2>/dev/null || true
    sudo pkill -f containerd 2>/dev/null || true
    sudo pkill -f kubelet 2>/dev/null || true
    echo "✅ Processes cleaned"
    
    # Step 14: Clean up firewall rules
    echo "[INFO] Cleaning up firewall rules..."
    
    # Clean UFW rules (Ubuntu/Debian)
    if command -v ufw &> /dev/null; then
        sudo ufw delete allow 6443/tcp 2>/dev/null || true
        sudo ufw delete allow 10250/tcp 2>/dev/null || true
        sudo ufw delete allow 7946/tcp 2>/dev/null || true
        sudo ufw delete allow 7946/udp 2>/dev/null || true
        echo "✅ UFW rules cleaned"
    fi
    
    # Clean firewalld rules (RHEL/CentOS)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        sudo firewall-cmd --permanent --remove-port=6443/tcp 2>/dev/null || true
        sudo firewall-cmd --permanent --remove-port=10250/tcp 2>/dev/null || true
        sudo firewall-cmd --permanent --remove-port=8472/udp 2>/dev/null || true
        sudo firewall-cmd --permanent --remove-port=7946/tcp 2>/dev/null || true
        sudo firewall-cmd --permanent --remove-port=7946/udp 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        echo "✅ Firewalld rules cleaned"
    fi
    read -p "Remove Helm as well? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[INFO] Removing Helm..."
        sudo rm -f /usr/local/bin/helm
        sudo rm -rf ~/.helm
        sudo rm -rf ~/.cache/helm
        sudo rm -rf ~/.config/helm
        echo "✅ Helm removed"
    else
        echo "ℹ️  Keeping Helm installation"
    fi
    
    echo ""
    echo "========================================="
    echo "[SUCCESS] K3s cleanup completed!"
    echo "========================================="
    echo ""
    echo "What was removed:"
    echo "✅ K3s binaries and services"
    echo "✅ All K3s data and configuration"
    echo "✅ Network interfaces and CNI config"
    echo "✅ iptables rules and chains"
    echo "✅ Mount points and processes"
    echo "✅ Container images and data"
    echo ""
    echo "Notes:"
    echo "• A reboot is recommended to ensure all changes take effect"
    echo "• Some network settings may require manual cleanup"
    echo "• Check 'ip link show' for any remaining interfaces"
    echo ""
    echo "To reinstall K3s, run this script with --master or --worker"
    echo "========================================="
}
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
    
    # Detect OS first
    detect_os
    
    # Disable swap
    sudo swapoff -a
    if [ "$PKG_MANAGER" = "apt" ]; then
        sudo sed -i '/swap/d' /etc/fstab
    else
        # RHEL/CentOS may use different swap configuration
        sudo sed -i '/swap/d' /etc/fstab 2>/dev/null || true
        # Also check for swap in systemd
        sudo systemctl mask swap.target 2>/dev/null || true
    fi

    # Setup proxy if needed
    setup_proxy

    # Update system
    echo "[INFO] Updating system packages..."
    sudo $PKG_UPDATE
    
    # Install required packages
    echo "[INFO] Installing required packages..."
    if [ "$PKG_MANAGER" = "apt" ]; then
        sudo $PKG_INSTALL curl apt-transport-https openssl
    else
        sudo $PKG_INSTALL curl openssl wget
        # Install additional packages that might be needed on RHEL
        sudo $PKG_INSTALL iptables container-selinux
    fi
}

# Function to configure firewall and final settings
final_configuration() {
    echo "[INFO] Applying final configurations..."

    # Configure firewall rules based on the system
    if [ "$FIREWALL_CMD" = "ufw" ] && command -v ufw &> /dev/null; then
        echo "[INFO] Configuring UFW firewall..."
        sudo ufw allow 6443/tcp   # K3s API server
        sudo ufw allow 10250/tcp  # Kubelet
        if [ "$MODE" = "master" ] && [ "$INSTALL_METALLB" = true ]; then
            sudo ufw allow 7946/tcp   # MetalLB memberlist
            sudo ufw allow 7946/udp   # MetalLB memberlist
        fi
        echo "[INFO] UFW firewall rules configured"
        
    elif [ "$FIREWALL_CMD" = "firewalld" ] && systemctl is-active --quiet firewalld; then
        echo "[INFO] Configuring firewalld..."
        sudo firewall-cmd --permanent --add-port=6443/tcp    # K3s API server
        sudo firewall-cmd --permanent --add-port=10250/tcp   # Kubelet
        sudo firewall-cmd --permanent --add-port=8472/udp    # Flannel VXLAN
        if [ "$MODE" = "master" ] && [ "$INSTALL_METALLB" = true ]; then
            sudo firewall-cmd --permanent --add-port=7946/tcp   # MetalLB memberlist
            sudo firewall-cmd --permanent --add-port=7946/udp   # MetalLB memberlist
        fi
        sudo firewall-cmd --reload
        echo "[INFO] Firewalld rules configured"
        
    elif systemctl is-active --quiet firewalld; then
        echo "[WARNING] Firewalld is active but firewall-cmd not found"
        echo "[INFO] You may need to manually configure firewall rules"
        
    else
        echo "[INFO] No active firewall detected or firewall configuration skipped"
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
    local token_file="/var/lib/rancher/k3s/server/node-token"
    echo "[INFO] Worker join token saved at: $token_file"
    
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
    echo "$0 --worker --token \$(sudo cat /var/lib/rancher/k3s/server/node-token) --master-ip $MASTER_IP"
    echo ""
    echo "Join token: $(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo 'Run: sudo cat /var/lib/rancher/k3s/server/node-token')"
    echo "========================================="
}

# Function to install worker node
install_worker() {
    if [ -z "$JOIN_TOKEN" ]; then
        echo "[ERROR] --token is required for --worker mode"
        echo "Use --help for usage information"
        exit 1
    fi
    
    echo "[INFO] Installing K3s as WORKER..."
    
    common_setup
    
    curl -sfL https://get.k3s.io | \
    K3S_URL="https://$MASTER_IP:6443" \
    K3S_TOKEN="$JOIN_TOKEN" sh -
    
    final_configuration
    
    echo "[SUCCESS] Worker node joined cluster."
}

# Parse command line arguments
MODE=""
JOIN_TOKEN=""

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
        --cleanup)
            MODE="cleanup"
            shift
            ;;
        --master-ip)
            MASTER_IP="$2"
            shift 2
            ;;
        --token)
            JOIN_TOKEN="$2"
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
    cleanup)
        cleanup_k3s
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

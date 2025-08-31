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
# Ubuntu/Debian with UFW (handled automatically by script)
sudo ufw allow 6443/tcp
sudo ufw allow 2379/tcp
sudo ufw allow 2380/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 8472/udp

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

# Add worker nodes
./k3s-ha-install.sh --worker --token $(sudo cat /tmp/k3s-node-token) --master-ip MASTER_IP
```

#### Scenario 2: High Availability (Production)

```bash
# Step 1: Install first master node
./k3s-ha-install.sh --master --metallb-range "10.0.1.100-10.0.1.110"

# Step 2: Install second master node
./k3s-ha-install.sh --master-ha \
    --token $(sudo cat /tmp/k3s-node-token) \
    --secret CLUSTER_SECRET \
    --master-ip FIRST_MASTER_IP

# Step 3: Install third master node
./k3s-ha-install.sh --master-ha \
    --token $(sudo cat /tmp/k3s-node-token) \
    --secret CLUSTER_SECRET \
    --master-ip FIRST_MASTER_IP

# Step 4: Add worker nodes
./k3s-ha-install.sh --worker \
    --token $(sudo cat /tmp/k3s-node-token) \
    --master-ip FIRST_MASTER_IP
```

#### Scenario 3: Corporate Environment with Proxy

```bash
# Install with proxy support
./k3s-ha-install.sh --master \
    --http-proxy "http://proxy.company.com:8080" \
    --https-proxy "http://proxy.company.com:8080" \
    --metallb-range "172.16.10.100-172.16.10.110"

# Add HA masters with proxy
./k3s-ha-install.sh --master-ha \
    --token TOKEN \
    --secret SECRET \
    --master-ip MASTER_IP \
    --http-proxy "http://proxy.company.com:8080" \
    --https-proxy "http://proxy.company.com:8080"
```

## 🔧 Script Parameters Reference

### Required Parameters

| Parameter | Description | Required For | Example |
|-----------|-------------|--------------|---------|
| `--master` | Install as first master | First master only | `--master` |
| `--master-ha` | Install as additional master | HA masters only | `--master-ha` |
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

### Expected Output Examples

```bash
# Healthy 3-master cluster
$ k3s kubectl get nodes
NAME       STATUS   ROLES                       AGE   VERSION
master-1   Ready    control-plane,etcd,master   10m   v1.28.2+k3s1
master-2   Ready    control-plane,etcd,master   8m    v1.28.2+k3s1
master-3   Ready    control-plane,etcd,master   6m    v1.28.2+k3s1
worker-1   Ready    <none>                      4m    v1.28.2+k3s1
worker-2   Ready    <none>                      2m    v1.28.2+k3s1
```

### Testing MetalLB

```bash
# Create test service
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --type=LoadBalancer --port=80

# Check external IP assignment
kubectl get services
```

## 🔒 Security Considerations

### Default Security Features

- **Traefik Ingress Disabled**: Custom ingress controller can be installed
- **ServiceLB Disabled**: MetalLB provides better load balancing
- **Network Policies**: Supported via CNI (Flannel)
- **RBAC**: Enabled by default
- **TLS**: All cluster communication encrypted

### Additional Security Hardening

```bash
# Enable audit logging
echo "audit-policy-file: /etc/rancher/k3s/audit.yaml" >> /etc/rancher/k3s/config.yaml

# Create audit policy
cat > /etc/rancher/k3s/audit.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  namespaces: ["kube-system", "kube-public", "kube-node-lease"]
- level: Request
  resources:
  - group: ""
    resources: ["pods", "services"]
EOF
```

### Backup Strategy

The script automatically configures etcd snapshots:

```bash
# Manual snapshot
k3s etcd-snapshot save my-snapshot

# List snapshots
ls -la /var/lib/rancher/k3s/server/db/snapshots/

# Restore from snapshot (emergency only)
k3s server --cluster-reset --cluster-reset-restore-path=/path/to/snapshot
```

## 🔧 Troubleshooting

### Common Issues and Solutions

#### Issue: Nodes not joining cluster

```bash
# Check network connectivity
nc -zv MASTER_IP 6443

# Verify token
sudo cat /var/lib/rancher/k3s/server/node-token

# Check logs
journalctl -u k3s -f
```

#### Issue: MetalLB not assigning IPs

```bash
# Check MetalLB configuration
k3s kubectl get ipaddresspool -n metallb-system -o yaml

# Verify IP range availability
nmap -sn YOUR_IP_RANGE

# Check MetalLB logs
k3s kubectl logs -n metallb-system -l app=metallb
```

#### Issue: Proxy not working

```bash
# Verify proxy environment
env | grep -i proxy

# Test proxy connectivity
curl -x $HTTP_PROXY http://get.k3s.io

# Check systemd service environment
systemctl show k3s | grep Environment
```

### Log Locations

```bash
# K3s service logs
journalctl -u k3s -f

# K3s server logs
tail -f /var/lib/rancher/k3s/agent/logs/k3s.log

# Container runtime logs
crictl logs CONTAINER_ID
```

### Useful Commands

```bash
# Restart K3s service
sudo systemctl restart k3s

# Check K3s configuration
sudo cat /etc/rancher/k3s/config.yaml

# View cluster certificates
sudo k3s certificate rotate --help

# Check resource usage
k3s kubectl top nodes
k3s kubectl top pods -A
```

## 📈 Monitoring and Maintenance

### Built-in Monitoring

```bash
# Install metrics server (if needed)
k3s kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# View resource usage
k3s kubectl top nodes
k3s kubectl top pods -A
```

### Recommended Monitoring Stack

```bash
# Install Prometheus + Grafana using Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack
```

### Maintenance Tasks

```bash
# Update K3s (on each node)
curl -sfL https://get.k3s.io | sh -

# Clean up unused images
k3s crictl rmi --prune

# Rotate certificates (annually)
k3s certificate rotate
```

## 🚀 Scaling Operations

### Adding More Nodes

```bash
# Add worker node
./k3s-ha-install.sh --worker --token TOKEN --master-ip MASTER_IP

# Add master node (for scaling HA)
./k3s-ha-install.sh --master-ha --token TOKEN --secret SECRET --master-ip MASTER_IP
```

### Removing Nodes

```bash
# Drain node
k3s kubectl drain NODE_NAME --ignore-daemonsets --delete-emptydir-data

# Remove from cluster
k3s kubectl delete node NODE_NAME

# Uninstall K3s from node
/usr/local/bin/k3s-uninstall.sh
```


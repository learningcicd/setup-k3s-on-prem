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







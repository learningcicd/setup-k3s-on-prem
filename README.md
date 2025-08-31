# Setting Up K3s

## Installing Master 
### Pre-Requisites
*** Hardware Requirements ***

- CPU: Minimum 2 cores (4+ cores recommended for production)
- RAM: Minimum 2GB (4GB+ recommended for production)
- Storage: Minimum 20GB free space (50GB+ recommended for etcd snapshots)
- Network: Stable network connection between all nodes
- Operating System
    - Supported OS: Ubuntu 18.04+, Debian 9+, CentOS 7+, RHEL 7+, SLES 15+
- Architecture: x86_64 or ARM64
- Root/Sudo access required

- # K3s API Server
6443/tcp    # Kubernetes API server

# Kubelet API
10250/tcp   # Used by kubelet

# ETCD (for HA masters)
2379/tcp    # ETCD client requests
2380/tcp    # ETCD peer communication

# Flannel VXLAN (if using default CNI)
8472/udp    # Flannel VXLAN

# Node port services (optional)
30000-32767/tcp

Network Configuration

Static IP addresses recommended for all master nodes
DNS resolution between nodes (or proper /etc/hosts entries)
No conflicting services on required ports
Firewall rules configured (script handles UFW automatically)

```bash
./script.sh --master
```

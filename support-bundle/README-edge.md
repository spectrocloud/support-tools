# Edge Support Bundle Collection Script

This Bash script (`support-bundle-edge.sh`) is designed to collect various logs from an edge host and a Kubernetes cluster. The collected logs are then archived for troubleshooting and support purposes.

## Quick Start

To collect edge support bundle, you can use either of these methods:

Using the official SpectroCloud software URL:
```bash
curl -sSL https://software.spectrocloud.com/scripts/support-bundle-edge.sh
sudo bash support-bundle-edge.sh
```

Or using the GitHub repository URL:
```bash
curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-edge.sh
sudo bash support-bundle-edge.sh
```

## Prerequisites

* Run the script as a user with `sudo` privileges
* Run the script on all edge hosts
* Required dependencies:
  - `journalctl`: For accessing system journal logs
  - `systemctl`: For checking systemd services status
  - `kubectl`: For interacting with Kubernetes clusters

## Usage

Basic usage:
```bash
./support-bundle-edge.sh
```

Advanced usage with additional collection options:
```bash
./support-bundle-edge.sh -n hello-universe,hello-world -r certificates.cert-manager.io -R clusterissuers.cert-manager.io -j cloud-init,systemd-resolved
```

## Available Flags

All flags are optional:

| Flag | Description | Example |
|------|-------------|---------|
| `-d` | Output directory for temporary storage and .tar.gz archive | `-d /var/tmp` |
| `-s` | Start day of journald log collection | `-s 7` (7 days ago) |
| `-e` | End day of journald log collection | `-e 5` (5 days ago) |
| `-S` | Start date of journald log collection | `-S 2024-01-01` |
| `-E` | End date of journald log collection | `-E 2024-01-01` |
| `-l` | Number of log lines to collect | `-l 500000` |
| `-n` | Additional namespaces to collect | `-n hello-universe,hello-world` |
| `-r` | Additional namespace scoped resources | `-r certificates.cert-manager.io` |
| `-R` | Additional cluster scoped resources | `-R clusterissuers.cert-manager.io` |
| `-j` | Additional journald logs to collect | `-j cloud-init,systemd-resolved` |

## Environment Variables

* `KUBECONFIG`: Path to the Kubernetes configuration file
  * Default: `/run/kubeconfig` if not specified

## Important Notes

* Secrets are not collected as part of the support bundle
* Only helm release secrets for the spectrocloud namespaces are collected
* The script automatically detects the Kubernetes distribution (kubeadm, k3s, or rke2)
* Collected logs are stored in `/opt/spectrocloud/logs/` by default

## Output

The script creates a compressed tarball (`*.tar.gz`) containing all collected logs. The filename includes:
* Hostname
* Timestamp of collection

Example: `hostname-2024-03-21_14_30_45.tar.gz`

The tar archive is saved in `$TMPDIR` by default. You can specify a different output directory using the `-d` flag when running the script.

## Collected Information

The script collects various types of information:

### System Information
* System logs (journald)
* Network configuration
* System services status
* Host information

### Kubernetes Information
* Cluster information
* Resource states
* Pod logs
* Custom resources
* Metrics
* Helm releases

### Container Information
* Container runtime logs
* Container status
* Container metrics

### Edge-specific Information
* Stylus agent logs
* Palette agent logs
* Edge cluster configuration
* System upgrade information

## Collection Details

This document provides transparency about the output collected when running the support bundle script. The collection is designed to gather necessary troubleshooting information while respecting privacy and security concerns.

Where possible, output from the collection is sanitized. However, we recommend you check the log collection and remove or edit any sensitive data before sharing.

### Node-level Collection

Output that is collected only from the node where the support bundle script is run:

#### Operating System
* General OS configuration:
  * Hostname and system information
  * Resource utilization
  * Process list
  * Service list
  * System packages
  * System limits and tunables
* Networking information:
  * iptables rules
  * netstat output
  * Network interfaces
  * CNI configuration
* System logs:
  * Journalctl output for related services (see `JOURNALD_LOGS` variable in script)
  * OS logs from /var/log
  * System service logs

#### Kubernetes Distribution
* Distribution-specific logs:
  * k3s agent/server logs
  * rke2 agent/server logs
  * kubeadm logs
* Distribution configuration:
  * k3s configuration files
  * rke2 configuration files
  * Static pod manifests
* Container runtime:
  * containerd logs and configuration
  * Container runtime status and metrics

### Cluster-level Collection

Output that is collected from the cluster. Note that pod logs from other nodes and additional kubectl output can only be collected when running on a control plane/server node.

#### Kubernetes Components
* Control plane components:
  * kube-apiserver configuration and logs
  * kube-scheduler logs
  * kube-controller-manager logs
  * etcd logs and configuration
* Worker components:
  * kubelet configuration and logs
  * Container runtime logs
* System directories:
  * Kubernetes manifests
  * SSL certificates
  * etcd data (if applicable)

#### Kubernetes Resources
* Cluster resources:
  * Nodes information
  * Pod status and logs
  * Services configuration
  * RBAC roles and bindings
  * Persistent volumes
  * Events
  * Ingress configurations
  * Deployments and other workloads
* Custom resources:
  * Cluster API objects
  * Palette-specific resources
  * Other custom resources in system namespaces

### Edge-specific Collection

* Stylus agent logs and configuration
* Palette agent logs and status
* Edge cluster configuration
* System upgrade information
* Edge-specific custom resources
* Edge networking configuration

### MongoDB Collection (Enterprise Clusters Only)

For Enterprise and PCG clusters, the script collects MongoDB replica set information:

* `rs-status.json`: Replica set status including member health, sync state, and election info
* `rs-conf.json`: Replica set configuration including member settings and priorities
* `replication-info.txt`: Oplog information and replication window

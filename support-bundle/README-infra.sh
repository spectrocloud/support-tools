# Kubernetes Infrastructure Support Bundle Collection Script

This Bash script (`support-bundle-infra.sh`) is designed to collect logs specifically from a Kubernetes cluster. It gathers cluster information, Cluster API (CAPI) objects, and other relevant resources for troubleshooting and support purposes.

## Quick Start

To collect infrastructure support bundle, you can use either of these methods:

Using the official SpectroCloud software URL:
```bash
curl -sSL https://software.spectrocloud.com/scripts/support-bundle-infra.sh
bash support-bundle-infra.sh
```

Or using the GitHub repository URL:
```bash
curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-infra.sh
bash support-bundle-infra.sh
```

## Prerequisites

* Run the script as a user with `kubectl` access to the Kubernetes cluster
* Required dependency:
  - `kubectl`: For interacting with Kubernetes clusters

## Usage

Basic usage:
```bash
./support-bundle-infra.sh
```

## Configuration

The script uses the following configuration:

* `-d`: Output directory for temporary storage and .tar.gz archive (ex: -d /var/tmp)
* `KUBECONFIG`: Environment variable specifying the path to the Kubernetes configuration file
* `tmp_bundle_dir`: Temporary directory for storing intermediate logs
* `namespaces`: Array of Kubernetes namespaces to include in log collection

## Output

The script creates a compressed tarball (`*.tar.gz`) containing all collected logs. The filename includes:
* Cluster name
* Timestamp of collection

Example: `spectro-cluster-2024-03-21_14_30_45.tar.gz`

The tar archive is saved in the current working directory by default. You can specify a different output directory using the `-d` flag when running the script.

## Collected Information

The script collects various types of information:

### Cluster Information
* Cluster API (CAPI) objects
* Cluster resources
* Cluster configuration
* Cluster status

### Kubernetes Resources
* Namespace information
* Resource states
* Custom resources
* Cluster-wide resources

### Infrastructure Components
* Infrastructure provider information
* Network configuration
* Storage configuration
* Security settings

## Collection Details

This document provides transparency about the output collected when running the support bundle script. The collection is designed to gather necessary troubleshooting information while respecting privacy and security concerns.

Where possible, output from the collection is sanitized. However, we recommend you check the log collection and remove or edit any sensitive data before sharing.

### Cluster-level Collection

Output that is collected from the cluster. Note that some information can only be collected when running with appropriate cluster access permissions.

#### Kubernetes Components
* Control plane components:
  * kube-apiserver configuration and logs
  * kube-scheduler logs
  * kube-controller-manager logs
  * etcd logs and configuration (if applicable)
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

### Infrastructure Components
* Infrastructure provider information:
  * Cloud provider configuration
  * Infrastructure resources
  * Network configuration
  * Storage configuration
* Security settings:
  * Authentication configuration
  * Authorization policies
  * Network policies
  * Security contexts

### Management Cluster Information
* Palette management components:
  * Management cluster configuration
  * Cluster API resources
  * Infrastructure provider resources
  * Cluster provisioning status
* System resources:
  * Management cluster workloads
  * System services
  * Monitoring and logging components

## Important Notes

* The script requires proper kubectl access to the cluster
* Collected information is focused on infrastructure and cluster-level resources
* The script is designed to be run from a management cluster or a system with cluster access
* All collected data is stored in a temporary directory before being archived

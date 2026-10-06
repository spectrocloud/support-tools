# SpectroCloud Support Bundle Scripts

This repository contains a collection of scripts designed to gather diagnostic information from SpectroCloud environments for troubleshooting and support purposes.

## Available Scripts

### Consolidated Support Bundle (preview)
- **Script**: `support-bundle.sh`
- **Purpose**: Single script covering both the edge (host + cluster) and infrastructure (cluster-only) scopes. Collection is capability-driven and never aborts mid-run: each collector records OK / SKIP / FAIL / DENIED into `collection-summary.txt` inside the bundle, and RBAC gaps are reported (with remediation guidance in `namespace-coverage.txt`) instead of failing the run.
- **Documentation**: [README-support-bundle.md](README-support-bundle.md)
- **Quick Start**:
  ```bash
  # Full bundle on an edge/cluster host (host collection requires root)
  sudo bash support-bundle.sh

  # Cluster-only bundle from any machine with kubectl access (no root needed)
  bash support-bundle.sh -H

  # Host-only bundle (no Kubernetes collection)
  sudo bash support-bundle.sh -K
  ```
- Supports all flags of both legacy scripts, plus `-k <kubeconfig>`, `-K` (skip Kubernetes), `-H` (skip host), `-q` (quiet progress), and `-v` (print version).
- The legacy scripts below remain available as fallbacks until this script is widely adopted.

### Edge Environment Support Bundle
- **Script**: `support-bundle-edge.sh`
- **Purpose**: Collects logs and diagnostic information from edge hosts and their Kubernetes clusters
- **Documentation**: [README-edge.md](README-edge.md)
- **Quick Start**:
  ```bash
  # Using official URL
  curl -sSL https://software.spectrocloud.com/scripts/support-bundle-edge.sh
  sudo bash support-bundle-edge.sh

  # Using GitHub URL
  curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-edge.sh
  sudo bash support-bundle-edge.sh
  ```

### Infrastructure Support Bundle
- **Script**: `support-bundle-infra.sh`
- **Purpose**: Collects logs and diagnostic information from Kubernetes infrastructure clusters
- **Documentation**: [README-infra.md](README-infra.md)
- **Quick Start**:
  ```bash
  # Using official URL
  curl -sSL https://software.spectrocloud.com/scripts/support-bundle-infra.sh
  bash support-bundle-infra.sh

  # Using GitHub URL
  curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-infra.sh
  bash support-bundle-infra.sh
  ```

## Documentation

Each script has its own detailed documentation:

1. [README-support-bundle.md](README-support-bundle.md) - Complete documentation for the consolidated support bundle script
   - Collection scopes (`-K` / `-H`) and full flag reference
   - Kubeconfig resolution order
   - Collection summary statuses and advisory RBAC coverage
   - Differences from the legacy scripts

2. [README-edge.md](README-edge.md) - Complete documentation for the edge support bundle script
   - Detailed usage instructions
   - Available flags and options
   - Collection details
   - Prerequisites and dependencies

3. [README-infra.md](README-infra.md) - Complete documentation for the infrastructure support bundle script
   - Detailed usage instructions
   - Configuration options
   - Collection details
   - Prerequisites and dependencies

## Support

For issues, questions, or contributions:
- Open an issue in this repository
- Contact SpectroCloud support
- Refer to the detailed documentation in each script's README file

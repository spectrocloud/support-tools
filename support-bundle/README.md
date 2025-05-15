# SpectroCloud Support Bundle Scripts

This repository contains a collection of scripts designed to gather diagnostic information from SpectroCloud environments for troubleshooting and support purposes.

## Available Scripts

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

1. [README-edge.md](README-edge.md) - Complete documentation for the edge support bundle script
   - Detailed usage instructions
   - Available flags and options
   - Collection details
   - Prerequisites and dependencies

2. [README-infra.md](README-infra.md) - Complete documentation for the infrastructure support bundle script
   - Detailed usage instructions
   - Configuration options
   - Collection details
   - Prerequisites and dependencies

## Support

For issues, questions, or contributions:
- Open an issue in this repository
- Contact SpectroCloud support
- Refer to the detailed documentation in each script's README file

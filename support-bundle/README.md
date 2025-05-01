# Support Bundle Scripts


Contents:
- [Support Bundle Scripts](#support-bundle-scripts)
- [Support Bundle Collection Scripts](#support-bundle-collection-scripts)
	- [Edge Support Bundle Collection Script](#edge-support-bundle-collection-script)
		- [Usage](#usage)
			- [Example](#example)
		- [Flags](#flags)
		- [Environment Variables](#environment-variables)
		- [Dependencies](#dependencies)
		- [Note](#note)
		- [Output](#output)
	- [Kubernetes Support Bundle Collection Script](#kubernetes-support-bundle-collection-script)
		- [Usage](#usage-1)
			- [Example](#example-1)
		- [Dependencies](#dependencies-1)
		- [Configuration](#configuration)
		- [Output](#output-1)

# Support Bundle Collection Scripts

## [Edge Support Bundle Collection Script](support-bundle-edge.sh)
This Bash script, [support-bundle-edge.sh](support-bundle-edge.sh), is designed to collect various logs from an edge host and a Kubernetes cluster. The collected logs are then archived for troubleshooting and support purposes.

* Run the script as a user with `sudo` privileges.
* Run the script in all the edge hosts.

### Usage

```bash
./support-bundle-edge.sh
```

#### Example

```bash
./support-bundle-edge.sh
```

To collect logs from additional namespaces, resources, or journald logs, use the following example as a reference:

```bash
./support-bundle-edge.sh -n hello-universe,hello-world -r certificates.cert-manager.io -R clusterissuers.cert-manager.io,clusterissuers.cert-manager.io -j cloud-init,systemd-resolved
```

### Flags
```
SpectroCloud Edge support bundle collector
  Usage: support-bundle-edge.sh [ -s <days> ]

  All flags are optional

  -s    Start day of journald log collection. Specify the number of days before the current time (ex: -s 7)
  -e    End day of journald log collection. Specify the number of days before the current time (ex: -e 5)
  -S    Start date of journald log collection. (ex: -S 2024-01-01)
  -E    End date of journald log collection. (ex: -E 2024-01-01)
  -n    Additional namespaces to collect logs from. (ex: -n hello-universe,hello-world)
  -r    Additional namespace scoped resources to collect. (ex: -r certificates.cert-manager.io,clusterissuers.cert-manager.io)
  -R    Additional cluster scoped resources to collect. (ex: -R clusterissuers.cert-manager.io,clusterissuers.cert-manager.io)
  -j    Additional journald logs to collect. (ex: -j cloud-init,systemd-resolved)"

```

### Environment Variables

- `KUBECONFIG`: Path to the Kubernetes configuration file (`kubeconfig`).
  if not set, the script will use the default kubeconfig file path `/run/kubeconfig`

### Dependencies

- `journalctl`: Used to access system journal logs.
- `systemctl`: Utilized to check the status of systemd services.
- `kubectl`: Required for interacting with Kubernetes clusters.

### Note
* Secrets are not collected as part of the support bundle.
* Only helm release secrets for the spectrocloud namespaces are collected.

### Output

Upon successful execution, the script archives the collected logs into a compressed tarball (`*.tar`) stored in the specified `logs_dir`. The filename includes the hostname and timestamp of the log collection.


## [Kubernetes Support Bundle Collection Script](support-bundle-infra.sh)

This Bash script, [support-bundle-infra.sh](support-bundle-infra.sh), is designed to collect logs specifically from a Kubernetes cluster. It gathers cluster information, Cluster API (CAPI) objects, and other relevant resources for troubleshooting and support purposes.

* Run the script as a user with `kubectl` access to the Kubernetes cluster.
* Set the `KUBECONFIG` environment variable to the path of the Kubernetes configuration file (`kubeconfig`).

### Usage

```bash
./support-bundle-infra.sh
```

#### Example

```bash
./support-bundle-infra.sh
```

### Dependencies

- `kubectl`: Required for interacting with Kubernetes clusters.

### Configuration

- `tmp_bundle_dir`: Temporary directory where intermediate logs will be stored.
- `namespaces`: Array of Kubernetes namespaces to include in log collection.

### Output

Upon successful execution, the script archives the collected logs into a compressed tarball (`*.tar.gz`). The filename includes the cluster name and timestamp of the log collection.

---

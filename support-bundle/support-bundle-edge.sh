#!/bin/bash
# Copyright 2024 Spectro Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SB_VERSION=20250624+3e4a15f

# set -e
# set -x

DEFAULT_KUBECONFIG="/run/kubeconfig"

JOURNALD_LOGS=(
  # edge-cluster
  stylus-agent stylus-operator palette-tui
  # agent-mode
  spectro-stylus-agent spectro-stylus-operator spectro-init spectro-palette-agent-start spectro-palette-agent-initramfs spectro-palette-agent-boot spectro-palette-agent-network spectro-palette-agent-bootstrap
  # system
  systemd-timesyncd
  # k8s
  containerd spectro-containerd kubelet k3s k3s-agent rke2-server rke2-agent
  # Kairos specific services
  cos-setup-boot
  )

SYSTEM_NAMESPACES=(capa-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capi-system capi-webhook-system cert-manager default harbor kube-system kube-public longhorn-system os-patch palette-system piraeus-system reach-system spectro-system spectro-task system-upgrade zot-system)

API_RESOURCES=(apiservices clusterroles clusterrolebindings crds csr mutatingwebhookconfigurations namespaces nodes priorityclasses pv storageclasses validatingwebhookconfigurations volumeattachments)

API_RESOURCES_NAMESPACED=(apiservices configmaps cronjobs daemonsets deployments endpoints endpointslices events hpa ingress jobs leases limitranges networkpolicies poddisruptionbudgets pods pvc replicasets resourcequotas roles rolebindings services serviceaccounts statefulsets)

VAR_LOG_LINES=500000

function load-env() {
  if [ -f /etc/spectro/environment ]; then
    . /etc/spectro/environment
  fi
  export PATH=$PATH:$STYLUS_ROOT/usr/bin:$STYLUS_ROOT/usr/sbin:$STYLUS_ROOT/usr/local/bin
}

function timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

function techo() {
  echo "$(timestamp): $*"
}

function setup() {
  TMPDIR_BASE=$(mktemp -d $MKTEMP_BASEDIR) || { techo 'Creating temporary directory failed, please check options'; exit 1; }
  techo "Created temporary directory: $TMPDIR_BASE"
  if ! command -v hostname 2>&1 >/dev/null; then
    techo "Hostname doesn't exist in the node. Using date timestamp instead !"
    LOGNAME="$(date +'%Y-%m-%d_%H_%M_%S')"
  else
    LOGNAME="$(hostname)-$(date +'%Y-%m-%d_%H_%M_%S')"
  fi

  TMPDIR="${TMPDIR_BASE}/${LOGNAME}"
  mkdir -p "$TMPDIR" || { echo "Failed to create temporary log directory $TMPLOG_DIR"; exit 1; }

  exec > >(tee -a "$TMPDIR/console.log") 2>&1
  techo "Collecting logs in $TMPDIR"
  techo "Support Bundle Version: $SB_VERSION" > "$TMPDIR/.support-bundle"
}

function defaults() {
  CRICTL_FLAGS+=" --tail=${VAR_LOG_LINES}"
  techo "Using Crictl flags: ${CRICTL_FLAGS}"
  
  if [ -z "$JOURNALD_FLAGS" ]; then
    JOURNALD_FLAGS+=" -n ${VAR_LOG_LINES}"
    techo "No number of log lines defined for collection. Collecting last 500k log lines from journald and crictl logs"
  else
    techo "Using Journald flags: ${JOURNALD_FLAGS}"
  fi
}

function archive() {
  tar -czf "${TMPDIR_BASE}/${LOGNAME}.tar.gz" -C "$TMPDIR_BASE" "$LOGNAME" || {
    techo "Failed to create tar file"
  }

  techo "Logs are archived in ${TMPDIR_BASE}/${LOGNAME}.tar.gz"
  techo "Please upload the support bundle to the support ticket"
}

function cleanup() {
  rm -rf "$TMPDIR" > /dev/null 2>&1
}

function sherlock() {
  techo "Detecting k8s distribution"
  if (command -v kubeadm > /dev/null 2>&1); then
    DISTRO="kubeadm"
  elif (command -v k3s > /dev/null 2>&1); then
    if k3s crictl ps >/dev/null 2>&1; then
        DISTRO="k3s"
    else
      FOUND+="k3s"
    fi
  elif (command -v rke2 > /dev/null 2>&1); then
    rke2-setup
    if ${RKE2_BIN} >/dev/null 2>&1; then
      DISTRO="rke2"
    else
      FOUND+="rke2"
    fi
  else
    techo "Could not detect K8s distribution."
  fi

  if [ -z ${DISTRO} ]; then
    if [ -n "${FOUND}" ]; then
      techo "Could not detect K8s distribution. Found ${FOUND}"
    else
      techo "Could not detect K8s distribution."
    fi
  else
    techo "K8s distribution detected: ${DISTRO}"
  fi
}

function rke2-setup() {
  if RKE2_BIN=$(command -v rke2 2>/dev/null); then
    techo "Using RKE2 binary... ${RKE2_BIN}"
  else
    techo "rke2 command can run, but the binary can't be found"
  fi

  RKE2_DATA_DIR="/var/lib/rancher/rke2" # TODO: input custom-data-dir
  if [ -d "${RKE2_DATA_DIR}" ]; then
    if [ -f "${RKE2_DATA_DIR}/bin/crictl" ]; then
      CRICTL_BIN="${RKE2_DATA_DIR}/bin/crictl"

      if [ -f "${RKE2_DATA_DIR}/agent/etc/crictl.yaml" ]; then
        export CRI_CONFIG_FILE="${RKE2_DATA_DIR}/agent/etc/crictl.yaml"
      fi
  fi

    if [ -f "${RKE2_DATA_DIR}/bin/kubectl" ]; then
      KUBECTL_BIN="${RKE2_DATA_DIR}/bin/kubectl"
    fi
  else
    techo "RKE2 data directory ${RKE2_DATA_DIR} does not exist"
  fi
}

function crictl() {
  if [[ -n "$CRICTL_BIN" && -x "$CRICTL_BIN" ]]; then
    "$CRICTL_BIN" "$@"
  elif command -v crictl >/dev/null 2>&1; then
    command crictl "$@"
  else
    techo "crictl not found and no CRICTL_BIN or CRI_CONFIG_FILE set" >&2
    return 1
  fi
}

function kubectl() {
  if [[ -n "$KUBECTL_BIN" && -x "$KUBECTL_BIN" ]]; then
    "$KUBECTL_BIN" "$@"
  elif command -v kubectl >/dev/null 2>&1; then
    command kubectl "$@"
  else
    techo "kubectl not found and no KUBECTL_BIN set" >&2
    return 1
  fi
}

function var-log() {
  techo "Collecting logs from /var/log"
  mkdir -p $TMPDIR/var/log
  for logfile in /var/log/*log*; do
    if file "$logfile" | grep -q "text"; then
      cp -p "$logfile" "$TMPDIR/var/log" 2>&1
    fi
  done
}

function journald-log() {
  techo "Collecting logs from journald using flags ${JOURNALD_FLAGS}"
  mkdir -p $TMPDIR/journald

  journalctl --no-pager -k $JOURNALD_FLAGS >"$TMPDIR/journald/dmesg"
  journalctl --no-pager --list-boot $JOURNALD_FLAGS >"$TMPDIR/journald/journal-boot"

  for JOURNALD_LOG in "${JOURNALD_LOGS[@]}"; do
    if systemctl list-units --full -all | grep -Fq "$JOURNALD_LOG.service"; then
      techo "Collecting logs for $JOURNALD_LOG"
      journalctl --no-pager -u "$JOURNALD_LOG" $JOURNALD_FLAGS >"$TMPDIR/journald/$JOURNALD_LOG.log"
    fi
  done

  journalctl --no-pager $JOURNALD_FLAGS >"$TMPDIR/journald/journalctl"
}

function system-info() {
  techo "Collecting system info"
  mkdir -p $TMPDIR/systeminfo

  if command -v hostname 2>&1 >/dev/null; then
    hostname > $TMPDIR/systeminfo/hostname 2>&1
    hostname -f > $TMPDIR/systeminfo/hostnamefqdn 2>&1
  fi

  cat /proc/cmdline > $TMPDIR/systeminfo/cmdline 2>&1
  cat /etc/*release > $TMPDIR/systeminfo/osrelease 2>&1

  cp -p /etc/hosts $TMPDIR/systeminfo/etchosts 2>&1
  cp -p /etc/resolv.conf $TMPDIR/systeminfo/etcresolvconf 2>&1
}

function stylus-files() {
  techo "Collecting /oem files"
  mkdir -p $TMPDIR/oem
  ls -lah /oem/ > $TMPDIR/oem/files 2>&1
  cp -prf /oem/* $TMPDIR/oem 2>&1

  techo "Collecting /run/stylus files"
  mkdir -p $TMPDIR/run/stylus
  ls -lah /run/stylus/ > $TMPDIR/run/stylus/files 2>&1
  cp -prf /run/stylus/* $TMPDIR/run/stylus 2>&1

  techo "Collecting /usr/local/cloud-config files"
  mkdir -p $TMPDIR/usr/local/cloud-config
  ls -lah /usr/local/cloud-config/ > $TMPDIR/usr/local/cloud-config/files 2>&1
  cp -prf /usr/local/cloud-config/* $TMPDIR/usr/local/cloud-config 2>&1

  techo "Collecting /run/immucore files"
  mkdir -p $TMPDIR/run/immucore
  ls -lah /run/immucore/ > $TMPDIR/run/immucore/files 2>&1
  cp -prf /run/immucore/* $TMPDIR/run/immucore 2>&1

  # collect bundle-pkg index.json if exists
  techo "Collecting bundle-pkg index.json if exists"
  if [ -f "/usr/local/spectrocloud/bundle/bundle-pkg/index.json" ]; then
    mkdir -p $TMPDIR/usr/local/spectrocloud/bundle/bundle-pkg
    cp -p "/usr/local/spectrocloud/bundle/bundle-pkg/index.json" "$TMPDIR/usr/local/spectrocloud/bundle/bundle-pkg/" 2>&1
    techo "Collected bundle-pkg index.json"
  else
    techo "bundle-pkg index.json not found at /usr/local/spectrocloud/bundle/bundle-pkg/index.json"
  fi

  # collect containerd config.toml if exists
  techo "Collecting containerd config.toml if exists"
  if [ -f "/etc/containerd/config.toml" ]; then
    mkdir -p $TMPDIR/etc/containerd
    cp -p "/etc/containerd/config.toml" "$TMPDIR/etc/containerd/" 2>&1
    techo "Collected containerd config.toml"
  else
    techo "containerd config.toml not found at /etc/containerd/config.toml"
  fi

  # collect containerd conf.d/*.toml files if they exist
  techo "Collecting containerd conf.d/*.toml files if they exist"
  if [ -d "/etc/containerd/conf.d" ]; then
    mkdir -p $TMPDIR/etc/containerd/conf.d
    ls -lah /etc/containerd/conf.d/ > "$TMPDIR/etc/containerd/conf.d/files" 2>&1
    
    # collect all .toml files from conf.d directory
    for file in /etc/containerd/conf.d/*.toml; do
      if [ -f "$file" ]; then
        cp -p "$file" "$TMPDIR/etc/containerd/conf.d/" 2>&1
        techo "Collected containerd config file: $(basename $file)"
      fi
    done
    
    # check if any .toml files were found
    if [ -z "$(ls -A $TMPDIR/etc/containerd/conf.d/*.toml 2>/dev/null)" ]; then
      techo "No .toml files found in /etc/containerd/conf.d/"
    fi
  else
    techo "containerd conf.d directory not found at /etc/containerd/conf.d"
  fi

  # collect bundle directory listing
  techo "Collecting bundle directory listing"
  if [ -d "/usr/local/spectrocloud/bundle" ]; then
    mkdir -p $TMPDIR/usr/local/spectrocloud/bundle
    ls -larthR /usr/local/spectrocloud/bundle/ > "$TMPDIR/usr/local/spectrocloud/bundle/directory-listing.txt" 2>&1
    techo "Collected bundle directory listing"
  else
    techo "bundle directory not found at /usr/local/spectrocloud/bundle"
  fi

# collect content from /opt/spectrocloud/bin-checksums/*
  techo "Collecting content from /opt/spectrocloud/bin-checksums/*"
  mkdir -p $TMPDIR/opt/spectrocloud/bin-checksums
  for file in /opt/spectrocloud/bin-checksums/*; do
    if [ -f "$file" ]; then
      cp -p "$file" "$TMPDIR/opt/spectrocloud/bin-checksums" 2>&1
    fi
  done

  #  check if sha256sum is installed, fallback to openssl
  if command -v sha256sum >/dev/null 2>&1; then
    CHECKSUM_CMD="sha256sum"
  elif command -v openssl >/dev/null 2>&1; then
    CHECKSUM_CMD="openssl dgst -sha256"
  else
    techo "Neither sha256sum nor openssl commands found"
    return
  fi

  # collect checksums for /opt/spectrocloud/bin/*
  techo "Collecting checksums for /opt/spectrocloud/bin/* using $CHECKSUM_CMD"
  mkdir -p $TMPDIR/opt/spectrocloud/bin
  for file in /opt/spectrocloud/bin/*; do
    if [ -f "$file" ]; then
      $CHECKSUM_CMD "$file" > "$TMPDIR/opt/spectrocloud/bin/$(basename $file).sha256" 2>&1
    fi
  done
}

function set-kubeconfig() {
  if [ -n "$KUBECONFIG" ]; then
    techo "Using env KUBECONFIG: $KUBECONFIG"
  elif [ -f "$DEFAULT_KUBECONFIG" ]; then
    export KUBECONFIG="$DEFAULT_KUBECONFIG"
    techo "KUBECONFIG file exists and is readable. Defaulting to $KUBECONFIG"
  else
    techo "KUBECONFIG file ($DEFAULT_KUBECONFIG) does not exist."
  fi
}

function spectro-k8s-defaults() {
  if ! kubectl version >/dev/null 2>&1; then
    techo "kubectl command not found"
    return
  fi

	IS_ENTERPRISE_CLUSTER=false
	if kubectl get ns --output=custom-columns="Name:.metadata.name" --no-headers 2>/dev/null | grep 'hubble-system'; then
		IS_ENTERPRISE_CLUSTER=true
    CLUSTER_NAME="spectro-enterprise-cluster"
		techo "This is an Enterprise cluster. Collecting logs from all namespaces"
	fi

	IS_PCG_CLUSTER=false
	if kubectl get deployment -n jet-system --output=custom-columns="Name:.metadata.name" --no-headers 2>/dev/null | grep 'spectro-cloud-driver'; then
		IS_PCG_CLUSTER=true
    CLUSTER_NAME="spectro-pcg-cluster"
		techo "This is a PCG cluster. Collecting logs from all namespaces"
	fi

  if [[ "$IS_ENTERPRISE_CLUSTER" == true ]] || [[ "$IS_PCG_CLUSTER" == true ]]; then
		SYSTEM_NAMESPACES=($(kubectl get ns --output=custom-columns="Name:.metadata.name" --no-headers 2>/dev/null))
    return 0
  fi

  for NS in "${SYSTEM_NAMESPACES[@]}"; do
    if ! kubectl get ns "$NS" >/dev/null 2>&1; then
      for i in "${!SYSTEM_NAMESPACES[@]}"; do
        if [[ ${SYSTEM_NAMESPACES[i]} = "$NS" ]]; then
          unset 'SYSTEM_NAMESPACES[i]'
          techo "Namespace $NS not found in the cluster. Removing from the list."
        fi
      done
    fi
  done

  CLUSTER_NS=$(kubectl get ns --output=custom-columns="Name:.metadata.name" --no-headers -l 'spectrocloud.com/cluster-name' 2>/dev/null)
  if [[ -z "${CLUSTER_NS}" ]]; then
    CLUSTER_NS=$(kubectl get ns -o=name | grep '^namespace/cluster-' | sed "s/^.\{10\}//")
  fi

  if [[ -z "${CLUSTER_NS}" ]]; then
    techo "Palette cluster namespace is empty."
  else
    for NS in $(echo $CLUSTER_NS | tr " " "\n"); do
      techo "Adding namespace $NS for logs collection."
      SYSTEM_NAMESPACES+=("$NS")
    done
  fi

  SYSTEM_UPGRADE_UUID_NS=$(kubectl get ns -o=name | grep '^namespace/system-upgrade-' | sed "s/^.\{10\}//")
  if [[ -z "${SYSTEM_UPGRADE_UUID_NS}" ]]; then
    techo "System upgrade UUID namespace is empty."
  else
    for NS in $(echo $SYSTEM_UPGRADE_UUID_NS | tr " " "\n"); do
      techo "Adding namespace $NS for logs collection."
      SYSTEM_NAMESPACES+=("$NS")
    done
  fi

  SPECTRO_TASK_NS=$(kubectl get ns -o=name | grep '^namespace/spectro-task-' | sed "s/^.\{10\}//")
  if [[ -z "${SPECTRO_TASK_NS}" ]]; then
    techo "Spectro task UUID namespace is empty."
  else
    for NS in $(echo $SPECTRO_TASK_NS | tr " " "\n"); do
      techo "Adding namespace $NS for logs collection."
      SYSTEM_NAMESPACES+=("$NS")
    done
  fi

  CLUSTER_NAME=$(kubectl get spc -n "${CLUSTER_NS}" --output=custom-columns="Name:.metadata.name" --no-headers 2>/dev/null)
	if [[ -z "${CLUSTER_NAME}" ]]; then
		techo "Cluster name is empty. Please check if the cluster is registered with Palette"
		CLUSTER_NAME="spectro-cluster"
	fi
}

function k8s-resources() {
  if ! kubectl version >/dev/null 2>&1; then
    techo "kubectl command not found"
    return
  fi

  techo "Collecting logs from following namespaces: ${SYSTEM_NAMESPACES[*]}"

  techo "Collecting k8s cluster-info"
  mkdir -p "${TMPDIR}/k8s/cluster-info"
  kubectl version -o yaml > "${TMPDIR}/k8s/cluster-info/cluster-version.yaml" 2>&1
  kubectl cluster-info > "${TMPDIR}/k8s/cluster-info/cluster-info" 2>&1

  techo "Collecting k8s cluster-info dump"
  mkdir -p "${TMPDIR}/k8s/cluster-info/dump"
  kubectl cluster-info dump --namespaces "$(IFS=,; echo "${SYSTEM_NAMESPACES[*]}")" --output-directory="${TMPDIR}/k8s/cluster-info/dump" --output=yaml 2>&1
  kubectl api-resources -o wide > "${TMPDIR}/k8s/cluster-info/api-resources" 2>&1

  techo "Collecting k8s resources"
  mkdir -p "${TMPDIR}/k8s/cluster-resources"
  for RESOURCE in "${API_RESOURCES[@]}"; do
    printf "\rCollecting k8s resource: %-50s" "${RESOURCE}"
    kubectl get "$RESOURCE" --all-namespaces --show-managed-fields -o yaml > "${TMPDIR}/k8s/cluster-resources/${RESOURCE}.yaml" 2>&1
  done
  printf "\n"

  techo "Collecting k8s namespaced resources"
  for RESOURCE in "${API_RESOURCES_NAMESPACED[@]}"; do
    mkdir -p "${TMPDIR}/k8s/cluster-resources/${RESOURCE}"
    printf "\rCollecting k8s namespaced resource: %-50s" "${RESOURCE}"
    for NS in "${SYSTEM_NAMESPACES[@]}"; do
      kubectl get "$RESOURCE" -n "$NS" --show-managed-fields -o yaml > "${TMPDIR}/k8s/cluster-resources/${RESOURCE}/${NS}.yaml" 2>&1
    done
  done
  printf "\n"

  techo "Collecting helm release secrets"
  mkdir -p "${TMPDIR}/k8s/cluster-resources/secrets"
  for NS in "${SYSTEM_NAMESPACES[@]}"; do
    kubectl get secret -n "$NS" --field-selector type=helm.sh/release.v1 --show-managed-fields -o yaml > "${TMPDIR}/k8s/cluster-resources/secrets/${NS}.yaml" 2>&1
  done

  techo "Collecting k8s custom-resources"
  mkdir -p "${TMPDIR}/k8s/cluster-resources/custom-resources"

  techo "Collecting k8s cluster-scoped custom-resources"
  CLUSTER_CRDS=$(kubectl get crd -o custom-columns=NAME:.metadata.name,SCOPE:.spec.scope --no-headers | grep "Cluster" | awk '{print $1}')
  for CRD in $CLUSTER_CRDS; do
    COUNT=$(kubectl get "$CRD" --no-headers 2>/dev/null | wc -l | xargs)
    if [ $COUNT -gt 0 ]; then
      printf "\rCollecting k8s cluster-scoped custom-resource: %-50s" "${CRD}"
      kubectl get "$CRD" --show-managed-fields -o yaml > "${TMPDIR}/k8s/cluster-resources/custom-resources/${CRD}.yaml" 2>&1
    fi
  done
  printf "\n"

  techo "Collecting k8s namespace-scoped custom-resources"
  NAMESPACED_CRDS=$(kubectl get crd -o custom-columns=NAME:.metadata.name,SCOPE:.spec.scope --no-headers | grep "Namespaced" | awk '{print $1}')
  for CRD in $NAMESPACED_CRDS; do
    ALL_COUNT=$(kubectl get "$CRD" -A --no-headers 2>/dev/null | wc -l | xargs)
    if [ $ALL_COUNT -gt 0 ]; then
      printf "\rCollecting k8s namespace-scoped custom-resource: %-50s" "${CRD}"
      for NS in "${SYSTEM_NAMESPACES[@]}"; do
        COUNT=$(kubectl get "$CRD" -n "$NS" --no-headers 2>/dev/null | wc -l | xargs)
        if [ $COUNT -gt 0 ]; then
          mkdir -p "${TMPDIR}/k8s/cluster-resources/custom-resources/${CRD}"
            kubectl get "$CRD" -n "$NS" --show-managed-fields -o yaml > "${TMPDIR}/k8s/cluster-resources/custom-resources/${CRD}/${NS}.yaml" 2>&1
          fi
      done
    fi
  done
  printf "\n"

  techo "Collecting k8s metrics"
  mkdir -p "${TMPDIR}/k8s/metrics"
  kubectl top nodes > "${TMPDIR}/k8s/metrics/nodes-metrics" 2>&1
  kubectl top pods --all-namespaces > "${TMPDIR}/k8s/metrics/pods-metrics" 2>&1
  kubectl top pods --all-namespaces --containers > "${TMPDIR}/k8s/metrics/pods-containers-metrics" 2>&1

  techo "Collecting logs from previous pods"
  mkdir -p "${TMPDIR}/k8s/previous-pod-logs"
  for NS in "${SYSTEM_NAMESPACES[@]}"; do
    for POD in $(kubectl get pods -n "$NS" --no-headers -o custom-columns="NAME:.metadata.name"); do
      LOGS=$(kubectl logs -n "$NS" "$POD" --all-containers --previous 2>&1)
      if [[ -n "$LOGS" ]]; then
        mkdir -p "${TMPDIR}/k8s/previous-pod-logs/${NS}/${POD}"
        echo "$LOGS" > "${TMPDIR}/k8s/previous-pod-logs/${NS}/${POD}/previous.log"
      fi
    done
  done
}

function var-log-pods() {
  techo "Collecting k8s pod logs"
  mkdir -p "${TMPDIR}/k8s/pod-logs"
  for NS in "${SYSTEM_NAMESPACES[@]}"; do
    cp -prf /var/log/pods/"$NS"* "${TMPDIR}/k8s/pod-logs" 2>&1
  done
}

function opt-kubeadm-files() {
  if [ ! -d /opt/kubeadm ]; then
    techo "/opt/kubeadm does not exist"
    return
  fi

  techo "Collecting files from /opt/kubeadm"
  mkdir -p $TMPDIR/opt/kubeadm
  ls -lah /opt/kubeadm/ > $TMPDIR/opt/kubeadm/files 2>&1
  cp -p /opt/kubeadm/* $TMPDIR/opt/kubeadm 2>/dev/null
}

function kubeadm-manifests() {
  if [ ! -d /etc/kubernetes/manifests ]; then
    techo "/etc/kubernetes/manifests does not exist"
    return
  fi

  techo "Collecting static manifests from /etc/kubernetes/manifests"
  mkdir -p $TMPDIR/etc/kubernetes/manifests
  ls -lah /etc/kubernetes/manifests/ > $TMPDIR/etc/kubernetes/manifests/files 2>&1
  cp -p /etc/kubernetes/manifests/* $TMPDIR/etc/kubernetes/manifests 2>&1

    if ! $(command -v kubeadm >/dev/null 2>&1); then
    techo "kubeadm-manifests: kubeadm command not found"
    return
  fi
  kubeadm version -o yaml > $TMPDIR/etc/kubernetes/kubeadm-version.yaml 2>&1
}

function kubeadm-certs() {

  if ! $(command -v openssl >/dev/null 2>&1); then
    techo "kubeadm-certs: openssl command not found"
    return
  fi

  if [ -d /etc/kubernetes/pki/ ]
    then
      techo "Collecting k8s kubeadm directory state"
      mkdir -p $TMPDIR/etc/kubernetes/pki/{server,kubelet}

      ls -lah /etc/kubernetes/ > $TMPDIR/etc/kubernetes/files 2>&1

      techo "Collecting k8s kubeadm certificates"
      SERVER_CERTS=$(find /etc/kubernetes/pki/ -maxdepth 2 -type f -name "*.crt" | grep -v "\-ca.crt$")
      for CERT in $SERVER_CERTS
        do
          openssl x509 -in $CERT -text -noout > $TMPDIR/etc/kubernetes/pki/server/$(basename $CERT) 2>&1
      done
      if [ -d /var/lib/kubelet/pki/ ]; then
        techo "Collecting kubelet certificates"
        AGENT_CERTS=$(find /var/lib/kubelet/pki/ -maxdepth 2 -type f -name "*.crt" | grep -v "\-ca.crt$")
        for CERT in $AGENT_CERTS
          do
            openssl x509 -in $CERT -text -noout > $TMPDIR/etc/kubernetes/pki/kubelet/$(basename $CERT) 2>&1
        done
      fi
  fi

}

function kubeadm-etcd() {

  KUBEADM_ETCD_DIR="/etc/kubernetes"
  KUBEADM_ETCD_CERTS="/etc/kubernetes/pki/etcd/"

  if ! $(command -v etcdctl >/dev/null 2>&1); then
    techo "kubeadm-etcd: etcdctl command not found"
    return
  fi

  if [ -d $KUBEADM_ETCD_DIR ]; then
    techo "Collecting kubeadm etcd info"
    mkdir -p $TMPDIR/etcd
    ETCDCTL_ENDPOINTS=$(etcdctl --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt --write-out="simple" endpoint status | cut -d "," -f 1)

    etcdctl version > $TMPDIR/etcd/version 2>&1
    etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt --write-out table endpoint status > $TMPDIR/etcd/endpointstatus 2>&1
    etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt endpoint health > $TMPDIR/etcd/endpointhealth 2>&1
    etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt alarm list > $TMPDIR/etcd/alarmlist 2>&1
    etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt member list --write-out table > $TMPDIR/etcd/memberlist 2>&1
    
    etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cert ${KUBEADM_ETCD_CERTS}/server.crt --key ${KUBEADM_ETCD_CERTS}/server.key --cacert ${KUBEADM_ETCD_CERTS}/ca.crt --write-out table endpoint status --cluster > $TMPDIR/etcd/cluster_endpointstatus 2>&1
  fi

  if [ -d ${KUBEADM_ETCD_DIR} ]; then
    find ${KUBEADM_ETCD_DIR} -type f -exec ls -la {} \; > $TMPDIR/etcd/findserverdbetcd 2>&1
  fi

}

function rke2-certs() {

  if [ -d ${RKE2_DATA_DIR} ]
    then
      techo "Collecting rke2 directory state"
      mkdir -p $TMPDIR/${DISTRO}/directories
      ls -lah ${RKE2_DATA_DIR}/agent > $TMPDIR/${DISTRO}/directories/rke2agent 2>&1
      ls -lahR ${RKE2_DATA_DIR}/server/manifests > $TMPDIR/${DISTRO}/directories/rke2servermanifests 2>&1
      ls -lahR ${RKE2_DATA_DIR}/server/tls > $TMPDIR/${DISTRO}/directories/rke2servertls 2>&1
      techo "Collecting rke2 certificates"
      mkdir -p $TMPDIR/${DISTRO}/certs/{agent,server}
      AGENT_CERTS=$(find ${RKE2_DATA_DIR}/agent -maxdepth 1 -type f -name "*.crt" | grep -v "\-ca.crt$")
      for CERT in $AGENT_CERTS
        do
          openssl x509 -in $CERT -text -noout > $TMPDIR/${DISTRO}/certs/agent/$(basename $CERT) 2>&1
      done
      if [ -d ${RKE2_DATA_DIR}/server/tls ]; then
        techo "Collecting rke2 server certificates"
        SERVER_CERTS=$(find ${RKE2_DATA_DIR}/server/tls -maxdepth 1 -type f -name "*.crt" | grep -v "\-ca.crt$")
        for CERT in $SERVER_CERTS
          do
            openssl x509 -in $CERT -text -noout > $TMPDIR/${DISTRO}/certs/server/$(basename $CERT) 2>&1
        done
      fi
  fi

}

function helm-logs() {
  if [ ! -f "$STYLUS_ROOT/opt/spectrocloud/bin/helm" ]; then
    techo "Helm binary not found at /opt/spectrocloud/bin/helm"
    return
  fi

  mkdir -p "$TMPDIR/helm"
  $STYLUS_ROOT/opt/spectrocloud/bin/helm list --all --all-namespaces > "$TMPDIR/helm/helm-list.log" 2>&1
  $STYLUS_ROOT/opt/spectrocloud/bin/helm repo list > "$TMPDIR/helm/helm-repo.log" 2>&1
  $STYLUS_ROOT/opt/spectrocloud/bin/helm version > "$TMPDIR/helm/helm-version.log" 2>&1
  $STYLUS_ROOT/opt/spectrocloud/bin/helm env > "$TMPDIR/helm/helm-env.log" 2>&1
  $STYLUS_ROOT/opt/spectrocloud/bin/helm plugin list > "$TMPDIR/helm/helm-plugin-list.log" 2>&1
}

function crictl-logs() {
  if ! crictl --version >/dev/null 2>&1; then
    techo "crictl command not found"
    return
  fi

  techo "Collecting crictl logs using flags ${CRICTL_FLAGS}"
  mkdir -p $TMPDIR/${DISTRO}/crictl
  if !  crictl ps > /dev/null 2>&1; then
    techo "[!] Containerd is offline, skipping crictl collection"
    return
  else
    crictl ps -a > $TMPDIR/${DISTRO}/crictl/psa 2>&1
    crictl pods > $TMPDIR/${DISTRO}/crictl/pods 2>&1
    crictl info > $TMPDIR/${DISTRO}/crictl/info 2>&1
    crictl stats -a > $TMPDIR/${DISTRO}/crictl/statsa 2>&1
    crictl version > $TMPDIR/${DISTRO}/crictl/version 2>&1
    crictl images > $TMPDIR/${DISTRO}/crictl/images 2>&1
    crictl imagefsinfo > $TMPDIR/${DISTRO}/crictl/imagefsinfo 2>&1
    crictl stats -a > $TMPDIR/${DISTRO}/crictl/statsa 2>&1

    CONTAINERS=$(crictl ps -a -q)
    mkdir -p "$TMPDIR/${DISTRO}/crictl/logs"
    for container_id in $CONTAINERS; do
      container_name=$(crictl inspect "$container_id" | jq -r '.status.metadata.name')
      if [ -z "$container_name" ] || [ "$container_name" == "null" ]; then
        container_name="$container_id"
      fi
      crictl logs $CRICTL_FLAGS "$container_id" > "$TMPDIR/${DISTRO}/crictl/logs/${container_name}_${container_id:0:12}.log" 2>&1
    done
  fi
}

function networking-info() {
  techo "Collecting network info"
  mkdir -p $TMPDIR/networking
  iptables-save > $TMPDIR/networking/iptablessave 2>&1
  ip6tables-save > $TMPDIR/networking/ip6tablessave 2>&1
  if [ ! "${OSRELEASE}" = "sles" ]
    then
      IPTABLES_FLAGS="--wait 1"
  fi
  iptables $IPTABLES_FLAGS --numeric --verbose --list --table mangle > $TMPDIR/networking/iptablesmangle 2>&1
  iptables $IPTABLES_FLAGS --numeric --verbose --list --table nat > $TMPDIR/networking/iptablesnat 2>&1
  iptables $IPTABLES_FLAGS --numeric --verbose --list > $TMPDIR/networking/iptables 2>&1
  ip6tables $IPTABLES_FLAGS --numeric --verbose --list --table mangle > $TMPDIR/networking/ip6tablesmangle 2>&1
  ip6tables $IPTABLES_FLAGS --numeric --verbose --list --table nat > $TMPDIR/networking/ip6tablesnat 2>&1
  ip6tables $IPTABLES_FLAGS --numeric --verbose --list > $TMPDIR/networking/ip6tables 2>&1
  if $(command -v nft >/dev/null 2>&1); then
    nft list ruleset  > $TMPDIR/networking/nft_ruleset 2>&1
  fi
  if $(command -v netstat >/dev/null 2>&1); then
    netstat --programs --all --numeric --tcp --udp > $TMPDIR/networking/netstat 2>&1
    netstat --statistics > $TMPDIR/networking/netstatistics 2>&1
  fi
  if $(command -v ipvsadm >/dev/null 2>&1); then
    ipvsadm -ln > $TMPDIR/networking/ipvsadm 2>&1
  fi
  if [ -f /proc/net/xfrm_stat ]
    then
      cat /proc/net/xfrm_stat > $TMPDIR/networking/procnetxfrmstat 2>&1
  fi
  if $(command -v ip >/dev/null 2>&1); then
    ip addr show > $TMPDIR/networking/ipaddrshow 2>&1
    ip route show table all > $TMPDIR/networking/iproute 2>&1
    ip neighbour > $TMPDIR/networking/ipneighbour 2>&1
    ip rule show > $TMPDIR/networking/iprule 2>&1
    ip -s link show > $TMPDIR/networking/iplinkshow 2>&1
    ip -6 neighbour > $TMPDIR/networking/ipv6neighbour 2>&1
    ip -6 rule show > $TMPDIR/networking/ipv6rule 2>&1
    ip -6 route show > $TMPDIR/networking/ipv6route 2>&1
    ip -6 addr show > $TMPDIR/networking/ipv6addrshow 2>&1
  fi
  if $(command -v ifconfig >/dev/null 2>&1); then
    ifconfig -a > $TMPDIR/networking/ifconfiga
  fi
  if $(command -v ss >/dev/null 2>&1); then
    ss -anp > $TMPDIR/networking/ssanp 2>&1
    ss -itan > $TMPDIR/networking/ssitan 2>&1
    ss -uapn > $TMPDIR/networking/ssuapn 2>&1
    ss -wapn > $TMPDIR/networking/sswapn 2>&1
    ss -xapn > $TMPDIR/networking/ssxapn 2>&1
    ss -4apn > $TMPDIR/networking/ss4apn 2>&1
    ss -6apn > $TMPDIR/networking/ss6apn 2>&1
    ss -tunlp6 > $TMPDIR/networking/sstunlp6 2>&1
    ss -tunlp4 > $TMPDIR/networking/sstunlp4 2>&1
  fi
  if [ -d /etc/cni/net.d/ ]; then
    mkdir -p $TMPDIR/networking/cni
    cp -r -p /etc/cni/net.d/* $TMPDIR/networking/cni 2>&1
  fi

}

function help() {
  echo "SpectroCloud Edge support bundle collector
  Usage: support-bundle-edge.sh [ -s <days> ]

  All flags are optional

  # general flags
  -d    Output directory for temporary storage and .tar.gz archive (ex: -d /var/tmp)
  -s    Start day of journald log collection. Specify the number of days before the current time (ex: -s 7)
  -e    End day of journald log collection. Specify the number of days before the current time (ex: -e 5)
  -S    Start date of journald log collection. (ex: -S 2024-01-01)
  -E    End date of journald log collection. (ex: -E 2024-01-01)
  -l    Number of log lines to collect from journald logs. (ex: -l 500000)
  -j    Additional journald logs to collect. (ex: -j cloud-init,cloud-init-local)

  # kubernetes specific flags
  -n    Additional namespaces to collect logs from. (ex: -n hello-universe,hello-world)
  -r    Additional namespace scoped resources to collect. (ex: -r certificates.cert-manager.io,clusterissuers.cert-manager.io)
  -R    Additional cluster scoped resources to collect. (ex: -R clusterissuers.cert-manager.io,clusterissuers.cert-manager.io)

  "
}

# Check if the script is being run as root
if [[ $EUID -ne 0 ]] && [[ "${DEV}" == "" ]]
  then
    help
    techo "This script must be run as root"
    exit 1
fi

while getopts "d:s:e:S:E:l:n:r:R:j:h" opt; do
  case $opt in
  d)
    MKTEMP_BASEDIR="-p ${OPTARG}"
    techo "Using custom output directory: $MKTEMP_BASEDIR"
    ;;
  s)
    START_DAY=${OPTARG}
    START=$(date -d "$START_DAY days ago" +%Y-%m-%d)
    SINCE_FLAG="--since $START"
    JOURNALD_FLAGS+=" ${SINCE_FLAG}"
    techo "Logging since $START"
    ;;
  e)
    END_DAY=${OPTARG}
    END=$(date -d "$END_DAY days ago" +%Y-%m-%d)
    UNTIL_FLAG="--until $END"
    JOURNALD_FLAGS+=" ${UNTIL_FLAG}"
    techo "Logging until $END"
    ;;
  S)
    SINCE_FLAG="--since ${OPTARG}"
    JOURNALD_FLAGS+=" ${SINCE_FLAG}"
    techo "Collecting logs starting ${OPTARG}"
    ;;
  E)
    UNTIL_FLAG="--until ${OPTARG}"
    JOURNALD_FLAGS+=" ${UNTIL_FLAG}"
    techo "Collecting logs until ${OPTARG}"
    ;;
  l)
    NUM_LINES="${OPTARG}"
    JOURNALD_FLAGS+=" -n ${NUM_LINES}"
    CRICTL_FLAGS+=" --tail=${NUM_LINES}"
    techo "Collecting most recent ${OPTARG} from journald and crictl logs"
    ;;
  n)
    NAMESPACES=${OPTARG}
    techo "Collecting logs for additional namespaces $NAMESPACES"
    for NS in $(echo $NAMESPACES | tr "," "\n"); do
      SYSTEM_NAMESPACES+=("$NS")
    done
    ;;
  r)
    RESOURCES=${OPTARG}
    techo "Collecting logs for additional namespaced resources $RESOURCES"
    for RESOURCE in $(echo $RESOURCES | tr "," "\n"); do
      API_RESOURCES_NAMESPACED+=("$RESOURCE")
    done
    ;;
  R)
    RESOURCES=${OPTARG}
    techo "Collecting logs for additional resources $RESOURCES"
    for RESOURCE in $(echo $RESOURCES | tr "," "\n"); do
      API_RESOURCES+=("$RESOURCE")
    done
    ;;
  j)
    RESOURCES=${OPTARG}
    techo "Collecting additional journald logs $RESOURCES"
    for RESOURCE in $(echo $RESOURCES | tr "," "\n"); do
      JOURNALD_LOGS+=("$RESOURCE")
    done
    ;;
  h)
    help && exit 0
    ;;
  *)
    help && exit 1
    ;;
  esac
done

load-env
defaults
setup
sherlock
system-info
networking-info
var-log
journald-log

stylus-files

crictl-logs
set-kubeconfig
spectro-k8s-defaults
k8s-resources
if [ "${DISTRO}" = "kubeadm" ]; then
  var-log-pods
  opt-kubeadm-files
  kubeadm-manifests
  kubeadm-certs
  kubeadm-etcd
fi

if [ "${DISTRO}" = "k3s" ]; then
  var-log-pods
  # TODO: k3s manifests, certs, etcd collection and logs
fi

# TODO: rke2 info
if [ "${DISTRO}" = "rke2" ]; then
  rke2-certs
  # TODO: rke2 manifests, certs, etcd collection and logs
fi

helm-logs
archive
cleanup

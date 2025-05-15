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

# Version: 20250515+be0da61

# set -e
# set -x

SYSTEM_NAMESPACES=(capa-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capi-system capi-webhook-system cert-manager default harbor kube-system kube-public longhorn-system os-patch palette-system reach-system spectro-system system-upgrade)

API_RESOURCES=(apiservices clusterroles clusterrolebindings crds csr mutatingwebhookconfigurations namespaces nodes priorityclasses pv storageclasses validatingwebhookconfigurations volumeattachments)

API_RESOURCES_NAMESPACED=(apiservices configmaps cronjobs daemonsets deployments endpoints endpointslices events hpa ingress jobs leases limitranges networkpolicies poddisruptionbudgets pods pvc replicasets resourcequotas roles rolebindings services serviceaccounts statefulsets)

function is-kubeconfig-set() {
	if [[ -z "${KUBECONFIG}" ]]; then
		return 1
	fi
	return 0
}

function spectro-k8s-defaults() {
  if ! command -v kubectl >/dev/null 2>&1; then
    techo "k8s-resources: kubectl command not found"
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

function timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

function techo() {
  echo "$(timestamp): $*"
}

function setup() {
  TMPDIR_BASE=$(mktemp -d $MKTEMP_BASEDIR) || { techo 'Creating temporary directory failed, please check options'; exit 1; }
  techo "Created temporary directory: $TMPDIR_BASE"
  if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME="spectro-cluster"
  fi

  LOGNAME="${CLUSTER_NAME}-$(date +'%Y-%m-%d_%H_%M_%S')"
  TMPDIR="${TMPDIR_BASE}/${LOGNAME}"
  mkdir -p "$TMPDIR" || { techo "Failed to create temporary log directory $TMPLOG_DIR"; exit 1; }
  techo "Collecting logs in $TMPDIR"
}

function archive() {
  tar -czf "${LOGNAME}.tar.gz" -C "$TMPDIR_BASE" "$LOGNAME" || {
    techo "Failed to create tar file"
  }

  techo "Logs are archived in ${LOGNAME}.tar.gz"
  techo "Please upload the support bundle to the support ticket"
}

function cleanup() {
  rm -rf "$TMPDIR_BASE" > /dev/null 2>&1
}

function help() {
  echo "SpectroCloud Infrastructure support bundle collector
  Usage: support-bundle-infra.sh [ -d <directory> ]

  All flags are optional

  -d    Output directory for temporary storage and .tar.gz archive (ex: -d /var/tmp)
  -n    Additional namespaces to collect logs from. (ex: -n hello-universe,hello-world)
  -r    Additional namespace scoped resources to collect. (ex: -r certificates.cert-manager.io,clusterissuers.cert-manager.io)
  -R    Additional cluster scoped resources to collect. (ex: -R clusterissuers.cert-manager.io,clusterissuers.cert-manager.io)

  "


}

while getopts "d:n:r:R:h" opt; do
  case $opt in
  d)
    MKTEMP_BASEDIR="-p ${OPTARG}"
    techo "Using custom output directory: $MKTEMP_BASEDIR"
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
  h)
    help && exit 0
    ;;
  *)
    help && exit 1
    ;;
  esac
done

is-kubeconfig-set || { echo "KUBECONFIG is not set. Unable to collect Kubernetes logs."; cleanup; exit 1; }
spectro-k8s-defaults
setup
k8s-resources
archive
cleanup

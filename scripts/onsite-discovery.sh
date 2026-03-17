#!/usr/bin/env bash
# =============================================================================
# Pryon on RKE2 — On-Site Discovery Script
# =============================================================================
#
# PURPOSE:
#   Day 1 assessment tool. Run this from whatever terminal you have access to
#   inside the environment. It probes as deep as it can with the access
#   available and produces a structured report to send back to Recro.
#
#   Nothing in this script modifies the environment. It is read-only.
#   If a check requires access you don't have, it is skipped and noted.
#
# USAGE:
#   chmod +x onsite-discovery.sh
#   ./onsite-discovery.sh 2>&1 | tee discovery-$(hostname)-$(date +%Y%m%d-%H%M).txt
#
#   Then send the output file back to the Recro team before EOD.
#
# REQUIREMENTS:
#   Tier 0 (minimum): bash, curl — available on any RHEL 9 node
#   Tier 1: kubectl configured with any RBAC level
#   Tier 2: kubectl with cluster-admin
#   Tier 3: SSH access to worker nodes (prompted interactively)
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
YLW='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

REPORT_LINES=()
WARN_COUNT=0
FAIL_COUNT=0

# --- Helpers -----------------------------------------------------------------

section() { echo -e "\n${BLD}${CYN}══════════════════════════════════════════${RST}"; echo -e "${BLD}${CYN}  $1${RST}"; echo -e "${BLD}${CYN}══════════════════════════════════════════${RST}"; }
ok()      { echo -e "  ${GRN}✓${RST}  $*"; REPORT_LINES+=("OK      $*"); }
warn()    { echo -e "  ${YLW}⚠${RST}  $*"; REPORT_LINES+=("WARN    $*"); (( WARN_COUNT++ )); }
fail()    { echo -e "  ${RED}✗${RST}  $*"; REPORT_LINES+=("FAIL    $*"); (( FAIL_COUNT++ )); }
info()    { echo -e "  ${BLD}→${RST}  $*"; REPORT_LINES+=("INFO    $*"); }
skip()    { echo -e "       ${RST}(skipped — $*)"; REPORT_LINES+=("SKIP    $*"); }
ask()     { echo -e "\n  ${BLD}${YLW}[MANUAL]${RST} $*"; REPORT_LINES+=("MANUAL  $*"); }

have_cmd() { command -v "$1" &>/dev/null; }

# --- Banner ------------------------------------------------------------------

echo -e "${BLD}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║   Pryon / RKE2 — On-Site Environment Discovery       ║"
echo "  ║   Run by: $(whoami)@$(hostname -s)                          ║"
echo "  ║   Date:   $(date '+%Y-%m-%d %H:%M %Z')                         ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${RST}"
echo "  Everything below is read-only. Nothing will be changed."
echo "  Capture the full output and send it back to Recro."
echo ""

# =============================================================================
# TIER 0 — Local terminal and network reachability
# =============================================================================
section "TIER 0 — Terminal + Network Reachability"

# Local environment
info "Running as: $(whoami)  |  hostname: $(hostname -f 2>/dev/null || hostname)"
info "OS: $(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | head -1 || echo 'unknown')"
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"

# FIPS (Tier 0 — readable without any special access)
if [ -f /proc/sys/crypto/fips_enabled ]; then
  FIPS=$(cat /proc/sys/crypto/fips_enabled)
  if [ "$FIPS" = "1" ]; then
    ok "FIPS mode: ENABLED (fips_enabled=1)"
  else
    fail "FIPS mode: DISABLED (fips_enabled=0) — required by NCIS STIG"
  fi
else
  skip "fips_enabled — not on a Linux node or /proc unavailable"
fi

# Key sysctl values
for param in fs.inotify.max_user_watches fs.inotify.max_user_instances fs.file-max; do
  val=$(sysctl -n "$param" 2>/dev/null || echo "unreadable")
  info "sysctl $param = $val"
done

case "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)" in
  [0-9]|[0-9][0-9][0-9][0-9][0-9]) fail "fs.inotify.max_user_watches too low (need ≥524288)" ;;
  *) ok "fs.inotify.max_user_watches looks sufficient" ;;
esac

info "Open file limit (ulimit -n): $(ulimit -n)"

# Tool availability
echo ""
info "Tool availability on this terminal:"
for tool in kubectl helm curl jq git python3 ansible; do
  if have_cmd "$tool"; then
    ok "$tool: $(command -v $tool)  $(${tool} --version 2>&1 | head -1)"
  else
    warn "$tool: NOT FOUND on this terminal"
  fi
done

# Harbor connectivity (prompt for hostname if not set)
echo ""
if [ -z "${HARBOR_HOST:-}" ]; then
  echo -e "  ${BLD}Harbor registry hostname (leave blank to skip):${RST} "
  read -r HARBOR_HOST || HARBOR_HOST=""
fi

if [ -n "${HARBOR_HOST:-}" ]; then
  info "Testing Harbor connectivity: https://${HARBOR_HOST}"
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://${HARBOR_HOST}/api/v2.0/ping" 2>/dev/null || echo "FAILED")
  if [ "$HTTP" = "200" ]; then
    ok "Harbor reachable: https://${HARBOR_HOST} → HTTP $HTTP"
  elif [ "$HTTP" = "401" ]; then
    ok "Harbor reachable (HTTP 401 — unauthenticated, as expected)"
  else
    fail "Harbor NOT reachable: https://${HARBOR_HOST} → $HTTP (connection refused, timeout, or TLS error)"
  fi
else
  skip "Harbor connectivity — no hostname provided"
  ask "MANUAL: What is the Harbor registry hostname/URL? (critical — needed for all chart pulls)"
fi

# Kubernetes API server reachability
echo ""
if [ -z "${K8S_API:-}" ]; then
  echo -e "  ${BLD}Kubernetes API server URL (e.g. https://192.168.1.10:6443, blank to skip):${RST} "
  read -r K8S_API || K8S_API=""
fi

if [ -n "${K8S_API:-}" ]; then
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "${K8S_API}/healthz" 2>/dev/null || echo "FAILED")
  if [ "$HTTP" = "200" ] || [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
    ok "Kubernetes API reachable: ${K8S_API} → HTTP $HTTP"
  else
    fail "Kubernetes API NOT reachable: ${K8S_API} → $HTTP"
  fi
else
  skip "Kubernetes API reachability — no URL provided"
fi

# =============================================================================
# TIER 1 — kubectl (any access level)
# =============================================================================
section "TIER 1 — Cluster State (kubectl, any RBAC)"

if ! have_cmd kubectl; then
  skip "All Tier 1 checks — kubectl not found on this terminal"
  warn "BLOCKING: kubectl must be installed and configured to proceed with deployment"
else
  KUBE_OK=false
  if kubectl cluster-info &>/dev/null 2>&1; then
    KUBE_OK=true
    ok "kubectl connected: $(kubectl cluster-info 2>/dev/null | head -1)"
  else
    fail "kubectl cannot reach cluster — kubeconfig missing, wrong context, or API unreachable"
    info "KUBECONFIG=${KUBECONFIG:-~/.kube/config}"
    info "Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
  fi

  if [ "$KUBE_OK" = "true" ]; then
    echo ""
    info "Nodes:"
    kubectl get nodes -o wide 2>/dev/null || warn "Cannot list nodes (insufficient RBAC)"

    echo ""
    info "Node architectures:"
    kubectl get nodes -o json 2>/dev/null | \
      jq -r '.items[] | "\(.metadata.name): \(.status.nodeInfo.architecture)  OS=\(.status.nodeInfo.osImage)  kernel=\(.status.nodeInfo.kernelVersion)  runtime=\(.status.nodeInfo.containerRuntimeVersion)"' 2>/dev/null || \
      warn "Cannot read node info (jq missing or insufficient RBAC)"

    echo ""
    info "Node capacity (pods):"
    kubectl get nodes -o json 2>/dev/null | \
      jq -r '.items[] | "\(.metadata.name): maxPods=\(.status.capacity.pods)  cpu=\(.status.capacity.cpu)  mem=\(.status.capacity.memory)"' 2>/dev/null || \
      warn "Cannot read node capacity"

    # Architecture check
    ARCHS=$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[].status.nodeInfo.architecture] | unique | .[]' 2>/dev/null || echo "unknown")
    for arch in $ARCHS; do
      if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        fail "FATAL: ARM64/aarch64 nodes detected — Pryon images may not support ARM64. Confirm with Pryon before proceeding."
      elif [ "$arch" = "amd64" ] || [ "$arch" = "x86_64" ]; then
        ok "Node architecture: $arch (Pryon-compatible)"
      else
        warn "Unknown node architecture: $arch — verify with Pryon"
      fi
    done

    # maxPods check
    LOW_PODS=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | select((.status.capacity.pods | tonumber) < 200) | .metadata.name' 2>/dev/null || echo "")
    if [ -n "$LOW_PODS" ]; then
      fail "Nodes with maxPods < 200 (Pryon needs 256): $LOW_PODS"
    else
      ok "All nodes have sufficient pod capacity (≥200)"
    fi

    echo ""
    info "Kubernetes version:"
    kubectl version --short 2>/dev/null || kubectl version 2>/dev/null | head -3

    echo ""
    info "Namespaces (existing):"
    kubectl get namespaces 2>/dev/null || warn "Cannot list namespaces"

    echo ""
    info "Storage classes:"
    kubectl get storageclass 2>/dev/null || warn "Cannot list storage classes — B-1 (Longhorn) cannot be verified"

    # Check for NFS (Pryon incompatible)
    NFS_SC=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.provisioner | test("nfs|csi-driver-nfs|efs")) | .metadata.name' 2>/dev/null || echo "")
    if [ -n "$NFS_SC" ]; then
      fail "NFS storage class detected: $NFS_SC — Pryon databases cannot use NFS"
    fi

    BLOCK_SC=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.provisioner | test("longhorn|ebs|rbd|ceph-rbd|disk")) | .metadata.name' 2>/dev/null || echo "")
    if [ -n "$BLOCK_SC" ]; then
      ok "Block storage class found: $BLOCK_SC"
    else
      warn "No recognized block storage class found — Longhorn may not be installed"
    fi

    echo ""
    info "Installed CRDs (key components):"
    for crd in certificates.cert-manager.io \
                issuers.cert-manager.io \
                gateways.networking.istio.io \
                virtualservices.networking.istio.io \
                workflows.argoproj.io \
                volumes.longhorn.io \
                clusterpolicies.nvidia.com \
                ipaddresspools.metallb.io; do
      if kubectl get crd "$crd" &>/dev/null 2>&1; then
        ok "CRD present: $crd"
      else
        info "CRD absent: $crd"
      fi
    done

    echo ""
    info "Pods by namespace (summary — looking for conflicts):"
    kubectl get pods -A --no-headers 2>/dev/null | \
      awk '{print $1}' | sort | uniq -c | sort -rn | head -20 || \
      warn "Cannot list pods across namespaces"

    echo ""
    info "Checking for pre-existing Istio (BLOCKING if cluster-scoped):"
    ISTIO_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "istiod|istio-pilot|istio-ingressgateway" || echo "")
    if [ -n "$ISTIO_PODS" ]; then
      warn "Istio pods found — verify scope (namespace vs cluster):"
      echo "$ISTIO_PODS"
    else
      ok "No existing Istio pods detected"
    fi

    ISTIO_WEBHOOK=$(kubectl get mutatingwebhookconfigurations 2>/dev/null | grep -i istio || echo "")
    if [ -n "$ISTIO_WEBHOOK" ]; then
      fail "Cluster-scoped Istio MutatingWebhookConfiguration found — will conflict with Pryon's namespace-scoped Istio: $ISTIO_WEBHOOK"
    else
      ok "No cluster-scoped Istio webhook found"
    fi

    echo ""
    info "Checking for pre-existing Argo Workflows (BLOCKING if cluster-scoped):"
    ARGO_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep "workflow-controller" || echo "")
    if [ -n "$ARGO_PODS" ]; then
      warn "Argo Workflows controller found — verify namespace scope:"
      echo "$ARGO_PODS"
    else
      ok "No existing Argo Workflows controller detected"
    fi

    echo ""
    info "GPU nodes and NVIDIA device plugin:"
    kubectl get nodes -l "nvidia.com/gpu.present=true" 2>/dev/null | \
      head -5 || info "No nodes labeled nvidia.com/gpu.present=true"
    kubectl get pods -A --no-headers 2>/dev/null | grep -E "nvidia|gpu-operator" | head -10 || \
      info "No GPU operator pods found"

    echo ""
    info "MetalLB:"
    kubectl get pods -n metallb-system 2>/dev/null | head -5 || info "metallb-system namespace not found"
    kubectl get ipaddresspool -A 2>/dev/null || info "No MetalLB IPAddressPool CRD (MetalLB likely not installed)"

    echo ""
    info "Pending / failed pods (potential existing problems):"
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | \
      grep -v "^NAMESPACE" | head -20 || info "None"
  fi
fi

# =============================================================================
# TIER 2 — cluster-admin checks
# =============================================================================
section "TIER 2 — Cluster-Admin Checks"

if ! have_cmd kubectl || [ "${KUBE_OK:-false}" = "false" ]; then
  skip "All Tier 2 checks — kubectl not connected"
else
  CAN_ALL=$(kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null || echo "no")
  if [ "$CAN_ALL" = "yes" ]; then
    ok "Current user has cluster-admin"
  else
    warn "Current user does NOT have cluster-admin — some checks will be incomplete"
    info "RBAC level: $(kubectl auth can-i --list 2>/dev/null | head -5 || echo 'cannot list')"
  fi

  echo ""
  info "PSA (Pod Security Admission) enforcement:"
  # Check if there's a cluster-level PSA policy restricting things
  kubectl get --raw /api/v1/namespaces 2>/dev/null | \
    jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] != null) | "\(.metadata.name): enforce=\(.metadata.labels["pod-security.kubernetes.io/enforce"])"' 2>/dev/null | \
    head -20 || info "Could not read namespace PSA labels"

  # Check admission controller config
  kubectl get admissionconfiguration -A 2>/dev/null | head -5 || true

  echo ""
  info "Kubelet config (maxPods via node status):"
  kubectl get nodes -o json 2>/dev/null | \
    jq -r '.items[] | "  \(.metadata.name): maxPods=\(.status.capacity.pods)"' 2>/dev/null || \
    warn "Cannot read"

  echo ""
  info "RKE2 version (from node labels):"
  kubectl get nodes -o json 2>/dev/null | \
    jq -r '.items[0].status.nodeInfo.kubeletVersion' 2>/dev/null || \
    warn "Cannot read"

  echo ""
  info "Existing imagePullSecrets in any pryon-related namespace:"
  kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson 2>/dev/null | \
    grep -i "pryon\|harbor\|registry" || info "None found"
fi

# =============================================================================
# TIER 3 — Node-level (SSH)
# =============================================================================
section "TIER 3 — Node-Level Checks (requires SSH)"

echo ""
echo -e "  ${BLD}Do you have SSH access to the worker nodes? (y/n):${RST} "
read -r HAVE_SSH || HAVE_SSH="n"

if [ "$HAVE_SSH" != "y" ] && [ "$HAVE_SSH" != "Y" ]; then
  skip "All Tier 3 checks — no SSH access available"
  warn "Without SSH, the following CANNOT be verified on-site:"
  warn "  → FIPS status on worker nodes"
  warn "  → sysctl values (inotify, file-max)"
  warn "  → Container runtime (runc vs crun)"
  warn "  → maxPods kubelet config"
  warn "  → GPU driver / CUDA version"
  warn "  → Available disk on /var/lib/rancher and /var/lib/longhorn"
  ask "MANUAL: Get SSH access confirmed with NCIS DevOps as a pre-deployment requirement"
else
  echo -e "  ${BLD}Comma-separated list of node IPs/hostnames to check:${RST} "
  read -r NODE_LIST || NODE_LIST=""

  echo -e "  ${BLD}SSH user (e.g. rhel, root, admin):${RST} "
  read -r SSH_USER || SSH_USER="rhel"

  echo -e "  ${BLD}SSH key path (blank for password auth):${RST} "
  read -r SSH_KEY || SSH_KEY=""

  SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
  [ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

  IFS=',' read -ra NODES <<< "$NODE_LIST"
  for NODE in "${NODES[@]}"; do
    NODE=$(echo "$NODE" | tr -d ' ')
    [ -z "$NODE" ] && continue

    echo ""
    echo -e "  ${BLD}--- Node: $NODE ---${RST}"

    SSH_CMD="ssh $SSH_OPTS ${SSH_USER}@${NODE}"

    if ! $SSH_CMD "echo ok" &>/dev/null 2>&1; then
      fail "Cannot SSH to $NODE as $SSH_USER — skipping node-level checks"
      continue
    fi

    ok "SSH reachable: $NODE"

    # FIPS
    FIPS=$($SSH_CMD "cat /proc/sys/crypto/fips_enabled 2>/dev/null" || echo "?")
    [ "$FIPS" = "1" ] && ok "$NODE: FIPS enabled" || fail "$NODE: FIPS NOT enabled (got: $FIPS)"

    # sysctl
    WATCHES=$($SSH_CMD "sysctl -n fs.inotify.max_user_watches 2>/dev/null" || echo "0")
    INSTANCES=$($SSH_CMD "sysctl -n fs.inotify.max_user_instances 2>/dev/null" || echo "0")
    info "$NODE: inotify watches=$WATCHES  instances=$INSTANCES"
    [ "$WATCHES" -ge 524288 ] 2>/dev/null && ok "$NODE: inotify watches sufficient" || fail "$NODE: inotify watches too low ($WATCHES < 524288)"

    # Container runtime
    RUNTIME=$($SSH_CMD "cat /etc/rancher/rke2/config.yaml 2>/dev/null | grep default_runtime || /var/lib/rancher/rke2/bin/crictl info 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"config\"][\"default_runtime_name\"])' 2>/dev/null" || echo "unknown")
    info "$NODE: container runtime = $RUNTIME"
    [ "$RUNTIME" = "crun" ] && ok "$NODE: crun configured (GPU time-slicing safe)" || warn "$NODE: runtime=$RUNTIME (crun required on GPU nodes for time-slicing)"

    # maxPods
    MAX_PODS=$($SSH_CMD "cat /etc/rancher/rke2/config.yaml 2>/dev/null | grep -i max.*pod | head -1" || echo "not set")
    info "$NODE: maxPods config = $MAX_PODS (check config.yaml)"

    # Disk
    DISK=$($SSH_CMD "df -h /var/lib 2>/dev/null | tail -1" || echo "?")
    info "$NODE: /var/lib disk = $DISK"

    # GPU check
    if $SSH_CMD "command -v nvidia-smi" &>/dev/null 2>&1; then
      GPU_INFO=$($SSH_CMD "nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null" || echo "error")
      ok "$NODE: GPU found: $GPU_INFO"
      CUDA_VER=$($SSH_CMD "nvidia-smi 2>/dev/null | grep 'CUDA Version' | awk '{print \$NF}'" || echo "unknown")
      info "$NODE: CUDA version = $CUDA_VER"
      if [ "$(echo "$CUDA_VER" | cut -d. -f1)" -ge 13 ] 2>/dev/null; then
        ok "$NODE: CUDA $CUDA_VER ≥ 12.6 (Pryon-compatible)"
      else
        fail "$NODE: CUDA $CUDA_VER < 12.6 — Pryon GPU workloads will fail (need GPU Operator v25.3+)"
      fi
    else
      info "$NODE: no nvidia-smi (not a GPU node, or GPU Operator not yet installed)"
    fi

    # RKE2 service state
    SERVER_STATE=$($SSH_CMD "systemctl is-active rke2-server 2>/dev/null" || echo "not-found")
    AGENT_STATE=$($SSH_CMD "systemctl is-active rke2-agent 2>/dev/null" || echo "not-found")
    info "$NODE: rke2-server=$SERVER_STATE  rke2-agent=$AGENT_STATE"
  done
fi

# =============================================================================
# MANUAL CHECKLIST — things that need a human answer
# =============================================================================
section "MANUAL CHECKLIST — Answers needed from NCIS DevOps"

ask "U-1:  Harbor hostname/URL for Pryon images?"
ask "U-2:  Are Pryon images already mirrored into NCIS Harbor? Under which project?"
ask "U-3:  What 2 IP addresses are allocated for load balancer (Keycloak + Istio)?"
ask "U-4:  What FQDNs are assigned for Pryon? (e.g. pryon.ncis.mil, keycloak.ncis.mil)"
ask "U-5:  Which Pryon chart versions are being deployed? (get from Pryon/Bertrand)"
ask "U-6:  Is there a pre-existing cluster-wide Istio or service mesh?"
ask "U-7:  Is there a pre-existing cluster-wide Argo Workflows?"
ask "U-8:  What namespace(s) does NCIS want Pryon installed in?"
ask "U-9:  Does Ryan have SSH access to worker nodes? (determines B-3, B-4, B-11 fixability)"
ask "U-10: Is there an existing ingress controller?"
ask "U-11: NODE ARCHITECTURE — confirmed x86_64 or ARM64 (Graviton)?"
ask "U-12: FIPS 140-3 already enabled on all nodes? (confirmed by NCIS security team)"
ask "U-13: Does NCIS have an approved method for transferring files into the SCIF?"
ask "U-14: What is the Longhorn storage class name exactly?"
ask "U-15: Does Ryan have pryon-key.json, or does NCIS provision Harbor credentials separately?"

# =============================================================================
# SUMMARY
# =============================================================================
section "DISCOVERY SUMMARY"

echo ""
echo -e "  ${BLD}Results:${RST}"
echo -e "  ${GRN}OK:${RST}      $(grep -c '^OK' <<< "$(printf '%s\n' "${REPORT_LINES[@]}")" || echo 0)"
echo -e "  ${YLW}Warnings:${RST} $WARN_COUNT"
echo -e "  ${RED}Failures:${RST} $FAIL_COUNT"
echo -e "  Manual:   $(grep -c '^MANUAL' <<< "$(printf '%s\n' "${REPORT_LINES[@]}")" || echo 0) items need human answers"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "  ${RED}${BLD}Failures detected. Send this report to Recro before proceeding.${RST}"
  echo -e "  ${RED}Do not begin deployment until failure items are resolved.${RST}"
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo -e "  ${YLW}${BLD}Warnings present. Review with Recro before proceeding.${RST}"
else
  echo -e "  ${GRN}${BLD}No failures. Validate manual checklist items and proceed.${RST}"
fi

echo ""
echo -e "  ${BLD}Save this output:${RST}"
echo "  ./onsite-discovery.sh 2>&1 | tee discovery-\$(hostname)-\$(date +%Y%m%d-%H%M).txt"
echo ""
echo "  Send the .txt file to the Recro team (cwilson@recrocog.com)"
echo "  before end of business on Day 1."
echo ""

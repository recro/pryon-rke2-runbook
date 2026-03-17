# Pryon on RKE2 — Integration Failure Points

Every item below is an assumption baked into the deployment that has a realistic
probability of being wrong when Ryan walks in. They are ordered by severity:
**FATAL** (stop, go home) → **BLOCKING** (nothing works until resolved) →
**REMEDIABLE** (fixable on-site, documented workaround exists) →
**UNKNOWN** (needs an answer before or during Day 1 assessment).

The `onsite-discovery.sh` script checks every FATAL and BLOCKING item
automatically and exits with a report. Run it first. Send the output to Recro
before touching anything else.

---

## Starting assumption: nothing is given

We cannot assume:
- A STIG-hardened OS
- A running RKE2 cluster
- Any platform prerequisites (Longhorn, cert-manager, MetalLB, GPU Operator)
- kubectl on Ryan's terminal
- SSH access to nodes
- Harbor reachable from nodes
- Pryon images pre-staged anywhere
- A network that permits any of the above

Day 1 is a survey, not a deployment. The goal is to determine which layer of
the stack Ryan is starting from, and report that back to Recro by EOD.

```
Layer 0: Hardware / VMs exist and are accessible
Layer 1: RHEL 9 installed
Layer 2: RHEL 9 STIG-hardened + FIPS 140-3 enabled
Layer 3: RKE2 installed and clustered
Layer 4: Platform prerequisites installed (Longhorn, cert-manager, MetalLB, GPU Operator)
Layer 5: Pryon 10 charts deployed and healthy
```

Ryan identifies which layer he's at. We build from that layer up.

---

## FATAL — Cannot proceed; must be resolved before deployment window

### F-1 · Node Architecture Mismatch
**Assumption:** Pryon container images support x86_64.
**Risk:** NCIS Leidos environment specifies EC2 G6s (Graviton, ARM64). If Pryon
has not published multi-arch images, nothing runs at all.
**Check:** `kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.architecture'`
**Owner:** Pryon must confirm multi-arch support OR NCIS must confirm x86_64 nodes.
**Pre-visit:** Get written confirmation before Ryan travels.

---

### F-2 · No Cluster Access
**Assumption:** Ryan has a kubeconfig with cluster-admin.
**Risk:** RBAC may be namespace-scoped, read-only, or kubeconfig may not exist.
**Check:** `kubectl auth can-i '*' '*' --all-namespaces`
**Owner:** NCIS DevOps must provision cluster-admin credentials before the visit.

---

### F-3 · Harbor Unreachable from Cluster Nodes
**Assumption:** Cluster nodes can reach Harbor over HTTPS.
**Risk:** SCIF network policy may block egress entirely. Harbor may be on an
isolated network segment not reachable from worker nodes.
**Check:** `curl -sk https://${HARBOR_HOST}/api/v2.0/ping`
**Owner:** NCIS networking — firewall rule or proxy config needed.

---

### F-4 · Pryon Registry Credentials Not Available On-Site
**Assumption:** `pryon-key.json` is accessible from Ryan's terminal inside the SCIF.
**Risk:** SCIF USB policy may prohibit removable media.
**Owner:** Pryon must pre-provision credentials inside the SCIF boundary, or
NCIS Harbor must have a separate credential set already configured.

---

### F-5 · Pryon Images Not Staged in NCIS Harbor
**Assumption:** NCIS Harbor has Pryon images loaded.
**Risk:** Harbor may be empty or have only infrastructure images.
**Check:** `curl -sk -u "${USER}:${PASS}" "https://${HARBOR_HOST}/api/v2.0/projects/pryon/repositories"`
**Owner:** NCIS + Pryon — images must be staged before the deployment window.
If air-gapped, a Hauler bundle must be transported on approved media.

---

## BLOCKING — Fixable on-site but deployment cannot proceed until resolved

### B-1 · No RKE2 Cluster
**Assumption:** An RKE2 cluster exists and is healthy.
**Risk:** Nodes may be bare RHEL 9. RKE2 installation is the first workload.
**Fix:** Ansible `site-onsite.yml` playbook installs RKE2 (server + agents).
**Requires:** SSH to nodes, RKE2 install script accessible (internet or mirror).

---

### B-2 · RHEL 9 Not STIG-Hardened
**Assumption:** OS-level STIG applied.
**Risk:** Raw RHEL 9 install. STIG hardening changes audit rules, SELinux
contexts, sysctl values, FIPS mode — all of which affect RKE2 stability.
**Fix:** Ansible `ami_stig` + `ami_fips` roles (refactored for SSH transport).
**Note:** FIPS enablement requires a reboot.

---

### B-3 · Longhorn Not Installed / Wrong Storage Class Name
**Assumption:** Longhorn installed, storage class named `longhorn`.
**Risk:** No CSI driver = all database PVCs pending forever.
NFS storage class = YugabyteDB won't start (explicit rejection).
**Fix:** `helm install longhorn longhorn/longhorn -f manifests/longhorn/values.yaml`
**Requires:** Image access (Longhorn images from longhornio — needs mirror if air-gapped).

---

### B-4 · MetalLB Not Installed / No IP Pool
**Assumption:** Two dedicated IPs available for LoadBalancer services.
**Risk:** Services type LoadBalancer stay `<pending>`. Keycloak and Istio
ingress unreachable. Nothing works end-to-end.
**Fix:** Install MetalLB + configure IPAddressPool with 2 IPs from NCIS.
**Requires:** NCIS must provide 2 pre-allocated IPs (U-3).

---

### B-5 · maxPods = 110 (Kubernetes Default)
**Assumption:** kubelet configured with `maxPods: 256`.
**Risk:** Pryon deploys ~150–200 pods. Workers hit the ceiling mid-deployment.
New pods fail with `Too many pods`. Deployment appears to partially succeed.
**Fix:** Edit `/etc/rancher/rke2/config.yaml` on each worker, restart `rke2-agent`.
**Requires:** SSH to worker nodes.

---

### B-6 · sysctl Defaults (inotify / file descriptors)
**Assumption:** Pryon OS tuning applied.
**Risk:** Default RHEL 9: `fs.inotify.max_user_watches=8192` (need 524288+).
Pods crash or fail to start under load — intermittent, hard to diagnose.
**Fix:** Write `/etc/sysctl.d/99-pryon.conf`, run `sysctl --system`. No reboot needed.
**Requires:** SSH to nodes (or root on nodes).

---

### B-7 · FIPS 140-3 Not Enabled
**Assumption:** FIPS 140-3 enabled at OS level.
**Risk:** Cannot be fixed on a running node — requires reboot + re-enrollment.
If not enabled, STIG scans fail and NCIS security will not approve the install.
**Fix:** Must be done before RKE2 is installed. Pre-visit requirement.
**Owner:** NCIS must confirm FIPS status before the deployment window.

---

### B-8 · Cluster-Wide Istio Already Installed
**Assumption:** No existing Istio. Pryon installs namespace-scoped Istio.
**Risk:** Two Istio control planes fighting over sidecar injection = random
pod failures across the entire cluster. Immediate cluster destabilization.
**Fix:** Coordinate with NCIS to remove or scope down existing Istio.
Cannot be done solo. Pre-visit conversation required.

---

### B-9 · Cluster-Wide Argo Workflows Already Installed
**Assumption:** No existing Argo Workflows.
**Risk:** Pryon ingestion uses Argo. Two workflow controllers watching the
same CRDs = workflow conflation and unpredictable execution behavior.
**Fix:** Reconfigure existing Argo to namespace-scoped, or negotiate parallel install.

---

### B-10 · NVIDIA GPU Operator Not Installed / Wrong Version
**Assumption:** GPU Operator v25.3+ installed (CUDA 13.0 / driver 580.x).
**Risk:** GPU Operator v24.9 provides CUDA 12.4 — insufficient. Vision,
delphigpuexchange, and all vLLM pods crash with CUDA version mismatch.
**Fix:** `helm install gpu-operator nvidia/gpu-operator -f manifests/gpu-operator/values.yaml`
Chart specifies v25.3+ in `values.yaml`.

---

### B-11 · cert-manager Not Installed
**Assumption:** cert-manager present for Istio and Keycloak TLS.
**Risk:** Certificate issuance fails. Istio mTLS bootstrapping fails.
**Fix:** `helm install cert-manager jetstack/cert-manager -f manifests/cert-manager/values.yaml`

---

### B-12 · runc on GPU Nodes (time-slicing procfs bug)
**Assumption:** GPU nodes running crun.
**Risk:** runc 1.2.5 bug causes "unsafe procfs detected" crash on any pod with
`shareProcessNamespace: true`. Confirmed on OpenShift; same bug present in RKE2.
**Fix:** Override containerd default runtime on GPU nodes to crun via
`/etc/rancher/rke2/config.yaml` + containerd `config.toml`.
**Requires:** SSH to GPU worker nodes.

---

## REMEDIABLE — Documented workarounds; fixable during deployment

| # | Issue | Fix |
|---|-------|-----|
| R-1 | imagePullSecrets not created | `kubectl create secret docker-registry pryon-registry ...` in each namespace |
| R-2 | Namespace PSA not privileged for Istio | `kubectl label namespace istio-system pod-security.kubernetes.io/enforce=privileged` |
| R-3 | DNS not configured | NCIS provides FQDNs + IPs; Ryan manually confirms resolution |
| R-4 | YugabyteDB `pryon` user not auto-created | Manual `CREATE USER` in YSQL + YCQL after databases chart healthy |
| R-5 | Placeholder env vars in ext-access / opsconsole | `kubectl set env` with actual Keycloak FQDN |
| R-6 | Keycloak missing redirect URIs for opsconsole | Keycloak Admin API: add `/ops-console/*` to pryon-platform-client |
| R-7 | opsconsole readOnlyRootFilesystem crash | Runtime patch: emptyDir volume + init container for env.js |
| R-8 | floating-server permission denied | Patch StatefulSet: add emptyDir for /opt/server/logs and /opt/server/database |
| R-9 | YugabyteDB CPU request > node allocatable | Override: `yb-tserver.resources.requests.cpu: 7` in databases values |
| R-10 | delphigpuexchange minReplicas=6 | Override: `autoscaling.minReplicas: 1` in retrieval values |
| R-11 | Redis node affinity mismatch | Override node selector in values to match actual node labels |
| R-12 | GPU nodes not labeled | `kubectl label node <gpu-node> pryon.ai/gpu=enabled` |

---

## UNKNOWN — Must be answered on Day 1

| # | Question | Blocks | Owner |
|---|----------|--------|-------|
| U-1 | Harbor hostname/URL? | Everything | NCIS |
| U-2 | Pryon images mirrored to NCIS Harbor? Under which project path? | F-5 | NCIS + Pryon |
| U-3 | 2 IP addresses for load balancer (Keycloak + Istio)? | B-4, R-3 | NCIS |
| U-4 | FQDNs assigned for Pryon and Keycloak? | R-3, values files | NCIS |
| U-5 | Which Pryon chart versions to deploy? | Every `helm pull` | Pryon (Bertrand) |
| U-6 | Pre-existing cluster-wide Istio? | B-8 | NCIS |
| U-7 | Pre-existing cluster-wide Argo Workflows? | B-9 | NCIS |
| U-8 | Target namespace(s) for Pryon? | Namespace creation, PSA, RBAC | NCIS |
| U-9 | SSH access to worker nodes? | B-5, B-6, B-12 | NCIS |
| U-10 | Existing ingress controller? | Potential Istio conflict | NCIS |
| U-11 | **Node architecture — x86_64 or ARM64?** | **F-1 — most critical** | NCIS + Pryon |
| U-12 | FIPS 140-3 already enabled on all nodes? | B-7 | NCIS |
| U-13 | Method for transferring files into the SCIF? | Everything (repo, Hauler bundle) | NCIS |
| U-14 | Longhorn version and storage class name? | B-3, values files | NCIS |
| U-15 | Ryan's Harbor credentials — pryon-key.json or NCIS-provisioned? | F-4 | Pryon + NCIS |
| U-16 | What layer is the stack at when Ryan walks in? (Layer 0–4) | Determines entire plan | NCIS |

---

## Day 1 Go / No-Go Gate

Ryan runs `onsite-discovery.sh`, sends the output to Recro by EOD.

**Go:** F-1, F-2, F-3, F-5 are confirmed clear. B-7 (FIPS) confirmed by NCIS.
U-11 (architecture) confirmed x86_64. U-16 is answered. Deployment window begins.

**No-Go:** Any FATAL unresolved, or U-16 reveals the stack is at Layer 0–1
(bare metal / un-STIGged OS). Recro and NCIS must resolve blockers before
scheduling the next deployment window.

**Discovery-only:** Ryan cannot get past Tier 0 (no kubectl, no SSH).
Day 1 becomes entirely a meeting-based survey. Ryan asks the NCIS DevOps
engineer every U-* question and documents the answers. Sends that back.
No scripts needed.

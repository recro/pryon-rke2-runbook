# Claude Context — Pryon RKE2 On-Site Deployment

## Mission

Prepare Ryan Zielinski to install the Pryon platform on a STIG-hardened RKE2
cluster at NCIS. This repository contains everything Ryan needs to carry in:
a discovery script, a printable runbook, Ansible automation, and Helm values
for all 10 Pryon platform charts.

**The core operating assumption: nothing is given.** Ryan may walk into bare
RHEL 9 nodes with no Kubernetes, no storage, no registry access, and no
prior Pryon deployment artifacts. The automation must handle every layer.

---

## Engagement Context

**Customer:** NCIS (Naval Criminal Investigative Service)  
**Platform:** Pryon — RAG/agentic platform for enterprise  
**Environment:** STIG-hardened RHEL 9 + RKE2, air-gap capable, FIPS 140-3  
**Timeline:** Production deployment end of March 2026  
**On-site engineer:** Ryan Zielinski

**Recro contact:** cwilson@recrocog.com  
**Pryon contact (charts/registry):** Bertrand (Head of Deployments)

---

## Repository Purpose

This is a **public** repository. It must never contain:
- Credentials, tokens, or keys
- Customer-specific hostnames or IP addresses  
- Classified or CUI content
- Real registry URLs (use `{{ HARBOR_HOST }}` placeholders)

All environment-specific values live in a local `inventory.yml` and
`*.local.yaml` files (gitignored). The repo ships templates and automation;
Ryan fills in the blanks on Day 1 after running discovery.

---

## Stack Layers

The deployment is structured around which layer the environment is at when
Ryan arrives. Day 1 discovery (`scripts/onsite-discovery.sh`) determines this.

| Layer | State | Est. Time |
|-------|-------|-----------|
| 0 | Bare hardware, no OS | Out of scope (NCIS provisions) |
| 1 | RHEL 9 installed, not hardened | ~4 hrs (STIG + FIPS + reboot) |
| 2 | RHEL 9 STIG + FIPS complete | ~2 hrs (RKE2 cluster) |
| 3 | RKE2 running | ~2 hrs (Longhorn, MetalLB, GPU Operator, cert-manager) |
| 4 | Prerequisites installed | ~3–4 hrs (Pryon 10 charts + post-install) |
| 5 | Pryon deployed | Validation + handoff |

---

## Pryon Platform Architecture

10 umbrella Helm charts deployed in strict order:

1. **Istio** — service mesh + ingress gateway (namespace-scoped, NOT cluster-wide)
2. **Keycloak** — identity and access management
3. **Databases** — YugabyteDB (PostgreSQL + Cassandra layers) + OpenSearch
4. **Platform** — core services, access service, floating-server
5. **Ingestion** — Argo Workflows-based document pipeline (namespace-scoped)
6. **Connectors** — external datasource polling
7. **Retrieval** — vector search, int-qr, delphigpuexchange
8. **Generative** — vLLM inference (GPU required, CUDA ≥ 12.6)
9. **Clients** — opsconsole UI, adminui
10. **Observability** — Prometheus + Grafana

**Critical constraints:**
- Istio: namespace-scoped only. Cluster-wide Istio will conflict.
- Argo Workflows: namespace-scoped only. Cluster-wide causes workflow collision.
- Storage: block storage only (Longhorn). NFS explicitly rejected by YugabyteDB.
- GPU: NVIDIA GPU Operator v25.3+ required (CUDA 13.0). v24.9 insufficient.
- Pods: 256 maxPods per node required (Kubernetes default is 110).

---

## Known Issues (from OpenShift STIG validation — apply to RKE2)

These are confirmed bugs or misconfigurations in Pryon's Helm charts that
require workarounds. All are documented in `docs/INTEGRATION_FAILURE_POINTS.md`
and scripted in `scripts/`.

| Component | Issue | Fix |
|-----------|-------|-----|
| Istio | Sidecar needs NET_ADMIN | PSA `privileged` on istio-system namespace |
| GPU nodes | runc 1.2.5 procfs bug with time-slicing | Switch GPU nodes to crun runtime |
| GPU Operator | CUDA 12.4 insufficient | Upgrade to v25.3+ (driver 580.x, CUDA 13.0) |
| opsconsole | readOnlyRootFilesystem + sed on entrypoint | emptyDir + init container patch |
| floating-server | Permission denied on /opt/server/logs | emptyDir mount patch |
| YugabyteDB | `pryon` user not auto-created | Manual CREATE USER in YSQL + YCQL |
| ext-access | Literal placeholder env vars | `kubectl set env` with real Keycloak URL |
| Keycloak | Missing opsconsole redirect URIs | Admin API: add /ops-console/* |
| delphigpuexchange | minReplicas=6 assumes 6 GPUs | Override to minReplicas=1 |
| Redis | Node affinity mismatch on custom labels | Override node selector in values |

---

## Repository Structure

```
pryon-rke2-runbook/
├── CLAUDE.md                           ← you are here
├── README.md                           ← public-facing entry point
├── docs/
│   ├── INTEGRATION_FAILURE_POINTS.md  ← every assumption + failure mode
│   ├── LAYER_GUIDE.md                 ← what to do at each starting layer
│   └── RUNBOOK.md                     ← printable ≤20-page field guide
├── scripts/
│   ├── onsite-discovery.sh            ← Day 1 read-only survey (run first)
│   ├── site-onsite.sh                 ← full stack bootstrap (Layer 1→4)
│   ├── deploy-pryon.sh                ← ordered Pryon chart deployment
│   └── post-install.sh                ← YugabyteDB user, env patches, Keycloak
├── ansible/
│   ├── site-onsite.yml                ← SSH-based (no AWS/SSM dependency)
│   ├── inventory.yml.example          ← template: fill in node IPs on Day 1
│   └── roles/                         ← STIG, FIPS, RKE2, GPU, Pryon tuning
└── values/
    ├── 01-istio-values.yaml           ← namespace-scoped, PSA privileged
    ├── 02-keycloak-values.yaml
    ├── 03-databases-values.yaml       ← Longhorn SC, YugabyteDB CPU override
    ├── 04-platform-values.yaml
    ├── 05-ingestion-values.yaml       ← Argo namespace-scoped
    ├── 06-connectors-values.yaml
    ├── 07-retrieval-values.yaml       ← int-qr emptyDir, minReplicas=1
    ├── 08-generative-values.yaml      ← GPU node selector, CUDA 12.6+
    ├── 09-clients-values.yaml         ← opsconsole emptyDir patch
    └── 10-observability-values.yaml
```

---

## Day 1 Protocol

1. Run `scripts/onsite-discovery.sh` — capture full output to a `.txt` file
2. Send output to Recro (cwilson@recrocog.com) by end of business
3. Wait for go/no-go from Recro before beginning any deployment work
4. Fill in `ansible/inventory.yml` from the `inventory.yml.example` template
5. Fill in local values overrides based on answers to U-* questions

**Go/No-Go gate:**
- F-1 (node architecture) confirmed x86_64
- F-3 (Harbor reachable from nodes) confirmed
- F-5 (Pryon images staged in Harbor) confirmed
- B-7 (FIPS 140-3 enabled) confirmed by NCIS security team
- U-16 (starting layer) known

If any of those are unresolved, Day 1 is discovery-only. No deployment.

---

## Related Repositories

| Repo | Purpose |
|------|---------|
| `recro/rke2-pryon-infra` | AWS-based digital twin environment (Terraform + Packer + Ansible over SSM). CI/CD pipeline, STIG compliance scans. Source of the Ansible roles used here. |

---

## Sensitive Material Handling

Never commit to this repository:
- `pryon-key.json` (Harbor registry credentials)
- `inventory.yml` (contains node IPs)
- `*.local.yaml` / `*.local.yml` (contains real hostnames, IPs, secrets)
- Any kubeconfig file
- Any SSH private key

These are gitignored. Keep them on a local filesystem or in an approved
secrets manager only.

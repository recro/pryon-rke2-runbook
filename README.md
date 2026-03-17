# Pryon RKE2 Runbook

On-site deployment automation and runbook for installing the Pryon platform
on a STIG-hardened RKE2 cluster.

**Maintained by:** Recro  
**Engagement:** Pryon / NCIS Digital Twin  
**Classification:** UNCLASSIFIED — no credentials, no hostnames, no customer data

---

## Repository Structure

```
pryon-rke2-runbook/
├── docs/
│   ├── INTEGRATION_FAILURE_POINTS.md   # Every assumption + what breaks if wrong
│   ├── RUNBOOK.md                       # Printable step-by-step (≤20 pages)
│   └── LAYER_GUIDE.md                   # What to do at each starting layer (0–5)
├── scripts/
│   ├── onsite-discovery.sh              # Day 1: read-only environment survey
│   ├── site-onsite.sh                   # Full stack install (Layer 0 → 4)
│   └── deploy-pryon.sh                  # Pryon 10-chart ordered deployment
├── ansible/
│   ├── site-onsite.yml                  # SSH-based playbook (no AWS/SSM)
│   ├── inventory.yml.example            # Fill in node IPs on Day 1
│   └── roles/ -> (symlink or copy from rke2-pryon-infra)
└── values/
    ├── 01-istio-values.yaml
    ├── 02-keycloak-values.yaml
    ├── 03-databases-values.yaml
    ├── 04-platform-values.yaml
    ├── 05-ingestion-values.yaml
    ├── 06-connectors-values.yaml
    ├── 07-retrieval-values.yaml
    ├── 08-generative-values.yaml
    ├── 09-clients-values.yaml
    └── 10-observability-values.yaml
```

---

## Day 1 — Discovery (always start here)

Before touching anything, run the discovery script from whatever terminal
you have access to inside the environment:

```bash
curl -fsSL https://raw.githubusercontent.com/recro/pryon-rke2-runbook/main/scripts/onsite-discovery.sh \
  | bash 2>&1 | tee discovery-$(hostname)-$(date +%Y%m%d-%H%M).txt
```

Or if you have the repo cloned:

```bash
chmod +x scripts/onsite-discovery.sh
./scripts/onsite-discovery.sh 2>&1 | tee discovery-$(hostname)-$(date +%Y%m%d-%H%M).txt
```

Send the `.txt` output file to Recro (cwilson@recrocog.com) by end of Day 1.
Do not begin deployment until Recro has reviewed the output.

---

## Stack Layers

The runbook is structured around which layer you're starting from.
Day 1 discovery tells you which layer the environment is at.

| Layer | State | Time estimate |
|-------|-------|---------------|
| 0 | Bare hardware / VMs, no OS | Out of scope — NCIS provision |
| 1 | RHEL 9 installed, not hardened | ~4 hrs (STIG + FIPS + reboot) |
| 2 | RHEL 9 STIG + FIPS complete | ~2 hrs (RKE2 install + cluster) |
| 3 | RKE2 cluster running | ~2 hrs (Longhorn, MetalLB, GPU, cert-manager) |
| 4 | Prerequisites installed | ~3–4 hrs (Pryon 10 charts + post-install) |
| 5 | Pryon deployed | Validation + handoff |

See `docs/LAYER_GUIDE.md` for what to do at each layer.

---

## Key Documents

- **[INTEGRATION_FAILURE_POINTS.md](docs/INTEGRATION_FAILURE_POINTS.md)** —
  Comprehensive catalog of every assumption that can be wrong and what breaks.
  Read this before the site visit.

- **[RUNBOOK.md](docs/RUNBOOK.md)** *(in progress)* —
  Printable step-by-step for Ryan to carry in.

---

## Security Notice

This repository is **public and intentionally contains no sensitive information**.

- No credentials, tokens, or keys
- No customer-specific hostnames or IP addresses
- No classified or CUI content
- All environment-specific values use `{{ PLACEHOLDER }}` syntax

Fill in placeholders locally. Never commit real values to this repo.

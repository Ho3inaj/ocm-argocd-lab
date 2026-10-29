# ocm-argocd-lab — Multi-cluster GitOps: Push vs Pull (OCM + ArgoCD)

Hands-on homelab: **3 VMware VMs (Debian 13), 3 kind clusters, 1 OCM hub + 2 spokes**,
one git repo, one workload — delivered two ways so you can *feel* the difference between
**push** and **pull** GitOps.

**Start here → [RUNBOOK.md](RUNBOOK.md)** (zero-to-hero, step by step, with drills).

## Topology

```
                        Windows laptop (you)
                 edit git · scp relays · SSH · browser
                              |        |
        ┌─────────────────────┼────────┼──────────────────────┐
        │        VMware NAT (vmnet8)   192.168.240.0/24       │
        │                     |           |            |      │
        │   ┌─────────────────┴──┐   ┌─────┴─────┐ ┌────┴────┐│
        │   │  hub   .10        │   │ spoke1 .11│ │spoke2 .12││
        │   │  kind "hub"       │   │ kind      │ │ kind     ││
        │   │  · OCM cluster-   │──▶│ klusterlet│ │klusterlet││
        │   │    manager        │   │ no ArgoCD │ │ ArgoCD ▲ ││
        │   │  · ArgoCD (full)  │───┼── PUSH ──▶│ │  (shipped││
        │   │    holds spoke1   │   │  creds:   │ │  by OCM  ││
        │   │    kubeconfig     │   │  hub holds│ │  add-on) ││
        │   │  · pull controller│   └───────────┘ └────┬─────┘│
        │   │  · ApplicationSet │◀── ManifestWork ─────┘      │
        │   └───────────────────┘   (spoke2 pulls it itself)   │
        └─────────────────────────────────────────────────────┘
```

- **PUSH** (`spoke1`): hub ArgoCD → `https://192.168.240.11:6443` using a cluster secret.
- **PULL** (`spoke2`): hub wraps the `Application` in an OCM **ManifestWork** → spoke2's
  work-agent fetches it → **spoke2's own ArgoCD** reconciles from git locally.
  Hub holds **zero** credentials for spoke2.

## The comparison (same both sides, one variable: direction)

- Same public GitHub repo, same commit, same podinfo Helm chart (wrapped by kustomize
  overlays — `apps/overlays/spoke1` vs `apps/overlays/spoke2`, values-only differences).
- Same sync policy (`automated`, `prune`, `selfHeal`).
- Drills: baseline → hub power-off → spoke API down → drift/self-heal → one-commit/two-paths.

## Pinned versions (all in [`config.sh`](config.sh))

| Component | Version | Why |
|---|---|---|
| kind | v0.33.0 (node image k8s **1.37.0**) | current stable |
| kubectl | v1.37.2 | matches k8s 1.37 line |
| Helm | **v3.22.1** (last 3.x) | kustomize `--enable-helm` compatibility (Helm 4 is out but unproven with kustomize) |
| OCM / clusteradm | **v1.4.0 / v1.4.0** | matching bundle |
| ArgoCD | **v3.5.6** | current stable; server-side apply required |
| podinfo chart | 6.17.0 | tiny, message visible in HTTP response |
| OS | Debian 13 (trike) | matches your prod servers |

## Repository layout

```
config.sh                    ← EDIT: git URL + all version pins + VM IPs
RUNBOOK.md                   ← the actual lab (start here)
apps/
  base/                      ← shared default values + reference render of the podinfo chart
  overlays/spoke1/           ← push target: chart ref + values + patch (replicas 1, PUSH message)
  overlays/spoke2/           ← pull target: chart ref + values + patch (replicas 2, PULL message)
infra/
  bootstrap.sh               ← per-VM: docker, kind, kubectl, helm, clusteradm, argocd CLI
  kind/{hub,spoke1,spoke2}.yaml  ← certSANs = VM IP, port 6443 published
  create-cluster.sh          ← create kind cluster + rewrite kubeconfig to VM IP + verify
  setup-ocm-hub.sh           ← clusteradm init + save join command
  setup-ocm-spoke.sh         ← clusteradm join (parse hub/token from join file)
  setup-ocm-accept.sh        ← accept joins + clusterSet/labels for placement
  setup-argocd-push.sh       ← ArgoCD install + spoke1 cluster secret + push Application
  setup-argocd-pull.sh       ← hub add-on + enable on spoke2 + binding/placement + ApplicationSet
  argocd/push-application.yaml
  argocd/pull-applicationset.yaml   ← official OCM pattern: label + skip-reconcile annotations
  ocm/placement.yaml         ← selects clusters labeled pull-target=true
  ocm/managedclustersetbinding.yaml ← lets ns argocd placements see the default clusterSet
```

## Weekend schedule (as planned)

| Slot | Runbook |
|---|---|
| Sat AM | Phase 0–1: repo, bootstrap, kind clusters, cross-VM TLS proof |
| Sat PM | Phase 2: OCM mesh + **push** delivery + drill 1 + UI |
| Sun AM | Phase 3: **pull** delivery chain, hop-by-hop inspection |
| Sun PM | Phase 4: drills 2–5, fill the comparison table, cleanup notes |

## Requirements

- 3 × Debian 13 VMs, **4 GB RAM / 40 GB disk** each (assumed), NAT adapter, static IPs
  `.10 / .11 / .12` in `192.168.240.0/24` (or edit `config.sh` + kind certSANs)
- Your Windows machine: PowerShell, `git`, OpenSSH (both present on your laptop)
- ~4 GB of image pulls over NAT on first boot

## Out of scope / later

Advanced pull model with **argocd-agent** (`GitOpsCluster` CR, full hub-UI status mirroring)
— see the end of [RUNBOOK.md](RUNBOOK.md).

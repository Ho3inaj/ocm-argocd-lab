# RUNBOOK — OCM + ArgoCD: Push vs Pull GitOps (zero to hero)

You will build **3 kind clusters on 3 Debian 13 VMs**, wire them into an **Open Cluster
Management (OCM)** hub-spoke mesh, then deploy the *same* podinfo app from the *same* git
repo two different ways and break things on purpose to feel the difference:

| Model | Engine | Direction | Target |
|---|---|---|---|
| **PUSH** | ArgoCD **on the hub** holds spoke1's credentials and applies manifests over the network | hub → spoke1 | spoke1 (`192.168.240.11`) |
| **PULL** | Hub wraps the ArgoCD `Application` in an OCM **ManifestWork**; spoke2's work-agent fetches it; **spoke2's own ArgoCD** applies it locally | spoke2 dials out → hub & git | spoke2 (`192.168.240.12`) |

> **Convention:** `<vmuser>` = your Debian login (run `whoami` on any VM to see it).
> Everything marked **[WINDOWS]** runs in PowerShell on your laptop. Everything else runs
> on the VM you're SSH'd into. Replace `YOUR_GITHUB_USERNAME` for real.

---

## 0. Concepts (read once, 5 minutes)

| Term | Plain English |
|---|---|
| **hub / spoke** | hub = control plane cluster; spoke (managed cluster) = cluster being controlled |
| **`ManagedCluster`** | hub's record of one spoke; `Available=True` means healthy & connected |
| **klusterlet** | the OCM agent installed *on the spoke*; it **dials the hub** (pull-direction!) |
| **ManifestWork** | "hey spoke, here's a payload — pull it down and apply it". The OCM pull primitive |
| **add-on** | optional component shipped to spokes *via* ManifestWork (our `argocd` add-on ships ArgoCD to spoke2) |
| **Placement / PlacementDecision** | "pick N clusters matching this label". Feeds the ApplicationSet generator |
| **push vs pull (GitOps)** | **push:** engine holds cluster credentials, applies outward. **pull:** agent on the cluster fetches work itself — survives hub outages, no hub→spoke credentials |
| **ApplicationSet** | Application factory: one template × N selected clusters |
| **`skip-reconcile`** | annotation that freezes the hub copy of an Application so only the spoke's ArgoCD reconciles it (this is what makes "pull" work) |

---

## PHASE 0 — Git repo prep **[WINDOWS]** (~10 min)

1. Create a **public** GitHub repo named `ocm-argocd-lab` (no README, no .gitignore — empty).
2. Edit `config.sh` in this folder: set `GIT_REPO_URL` to your repo URL. Leave branch `main`.
3. One-time git identity (skip if you already have one — `git config --global user.name`):

```powershell
git config --global user.name "Your Name"
git config --global user.email "you@users.noreply.github.com"
```

4. Publish the lab (run in PowerShell from this folder):

```powershell
cd "$env:USERPROFILE\Documents\ocm"
git init -b main
git add -A
git -c core.autocrlf=false commit -m "ocm + argocd push vs pull lab"
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/ocm-argocd-lab.git
git push -u origin main
```

> Auth tip: `git push` will prompt for a GitHub login — use a **Personal Access Token**
> (classic, `repo` scope) as the password if 2FA is on.

✅ **Checkpoint:** the repo URL opens in a browser and shows `apps/`, `infra/`, `RUNBOOK.md`.

---

## PHASE 1 (Sat AM) — VMs, bootstrap, kind clusters

### 1. VM network sanity **[WINDOWS]**

Your 3 VMs must be on VMware **NAT** (vmnet8) with their original IPs:

```powershell
ping 192.168.240.10   # hub
ping 192.168.240.11   # spoke1
ping 192.168.240.12   # spoke2
ssh <vmuser>@192.168.240.10
```

If IPs differ from `.10/.11/.12`: either fix them inside each guest
(`/etc/systemd/network/` or `interfaces`: `192.168.240.x/24`, gateway `192.168.240.2`,
DNS `1.1.1.1`) or edit the IPs at the top of `config.sh` **and** in the three
`infra/kind/*.yaml` certSANs — then re-push before continuing.

### 2. Bootstrap each VM (run on ALL 3 — ~5 min each)

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/YOUR_GITHUB_USERNAME/ocm-argocd-lab.git
cd ocm-argocd-lab
sudo bash infra/bootstrap.sh
exec bash                 # reload shell so docker group applies
docker ps                 # must NOT say "permission denied"
```

`bootstrap.sh` installs: Docker CE · kind `v0.33.0` (k8s 1.37) · kubectl `v1.37.2` ·
helm `v3.22.1` · clusteradm `v1.4.0` · argocd CLI `v3.5.6` — all pinned in `config.sh`.

✅ **Checkpoint:** version table printed at the end of the script on all 3 VMs.

### 3. Create one kind cluster per VM (run ON that VM)

```bash
# ON hub VM:
bash infra/create-cluster.sh hub
# ON spoke1 VM:
bash infra/create-cluster.sh spoke1
# ON spoke2 VM:
bash infra/create-cluster.sh spoke2
```

What this does: creates a single-node kind cluster, then **rewrites the kubeconfig server
to `https://<VM-IP>:6443`** and verifies TLS works. The kind config put your VM IP into the
apiserver certificate SANs and published port 6443 on the VM — without both, no other
cluster can ever talk to this one.

✅ **Checkpoint (both must pass — the script itself runs them):**
1. `KUBECONFIG=~/.kube/<role>.kubeconfig kubectl get nodes -o wide` → `Ready`
2. plain `kubectl get nodes -o wide` → `Ready` (default config, this is what everything else uses)

### 4. Relay credentials through Windows **[WINDOWS]**

VMs can't scp to each other (no shared keys) — use your laptop as courier:

```powershell
cd ~   # any scratch folder
scp <vmuser>@192.168.240.10:ocm-join.txt .     # (this file arrives in Phase 2; skip for now)
scp <vmuser>@192.168.240.11:.kube/spoke1.kubeconfig .
scp <vmuser>@192.168.240.12:.kube/spoke2.kubeconfig .
scp .\spoke1.kubeconfig <vmuser>@192.168.240.10:~
scp .\spoke2.kubeconfig <vmuser>@192.168.240.10:~
```

(First scp of `ocm-join.txt` happens after Phase 2 step 1 — do that part later.)

### 5. Cross-cluster reachability proof **ON hub VM**

```bash
KUBECONFIG=~/.kube/spoke1.kubeconfig kubectl get nodes
```

✅ If `Ready` — the hub can reach spoke1's apiserver over TLS. **This is exactly the path
the PUSH model will use.** If it fails with `x509: certificate is valid for ...` the
certSANs didn't take → recreate the cluster (step 3).

---

## PHASE 2 (Sat PM) — OCM mesh + PUSH delivery

### 1. Initialize the OCM hub — **ON hub VM**

```bash
bash infra/setup-ocm-hub.sh
```

Runs `clusteradm init --wait` (installs the OCM control plane into namespace
`open-cluster-management`) and saves the spoke join command to `~/ocm-join.txt`.

✅ `kubectl get deployment -n open-cluster-management cluster-manager` → `Ready 1/1` (or 2).

### 2. Relay the join command **[WINDOWS]**

```powershell
scp <vmuser>@192.168.240.10:ocm-join.txt .
scp .\ocm-join.txt <vmuser>@192.168.240.11:~
scp .\ocm-join.txt <vmuser>@192.168.240.12:~
```

### 3. Join both spokes — **ON spoke1 VM, then spoke2 VM**

```bash
# spoke1 VM:
bash infra/setup-ocm-spoke.sh spoke1 ~/ocm-join.txt
# spoke2 VM:
bash infra/setup-ocm-spoke.sh spoke2 ~/ocm-join.txt
```

This installs the **klusterlet** agent on the spoke. Notice the direction: the spoke
*dials the hub* using the token — nothing on the hub reaches into the spoke yet.

### 4. Accept + verify — **ON hub VM**

```bash
bash infra/setup-ocm-accept.sh
```

Accepts both join requests (OCM requires explicit approval), places both clusters into
the `default` ManagedClusterSet, and tags `spoke2` with `pull-target=true` (that label is
what the pull-model Placement will select on later).

✅ **Checkpoint — this is your multi-cluster control plane:**

```bash
kubectl get managedclusters
# NAME      HUB ACCEPTED  JOINED   AVAILABLE   AGE
# spoke1    true          True     True        ...
# spoke2    true          True     True        ...
```

💡 On spoke VMs peek at the agent: `kubectl -n open-cluster-management-agent get pods`
(registration + work agents — the work-agent is the thing that later pulls ManifestWorks).

### 5. Install ArgoCD + register spoke1 (PUSH credentials) — **ON hub VM**

```bash
bash infra/setup-argocd-push.sh ~/spoke1.kubeconfig
```

What it does, in order: installs ArgoCD v3.5.6 (server-side apply — plain apply chokes on
the giant ApplicationSet CRD), enables `kustomize.buildOptions=--enable-helm` (our overlays
build a Helm chart through kustomize), extracts spoke1's CA/cert/key from the kubeconfig
into a **cluster secret** (the push model's core artifact: *the hub now holds spoke1's
keys*), then applies `infra/argocd/push-application.yaml`.

✅ **Checkpoints:**

```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster   # argocd-cluster-spoke1
kubectl -n argocd get application podinfo-push-spoke1                      # Synced / Healthy within ~3 min
KUBECONFIG=~/.kube/spoke1.kubeconfig kubectl -n podinfo get deploy,pods
KUBECONFIG=~/.kube/spoke1.kubeconfig kubectl -n podinfo exec deploy/podinfo -- wget -qO- localhost:9898/env | grep MESSAGE
# → "PUSH: hub ArgoCD pushed this to spoke1"
```

ArgoCD polls git every ~3 min (no webhooks in this lab) — first sync can take a minute or
two. **DRILL 1 (push) done when the MESSAGE shows.**

### 6. Look at the ArgoCD UI (optional but worth it) **[WINDOWS]**

```powershell
ssh -L 8080:localhost:8080 <vmuser>@192.168.240.10     # keep this window open
```
Then in a second terminal:
```powershell
ssh <vmuser>@192.168.240.10
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
```
Browser: `http://localhost:8080` — login `admin` / password printed by
`setup-argocd-push.sh` (or get it any time:
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

Open the app `podinfo-push-spoke1` → full resource tree, live state, sync history. **Remember
this view — the pull side will look poorer (step 7).**

---

## PHASE 3 (Sun AM) — PULL delivery via OCM add-on

### 1. Install the pull machinery — **ON hub VM**

```bash
bash infra/setup-argocd-pull.sh
```

Step by step: installs the `argocd` **hub add-on** (deploys `argocd-pull-integration`
controller = the pull controller + status feedback controller) → enables the add-on on
**spoke2 only** (OCM ships ArgoCD *to* spoke2 via ManifestWork and waits until it's
`Available`) → applies `ManagedClusterSetBinding` (lets placements in ns `argocd` see
clusters) → applies `Placement app-placement` (selects clusters labeled `pull-target=true`
= only spoke2) → applies the `ApplicationSet podinfo-pull-set`.

### 2. Walk the pull chain — **watch every hop**

```bash
# (a) ApplicationSet generated one Application per selected cluster — on the HUB:
kubectl -n argocd get application
#   spoke2-podinfo-pull          ← exists on hub but FROZEN (skip-reconcile), no status yet

# (b) the pull controller wrapped it into a ManifestWork in spoke2's namespace:
kubectl -n spoke2 get manifestwork            # name has a hash suffix, e.g. spoke2-podinfo-pull-d0e5
kubectl -n spoke2 get manifestwork -o yaml | less   # the Application object is embedded inside spec.workload

# (c) spoke2's work-agent pulled it and created the Application LOCALLY:
KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n argocd get application
#   spoke2-podinfo-pull          ← Synced / Healthy (real status, computed on spoke2)

# (d) spoke2's OWN ArgoCD pulled git and applied podinfo:
KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n podinfo get deploy,pods -o wide   # replicas = 2
KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n podinfo exec deploy/podinfo -- wget -qO- localhost:9898/env | grep MESSAGE
# → "PULL: spoke2 pulled this itself via OCM ManifestWork"

# (e) status flowed BACK through the ManifestWork to the frozen hub copy:
kubectl -n argocd get application spoke2-podinfo-pull   # now reports Synced/Healthy — but only basics
```

💡 **Security moment:** `kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster`
still shows **only spoke1**. The hub has *no credentials for spoke2* — it never needs them.
That's the pull model's headline win.

✅ **DRILL 1b (pull) done when step (d) shows the PULL message with 2 replicas.**

---

## PHASE 4 (Sun PM) — The drills (this is the actual lesson)

### DRILL 2 — Hub outage: does GitOps survive? (the big one)

1. **[WINDOWS]** power OFF the `hub` VM (VMware → Power Off).
2. On **hub-less** observations, from spoke2 VM:

```bash
kubectl -n podinfo get deploy      # still running, obviously
kubectl -n argocd get application spoke2-podinfo-pull   # controller keeps reconciling
```

3. **[WINDOWS]** change git while the hub is dead — edit
   `apps/overlays/spoke2/patch.yaml` (message → `"PULL: still alive while hub is DOWN"`),
   commit + push.
4. Wait ~3 min on spoke2: `kubectl -n podinfo exec deploy/podinfo -- wget -qO- localhost:9898/env | grep MESSAGE`
   → **spoke2 delivered a git change with the entire control plane offline.**
5. Push side is dead by definition — no engine, no credentials. (Check on spoke2? The push
   Application lives on the hub — nothing to check; *that's the point.*)
6. **[WINDOWS]** power the hub back on. Wait ~2 min: `kubectl get managedclusters` on hub
   → spoke1/spoke2 `AVAILABLE=True` again; hub's copy of the pull app regains status.
   Also observe spoke2's `ManagedCluster` during the outage: hub marks it `Unknown` —
   klusterlet couldn't phone home. (Pull *delivery* survived; *observability* didn't.)

📝 Write down: what exactly broke, what didn't, and why.

### DRILL 3 — Spoke API unreachable: watch PUSH fail in isolation

```bash
# ON spoke1 VM — blackhole exactly the push path (hub → spoke1:6443):
sudo iptables -I INPUT -p tcp --dport 6443 -j DROP
```

On hub: `kubectl -n argocd get application podinfo-push-spoke1 -w` → within ~1 min goes
`ComparisonError` / `Unknown` (push engine can't dial spoke1:6443).

**Key observation:** `kubectl get managedcluster spoke1` stays `Available=True` — the OCM
klusterlet dials *out* to the hub and never touches port 6443 inbound. The control channel
survived; only the push data path broke. spoke2 noticed nothing.

Recovery:

```bash
sudo iptables -D INPUT -p tcp --dport 6443 -j DROP
```

Within ~1 min the push app returns to `Synced/Healthy`.

<details>
<summary><b>Nuclear option</b> (kills the whole cluster incl. the OCM agent — good too)</summary>

```bash
sudo systemctl stop docker      # every container in spoke1 dies
sudo systemctl start docker
docker ps -a                    # if the kind node container shows Exited:
docker start <kind-node-container>
```

Now BOTH the push app (engine can't connect) AND `managedcluster spoke1` (agent dead)
degrade — then both recover. Shows the shared-fate difference vs the iptables drill.
</details>

### DRILL 4 — Drift: who wins, git or kubectl?

```bash
# spoke1 (push):
KUBECONFIG=~/.kube/spoke1.kubeconfig kubectl -n podinfo scale deploy podinfo --replicas=5
KUBECONFIG=~/.kube/spoke1.kubeconfig kubectl -n podinfo get deploy podinfo    # back to 1 shortly

# spoke2 (pull):
KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n podinfo scale deploy podinfo --replicas=5
KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n podinfo get deploy podinfo    # back to 2
```

Both self-heal (identical `selfHeal: true` policy) — **but the correct end-state differs**
per overlay: git is the source of truth, cluster-specific truth comes from the overlay.
Now compare *reporting*: hub UI (push app) shows the full resource tree + live state;
hub's copy of the pull app shows only `Synced/Healthy` — status fidelity is the pull
model's known trade-off in this basic form (the advanced/Phase-2 model fixes it).

Extra: `kubectl -n podinfo delete deploy podinfo` on each → both recreate from scratch.

### DRILL 5 — One git commit, two delivery paths

**[WINDOWS]:**

```powershell
# e.g. change messages in both overlays + bump spoke2 to 3 replicas in its patch.yaml
git add -A; git commit -m "drill5: one commit, two pipelines"; git push
```

Then watch both, side by side (hub VM):

```bash
kubectl -n argocd get application -w
```

Notes to capture: push path = hub controller → cluster secret → spoke1 API → apply.
Pull path = hub controller → ManifestWork → spoke2 work-agent → local ArgoCD → git pull →
apply. More hops in pull, but none require hub→spoke connectivity.

### Summary table — fill it in yourself

| Observation | PUSH (spoke1) | PULL (spoke2) |
|---|---|---|
| Hub holds spoke credentials? | yes (cluster secret) | **no** |
| Survives hub outage (delivery) | | |
| Survives hub outage (status/observability) | | |
| Survives spoke API being unreachable | | |
| Status fidelity on hub UI | full | basic |
| Network hops for one sync | | |
| Extra components on spoke | none | ArgoCD (via add-on) |

---

## Cleanup / rebuild

```bash
# per VM — destroy the kind cluster and start over:
kind delete cluster --name hub        # or spoke1 / spoke2
bash infra/create-cluster.sh hub      # recreate (idempotent)

# on hub — if you re-join a cluster, drop its stale record first:
kubectl delete managedcluster spoke1 --ignore-not-found
# then redo PHASE 2 steps 2-4 (join + accept)
```

All `infra/*.sh` scripts are safe to re-run (they detect existing state). To wipe fully:
delete kind clusters on all 3 VMs + `kubectl delete namespace open-cluster-management argocd`
on hub, then restart from Phase 1 step 3.

---

## Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| Bootstrap prints `Synchronizing state of docker.service with SysV...` then goes silent | **Normal** — the docker package's systemd enable step; wait up to ~30 s. Truly frozen >2 min → `Ctrl+C` and re-run `sudo bash infra/bootstrap.sh` (idempotent, skips what's installed) |
| `curl: (7) Failed to connect to kind.sigs.k8s.io` (or any download dies mid-bootstrap) | transient/blocked mirror → re-run `sudo bash infra/bootstrap.sh`: downloads have retries and kind falls back to the GitHub release mirror; version-guarded installs skip what already succeeded |
| `x509: certificate is valid for 192.168.240.x, not 0.0.0.0` | your `~/.kube/config` kept the `0.0.0.0` entry that kind auto-writes at cluster creation → `git pull`, then re-run `bash infra/create-cluster.sh <role>` (repairs kubeconfig merge, does NOT recreate the cluster) |
| `x509: certificate is valid for ...` (other IP) when VM talks to another | kind cluster created before IP/certSAN matched → `kind delete cluster` + recreate (Phase 1 step 3) |
| `clusteradm join` parse error in setup-ocm-spoke.sh | join file garbled in transfer → `cat ~/ocm-join.txt`, if it's not a single `clusteradm join ...` line, re-relay it |
| ManagedCluster stuck `Pending` / `Joined=False` | you skipped `setup-ocm-accept.sh` → run it (hub VM) |
| Spoke pods `ImagePullBackOff` (`open-cluster-management-agent`) | VM has no internet / proxy issue → `docker pull` one of the failing images manually to see the error |
| Push app `ComparisonError: repository not found` | `GIT_REPO_URL` in config.sh wrong or repo not pushed → fix, re-run `setup-argocd-push.sh` |
| Push app `unknown revision` | repo exists but branch ≠ `main` → fix `GIT_REPO_BRANCH` |
| ApplicationSet generates **no** Applications | generator configmap missing → `kubectl get cm -n argocd ocm-placement-generator` (comes with the hub add-on — if absent, check `argocd-pull-integration` pod logs); decisions empty → check binding (`kubectl get mclsetbinding -n argocd`), labels (`kubectl get managedcluster --show-labels` → spoke2 must show `pull-target=true`), and `kubectl get placement -n argocd app-placement -o yaml` conditions |
| Pull app exists on hub but never reaches spoke2 | `kubectl get manifestwork -n spoke2` exists? → spoke work-agent logs: `KUBECONFIG=~/.kube/spoke2.kubeconfig kubectl -n open-cluster-management-agent get pods` then `logs -f <work-agent-pod>` |
| Spoke2's local ArgoCD missing | add-on still progressing → `kubectl -n spoke2 get managedclusteraddon argocd` (hub) — wait for `AVAILABLE=True` |
| ArgoCD build fails `unknown flag: --enable-helm` context | `kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.kustomize.buildOptions}'` should be `--enable-helm` → re-run `setup-argocd-push.sh` |
| `Too long` annotation error installing ArgoCD | must use server-side apply (scripts already do) |
| Everything OOMs / pods Pending | VMs below 4 GB RAM, or hub overloaded → check `kubectl top nodes` (needs metrics-server) / `free -h`; raise VM memory in VMware |
| `docker ps` permission denied after bootstrap | `newgrp docker` or log out/in |

---

## Later — Phase 2 roadmap (optional, next weekend)

The lab uses the OCM **basic** pull model (Application wrapped in ManifestWork). The
flagship **advanced** model uses [`argocd-pull-integration`](https://github.com/open-cluster-management-io/argocd-pull-integration)
+ **argocd-agent**: a `GitOpsCluster` CR, gRPC principal↔agent, full status mirrored back
to the hub UI, `ApplicationSet` routing by `destination.name`. Prerequisites: more RAM on
the hub (~+500 MB) and a LoadBalancer (MetalLB) on the kind hub. Re-run drill 2 afterwards
to compare — the advanced agent keeps even *sync operations* available from the hub UI
during spoke-side operation.

Reference (advanced vs basic): see the README of
[`open-cluster-management-io/argocd-pull-integration`](https://github.com/open-cluster-management-io/argocd-pull-integration).

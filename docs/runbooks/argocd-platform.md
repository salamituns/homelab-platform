# Runbook: cluster add-ons via Argo CD (app of apps)

Why: [ADR 0008](../adr/0008-argocd-app-of-apps-platform.md). Layout: `k8s/platform/`
(`bootstrap/root.yaml` -> `apps/*.yaml` -> one directory per add-on).

## Bootstrap (once per cluster)

1. Argo CD repo credential for every `tunsgit` repo (reuses the `read:repository` token; created outside git):

   ```bash
   kubectl -n argocd get secret gitea-belleshop-readonly -o json | python3 -c '
   import json,sys; d=json.load(sys.stdin)["data"]
   print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"gitea-tunsgit-readonly-creds","namespace":"argocd",
     "labels":{"argocd.argoproj.io/secret-type":"repo-creds"}},
     "data":{"username":d["username"],"password":d["password"]},
     "stringData":{"url":"https://gitea.home.arpa/tunsgit/","type":"git"}}))' | kubectl apply -f -
   ```

2. Root app: `kubectl apply -f k8s/platform/bootstrap/root.yaml`. It creates the `platform` AppProject
   and the child Applications. Children start without automated sync.

3. For each child: check it shows **Synced** (no diff) or only expected differences, then sync it once
   (UI "Sync", or `kubectl -n argocd patch application <name> --type merge -p '{"operation":{"sync":{}}}'`).

4. Turn on automated sync (`syncPolicy.automated: {prune: true, selfHeal: true}`) for the children in git.

## Day to day

- Change an add-on: edit its directory (or `monitoring/values.yaml`), commit, push. Argo CD applies it within ~3 min.
- Upgrade a vendored add-on: replace the file under `vendor/`, update `VENDOR.md`, check
  `kubectl kustomize k8s/platform/<addon> | kubectl diff -f -` before pushing.
- A manual `kubectl edit` on a managed object is reverted by selfHeal. That is the point.

## Proof drill: delete `monitoring`, watch it come back

What comes back: every object in git (chart, values, Grafana ingress, BelleShop's ServiceMonitor and dashboard).
What does NOT: `grafana-admin` (not in git) and the Prometheus/Alertmanager PVC data (7 days of metrics).

```bash
# Keep the Grafana admin Secret (it is not in git); 0600, gitignored
umask 077; kubectl -n monitoring get secret grafana-admin -o json \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); m=s["metadata"]; s["metadata"]={"name":m["name"],"namespace":m["namespace"]}; print(json.dumps(s))' \
  > private/grafana-admin.secret.json
date; kubectl delete namespace monitoring --wait=false
watch -n5 'kubectl -n argocd get applications; kubectl -n monitoring get pods'
# Argo CD recreates the namespace and objects. Grafana waits for its Secret:
kubectl apply -f private/grafana-admin.secret.json && rm -P private/grafana-admin.secret.json
```

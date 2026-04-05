# 10 — Troubleshooting & Debugging

Systematic debugging is the most valuable SRE skill. This section builds a mental model for diagnosing any Kubernetes problem.

---

## Troubleshooting Methodology

```
1. OBSERVE    — What is the symptom? Gather facts without assuming.
2. HYPOTHESIZE — What could cause this? List possible causes.
3. TEST        — Disprove hypotheses one by one (most likely first).
4. FIX         — Apply the minimal change that resolves the root cause.
5. VERIFY      — Confirm the fix works and didn't introduce new issues.
6. DOCUMENT    — Write a postmortem / runbook entry.
```

---

## Common Pod Failure States

### CrashLoopBackOff

The container is crashing repeatedly. Kubernetes backs off exponentially before restarting.

```bash
# Step 1: Get exit code and reason
kubectl describe pod <name>
# Look for: "Last State: Terminated" and "Reason: Error/OOMKilled/etc."

# Step 2: Read logs from the previous (crashed) container instance
kubectl logs <pod> --previous
kubectl logs <pod> -c <container> --previous

# Step 3: Check exit code
# Exit 0:   Clean exit — check if app exits early (config issue)
# Exit 1:   Application error — read logs
# Exit 137: OOMKilled (128 + 9 SIGKILL)
# Exit 139: Segfault (128 + 11 SIGSEGV)
# Exit 143: SIGTERM not handled (128 + 15)

# Common causes:
# - App can't connect to database/dependency
# - Missing env var or config file
# - App exits immediately (bad entrypoint)
# - OOMKilled (increase memory limit)
```

### ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <name>
# Look for: "Failed to pull image" error

# Common causes and fixes:
# 1. Image doesn't exist or wrong tag
#    → verify: docker pull <image>:<tag>
# 2. Wrong registry credentials
#    → check imagePullSecrets on the pod and the Secret content
# 3. Rate limiting (Docker Hub)
#    → use authenticated pull or mirror registry
# 4. Private registry, no imagePullSecrets
#    → add imagePullSecrets to pod spec or ServiceAccount

# Test registry credentials manually
kubectl create secret docker-registry test-pull \
  --docker-server=registry.example.com \
  --docker-username=user \
  --docker-password=pass
```

### Pending Pod

```bash
kubectl describe pod <name>
# Events section shows the reason

# Common causes:
# "Insufficient cpu" / "Insufficient memory"
kubectl top nodes
kubectl describe node <node>    # check Allocated resources

# "0 nodes available: X node(s) had taint..."
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'

# "pod has unbound immediate PersistentVolumeClaims"
kubectl get pvc
kubectl describe pvc <name>

# "pod topology spread constraints not satisfiable"
# Check zones: kubectl get nodes -L topology.kubernetes.io/zone
```

### OOMKilled

```bash
kubectl describe pod <name>
# Last State: Terminated
#   Reason: OOMKilled
#   Exit Code: 137

# Check memory usage vs limit
kubectl top pod <name>
kubectl top pod <name> --containers

# Check node OOM events
kubectl get events --field-selector reason=OOMKilling

# Fix: increase memory limit or reduce app memory usage
kubectl set resources deployment my-app --limits=memory=512Mi
```

### Evicted

```bash
kubectl get pods | grep Evicted
kubectl describe pod <evicted-pod>
# Reason: The node was low on resource: memory. ...

# Check node conditions
kubectl describe node <node> | grep -A 5 Conditions

# Clean up evicted pods
kubectl get pods -A --field-selector=status.phase=Failed | \
  grep Evicted | \
  awk '{print $1, $2}' | \
  xargs -n 2 sh -c 'kubectl delete pod $2 -n $1'
```

---

## kubectl Debugging Commands

### Logs

```bash
kubectl logs <pod>                          # current container
kubectl logs <pod> --previous              # previous instance
kubectl logs <pod> -c <container>          # specific container
kubectl logs <pod> --all-containers        # all containers
kubectl logs <pod> -f                      # follow
kubectl logs <pod> --tail=100              # last 100 lines
kubectl logs <pod> --since=1h             # last hour
kubectl logs <pod> --since-time="2024-01-01T12:00:00Z"

# Multi-pod log streaming (install stern)
stern my-app                               # all pods matching "my-app"
stern -l app=frontend -n production        # by label
stern . --namespace kube-system            # all pods in namespace
```

### Events

```bash
kubectl get events --sort-by='.lastTimestamp'
kubectl get events -n kube-system
kubectl get events --field-selector involvedObject.name=<pod-name>
kubectl get events --field-selector reason=BackOff
kubectl get events -w                      # watch live events
```

### Exec into a Pod

```bash
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -c <container> -- bash
kubectl exec <pod> -- env                  # list env vars
kubectl exec <pod> -- cat /etc/config/app.properties
```

### Port Forward

```bash
kubectl port-forward pod/<name> 8080:8080
kubectl port-forward svc/<name> 8080:80
kubectl port-forward deployment/<name> 8080:8080
```

### Debug (ephemeral containers)

```bash
# Add a debug sidecar to a running pod (non-destructive)
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>

# Copy a pod and add a debug container
kubectl debug <pod> -it --image=busybox --copy-to=debug-pod

# Debug a node
kubectl debug node/<node-name> -it --image=ubuntu
```

---

## Network Debugging

```bash
# Deploy a debug pod
kubectl run netdebug --image=nicolaka/netshoot -it --rm -- bash

# Inside the debug pod:
# Test DNS
dig my-service.default.svc.cluster.local
nslookup my-service
nslookup google.com

# Test connectivity
curl -v http://my-service:80/healthz
nc -zv my-service 80
telnet my-service 80

# Trace the route
traceroute <destination-ip>
mtr <destination-ip>

# Check NetworkPolicy blocking
# (Cilium)
cilium policy trace --src-pod default/frontend --dst-pod default/backend --dport 8080

# Check iptables rules for a service
kubectl get svc my-svc -o jsonpath='{.spec.clusterIP}'
iptables -t nat -L | grep <cluster-ip>
```

---

## Node-Level Debugging

```bash
# SSH to a node (EKS example)
aws ssm start-session --target <instance-id>

# Or via kubectl debug
kubectl debug node/<name> -it --image=ubuntu -- chroot /host

# On the node:
# Check kubelet
systemctl status kubelet
journalctl -u kubelet -f --since "10 minutes ago"

# Check container runtime
systemctl status containerd
crictl ps                          # running containers
crictl logs <container-id>         # container logs
crictl inspect <container-id>      # container details

# Check disk pressure
df -h
du -sh /var/lib/containerd        # container storage
du -sh /var/log/pods              # pod logs

# Check memory
free -m
cat /proc/meminfo
dmesg | grep -i "oom\|kill"

# Check system logs
journalctl -k --since "30 minutes ago"  # kernel messages
dmesg -T | tail -50
```

---

## API Server Debugging

```bash
# Slow kubectl responses? Check API server latency
kubectl get --raw /metrics | grep apiserver_request_duration

# Check audit logs (if enabled)
tail -f /var/log/kubernetes/audit.log | python3 -m json.tool | grep -v "get\|list\|watch"

# etcd latency (cause of slow API server)
ETCDCTL_API=3 etcdctl endpoint status --cluster --write-out=table

# API server logs
kubectl logs -n kube-system -l component=kube-apiserver | tail -100
```

---

## RBAC Debugging

```bash
# Check permissions for current user
kubectl auth can-i create deployments
kubectl auth can-i '*' '*'

# Check permissions for a ServiceAccount
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:my-sa

# Check permissions for a user
kubectl auth can-i delete pods --as=jane@example.com -n production

# Describe what access a role grants
kubectl describe clusterrole view
kubectl describe rolebinding my-binding -n production

# Common RBAC errors:
# "forbidden: User "system:serviceaccount:default:my-sa" cannot list resource "secrets""
# → create a Role/ClusterRole and bind it to the ServiceAccount

# Install kubectl-who-can
kubectl who-can list pods
kubectl who-can delete secrets -n production
```

---

## Storage Debugging

```bash
# PVC stuck in Pending
kubectl describe pvc <name>
# "no persistent volumes available" → no PV matches, or no StorageClass
# "waiting for first consumer" → WaitForFirstConsumer mode, normal until pod schedules

# Pod can't mount volume
kubectl describe pod <name>
# "AttachVolume.Attach failed" → CSI driver issue or cross-AZ mount
# "MountVolume.SetUp failed" → filesystem error

# Check CSI driver pods
kubectl get pods -n kube-system | grep csi
kubectl logs -n kube-system <csi-pod>

# Inspect PV/PVC binding
kubectl get pv,pvc -A
```

---

## Common Debugging Tools

```bash
# Install useful tools
brew install stern         # multi-pod log streaming
brew install kubectx       # context/namespace switching
pip install k9s            # terminal UI
go install sigs.k8s.io/kubectl-neat@latest  # clean kubectl output

# One-liner: debug pod with all tools
kubectl run debug \
  --image=nicolaka/netshoot \
  --rm -it \
  --restart=Never \
  -- bash

# Check cluster health quickly (Popeye)
kubectl krew install popeye
kubectl popeye
```

---

## Systematic Debugging Flowchart

```
Pod not working?
│
├── kubectl get pod → status?
│   ├── Pending → describe pod → Events
│   │   ├── Insufficient resources → scale cluster / reduce requests
│   │   ├── Taint/affinity → fix tolerations/nodeSelector
│   │   └── PVC unbound → fix storage
│   │
│   ├── CrashLoopBackOff → kubectl logs --previous
│   │   ├── Connection refused → check dependency health + readiness
│   │   ├── OOMKilled → increase memory limit
│   │   └── App error → fix application code
│   │
│   ├── Running but not accessible?
│   │   ├── kubectl get endpoints → empty? → fix Service selector
│   │   ├── readinessProbe failing → check probe endpoint
│   │   └── NetworkPolicy blocking → check network policy
│   │
│   └── Running but slow?
│       ├── kubectl top pod → CPU throttled? → remove CPU limit
│       └── Check external dependencies (DB, APIs)
```

---

## SRE Lens

- **`kubectl describe` first** — the Events section at the bottom is almost always where the answer is.
- **`--previous` logs are gold** — the only way to see why a crashed container died.
- **Test from inside the cluster** — "can't reach the service" often means you're testing from outside and forgetting VPN/firewall. Test with `kubectl exec` first.
- **Measure before you fix** — `kubectl top` and Prometheus data tell you the actual state; don't guess at resource limits.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/) |
| Official Docs | [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/) |
| Official Docs | [Troubleshooting Clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/) |
| Tool | [netshoot](https://github.com/nicolaka/netshoot) |
| Tool | [stern](https://github.com/stern/stern) |
| Tool | [k9s](https://k9scli.io/) |
| Tool | [Popeye](https://popeyecli.io/) |
| Blog | [K8s Troubleshooting Flowchart (Learnk8s)](https://learnk8s.io/troubleshooting-deployments) |

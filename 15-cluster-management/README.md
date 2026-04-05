# 15 — Cluster Management

Running one cluster is easy. Running a fleet of clusters safely — with upgrades, multi-tenancy, and multi-cloud — is the hard part.

---

## Managed Kubernetes

### EKS (AWS)

```bash
# Create EKS cluster with eksctl
eksctl create cluster \
  --name production \
  --region us-east-1 \
  --version 1.29 \
  --nodegroup-name workers \
  --node-type m5.xlarge \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 10 \
  --managed \
  --with-oidc   # enable OIDC for IRSA

# Update kubeconfig
aws eks update-kubeconfig --name production --region us-east-1

# Add a new managed node group
eksctl create nodegroup \
  --cluster production \
  --name gpu-nodes \
  --node-type p3.2xlarge \
  --nodes 0 \
  --nodes-min 0 \
  --nodes-max 5 \
  --node-labels role=gpu \
  --taints dedicated=gpu:NoSchedule
```

### IRSA — IAM Roles for Service Accounts

```bash
# Create IAM role with trust policy for a ServiceAccount
eksctl create iamserviceaccount \
  --cluster production \
  --namespace my-app \
  --name my-app-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
```

```yaml
# Pod automatically gets AWS credentials via projected token
spec:
  serviceAccountName: my-app-sa
  # No secret needed — EKS injects AWS_WEB_IDENTITY_TOKEN_FILE env var
```

### GKE (GCP)

```bash
# Create GKE Autopilot cluster (fully managed nodes)
gcloud container clusters create-auto production \
  --region us-central1

# Standard cluster
gcloud container clusters create production \
  --machine-type e2-standard-4 \
  --num-nodes 3 \
  --zone us-central1-a \
  --enable-autoscaling \
  --min-nodes 1 \
  --max-nodes 10 \
  --workload-pool=PROJECT_ID.svc.id.goog  # Workload Identity

# Get credentials
gcloud container clusters get-credentials production --region us-central1
```

### AKS (Azure)

```bash
# Create AKS cluster
az aks create \
  --resource-group myRG \
  --name production \
  --node-count 3 \
  --node-vm-size Standard_D4s_v3 \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

# Get credentials
az aks get-credentials --resource-group myRG --name production
```

---

## Cluster Provisioning with Cluster API (CAPI)

Cluster API is a Kubernetes-native way to provision and manage clusters. The management cluster runs the CAPI controllers; workload clusters are the output.

```bash
# Install clusterctl CLI
brew install clusterctl

# Initialize management cluster (AWS provider)
export AWS_REGION=us-east-1
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
clusterawsadm bootstrap iam create-cloudformation-stack

clusterctl init --infrastructure aws

# Generate and apply a cluster manifest
clusterctl generate cluster prod-cluster \
  --infrastructure aws \
  --kubernetes-version v1.29.0 \
  --control-plane-machine-count 3 \
  --worker-machine-count 3 > prod-cluster.yaml

kubectl apply -f prod-cluster.yaml

# Watch cluster provisioning
kubectl get clusters -w
kubectl get machines -w
```

### ClusterClass (CAPI 1.2+)

```yaml
# Define a reusable cluster topology
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterClass
metadata:
  name: production-class
spec:
  controlPlane:
    ref:
      apiVersion: controlplane.cluster.x-k8s.io/v1beta1
      kind: KubeadmControlPlaneTemplate
      name: production-cp-template
  workers:
    machineDeployments:
    - class: default-worker
      template:
        bootstrap:
          ref:
            kind: KubeadmConfigTemplate
            name: worker-template
        infrastructure:
          ref:
            kind: AWSMachineTemplate
            name: worker-machine-template
---
# Instantiate a cluster from the class
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: my-cluster
spec:
  topology:
    class: production-class
    version: v1.29.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
      - class: default-worker
        name: workers
        replicas: 5
```

---

## Cluster Upgrades

### EKS Upgrade

```bash
# 1. Check the current version
kubectl version --short
kubectl get nodes

# 2. Upgrade control plane first
aws eks update-cluster-version \
  --name production \
  --kubernetes-version 1.29

# Wait for control plane upgrade to complete
aws eks describe-cluster --name production \
  --query "cluster.status"

# 3. Upgrade node groups (one at a time)
aws eks update-nodegroup-version \
  --cluster-name production \
  --nodegroup-name workers \
  --kubernetes-version 1.29

# With eksctl (handles drain/cordon automatically)
eksctl upgrade nodegroup \
  --cluster production \
  --name workers \
  --kubernetes-version 1.29
```

### Self-Managed Upgrade (kubeadm)

```bash
# 1. Upgrade control plane node
sudo apt-get update && apt-get install -y kubeadm=1.29.0-00

# Verify upgrade plan
sudo kubeadm upgrade plan

# Apply upgrade
sudo kubeadm upgrade apply v1.29.0

# Upgrade kubelet and kubectl on control plane
sudo apt-get install -y kubelet=1.29.0-00 kubectl=1.29.0-00
sudo systemctl daemon-reload && systemctl restart kubelet

# 2. Upgrade worker nodes (one at a time)
kubectl cordon worker-1
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data

# On the worker node:
sudo apt-get install -y kubeadm=1.29.0-00
sudo kubeadm upgrade node
sudo apt-get install -y kubelet=1.29.0-00
sudo systemctl daemon-reload && systemctl restart kubelet

# On control plane: uncordon the worker
kubectl uncordon worker-1
```

---

## etcd Operations

```bash
# etcd health check
ETCDCTL_API=3 etcdctl endpoint health --cluster \
  --endpoints=https://etcd1:2379,https://etcd2:2379,https://etcd3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Backup
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Verify backup
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-*.db --write-out=table

# Restore (stop all API servers first)
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-latest.db \
  --data-dir=/var/lib/etcd-restored \
  --name etcd1 \
  --initial-cluster etcd1=https://192.168.1.10:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls https://192.168.1.10:2380

# Compaction (free old revisions)
rev=$(etcdctl endpoint status --write-out json | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d[0]['Status']['header']['revision'])
")
ETCDCTL_API=3 etcdctl compact $rev
ETCDCTL_API=3 etcdctl defrag

# Monitor etcd disk latency (critical metric)
# etcd_disk_wal_fsync_duration_seconds_bucket
# Alert: p99 > 100ms indicates disk pressure
```

---

## Multi-Cluster Networking

### Submariner (multi-cluster networking)

```bash
subctl deploy-broker --kubeconfig admin.kubeconfig
subctl join --kubeconfig cluster1.kubeconfig broker-info.subm --clusterid cluster1
subctl join --kubeconfig cluster2.kubeconfig broker-info.subm --clusterid cluster2

# After joining: pods in cluster1 can reach services in cluster2 directly
```

### Cluster API Add-on Orchestration

```yaml
# Install add-ons to workload clusters automatically
apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: ClusterResourceSet
metadata:
  name: install-cni
spec:
  clusterSelector:
    matchLabels:
      cni: cilium
  resources:
  - name: cilium-configmap
    kind: ConfigMap
```

---

## Multi-Tenancy Models

### Namespace-based (soft multi-tenancy)

```bash
# Each team gets a namespace with ResourceQuota + RBAC
kubectl create namespace team-a
kubectl apply -f team-a-resourcequota.yaml
kubectl apply -f team-a-limitrange.yaml
kubectl apply -f team-a-rolebinding.yaml
```

### vCluster (virtual clusters — stronger isolation)

```bash
helm install my-vcluster vcluster \
  --repo https://charts.loft.sh \
  --namespace team-a --create-namespace \
  --set vcluster.image=rancher/k3s:v1.28.0-k3s1

# Connect to the virtual cluster
vcluster connect my-vcluster --namespace team-a
```

---

## Node Management

```bash
# Cordoned node list
kubectl get nodes | grep SchedulingDisabled

# Node conditions
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason'

# Force drain a stuck node (use carefully)
kubectl drain <node> --force --ignore-daemonsets --delete-emptydir-data --grace-period=0

# Delete a node (node object only — doesn't terminate the VM)
kubectl delete node <node>

# Spot/preemptible: handle node termination
# Deploy AWS Node Termination Handler
helm install aws-node-termination-handler \
  eks/aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true
```

---

## Cluster Health Dashboard Metrics

```promql
# Nodes not ready
count(kube_node_status_condition{condition="Ready",status="true"} == 0)

# Pods not running
count(kube_pod_status_phase{phase!~"Running|Succeeded"}) by (phase)

# etcd leader changes (should be 0 in stable clusters)
increase(etcd_server_leader_changes_seen_total[1h])

# API server request error rate
rate(apiserver_request_total{code=~"5.."}[5m]) /
rate(apiserver_request_total[5m])

# Pending pods for >5 minutes
kube_pod_status_phase{phase="Pending"} > 0
# Combine with: kube_pod_created{} < (time() - 300)
```

---

## SRE Lens

- **Upgrade control plane first** — never upgrade workers before the control plane. The API server must support the kubelet version.
- **One minor version at a time** — Kubernetes only supports N-2 skew between apiserver and kubelet. Skip a version and you may break the cluster.
- **etcd backup before every upgrade** — treat it like a pre-surgery checklist.
- **Use PodDisruptionBudgets** — cluster upgrades drain nodes. Without PDBs, you risk taking down entire services.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Cluster API](https://cluster-api.sigs.k8s.io/) |
| Official Docs | [kubeadm upgrade](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/) |
| Official Docs | [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/) |
| Tool | [eksctl](https://eksctl.io/) |
| Tool | [kOps](https://kops.sigs.k8s.io/) |
| Tool | [vCluster](https://www.vcluster.com/docs/) |
| Blog | [Kubernetes Upgrade Strategy](https://learnk8s.io/kubernetes-upgrade) |

# 07 — Storage & StatefulSets

Kubernetes storage abstracts the underlying infrastructure so workloads are portable. StatefulSets give stateful apps the stable identity they need.

---

## Volume Types

### emptyDir

Ephemeral volume that lives as long as the Pod. Shared between containers in the same Pod.

```yaml
volumes:
- name: shared-data
  emptyDir: {}
  # emptyDir:
  #   medium: Memory  # RAM-backed tmpfs
  #   sizeLimit: 500Mi
```

**Use for:** cache, inter-container data sharing, scratch space.

### hostPath

Mounts a path from the host node into the Pod.

```yaml
volumes:
- name: docker-sock
  hostPath:
    path: /var/run/docker.sock
    type: Socket   # File | Directory | Socket | CharDevice | BlockDevice
```

**Avoid in production** — ties the Pod to a specific node, creates security risks.

### configMap and secret

```yaml
volumes:
- name: app-config
  configMap:
    name: my-config
    items:
    - key: app.properties
      path: config.properties
      mode: 0444

- name: tls-certs
  secret:
    secretName: my-tls-secret
    defaultMode: 0400
```

### projected

Combine multiple sources into a single volume mount.

```yaml
volumes:
- name: combined
  projected:
    sources:
    - configMap:
        name: my-config
    - secret:
        name: my-secret
    - serviceAccountToken:
        path: token
        expirationSeconds: 3600
        audience: vault
```

---

## Persistent Volumes

### The Three-Layer Abstraction

```
StorageClass       ← describes how to provision storage (cloud, speed, reclaim policy)
     ↓
PersistentVolume   ← represents a piece of actual storage
     ↑
PersistentVolumeClaim ← request for storage (what the Pod uses)
```

### StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Delete    # Delete | Retain
volumeBindingMode: WaitForFirstConsumer  # or Immediate
allowVolumeExpansion: true
```

### PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 20Gi
```

### Access Modes

| Mode | Abbreviation | Meaning |
|------|-------------|---------|
| `ReadWriteOnce` | RWO | One node can read/write |
| `ReadOnlyMany` | ROX | Many nodes can read |
| `ReadWriteMany` | RWX | Many nodes can read/write |
| `ReadWriteOncePod` | RWOP | One Pod can read/write (1.22+) |

### Mount a PVC in a Pod

```yaml
spec:
  containers:
  - name: app
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

---

## Dynamic Provisioning

With dynamic provisioning, creating a PVC automatically creates a PV.

```bash
# Watch provisioning
kubectl get pvc -w
# my-data   Pending → Bound (after pod using it is created, with WaitForFirstConsumer)

kubectl get pv
# Shows the auto-created PV

kubectl describe pvc my-data   # shows which PV it's bound to
```

### WaitForFirstConsumer

Delays volume creation until a Pod using the PVC is scheduled. This ensures the volume is created in the same AZ as the Pod.

```yaml
storageClassName: gp3
volumeBindingMode: WaitForFirstConsumer   # critical for multi-AZ clusters
```

---

## Reclaim Policies

| Policy | What happens when PVC is deleted |
|--------|----------------------------------|
| `Delete` | PV and underlying storage are deleted |
| `Retain` | PV remains; requires manual cleanup |
| `Recycle` | (deprecated) Basic scrub |

```bash
# Retain a PV for manual recovery
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

---

## Volume Expansion

```bash
# Expand a PVC (StorageClass must have allowVolumeExpansion: true)
kubectl patch pvc my-data -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# Watch the expansion
kubectl get pvc my-data -w
kubectl describe pvc my-data   # shows resize conditions
```

For file systems (ext4, xfs), the filesystem is resized automatically when the Pod restarts (or immediately if the volume supports it).

---

## Volume Snapshots

```yaml
# VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-aws-vsc
driver: ebs.csi.aws.com
deletionPolicy: Delete
---
# Take a snapshot
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-data-snap-20240101
spec:
  volumeSnapshotClassName: csi-aws-vsc
  source:
    persistentVolumeClaimName: my-data
---
# Restore from snapshot
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data-restored
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 20Gi
  dataSource:
    name: my-data-snap-20240101
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
```

```bash
kubectl get volumesnapshot
kubectl get volumesnapshotcontent
```

---

## CSI Drivers

The Container Storage Interface (CSI) standardizes how storage is attached.

```bash
# Common CSI drivers
# AWS EBS:    ebs.csi.aws.com
# AWS EFS:    efs.csi.aws.com
# GCE PD:     pd.csi.storage.gke.io
# Azure Disk: disk.csi.azure.com
# Longhorn:   driver.longhorn.io
# Rook/Ceph:  rook-ceph.rbd.csi.ceph.com

# List installed CSI drivers
kubectl get csidrivers
kubectl get csinodes
```

---

## StatefulSets

StatefulSets are for apps that need:
- **Stable network identity**: `pod-0`, `pod-1`, `pod-2` (not random hashes)
- **Stable storage**: each pod gets its own PVC that survives rescheduling
- **Ordered operations**: pods are created, updated, and deleted in order

### Full StatefulSet Example

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
  - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres-headless   # required — links to headless service
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0   # set to 2 to update only pod-2 first (canary)
  podManagementPolicy: OrderedReady  # or Parallel
  template:
    metadata:
      labels:
        app: postgres
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: mydb
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: user
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: password
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        readinessProbe:
          exec:
            command: [pg_isready, -U, postgres]
          initialDelaySeconds: 10
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 50Gi
```

### StatefulSet DNS

```
pod-0.postgres-headless.default.svc.cluster.local
pod-1.postgres-headless.default.svc.cluster.local
pod-2.postgres-headless.default.svc.cluster.local
```

### StatefulSet Operations

```bash
# Scale up (adds pod-3, then pod-4, etc.)
kubectl scale statefulset postgres --replicas=5

# Scale down (removes highest ordinal first: pod-4, pod-3, ...)
kubectl scale statefulset postgres --replicas=3

# Rolling update (one pod at a time, highest ordinal first)
kubectl set image statefulset/postgres postgres=postgres:16.1

# Canary: update only pod-2 first
kubectl patch statefulset postgres -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
# Then verify pod-2, then reduce partition to 0

# Force pod recreation (useful for config updates)
kubectl rollout restart statefulset postgres

# Delete pod only (PVC survives — pod will be recreated with same storage)
kubectl delete pod postgres-1
```

---

## Storage Debugging

```bash
# PVC stuck in Pending
kubectl describe pvc my-data
# Look for: "no persistent volumes available" or provisioner errors

# PVC in WaitForFirstConsumer
kubectl describe pvc my-data
# Normal — will bind when a Pod using it is scheduled

# PV not available (mismatched access mode or size)
kubectl get pv
kubectl describe pv <pv-name>

# CSI driver issues
kubectl logs -n kube-system -l app=ebs-csi-controller
kubectl get csinodes

# Pod can't mount volume
kubectl describe pod <pod-name>
# Look for: "AttachVolume.Attach failed" or "MountVolume.MountDevice failed"
```

---

## SRE Lens

- **Always use `WaitForFirstConsumer`** for multi-AZ clusters. `Immediate` creates volumes in a random AZ, which may not match where the Pod schedules.
- **StatefulSet PVCs are NOT deleted when StatefulSet is deleted** — you must manually delete PVCs. This prevents accidental data loss.
- **Backup before resizing** — volume expansion is irreversible on most CSI drivers.
- **Monitor PVC usage** — `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` alerts on near-full volumes before they cause write errors.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Storage](https://kubernetes.io/docs/concepts/storage/) |
| Official Docs | [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) |
| Official Docs | [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/) |
| Official Docs | [CSI](https://kubernetes-csi.github.io/docs/) |
| Tool | [Rook Ceph](https://rook.io/docs/) |
| Tool | [Longhorn](https://longhorn.io/docs/) |
| Tool | [OpenEBS](https://openebs.io/docs) |
| Blog | [StatefulSet Patterns (Learnk8s)](https://learnk8s.io/stateful-kubernetes) |

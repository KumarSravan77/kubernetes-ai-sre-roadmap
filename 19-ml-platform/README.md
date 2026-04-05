# 19 — ML Platform on Kubernetes

Running ML workloads on Kubernetes requires GPU-aware scheduling, distributed training frameworks, and scalable model serving.

---

## GPU Support

### NVIDIA GPU Operator

```bash
# Install NVIDIA GPU Operator (handles driver, device plugin, runtime)
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set mig.strategy=single

# Verify GPU nodes
kubectl get nodes -L nvidia.com/gpu.count,nvidia.com/gpu.product
kubectl describe node gpu-node-1 | grep -A 5 "nvidia.com"
```

```yaml
# Pod requesting a GPU
spec:
  containers:
  - name: training
    image: nvcr.io/nvidia/pytorch:23.10-py3
    resources:
      requests:
        nvidia.com/gpu: 1      # request 1 GPU
      limits:
        nvidia.com/gpu: 1      # must equal request for GPU
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

### MIG (Multi-Instance GPU) Partitioning

```bash
# Enable MIG on a node (A100, H100 only)
kubectl label node gpu-node-1 nvidia.com/mig.config=all-1g.5gb

# Available MIG profiles for A100:
# all-1g.5gb  → 7 instances of 1 GPU with 5GB memory each
# all-2g.10gb → 3 instances of 2 GPU with 10GB memory
# all-7g.40gb → 1 instance (full GPU)
```

```yaml
# Pod using a MIG slice
spec:
  containers:
  - name: inference
    resources:
      limits:
        nvidia.com/mig-1g.5gb: 1
```

---

## Kubeflow Pipelines

Kubeflow Pipelines orchestrates ML workflows as DAGs of containerized steps.

```bash
# Install Kubeflow
export PIPELINE_VERSION=2.0.5
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$PIPELINE_VERSION"
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=$PIPELINE_VERSION"

# Access UI
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80
```

### Define a Pipeline (Python SDK)

```python
import kfp
from kfp import dsl
from kfp.dsl import component, pipeline, Input, Output, Dataset, Model

@component(
    base_image="python:3.11-slim",
    packages_to_install=["pandas", "scikit-learn"],
)
def preprocess_data(
    raw_data: Input[Dataset],
    processed_data: Output[Dataset],
    test_size: float = 0.2,
):
    import pandas as pd
    from sklearn.model_selection import train_test_split

    df = pd.read_csv(raw_data.path)
    train, test = train_test_split(df, test_size=test_size)
    train.to_csv(processed_data.path, index=False)


@component(
    base_image="python:3.11-slim",
    packages_to_install=["pandas", "scikit-learn", "joblib"],
)
def train_model(
    training_data: Input[Dataset],
    model: Output[Model],
    n_estimators: int = 100,
):
    import pandas as pd
    from sklearn.ensemble import RandomForestClassifier
    import joblib

    df = pd.read_csv(training_data.path)
    X, y = df.drop("label", axis=1), df["label"]
    clf = RandomForestClassifier(n_estimators=n_estimators)
    clf.fit(X, y)
    joblib.dump(clf, model.path)


@pipeline(name="ml-training-pipeline")
def training_pipeline(
    data_path: str,
    test_size: float = 0.2,
    n_estimators: int = 100,
):
    preprocess_task = preprocess_data(
        raw_data=dsl.importer(artifact_uri=data_path, artifact_class=Dataset).output,
        test_size=test_size,
    )
    train_task = train_model(
        training_data=preprocess_task.outputs["processed_data"],
        n_estimators=n_estimators,
    )


# Submit pipeline
client = kfp.Client(host="http://localhost:8080")
run = client.create_run_from_pipeline_func(
    training_pipeline,
    arguments={"data_path": "gs://my-bucket/data.csv"},
)
```

---

## Training Operators

### PyTorchJob (distributed training)

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: pytorch-dist-training
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: myorg/pytorch-training:latest
            command:
            - python
            - -m
            - torch.distributed.run
            - --nproc_per_node=1
            - train.py
            - --epochs=100
            - --batch-size=256
            resources:
              limits:
                nvidia.com/gpu: 1
    Worker:
      replicas: 4
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: myorg/pytorch-training:latest
            command:
            - python
            - -m
            - torch.distributed.run
            - --nproc_per_node=1
            - train.py
            - --epochs=100
            resources:
              limits:
                nvidia.com/gpu: 1
```

```bash
kubectl apply -f pytorch-job.yaml
kubectl get pytorchjobs
kubectl logs pytorch-dist-training-master-0 -f
```

---

## KServe — Model Serving

KServe provides serverless model serving with autoscaling (including scale-to-zero via Knative).

```bash
# Install KServe
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.12.0/kserve.yaml
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.12.0/kserve-cluster-resources.yaml
```

```yaml
# Serve a scikit-learn model from S3
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  namespace: production
spec:
  predictor:
    sklearn:
      storageUri: s3://my-models/iris-model
      resources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          cpu: 1
          memory: 1Gi
---
# Serve a PyTorch model with GPU
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llm-service
spec:
  predictor:
    pytorch:
      storageUri: s3://my-models/llm
      runtimeVersion: latest-gpu
      resources:
        limits:
          nvidia.com/gpu: 1
---
# Canary rollout
spec:
  predictor:
    canaryTrafficPercent: 20
    pytorch:
      storageUri: s3://my-models/llm-v2
  # 20% → new model, 80% → previous (stable) model
```

```bash
# Test an InferenceService
MODEL_NAME=sklearn-iris
INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -v \
  -H "Host: sklearn-iris.production.example.com" \
  -H "Content-Type: application/json" \
  http://$INGRESS_HOST/v1/models/$MODEL_NAME:predict \
  -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}'
```

---

## Ray on Kubernetes (KubeRay)

Ray provides distributed computing for ML training, hyperparameter tuning, and serving.

```bash
helm install kuberay-operator kuberay/kuberay-operator \
  --namespace ray-system --create-namespace
```

```yaml
# RayCluster for distributed training
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: training-cluster
spec:
  rayVersion: "2.9.0"
  headGroupSpec:
    replicas: 1
    rayStartParams:
      dashboard-host: "0.0.0.0"
      num-gpus: "1"
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray-ml:2.9.0-gpu
          resources:
            limits:
              nvidia.com/gpu: 1
              cpu: 4
              memory: 16Gi
  workerGroupSpecs:
  - groupName: gpu-workers
    replicas: 4
    minReplicas: 1
    maxReplicas: 8
    rayStartParams:
      num-gpus: "1"
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray-ml:2.9.0-gpu
          resources:
            limits:
              nvidia.com/gpu: 1
              cpu: 8
              memory: 32Gi
---
# Submit a job to the cluster
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: train-resnet
spec:
  entrypoint: python train_resnet.py --epochs 50
  runtimeEnvYAML: |
    pip:
    - torch==2.1.0
    - torchvision
  clusterSelector:
    matchLabels:
      ray.io/cluster: training-cluster
```

---

## MLflow on Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: mlflow
        image: ghcr.io/mlflow/mlflow:v2.10.0
        command:
        - mlflow
        - server
        - --host=0.0.0.0
        - --port=5000
        - --backend-store-uri=postgresql://mlflow:$(DB_PASSWORD)@postgres:5432/mlflow
        - --default-artifact-root=s3://my-mlflow-artifacts
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mlflow-db-secret
              key: password
```

```python
# Track an experiment
import mlflow

mlflow.set_tracking_uri("http://mlflow.mlops.svc:5000")
mlflow.set_experiment("my-model-training")

with mlflow.start_run():
    mlflow.log_param("n_estimators", 100)
    mlflow.log_param("max_depth", 10)
    mlflow.log_metric("accuracy", 0.95)
    mlflow.log_metric("f1_score", 0.94)
    mlflow.sklearn.log_model(model, "model")
```

---

## Argo Workflows for ML Pipelines

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ml-pipeline-
spec:
  entrypoint: ml-pipeline
  templates:
  - name: ml-pipeline
    dag:
      tasks:
      - name: data-prep
        template: run-python
        arguments:
          parameters:
          - name: script
            value: data_prep.py
      - name: train
        template: gpu-training
        dependencies: [data-prep]
        arguments:
          parameters:
          - name: dataset
            value: "{{tasks.data-prep.outputs.parameters.dataset-path}}"
      - name: evaluate
        template: run-python
        dependencies: [train]
      - name: deploy
        template: deploy-model
        dependencies: [evaluate]

  - name: gpu-training
    inputs:
      parameters:
      - name: dataset
    container:
      image: myorg/trainer:latest
      command: [python, train.py]
      args: ["--dataset", "{{inputs.parameters.dataset}}"]
      resources:
        limits:
          nvidia.com/gpu: 1
```

---

## Batch Scheduling with Volcano

For gang-scheduling (all workers must start together or none start):

```bash
helm install volcano volcano-sh/volcano -n volcano-system --create-namespace
```

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: mpi-training
spec:
  minAvailable: 5   # all 5 must be scheduled together
  schedulerName: volcano
  plugins:
    ssh: []
    env: []
    svc: []
  tasks:
  - replicas: 1
    name: mpimaster
    template:
      spec:
        containers:
        - image: mpioperator/mpi-operator:latest
          name: master
  - replicas: 4
    name: mpiworker
    template:
      spec:
        containers:
        - image: myorg/mpi-worker:latest
          name: worker
          resources:
            limits:
              nvidia.com/gpu: 1
```

---

## SRE Lens

- **GPU nodes are expensive** — use Karpenter or CA to scale them down when no training jobs are running.
- **Failed training jobs waste GPU hours** — always set `activeDeadlineSeconds` on Jobs and `backoffLimit` to avoid infinite retries.
- **Model serving autoscaling** — KServe scales to zero during off-hours; use a warmup sidecar or HPA with min=1 for latency-sensitive serving.
- **etcd size** — ML metadata (experiments, runs, artifacts) can grow large. Store artifact files in S3/GCS, not etcd.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Kubeflow](https://www.kubeflow.org/docs/) |
| Official Docs | [KServe](https://kserve.github.io/website/) |
| Official Docs | [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) |
| Official Docs | [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html) |
| Official Docs | [Volcano](https://volcano.sh/en/docs/) |
| Tool | [MLflow](https://mlflow.org/docs/latest/index.html) |
| Blog | [Running PyTorch on Kubernetes](https://pytorch.org/tutorials/intermediate/dist_tuto.html) |

# 08 — ConfigMaps & Secrets

Decouple configuration from container images. Never bake config or credentials into images.

---

## ConfigMaps

ConfigMaps store non-sensitive configuration data as key-value pairs.

### Creating ConfigMaps

```bash
# From literals
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MAX_CONNECTIONS=100

# From a file (key = filename)
kubectl create configmap nginx-config \
  --from-file=nginx.conf

# From a file with custom key
kubectl create configmap nginx-config \
  --from-file=config=nginx.conf

# From a directory (all files become keys)
kubectl create configmap app-configs \
  --from-file=./config-dir/

# From an env file
kubectl create configmap app-env \
  --from-env-file=.env
```

```yaml
# Declarative ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  # Simple key-value
  LOG_LEVEL: info
  MAX_CONNECTIONS: "100"
  FEATURE_FLAG_X: "true"

  # Multi-line value (file content)
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      server {
        listen 80;
        location / { proxy_pass http://localhost:8080; }
      }
    }

  # Properties file
  application.properties: |
    server.port=8080
    spring.datasource.url=jdbc:postgresql://postgres:5432/mydb
```

### Consuming ConfigMaps

#### As environment variables (all keys)

```yaml
spec:
  containers:
  - name: app
    envFrom:
    - configMapRef:
        name: app-config
    - configMapRef:
        name: feature-flags
        optional: true   # don't fail if ConfigMap doesn't exist
```

#### As environment variables (specific keys)

```yaml
spec:
  containers:
  - name: app
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
    - name: APP_PORT
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: PORT
          optional: true
```

#### As volume (file mount)

```yaml
spec:
  containers:
  - name: nginx
    volumeMounts:
    - name: config-vol
      mountPath: /etc/nginx
      readOnly: true
  volumes:
  - name: config-vol
    configMap:
      name: nginx-config
      # Optional: only mount specific keys
      items:
      - key: nginx.conf
        path: nginx.conf
        mode: 0444
```

### Live Config Reload

When a ConfigMap is mounted as a volume, Kubernetes updates the files automatically (with ~1 minute delay). Apps that watch for file changes can reload without a restart.

```bash
# Force reload by updating a data key
kubectl patch configmap app-config --patch '{"data":{"version":"'$(date +%s)'"}}'

# Or restart the deployment to force fresh mount
kubectl rollout restart deployment my-app
```

### Immutable ConfigMaps (1.21+)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: stable-config
immutable: true   # prevents accidental changes; API server rejects updates
data:
  APP_VERSION: "v1.2.3"
```

---

## Secrets

Secrets store sensitive data. They are base64-encoded (not encrypted by default!).

> **Important:** Secrets are base64, not encrypted. Anyone who can read the Secret in the API can decode it. Use encryption at rest and external secret managers for real security.

### Secret types

| Type | Use case |
|------|---------|
| `Opaque` | Generic secrets (default) |
| `kubernetes.io/tls` | TLS certificate and key |
| `kubernetes.io/dockerconfigjson` | Docker registry credentials |
| `kubernetes.io/service-account-token` | ServiceAccount token (auto-created) |
| `kubernetes.io/ssh-auth` | SSH private key |
| `kubernetes.io/basic-auth` | Username and password |

### Creating Secrets

```bash
# Opaque secret from literals
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password='S3cr3t!'

# From files
kubectl create secret generic tls-secret \
  --from-file=tls.crt=server.crt \
  --from-file=tls.key=server.key

# Docker registry credentials
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=ci-bot \
  --docker-password='token123' \
  --docker-email=ci@example.com

# TLS secret
kubectl create secret tls my-tls-secret \
  --cert=server.crt \
  --key=server.key
```

```yaml
# Declarative Secret (values must be base64-encoded)
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  username: YWRtaW4=       # echo -n 'admin' | base64
  password: UzNjcjN0IQ==   # echo -n 'S3cr3t!' | base64

# Alternative: use stringData (plain text, auto-encoded)
stringData:
  username: admin
  password: S3cr3t!
```

```bash
# Decode a secret value
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d
```

### Consuming Secrets

Same patterns as ConfigMaps:

```yaml
spec:
  containers:
  - name: app
    # All keys as env vars
    envFrom:
    - secretRef:
        name: db-credentials

    # Specific key
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password

    # Volume mount
    volumeMounts:
    - name: tls
      mountPath: /etc/ssl/certs
      readOnly: true

  volumes:
  - name: tls
    secret:
      secretName: my-tls-secret
      defaultMode: 0400

  # Pull from private registry
  imagePullSecrets:
  - name: regcred
```

---

## Secrets Encryption at Rest

By default, Secrets are stored in etcd as base64 — anyone with etcd access can read them.

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:                    # AES-CBC encryption
      keys:
      - name: key1
        secret: <base64-32-byte-key>
  - identity: {}               # fallback: unencrypted (for reading existing secrets)
```

```bash
# Generate a 32-byte key
head -c 32 /dev/urandom | base64

# Apply to kube-apiserver
# Add: --encryption-provider-config=/etc/kubernetes/encryption-config.yaml

# Re-encrypt all existing secrets after enabling
kubectl get secrets -A -o json | kubectl replace -f -
```

For cloud clusters, use:
- **AWS**: EKS Secrets Encryption with AWS KMS
- **GCP**: GKE Application-Layer Secrets Encryption with Cloud KMS
- **Azure**: AKS etcd encryption with Azure Key Vault

---

## External Secrets Operator

ESO syncs secrets from external stores (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager) into Kubernetes Secrets.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace
```

```yaml
# SecretStore — connects to AWS Secrets Manager using IRSA
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
---
# ExternalSecret — defines which secrets to sync
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: db-credentials     # name of the Kubernetes Secret to create
    creationPolicy: Owner
  data:
  - secretKey: password      # key in Kubernetes Secret
    remoteRef:
      key: prod/myapp/db     # name in AWS Secrets Manager
      property: password     # JSON property within the secret
  - secretKey: username
    remoteRef:
      key: prod/myapp/db
      property: username
```

```yaml
# ClusterSecretStore — cluster-wide secret store
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: kubernetes
          role: my-role
```

---

## Sealed Secrets (for GitOps)

Sealed Secrets encrypt Kubernetes Secrets so they can be safely committed to Git.

```bash
# Install controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Install kubeseal CLI
brew install kubeseal

# Seal a secret
kubectl create secret generic my-secret --dry-run=client \
  --from-literal=password=S3cr3t! -o yaml | \
  kubeseal --format yaml > my-sealed-secret.yaml

# The sealed secret is safe to commit to Git
cat my-sealed-secret.yaml
git add my-sealed-secret.yaml && git commit -m "Add sealed secret"

# Apply — controller decrypts and creates the real Secret
kubectl apply -f my-sealed-secret.yaml
kubectl get secret my-secret
```

---

## HashiCorp Vault Integration

```yaml
# Vault Agent Injector (sidecar injection approach)
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "my-app"
    vault.hashicorp.com/agent-inject-secret-config: "secret/data/myapp/config"
    vault.hashicorp.com/agent-inject-template-config: |
      {{ with secret "secret/data/myapp/config" -}}
      export DB_PASSWORD="{{ .Data.data.db_password }}"
      export API_KEY="{{ .Data.data.api_key }}"
      {{- end }}
```

---

## Secret Rotation Patterns

```bash
# Pattern 1: ESO with refreshInterval — auto-rotates secrets
# Pattern 2: Restart Pods after secret rotation
kubectl rollout restart deployment my-app

# Pattern 3: Use projected service account tokens (rotate automatically)
volumes:
- name: vault-token
  projected:
    sources:
    - serviceAccountToken:
        path: token
        expirationSeconds: 3600
        audience: vault
```

---

## SRE Lens

- **Secrets are not secret by default** — enable encryption at rest and use IAM/RBAC to restrict who can `get secrets`.
- **Never log secret values** — check your app logs for accidental credential exposure.
- **Use ESO or Vault** for production secrets — avoid manually managing Kubernetes Secrets in GitOps repos (use Sealed Secrets as a minimum).
- **Watch for ESO sync failures** — monitor `externalsecret_status_condition` metric.
- **Immutable Secrets improve performance** — kubelet doesn't need to watch them for changes.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) |
| Official Docs | [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) |
| Official Docs | [Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) |
| Tool | [External Secrets Operator](https://external-secrets.io/) |
| Tool | [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) |
| Tool | [HashiCorp Vault + Kubernetes](https://developer.hashicorp.com/vault/docs/platform/k8s) |
| Blog | [Kubernetes Secrets Are Not Secret (CNCF)](https://www.cncf.io/blog/2021/04/22/kubernetes-secrets-management-build-secure-apps-faster-without-secrets/) |

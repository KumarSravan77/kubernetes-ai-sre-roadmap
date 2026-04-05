# 17 — Operators & Kubebuilder

Operators extend Kubernetes with domain-specific automation. You define a CRD (the "what") and write a controller (the "how").

---

## The Operator Pattern

```
CRD (DatabaseBackup)       ← declares desired state
      +
Controller (backup-operator) ← watches CRDs, reconciles actual state

Together: DatabaseBackup objects are self-managing
```

Real-world operators:
- **cert-manager** — manages TLS certificates
- **prometheus-operator** — manages Prometheus instances
- **postgres-operator** — manages PostgreSQL clusters
- **strimzi** — manages Apache Kafka

---

## Kubebuilder Setup

```bash
# Install
brew install kubebuilder
go version   # requires Go 1.21+

# Create a new project
mkdir database-operator && cd database-operator
kubebuilder init \
  --domain example.com \
  --repo github.com/myorg/database-operator

# Generate the API (CRD + controller skeleton)
kubebuilder create api \
  --group database \
  --version v1alpha1 \
  --kind DatabaseBackup

# Generate webhook
kubebuilder create webhook \
  --group database \
  --version v1alpha1 \
  --kind DatabaseBackup \
  --defaulting \
  --programmatic-validation
```

Generated structure:

```
database-operator/
├── api/v1alpha1/
│   ├── databasebackup_types.go    ← CRD spec/status types
│   └── zz_generated.deepcopy.go  ← auto-generated
├── config/
│   ├── crd/                       ← generated CRD manifests
│   ├── rbac/                      ← generated RBAC manifests
│   └── default/                   ← kustomize base
├── internal/controller/
│   └── databasebackup_controller.go ← YOUR reconcile logic
├── Dockerfile
├── Makefile
└── main.go
```

---

## Defining a CRD in Go

```go
// api/v1alpha1/databasebackup_types.go
package v1alpha1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// DatabaseBackupSpec defines the desired state
type DatabaseBackupSpec struct {
    // +kubebuilder:validation:Required
    Database string `json:"database"`

    // +kubebuilder:validation:Pattern=`^(\d+|\*)(/\d+)?(\s+(\d+|\*)(/\d+)?){4}$`
    Schedule string `json:"schedule"`

    // +kubebuilder:default=7
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=365
    RetentionDays int `json:"retentionDays,omitempty"`

    StorageLocation string `json:"storageLocation"`

    // +kubebuilder:validation:Enum=postgres;mysql;mongodb
    Engine string `json:"engine"`
}

// DatabaseBackupStatus defines the observed state
type DatabaseBackupStatus struct {
    // +listType=map
    // +listMapKey=type
    Conditions []metav1.Condition `json:"conditions,omitempty"`

    LastBackupTime  *metav1.Time `json:"lastBackupTime,omitempty"`
    LastBackupSize  string       `json:"lastBackupSize,omitempty"`
    BackupsRetained int          `json:"backupsRetained,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Database",type="string",JSONPath=".spec.database"
// +kubebuilder:printcolumn:name="Schedule",type="string",JSONPath=".spec.schedule"
// +kubebuilder:printcolumn:name="Last Backup",type="date",JSONPath=".status.lastBackupTime"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"
type DatabaseBackup struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   DatabaseBackupSpec   `json:"spec,omitempty"`
    Status DatabaseBackupStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type DatabaseBackupList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []DatabaseBackup `json:"items"`
}

func init() {
    SchemeBuilder.Register(&DatabaseBackup{}, &DatabaseBackupList{})
}
```

```bash
# Generate CRD manifests from the types
make generate
make manifests
```

---

## Writing the Controller

```go
// internal/controller/databasebackup_controller.go
package controller

import (
    "context"
    "fmt"
    "time"

    batchv1 "k8s.io/api/batch/v1"
    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/api/errors"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"

    databasev1alpha1 "github.com/myorg/database-operator/api/v1alpha1"
)

type DatabaseBackupReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=database.example.com,resources=databasebackups,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=database.example.com,resources=databasebackups/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=database.example.com,resources=databasebackups/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=cronjobs,verbs=get;list;watch;create;update;patch;delete

func (r *DatabaseBackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)

    // 1. Fetch the DatabaseBackup instance
    backup := &databasev1alpha1.DatabaseBackup{}
    if err := r.Get(ctx, req.NamespacedName, backup); err != nil {
        if errors.IsNotFound(err) {
            // Object deleted — nothing to do
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, err
    }

    // 2. Handle deletion with finalizer
    if !backup.DeletionTimestamp.IsZero() {
        return r.handleDeletion(ctx, backup)
    }

    // 3. Add finalizer if not present
    if !containsString(backup.Finalizers, "database.example.com/cleanup") {
        backup.Finalizers = append(backup.Finalizers, "database.example.com/cleanup")
        if err := r.Update(ctx, backup); err != nil {
            return ctrl.Result{}, err
        }
    }

    // 4. Reconcile the CronJob
    cronJob := r.buildCronJob(backup)
    if err := ctrl.SetControllerReference(backup, cronJob, r.Scheme); err != nil {
        return ctrl.Result{}, err
    }

    existing := &batchv1.CronJob{}
    err := r.Get(ctx, client.ObjectKey{Name: cronJob.Name, Namespace: cronJob.Namespace}, existing)
    if errors.IsNotFound(err) {
        logger.Info("Creating CronJob", "name", cronJob.Name)
        if err := r.Create(ctx, cronJob); err != nil {
            return ctrl.Result{}, err
        }
    } else if err != nil {
        return ctrl.Result{}, err
    } else {
        // Update if spec changed
        existing.Spec = cronJob.Spec
        if err := r.Update(ctx, existing); err != nil {
            return ctrl.Result{}, err
        }
    }

    // 5. Update status
    backup.Status.Conditions = []metav1.Condition{
        {
            Type:               "Ready",
            Status:             metav1.ConditionTrue,
            Reason:             "CronJobSynced",
            Message:            fmt.Sprintf("CronJob %s is synced", cronJob.Name),
            LastTransitionTime: metav1.Now(),
        },
    }
    if err := r.Status().Update(ctx, backup); err != nil {
        return ctrl.Result{}, err
    }

    return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

func (r *DatabaseBackupReconciler) buildCronJob(backup *databasev1alpha1.DatabaseBackup) *batchv1.CronJob {
    return &batchv1.CronJob{
        ObjectMeta: metav1.ObjectMeta{
            Name:      backup.Name + "-backup",
            Namespace: backup.Namespace,
        },
        Spec: batchv1.CronJobSpec{
            Schedule: backup.Spec.Schedule,
            JobTemplate: batchv1.JobTemplateSpec{
                Spec: batchv1.JobSpec{
                    Template: corev1.PodTemplateSpec{
                        Spec: corev1.PodSpec{
                            RestartPolicy: corev1.RestartPolicyOnFailure,
                            Containers: []corev1.Container{
                                {
                                    Name:  "backup",
                                    Image: "myorg/db-backup:latest",
                                    Env: []corev1.EnvVar{
                                        {Name: "DATABASE", Value: backup.Spec.Database},
                                        {Name: "ENGINE", Value: backup.Spec.Engine},
                                        {Name: "STORAGE", Value: backup.Spec.StorageLocation},
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }
}

func (r *DatabaseBackupReconciler) handleDeletion(ctx context.Context, backup *databasev1alpha1.DatabaseBackup) (ctrl.Result, error) {
    // Cleanup logic here (e.g., delete old backups from storage)
    // Remove finalizer to allow deletion
    backup.Finalizers = removeString(backup.Finalizers, "database.example.com/cleanup")
    return ctrl.Result{}, r.Update(ctx, backup)
}

func (r *DatabaseBackupReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&databasev1alpha1.DatabaseBackup{}).
        Owns(&batchv1.CronJob{}).     // watch CronJobs owned by DatabaseBackup
        Complete(r)
}

func containsString(slice []string, s string) bool {
    for _, item := range slice {
        if item == s {
            return true
        }
    }
    return false
}

func removeString(slice []string, s string) []string {
    result := []string{}
    for _, item := range slice {
        if item != s {
            result = append(result, item)
        }
    }
    return result
}
```

---

## Admission Webhooks

```go
// api/v1alpha1/databasebackup_webhook.go
package v1alpha1

import (
    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/webhook"
    "sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

func (r *DatabaseBackup) SetupWebhookWithManager(mgr ctrl.Manager) error {
    return ctrl.NewWebhookManagedBy(mgr).
        For(r).
        Complete()
}

// Defaulting webhook
var _ webhook.Defaulter = &DatabaseBackup{}

func (r *DatabaseBackup) Default() {
    if r.Spec.RetentionDays == 0 {
        r.Spec.RetentionDays = 7
    }
}

// Validation webhook
var _ webhook.Validator = &DatabaseBackup{}

func (r *DatabaseBackup) ValidateCreate() (admission.Warnings, error) {
    return r.validate()
}

func (r *DatabaseBackup) ValidateUpdate(old runtime.Object) (admission.Warnings, error) {
    return r.validate()
}

func (r *DatabaseBackup) ValidateDelete() (admission.Warnings, error) {
    return nil, nil
}

func (r *DatabaseBackup) validate() (admission.Warnings, error) {
    if r.Spec.Engine == "mysql" && r.Spec.RetentionDays > 30 {
        return nil, fmt.Errorf("MySQL backups cannot be retained for more than 30 days")
    }
    return nil, nil
}
```

---

## Testing Operators

```go
// internal/controller/databasebackup_controller_test.go
package controller

import (
    "context"
    . "github.com/onsi/ginkgo/v2"
    . "github.com/onsi/gomega"
    // ...
)

var _ = Describe("DatabaseBackup Controller", func() {
    ctx := context.Background()

    It("should create a CronJob when a DatabaseBackup is created", func() {
        backup := &databasev1alpha1.DatabaseBackup{
            ObjectMeta: metav1.ObjectMeta{
                Name:      "test-backup",
                Namespace: "default",
            },
            Spec: databasev1alpha1.DatabaseBackupSpec{
                Database:      "mydb",
                Schedule:      "0 2 * * *",
                Engine:        "postgres",
                StorageLocation: "s3://my-backups",
            },
        }
        Expect(k8sClient.Create(ctx, backup)).Should(Succeed())

        cronJob := &batchv1.CronJob{}
        Eventually(func() bool {
            err := k8sClient.Get(ctx, types.NamespacedName{
                Name:      "test-backup-backup",
                Namespace: "default",
            }, cronJob)
            return err == nil
        }, timeout, interval).Should(BeTrue())

        Expect(cronJob.Spec.Schedule).Should(Equal("0 2 * * *"))
    })
})
```

```bash
# Run tests with envtest (real API server, no cluster needed)
make test
```

---

## Running the Operator

```bash
# Run locally against a cluster (for development)
make install       # install CRD
make run           # run controller locally

# Build and deploy
make docker-build IMG=myorg/database-operator:v0.1.0
make docker-push IMG=myorg/database-operator:v0.1.0
make deploy IMG=myorg/database-operator:v0.1.0
```

```yaml
# Deploy a DatabaseBackup resource
apiVersion: database.example.com/v1alpha1
kind: DatabaseBackup
metadata:
  name: production-postgres-backup
spec:
  database: production
  engine: postgres
  schedule: "0 2 * * *"
  retentionDays: 14
  storageLocation: s3://my-backup-bucket/postgres
```

```bash
kubectl get databasebackups
kubectl describe databasebackup production-postgres-backup
kubectl get cronjobs   # should see the auto-created CronJob
```

---

## Owner References and GC

```go
// Set owner reference so CronJob is deleted when DatabaseBackup is deleted
ctrl.SetControllerReference(backup, cronJob, r.Scheme)
// This adds ownerReferences to the CronJob
// When DatabaseBackup is deleted → CronJob is garbage-collected automatically
```

---

## SRE Lens

- **Idempotent reconcile** — your reconcile function will run many times. Ensure creating/updating is always safe to call repeatedly.
- **Status conditions** — use `metav1.Condition` with proper `Type`, `Reason`, `Message`. This is how users understand operator health.
- **Finalizers prevent accidental deletion** — use them for resources that need cleanup (cloud objects, backups). But always clean up and remove the finalizer, or the object will be stuck forever.
- **Rate limiting** — controller-runtime has built-in exponential backoff. Don't retry too aggressively on transient failures.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Kubebuilder Book](https://book.kubebuilder.io/) |
| Official Docs | [controller-runtime](https://pkg.go.dev/sigs.k8s.io/controller-runtime) |
| Official Docs | [Operator SDK](https://sdk.operatorframework.io/docs/) |
| Resource | [OperatorHub.io](https://operatorhub.io/) |
| Book | *Programming Kubernetes* — Hausenblas & Schimanski (O'Reilly) |
| Blog | [Kubebuilder Tutorial (official)](https://book.kubebuilder.io/cronjob-tutorial/cronjob-tutorial.html) |

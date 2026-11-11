---
title: "Basic Verification of Custom CRD Design and Controller Implementation with Kubebuilder"
slug: "kubebuilder-crd-controller-implementation"
date: 2026-11-11T11:00:35+09:00
draft: false
image: ""
description: "An engineering note documenting the implementation procedures and verification process for custom controllers that manage CRD schema definitions and Reconcile loops in Kubernetes API extensions."
categories: ["DevOps Logistics"]
tags: ["kubebuilder", "kubernetes", "crd", "controller-runtime", "kubectl"]
author: "K-Life Hack"
---

In the process of operating a Kubernetes cluster, relying solely on standard primitives such as Pods, Services, and Deployments introduces challenges where domain-specific lifecycle management and declarative state maintenance cannot be fully automated. Because ad-hoc operations using shell scripts or external scripts are prone to human error and state drift, it becomes necessary to apply the Operator pattern—registering custom resource types directly into the Kubernetes Control Plane and managing their lifecycle via the API server.


This article outlines the workflow from formulating a Custom Resource Definition (CRD) schema using the Kubebuilder framework to implementing a state-tracking controller via a Reconcile loop and verifying connectivity in a local environment.



## 1. Components of the Kubernetes Extension Architecture

The Kubernetes extension mechanism is based on a feedback control model that reconciles the declared specification (Desired State) with the actual system state (Actual State).



* <b>Custom Resource (CR):</b> An instance of a user-defined custom object. Data is persisted to etcd, the cluster's storage backend, enabling CRUD operations via the API server.
* <b>Custom Resource Definition (CRD):</b> The blueprint defining the OpenAPI v3 schema of a CR. It specifies field type validation, required checks, and the presence or absence of status subresources.
* <b>Controller:</b> An autonomous process that watches for events (create, update, delete) on specified resources and executes a `Reconcile()` function within an infinite loop structure to eliminate discrepancies.

### Characteristics of Development Framework Options

For implementing Kubernetes controllers, Kubebuilder and Operator SDK are the two primary options. Their characteristics are compared below:



| Item | Kubebuilder | Operator SDK |
| :--- | :--- | :--- |
| Primary Maintainer | Kubernetes SIGs | Operator Framework (CNCF/Red Hat) |
| Supported Languages | Go | Go, Ansible, Helm |
| Scope | Scaffolding, code generation, testing | Scaffolding, OLM integration, packaging |
| Structural Relationship | Standard core for controller implementation | Adopts Kubebuilder internally as the engine for Go-based implementations |

In this implementation, Kubebuilder is adopted to minimize dependencies and rapidly verify pure Go controller logic.



## 2. Project Initialization and API Schema Definition

First, create a working directory and run scaffolding by specifying the project domain and repository module name.



```bash
mkdir cinema-operator &amp;&amp; cd cinema-operator
kubebuilder init --domain cinema.com --repo cinema.com/operator
```

Next, generate the API resource structure with group name `entertainment`, version `v1`, and Kind name `Movie`.



```bash
kubebuilder create api --group entertainment --version v1 --kind Movie
```

Edit the generated `api/v1/movie_types.go` and declare domain-specific fields in `MovieSpec`.



```go
package v1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type MovieSpec struct {
    Title       string `json:"title,omitempty"`
    Genre       string `json:"genre,omitempty"`
    RunningTime int    `json:"runningTime,omitempty"`
    IsReleased  bool   `json:"isReleased,omitempty"`
}

type MovieStatus struct {
    // Add status fields for state management as necessary
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status

type Movie struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   MovieSpec   `json:"spec,omitempty"`
    Status MovieStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

type MovieList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []Movie `json:"items"`
}

func init() {
    SchemeBuilder.Register(&amp;Movie{}, &amp;MovieList{})
}
```

## 3. Implementing Controller Reconcile Logic

Implement the processing flow upon event detection in `internal/controller/movie_controller.go`. Retrieve the instance of the target resource from the API server; if it does not exist, ignore the NotFound error and terminate the loop.



```go
package controller

import (
    "context"

    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"

    entertainmentv1 "cinema.com/operator/api/v1"
)

type MovieReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=entertainment.cinema.com,resources=movies,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=entertainment.cinema.com,resources=movies/status,verbs=get;update;patch

func (r *MovieReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)

    var movie entertainmentv1.Movie
    if err := r.Get(ctx, req.NamespacedName, &amp;movie); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    logger.Info("Reconciling Movie resource", 
        "Name", movie.Name, 
        "Title", movie.Spec.Title, 
        "Genre", movie.Spec.Genre,
        "RunningTime", movie.Spec.RunningTime,
        "IsReleased", movie.Spec.IsReleased,
    )

    return ctrl.Result{}, nil
}

func (r *MovieReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&amp;entertainmentv1.Movie{}).
        Complete(r)
}
```

## 4. Manifest Generation and Local Endpoint Verification

Automatically generate CRD manifest files from the marker comments (`+kubebuilder:...`) attached to the Go structs.



```bash
make manifests
```

Apply the generated manifest file `config/crd/bases/entertainment.cinema.com_movies.yaml` to the verification API server. Below is the procedure to launch a temporary container for development verification and register the resource.



```bash
docker run -d --name=k8s-api --net=host \
  registry.k8s.io/kube-apiserver:v1.19.0 \
  kube-apiserver --etcd-servers=http://127.0.0.1:8888 \
  --authorization-mode=AlwaysAllow --bind-address=0.0.0.0 \
  --insecure-port=8080 --secure-port=6444 --allow-privileged=true

kubectl --server=http://127.0.0.1:8080 apply -f config/crd/bases/entertainment.cinema.com_movies.yaml
```

Write a CR instance manifest `movie-sample.yaml` that conforms to the defined schema.



```yaml
apiVersion: entertainment.cinema.com/v1
kind: Movie
metadata:
  name: the-outlaws
spec:
  title: "The Outlaws 4"
  genre: "Action"
  runningTime: 109
  isReleased: true
```

Register the CR into the cluster.



```bash
kubectl --server=http://127.0.0.1:8080 apply -f movie-sample.yaml
```

Start the controller process and synchronize it with the API server.



```bash
export KUBERNETES_MASTER="http://127.0.0.1:8080"
make run
```

## 5. Troubleshooting

### Schema Validation Errors During CRD Application

When applying a CRD, syntax errors in Kubebuilder tags or type mismatches may trigger the following error:



```text
error: unable to recognize "config/crd/bases/entertainment.cinema.com_movies.yaml": no matches for kind "CustomResourceDefinition" in version "apiextensions.k8s.io/v1"
```

In this scenario, verify whether the target API server version matches the CRD API specification (`v1` or `v1beta1`). If backward compatibility is required, re-specify `crd:crdVersions=v1beta1` in the Controller-tools generation options within the `Makefile`.



### Reconcile Failure Due to Insufficient RBAC Permissions

When running the controller as a Pod in an actual cluster environment, missing RoleBindings for the ServiceAccount will lead to access denial errors such as:



```text
ERROR   controllers.Movie       unable to fetch Movie   {"error": "movies.entertainment.cinema.com is forbidden: User \"system:serviceaccount:cinema-system:cinema-operator\" cannot get resource \"movies\" in API group \"entertainment.cinema.com\""}
```

This issue originates either from missing RBAC markers (`// +kubebuilder:rbac:groups=...`) in the Go code or from not applying the generated Role configurations. After updating the markers, re-run `make manifests` and redeploy the generated ClusterRole/Role manifests.



## 6. Verification Logs and Execution Protocol

Inspect the logs from CR application and controller startup to verify that the Reconcile process executes correctly.



```text
$ kubectl --server=http://127.0.0.1:8080 get crd
NAME                                  CREATED AT
movies.entertainment.cinema.com       2026-11-11T09:12:44Z

$ kubectl --server=http://127.0.0.1:8080 get movie the-outlaws -o yaml
apiVersion: entertainment.cinema.com/v1
kind: Movie
metadata:
  name: the-outlaws
  namespace: default
spec:
  genre: Action
  isReleased: true
  runningTime: 109
  title: The Outlaws 4

$ make run
/home/user/cinema-operator/bin/controller-gen rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
go run ./cmd/main.go
2026-11-11T09:15:02.114Z INFO controller-runtime.metrics Metrics server is starting to listen {"addr": ":8080"}
2026-11-11T09:15:02.115Z INFO Starting server {"path": "/metrics", "kind": "metrics", "addr": "[::]:8080"}
2026-11-11T09:15:02.116Z INFO Starting EventSource {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "source": "kind source: *v1.Movie"}
2026-11-11T09:15:02.116Z INFO Starting Controller {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie"}
2026-11-11T09:15:02.218Z INFO Starting workers {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "worker count": 1}
2026-11-11T09:15:02.219Z INFO Reconciling Movie resource {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "Movie": {"name":"the-outlaws","namespace":"default"}, "namespace": "default", "name": "the-outlaws", "reconcileID": "84e3d179-8ab3-4c91-921c-cb9716ebff12", "Name": "the-outlaws", "Title": "The Outlaws 4", "Genre": "Action", "RunningTime": 109, "IsReleased": true}
```

## 7. Architectural Separation Between CRDs and Annotations

When storing custom data in Kubernetes, two primary approaches are considered: using Annotations or introducing a new CRD. The boundary between the two directly impacts system responsibility design.



* <b>CRD:</b> Used when strict system schema validation is required and a typed API endpoint needs to be established. CRDs are mandatory for constructing the Operator pattern, where other resources (Pods, Jobs, external cloud services, etc.) are actively created, updated, or deleted via the Reconcile loop.
* <b>Annotation:</b> Used exclusively for attaching incidental metadata, external audit information, or temporary unstructured text. No type validation is performed by the API server.

## Operational Notes

When designing custom resources and controllers, the Reconcile logic must be guaranteed to be idempotent. Because the Kubernetes event notification mechanism follows an At-Least-Once delivery model, the logic structure must prevent duplicate resource creation and state inconsistencies even if Reconcile is invoked multiple consecutive times for the same object.


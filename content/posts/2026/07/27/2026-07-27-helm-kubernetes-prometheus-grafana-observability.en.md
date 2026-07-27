---
title: "Kubernetes Application Management Using Helm and Prometheus Monitoring Stack Deployment"
slug: "helm-kubernetes-prometheus-grafana-observability"
date: 2026-07-27T10:09:05+09:00
draft: false
image: ""
description: "Explains the procedures for Kubernetes package management using Helm, and the deployment configuration of a Prometheus/Grafana observability stack using kube-prometheus-stack and custom manifests."
categories: ["DevOps Logistics"]
tags: ["helm", "kubernetes", "prometheus", "grafana", "kubectl"]
author: "K-Life Hack"
---

As the operational scale of a Kubernetes cluster grows, manually deploying and managing static YAML manifests individually leads to configuration bloat and version control confusion. Introducing an abstracted packaging mechanism is essential, particularly when applying identical configurations across multiple environments or managing dependent components collectively. This article explains resource deployment utilizing Helm, the package manager for Kubernetes, alongside procedures for building a visualization and monitoring stack centered on Prometheus and Grafana.



## Helm Basic Structure and Operating Principles

Helm achieves dynamic manifest generation by separating the variable configuration file (<code>values.yaml</code>) from a template engine based on Go Template syntax. It manages the application lifecycle using package units called charts.



### Standard Chart Directory Structure

```text
<chart-name>/
├── Chart.yaml       # Chart metadata (name, version, API version, etc.)
├── values.yaml      # Default parameter values to be injected into templates
├── charts/          # Directory containing dependent subcharts
├── templates/       # Kubernetes manifests written as Go templates
└── .helmignore      # File patterns to exclude when packaging
```

### Installing the Helm 3 Binary

Install Helm 3 on the control node to set up the execution environment.



```bash
mkdir /root/helm &amp;&amp; cd /root/helm
curl -fssL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
```

After installation completes, verify the version information.



```bash
helm version
```

Example execution log output:



```text
version.BuildInfo{Version:"v3.20.0", GitCommit:"b2e4314fa0f229a1de7b4c981273f61d69ee5a59", GitTreeState:"clean", GoVersion:"go1.25.6"}
```

## Repository Integration and NGINX Chart Parameter Customization

Fetch the chart from an external repository, modify parameters, and deploy it to a specific namespace.



```bash
helm repo add bitnami https://charts.bitnami.com/bitnami/
helm pull bitnami/nginx
tar zxvf nginx-22.5.5.tgz
mv nginx/ nginx-22.5.5/
cd nginx-22.5.5/
```

Edit <code>values.yaml</code> to change the replica count from the default value of 1 to 2.



```yaml
## @param replicaCount Number of NGINX replicas to deploy
##
replicaCount: 2
```

Create a dedicated namespace and execute the deployment from the chart in the local directory.



```bash
kubectl create ns nginx
helm install nginx . --namespace=nginx
```

Verify the deployment status and rendered manifests.



```bash
helm ls -n nginx
helm get manifest nginx -n nginx
```

## Integration of the Observability Stack (Prometheus / Grafana)

For stable Kubernetes cluster operations, metrics collection and visualization at both the node and container layers are essential. This setup integrates the following components:



* <b>Prometheus</b>: Time-series database (TSDB) and pull-based metrics collection engine
* <b>Grafana</b>: Dashboard that queries and visualizes data from Prometheus using PromQL
* <b>Alertmanager</b>: Routes notifications matching alert conditions to external systems
* <b>kube-state-metrics</b>: Listens to the API server and generates metrics about the state of Kubernetes objects
* <b>cAdvisor</b>: Embedded in Kubelet to extract per-container CPU and memory resource consumption
* <b>Node-Exporter</b>: Exposes hardware and kernel metrics at the host OS level

### Deploying kube-prometheus-stack

Deploy the entire stack at once using the official chart from Prometheus Community.



```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
```

### Configuring Dashboard Access

Configure port forwarding for the Prometheus UI and Grafana Web UI.



```bash
# Prometheus UI port forwarding
kubectl port-forward --address 0.0.0.0 svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring

# Retrieve Grafana admin password
kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode ; echo

# Grafana UI port forwarding
kubectl port-forward --address 0.0.0.0 svc/monitoring-grafana 3000:80 -n monitoring
```

To apply custom configuration values (e.g., exposure via NodePort), create a <code>custom.yaml</code> for overrides and install with it.



```yaml
grafana:
  adminPassword: "P@ssw0rd"
  service:
    type: NodePort
    nodePort: 30002

```bash

helm install monitoring . -f custom.yaml -n monitoring

```

## マニフェスト直接定義によるPrometheusデプロイ

Helmを使用できない制限環境向けに、純粋なKubernetesマニフェストを用いてPrometheusを構成する手法を示します。

### 1. RBAC権限の設定 (`prometheus-cluster-role.yaml`)

```yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
name: prometheus
namespace: monitoring
rules:
- apiGroups: [""]
resources:
- nodes
- nodes/proxy
- services
- endpoints
- pods
verbs: ["get", "list", "watch"]
- apiGroups:
- extensions
resources:
- ingresses
verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics"]
verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
name: prometheus
roleRef:
apiGroup: rbac.authorization.k8s.io
kind: ClusterRole
name: prometheus
subjects:
- kind: ServiceAccount
name: default
namespace: monitoring

```

### 2. ConfigMapによるPrometheus設定 (`prometheus-config-map.yaml`)

```yaml

apiVersion: v1
kind: ConfigMap
metadata:
name: prometheus-server-conf
labels:
name: prometheus-server-conf
namespace: monitoring
data:
prometheus.rules: |-
groups:
- name: container memory alert
rules:
- alert: container memory usage rate is very high( &gt; 55%)
expr: sum(container_memory_working_set_bytes{pod!="", name=""})/ sum (kube_node_status_allocatable_memory_bytes) * 100 &gt; 55
for: 1m
labels:
severity: fatal
annotations:
summary: High Memory Usage
prometheus.yml: |-
global:
scrape_interval: 5s
evaluation_interval: 5s
rule_files:
- /etc/prometheus/prometheus.rules
scrape_configs:
- job_name: 'kubernetes-apiservers'
kubernetes_sd_configs:
- role: endpoints
scheme: https
tls_config:
ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
relabel_configs:
- source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
action: keep
regex: default;kubernetes;https
- job_name: 'kubernetes-pods'
kubernetes_sd_configs:
- role: pod
relabel_configs:
- source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
action: keep
regex: true

```

### 3. DeploymentとDaemonSetの適用

```yaml

apiVersion: apps/v1
kind: Deployment
metadata:
name: prometheus-deployment
namespace: monitoring
spec:
replicas: 1
selector:
matchLabels:
app: prometheus-server
template:
metadata:
labels:
app: prometheus-server
spec:
containers:
- name: prometheus
image: prom/prometheus:latest
args:
- "--config.file=/etc/prometheus/prometheus.yml"
- "--storage.tsdb.path=/prometheus/"
ports:
- containerPort: 9090
volumeMounts:
- name: prometheus-config-volume
mountPath: /etc/prometheus/
- name: prometheus-storage-volume
mountPath: /prometheus/
volumes:
- name: prometheus-config-volume
configMap:
defaultMode: 420
name: prometheus-server-conf
- name: prometheus-storage-volume
emptyDir: {}

```

## Troubleshooting

### 1. リポジトリ未登録によるチャート検索エラー

Helmのインストール直後に <code>helm search repo</code> を実行すると以下のエラーが発生します。

```text

Error: no repositories configured

```

⚠️ <b>原因</b>: ローカルキャッシュにリモートリポジトリ情報が存在しないためです。
🛠️ <b>解決策</b>: <code>helm repo add <name> <url></url></name></code> を実行し、対象のリポジトリを追加した後に <code>helm repo update</code> を行ってインデックスを更新します。

### 2. ポートフォワーディング接続の拒否

<code>kubectl port-forward</code> を実行した際、外部クライアントからアクセスできない現象が発生することがあります。

⚠️ <b>原因</b>: デフォルトでは <code>127.0.0.1</code>（ループバックアドレス）にのみバインドされるためです。
🛠️ <b>解決策</b>: 明示的に <code>--address 0.0.0.0</code> パラメータを付与して全ネットワークインタフェースからのトラフィックを許可します。

### 3. PrometheusのAPIスクレイピングにおける403 Forbidden

カスタムマニフェストでPrometheusをデプロイした際、<code>kubernetes-nodes</code> や <code>kubernetes-pods</code> のターゲット取得に失敗するケースがあります。

⚠️ <b>原因</b>: ServiceAccountに対するRBAC ClusterRoleの権限不足（<code>/metrics</code> エンジンのアクセス権限欠落）です。
🛠️ <b>解決策</b>: ClusterRoleマニフェストにおいて <code>nonResourceURLs: ["/metrics"]</code> に対する <code>get</code> 権限を明示的に付与してください。

## システム検証プロトコル

デプロイ完了後、監視スタックが正常に稼働しているかを端末ログから検証します。

```text

$ kubectl get pods -n monitoring
NAME                                                     READY   STATUS    RESTARTS   AGE
alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2     Running   0          10m
monitoring-grafana-7678d7857c-x98kp                      1/1     Running   0          10m
monitoring-kube-prometheus-operator-7988fc5dcd-n4z92    1/1     Running   0          10m
monitoring-kube-state-metrics-569d9c7d8b-z2xlj         1/1     Running   0          10m
monitoring-prometheus-node-exporter-4z88k               1/1     Running   0          10m
prometheus-monitoring-kube-prometheus-prometheus-0      2/2     Running   0          10m

$ helm ls -n monitoring
NAME        NAMESPACE   REVISION    UPDATED                                 STATUS      CHART                       APP VERSION
monitoring  monitoring  1           2026-07-27 10:15:22.123456789 +0900 KST deployed    kube-prometheus-stack-58.2.0 v0.72.0</chart-name>
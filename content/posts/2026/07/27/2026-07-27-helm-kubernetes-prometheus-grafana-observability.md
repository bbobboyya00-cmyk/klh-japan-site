---
title: "Helmを用いたKubernetesアプリケーション管理とPrometheus監視スタックの構築"
slug: "helm-kubernetes-prometheus-grafana-observability"
date: 2026-07-27T10:09:04+09:00
draft: false
image: ""
description: "Helmを使用したKubernetesパッケージ管理の手順と、kube-prometheus-stackおよびカスタムマニフェストによるPrometheus/Grafana観測スタックのデプロイ構成を解説します。"
categories: ["DevOps Logistics"]
tags: ["helm", "kubernetes", "prometheus", "grafana", "kubectl"]
author: "K-Life Hack"
---

Kubernetesクラスタの運用規模が拡大するにつれ、静的なYAMLマニフェストを手動で個別にデプロイ・管理する手法は設定の肥大化やバージョン管理の混乱を引き起こします。特に複数環境に対する同一構成の適用や、依存関係を持つコンポーネントの一括管理において、抽象化されたパッケージング機構の導入は不可欠です。本稿では、KubernetesのパッケージマネージャーであるHelmを活用したリソースデプロイと、PrometheusおよびGrafanaを中心とした可視化・監視スタックの構築手順について解説します。

## Helmの基本構造と動作原理

HelmはGo Template構文をベースとしたテンプレートエンジンと、変数設定ファイル（<code>values.yaml</code>）を分離することで、動的なマニフェスト生成を実現します。チャートと呼ばれるパッケージ単位でアプリケーションのライフサイクルを管理します。

### チャートの標準ディレクトリ構造

```text
<chart-name>/
├── Chart.yaml       # チャートのメタデータ（名前、バージョン、APIバージョン等）
├── values.yaml      # テンプレートに注入するデフォルトのパラメータ値
├── charts/          # 依存するサブチャートを格納するディレクトリ
├── templates/       # Go templateで記述されたKubernetesマニフェスト群
└── .helmignore      # パッケージング時に除外するファイルパターン
```

### Helm 3 バイナリのインストール

コントロールノードにHelm 3をインストールし、実行環境をセットアップします。

```bash
mkdir /root/helm &amp;&amp; cd /root/helm
curl -fssL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
```

インストール完了後、バージョン情報を確認します。

```bash
helm version
```

実行結果ログ例:

```text
version.BuildInfo{Version:"v3.20.0", GitCommit:"b2e4314fa0f229a1de7b4c981273f61d69ee5a59", GitTreeState:"clean", GoVersion:"go1.25.6"}
```

## リポジトリ連携とNGINXチャートのパラメータカスタマイズ

外部リポジトリからチャートを取得し、パラメータを変更して特定ネームスペースへ展開します。

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami/
helm pull bitnami/nginx
tar zxvf nginx-22.5.5.tgz
mv nginx/ nginx-22.5.5/
cd nginx-22.5.5/
```

<code>values.yaml</code> を編集し、レプリカ数をデフォルトの1から2へ変更します。

```yaml
## @param replicaCount Number of NGINX replicas to deploy
##
replicaCount: 2
```

専用ネームスペースを作成し、ローカルディレクトリのチャートからデプロイを実行します。

```bash
kubectl create ns nginx
helm install nginx . --namespace=nginx
```

デプロイ状態およびレンダリングされたマニフェストの検証を行います。

```bash
helm ls -n nginx
helm get manifest nginx -n nginx
```

## Observabilityスタック（Prometheus / Grafana）の統合

Kubernetesクラスタの安定運用には、ノードおよびコンテナ層のメトリクス収集と可視化が不可欠です。本構成では以下のコンポーネントを連携させます。

* <b>Prometheus</b>: 時系列データベース（TSDB）およびメトリクスのPull型収集エンジン
* <b>Grafana</b>: PromQLを用いてPrometheusからデータを取得・描画するダッシュボード
* <b>Alertmanager</b>: アラート条件に合致した通知を外部システムへルーティング
* <b>kube-state-metrics</b>: APIサーバーを監視し、Kubernetesオブジェクトの状態をメトリクス化
* <b>cAdvisor</b>: Kubeletに組み込まれ、コンテナ単位のCPU・メモリリソース消費量を抽出
* <b>Node-Exporter</b>: ホストOSレベルのハードウェア・カーネルメトリクスを露出

### kube-prometheus-stackのデプロイ

Prometheus Communityの公式チャートを使用してスタック全体を一括展開します。

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
```

### ダッシュボードへのアクセス設定

Prometheus UIおよびGrafana Web UIへのポートフォワーディングを設定します。

```bash
# Prometheus UI ポートフォワード
kubectl port-forward --address 0.0.0.0 svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring

# Grafana管理者パスワードの取得
kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode ; echo

# Grafana UI ポートフォワード
kubectl port-forward --address 0.0.0.0 svc/monitoring-grafana 3000:80 -n monitoring
```

カスタムの設定値（例: NodePortでの露出）を適用する場合は、オーバーライド用の <code>custom.yaml</code> を作成してインストールします。

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
🛠️ <b>解決策</b>: <code>helm repo add &lt;name&gt; &lt;url&gt;</code> を実行し、対象のリポジトリを追加した後に <code>helm repo update</code> を行ってインデックスを更新します。

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
monitoring  monitoring  1           2026-07-27 10:15:22.123456789 +0900 KST deployed    kube-prometheus-stack-58.2.0 v0.72.0
```

## Configuration Notes

* 💡 <b>Helmの管理方針</b>: Helmを用いたチャート管理では、`values.yaml` のバックアップ（`values.yaml.bak`）を保持するか、Gitなどのリポジトリで管理してインフラの宣言的状態を維持してください。
* 💡 <b>データの永続化</b>: プロダクション環境においてマニフェスト直接定義のPrometheusを運用する場合は、`emptyDir` ではなく PersistentVolumeClaim (PVC) を割り当ててTSDB データの永続性を確保する必要があります。
* 💡 <b>スクレイピング間隔の最適化</b>: 大規模クラスタでは、cAdvisorおよびNode-Exporterのスクレイピング間隔（`scrape_interval`）を最適化し、PrometheusのストレージおよびCPU負荷を抑える設計を検討してください。</chart-name>
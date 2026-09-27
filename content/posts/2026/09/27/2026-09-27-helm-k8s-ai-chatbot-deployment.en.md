---
title: "Helm v3 Chart Configuration and GitOps Pipeline for Deploying a Healthcare AI Chatbot to Kubernetes"
slug: "helm-k8s-ai-chatbot-deployment"
date: 2026-09-27T10:08:25+09:00
draft: false
image: ""
description: "Explains the approach for securely and declaratively building an AI chatbot on Kubernetes using Helm v3 and ArgoCD, integrating with hospital EMR and using the OpenAI API."
categories: ["DevOps Logistics"]
tags: ["kubernetes", "helm3", "argocd", "ingress-nginx", "deployment"]
author: "K-Life Hack"
---

In container operations for healthcare systems, when deploying microservices that integrate with internal Electronic Medical Record (EMR) APIs and external AI engines, managing environment-specific configuration differences, certificate lifecycle control, and secure credential distribution are critical operational challenges. Manual manifest editing and individual virtual host configurations increase the risk of outages caused by human operational errors during node scaling or multi-environment deployments.


This article describes packaging and abstraction methods using Helm v3 for a healthcare AI chatbot (<code>ai-chatbot</code>), an in-memory token-sharing architecture, and configuration specifications for GitOps continuous deployment using ArgoCD.



## System Architecture and Topology Structure

The target workload communicates with an internal EMR endpoint (<code>https://emr.myhospital.co.kr/api</code>) inside the cluster and an external OpenAI API engine. This configuration separates the infrastructure tiers, declaratively controlling the Ingress responsible for TLS termination, the Service (ClusterIP) for intra-cluster routing, and the underlying Pod replicas using Helm.



```
ai-chatbot/
├── Chart.yaml             # Chart metadata and semantic versioning definitions
├── values.yaml            # Default variables and runtime parameters
└── templates/             # Kubernetes manifest templates
    ├── deployment.yaml    # Pod orchestration control
    ├── service.yaml       # Layer 4 internal network abstraction (ClusterIP)
    ├── ingress.yaml       # Layer 7 external routing and TLS termination configuration
    └── configmap.yaml     # External API configuration and system prompt definitions
```

## Core Template Design Specifications

### 1. Metadata Definition (`Chart.yaml`)

To guarantee compatibility with Helm 3, specify <code>apiVersion: v2</code> and configure semantic versioning for the application.



```yaml
apiVersion: v2
name: ai-chatbot
description: Helm chart for hospital AI chatbot
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 2. Environment Variables and Resource Definitions (`values.yaml`)

To simplify parameter changes based on the execution environment, CPU/memory requirements, replica counts, and Ingress hostnames are managed centrally in <code>values.yaml</code>.



```yaml
replicaCount: 2

image:
  repository: myregistry/ai-chatbot
  tag: latest
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  hostname: chatbot.myhospital.co.kr
  tls: true

resources:
  limits:
    cpu: "500m"
    memory: "512Mi"
  requests:
    cpu: "250m"
    memory: "256Mi"

env:
  EMR_API_URL: "https://emr.myhospital.co.kr/api"
  CHATBOT_LANG: "ko"
```

### 3. Workload Control Definition (`templates/deployment.yaml`)

Performs resource limiting and dynamic insertion of environment variables. Correctly apply the Helm template function <code>nindent</code> to prevent corruption of YAML indentation.



```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-chatbot
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: ai-chatbot
  template:
    metadata:
      labels:
        app: ai-chatbot
    spec:
      containers:
        - name: chatbot
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 3000
          env:
            - name: EMR_API_URL
              value: {{ .Values.env.EMR_API_URL | quote }}
            - name: CHATBOT_LANG
              value: {{ .Values.env.CHATBOT_LANG | quote }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

### 4. Internal Services and Ingress Exposure (`templates/service.yaml`, `templates/ingress.yaml`)

Traffic is forwarded from port 80 to container port 3000 using <code>service.yaml</code>, while SSL redirection and TLS termination via the NGINX Ingress Controller are applied using <code>ingress.yaml</code>.



```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-chatbot
spec:
  type: {{ .Values.service.type }}
  selector:
    app: ai-chatbot
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: 3000

```yaml

{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: {{ .Release.Name }}-chatbot
annotations:
nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
rules:
- host: {{ .Values.ingress.hostname }}
http:
paths:
- path: /
pathType: Prefix
backend:
service:
name: {{ .Release.Name }}-chatbot
port:
number: {{ .Values.service.port }}
{{- if .Values.ingress.tls }}
tls:
- hosts:
- {{ .Values.ingress.hostname }}
secretName: chatbot-tls
{{- end }}
{{- end }}

```

### 5. OpenAI 設定用 ConfigMap (`templates/configmap.yaml`)

モデル識別子やプロンプトパラメータをアプリケーション本体から切り離して外部化します。

```yaml

apiVersion: v1
kind: ConfigMap
metadata:
name: {{ .Release.Name }}-chatbot-config
labels:
app: ai-chatbot
data:
OPENAI_MODEL: "gpt-4o"
OPENAI_MAX_TOKENS: "2048"
OPENAI_TEMPERATURE: "0.2"
SYSTEM_PROMPT: |
You are an AI assistant designed for hospital settings.
You assist medical personnel and patients by answering queries based on the hospital's EMR dataset.
Always operate under medical protocol standards.

```

## EMR 認証トークン統合パターン

医療データ（PHI）の流出を防止するため、EMRアクセストークンは永続ストレージではなくメモリ上にのみ保持する設計を採用します。

* <b>Sidecar/InitContainer パターン</b>: 認証サイドカーがEMR認証サーバー（`https://emr.myhospital.co.kr`）から短寿命JWTトークンを取得します。
* <b>In-Memory ボリューム (`tmpfs`)</b>: 取得したトークンは `medium: Memory` で構成された `emptyDir` ボリューム（`/var/run/secrets/emr`）に書き込まれ、メインのチャットボットコンテナから参照されます。
* <b>動的トークン更新</b>: チャットボットアプリケーション層のOAuth2クライアントモジュールが定期的にトークンの有効期限を検証し、Podを再起動することなくメモリ上のJWTを透過的に更新します。

## GitOps パイプライン構成 (`argocd-application.yaml`)

ArgoCDを用いてGitリポジトリの状態とクラスタの実体を自動同期します。

```yaml

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
name: ai-chatbot-prod
namespace: argocd
finalizers:
- resources-finalizer.argocd.argoproj.io
spec:
project: default
source:
repoURL: 'https://github.com/myhospital-org/helm-charts.git'
targetRevision: HEAD
path: ai-chatbot
helm:
valueFiles:
- values.yaml
destination:
server: 'https://kubernetes.default.svc'
namespace: ai-services
syncPolicy:
automated:
prune: true
selfHeal: true
syncOptions:
- CreateNamespace=true

```

## トラブルシューティング 🛠️

### 1. `nindent` 関数適用不備による YAML パースエラー

* <b>現象</b>: `helm template` 実行時に `error converting YAML to JSON: yaml: line X: did not find expected key` が発生します。
* <b>原因</b>: `deployment.yaml` 内の `resources:` ブロック直下で `nindent` のインデント数が合致していない場合、構文エラーが発生します。
* <b>対策</b>: `{{- toYaml .Values.resources | nindent 12 }}` のように、`resources` キーの配下に入る正確なスペース数（12スペース）を正しく指定します。

### 2. Ingress の TLS Secret 不整合による 502/SSL エラー

* <b>現象</b>: 外部からHTTPSアクセス時にデフォルトのKubernetes Ingress Fake Certificateが返却され、接続が拒否されます。
* <b>原因</b>: `values.yaml` で定義した `chatbot-tls` Secretが対象のネームスペースに存在しない、またはIngressのhost名と証明書のSAN（Subject Alternative Name）が一致していません。
* <b>対策</b>: 証明書管理コンポーネント（cert-manager等）を用いて、ターゲットネームスペース（`ai-services`）内に正しく `chatbot-tls` が生成されているかを検証します。

### 3. メモリバックド emptyDir の書き込み権限エラー

* <b>現象</b>: サイドカーコンテナからトークンファイル書き込み時に `Permission denied` が発生し、Podが `CrashLoopBackOff` に陥ります。
* <b>原因</b>: セキュリティコンテキストで非rootユーザー実行を定義している際、マウントされた `emptyDir` ボリュームのオーナー権限が一致していません。
* <b>対策</b>: `securityContext` の `fsGroup` 設定をPod仕様に追加し、書き込み権限を持つGIDを明示的に割り当てます。

## 動作検証および検証ログ

デプロイメント完了後、以下の検証用ターミナルコマンドを実行してオブジェクトの正常性を確認します。

```text

$ helm status chatbot -n ai-services
NAME: chatbot
LAST DEPLOYED: Sun Sep 27 10:15:22 2026
NAMESPACE: ai-services
STATUS: deployed
REVISION: 1
TEST SUITE: None

$ kubectl get pods -n ai-services -l app=ai-chatbot -o wide
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
chatbot-ai-chatbot-67f9b87c-x92zk 1/1 Running 0 2m 10.244.1.45 k8s-worker-01 <none> <none>
chatbot-ai-chatbot-67f9b87c-z4l8p 1/1 Running 0 2m 10.244.2.89 k8s-worker-02 <none> <none>

$ kubectl get ingress -n ai-services
NAME CLASS HOSTS ADDRESS PORTS AGE
chatbot-ai-chatbot nginx chatbot.myhospital.co.kr 192.168.1.100 80, 443 2m

$ curl -I -sS https://chatbot.myhospital.co.kr/
HTTP/2 200
server: nginx/1.25.3
date: Sun, 27 Sep 2026 10:17:45 GMT
content-type: text/html; charset=utf-8
strict-transport-security: max-age=15724800; includeSubDomains

```

## 設定上の留意事項 💡

1. <b>リソース制限の調整</b>: EMR応答の解析処理によりスパイクアクセスが発生する場合、`values.yaml` の `resources.limits.cpu` をノードのコア数に応じて適切にチューニングしてください。
2. <b>プロンプト情報の管理</b>: ConfigMap内のシステムプロンプトの更新はPodの自動再起動を誘発しないため、設定反映にはArgoCDによるローリングアップデートまたはPodの再作成を伴う運用を推奨します。
3. <b>ネットワークポリシー</b>: 医療データを取り扱う性質上、`ai-services` ネームスペースに対してEMR認証エンドポイントおよびIngress以外の外部アウトバウンド通信を制限するNetworkPolicyの併用を推奨します。</none></none></none></none>
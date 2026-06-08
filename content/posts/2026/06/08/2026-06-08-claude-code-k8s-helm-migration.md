---
title: "Claude CodeによるKubernetesマニフェ生成とHelm移行の自動化"
slug: "claude-code-k8s-helm-migration"
date: 2026-06-08T18:03:25+09:00
draft: false
image: ""
description: "Claude Codeを用いてKubernetesマニフェ生成を自動化し、Helmチャートへ移行する際の実践的なワークフローと設定手法を解説します。"
categories: ["DevOps Logistics"]
tags: ["kubernetes", "helm", "gke", "claude-code", "devops", "yaml-automation"]
author: "K-Life Hack"
---

Kubernetesの運用において、手動によるマニフェスト（YAML）の作成と管理は、ヒューマンエラーの温床となりやすく、多くの時間を消費します。本稿では、AIエージェントであるClaude Codeを活用し、Google Kubernetes Engine（GKE）環境を対象としたマニフェスト生成の自動化、および静的なYAMLからHelmチャートへの移行プロセスを技術的に分析します。

## 1. コンテキストの永続化：CLAUDE.mdの定義

AIによる生成の精度を維持し、セッションごとに同一の制約を適用するためには、プロジェクトルートに<b>CLAUDE.md</b>を配置することが不可欠です。これにより、クラスタ固有の規約や命名規則、デプロイメント戦略をAIに事前学習させ、一貫性のある出力を担保します。

```markdown
# CLAUDE.md Configuration for GKE

- Cluster Provider: GKE (Google Kubernetes Engine)
- Region: asia-northeast3 (Seoul)
- Namespace Convention: {app}-{environment}
- Resource Management: Always define both requests and limits.
- Image Registry: gcr.io/my-project/
- Mandatory Labels: app, env, version
- Health Checks: Liveness and Readiness probes are mandatory.
- High Availability: Pod anti-affinity for multi-AZ distribution.
```

## 2. 自動化されたデプロイメント生成

Claude Codeに対し、具体的なリソース要件や環境変数を指示することで、本番環境のワークロードに耐えうるマニフェストを生成します。例えば、Node.js APIサービスの場合、リソース制限（Requests/Limits）、Liveness/Readinessプローブ、ポッド間のアフィニティ設定を含む高度なYAMLが即座に構成されます。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: payments-prod
  labels:
    app: api
    env: production
    version: v1.2.0
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - api
              topologyKey: "topology.kubernetes.io/zone"
      containers:
      - name: api-container
        image: gcr.io/my-project/api:v1.2.0
        ports:
        - containerPort: 3000
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 30
```

内部的な検証によれば、このような生成プロセスを導入することで、手動作成と比較してマニフェスト構築時間を大幅に短縮可能です。また、<code>kubectl apply --dry-run=client</code>による事前バリデーションにおいて、構文エラーの発生率を極限まで低減できることが確認されています。

## 3. Helmチャートへの移行ワークフロー

静的なYAMLファイルを再利用可能なHelmチャートへ変換するプロセスは、以下のステップで構造化されます。Claude Codeは既存のYAMLを解析し、環境ごとに動的な変更が必要なパラメータを特定します。

1. <b>パラメータ化</b>: イメージタグ、レプリカ数、リソース制限などの可変要素を<code>values.yaml</code>に抽出します。
2. <b>ディレクトリ構造の構築</b>: <code>Chart.yaml</code>および<code>templates/</code>ディレクトリを自動生成し、標準的なHelmレイアウトを構成します。
3. <b>ヘルパー関数の定義</b>: 共通ラベルや命名規則を統一管理するための<code>_helpers.tpl</code>を作成し、保守性を向上させます。

生成される標準的なディレクトリ構造の構成例です。

```text
helm/api/
├── Chart.yaml
├── values.yaml
├── values-prod.yaml
├── values-staging.yaml
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── _helpers.tpl
```

## 4. クラスタのトラブルシューティングと最適化

Claude Codeは、単なるコード生成にとどまらず、実行中のクラスタに対する診断エージェントとしても機能します。<code>kubectl</code>の実行結果をコンテキストとして渡すことにより、障害の根本原因分析と修正案の提示を迅速に実行します。

🛠️ <b>CrashLoopBackOffの解析</b>: <code>kubectl describe pod</code>のイベントログから、OOMKilled（メモリ不足）やシークレットの参照エラーを特定し、修正パッチを生成します。
💡 <b>リソースの最適化</b>: <code>kubectl top pods</code>のメトリクスを基に、実際のCPU/メモリ使用率に適合した<code>requests</code>の調整案を提示し、クラスタのコスト効率を最大化します。

## 5. セキュリティとネットワーク制御

セキュリティの担保として、Claude Codeは最小特権の原則（Principle of Least Privilege）に基づいた<code>NetworkPolicy</code>を生成します。これにより、特定のNamespaceやラベルを持つポッド間のみの通信を許可するゼロトラストなネットワーク構成が容易に実装可能です。

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-ingress
  namespace: payments-prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  egress:
  - to:
    - ports:
      - protocol: TCP
        port: 5432
```

## Configuration Notes

AIによる自動生成は極めて強力なツールですが、本番環境への適用前には必ず<code>--dry-run</code>による検証と、生成されたマニフェストに対するエンジニアのピアレビューが必須となります。また、<code>CLAUDE.md</code>に記述する制約（例：特定のIngressコントローラーの使用、アノテーションの必須化）が具体的であるほど、生成物の精度と環境適合性は向上します。マルチクラウド環境（EKS, AKS等）への対応が必要な場合は、クラウドプロバイダー固有のアノテーション設定をコンテキストに追加することで、柔軟なマルチプラットフォーム展開が可能になります。
---
title: "NCP Developer ToolsによるKubernetes CI/CDパイプラインの構築と運用最適化"
slug: "ncp-k8s-cicd-pipeline-implementation"
date: 2026-07-19T10:06:09+09:00
draft: false
image: ""
description: "Naver Cloud PlatformのSourceCommit、SourceBuild、SourceDeploy、SourcePipelineを統合し、NKS環境への自動デプロイを実現するCI/CDパイプラインの構築手法と、ビルド高速化・承認フローの設計について解説します。"
categories: ["DevOps Logistics"]
tags: ["ncp-sourcecommit", "nks-deployment", "docker-build-cache", "cicd-pipeline", "kubernetes-loadbalancer"]
author: "K-Life Hack"
---

# NCP Developer Toolsを活用したNKS CI/CDパイプラインの構築

クラウドネイティブなインフラストラクチャにおいて、手動によるデプロイ作業は環境の不一致やヒューマンエラーを誘発する大きな要因となります。特にマイクロサービスアーキテクチャでは、コンテナイメージのビルドからKubernetes（NKS）へのデプロイまでを抽象化し、一貫したパイプラインで管理することが、リリースの信頼性を確保するために不可欠です。本稿では、Naver Cloud Platform（NCP）のDeveloper Toolsスイートを活用し、ソースコードの変更をトリガーとしたエンドツーエンドのCI/CDパイプラインを構築する実務的な手法について詳述します。

## 1. アーキテクチャの構成要素

NCP Developer Toolsは、以下の4つのマネージドサービスで構成され、SDLC（Software Development Life Cycle）全体をカバーします。

SourceCommitはプライベートGitリポジトリであり、GitHub等からの移行もサポートします。SourceBuildは並列ビルドが可能なマネージドサービスで、Dockerイメージの作成とContainer Registryへのプッシュを担当します。SourceDeployはNKSやサーバー群への自動デプロイを行い、ローリングアップデート等の戦略をサポートします。SourcePipelineは、これらのプロセスを統合し、ワークフローを自動化するオーケストレーターとして機能します。

## 2. SourceCommit：リポジトリの移行と認証設計

外部リポジトリ（GitHub等）からSourceCommitへ移行する際、認証情報の管理が最初の摩擦点となります。プライベートリポジトリのコピーには、標準のパスワードではなく、GitHubのPersonal Access Token（PAT）の使用が必須です。

運用担当者には<b>NCP_SOURCECOMMIT_MANAGER</b>ポリシーを割り当て、コンソール上で専用のGitパスワードを設定する必要があります。これにより、HTTPS経由でのセキュアなクローンとプッシュが可能になります。

## 3. SourceBuild：コンテナイメージの構築と最適化

SourceBuildでは、Ubuntu 16.04等のベースランタイム上でDockerビルドを実行します。ここでは、アプリケーションの依存関係を解決し、軽量なイメージを作成する構成が求められます。

```dockerfile
FROM python:3.9-slim

WORKDIR /app

# 依存関係のインストール（キャッシュ効率化のため先にコピー）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
```

ビルドプロジェクトの設定では、latestタグと併せて、ビルド番号（#シンボルを使用）によるバージョニングを有効にすることで、ロールバックの容易性を確保します。

## 4. SourceDeploy：NKSへのデプロイメント戦略

SourceDeployは、Kubernetesマニフェスト（Deployment/Service）をNKSクラスタに適用します。ダウンタイムを最小化するため、通常はローリングアップデート戦略を選択します。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: flask-app
        image: <your-ncr-endpoint>/flask-app:latest
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app-service
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 5000
  selector:
    app: flask-app
```

## 5. SourcePipelineによる自動化とガバナンス

SourcePipelineでSourceCommitのmasterブランチへのプッシュをトリガーに設定することで、コード修正から本番反映までを完全自動化します。本番環境へのデプロイにおいては、requestDeploy権限を持つユーザーによる「承認フロー」を組み込むことで、ガバナンスを強化することが推奨されます。

## Troubleshooting

⚠️ <b>認証エラー (401 Unauthorized)</b>: SourceCommitへのプッシュ時に発生する場合、サブアカウントで設定したGitパスワードが正しく入力されているか確認してください。GitHubからのコピー時はPATの有効期限とスコープ（repo）を確認する必要があります。

🛠️ <b>ビルド時間の増大</b>: requirements.txtのパッケージダウンロードがボトルネックになる場合、SourceBuildの「ビルド完了後のイメージアップロード」機能を活用し、依存関係が含まれたビルド環境自体をキャッシュイメージとしてContainer Registryに保存、次回のビルドでカスタムイメージとして使用することで大幅に短縮可能です。

💡 <b>イメージプルエラー (ErrImagePull)</b>: NKSがContainer Registryからイメージを取得できない場合、レジストリのエンドポイントURLがマニフェスト内で正確に記述されているか、およびNKSクラスタに適切なアクセス権限が付与されているかを確認してください。

## Verification

デプロイ完了後、以下のコマンドを使用してクラスタの状態とアプリケーションの応答を確認します。

```text
# Podのステータス確認
$ kubectl get pods -l app=flask-app
NAME                                    READY   STATUS    RESTARTS   AGE
flask-app-deployment-5f7d8b9c4d-abc12   1/1     Running   0          3m
flask-app-deployment-5f7d8b9c4d-def34   1/1     Running   0          3m
flask-app-deployment-5f7d8b9c4d-ghi56   1/1     Running   0          3m

# LoadBalancerの外部IP取得
$ kubectl get svc flask-app-service
NAME                TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
flask-app-service   LoadBalancer   10.100.1.50    1.2.3.4          80:32000/TCP   5m

# アプリケーションの応答確認
$ curl -s http://1.2.3.4 | jq .
{
  "pod_ip": "172.16.0.10",
  "pod_name": "flask-app-deployment-5f7d8b9c4d-abc12",
  "timestamp": "2026-07-19T10:00:00Z",
  "uri": "/"
}
```

## Operational Notes

NCP Developer Toolsを統合することで、インフラ構成のコード化（IaC）とアプリケーションの継続的デリバリーが高度に同期されます。特に、ビルドキャッシュの活用と承認プロセスの導入は、開発速度と安全性のトレードオフを解決する鍵となります。プロジェクトの規模に応じて、SourceBuildのコンピュートタイプを調整し、リソース効率を最適化することを推奨します。</your-ncr-endpoint>
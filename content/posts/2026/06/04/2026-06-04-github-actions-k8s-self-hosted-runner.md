---
title: "GitHub ActionsとSelf-Hosted RunnerによるKubernetesデプロイ自動化の実装"
slug: "github-actions-k8s-self-hosted-runner"
date: 2026-06-04T18:02:34+09:00
draft: false
image: ""
description: "GitHub ActionsとSelf-Hosted Runnerを組み合わせ、ローカルKubernetes環境への自動デプロイを実現するプロセスと、PEMパースエラーやネットワーク解決などの実務的なトラブルシューティングを解説します。"
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "ci-cd", "docker-desktop"]
author: "K-Life Hack"
---

## 1. 概要と目的

GitHub ActionsとローカルのKubernetes環境を統合し、ソースコードのプッシュからデプロイまでを完全に自動化するCI/CDパイプラインを構築します。手動介入を排除し、ローリングアップデートを自動的に実行するワークフローの確立を目的とします。

<b>ターゲットワークフロー:</b>
1. <b>Git Push:</b> 開発者が `master` ブランチへコードをプッシュ。
2. <b>Docker Build:</b> GitHub Actionsがコンテナイメージのビルドをトリガー。
3. <b>Docker Push:</b> ビルドされたイメージをDockerHub等のレジストリへプッシュ。
4. <b>Kubernetes Update:</b> クラスターが新しいイメージをプルし、ローリングアップデートを実行。

## 2. Kubernetes接続の確立と認証設定

GitHub Actionsが外部からクラスターを操作するためには、適切な認証情報（kubeconfig）の定義が不可欠です。

### 2.1 Kubeconfigの抽出

まず、ローカル環境で現在の接続情報を確認し、必要なデータを抽出します。

```bash
kubectl config view
```

このコマンドから出力されるYAML構造には、クラスターのサーバーURL、証明書データ、およびユーザーコンテキストが含まれます。これをGitHub Secretsに登録しますが、単純なコピー＆ペーストでは改行コードやインデントの崩れにより、PEMブロックのパースエラーが発生するリスクがあります。

### 2.2 Base64エンコーディングによるデータ保護

証明書データの整合性を保つため、kubeconfigファイルをBase64でエンコードしてからGitHub Secretsに登録する手法を採用します。

```powershell
# Windows PowerShell環境での実行例
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\Administrator\.kube\config"))
```

取得した文字列をGitHubリポジトリの `Settings > Secrets and variables > Actions` に `KUBE_CONFIG` という名前で保存します。💡 <b>Base64エンコード</b>は、CI環境におけるバイナリデータの破損を防ぐための標準的なプラクティスです。

## 3. ワークフローの定義とトラブルシューティング

### 3.1 初期ワークフロー構成 (`.github/workflows/docker-build.yml`)

イメージのビルド、プッシュ、およびデプロイを一貫して実行する初期の定義を構成します。

```yaml
name: Build and Deploy
on:
  push:
    branches:
      - master

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Docker Login
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      - name: Build Docker Image
        run: |
          docker build -t ${{ secrets.DOCKER_USERNAME }}/my-tomcat:latest .

      - name: Push Docker Image
        run: |
          docker push ${{ secrets.DOCKER_USERNAME }}/my-tomcat:latest

      - name: Set kube config
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d > ~/.kube/config

      - name: Deploy to Kubernetes
        run: |
          kubectl rollout restart deployment tomcat-deployment
```

### 3.2 PEMパースエラーの解決

GitHub Actionsのログに `error: unable to load root certificates: unable to parse bytes as PEM block` が出力される場合、Secretsからデコードされたファイル形式が不正である可能性が高いです。⚠️ 前述のBase64エンコード手法を適用し、ワークフロー内で `base64 -d` を用いて復元することで、この問題を確実に回避できます。

## 4. Self-Hosted Runnerの導入

### 4.1 ネットワーク境界の課題

GitHubが提供するホスト型ランナー（ubuntu-latest等）を使用する場合、ローカル環境のDocker Desktop（`kubernetes.docker.internal`）への名前解決ができず、接続エラーが発生します。

```text
Unable to connect to the server: dial tcp: lookup kubernetes.docker.internal: no such host
```

この課題を解決するため、ローカルネットワーク内で動作する <b>Self-Hosted Runner</b> を導入し、内部リソースへの直接アクセスを可能にします。

### 4.2 Windows環境へのインストール手順

GitHubリポジトリの `Settings > Actions > Runners` から「New self-hosted runner」を選択します。OSに「Windows」を指定し、提供されるPowerShellスクリプトを実行してランナーを構成します。

```powershell
# ランナーの配置と設定
mkdir actions-runner; cd actions-runner
# (GitHubから提供されるトークンを使用して設定を実行)
.\config.cmd --url https://github.com/[USER]/[REPO] --token [TOKEN]
.\run.cmd
```

### 4.3 ワークフローの修正

ランナーの指定を `self-hosted` に変更し、ローカル環境でのジョブ実行を有効化します。

```yaml
runs-on: self-hosted
```

## 5. クロスプラットフォームにおけるコマンドの互換性

Windows上のランナーでシェルを実行する場合、Linux標準の `mkdir -p` 等のコマンドが失敗することがあります。🛠️ PowerShellの構文に合わせてステップを調整し、環境依存のエラーを排除する必要があります。

```yaml
- name: Set kube config
  shell: powershell
  run: |
    if (!(Test-Path "$HOME\.kube")) {
      New-Item -ItemType Directory -Path "$HOME\.kube"
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("${{ secrets.KUBE_CONFIG }}")) | Out-File "$HOME\.kube\config"
```

## 6. ErrImagePullの解析とマニフェストの調整

デプロイ後にPodが `ErrImagePull` 状態になる場合、以下の要因を検証する必要があります。

1. <b>レジストリへのプッシュ失敗:</b> イメージがDockerHubに正しく存在するか確認。
2. <b>Pull Policyの不一致:</b> `imagePullPolicy: Always` が設定されている場合、ローカルにイメージが存在しても常に外部レジストリからの取得を試みます。

開発環境においてローカルキャッシュのイメージを優先的に使用する場合は、`Deployment.yaml` を以下のように修正します。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tomcat2-deployment
spec:
  template:
    spec:
      containers:
      - name: tomcat
        image: abungard/my-tomcat:latest
        imagePullPolicy: IfNotPresent
```

## 7. 結論と今後の展望

今回の実装を通じて、GitHub Actionsを用いたCI/CDパイプライン構築における重要な知見が得られました。特に、証明書データのBase64による保護は、CI環境での認証エラーを防ぐための極めて有効な手段です。また、ローカル環境へのデプロイにおいては、ネットワークの到達性を確保するためにSelf-Hosted Runnerが不可欠であることを再確認しました。今後は、`latest` タグの運用からGit SHAを用いたバージョン管理への移行、およびArgoCD等のGitOpsツールの導入を検討し、より堅牢なデプロイフローの構築を目指します。
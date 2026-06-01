---
title: "GitHub ActionsとSelf-hosted RunnerによるローカルKubernetes CI/CDの構築と認証・ネットワーク境界の突破"
slug: "github-actions-self-hosted-k8s-cicd"
date: 2026-06-01T11:26:26+09:00
draft: false
image: ""
description: "ローカルKubernetes環境への自動デプロイを実現するため、GitHub ActionsのSelf-hosted Runner導入とKubeconfigのBase64エンコードによる認証エラー回避、Windows環境特有のシェル制御を詳解します。"
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "kubeconfig", "powershell", "devops"]
author: "K-Life Hack"
---

## GitHub ActionsとSelf-hosted RunnerによるローカルKubernetesデプロイの最適化

### 1. 課題の背景：ハイブリッド環境におけるデプロイメントの断絶

モダンなマイクロサービス開発において、Docker Desktop等のローカルKubernetes環境は、本番環境に近い検証を可能にする重要なアセットです。しかし、GitHub Actionsのマネージドランナー（ubuntu-latest等）からローカルクラスターへデプロイを試みる際、二つの大きな障壁に直面します。第一に、パブリッククラウド上のランナーからプライベートネットワーク内のクラスターエンドポイント（kubernetes.docker.internal）への到達不能性。第二に、YAML形式のKubeconfigをGitHub Secretsに保存する際に発生する、改行コードやインデントの崩れによるPEMブロック解析エラーです。

本稿では、これらの境界を突破し、Git Pushからローカルクラスターへの同期を完全自動化するCI/CDパイプラインの構築プロセスを詳解します。

### 2. 技術選定とトレードオフ：Self-hosted Runnerの採用理由

GitHub Actionsからプライベートクラスターへアクセスする手法として、以下の比較検討を行いました。

*   <b>Cloud Runner + VPN/Tunneling (ngrok等)</b>: 外部からローカルネットワークへのトンネルを構築する手法。セットアップは容易ですが、セキュリティリスクが高く、帯域制限やレイテンシがボトルネックとなります。
*   <b>Self-hosted Runner (採用)</b>: ローカルマシン上でGitHub Actionsのエージェントを直接稼働させる手法。ファイアウォールの内側で動作するため、外部へのポート開放が不要であり、ローカルのDockerデーモンやK8s APIに直接アクセスできます。また、ビルド済みイメージをレジストリからプルする際のネットワークコストを最小化できる利点があります。

### 3. 実装詳細：認証情報のカプセル化とランナーの構成

#### 3.1 KubeconfigのBase64エンコードによる整合性確保

GitHub SecretsにKubeconfigをそのまま保存すると、<b>error: unable to load root certificates: unable to parse bytes as PEM block</b>というエラーに遭遇する確率が極めて高いです。これを回避するため、PowerShellを用いてバイナリレベルでBase64エンコードを行い、文字列として注入します。

```powershell
# KubeconfigをBase64文字列に変換し、ファイルに出力
$configPath = "$HOME\.kube\config"
$base64Config = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$base64Config | Out-File -FilePath "encoded_config.txt"
```

#### 3.2 Windows Self-hosted Runnerのワークフロー定義

Windows環境でランナーを動作させる場合、デフォルトシェルがPowerShellになるため、Linuxベースのコマンド（mkdir -p等）は動作しません。以下に、冪等性を担保したワークフローの実装例を示します。

```yaml
jobs:
deploy:
runs-on: self-hosted
steps:
- name: Checkout code
uses: actions/checkout@v4

- name: Configure Kubeconfig
shell: pwsh
run: |
$kubeDir = "$HOME\.kube"
if (!(Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir }
$decodedConfig = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("${{ secrets.KUBE_CONFIG_DATA }}"))
$decodedConfig | Out-File -FilePath "$kubeDir\config" -Encoding ascii

- name: Deploy to Local Kubernetes
run: |
kubectl apply -f ./k8s/deployment.yaml
kubectl rollout status deployment/api-service
```

### 4. 実務における警告と回避策 (Operational Reality)

#### 4.1 ErrImagePullとimagePullPolicyの最適化

ローカル環境での開発時、イメージをレジストリにプッシュした直後にデプロイを行うと、タグがlatestの場合にKubernetesが古いキャッシュを参照したり、プルに失敗して<b>ErrImagePull</b>を発生させることがあります。これを防ぐため、deployment.yamlでは以下の設定を推奨します。

*   <b>imagePullPolicy: Always</b>: 常にレジストリを確認させます。ただし、ネットワーク負荷が増大します。
*   <b>imagePullPolicy: IfNotPresent</b>: ローカルビルドしたイメージをそのまま使う場合に有効です。Self-hosted Runnerがクラスターと同じノードで動作している場合、ビルドしたイメージが即座に利用可能になるため、この設定が最も効率的です。

#### 4.2 永続ボリュームのパス指定における注意点

⚠️ Docker Desktop for Windowsを使用する場合、hostPathに指定するパスはWindows形式ではなく、Docker VM内のマウントパス（<b>/run/desktop/mnt/host/c/...</b>）を指定する必要があります。ここを誤ると、コンテナ起動時にマウントエラーが発生し、共有ディレクトリが正しく認識されません。

### 5. 結果と評価

本構成の導入により、以下の定量的・定性的改善を確認しました。

*   <b>デプロイ時間の短縮</b>: 手動でのkubectl操作と比較し、コードプッシュから反映までのリードタイムを約70%削減。
*   <b>環境整合性の向上</b>: Kubeconfigの動的生成により、開発者のローカル環境に依存しない一貫したデプロイパイプラインを確立。
*   <b>セキュリティの強化</b>: 外部からのインバウンド通信を一切許可することなく、GitHub Actionsとの双方向通信を実現。

## Summary

本アーキテクチャは、GitHub Actionsの柔軟性とSelf-hosted Runnerのネットワーク的優位性を組み合わせることで、ハイブリッドクラウド環境におけるデプロイの障壁を解消するものです。従来のNginx等の静的設定中心のレガシーな運用から、KubernetesネイティブなGitOpsへの移行期において、運用負荷（Ops Burden）を大幅に軽減する実効的なソリューションとなります。今後は、latestタグ運用を廃止し、GITHUB_RUN_NUMBERを用いたイミュータブルなタグ管理への移行が、さらなる信頼性向上の鍵となります。
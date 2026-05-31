---
title: "GitHub ActionsとWindows Self-Hosted RunnerによるKubernetesデプロイ自動化時のエラー解決"
slug: "github-actions-windows-runner-kubernetes"
date: 2026-05-22T13:53:12+09:00
draft: false
image: ""
description: "Windows環境のSelf-Hosted RunnerとGitHub Actionsを連携し、Kubernetesへのデプロイ時に発生するPEMブロック解析エラー、DNS解決失敗、PowerShell構文エラーを解決する手順。"
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "powershell", "kubeconfig"]
author: "K-Life Hack"
---

## 🛠️ KubeconfigのPEMブロック解析エラー（unable to parse bytes as PEM block）の解決

GitHub Actionsのワークフロー実行時に、Kubernetesクラスターへの認証処理で以下のエラーが発生しました。

```
error: unable to load root certificates: unable to parse bytes as PEM block
Error: Process completed with exit code 1.
```

### 発生原因

GitHub Secretsにローカルの <b><mark>kubeconfig</mark></b> ファイルのYAMLテキストを直接コピー＆ペーストして保存した際、改行コード（\n と \r\n）の不整合やインデントの崩れ、Base64エンコードされた証明書データの末尾欠損が発生し、証明書データ（PEM形式）のパースに失敗しました。

### 修正手順

データの破損を防ぐため、Windows環境の kubeconfig ファイルをBase64文字列にエンコードしてからGitHub Secretsに登録します。

1. WindowsのPowerShellを開き、以下のコマンドを実行して kubeconfig をBase64エンコードします。

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes(\"C:\\Users\\Administrator\\.kube\\config\"))
```

出力された1行の長いBase64文字列をコピーします。

2. GitHubリポジトリの「Settings」→「Secrets and variables」→「Actions」から、既存の `KUBE_CONFIG` を削除し、コピーしたBase64文字列を新しい値として再登録します。

3. ワークフローファイル（`.github/workflows/docker-build.yml`）のデコード処理を以下のように修正します。

```yaml
      - name: Set kube config
        run: |
          mkdir -p ~/.kube
          echo \"${{ secrets.KUBE_CONFIG }}\" | base64 -d &gt; ~/.kube/config
```

---

## 🛠️ クラウドラナーからのDNS解決失敗（kubernetes.docker.internal:6443: no such host）の解決

証明書エラーの解決後、デプロイステップで以下のネットワークタイムアウトおよびDNS解決エラーが発生しました。

```
E0528 01:43:09.437587    2260 memcache.go:265] \"Unhandled Error\" err=\"couldn't get current server API group list: Get \\\"https://kubernetes.docker.internal:6443/api?timeout=32s\\\": dial tcp: lookup kubernetes.docker.internal on 127.0.0.53:53: no such host\"
Unable to connect to the server: dial tcp: lookup kubernetes.docker.internal on 127.0.0.53:53: no such host
```

### 発生原因

GitHub Actionsの標準ホストランナー（`runs-on: ubuntu-latest`）は、GitHubが提供するクラウド上の仮想マシンで実行されます。そのため、ローカル開発環境（Docker Desktop）のプライベートDNSである `kubernetes.docker.internal` を解決できず、ローカルのKubernetes APIサーバーにルーティングできません。

### 修正手順

ローカルネットワーク内のリソースに直接アクセスするため、ローカルマシン上に <b><mark>Self-Hosted Runner</mark></b> を構築します。

1. GitHubリポジトリの「Settings」→「Actions」→「Runners」から「New self-hosted runner」を選択し、OSに「Windows」を指定します。

2. ローカルのPowerShellで以下のコマンドを実行し、ランナーパッケージをダウンロードして展開します。

```powershell
mkdir actions-runner
cd actions-runner
Invoke-WebRequest -Uri https://github.com/actions/runner/releases/download/v2.334.0/actions-runner-win-x64-2.334.0.zip -OutFile actions-runner-win-x64-2.334.0.zip
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory(\"$PWD/actions-runner-win-x64-2.334.0.zip\", \"$PWD\")
```

3. 画面に表示されたトークンを使用してランナーを登録します。

```powershell
.\\config.cmd --url https://github.com/giturl-id/tomcat-k8s --token <your_token>
```

4. ランナーを起動します。

```powershell
.\\run.cmd
```

5. ワークフローファイルの実行環境ターゲットを修正します。

```yaml
# 変更前
runs-on: ubuntu-latest

# 変更後
runs-on: self-hosted
```

---

## 🛠️ Windows環境でのmkdir -pコマンド実行エラーの解決

実行環境をWindowsのSelf-Hosted Runnerに切り替えた際、ディレクトリ作成ステップで以下のエラーが発生しました。

```
mkdir : An item with the specified name C:\\Users\\Administrator\\.kube already exists.
At C:\\study\\tomcat\\actions-runner\\_work\\_temp\\836d0b14-98fc-4377-a457-faf5123b7885.ps1:2 char:1
+ mkdir -p ~/.kube
+ ~~~~~~~~~~~~~~~
    + CategoryInfo          : ResourceExists: (C:\\Users\\Administrator\\.kube:String) [New-Item], IOException
    + FullyQualifiedErrorId : DirectoryExist,Microsoft.PowerShell.Commands.NewItemCommand
```

### 発生原因

WindowsのSelf-Hosted Runnerでは、GitHub ActionsのステップがデフォルトでPowerShell上で実行されます。PowerShellにおいて `mkdir` は `New-Item -ItemType Directory` のエイリアスであり、`-p` オプションが存在しません。また、作成対象のディレクトリが既に存在する場合、PowerShellは `IOException` をスローして終了コード `1` で異常終了します。

### 修正手順

PowerShellのネイティブ構文を使用し、ディレクトリの存在確認を行ってから作成するロジックに変更します。また、Base64のデコード処理も.NETのランタイム機能を使用してPowerShell内で完結させます。

```yaml
      - name: Set kube config
        shell: powershell
        run: |
          if (!(Test-Path \"$HOME\\.kube\")) {
              New-Item -ItemType Directory -Path \"$HOME\\.kube\"
          }
          
          [System.Text.Encoding]::UTF8.GetString(
              [System.Convert]::FromBase64String(\"${{ secrets.KUBE_CONFIG }}\")
          ) | Out-File \"$HOME\\.kube\\config\" -Encoding utf8
```

---

## 🛠️ Kubernetesポッドのイメージプルエラー（ErrImagePull）の解決

デプロイ実行後、ポッドのステータスが `ErrImagePull` となり、コンテナが起動しない現象が発生しました。

```bash
kubectl get pods
# 出力結果:
# NAME                                  READY   STATUS         RESTARTS   AGE
# tomcat2-deployment-59d4ff8df8-cwwb2   0/1     ErrImagePull   0          9s
```

### 発生原因

マニフェストファイル（`Deployment.yaml`）内の `imagePullPolicy` が `Always` に設定されているため、ローカルのDockerキャッシュにイメージが存在する場合でも、Kubernetesは外部レジストリ（DockerHubなど）へ最新イメージの問い合わせを強制します。イメージがリモートレジストリにプッシュされていない、または認証情報が不足している場合、このプル処理が失敗します。

### 修正手順

開発環境においてローカルビルドしたイメージを直接使用する場合、`imagePullPolicy` を `IfNotPresent` に変更して外部レジストリへの問い合わせをスキップさせます。

1. `Deployment.yaml` のコンテナ定義を以下のように修正します。

```yaml
spec:
  containers:
    - name: tomcat
      image: abungard/my-tomcat:latest
      imagePullPolicy: IfNotPresent
```

2. 既存のデプロイを削除し、再適用します。

```bash
kubectl delete deployment tomcat2-deployment
kubectl apply -f Deployment.yaml
```

3. ポッドの起動状態を確認します。

```bash
kubectl get pods
```

ステータスが `Running` に遷移していることを確認します。

```
NAME                                  READY   STATUS    RESTARTS   AGE
tomcat2-deployment-59d4ff8df8-cwwb2   1/1     Running   0          12s
```</your_token>
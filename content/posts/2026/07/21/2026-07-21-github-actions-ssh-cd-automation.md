---
title: "GitHub ActionsとSSHを用いた継続的デプロイメントの自動化実装"
slug: "github-actions-ssh-cd-automation"
date: 2026-07-21T10:17:22+09:00
draft: false
image: ""
description: "GitHub ActionsとSSHを利用し、手動デプロイのヒューマンエラーを排除する自動化パイプラインの構築手法を解説します。セキュリティと保守性を両立する実装ガイドです。"
categories: ["DevOps Logistics"]
tags: ["github-actions", "ssh-deploy", "cd-pipeline", "devops", "automation"]
author: "K-Life Hack"
---

# GitHub Actionsを利用したSSHベースの自動デプロイメントパイプラインの構築

インフラストラクチャのスケールに伴い、手動によるSSH接続とコマンド実行は、ヒューマンエラーを誘発する重大なボトルネックとなります。特に、ノード数が増加しデプロイ頻度が高まる環境では、ディレクトリの指定ミスや環境変数の適用漏れ、サービスの再起動忘れといったオペレーションミスが、予期せぬダウンタイムに直結します。本稿では、GitHub Actionsを活用し、専用のCI/CDサーバーを運用するオーバーヘッドを回避しつつ、安全かつ軽量なSSHベースの自動デプロイメントパイプラインを構築する手法について詳述します。

## 1. デプロイメントアーキテクチャの設計

リモートサーバーへのデプロイにおいて、最も汎用的かつ軽量な手法はSSH（Secure Shell）経由のコマンド実行です。本構成では、GitHub Actionsのランナーがターゲットサーバーに対してセキュアなトンネルを確立し、事前に定義されたデプロイスクリプトをキックする構造を採用します。

```text
[Developer Push to 'test' Branch]
               │
               ▼
     [GitHub Actions Runner]
               │
       (SSH Connection)
               │
               ▼
     [Target Remote Server]
               │
     (Executes deploy.sh)
               │
               ▼
     [Deployment Completed]
```

## 2. サーバーサイドの事前準備

自動化パイプラインを稼働させる前に、ターゲットサーバー側でセキュアな接続を受け入れるための設定が必要です。

### SSH認証の設定

GitHub Actionsランナーからのアクセスを許可するため、Ed25519アルゴリズムを用いた鍵ペアを生成し、公開鍵をサーバーの `~/.ssh/authorized_keys` に登録します。

```bash
# 鍵ペアの生成
ssh-keygen -t ed25519 -C "github-actions-deploy"

# 公開鍵の登録（サーバー側）
cat id_ed25519.pub &gt;&gt; ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### デプロイスクリプト (`deploy.sh`) の実装

GitHub ActionsのYAMLファイル内に複雑なロジックを記述するのではなく、サーバー側に実行スクリプトを配置することで、保守性を高めます。

```bash
#!/bin/bash
set -e # エラー発生時に即時終了

PROJECT_DIR="/var/www/my-app"
cd $PROJECT_DIR

echo "Fetching latest changes from origin..."
git fetch origin test
git reset --hard origin/test

echo "Installing dependencies..."
npm install --production

echo "Building application..."
npm run build

echo "Restarting application service..."
pm2 reload my-app || pm2 start dist/index.js --name "my-app"

echo "Deployment successfully completed!"
```

## 3. GitHub Secretsによる機密情報の管理

セキュリティを担保するため、サーバーのIPアドレスやSSH秘密鍵をコードベースに含めてはなりません。GitHubリポジトリの `Settings &gt; Secrets and variables &gt; Actions` に以下の変数を登録します。

| Secret Name | Description | 
| :--- | :--- | 
| `SSH_HOST` | ターゲットサーバーのパブリックIPまたはドメイン |
| `SSH_USERNAME` | デプロイ専用のユーザー名 |
| `SSH_KEY` | 生成したSSH秘密鍵の全文 |
| `SSH_PORT` | SSH接続ポート（デフォルトは22） |

## 4. ワークフロー定義 (YAML)

`.github/workflows/deploy.yml` を作成し、特定のブランチへのプッシュをトリガーとしてデプロイを実行するパイプラインを定義します。

```yaml
name: Continuous Deployment to Test Environment

on:
  push:
    branches:
      - test

jobs:
  deploy:
    name: Execute Remote SSH Deployment
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Repository Code
        uses: actions/checkout@v4

      - name: Execute Remote Commands via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USERNAME }}
          key: ${{ secrets.SSH_KEY }}
          port: ${{ secrets.SSH_PORT }}
          script_stop: true
          script: |
            echo "Successfully connected to remote host."
            cd /var/www/my-app
            chmod +x deploy.sh
            ./deploy.sh
```

## 5. Troubleshooting &amp; Verification

デプロイ完了後、システムが正常に稼働しているかを確認するための検証コマンドを実行します。特に、SSH接続のタイムアウトや権限エラーが発生した場合は、以下のログプロトコルを確認してください。

```text
# サービス稼働状態の確認
$ pm2 status

# ポートリスニング状態の確認
$ ss -tulpn | grep :3000

# アプリケーションのレスポンス確認
$ curl -I http://localhost:3000
HTTP/1.1 200 OK
X-Powered-By: Express
Content-Type: text/html; charset=utf-8
```

### 代表的な失敗事例と対策

<b>Permission Denied</b>: デプロイユーザーが `PROJECT_DIR` に対して書き込み権限を持っていない場合に発生します。`chown` コマンドで適切な所有権を設定してください。
<b>SSH Timeout</b>: サーバー側のファイアウォール（UFW/iptables）で、GitHub ActionsのIPレンジまたは特定のポートが許可されていない可能性があります。
<b>Sudo Password Requirement</b>: サービス再起動に `sudo` が必要な場合、パスワード入力でパイプラインが停止します。`/etc/sudoers` に `NOPASSWD` 設定を追加して回避します。

```bash
# /etc/sudoers への設定例
deploy-user ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart my-app-service
```

## 6. Operational Notes

自動化を導入する際の設計指針として、以下の3点を推奨します。

1. 💡 <b>最小権限の原則 (PoLP)</b>: デプロイには `root` ユーザーを使用せず、権限を限定した専用ユーザーを作成してください。
2. 🛠️ <b>スクリプトの疎結合化</b>: デプロイロジックをYAMLに直接記述せず、サーバー上のシェルスクリプトにカプセル化することで、CIツールに依存しない運用が可能になります。
3. ⚠️ <b>秘密鍵のローテーション</b>: GitHub Secretsに登録した秘密鍵は、定期的に更新し、万が一の漏洩リスクを最小限に抑える運用フローを構築してください。

GitHub ActionsによるSSHデプロイの導入は、インフラ管理のオーバーヘッドを最小化しつつ、リリースの確実性を向上させる極めて有効なアプローチです。
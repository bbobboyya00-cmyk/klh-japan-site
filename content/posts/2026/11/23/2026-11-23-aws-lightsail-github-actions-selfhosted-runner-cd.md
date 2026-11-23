---
title: "AWS LightsailにおけるSelf-Hosted Runner移行とインバウンド非公開CDパイプラインの構築"
slug: "aws-lightsail-github-actions-selfhosted-runner-cd"
date: 2026-11-23T11:26:44+09:00
draft: false
image: ""
description: "AWS Lightsail環境において、インバウンドPort 22を閉鎖しGitHub Actions Self-Hosted Runnerを用いたセキュアなCDパイプラインへの移行手順と検証結果を記録します。"
categories: ["DevOps Logistics"]
tags: ["github actions self-hosted runner proxy"]
author: "K-Life Hack"
---

インフラのスケールおよび運用自動化において、アプリケーションコードと機械学習モデルの更新サイクルの分離、ならびにデプロイ時におけるインバウンドアクセス権限の最小化は極めて重要な設計要素です。従来のようにアプリケーションコードとモデルバイナリを同一のDockerイメージ内に同梱する構成では、モデル更新のみのタイミングでもリビルドが発生し、コンテナイメージの配送コストが増大する課題が存在しました。

また、CI/CDパイプラインから本番サーバーへSSH経由でデプロイを実行するアーキテクチャでは、IPアドレスが動的に変化するマネージドランナーに対応するため、SSHポート（Port 22）を全開放（0.0.0.0/0）せざるを得ず、セキュリティ上のリスクを抱え込むことになります。

本稿では、AWS Lightsail上で稼働する<code>eta-mini</code>サービスを対象に、コードとモデルのバージョン分離設計、外部SSH接続型デプロイ（Stage 1）からSelf-Hosted Runnerを用いたアウトバウンド専用デプロイ（Stage 2）への移行手順、および遭遇したトラブルシューティングの実績ログを記録します。

## 1. コードとモデルの分離アーキテクチャ

機械学習モデルの再学習サイクルは、アプリケーションのロジック改修よりも高頻度で発生します。このライフサイクルの非対称性に対応するため、コンテナイメージとモデルバイナリの依存関係を完全に切り離す分離設計を採用します。

* <b>アプリケーションコードバージョン (`v1.x`)</b>: Gitのセマンティックタグのプッシュをトリガーとして、GHCR（GitHub Container Registry）へコンテナイメージをビルド・プッシュします。
* <b>モデルバージョン (`m<yyyymmdd>-<seq>`)</seq></yyyymmdd></b>: モデルファイルはコンテナイメージ内部へ焼き込まず、ホストサーバーの永続ストレージ（`/srv/eta/models/`）に配置し、コンテナ起動時に読み取り専用（`:ro`）でボリュームマウントします。

コンテナ側は <code>/health</code> エンドポイントを公開し、現在読み込まれているアプリケーションバージョンとモデルバージョンの整合性を動的に応答する構造とします。

```json
{
  "status": "ok",
  "model": "onnx",
  "app_version": "v1.0",
  "model_version": "baked"
}
```

応答に含まれる <code>model_version</code> が <code>baked</code> を示す場合、イメージに組み込まれたデフォルトの初期モデルが適用されていることを意味します。

## 2. Stage 1: SSH接続によるデプロイの限界

初期運用段階（Stage 1）では、GitHubホステッドランナーからAWS Lightsail上のインスタンスへSSH経由で接続し、デプロイスクリプトを実行するプッシュ型の構成をとっていました。

### Stage 1 のデプロイスクリプト (`server.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/srv/eta"
ENV_FILE="${TARGET_DIR}/.env"

COMMAND="${1:-}"
TAG_NAME="${2:-}"

if [ "${COMMAND}" = "image" ]; then
  if [ -z "${TAG_NAME}" ]; then
    echo "Error: Tag name is required."
    exit 1
  fi

  PREV_TAG=$(grep -E '^TAG=' "${ENV_FILE}" | cut -d'=' -f2 || true)
  echo "Updating TAG to ${TAG_NAME}..."
  sed -i "s/^TAG=.*/TAG=${TAG_NAME}/" "${ENV_FILE}"

  docker compose -f "${TARGET_DIR}/compose.yml" pull
  docker compose -f "${TARGET_DIR}/compose.yml" up -d

  # ヘルスチェックによるロールバック判定
  sleep 5
  HEALTH_STATUS=$(curl -s http://localhost:8080/health | grep -o '"status":"ok"' || true)
  if [ -z "${HEALTH_STATUS}" ]; then
    echo "Health check failed. Rolling back to ${PREV_TAG}..."
    sed -i "s/^TAG=.*/TAG=${PREV_TAG}/" "${ENV_FILE}"
    docker compose -f "${TARGET_DIR}/compose.yml" up -d
    exit 1
  fi
fi
```

### Stage 1 のセキュリティ課題

⚠️ <b>構成上のリスクと制限事項:</b>
* <b>IP全開放の強制</b>: GitHubホステッドランナーの送信元IP帯域が可変であるため、LightsailのファイアウォールルールにてPort 22を <code>0.0.0.0/0</code> に対し常時開放する必要があります。
* <b>秘密情報の保持</b>: ホストのSSH秘密鍵（<code>LIGHTSAIL_SSH_KEY</code>）を外部CI/CDサービス側に保持し続ける運用リスクが存在します。
* <b>TOFUパターンのリスク</b>: 接続確立時に <code>StrictHostKeyChecking=accept-new</code> を指定するため、中間者攻撃（MITM）に対する厳格な検証が制限されます。

## 3. Stage 2: Self-Hosted Runnerへの移行とインバウンド閉鎖

インバウンドアクセスにおけるセキュリティリスクを根本から排除するため、ターゲットサーバー自体をGitHub ActionsのSelf-Hosted Runnerとして登録するプル型アーキテクチャへ移行します。サーバー側からGitHubに対しHTTPS（Port 443）経由でアウトバウンドのロングポーリングを行うため、外部からのインバウンドポート開放が一切不要となります。

### Self-Hosted Runnerのエージェント設定

ホストサーバー（Amazon Linux 2023）上にて以下のコマンドを実行し、Runnerエージェントの登録および systemd サービスとしての起動を完了させます。

```bash
# ランナーのセットアップとラベル付与
./config.sh --url https://github.com/<username>/eta-mini-aws \
  --token <registration_token> \
  --name eta-mini \
  --labels lightsail \
  --unattended

# Systemdサービスとして常駐化
sudo ./svc.sh install ec2-user
sudo ./svc.sh start
```

### ワークフロー設定の変更 (`.github/workflows/deploy.yml`)

デプロイジョブの実行環境ラベルを <code>ubuntu-latest</code> から <code>[self-hosted, lightsail]</code> へ変更し、ローカルでの直接シェル実行へ切り替えます。同一定義の並列実行によるリソース競合を防ぐため、<code>concurrency</code> 制御を追加します。

```yaml
name: CD Pipeline

on:
  push:
    tags:
      - 'v*'

jobs:
  deploy:
    runs-on: [self-hosted, lightsail]
    concurrency:
      group: lightsail-deploy
      cancel-in-progress: false
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Sync configuration files
        run: |
          cp compose.yml /srv/eta/compose.yml
          cp server.sh /srv/eta/server.sh
          chmod +x /srv/eta/server.sh

      - name: Execute deployment script
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          /srv/eta/server.sh image "${{ github.ref_name }}"
```

## Troubleshooting

### 1. ランナー登録トークンの有効期限切れ
🛠️ <b>現象と対策:</b>
* <b>現象</b>: <code>./config.sh</code> 実行時に <code>HTTP 404 Not Found</code> または認証エラーが発生して登録が失敗する。
* <b>原因</b>: GitHub UI/APIから発行したアクティベーショントークンは、生成後1時間で自動的に失効する仕様となっています。
* <b>対策</b>: トークン発行後は速やかにセットアップスクリプトを実行するか、GitHub APIを用いてトークンを動的に自動再発行するスクリプトを構築します。

### 2. Linux依存ライブラリの不足による登録失敗

🛠️ <b>現象と対策:</b>
* <b>現象</b>: Amazon Linux 2023環境で <code>./config.sh</code> を実行した際、<code>libicu</code> などの共有ライブラリが見つからずプロセスが異常終了する。
* <b>原因</b>: 最小構成のOSイメージには .NET Core ランタイムの動的リンクに必要なシステムライブラリが含まれていません。
* <b>対策</b>: インスタンス起動時の UserData（Launch Script）に依存パッケージの事前インストール処理を追加します。

```bash
#!/usr/bin/env bash
sudo dnf install -y libicu digest-shasum docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

### 3. 同時タグプッシュによるローカル排他制御の失敗

🛠️ <b>現象と対策:</b>
* <b>現象</b>: 複数のGitタグが連続してプッシュされた際、<code>/srv/eta/.env</code> の書き換え処理が競合し、コンテナの起動状態が不正になる。
* <b>原因</b>: Self-Hosted Runner上で同一ホストリソースを参照するデプロイジョブが並行して実行されたためです。
* <b>対策</b>: GitHub Actionsの <code>concurrency</code> 属性を適切に定義し、該当のデプロイグループ単位でジョブを排他的にシリアライズ実行させます。

### 4. 移行途中の認証情報削除によるデプロイ不能

🛠️ <b>現象と対策:</b>
* <b>現象</b>: Stage 2への切り替え完了前にGitHub Secrets（<code>LIGHTSAIL_SSH_KEY</code>）を早期削除したことで、ロールバックが不可能になる。
* <b>対策</b>: 新規タグ（例: <code>v1.1</code>）によるデプロイがSelf-Hosted Runner経由で完全成功したことを実行ログから確認した上で、旧環境のSecretsおよび Port 22 のファイアウォールルールを段階的に削除・変更します。

## 4. ネットワーク隔離および動作検証

Stage 2への移行完了後、ホストのPort 22（SSH）に対する外部アクセス遮断を実施し、最終的なデプロイパイプラインの動作検証を行います。

```text
$ ssh -i eta-deploy.pem ec2-user@54.250.x.x
ssh: connect to host 54.250.x.x port 22: Connection timed out

$ curl -s http://54.250.x.x/health
{"status":"ok","model":"onnx","app_version":"v1.1","model_version":"baked"}

$ sudo systemctl status Actions-Runner-Service
● Actions-Runner-Service.service - GitHub Actions Runner (eta-mini)
     Loaded: loaded (/etc/systemd/system/Actions-Runner-Service.service; enabled; preset: disabled)
     Active: active (running) since Mon 2026-11-23 10:15:22 KST; 2h ago
   Main PID: 14205 (Runner.Listener)
      Tasks: 18 (limit: 2282)
     Memory: 48.2M


外部端末からのSSH直接接続はタイムアウトとなり、ポートが遮断されていることが実証されました。同時に、`/health` エンドポイントからは更新された `app_version: v1.1` が正常に応答されています。

## Lessons Learned

1. **インバウンドアクセス全廃による攻撃対象領域の縮小**: デプロイ基盤をアウトバウンドのポーリング型（Self-Hosted Runner）へ変更したことで、本番サーバーのSSHポートをインターネットに露出させるリスクを排除できました。
2. **コンテナとモデルバイナリの疎結合化**: アプリケーションコード（`v1.x`）とモデル（`m<date>`）のデプロイラインを分離したことで、無駄なコンテナイメージリビルドを防ぎ、帯域転送コストとデプロイ時間を削減できました。
3. **ローカル実行に伴う排他制御の必須化**: Self-Hosted Runnerを同一ノードで運用する場合、ホスト側の設定ファイルやDockerデーモンへのアクセス競合を防止するため、ワークフロー側での `concurrency` 制御が不可欠です。</date></registration_token></username>
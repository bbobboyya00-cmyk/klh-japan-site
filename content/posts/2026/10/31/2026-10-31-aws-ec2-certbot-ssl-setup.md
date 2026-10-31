---
title: "AWS環境における単一EC2とCertbotを用いたSSL証明書自動化とインフラ保守プロトコル"
slug: "aws-ec2-certbot-ssl-setup"
date: 2026-10-31T10:59:10+09:00
draft: false
image: ""
description: "AWS環境においてEC2単体でWebとDBを運用する際のVPC・セキュリティグループ設定、Certbotを用いたSSL/TLS証明書自動更新、およびS3バックアップの自動化構成について解説します。"
categories: ["Linux System Admin"]
tags: ["let's encrypt ssl 인증서 자동 갱신"]
author: "K-Life Hack"
---

大規模なアプリケーションアクセスに対応するApplication Load Balancer（ALB）の導入前段階におけるスタンドアロン構成や、初期構築コストを抑えたAWSインフラ構築において、手動による証明書更新や曖昧なネットワーク設計はサービス停止を招く直接的な原因となります。特に単一のEC2インスタンス上にWebサーバーとデータベースを同居させる構成では、最小権限の原則に準拠したセキュリティグループの定義、CertbotによるSSL/TLS証明書の自動更新パイプライン、ならびに定期的なバックアップ機構を厳格に実装する必要があります。

本稿では、AWSにおけるネットワーク境界の設計から、EC2インスタンスの初期化、Certbotを用いた証明書更新の自動化、およびS3バケットへのDBダンプ自動転送に至る具体手順と、実務運用上で発生し得る技術的トラブルシューティングを体系的に整理します。

## 1. ネットワーク境界とセキュリティグループの設定

Virtual Private Cloud（VPC）およびサブネットの適切な分離は、クラウドインフラストラクチャにおけるセキュリティの基盤です。本構成では `10.0.0.0/16` CIDRブロックを適用し、パブリックサブネットとプライベートサブネットの境界を明確に分離します。

### 🛠️ セキュリティグループ（Stateful）の設定要件

* <b>Web Server Security Group (`sg-web`)</b>:
* HTTP (Port 80): 送信元 `0.0.0.0/0`
* HTTPS (Port 443): 送信元 `0.0.0.0/0`
* SSH (Port 22): 送信元 `&lt;管理者IP&gt;/32`（`0.0.0.0/0` による全開放は厳禁）
* <b>Database Security Group (`sg-db`)</b>:
* MySQL (Port 3306) または PostgreSQL (Port 5432): 送信元IPアドレス直接指定ではなく `sg-web` のセキュリティグループIDを紐付け

## 2. EC2インスタンスのプロビジョニングと初期化

Ubuntu LTSをベースとしたEC2インスタンスの起動後、リモート接続用キーペアの権限変更を実施し、システムタイムゾーンの最適化およびメモリ枯渇によるOOM Panicを回避するためのスワップ領域作成を実行します。

```bash
chmod 400 my-key.pem
ssh -i my-key.pem ubuntu@<ec2_public_ip>

# タイムゾーンの設定
sudo timedatectl set-timezone Asia/Tokyo

# スワップ領域の作成（2GB）
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

## 3. CertbotによるSSL/TLS証明書の発行と自動更新

AWS Certificate Manager（ACM）はALBとの連携が前提となるため、単一EC2構成ではLet's Encrypt（Certbot）を適用し、Nginx上で直接SSL/TLSハンドシェイクを完了させます。

### 💡 Certbotのセットアップ手順

```bash
sudo apt update
sudo apt install certbot python3-certbot-nginx -y

# 証明書の発行とNginx自動設定
sudo certbot --nginx -d example.com -d www.example.com
```

Let's Encryptの証明書有効期限は90日間です。Certbotのパッケージ導入時に `systemd` タイマー（`certbot.timer`）が自動で登録され、1日2回の更新検証が実行されます。手動による動作検証を行う場合は、以下のドライランコマンドを実施します。

```bash
sudo certbot renew --dry-run
```

## 4. データベースバックアップとS3同期の自動化

単一障害点（SPOF）に起因するデータ消失リスクを抑えるため、EC2内部で生成されたDBダンプをAWS CLI経由でS3バケットへ自動転送するバックアップスクリプトを構築します。

```bash
#!/bin/bash
# /usr/local/bin/db-backup.sh
SET_DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/db_backups"
FILE_NAME="db_backup_${SET_DATE}.sql.gz"
S3_BUCKET="s3://my-db-backup-bucket-prod"

mkdir -p ${BACKUP_DIR}

# DBダンプの生成
mysqldump -u root -p'DB_PASSWORD_HERE' --all-databases | gzip &gt; ${BACKUP_DIR}/${FILE_NAME}

# S3への転送
aws s3 cp ${BACKUP_DIR}/${FILE_NAME} ${S3_BUCKET}/${FILE_NAME}

# ローカル一時ファイルの削除
rm -f ${BACKUP_DIR}/${FILE_NAME}
```

作成したスクリプトに対して実行権限を付与し、`crontab` に登録して定時実行を行います。

```cron
0 3 * * * /usr/local/bin/db-backup.sh &gt; /dev/null 2&gt;&amp;1
```

S3バケット側ではライフサイクルルールを設定し、作成から30日が経過したオブジェクトを自動的に削除することでストレージコストの最適化を図ります。

## Troubleshooting

### ⚠️ 1. Certbot更新チャレンジの失敗（HTTP-01 Challenge Failure）
* <b>現象</b>: `certbot renew` 実行時に `Timeout during connect (HTTP)` や `404 Not Found` のエラーが返却される。
* <b>原因</b>: セキュリティグループ側で Port 80 のインバウンド通信が開放されていない、または Nginx 内での `.well-known/acme-challenge/` に対するルーティング設定が不正である。
* <b>対策</b>: セキュリティグループのインバウンドルールに Port 80 が開いているか確認します。Nginx設定ファイル（`/etc/nginx/sites-available/default`）における静的ファイルのパス参照を再検証し、`certbot --nginx` プラグインの設定を復旧させます。

### ⚠️ 2. cron経由におけるAWS CLI転送の失敗

* <b>現象</b>: 手動でのスクリプト実行ではS3へ正常にアップロードされるが、cronによる自動実行時にアップロードがスキップされる。
* <b>原因</b>: cron実行環境における環境変数 `PATH` および `AWS_CONFIG_FILE` のパスが正しく参照できていない。
* <b>対策</b>: スクリプト内部で `/usr/local/bin/aws` のようにフルパス記述を行うか、スクリプト先頭で `export PATH=$PATH:/usr/local/bin` および `export AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials` を明示的に宣言します。

### ⚠️ 3. パッケージ更新時におけるOOMクラッシュ

* <b>現象</b>: `apt update &amp;&amp; apt upgrade` の実行中にコンソールが応答停止（Hang）する。
* <b>原因</b>: t3.microなどの小規模インスタンスにおいて物理メモリが枯渇し、LinuxカーネルのOOM Killerが作動する。
* <b>対策</b>: アップデート実行前に `swapon --show` コマンドを使用し、スワップ領域が正常に割り当てられているか確認します。

## Verification Protocols

各種コンポーネントの構築完了後、サービスおよび自動更新タイマーの稼働状態を以下の検証コマンドにて確認します。

```text
$ systemctl status certbot.timer
● certbot.timer - Run certbot twice daily
     Active: active (waiting) since Sun 2026-10-25 09:00:12 KST; 6 days ago
    Trigger: Sat 2026-10-31 18:42:11 KST; 4h 12min left
   Triggers: ● certbot.service

$ ss -tulpn | grep -E ':(80|443)'
tcp   LISTEN 0      512          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=1234,fd=6))
tcp   LISTEN 0      512          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=1234,fd=7))

$ swapon --show
NAME      TYPE BASE_SIZE USED PRIO
/swapfile file       2G 128M   -2

$ curl -I https://example.com
HTTP/2 200
server: nginx/1.18.0 (Ubuntu)
date: Sat, 31 Oct 2026 14:30:00 GMT
content-type: text/html
strict-transport-security: max-age=31536000; includeSubDomains
```

## Operational Notes

* <b>OSパッチ管理</b>: 全パッケージに対する一括更新（`apt upgrade -y`）は、既存の依存ライブラリを破損させるリスクを伴います。セキュリティパッチ適用（`dnf update --security` または `unattended-upgrades`）に限定した運用方針を維持してください。
* <b>証明書有効期限の監視</b>: 自動更新タイマーが正常に動作している場合でも、ドメインのDNS設定変更や外部ネットワーク制限により更新処理が失敗するケースが存在します。証明書の有効期限が30日未満になった際にアラートを発出する外部モニタリング（Prometheus Blackbox Exporter等）の統合を強く推奨します。</ec2_public_ip>
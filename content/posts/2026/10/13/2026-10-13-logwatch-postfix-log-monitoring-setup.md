---
title: "LogwatchとPostfixを用いたシステムログ集約と定期配送の設計"
slug: "logwatch-postfix-log-monitoring-setup"
date: 2026-10-13T10:14:11+09:00
draft: false
image: ""
description: "Ubuntu 24.04環境におけるLogwatchとPostfixを用いたログ監視の実装手順。設定ファイルの記述、cron連携、Postfixの配送トラブルシュートまでを整理します。"
categories: ["Linux System Admin"]
tags: ["logwatch", "postfix", "syslog", "cron", "sshd"]
author: "K-Life Hack"
---

インフラストラクチャの台数増加に伴い、各ノードに散在する認証ログやパケット破棄ログを手動で巡回確認する運用は、オペレーションミスの原因となります。集中ログ収集基盤を導入する前段階や、単体ホストの保全性を迅速に担保するアプローチとして、ログ要約ツールによる定期レポートの自動配送は標準的な監査手法の一つです。

本稿では、Ubuntu 24.04 LTS環境をベースに、Logwatchによるログ解析およびPostfixを経由した通知パイプラインの構築手順と、運用時に直面する設定上の摩擦要因について整理します。

## アーキテクチャと動作要件

Logwatchは各サービス（SSH, iptables, Apache, Postfix, cron, sudo等）のログファイルを走査し、指定された期間および粒度（Detailレベル）に基づいてテキストまたはHTML形式のサマリーを生成します。生成されたデータは標準出力、ファイル保存、あるいはローカルに常駐するMail Transfer Agent（MTA）経由での外部送信に対応しています。

```text
+-------------------------------------------------------------+
| Linux Node (Ubuntu 24.04.4 LTS)                             |
|                                                             |
|  /var/log/auth.log ---+                                     |
|  /var/log/syslog   ---+--&gt; [ Logwatch Engine ]              |
|  /var/log/mail.log ---+       |                             |
|                               v                             |
|                      [ /usr/sbin/sendmail ]                 |
|                               |                             |
|                               v                             |
|                       [ Postfix (MTA) ]                     |
|                               |                             |
+-------------------------------|-----------------------------+
                                v (SMTP: Port 25/587)
                     [ Remote Mail Server ]
```

## パッケージ導入とMTA設定

### 1. Logwatchの導入

システムのパッケージリポジトリを更新し、Logwatch本体を導入します。

```bash
sudo apt update
sudo apt install -y logwatch
logwatch --version
```

### 2. Postfixによる配送経路の構成

外部宛先にメールを中継・直接送信するため、Postfixおよび補助ユーティリティをセットアップします。

```bash
sudo apt install -y postfix mailutils
```

パッケージ設定ダイアログが表示された場合、送信要件に応じて以下を選択します。

- <b>Internet Site</b>: ホストから直接宛先MXレコードへSMTP配送を行う場合（SPF/DKIM/逆引きDNSの考慮が必要）。
- <b>Internet with smarthost</b>: 外部のリレーサーバーを経由して配送する場合。

構成完了後、送信元ドメインの認識を検証します。

```bash
sudo postconf mydomain
sudo postconf myhostname
```

## レポート生成パラメータと設定ファイル構成

### 即時検証（標準出力）

ターミナル上で本日の要約を直接確認する場合、以下のフラグを指定して実行します。

```bash
sudo logwatch --detail high --range today --output stdout
```

特定サービスのみを抽出する場合や期間を明示する場合は、`--service` および `--range` オプションを使用します。

```bash
# SSHサービスのみ抽出
sudo logwatch --service sshd --range today --output stdout

# 過去7日間の範囲を指定
sudo logwatch --range 'between -7 days and today' --output stdout
```

### `/etc/logwatch/conf/logwatch.conf` の定義

デフォルトの動作パラメータは `/etc/logwatch/conf/logwatch.conf` に記述します。配備例は以下の通りです。

```text
# Logwatch Default Configuration
Output = mail
Format = text
Encode = none
MailTo = admin@example.com
MailFrom = logwatch@yourserver.com
Detail = High
Range = yesterday

# 監視対象外とするサービス
Service = "-cron"
Service = "-ntpd"
```

閾値に基づくアラートを構成する場合、個別のサービス設定ファイルをオーバーライドします。ディスク容量の警告基準を変更するには、`/etc/logwatch/conf/services/disk_space.conf` を作成・編集します。

```text
disk_space_percent_used_warning = 90
```

## 自動化とcronスケジューリング

Ubuntuではデフォルトで `/etc/cron.daily/00logwatch` が配置されます。実行タイミングや配送パラメータを厳密に制御する場合は、標準のデイリージョブを無効化し、`crontab` を用いて明示的にスケジュールを登録します。

まず単体テストとして、mailコマンド経由およびLogwatch単体でのメール出力を検証します。

```bash
# 配送パイプラインの疎通テスト
echo "Test body" | mail -s "MTA Test" admin@example.com

# Logwatchによる単発メール送信テスト
sudo logwatch --output mail --mailto admin@example.com --detail high --range today
```

検証後、`/etc/cron.d/logwatch` または rootのcrontabに以下のように登録します。

```text
# 毎朝08:00に前日分のレポートを配送
0 8 * * * /usr/sbin/logwatch --output mail --mailto admin@example.com --detail high --range yesterday
```

## Troubleshooting

Logwatchの導入およびPostfixとの連携において発生しやすい障害事象と、その切り分け手順を以下に示します。

### 1. メールが外部宛先に到達せずキューに滞留する

⚠️ <b>原因</b>: クラウドプロバイダやISPによるOutbound Port 25 Blocking（OP25B）、またはPostfixのDNS解決・リレー設定の不備。

確認コマンド:

```bash
mailq
sudo journalctl -u postfix -n 50 --no-pager
```

キューに `Connection timed out` や `Network is unreachable` が記録されている場合、Port 25の通信が制限されています。この場合、`/etc/postfix/main.cf` 内で `relayhost` を定義し、認証付きSMTP（Port 587）経由へ迂回させる必要があります。

### 2. ログファイルのパーミッション拒否（Permission Denied）

⚠️ <b>原因</b>: `/var/log` 配下のファイルが特定のグループ（`adm` や `systemd-journal` など）に制限されており、cron実行ユーザー権限で参照できないケース。

対応手順: 実行権限の確認とログディレクトリの権限グループ照合を行います。

```bash
ls -l /var/log/auth.log
```

cronジョブを一般ユーザーで設定している場合は、必ずrootのcrontab（`sudo crontab -e`）または `/etc/cron.daily/` に配置されていることを確認してください。

## Operational Verification

🛠️ 各種デーモンおよびプロセスの正常動作確認、ネットワークリスナーの検査プロトコルは以下の通りです。

```bash
sudo systemctl status postfix --no-pager
sudo ss -tulpn | grep :25

```text
● postfix@-.service - Postfix Mail Transport Agent (instance -)
Loaded: loaded (/usr/lib/systemd/system/postfix@.service; enabled; preset: enabled)
Active: active (running) since Tue 2026-10-13 09:12:44 UTC; 2h 15min ago
Main PID: 12480 (master)
Tasks: 3 (limit: 4613)
Memory: 4.8M (peak: 5.2M)
CPU: 120ms
CGroup: /system.slice/system-postfix.slice/postfix@-.service
├─12480 /usr/lib/postfix/sbin/master -w
├─12482 qmgr -l -t unix -u
└─15210 pickup -l -t unix -u

tcp   LISTEN 0      100        127.0.0.1:25        0.0.0.0:*    users:(("master",pid=12480,fd=13))
tcp   LISTEN 0      100            [::1]:25           [::]:*    users:(("master",pid=12480,fd=14))
```

上記のようにPostfixのマスタープロセスがループバックアドレス（127.0.0.1）でリッスンしており、Logwatch実行時にエラーなくパイプラインが終了していれば、日次の監視基盤は正常に稼働しています。

## Operational Notes

💡 Logwatchは軽量かつ依存関係が少ないため、最小構成のLinuxサーバーにおける基本的なセキュリティ監査および死活状況の把握に適しています。ただし、ホスト数が増加した環境では個別のメールレポートを人が判読する負荷が急激に増大します。サーバ群の規模に応じて、LogwatchのHTML出力を集約スクリプトで統合するか、あるいはSyslogプロトコルを用いた集中ログ基盤（Fluentbit、OpenTelemetry、Vector等）への移行を検討する必要があります。
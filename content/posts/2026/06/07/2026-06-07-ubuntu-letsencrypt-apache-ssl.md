---
title: "Ubuntu 22.04 LTSにおけるApacheおよびNginxのLet's Encrypt導入と自動更新設定"
slug: "ubuntu-letsencrypt-apache-ssl"
date: 2026-06-07T10:06:29+09:00
draft: false
image: ""
description: "Ubuntu 22.04 LTS環境でCertbotを使用し、Apache/NginxにLet's Encrypt SSL/TLS証明書を導入・自動更新する手順と、移行時のトラブルシューティングを解説します。"
categories: ["Linux System Admin"]
tags: ["letsencrypt", "certbot", "ubuntu-22-04", "apache", "nginx"]
author: "K-Life Hack"
---

物理的なサーバー移行やネットワーク回線の切り替えに伴い、SSL/TLS設定の一時的な欠落が発生することがあります。暗号化されていないHTTP（ポート80）での運用を継続した場合、ブラウザ上に「保護されていない通信」という警告が表示され、ユーザーの信頼性低下や検索エンジン評価の降下、さらにはトラフィックの大幅な減少を招くリスクがあります。

本稿では、Ubuntu 22.04 LTS環境において、Apache 2.4およびNginxウェブサーバーを対象に、Certbotを用いたLet's Encrypt SSL/TLS証明書の導入、自動更新の設定、およびトラブルシューティングの手順を解説します。

## 1. 前提条件とネットワーク要件

証明書の発行手続きを開始する前に、対象環境が以下の要件を満たしている必要があります。

1. <b>管理者権限</b>: サーバーへのSSHアクセスおよびsudo実行権限。

2. <b>DNS設定</b>: 登録済みのドメイン名（AレコードまたはAAAAレコード）が、対象サーバーのパブリックIPアドレスを正しく指していること。

3. <b>ファイアウォール設定</b>: ポート80（HTTP）および443（HTTPS）が外部に開放され、ウェブサーバーへトラフィックがルーティングされていること。

⚠️ AWSなどのクラウド環境では、セキュリティグループのインバウンドルールでこれらのポートを明示的に許可する必要があります。この設定漏れは、証明書検証エラーの代表的な原因となります。

## 2. Certbotのインストールと証明書発行

Ubuntu 22.04 LTS環境におけるインストール手順です。ApacheとNginxそれぞれの環境に応じたプラグインを導入します。

### 2.1. システムパッケージの更新

依存関係の競合を防ぐため、ローカルのパッケージインデックスを更新します。

```bash
sudo apt update
```

### 2.2. Certbotおよびプラグインのインストール

使用しているウェブサーバーに合わせて、適切なパッケージを選択してインストールします。

Apache環境の場合：

```bash
sudo apt install certbot python3-certbot-apache -y
```

Nginx環境の場合：

```bash
sudo apt install certbot python3-certbot-nginx -y
```

### 2.3. 証明書発行コマンドの実行

Certbotを実行し、証明書の取得とウェブサーバーへの自動適用を行います。ルートドメインとwwwサブドメインの両方を指定することで、アクセス経路による証明書エラーを防ぎます。

Apache環境の場合：

```bash
sudo certbot --apache -d yourdomain.com -d www.yourdomain.com
```

Nginx環境の場合：

```bash
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```

💡 実行時のインタラクティブプロンプトでは、以下の入力が求められます。

1. <b>メールアドレスの入力</b>: Let's Encryptからの証明書期限切れ通知や重要なお知らせを受け取るためのアドレスを入力します。

2. <b>利用規約（ToS）への同意</b>: 同意を求められるため、画面の指示に従い承諾します。

3. <b>メールマガジンの購読</b>: Electronic Frontier Foundation（EFF）からの情報配信を希望するかどうかを選択します（任意）。

## 3. 証明書の自動更新と無停止リロードの設定

Let's Encrypt証明書の有効期限は90日間です。期限切れによるサービス停止を防ぐため、自動更新を設定します。

### 3.1. 更新処理のテスト（ドライラン）

実際に証明書を再発行することなく、検証プロセスが正常に機能するかを確認します。

```bash
sudo certbot renew --dry-run
```

### 3.2. Cronによる自動更新のスケジュール化

定期的に更新処理を実行するため、rootユーザーのcrontabにタスクを追加します。

crontabエディタを起動します。

```bash
sudo crontab -e
```

ファイルの末尾に以下の設定行を追記します。

```cron
0 3 * * * certbot renew --post-hook "systemctl reload apache2" --quiet
```

💡 このジョブは毎日午前3時に実行されます。--quietフラグにより、エラー発生時のみログが出力されます。--post-hook（または--deploy-hook）を使用することで、証明書が実際に更新されたタイミングでのみウェブサーバーをリロードし、アクティブなコネクションを切断することなく新しい証明書を反映させます（Nginxの場合はsystemctl reload nginxを指定します）。

## 4. トラブルシューティング

証明書適用後にブラウザでhttps://yourdomain.comにアクセスし、鍵マークが表示されない、または接続エラーが発生する場合は、以下の項目を確認します。

### 4.1. ポート443（HTTPS）の通信遮断

⚠️ HTTPS接続時にタイムアウトが発生する場合は、ホスト側のファイアウォール（UFW等）やクラウドインフラのセキュリティ設定を確認します。

```bash
sudo ufw status
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 4.2. ドメイン名の不一致

⚠️ ブラウザにCommon Name InvalidやSSL_ERROR_BAD_CERT_DOMAINが表示される場合は、Certbot実行時に指定したドメイン名が、DNSのAレコードに登録されているドメインと完全に一致しているか再確認してください。

### 4.3. バーチャルホスト設定の競合

⚠️ ウェブサーバーが起動しない、またはHTTPSアクセス時にデフォルトの暗号化されていないページが表示される場合は、Certbotによる自動書き換えが既存の設定と競合している可能性があります。設定ファイル（/etc/apache2/sites-enabled/ または /etc/nginx/sites-enabled/）を開き、証明書パスが正しく指定されているか確認します。

Apacheにおける設定例：

```apache
<virtualhost *:443="">
    ServerName yourdomain.com
    ServerAlias www.yourdomain.com

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/yourdomain.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/yourdomain.com/privkey.pem
</virtualhost>
```

Nginxにおける設定例：

```nginx
server {
    listen 443 ssl;
    server_name yourdomain.com www.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

## 5. 複数ドメイン（SAN）証明書の構成

同一サーバー上で複数のサブドメインや別ドメインを運用する場合、1つの証明書に複数のホスト名を統合する「Subject Alternative Name (SAN)」証明書を発行できます。

追加の-dフラグを使用してコマンドを実行します。

```bash
sudo certbot --expand -d yourdomain.com -d www.yourdomain.com -d otherdomain.com
```

### 運用の注意点

⚠️ Let's Encryptは1つの証明書につき最大100個の名前をサポートしていますが、検証処理の複雑化やDNSトラブル時のリスクを避けるため、1つの証明書に含めるドメイン数は10個以下に抑えることが推奨されます。

## Configuration Notes

本構築における主要な設定パラメータと推奨アクションのまとめは以下の通りです。

| 項目 / タスク | 指定内容 / 推奨アクション |
| :--- | :--- |
| <b>対象OS</b> | Ubuntu 22.04 LTS |
| <b>ウェブサーバー</b> | Apache 2.4 または Nginx |
| <b>証明書有効期間</b> | 90日間 |
| <b>自動更新の閾値</b> | 有効期限まで30日未満となった時点 |
| <b>自動更新スケジュール</b> | 毎日午前3:00にCron実行 (`0 3 * * *`) |
| <b>リロード処理</b> | `--post-hook` による無停止リロードの実行 |
| <b>複数ドメイン制限</b> | 1証明書あたり10ドメイン以下を推奨 |
| <b>必要ポート</b> | ポート80（HTTP検証用）およびポート443（HTTPS通信用） |
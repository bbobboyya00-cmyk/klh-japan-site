---
title: "Dockerコンテナ上のApacheからホストOSのPHP-FPMへFastCGIプロキシ経由で接続する実装"
slug: "docker-apache-host-php-fpm-proxy"
date: 2026-06-01T13:49:50+09:00
draft: false
image: ""
description: "Dockerコンテナ内のApache WebサーバーとホストOS上のPHP-FPMをFastCGIプロキシで連携させ、動的コンテンツ処理を分離するハイブリッド構成の実装手順と設定の詳細を解説します。"
categories: ["Linux System Admin"]
tags: ["docker", "apache-httpd", "php-fpm", "mod-proxy-fcgi", "fastcgi", "hybrid-infrastructure"]
author: "K-Life Hack"
---

# Dockerコンテナ(Apache)とホストOS(PHP-FPM)のハイブリッド構成によるPHP実行環境の構築

## 1. アーキテクチャの概要と選定理由

本稿では、Dockerコンテナ内で動作するApache HTTP Server（以下、Apache）と、ホストOS上で直接動作するPHP-FPM（FastCGI Process Manager）を連携させるハイブリッド構成の実装プロセスを詳述します。通常、Docker環境では同一コンテナ内、あるいはサイドカー構成でPHPを動作させることが一般的ですが、本構成ではプレゼンテーション層（Apache）とアプリケーション処理層（PHP）を物理的・論理的に分離します。

### 1.1 現状の課題

コンテナ化されたApache（コンテナ名: <b>web2</b>）において、静的コンテンツ（HTML）の配信は正常に行われていたものの、PHPファイルの要求に対してパースが行われず、ソースコードがそのまま露出するか、ブラウザがファイルをダウンロードしようとする事象が確認されました。これは、コンテナ内にPHPインタープリタが存在しない、あるいはApacheがPHPリクエストを適切にハンドリングできていないことに起因します。

### 1.2 採用されたソリューション：ハイブリッド・プロキシ・モデル

以下の2つの選択肢を検討した結果、オプション2を採用しました。

1. <b>コンテナの再構築</b>: ApacheとPHPを同梱した新しいイメージを作成する。
2. <b>ハイブリッド・プロキシ・モデル</b>: 既存のApacheコンテナとホストOS上のPHP-FPMをネットワークブリッジ経由で接続する。

オプション2の採用により、コンテナイメージの肥大化を防ぎつつ、ホストOSのネイティブなハードウェアリソースをPHP処理に活用することが可能となります。また、PHP拡張モジュールの管理や設定変更をホスト側で完結できるため、運用柔軟性が向上します。

## 2. ホストOS側の設定：PHP-FPMの構築

ホストOS側で、コンテナからのFastCGIリクエストを受け付けるための環境を整備します。

### 2.1 パッケージのインストール

ホストOSのパッケージマネージャ（dnf）を使用し、PHP本体および主要なモジュールをインストールします。

```bash
dnf install -y php-fpm php-mysqlnd php-opcache php-mbstring
```

各モジュールの役割は以下の通りです：

*   <b>php-fpm</b>: Webサーバーからのリクエストを処理するFastCGIマネージャ。
*   <b>php-mysqlnd</b>: データベース接続用ドライバ。
*   <b>php-opcache</b>: コンパイル済みバイトコードを共有メモリに保持し、実行速度を向上。
*   <b>php-mbstring</b>: マルチバイト文字列（日本語等）の適切な処理に必須。

### 2.2 PHP-FPM 設定の変更 (www.conf)

デフォルトでは、PHP-FPMはUnixドメインソケットまたは 127.0.0.1:9000 でリスンしており、外部（コンテナ）からのアクセスが拒否されます。これをネットワーク経由で受け付けるように変更します。

```bash
vi /etc/php-fpm.d/www.conf
```

以下の項目を修正します：

```ini
; 外部からのリクエストを許可するポート設定
listen = 8080

; アクセスを許可するクライアントの制限（必要に応じて調整）
listen.allowed_clients = 127.0.0.1, 192.168.159.10
```

設定変更後、サービスを起動・有効化します。

```bash
systemctl start php-fpm
systemctl enable php-fpm
```

## 3. Dockerコンテナ側の設定：Apache FastCGIプロキシ

次に、Apacheコンテナ（<b>web2</b>）がPHPリクエストをホストOSのポート8080へ転送するように設定します。

### 3.1 Apache設定ファイルの編集

コンテナのシェルに入り、httpd.conf を編集します。

```bash
docker exec -it web2 /bin/bash
vi /usr/local/apache2/conf/httpd.conf
```

#### 3.1.1 プロキシモジュールの有効化

以下の行のコメントアウトを解除し、FastCGIプロキシ機能を有効にします。

```apache
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
```

#### 3.1.2 ハンドラの設定

ファイルの末尾に、PHPファイルに対するプロキシ設定を追加します。ここではホストOSのIPアドレスを 192.168.159.10 と仮定します。

```apache
ProxyPassMatch ^/(.*\.php(/.*)?)$ fcgi://192.168.159.10:8080/var/www/html/$1
```

この設定により、拡張子が .php のリクエストはすべて指定されたFastCGIエンドポイントへ転送されます。

## 4. 統合テストと検証

設定完了後、コンテナとホスト間の通信が正常に行われるか検証します。

### 4.1 検証フロー

1.  <b>エントリーポイント</b>: コンテナ上の index.php（HTMLフォーム）にアクセス。
2.  <b>データ送信</b>: フォームから POST メソッドで login.php へデータを送信。
3.  <b>プロキシ処理</b>: Apacheが login.php へのリクエストを検知し、ホストOSの 192.168.159.10:8080 へ転送。
4.  <b>PHP実行</b>: ホストOSのPHP-FPMがスクリプトを実行し、結果をApacheに返却。
5.  <b>レスポンス</b>: ブラウザに実行結果が表示されることを確認。

PHPコードがそのまま表示されず、期待通りにサーバーサイドで処理された結果が返ってくれば、プロキシ連携は成功です。

## Operational Notes

*   ⚠️ <b>ネットワークの到達性</b>: コンテナからホストOSのIPアドレスに対して、ポート8080が開放されていることをファイアウォール（firewalld等）の設定で確認してください。
*   🛠️ <b>ファイルパスの整合性</b>: Apache側で見ているドキュメントルートと、PHP-FPM側が参照するスクリプトのパスが一致している必要があります。不一致の場合、`File not found` エラーが発生します。
*   💡 <b>パフォーマンス</b>: ネットワーク経由のプロキシとなるため、高トラフィック環境ではUnixドメインソケットと比較してオーバーヘッドが発生する可能性があります。必要に応じて php-opcache のチューニングを検討してください。
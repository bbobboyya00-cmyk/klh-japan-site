---
title: "MacBookとDocker Caddyによる自動TLS対応エッジサーバー構成"
slug: "macbook-docker-caddy-tls-reverse-proxy"
date: 2026-11-05T10:44:19+09:00
draft: false
image: ""
description: "MacBookとDocker環境においてCaddyリバースプロキシを活用し、自動証明書発行とポートフォワーディングを組み合わせたパブリック公開手順を解説します。"
categories: ["DevOps Logistics"]
tags: ["caddy", "docker-compose", "reverse-proxy", "acme-tls", "port-forwarding", "dns-a-record"]
author: "K-Life Hack"
---

オンプロミスやエッジ環境においてローカル機器を外部へ安全に公開するには、ドメイン名の名前解決、ルーターのパケットルーティング、そしてTLS証明書の自動更新メカニズムの構築が不可欠です。従来の動的なVirtualHost設定やCertbotに基づくcron管理方式は、ノード数が増加するにつれて設定の複雑性が急増し、証明書更新の失敗によるサービス中断を引き起こすリスクがあります。

本稿では、MacBookホスト上にDockerとCaddyリバースプロキシを構築し、パブリックDNS（Gabia等）およびポートフォワーディングを連携させることで、自動HTTPS暗号化通信を確立するエンドツーエンドのアーキテクチャについて解説します。

## アーキテクチャ構成とトラフィックフロー

パブリックドメインへのリクエストは、以下の順序でコンテナ内部のアプリケーション層へルーティングされます。

```
[クライアントブラウザ]
       │
       ▼
[パブリックDNS解決] (Gabia Aレコード)
       │
       ▼
[パブリックWAN IP] (ISPルーター / ゲートウェイ)
       │
       ▼
[ポートフォワーディング処理] (外部 80/443 -&gt; MacBook LAN IP)
       │
       ▼
[MacBook ホストOS] (ホームサーバー)
       │
       ▼
[Caddy リバースプロキシコンテナ] (ポート 80 / 443 / 443 UDP)
       │
       ▼
[アプリケーションコンテナ] (Bridge Network: custom-proxy)
```

## 1. ネットワークインフラとポートフォワーディング

ローカルネットワーク内のMacBookはDHCPによりプライベートIPv4アドレスを割り当てられています。外部からのトラフィックをMacBookへ到達させるには、ISPルーター（ゲートウェイ）でポートフォワーディングを設定する必要があります。

### パブリックWAN IPの確認とDouble NATのチェック

MacBookのターミナルで以下のコマンドを実行し、外部に露出しているパブリックIPv4アドレスを取得します。

```bash
curl ifconfig.me
```

ルーターの管理画面にログインし、表示されているWAN IPアドレスが `curl ifconfig.me` の出力結果と一致することを確認します。

* <b>Double NATの注意事項</b>: ルーターのWAN IPと `ifconfig.me` の結果が異なる場合、上位に別のモデムやルーターが存在するDouble NAT構成となっています。この場合、上位ゲートウェイ側でもポートフォワーディングを設定しなければ、外部からのパケットがMacBookに到達しません。

### ルーターのポート転送ルール

ルーターの管理画面にて以下の転送ルールを追加します。

* <b>HTTP</b>: 外部ポート `80` -&gt; MacBookのプライベートIP / 内部ポート `80`
* <b>HTTPS</b>: 外部ポート `443` -&gt; MacBookのプライベートIP / 内部ポート `443`

#### ポート80開放の必要性

アプリケーションがHTTPS（443）のみを使用する場合でも、ポート `80` は開放しておく必要があります。CaddyはACME（Automated Certificate Management Environment）プロトコルを用いてLet's Encrypt / ZeroSSLからTLS証明書を自動取得します。このHTTP-01チャレンジの検証プロセスにおいて、認証局がドメインのポート `80` にアクセスするためです。

## 2. DNSレコードの設定と伝播検証

パブリックDNSサービス（Gabiaなど）の管理コンソールから、取得したパブリックIPv4アドレスを指向するAレコードを設定します。

### 設定するDNSレコード

* ホスト `@` / タイプ `A` / 値 `[パブリックIPv4アドレス]`
* ホスト `www` / タイプ `A` / 値 `[パブリックIPv4アドレス]`
* ホスト `*` / タイプ `A` / 値 `[パブリックIPv4アドレス]` (サブドメイン用ワイルドカード)

### DNS伝播の検証

設定したレコードが正しく反映されているかを `dig` ユーティリティで確認します。

```bash
# ローカルのデフォルトDNSで検索
dig +short your-domain.com A

# CloudflareのパブリックDNS (1.1.1.1) に対して直接問い合わせ
dig @1.1.1.1 your-domain.com A +short
```

NXDOMAIN` や `SERVFAIL` が返される場合は、DNSレコードの伝播が完了していません。応答がルーターのパブリックIPアドレスと一致するまで待機します。

## 3. DockerおよびCaddyによるリバースプロキシ構成

NginxではTLS証明書の取得や自動更新に `certbot` や外部タイマーを組み合わせる必要がありますが、CaddyはACMEを用いた証明書の要求・検証・自動更新を単体で完結させます。

### `docker-compose.yml` の定義

```yaml
services:
  caddy:
    image: caddy:2
    container_name: caddy-server
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp" # HTTP/3 (QUIC) サポート用
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data/caddy:/data
      - ./data/config:/config
    networks:
      - custom-proxy

networks:
  custom-proxy:
    external: true
    name: custom-proxy
```

#### インフラ設定上の留意点

1. <b>外部ネットワーク (`external: true`)</b>:
`custom-proxy` ネットワークを事前にCLIから手動作成しておくことで、他の独立した `docker-compose.yml` プロジェクトから発行されたバックエンドコンテナも同一のプロキシネットワークに参加させることができます。

   ```bash
   docker network create custom-proxy
   ```

2. <b>TLSデータの永続化 (`./data/caddy`)</b>:
`/data` ボリュームには取得した証明書や秘密鍵、ACMEアカウント情報が保存されます。このディレクトリを削除すると、コンテナ再起動のたびに新規の証明書を発行することになり、Let's Encryptの重複発行レートリミット（Rate Limit）に達して一時的にアクセス不可となる危険性があります。

### `Caddyfile` の作成とルーティング設定

プロキシ動作を確認するためのテスト用 `Caddyfile` を作成します。

```caddyfile
your-domain.com {
    respond "Home Server is running!" 200
}
```

コンテナを起動します。

```bash
docker-compose up -d
```

実運用環境でバックエンドアプリケーションコンテナへ転送する場合は、以下のように `reverse_proxy` ディレクティブを設定します。

```caddyfile
your-domain.com {
    reverse_proxy my-app:3000
}
```

これで `your-domain.com` へのHTTP/HTTPSアクセスは、Docker内部ネットワーク `custom-proxy` 上の `my-app` コンテナの `3000` 番ポートへ自動的にプロキシされます。

## Troubleshooting

### 1. Hairpin NAT (NAT Loopback) による接続障害

<b>問題現象</b>: 外部ネットワーク（モバイルセルラー回線等）からはドメイン経由で正常にアクセスできるが、同一LAN内のデバイスから `https://your-domain.com` にアクセスするとタイムアウトや接続エラーが発生する。

<b>原因</b>: 市販のルーターが Hairpin NAT（NAT Loopback）に対応していない場合、LAN内部のクライアントがルーター自身のパブリックIP宛てに送ったパケットを内部へ折り返して転送できず、パケットが破棄されます。

<b>解決手順と対処法</b>:
* 接続検証は必ず外部ネットワーク（モバイルデータ通信やテザリング）から実施してください。
* LAN内部からのアクセスにおいては、ローカルDNSサーバー（Pi-hole等）や hosts ファイルでドメイン名をMacBookのプライベートIPへ直接解決させるスプリットDNS構成をとることで回避できます。

### 2. システム稼働状態および検証ログ

システム構築後のネットワークソケット状態、Dockerコンテナ状態、DNSレスポンス、HTTPレスポンスの出力結果例は以下の通りです。

```text
$ docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
NAMES          STATUS          PORTS
caddy-server   Up 12 minutes   0.0.0.0:80-&gt;80/tcp, 0.0.0.0:443-&gt;443/tcp, 0.0.0.0:443-&gt;443/udp

$ ss -tulpn | grep -E ':(80|443)'
tcp   LISTEN 0      4096         0.0.0.0:80        0.0.0.0:*    users:(("docker-proxy",pid=14201,fd=4))
tcp   LISTEN 0      4096         0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=14225,fd=4))
udp   UNCONN 0      0            0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=14249,fd=4))

$ dig @1.1.1.1 your-domain.com A +short
203.0.113.42

$ curl -I https://your-domain.com
HTTP/2 200 
server: Caddy
content-type: text/plain; charset=utf-8
date: Thu, 05 Nov 2026 10:15:30 GMT
```

## Key Takeaways

* 💡 <b>ACME検証におけるポート80の必須性</b>: TLS自動化を実現するためには、HTTPS通信用の `443` ポートだけでなく、HTTP-01チャレンジ用の `80` ポートのポートフォワーディングが不可欠です。
* ⚠️ <b>データボリュームの保持</b>: Let's Encryptのレートリミット回避のため、Caddyの `/data` ディレクトリの永続化は極めて重要です。
* 🛠️ <b>ネットワーク分離の設計</b>: Dockerの外部ネットワーク (`external: true`) を活用することで、Caddyと複数の独立したサービスコンテナ間を安全かつ柔軟に疎通させることが可能となります。
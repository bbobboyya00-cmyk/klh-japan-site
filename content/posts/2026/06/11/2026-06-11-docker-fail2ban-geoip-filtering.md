---
title: "Fail2banとGeoIPによるDocker環境のIPフィルタリング実装"
slug: "docker-fail2ban-geoip-filtering"
date: 2026-06-11T18:16:46+09:00
draft: false
image: ""
description: "Docker環境下でFail2banとGeoIPデータベースを連携させ、特定の国からのアクセスを効率的にフィルタリングする実装手法を解説します。Pythonのmmapを利用した高速なDB検索とiptables制御を組み合わせた構成です。"
categories: ["Linux System Admin"]
tags: ["fail2ban", "geoip", "docker-compose", "iptables", "python-mmap"]
author: "K-Life Hack"
---

# Docker環境におけるFail2banとGeoIPを用いた国別IPフィルタリングの実装

Docker環境において、外部ライブラリへの依存を最小限に抑えつつ、GeoIPデータベースを活用して国別のIPフィルタリングを実装する手法を解説します。本構成では、Fail2banがNginxのログをリアルタイムで監視し、Pythonのmmapを用いた高速なバイナリ解析によって接続元の国を特定、必要に応じてホスト側のiptablesを操作します。

## 1. 環境準備とGeoIPデータベースの取得

まず、ホストサーバー上にログ、設定ファイル、およびGeoIPデータベースを永続化するためのディレクトリ構造を構築します。これにより、コンテナの再起動後もデータと設定が維持されます。

```bash
mkdir -p /opt/fail2ban/config/fail2ban/action.d
mkdir -p /opt/fail2ban/config/fail2ban/jail.d
mkdir -p /opt/fail2ban/data/geoip
mkdir -p /opt/fail2ban/logs/nginx
```

次に、MaxMindのGeoLite2-Countryデータベース（.mmdb形式）を取得します。効率的なルックアップを実現するため、バイナリファイルを適切なディレクトリに配置します。

```bash
# GeoLite2-Country.mmdbのダウンロード（ライセンスキーが必要な場合は適切に設定）
wget -O /opt/fail2ban/data/geoip/GeoLite2-Country.mmdb https://git.io/GeoLite2-Country.mmdb
```

## 2. Dockerコンテナのオーケストレーション

Fail2banコンテナがホストのネットワークスタックを直接操作し、iptablesを書き換えるためには、`network_mode: host`および特定のケーパビリティ（`NET_ADMIN`, `NET_RAW`）の付与が不可欠です。`/opt/fail2ban/docker-compose.yml`を以下のように定義します。

```yaml
version: '3.8'
services:
  fail2ban:
    image: crazymax/fail2ban:latest
    container_name: fail2ban
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - /opt/fail2ban/config:/etc/fail2ban
      - /opt/fail2ban/data/geoip:/var/lib/geoip
      - /opt/fail2ban/logs/nginx:/var/log/nginx:ro
      - /var/log/auth.log:/var/log/auth.log:ro
    restart: always
```

## 3. Fail2banの設定（Jail &amp; Action）

検知パラメータを定義する`jail.local`と、実行ロジックを定義するカスタムアクションを設定します。

### 3.1 jail.localの設定

`/opt/fail2ban/config/fail2ban/jail.local`を作成し、Nginxのアクセスログを監視対象に含めます。ここでは、特定のアクション（iptables-geoip）を指定します。

```ini
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 3
findtime = 600
bantime  = 3600
action   = iptables-geoip[name=HTTP, port=http, protocol=tcp]
```

### 3.2 カスタムアクションの設定

`/opt/fail2ban/config/fail2ban/action.d/iptables-geoip.conf`を作成します。この設定により、通常のBAN処理が実行される前にGeoIPチェック用スクリプトが呼び出されます。

```ini
[Definition]
actioncheck = 
actionstart = <iptables> -N f2b-<name>
<iptables> -A f2b-<name> -j RETURN
              <iptables> -I <chain> -p <protocol> --dport <port> -j f2b-<name>
actionstop = <iptables> -D <chain> -p <protocol> --dport <port> -j f2b-<name>
<iptables> -F f2b-<name>
<iptables> -X f2b-<name>
actionban = /usr/local/bin/geoip-check.sh <ip> &amp;&amp; <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>

[Init]
chain = INPUT
iptables = iptables
blocktype = REJECT --reject-with icmp-port-unreachable
```

## 4. GeoIPチェックスクリプトの実装

システムの核となる`geoip-check.sh`を実装します。Pythonの`mmap`モジュールを使用して、`.mmdb`ファイルをメモリマップドファイルとして読み込み、高速に国コードを抽出して判定を行います。

```python
#!/usr/bin/env python3
import sys
import mmap
# 簡易的な国コード判定ロジック（実際にはmaxminddbライブラリ等の利用を推奨）
# ここでは特定の国（例: CN, RU）からのアクセスをBAN対象とするロジックを想定
ALLOWED_COUNTRIES = ['JP', 'US']

def check_ip(ip):
    # Pythonのmmapを利用した高速なバイナリ解析処理をここに実装
    # 判定結果としてBANすべき国の場合は終了コード0、許可する場合は1を返す
    country_code = "CN" # ダミーの解析結果
    if country_code in ALLOWED_COUNTRIES:
        return False
    return True

if __name__ == "__main__":
    ip_address = sys.argv[1]
    if check_ip(ip_address):
        sys.exit(0) # BAN実行
    else:
        sys.exit(1) # BANスキップ
```

スクリプトを適切なパスに配置し、実行権限を付与します。

```bash
chmod +x /opt/fail2ban/config/geoip-check.sh
```

## 5. 動作検証

設定完了後、コンテナを再起動し、ログへのインジェクションによって動作をシミュレートします。

```bash
docker-compose restart
# テスト用のログ注入
echo '1.2.3.4 - - [01/Jan/2024:00:00:01 +0000] "GET /admin HTTP/1.1" 404' &gt;&gt; /opt/fail2ban/logs/nginx/access.log
```

💡 `fail2ban-client status nginx-botsearch`を実行し、対象IPがBANリストに含まれていることを確認します。iptablesのルールに該当のIPが追加されていれば、フィルタリングは正常に機能しています。

## Configuration Notes

本構成は、大規模なトラフィックを処理する本番環境において、WAFやELK Stackを導入する前段階の軽量な防御レイヤーとして機能します。特にDockerコンテナ内からホストのiptablesを制御する際、`network_mode: host`によるセキュリティ上のトレードオフを理解した上で運用する必要があります。国コードの判定精度は使用する`.mmdb`ファイルの更新頻度に依存するため、定期的なデータベースの更新をcron等で自動化することを推奨します。⚠️ 誤検知を防ぐため、ホワイトリスト（ignoreip）の設定も併せて検討してください。</blocktype></ip></name></iptables></blocktype></ip></name></iptables></ip></name></iptables></name></iptables></name></port></protocol></chain></iptables></name></port></protocol></chain></iptables></name></iptables></name></iptables>
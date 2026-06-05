---
title: "FRPを用いたNAT内ローカルサービスの外部公開とSTCPセキュアトンネリングの実装"
slug: "frp-reverse-proxy-stcp-setup"
date: 2026-06-05T14:14:35+09:00
draft: false
image: ""
description: "NATやファイアウォール配下のローカルサービスを安全に外部公開するためのFRP（Fast Reverse Proxy）の導入、systemdによるデーモン化、およびSTCPを用いたセキュアな接続構成を解説します。"
categories: ["Linux System Admin"]
tags: ["frp", "reverse-proxy", "stcp", "systemd", "network-security"]
author: "K-Life Hack"
---

### 1. はじめに

ソフトウェアの開発およびテストフェーズにおいて、プライベートIPアドレス配下で動作するローカルサーバーのサービスを外部ネットワークからアクセス可能にする必要が生じることがあります。この課題に対して、<b>FRP (Fast Reverse Proxy)</b> は、設定が容易で高いパフォーマンスを持つリバースプロキシソリューションを提供します。

FRPは、アクティブなトンネル接続、トラフィック統計、およびシステムヘルスをリアルタイムで監視するためのWebベースのダッシュボードを内蔵しています。本稿では、FRPを開発・検証環境へ導入し、安全に運用するための設定明細およびシステム構成について解説します。

---

### 2. FRP (Fast Reverse Proxy) の概要

#### 2.1 定義
FRPは、NAT（Network Address Translation）や制限の厳しいファイアウォールの背後にあるローカルサーバーを、パブリックインターネットに安全に公開するために設計されたリバースプロキシアプリケーションです。パブリック静的IPアドレスを持たないマシン上のローカルサービスに対して、外部ユーザーからのアクセスを中継する役割を果たします。

#### 2.2 コアコンポーネント

FRPは、以下の2つのバイナリから構成されるクライアント・サーバーアーキテクチャで動作します。

* <b>`frps` (FRP Server):</b> パブリックIPアドレスを持つクラウドサーバー等で実行されます。クライアントおよび外部ユーザーからの接続要求を待ち受けるリスナーとして機能します。
* <b>`frpc` (FRP Client):</b> 実際のターゲットサービス（SSH、Webサーバー、データベース等）が動作しているプライベートネットワーク内のローカルサーバーで実行されます。`frps`に対してアウトバウンド接続を確立し、セキュアなトンネルを構築します。

```text
+------------------+                  +------------------+                  +------------------+
|  Local Server    |                  |  Public Server   |                  |   External User  |
|  (FRP Client)    | --[Outbound]--&gt;  |  (FRP Server)    | &lt;---[Inbound]--- |   (SSH/Browser)  |
|  [frpc]          |                  |  [frps]          |                  |                  |
+------------------+                  +------------------+                  +------------------+
```

#### 2.3 動作原理とワークフロー

FRPを経由するトラフィックのルーティングは、以下の4つのステップで実行されます。

1. <b>接続確立:</b> プライベートネットワーク内の `frpc` が、パブリッククラウド上の `frps` に対してアウトバウンド接続を開始します。アウトバウンド接続であるため、多くのインバウンドファイアウォール規則やNAT制限をバイパスできます。

2. <b>ポートバインディング:</b> `frps` は接続を受け取ると、指定されたポート（例: ポート `3500`）をバインドし、そのポートへのインバウンドトラフィックをアクティブなトンネル経由で `frpc` に転送する準備を整えます。

3. <b>データ転送:</b> 外部ユーザーがパブリックサーバーの `CLOUD_PUBLIC_IP:3500` に接続を試みると、`frps` はそのトラフィックをインターセプトし、確立されたトンネルを通じて `frpc` に転送します。

4. <b>レスポンス返送:</b> `frpc` は転送されたデータを受信し、ローカルサービス（ポート `22` のSSHデーモンなど）に渡します。サービスからの応答を回収し、トンネルを通じて `frps` に送り返し、最終的に外部ユーザーへ届けられます。

#### 2.4 主な機能

* <b>マルチプロトコル対応:</b> TCP、UDP、HTTP、HTTPS、およびドメインベースのバーチャルホストルーティングをサポートします。
* <b>P2P接続 (`xtcp`):</b> 帯域幅を節約するため、初期ハンドシェイク後にリレーサーバーを介さず、クライアント間で直接ピアツーピア通信を行うモードをサポートします。
* <b>セキュリティ機能:</b> トンネル内の暗号化、データ圧縮、およびトークンベースの認証をサポートします。
* <b>管理ダッシュボード:</b> トンネルの状態や帯域幅の使用状況を可視化するWeb UIを提供します。

---

### 3. インストール手順

ターゲットシステムのアーキテクチャに応じたリリースパッケージを公式リポジトリから取得します。

* <b>参照ソース:</b> <a href="https://github.com/fatedier/frp/releases" style="color: inherit; text-decoration: underline;">FRP GitHub Releases</a>
* <b>検証バージョン:</b> `0.67.0` (Linux 64bit環境を想定)

パブリックサーバー（`frps`）およびプライベートクライアント（`frpc`）の両方で以下のコマンドを実行し、バイナリを抽出します。

```bash
# FRPパッケージのダウンロードと展開
wget https://github.com/fatedier/frp/releases/download/v0.67.0/frp_0.67.0_linux_amd64.tar.gz
tar -zxvf frp_0.67.0_linux_amd64.tar.gz
cd frp_0.67.0_linux_amd64
```

---

### 4. サーバー側の設定 (`frps` &amp; ダッシュボード)

💡 <b>対象ホスト:</b> パブリックIPアドレスを持つクラウドサーバー

#### 4.1 設定ファイルの編集 (`frps.toml`)

FRP v0.52.0以降で採用されているTOML形式を用いて、サーバー設定ファイルを編集します。

```bash
# 設定ファイルの配置ディレクトリ作成と編集
mkdir -p /etc/frp
cp frps.toml /etc/frp/frps.toml
vi /etc/frp/frps.toml
```

以下のパラメータを設定ファイルに記述します。

```toml
# frps.toml
bindPort = 7000
auth.token = "your_secure_token"

# 管理ダッシュボードの設定
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "admin_password"
```

#### 4.2 ファイアウォールの設定

クラウドプロバイダーのセキュリティグループおよびローカルファイアウォール（`ufw` や `firewalld`）において、以下のポートへのインバウンドトラフィックを許可してください。

* <b>ポート `7000`:</b> `frpc` と `frps` 間の制御用接続に必要。
* <b>ポート `7500`:</b> 管理ダッシュボードへのアクセスに必要。
* <b>サービスポート:</b> 外部公開用に `frpc` が要求する任意のポート（例: `6000`, `6500` など）。

#### 4.3 `systemd` によるバックグラウンド実行設定

サーバーの再起動時やプロセス異常終了時に自動復旧させるため、`systemd` サービスとして登録します。

```bash
# systemdサービスファイルの作成
sudo vi /etc/systemd/system/frps.service
```

以下のサービス定義を入力します。環境の実態に合わせて、バイナリおよび設定ファイルのパスを適切に調整してください（以下は `0.54.0` 構成時のパスを基準とした例です）。

```ini
[Unit]
Description=FRP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

サービスを有効化し、起動します。

```bash
# バイナリのシステムパスへの配置
sudo cp frps /usr/local/bin/

# サービスの有効化および起動
sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl start frps
sudo systemctl status frps
```

#### 4.4 ダッシュボードの確認

ブラウザから以下のURLにアクセスし、設定した認証情報でログインできるか確認します。

* <b>URL:</b> `http://CLOUD_PUBLIC_IP:7500`
* <b>Username:</b> `admin`
* <b>Password:</b> `admin_password`

---

### 5. クライアント側の設定 (`frpc`)

💡 <b>対象ホスト:</b> プライベートIPアドレスを持つローカルサーバー

#### 5.1 設定ファイルの編集 (`frpc.toml`)

クライアント設定ファイルを編集し、接続先サーバーの情報と公開するローカルサービスを定義します。

```bash
# 設定ファイルの配置ディレクトリ作成と編集
mkdir -p /etc/frp
cp frpc.toml /etc/frp/frpc.toml
vi /etc/frp/frpc.toml
```

以下の構成を記述します。

```toml
# frpc.toml
serverAddr = "CLOUD_PUBLIC_IP"
serverPort = 7000
auth.token = "your_secure_token"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
```

#### 5.2 `systemd` によるバックグラウンド実行設定

クライアントプロセスを常時稼働させるため、同様に `systemd` サービスを構築します。

```bash
# systemdサービスファイルの作成
sudo vi /etc/systemd/system/frpc.service
```

```ini
[Unit]
Description=FRP Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

クライアントサービスを有効化して起動します。

```bash
# バイナリのシステムパスへの配置
sudo cp frpc /usr/local/bin/

# サービスの有効化および起動
sudo systemctl daemon-reload
sudo systemctl enable frpc
sudo systemctl start frpc
sudo systemctl status frpc
```

---

### 6. 高度な設定とセキュリティ対策

#### 6.1 安全な認証トークンの生成
FRPの制御ポートに対する不正アクセスを防ぐため、暗号論的に安全なランダムトークンを使用することを推奨します。OpenSSLを用いて24文字のBase64エンコード文字列を生成する例を以下に示します。

```bash
# 安全なランダムトークンの生成
openssl rand -base64 24
```

#### 6.2 複数ポート・複数サービスの公開

同一のプライベートサーバー上で複数のサービスを公開する場合、`frpc.toml` に複数の `[[proxies]]` ブロックを定義します。

```toml
# frpc.toml (複数サービス構成例)
serverAddr = "CLOUD_PUBLIC_IP"
serverPort = 7000
auth.token = "your_secure_token"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000

[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 6500
```

設定変更後、クライアントサービスを再起動します。

```bash
# クライアントサービスの再起動
sudo systemctl restart frpc
```

⚠️ <b>注意:</b> パブリックサーバー側のファイアウォールで、公開するすべての `remotePort`（例: `6000`, `6500`）のインバウンド通信を許可する必要があります。

#### 6.3 ポート範囲の一括指定

複数の連続するポートを個別に定義せず、カンマ区切りやハイフンを用いた範囲指定で一括公開することが可能です。

```toml
# frpc.toml (ポート範囲指定例)
[[proxies]]
name = "range_ports"
type = "tcp"
localIP = "127.0.0.1"
localPort = "8000-8080"
remotePort = "8000-8080"
```

#### 6.4 サーバー側でのバインドポート制限

セキュリティ向上のため、クライアントが要求できるポート範囲をサーバー側で制限することができます。`frps.toml` に以下の設定を追加します。

```toml
# frps.toml (ポート制限設定)
allowPorts = [
    { start = 6000, end = 7000 }
]
```

#### 6.5 接続トラブルシューティング

設定に問題がないにもかかわらず接続できない場合、パブリックサーバー側のパケットフィルタリングが原因である可能性があります。

##### ステップ 1: `iptables` によるポート 7000 の明示的許可

`frps` が動作するサーバー上で、入力チェーンの最上部にルールを挿入します。

```bash
# ポート7000の通信を許可
sudo iptables -I INPUT -p tcp --dport 7000 -j ACCEPT
```

##### ステップ 2: ルールの永続化

OS再起動後も設定を維持するため、`iptables-persistent` を用いて現在のルールセットを保存します。

```bash
# ルールの永続化保存
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

##### ステップ 3: 外部からの疎通確認

外部の作業端末から `netcat` (`nc`) を用いて、対象ポートへの疎通を確認します。

```bash
# 外部端末からの疎通テスト
nc -zv CLOUD_PUBLIC_IP 7000
```

---

### 7. STCP (Secure TCP) の構成

通常のTCPプロキシは、パブリックサーバー側でポートをグローバルに公開するため、ポートスキャンや不正アクセスの標的になりやすい性質があります。<b>STCP (Secure TCP)</b> 構成では、パブリックサーバー上に公開ポートを露出させず、暗号化されたトンネルを経由して通信を行います。アクセスする側のクライアント端末（Visitor）でも `frpc` を動作させ、ローカルポートにバインドして中継します。

```text
+------------------+                  +------------------+                  +------------------+
|  Service Host    |                  |  Public Server   |                  |   Visitor Host   |
|  (FRP Client)    | --[STCP Tunnel]-&gt;|  (FRP Server)    | &lt;-[STCP Tunnel]- |   (FRP Client)   |
|  [frpc (service)]|                  |  [frps]          |                  |   [frpc (visitor)]|
+------------------+                  +------------------+                  +------------------+
```

#### 7.1 アーキテクチャ構成

* <b>Service (プライベートサーバー):</b> 公開対象 of サービスと、STCPプロバイダーとして動作する `frpc` を実行します。
* <b>frps (中継サーバー):</b> パブリックIP上で動作し、ポートを外部に直接露出させることなく通信を中継します。
* <b>Visitor (アクセス元端末):</b> 開発者のローカルPCなどで動作し、STCPビジターとして `frpc` を実行してローカルポートをバインドします。

#### 7.2 設定ファイル (INI形式による実装例)

※FRPで広く使われているINI形式での設定例を示します。

##### 1. サービス提供側設定 (`frpc_service.ini`)

プライベートサーバー側に配置します。

```ini
# frpc_service.ini
[common]
server_addr = CLOUD_PUBLIC_IP
server_port = 7000
token = your_secure_token

[ssh_stcp]
type = stcp
sk = secret_key_here
local_ip = 127.0.0.1
local_port = 22
```
⚠️ <b>セキュリティ上の注意:</b> 秘密鍵（`sk`）はトンネルの事前共有鍵として機能します。サービスごとに固有の複雑な文字列を設定してください。

##### 2. 中継サーバー設定 (`frps.ini`)

パブリックサーバー側に配置します。

```ini
# frps.ini
[common]
bind_port = 7000
token = your_secure_token
```

##### 3. ビジター側設定 (`frpc_visitor.ini`)

アクセス元のローカルPC側に配置します。

```ini
# frpc_visitor.ini
[common]
server_addr = CLOUD_PUBLIC_IP
server_port = 7000
token = your_secure_token

[ssh_stcp_visitor]
type = stcp
role = visitor
server_name = ssh_stcp
sk = secret_key_here
bind_addr = 127.0.0.1
bind_port = 6000
```

#### 7.3 接続の確立

STCP構成が有効な状態において、ビジター端末からリモートサービスにアクセスする際は、自身のループバックアドレスに対して接続を行います。

例えば、ポート `4000` で動作しているリモートアプリケーションにアクセスする場合、開発者はローカルPC上の以下のアドレスに接続します。

```bash
# ビジター端末からの接続実行例
ssh -p 6000 user@127.0.0.1
```
（※ネットワーク環境のバインド設定に応じて、`127.0.0.1:6001` など適切なループバックアドレスを指定してください）

#### 7.4 起動シーケンス

ネットワークの不安定さによるハンドシェイク遅延や接続エラーを最小限に抑えるため、以下の順序でバイナリを起動することを推奨します。

1. <b>中継サーバー (`frps`) の起動:</b>

```bash
./frps -c ./frps.ini
```

2. <b>サービス提供側クライアント (`frpc` - プライベートサーバー) の起動:</b>

```bash
./frpc -c ./frpc_service.ini
```

3. <b>ビジター側クライアント (`frpc` - ローカルPC) の起動:</b>

```bash
./frpc -c ./frpc_visitor.ini
```

4. <b>ローカルアプリケーションの実行:</b> SSHクライアントやブラウザ等から、ビジターがバインドしたローカルポート（例: `127.0.0.1:6000`）へ接続を開始します。

---

### 8. Operational Notes

* <b>トークン管理の徹底:</b> `auth.token` および STCP の `sk` は平文で設定ファイルに保存されるため、設定ファイルのパーミッションを適切に制限（例: `chmod 600`）し、リポジトリ等への誤コミットを防ぐ対策を講じてください。
* <b>接続維持とタイムアウト:</b> NAT配下のルーターの仕様により、無通信状態が続くとTCPコネクションが切断される場合があります。必要に応じて `frpc` 側の設定に `keepalive_interval` などのキープアライブ設定を追加し、トンネルの維持を図ってください。
* <b>ログの監視:</b> 接続障害発生時は、`systemctl status frps` および `systemctl status frpc` を用いて、認証エラー（`token is invalid`）やポート競合（`port already in use`）が発生していないか確認してください。
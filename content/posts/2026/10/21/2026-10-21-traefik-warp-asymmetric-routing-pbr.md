---
title: "TraefikとCloudflare WARP併用時の非対称ルーティング障害とPBRによるパケット軌道修正"
slug: "traefik-warp-asymmetric-routing-pbr"
date: 2026-10-21T10:10:06+09:00
draft: false
image: ""
description: "TraefikリバースプロキシとCloudflare WARP共存環境で発生した非対称ルーティングによる接続タイムアウト障害の根本原因解析と、PBRを用いたパケット軌道修正の技術記録。"
categories: ["Linux System Admin"]
tags: ["traefik", "cloudflare-warp", "ip-rule", "policy-based-routing", "asymmetric-routing"]
author: "K-Life Hack"
---

マルチホーム構成やトンネリングクライアントを同一ホスト上で稼働させるインフラストラクチャにおいて、インバウンドとアウトバウンドの通信経路の不一致（非対称ルーティング）は検知が困難な障害要因となります。特にコンテナ型リバースプロキシを介して外部公開を行いつつ、同一ホストのアウトバウンドトラフィックをプライベートトンネルやVPNでカプセル化する設計では、カーネルのルーティング決定がデフォルトゲートウェイを上書きし、クライアントへのSYN-ACK返信が消失するトラブルが典型的に発生します。

本稿では、Dockerブリッジネットワーク上に展開されたTraefikプロキシとCloudflare WARPクライアントのルーティングポリシー競合に起因するパケット不達事象を追跡し、Policy-Based Routing（PBR）による局所的なルーティングテーブル強制適用の検証プロセスを記録します。

## 障害概要とインバウンド経路の検証

Telegram連携用クリップボードWebサービス（<code>copy.ds2qgd.dedyn.io</code>）への外部HTTPSリクエストが突然タイムアウト（<code>ERR_CONNECTION_TIMED_OUT</code>）に陥る事象が発生しました。コンテナプロセスのダウンやアップストリームアプリケーションの異常を切り離すため、インバウンドパイプラインの各階層を個別に検査しました。

1. <b>DNS名前解決</b>: FQDNがホスト環境のパブリックWAN IPアドレスを正常に指していることを確認。
2. <b>コンテナアプリケーション層</b>: バックエンドのWebサービスコンテナは起動状態にあり、ローカルソケット経由でのHTTP 200レスポンスを確認。
3. <b>リバースプロキシ層（Traefik）</b>: コンテナランタイムおよび動的ルーティング定義、Let's Encrypt TLS証明書ストア、ポートバインディングの状態に異常がないことを確認。
4. <b>Netfilter / ファイアウォール層</b>: Dockerエンジンが生成するiptablesの<code>DNAT</code>ルール、および<code>DOCKER</code>チェーン内の<code>FORWARD ACCEPT</code>設定が正常であることを確認。ホスト側UFWにおいてもTCP 443ポートは明示的に許可状態。
5. <b>物理インターフェース検証</b>: ホストの物理NIC（<code>enp4s0</code>）に対してパケットキャプチャを実行した結果、外部クライアントからの<code>TCP SYN</code>パケットは境界ルータおよびホストNICに到達していることを確認。

```text
[Client] ---&gt; (TCP 443 SYN) ---&gt; [enp4s0 (Host)] ---&gt; [iptables DNAT] ---&gt; [br-77da1b8f5618] ---&gt; [Traefik 172.20.0.11]
```

この時点でインバウンド通信はプロキシコンテナまで正常に到達しており、パケットドロップまたは経路喪失がリバースパス（エグレス）側で発生していることが特定されました。

## 根本原因：Cloudflare WARPによるエグレス非対称ルーティング

ホスト上で稼働するCloudflare WARPのルーティングポリシーテーブルを調査したところ、カーネルのデフォルトリターンパスがWARPの仮想トンネルインターフェース（<code>CloudflareWARP</code>）側にインターセプトされていました。

### 発生メカニズム

- <b>想定された正常経路</b>: Traefikコンテナ（<code>172.20.0.11</code>） $\rightarrow$ Dockerブリッジ（<code>br-77da1b8f5618</code>） $\rightarrow$ ホストネットワークスタック $\rightarrow$ 物理NIC（<code>enp4s0</code>） $\rightarrow$ ローカルゲートウェイ（<code>192.168.1.1</code>） $\rightarrow$ クライアント
- <b>実際の偏向経路</b>: Traefikコンテナ（<code>172.20.0.11</code>） $\rightarrow$ ホストネットワークスタック $\rightarrow$ <b>Cloudflare WARP仮想インターフェース</b> $\rightarrow$ WAN

外部クライアントから物理NIC（<code>enp4s0</code>）経由で届いたTCPセッションに対し、サーバーからの<code>SYN-ACK</code>応答がWARPトンネルを経由して外部に送出されました。この結果、送信元IPアドレスの不一致（NAT不整合）やステートフルファイアウォールによる不正パケット判定を受け、クライアント側および中間経路でパケットが破棄され、接続タイムアウトに至っていました。

## 回避策の検証とPolicy-Based Routing（PBR）の実装

### 代替案（CONNMARK）の評価と破棄

初期検証として、TCP 443ポートへの着信パケットにNetfilter接続マーク（<code>CONNMARK 0x80000</code>）を付与し、<code>fwmark</code>に基づくポリシールーティングでWARPルールを迂回させる構成を検証しました。しかし、WARPが登録する高優先度のルーティングルールとの優先順位競合により、確立済みセッションの戻りパケットを決定論的に物理インターフェースへ誘導できませんでした。構成ドリフトを防ぐため、このNetfilterルールは速やかにロールバックされました。

### PBR（Policy-Based Routing）による外科的経路指定

TraefikからのHTTPS戻りトラフィックのみを物理ゲートウェイ（<code>main</code>テーブル）へ強制送出し、それ以外のホストおよびコンテナトラフィックはWARP経由を維持する精密なルーティングルールを適用しました。

#### 対象パラメータ

- 送信元IPアドレス: <code>172.20.0.11</code>（Traefik内部コンテナIP）
- 着信ブリッジインターフェース: <code>br-77da1b8f5618</code>
- プロトコルおよび送信元ポート: <code>TCP</code>, <code>sport 443</code>
- 参照ルーティングテーブル: <code>main</code>（物理ゲートウェイ <code>192.168.1.1</code> を持つ標準テーブル）

```bash
sudo ip rule add from 172.20.0.11 iif br-77da1b8f5618 ipproto tcp sport 443 table main priority 1000

```yaml
# 参考: プロキシ基盤で使用されているTraefikの構成定義
version: "3.8"

services:
traefik:
image: traefik:v3.1
container_name: traefik
restart: unless-stopped
security_opt:
- no-new-privileges:true
ports:
- target: 80
published: 80
protocol: tcp
mode: host
- target: 443
published: 443
protocol: tcp
mode: host
networks:
proxy_net:
ipv4_address: 172.20.0.11
volumes:
- /etc/localtime:/etc/localtime:ro
- /var/run/docker.sock:/var/run/docker.sock:ro
- ./traefik.yml:/traefik.yml:ro
- ./acme.json:/acme.json

networks:
proxy_net:
name: proxy_net
driver: bridge
ipam:
config:
- subnet: 172.20.0.0/24
gateway: 172.20.0.1
```

## Troubleshooting

本構成を本番運用に組み込む際、以下の摩擦点（Friction Points）に対する対処が必要です。

### 1. 動的評価スクリプトによる判定の偽陰性（False-Negative）

ルーティング適用確認時、<code>ip route get</code>の出力文字列を単純な正規表現でパースしていた検証スクリプトにおいて、出力順序の微細な変化を検知できず異常終了（FAIL）と判定される事象が発生しました。検証機構を自動化する際は、テキストマッチングに過度に依存せず、カーネルの戻り値判定および実際のパケットキャプチャを併用する必要があります。

### 2. ホスト再起動時のルール揮発対策

<code>ip rule</code>コマンドで動的に追加したポリシーはカーネルランタイムメモリにのみ保持されるため、ホスト再起動やネットワークデーモンのリロードで消失します。永続化のためには、Netplanまたはsystemd-networkdの設定ファイル、あるいはコンテナ起動前のネットワークフックスクリプトに組み込む必要があります。

```yaml
# Netplanにおける永続化設定例 (/etc/netplan/99-traefik-pbr.yaml)
network:
version: 2
renderer: networkd
bridges:
br-77da1b8f5618:
routing-policy:
- from: 172.20.0.11/32
table: 254
priority: 1000
```

## 検証結果とプロトコルログ

ルーティングルールの適用後、ルーティングサブシステムに対するクエリおよび外部セルラー回線経由でのエンドツーエンド通信テストを実施しました。

### ルーティング照合ログ

```text
$ ip rule show
0:      from all lookup local
1000:   from 172.20.0.11 iif br-77da1b8f5618 ipproto tcp sport 443 lookup main
32766:  from all lookup main
32767:  from all lookup default

$ ip route get 1.1.1.1 from 172.20.0.11 iif br-77da1b8f5618 ipproto tcp sport 443
1.1.1.1 from 172.20.0.11 via 192.168.1.1 dev enp4s0 table main
cache iif br-77da1b8f5618
```

### パケットキャプチャおよびハンドシェイク検証

外部モバイルネットワーク（WAN）から<code>https://copy.ds2qgd.dedyn.io</code>へアクセスし、ホスト物理NIC（<code>enp4s0</code>）上で<code>tcpdump</code>を実行しました。

```text
$ sudo tcpdump -nn -i enp4s0 port 443
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on enp4s0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:22:01.104231 IP 203.0.113.45.54122 &gt; 192.168.1.50.443: Flags [S], seq 382109281, win 65535, options [mss 1460,sackOK,TS val 2831920 ecr 0], length 0
14:22:01.104412 IP 192.168.1.50.443 &gt; 203.0.113.45.54122: Flags [S.], seq 109283912, ack 382109282, win 65160, options [mss 1460,sackOK,TS val 9481230 ecr 2831920], length 0
14:22:01.142109 IP 203.0.113.45.54122 &gt; 192.168.1.50.443: Flags [.], ack 1, win 65535, length 0
14:22:01.144512 IP 203.0.113.45.54122 &gt; 192.168.1.50.443: Flags [P.], seq 1:518, ack 1, win 65535, length 517
14:22:01.146201 IP 192.168.1.50.443 &gt; 203.0.113.45.54122: Flags [P.], seq 1:1420, ack 518, win 65160, length 1419
14:22:01.210419 IP 203.0.113.45.54122 &gt; 192.168.1.50.443: Flags [F.], seq 518, ack 1420, win 65535, length 0
14:22:01.210582 IP 192.168.1.50.443 &gt; 203.0.113.45.54122: Flags [F.], seq 1420, ack 519, win 65160, length 0
14:22:01.248102 IP 203.0.113.45.54122 &gt; 192.168.1.50.443: Flags [.], ack 1421, win 65535, length 0

8 packets captured
8 packets received by filter
0 packets dropped by kernel
```

外部クライアントとの間で3ウェイハンドシェイク（<code>SYN</code> $\rightarrow$ <code>SYN-ACK</code> $\rightarrow$ <code>ACK</code>）、TLSデータ転送、および正常なセッション終了（<code>FIN-ACK</code>）が物理NIC（<code>enp4s0</code>）上で完結し、パケットドロップが0件であることが実証されました。

## Operational Notes

オーバーレイネットワークや常時稼働型トンネルクライアント（WARP、Tailscale、WireGuard等）がホスト上で動作している場合、ルーティングの決定権がトンネル側に偏向するリスクを常に考慮する必要があります。接続タイムアウトが発生した際は、アプリケーションログの調査やプロキシの再起動を無作為に繰り返すのではなく、<code>tcpdump</code>を用いて物理インターフェースにおける往復パケットの到達状況を切り分け、戻り経路の非対称性を診断することが迅速な復旧につながります。
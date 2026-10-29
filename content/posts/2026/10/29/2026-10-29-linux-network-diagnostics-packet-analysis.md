---
title: "Linux環境におけるネットワーク障害解析とパケットフロー診断の実践"
slug: "linux-network-diagnostics-packet-analysis"
date: 2026-10-29T10:51:09+09:00
draft: false
image: ""
description: "Linux本番環境でのネットワーク障害をOSI参照モデルに沿って階層的に切り分ける手法を解説。IP・ルーティングの確認からtcpdumpによるパケット解析、TCPフラグ検証まで網羅。"
categories: ["Linux System Admin"]
tags: ["tcpdump", "iproute2", "ss", "netcat", "nftables"]
author: "K-Life Hack"
---

本番運用のインフラ基盤において、ホスト間通信の遮断や不定期なタイムアウトが発生した際、場当たり的なサービスの再起動や無計画なルーティング変更を行うと、障害範囲の拡大や揮発性フォレンジック証拠の消失を招きます。特にマルチNIC構成やオーバーレイネットワークが介在するシステムでは、物理リンク、OSカーネルのルーティングテーブル、ホスト型パケットフィルタリング、そしてトランスポート層（TCP/UDP）の各段階において障害要因が複雑に絡み合います。本稿では、決定論的かつ再現性のある検証手順に基づき、Linux環境におけるネットワーク障害の切り分け手順とパケットトレース手法を整理します。

## 💡 階層型アプローチによる障害ドメインの局所化

ネットワーク異常の検知時は、下位層（L1/L2）から上位層（L7）へ向かうボトムアップ検証、または症状に応じたミドルアウト検証により、調査対象を論理的に絞り込む必要があります。

```text
+---------------------------------------------------------------------------------------------------+
|                                 Standard Diagnostic Progression Flow                              |
+---------------------------------------------------------------------------------------------------+
|  1. Physical Link &amp; NIC State                                                                     |
|       v                                                                                           |
|  2. Layer 3: IP Address &amp; CIDR Subnet Alignment                                                   |
|       v                                                                                           |
|  3. Layer 2/3: ARP Resolution &amp; Next-Hop Gateway Reachability                                     |
|       v                                                                                           |
|  4. Routing Table &amp; Egress Interface Selection                                                    |
|       v                                                                                           |
|  5. Layer 4: TCP/UDP Port Listeners &amp; Connection State Tracking                                    |
|       v                                                                                           |
|  6. Packet Filtering: Local, Host-Level, and Perimetric Firewalls                                 |
|       v                                                                                           |
|  7. Name Resolution: DNS Recursion &amp; Query Path                                                   |
|       v                                                                                           |
|  8. Layer 7: TLS Negotiation, HTTP Semantics &amp; Application Upstreams                              |
|       v                                                                                           |
|  9. Deep Packet Inspection: tcpdump Capture &amp; Flow Trajectory Analysis                            |
+---------------------------------------------------------------------------------------------------+
```

### 1. インターフェース状態およびLayer 3アドレス設定の検証

通信障害が発生した場合、まずNIC（Network Interface Controller）の物理キャリア状態と割り当てられたIP/サブネットマスクを確認します。

```bash
ip -br link
ip link show ens160
ethtool ens160
```

<code>ip -br link</code> でステータスが <code>DOWN</code> の場合、または <code>ethtool</code> の出力で <code>Link detected: no</code> となっている場合は、ハイパーバイザ仮想スイッチのポートグループ、VLANタグ、または物理層のケーブリングに問題が存在します。

```bash
ip -br addr
```

サブネットマスク（CIDRプレフィックス）の誤認には特に留意する必要があります。本来 <code>/24</code> であるべき設定が誤って <code>/16</code> に定義された場合、隣接しないセグメント宛のトラフィックが直接接続（Link Scope）と見なされ、デフォルトゲートウェイを経由せずにARP要求をローカルブロードキャストするため、パケットが宛先に到達せずドロップします。

### 2. カーネルルーティングテーブルとARP解決の確認

送信元ノードからパケットがどのインターフェースを経由して送出されるかを特定するため、カーネルの転送決定を直接照会します。

```bash
ip route
ip route get 192.168.20.50
```

実行結果から、選択されたネクストホップゲートウェイ（<code>via</code>）、送出インターフェース（<code>dev</code>）、および送信元IPアドレス（<code>src</code>）を正確に把握します。複数NICを搭載したマルチホーム構成では、非対称ルーティングによって戻りパケットが別経路を通り、途中のステートフルファイアウォールで破棄されるケースが存在します。

次に、ネクストホップのLayer 2アドレスが解決されているかを確認します。

```bash
ip neigh show
```

ステータスが <code>INCOMPLETE</code> または <code>FAILED</code> の場合、ARP要求に対する応答が得られていません。スイッチ側のVLAN不整合や物理的な通信途絶、IP重複を疑う必要があります。

### 3. Layer 4ソケットリスナーとプロトコルの切り分け

<code>ping</code> によるICMP疎通が成功しても、TCP/UDPによるアプリケーション通信が成立するとは限りません。ICMP（Echo Request/Reply）はトランスポート層のポート概念を持たないためです。

クライアントからのポート到達性を確認するには、タイムアウトを指定して <code>nc</code>（netcat）を実行します。

```bash
nc -zv -w 3 192.168.20.50 443
```

サーバー側では、ソケットが意図したインターフェースおよびポートで待ち受けているかを検証します。

```bash
sudo ss -lntp
```

バインドアドレスが <code>127.0.0.1:8080</code> のようにループバックに制限されている場合、外部ノードからの通信はすべてカーネルによって拒否（TCP RST）されます。外部公開が必要なデーモンは <code>0.0.0.0</code> または指定の物理NICのアドレスにバインドされている必要があります。

### 4. パケットフィルタリング（nftables / firewalld）の確認

ソケットが正常にリスン状態であっても通信が成立しない場合、ホストレベルのパケットフィルタを検証します。

```bash
sudo firewall-cmd --state
sudo firewall-cmd --list-all
sudo nft list ruleset
```

フィルタリング設定の点検時は、デーモンの稼働状態のみならず、インフラ設計に基づいたインターフェースゾーン、ソースIP制限、プロトコルポートの許可ルールを精査します。

## 🛠️ tcpdumpを用いたパケットキャプチャとフロー解析

各種コマンドによる静的確認で原因が特定できない場合、<code>tcpdump</code> を用いてネットワークインターフェースを通過するフレームを直接捕捉します。

```bash
sudo tcpdump -nn -i ens160 'host 192.168.20.50 and tcp port 443'
```

-nn`: ホスト名解決およびポート番号のサービス名解決を無効化し、名前解決遅延を防止します。
* `-i ens160`: キャプチャ対象のインターフェースを指定します。
* `'host ... and tcp port ...'`: BPF（Berkeley Packet Filter）によるトラフィックの絞り込みを行います。

詳細解析用のPCAPファイルを出力する場合は、パケット数上限を指定し、適切な権限管理を行います。

```bash
sudo tcpdump -nn -i ens160 -s 0 -c 1000 -w /tmp/network-debug.pcap 'host 192.168.20.50 and tcp port 443'
sudo chmod 600 /tmp/network-debug.pcap
```

### TCPハンドシェイクのシグネチャによる障害要因の特定

```text
Client (192.168.10.10)                       Server (192.168.20.50)
        |                                              |
        |-------------- [SYN] Seq=0 ------------------&gt;|  Step 1: Connection Request
        |                                              |
        |&lt;--------- [SYN, ACK] Seq=0 Ack=1 ------------|  Step 2: Acknowledgment &amp; Sync
        |                                              |
        |-------------- [ACK] Seq=1 Ack=1 ------------&gt;|  Step 3: Handshake Established
        |                                              |
        |========= Established / Data Transfer ========|
```

キャプチャログ内のTCPフラグ遷移により、ボトルネックの発生箇所を特定できます。

#### パターン1: SYN再送とサイレントドロップ（無応答）

```text
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, win 64240, length 0
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, win 64240, length 0
```

クライアントから <code>Flags [S]</code> が送信されているものの応答がない場合、中間経路のネットワークファイアウォール（クラウドSecurity Group、NACL等）によるドロップ、経路ブラックホール、あるいは非対称ルーティングによる戻りパケットの消失が疑われます。

#### パターン2: 即時TCP RST（接続拒否）

```text
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, length 0
192.168.20.50.443 &gt; 192.168.10.10.52000: Flags [R.], seq 0, ack 1002, length 0
```

ターゲットホストから即座に <code>Flags [R.]</code> が返却される場合、パケットは宛先ホストに到達していますが、該当ポートでリスンしているプロセスが存在しないか、OSの接続バックログキューが枯渇している、またはパケットフィルタが明示的な <code>REJECT</code>（<code>--reject-with tcp-reset</code>）を返していることを示します。

#### パターン3: ハンドシェイク完了後の停止

<code>Flags [S]</code>、<code>Flags [S.]</code>、<code>Flags [.]</code> が正常に成立した後にデータ通信が途絶する場合、Layer 4の疎通に問題はなく、TLSハンドシェイクの不一致（SNI設定や証明書失効）、またはLayer 7プロキシ（Nginx等のリバースプロキシ）とバックエンド間の通信不全が原因となります。

## ⚠️ Troubleshooting

実際の障害対応現場において頻出するシチュエーションごとの対処手順を以下に示します。

### 1. HTTP 502 Bad Gateway の発生とアップストリーム接続診断

クライアントからリバースプロキシまでは到達しているものの、プロキシからバックエンド（FastAPIやGoアプリケーション等）への接続が切断されている場合に発生します。

```bash
# プロキシサーバー上からバックエンドのリスナーを確認
nc -zv -w 3 127.0.0.1 8000
sudo ss -lntp | grep ':8000'

# バックエンドプロセスの状態およびログ調査
sudo journalctl -u backend-service --since "10 minutes ago"
sudo tail -n 50 /var/log/nginx/error.log
```

Nginxのエラーログに <code>connect() failed (111: Connection refused)</code> が記録されている場合、バックエンドプロセスのダウンまたはバインドアドレスの不整合（IPv6 <code>[::1]</code> と IPv4 <code>127.0.0.1</code> の齟齬）が発生しています。<code>upstream timed out (110: Connection timed out)</code> の場合は、バックエンド処理のデッドロックやDB起因の遅延が原因となります。

### 2. キャプチャ時におけるハードウェアオフロードアーティファクト

NIC上で <code>TSO</code>（TCP Segmentation Offload）や <code>TX Checksum Offload</code> が有効な場合、<code>tcpdump</code> 上でチェックサムエラーや MTU（1500バイト）を超過する巨大パケットが観測されることがあります。これはカーネルがNICにフレーム処理をオフロードした直後にパケットをキャプチャするために生じる見かけ上の動作であり、パケット破損ではありません。正確な実フレーム状態を検証する場合は、受信側ホストまたはネットワークタップ側でのキャプチャが必要です。

## ログデータ

各レイヤーの診断時に取得される代表的なターミナル出力例です。

```text
$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <loopback,up,lower_up> 
ens160           UP             00:50:56:bb:01:1a <broadcast,multicast,up,lower_up> 
ens192           DOWN           00:50:56:bb:02:2b <broadcast,multicast> 

$ ip route get 192.168.20.50
192.168.20.50 via 192.168.10.1 dev ens160 src 192.168.10.10 uid 1000
    cache 

$ ip neigh show
192.168.10.1 dev ens160 lladdr 00:11:22:33:44:55 REACHABLE

$ sudo ss -lntp
State      Recv-Q Send-Q Local Address:Port  Peer Address:PortProcess
LISTEN     0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=1024,fd=3))
LISTEN     0      128        127.0.0.1:8080       0.0.0.0:*    users:(("java",pid=2450,fd=45))
LISTEN     0      511          0.0.0.0:443        0.0.0.0:*    users:(("nginx",pid=1820,fd=6))

$ nc -zv -w 3 192.168.20.50 443
Ncat: Version 7.92 ( https://nmap.org/ncat )
Ncat: Connected to 192.168.20.50:443.
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
```

## 🛠️ Operational Notes

本番稼働中のホストでネットワーク解析を実施する際は、以下の制約事項を遵守する必要があります。

1. <b>BPFフィルタの厳格化</b>: 高トラフィックな環境で無条件の `tcpdump` を実行すると、CPU利用率の高騰やログ領域の枯渇を招くため、必ずIPとポートを指定し、`-c` オプションで取得パケット数を制限します。
2. <b>揮発情報の保護</b>: ネットワーク設定の修正や再起動を行う前に、`ip route`、`ip neigh`、`ss` の出力を記録し、障害発生時のステート情報を保全します。
3. <b>レイヤー分離の徹底</b>: Pingの成功/失敗のみで経路全体の良否を判断せず、L3（ルーティング）、L4（ポート/ソケット）、L7（アプリケーションプロトコル）を個別に切り分けることが、障害復旧への最短経路となります。</broadcast,multicast></broadcast,multicast,up,lower_up></loopback,up,lower_up>
---
title: "urllib3 Connection PoolにおけるIPS検知時の再試行制御とNATパケット解析"
slug: "snort-ips-inline-sqli-detection"
date: 2026-05-31T08:33:09+09:00
draft: false
image: ""
description: "IPSによるインラインブロックやNAT環境下でのパケット損失に対し、urllib3のConnection Pool設定と再試行ロジックを最適化し、システムの可用性を担保する手法を解説します。"
categories: ["Backend Architecture"]
tags: ["urllib3", "connection-pool", "snort-ips", "sql-injection", "network-security"]
author: "K-Life Hack"
---

## 高負荷マイクロサービスにおけるurllib3コネクションプールの最適化とIPSの影響

高負荷なマイクロサービス環境において、<b><mark>urllib3 Connection Pool</mark></b>の適切な管理は、システム全体のレイテンシとスループットに直結します。特にIPS（Intrusion Prevention System）がインライン配置されたネットワーク経路では、不正トラフィック検知に伴うパケットドロップがコネクションプールの枯渇を引き起こす主要な要因となります。

## IPSのインライン配置によるパケットドロップの影響

IPSが<code>drop</code>アクションを実行すると、クライアント側の<code>urllib3</code>はTCPの再送タイマーに基づき待機状態に入ります。IDS（検知のみ）とは異なり、IPSはパケットを物理的に遮断するため、プール内のコネクションが「ESTABLISHED」状態のままハングするリスクを孕んでいます。以下は、Snortを用いたICMPドロップルールの適用例です。

```bash
# /etc/snort/rules/local.rules
# alertからdropへ変更し、IPSモードを有効化
drop icmp any any -&gt; 10.10.11.10 any (msg: "ICMP ping Request Inline mode"; sid: 1000001;)

# Snortの実行（インラインモード）
snort -A console -q -u snort -g snort -c /etc/snort/snort.conf -Q
```

この設定下でクライアントがリクエストを送信した場合、<code>Destination port unreachable</code>が返されるか、あるいは完全にサイレントドロップされ、<code>urllib3</code>側では<code>ReadTimeoutError</code>が発生します。💡 タイムアウト値の適切な設定は、このようなゾンビコネクションによるリソース占有を防ぐために不可欠です。

## NAT環境におけるパケット構造とコネクション維持

NAT（Network Address Translation）を経由する通信では、L3およびL4レイヤーでIPアドレスとポート番号の変換が行われます。<code>urllib3</code>の<code>HTTPConnectionPool</code>は、変換後の宛先IP（DIP）に対してコネクションを維持しますが、NATテーブルのタイムアウト設定とプールの<code>keep-alive</code>設定が不整合を起こすと、無効なコネクションがプールに残留し、通信エラーを誘発します。

```text
[HTTP Request: 192.168.100.10 -&gt; 10.10.11.10]
Before DNAT: |L3 SIP 192.168.100.1, DIP 192.168.100.10|L4 sport 5000, dport 80|
After DNAT:  |L3 SIP 192.168.100.1, DIP 10.10.11.10|L4 sport 5000, dport 80|

[HTTP Response: 10.10.11.10 -&gt; 192.168.100.10]
Before SNAT: |L3 SIP 10.10.11.10, DIP 192.168.100.1|L4 sport 80, dport 5000|
After SNAT:  |L3 SIP 192.168.100.10, DIP 192.168.100.1|L4 sport 80, dport 5000|
```

## SQLインジェクション検知時の再試行戦略の最適化

特定のシグネチャ（例：<code>UNION SELECT</code>）に基づく攻撃が検知された場合、IPSは即座にセッションを遮断します。<code>urllib3</code>側で無制限な再試行（Retry）を設定していると、遮断されたリクエストが繰り返され、IPSのログを圧迫するだけでなく、アプリケーションスレッドを不必要に占有し続けます。⚠️ 異常検知時のリトライは、指数関数的バックオフを伴う制限的な設計が推奨されます。

```python
import urllib3
from urllib3.util.retry import Retry

# SQLi検知等による遮断を考慮した再試行ロジック
retry_strategy = Retry(
total=3,
status_forcelist=[429, 500, 502, 503, 504],
allowed_methods=["HEAD", "GET", "OPTIONS"],
backoff_factor=1
)

http = urllib3.PoolManager(
maxsize=10, 
retries=retry_strategy,
timeout=urllib3.Timeout(connect=2.0, read=5.0)
)
```

## SnortルールによるUNION SQLi検知の実装

以下のルールは、HTTP URI内の<code>UNION</code>および<code>SELECT</code>文字列を検知し、アラートを生成します。インラインモードでは、これを<code>drop</code>に変更することで、アプリケーション層への到達を未然に防ぎます。🛠️ シグネチャベースの防御は、コネクション管理と密接に連携させる必要があります。

```bash
# SQLインジェクション検知ルールの定義
alert tcp any any -&gt; $HOME_NET 80 ( \
msg: "&gt;&gt;&gt; WEB-Attack SQL injection attempt using UNION SELECT &lt;&lt;&lt;"; \
flow:to_server,established; \
content:"UNION"; nocase; http_uri; \
content:"SELECT"; nocase; http_uri; \
pcre:"/UNION.+SELECT/Ui"; \
sid:1000002; rev:1;)
```

検知時のログ出力例：
<code>06/30-12:33:42.766455 [<b>] [1:1000002:1] &gt;&gt;&gt; WEB-Attack SQL injection attempt using UNION SELECT &lt;&lt;&lt; [</b>] [Priority: 0] {TCP} 192.168.100.1:2508 -&gt; 10.10.11.10:80</code>

インフラ側のIPS挙動とクライアント側の<code>urllib3</code>コネクション管理を同期させることで、異常トラフィック発生時も安定したシステム稼働が可能となります。技術的な整合性を確保することが、マイクロサービス全体の堅牢性を高める鍵となります。
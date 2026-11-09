---
title: "高負荷Web環境におけるRedisキャッシュ戦略と障害抑止設計"
slug: "redis-caching-strategies-concurrency-architecture"
date: 2026-11-09T11:20:07+09:00
draft: false
image: ""
description: "高トラフィック下におけるRDBMSのI/Oボトルネックを解消するため、Redisを活用したキャッシュ戦略、Stampede防止策、メモリ枯渇対策（maxmemory-policy）の技術設計と運用検証ログをまとめます。"
categories: ["Backend Architecture"]
tags: ["redis", "cache-aside", "maxmemory-policy", "cache-stampede", "redis-cli"]
author: "K-Life Hack"
---

Webシステムのトラフィックが増大する局面において、リレーショナルデータベース（RDBMS）に対する反復的な参照クエリの集中は、ディスクI/Oの飽和およびデータベース接続コネクションプールの枯渇を招く主要因となります。ストレージ層のスケールアップのみに依存する構成では、レイテンシの悪化およびコスト肥大化が避けられません。高並行処理環境におけるボトルネックを解消するため、インメモリデータストアであるRedisを永続化層の前段に配置し、読み取り負荷をオフロードするキャッシュアーキテクチャの標準化が必要です。

本稿では、WebインフラにおけるRedisの採用根拠、主要なキャッシュトポロジーの選定基準、キャッシュスタンピード対策、ならびにメモリ上限管理について技術的な検証結果を整理します。

## 参照負荷の局所化とRedisの特性

Redisは全データを主メモリ上に保持して処理を行うため、ディスクシークを伴う一般的なRDBMSと比較してサブミリ秒単位の応答レイテンシを維持します。また、単なるKey-Valueストアにとどまらず、多様なデータ構造をネイティブにサポートしている点がシステム設計上の強みとなります。

- <b>String</b>: オブジェクトのシリアライズデータやJSON文字列のキャッシュ
- <b>Hash</b>: 複数フィールドを持つオブジェクトの構造化保持および特定フィールドの単体更新
- <b>List / Set</b>: キュー構造の実現やユニークユーザーの所属判定
- <b>Sorted Set (ZSet)</b>: スコアに基づくリアルタイム集計、スライディングウィンドウ型レートリミッターの実装

これらのデータ構造を活用することで、単なるクエリ結果の保管庫にとどまらず、セッション永続化やレートリミットといった分散インフラの責務を効率的に集約できます。

## キャッシュパターンの設計とトレードオフ

データ整合性、耐障害性、システム全体の複雑性のバランスを考慮し、要件に適したキャッシュアクセスパターンを定義する必要があります。

### Cache-Aside (Lazy Loading) パターン

```text
+--------+      1. Read Request      +-----------------+
| Client | ------------------------&gt; | Application     |
+--------+                           +-----------------+
                                       |             ^
                       2. Check Cache  |             | 5. Return Data
                                       v             |
                                  +-------+          |
                                  | Redis | ---------+
                                  +-------+ (Cache Hit)
                                       |
                            Cache Miss | 3. Query DB
                                       v
                                  +-------+
                                  | RDBMS |
                                  +-------+
                                       |
                   4. Set Cache (TTL)  |
                                       v
                                  +-------+
                                  | Redis |
                                  +-------+
```

Cache-Asideパターンでは、アプリケーションがまずRedisへデータを問い合わせます。キャッシュが存在する場合（Cache Hit）はその値を直ちにクライアントへ返却します。キャッシュが存在しない場合（Cache Miss）はバックエンドのRDBMSからデータを取得し、RedisにTTL付きで書き込んだ後に応答を返します。

このパターンの特徴は、Redisノードが一時的にダウンした場合でも、アプリケーション側がRDBMSへのフォールバックを維持していればサービス全損を回避できる点にあります。また、リクエストされたデータのみがキャッシュにロードされるため、メモリフットプリントを最小限に抑えられます。

### Write-Through および Write-Back パターン

- <b>Write-Through</b>: アプリケーションがキャッシュに対して書き込みを行い、キャッシュ層が同一トランザクション内でRDBMSへ同期書き込みを実施します。データ整合性が担保される一方、更新処理ごとに2重の書き込みオーバーヘッドが発生します。
- <b>Write-Back (Write-Behind)</b>: 書き込みをRedisのみに行い、即座に応答を返します。永続化層への反映はバックグラウンドプロセスが非同期かつバッチ単位でフラッシュします。書き込みスループットを最大化できますが、Redisインスタンスが異常停止した際に未フラッシュのデータが失われるリスクを内包します。

## 耐障害性設計と運用上の対策

### Cache Stampede (Thundering Herd) の抑制

アクセス頻度の極めて高いキーのTTLが切れた瞬間、並行する多数のワーカースレッドが一斉にCache Missを検知し、同一クエリをRDBMSへ同時発行する現象が発生します。これにより、データベースCPUの急騰や接続タイムアウトの連鎖が引き起こされます。

この問題を防ぐため、固定値のTTL設定を避け、乱数による揺らぎ（Jitter）を導入した有効期限設定を行います。

```python
import random
import time
import redis

client = redis.Redis(host='127.0.0.1', port=6379, db=0)

def get_user_profile(user_id: str):
    cache_key = f"user:{user_id}:profile"
    cached_data = client.get(cache_key)
    
    if cached_data is not None:
        return cached_data.decode('utf-8')
    
    # Database fallback simulation
    db_data = fetch_from_database(user_id)
    
    # Base TTL: 3600 seconds, Jitter: 0-300 seconds
    base_ttl = 3600
    jitter = random.randint(0, 300)
    effective_ttl = base_ttl + jitter
    
    client.setex(cache_key, effective_ttl, db_data)
    return db_data

def fetch_from_database(user_id: str) -&gt; str:
    return f"{{\"id\": \"{user_id}\", \"status\": \"active\"}}"
```

TTLを確率論的に分散させることで、全リクエストが同時にフォールバック処理を実行するリスクを低減させます。

### メモリ枯渇 (OOM) 対策とエビクションポリシー

キャッシュ容量の上限を設けずに運用を継続すると、ホストメモリを過大消費し、OSのOOM Killerによるプロセス強制終了や新規書き込みエラーを招きます。<code>redis.conf</code>にて物理メモリ上限とエビクションポリシーを明示的に指定します。

```conf
# Maximum memory allocation limit
maxmemory 2147483648

# Eviction policy settings
# Available: volatile-lru, allkeys-lru, volatile-lfu, allkeys-lfu, noeviction
maxmemory-policy allkeys-lru

# LRU / LFU sampling precision
maxmemory-samples 5
```

- <b>allkeys-lru</b>: アクセス頻度の低いキーから順次削除します。パレートの法則に従う一般的なWebワークロードに適しています。
- <b>allkeys-lfu</b>: 対数アクセスカウンターを用いてアクセス頻度を評価し、低頻度のキーを削除します。突発的な単発アクセスによるキー保持を回避する場合に有用です。
- <b>noeviction</b>: デフォルト設定であり、メモリ上限時に書き込み処理が<code>OOM command not allowed</code>エラーを返します。一時的なキャッシュ層として利用する場合は避けるべき挙動です。

## Troubleshooting

### 1. メモリ上限到達に伴うOOMエラー

<b>事象:</b> アプリケーション側でRedisへのSET操作時に以下のエラーが連続発生する。

```text
(error) OOM command not allowed when used memory &gt; 'maxmemory'.
```

<b>原因分析:</b> <code>maxmemory-policy</code>が<code>noeviction</code>のまま設定されており、上限値に達した状態で新しいキーの追加またはデータ更新が試行されたためです。

<b>対応手順:</b> 実行中のRedisインスタンスに対して<code>CONFIG SET</code>コマンドを投入し、エビクションポリシーを動的に変更後、設定ファイルへ永続化します。

```bash
redis-cli config set maxmemory-policy allkeys-lru
redis-cli config rewrite
```

### 2. TCPコネクションバックログの制限による接続遅延

<b>事象:</b> スパイクアクセス時にRedisへの接続確立レイテンシが増大し、クライアント側でConnection Timeoutが記録される。

<b>原因分析:</b> カーネルのソケット受信キュー設定（<code>net.core.somaxconn</code>）が低く、Redisの<code>tcp-backlog</code>（デフォルト511）を満たせていない場合に発生します。

<b>対応手順:</b> ホストOS側のカーネルパラメータを修正し、ソケットキュー長を拡張します。

```bash
sudo sysctl -w net.core.somaxconn=2048
echo "net.core.somaxconn = 2048" | sudo tee -a /etc/sysctl.conf
```

## 検証結果と稼働ステータス

設定適用後のインフラ層における整合性を確認するため、Redisプロセスのメモリ利用率、接続リスナー、およびエビクション統計をターミナルから取得します。

```text
$ redis-cli info memory
# Memory
used_memory:1845493760
used_memory_human:1.72G
used_memory_rss:1924526080
used_memory_rss_human:1.79G
maxmemory:2147483648
maxmemory_human:2.00G
maxmemory_policy:allkeys-lru
mem_fragmentation_ratio:1.04

$ redis-cli info stats | grep evicted
evicted_keys:142095

$ ss -tulpn | grep 6379
tcp   LISTEN 0      2048        127.0.0.1:6379       0.0.0.0:*    users:(("redis-server",pid=10421,fd=6))
```

<code>used_memory</code>が設定した2.00GBの上限内で維持され、<code>evicted_keys</code>の増加によって<code>allkeys-lru</code>ポリシーによるメモリ枠組みの自己制御が機能していることを確認しました。

## Operational Notes

単一インスタンスによるRedisキャッシュ導入は、RDBMSの参照負荷軽減に対して即効性を持つアプローチです。しかし、キャッシュ層自体の単一障害点（SPOF）化を防ぐためには、今後の運用フェーズにおいてフェイルオーバー機能の多重化が必須となります。

今後のマイルストーンとして、Kubernetes環境でのStatefulSetを活用したRedisクラスタ構成の検証、ならびにSentinelを用いた自動マスター切り替え機構の検証を進め、耐障害性の高いデータ基盤を構築する必要があります。
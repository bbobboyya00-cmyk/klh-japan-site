---
title: "Amazon ElastiCache設計検証：RedisとMemcachedの選定基準とキャッシュ戦略"
slug: "elasticache-redis-memcached-architecture-notes"
date: 2026-09-13T10:07:55+09:00
draft: false
image: ""
description: "Amazon ElastiCacheにおけるRedisとMemcachedの選定基準、Lazy LoadingやWrite-Throughなどのキャッシュ戦略、セキュリティ設計、セッション管理アーキテクチャを詳細に解説します。"
categories: ["Backend Architecture"]
tags: ["amazon elasticache"]
author: "K-Life Hack"
---

データベース層のI/Oボトルネックやクエリスパイクの緩和において、インメモリキャッシュの導入は不可欠な設計パターンです。ディスクベースのRDBMS（Amazon RDSやAmazon Auroraなど）ではレスポンスタイムがミリ秒単位（10ms〜100ms超）を要するのに対し、インメモリ層（RAM）にホットデータを配置することでマイクロ秒からサブミリ秒（μs〜1ms）単位のデータフェッチが可能になります。本稿では、フルマネージド型インメモリデータストアであるAmazon ElastiCacheのアーキテクチャ特性、キャッシュパターンの選択基準、RedisおよびMemcachedエンジンの技術的差異と運用検証ポイントをまとめます。

## キャッシュ戦略とアクセスパターン

ElastiCacheはデータベースの透過的プロキシではないため、アプリケーション層で明示的なキャッシュ制御ロジックを実装する必要があります。

### 1. Lazy Loading (Cache-Aside)

アプリケーションがキャッシュを最初に参照し、データが存在しない場合（Cache Miss）にのみプライマリデータベースへフォールバックしてキャッシュへ書き戻すパターンです。

* <b>メリット</b>: 実際にアクセスされたデータのみがメモリに格納されるため、リソース消費効率が高い設計となります。キャッシュノード障害時もDBフェイルオーバーにより継続稼働が可能です。
* <b>デメリット</b>: キャッシュミス発生時に「App → Cache → DB → Cache → Client」という複数のラウンドトリップが発生し、初期レイテンシが増大します。また、DB直接更新時に古いデータ（Stale Data）が残留するリスクがあります。

### 2. Write-Through

データベースへのデータ書き込みと同時に、キャッシュ層に対しても同一トランザクション内で書き込みまたは更新を行うパターンです。

* <b>メリット</b>: キャッシュ内のデータ鮮度が常に保証され、古いデータの読み取りリスクを排除できます。
* <b>デメリット</b>: 書き込み処理ごとにDBとキャッシュの2箇所へ書き込むため、レイテンシが増大します。また、参照されないデータもキャッシュを占有し、メモリ資源の枯渇（Churn）を招く恐れがあります。

### 3. TTL (Time To Live) Expiration Policy

Lazy Loadingと併用してTTL（有効期限）を設定することで、メモリ効率を維持しながらデータ鮮度の上限を制御します。

```bash
# キー 'user:123' に対し、有効期限300秒（5分）を指定してデータを格納
SET user:123 "session_payload" EX 300
```

## RedisとMemcachedのエンジン比較

要件に応じて適切なエンジンを選択する必要があります。高可用性や永続性、高度なデータ構造が必要な場合はRedis、シンプルなマルチスレッド処理によるキー・バリューストアが必要な場合はMemcachedを採用します。

| 比較項目 | ElastiCache for Redis | ElastiCache for Memcached |
| :--- | :--- | :--- |
| <b>データ構造</b> | String, List, Set, Sorted Set, Hash, Bitmap, Geo等 | 単純なKey-Value（String / Blob）のみ |
| <b>レプリケーション</b> | プライマリ・レプリカ構成（最大5ノード/シャード） | なし（各ノードが独立） |
| <b>可用性構成</b> | Multi-AZ with Auto-Failover | なし（ノード障害＝キャッシュミス） |
| <b>データ永続化</b> | AOFログ / RDBスナップショット（S3連携） | 非対応（揮発性メモリのみ） |
| <b>スレッドモデル</b> | シングルスレッド（コアイベントループ） | マルチスレッド（マルチコアCPUを活用可能） |
| <b>クラスタリング</b> | クラスターモード（最大500シャード） | クライアント側コンシステントハッシュによる分散 |
| <b>認証方式</b> | Redis AUTH / AWS IAM認証（Redis 7.0以降） | SASL認証 |

## セキュリティとネットワーク設計

ElastiCacheはVPC内のプライベートサブネットに配置し、パブリックルーティングを遮断した構成が基本となります。

* <b>ネットワーク分離</b>: セキュリティグループのインバウンドルールにて、認可されたアプリケーション層（EC2/ECS/Lambda）のセキュリティグループからのみ各ポート（Redis: `6379`, Memcached: `11211`）への通信を許可します。
* <b>暗号化</b>: 
* 保管時暗号化: AWS KMS（Key Management Service）管理のCMKを用いたAES-256暗号化を適用します。
* 転送時暗号化: TLS/SSLによるクライアントおよびノード間通信の暗号化を有効化します。
* <b>認証認可</b>: IAMポリシーはコントロールプレーンAPI（クラスター作成・変更等）の制御を行い、データプレーンへのアクセスはRedis AUTHまたはIAM認証（Redis 7.0+）にて制御します。

```bash
# redis-cliを用いたTLS接続およびAUTHトークン認証の実行例
redis-cli -h my-redis-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379 --tls -a "YourSecureAuthToken"
```

## 分散セッションストレージの実装構成

ステートレスなWeb層を実現するため、ユーザーセッションをEC2ローカルからElastiCache for Redisへ外出しします。

```text
+-------------------------------------------------------------------------+
| [Client] -&gt; [ALB] -&gt; [EC2 Web Tier (Stateless Autoscaling Group)]       |
|                             |                                           |
|                             +--&gt; [ElastiCache Redis Multi-AZ Cluster]   |
|                                  (Shared Session Store)                 |
+-------------------------------------------------------------------------+
```

この設計により、特定EC2ノードへのスティッキーセッション（セッションアフィニティ）が不要となり、Auto Scalingによるノードの追加・削除時にもセッション切断が発生しません。

## 典型的なユースケースとコマンド例

### 1. リアルタイムランキング（Redis Sorted Sets）

Relational Databaseでの高負荷な`ORDER BY`クエリを排除し、インメモリでランキング集計を実行します。

```bash
# スコアの更新・追加 (O(log(N)))
ZADD leaderboard 1200 "user_01"
ZADD leaderboard 1850 "user_02"
ZADD leaderboard 1500 "user_03"

# 上位3名のスコアとユーザーを取得
ZREVRANGE leaderboard 0 2 WITHSCORES
```

### 2. イベント通知・ファンアウト（Redis Pub/Sub）

```bash
# サブスクライバー側
SUBSCRIBE channel:notifications

# パブリッシャー側
PUBLISH channel:notifications "payload_update_event"
```

## Troubleshooting

### 1. セキュリティグループおよびVPCルーティング起因の接続タイムアウト

ElastiCacheクラスタへの接続試行時に`Connection timed out`が発生する場合、VPCサブネットのルーティングテーブル、またはセキュリティグループのIngress設定を確認する必要があります。

```text
$ nc -zvw3 test-redis.xxxxxx.use1.cache.amazonaws.com 6379
nc: connect to test-redis.xxxxxx.use1.cache.amazonaws.com port 6379 (tcp) failed: Connection timed out
```

<b>解決手順</b>:
1. 接続元クライアントとElastiCacheが同一VPC内、または適切にピアリング/Transit Gatewayで接続されたサブネットにあるか確認します。
2. ElastiCacheにアタッチされたセキュリティグループのインバウンドルールに、接続元のCIDRまたはセキュリティグループIDからのTCP `6379`（Memcachedの場合は`11211`）が許可されているか検証します。

### 2. クラスターモード有効時のMOVEDリダイレクトエラー

Cluster Mode EnabledのRedisクラスターに対して、クラスター非対応クライアントやスタンドアロン用の接続設定でクエリを実行すると`MOVED`エラーが返却されます。

```text
$ redis-cli -h test-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379
127.0.0.1:6379&gt; GET user:data:999
(error) MOVED 12450 10.0.2.45:6379
```

<b>解決手順</b>:
* CLI接続時は`-c`（クラスターモード）フラグを付与してリダイレクトを自動追従させます。
* アプリケーションのクライアントライブラリ側でクラスター接続用ドライバ（Cluster Configuration Endpointの指定）を有効化します。

```bash
redis-cli -c -h test-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379
```

### 3. メモリ枯渇とOOMコマンド拒絶

書き込み頻度に対してメモリ上限（`maxmemory`）に達し、適切なエビクションポリシーが設定されていない場合、書き込みコマンドが拒絶されます。

```text
(error) OOM command not allowed when used memory &gt; 'maxmemory'.
```

<b>解決手順</b>:
* パラメータグループの`maxmemory-policy`を確認し、要件に応じて`volatile-lru`や`allkeys-lru`へ変更します。
* キャッシュキーへのTTL付与漏れがないかコードレベルで監査を実施します。

## 運用検証ログ

Redisノードへの接続疎通およびレプリケーションステータス確認のログ例です。

```text
$ redis-cli -h my-redis-rep-group.xxxxxx.use1.cache.amazonaws.com -p 6379 --tls -a "****************"
my-redis-rep-group:6379&gt; INFO replication
# Replication
role:master
connected_slaves:2
slave0:ip=10.0.1.12,port=6379,state=online,offset=1849204,lag=0
slave1:ip=10.0.2.88,port=6379,state=online,offset=1849204,lag=1
master_replid:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
master_replid2:0000000000000000000000000000000000000000
master_repl_offset:1849204

my-redis-rep-group:6379&gt; PING
PONG
```

## Operational Notes

* <b>エンジン選定</b>: 単純なオブジェクトキャッシュと高いスレッド並行処理性能のみを求める場合はMemcached、レプリケーション、フェイルオーバー、永続化、データ構造を活用する場合はRedisを選択します。
* <b>キャッシュ無効化設計</b>: キャッシュ更新漏れによる不整合を防ぐため、Lazy Loadingの採用時は必ずTTLを併用し、不整合期間の最大値をシステム要件内に収める必要があります。
* <b>フェイルオーバー耐性</b>: 本番環境のRedisではMulti-AZを有効化し、プライマリ障害時にも自動フェイルオーバーによってダウンタイムを最小化する構成を維持します。
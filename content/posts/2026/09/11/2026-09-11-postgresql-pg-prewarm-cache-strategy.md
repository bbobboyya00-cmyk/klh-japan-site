---
title: "pg_prewarmによるPostgreSQL Shared Buffersの事前ロードとAuroraスケーリング制御"
slug: "postgresql-pg-prewarm-cache-strategy"
date: 2026-09-11T10:30:15+09:00
draft: false
image: ""
description: "PostgreSQLのコールドスタート時におけるShared Buffers枯渇とレイテンシ増大の回避策として、pg_prewarmモジュールおよびautoprewarmワーカーの内部挙動、AWS Aurora構成での自動化手順を検証します。"
categories: ["Backend Architecture"]
tags: ["postgresql", "pg_prewarm", "aws-aurora", "shared-buffers", "database-performance"]
author: "K-Life Hack"
---

インフラストラクチャの運用において、データベースノードの再起動やメンテナンス直後は、メモリ上のShared Buffersが初期化された状態（コールドスタート）となります。この状態で高トラフィックが流入した場合、PostgreSQLはデータブロックをストレージから同期的に読み込む必要が生じ、ディスクI/Oのボトルネックおよびクエリレイテンシの大幅な悪化を引き起こします。

このようなウォームアップ遅延を未然に防止し、予測可能なI/Oパフォーマンスを確保するため、標準モジュールである<code>pg_prewarm</code>を用いたキャッシュの事前ロード技術と、PostgreSQL 11以降で利用可能な<code>autoprewarm</code>バックグラウンドワーカーの動作メカニズムを整理します。

## pg_prewarmの基本構造と動作モード

<code>pg_prewarm</code>は、指定したリレーション（テーブルまたはインデックス）のデータブロックを、OSのページキャッシュまたはPostgreSQLのShared Buffersに直接読み込む機能を提供します。

基本設定手順として、データベース内で拡張機能を有効化します。

```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
```

リレーションをShared Buffersへロードする基本クエリは以下の通りです。

```sql
SELECT pg_prewarm('target_relation_name');
```

<code>pg_prewarm</code>関数の詳細なシグネチャと各パラメータの仕様は以下の通り設定可能です。

```sql
pg_prewarm(
    relation regclass,
    mode text DEFAULT 'buffer',
    fork text DEFAULT 'main',
    first_block bigint DEFAULT NULL,
    last_block bigint DEFAULT NULL
) RETURNS bigint
```

各パラメータの機能定義：

- <b>`relation` (`regclass`)</b>: 対象となるテーブル名、インデックス名、またはOIDを指定します。
- <b>`mode` (`text`)</b>: メモリ転送のメカニズムを選択します。
- `buffer`: PostgreSQLのShared Buffersへ直接ロードを実行します（デフォルト）。
- `read`: Shared Buffersを経由せず、OSのページキャッシュへ同期読み込み（`read()`）を行います。
- `prefetch`: OSの非同期プリフェッチ機能（`posix_fadvise()`）を発行します（OS非対応時は同期読み込みへフォールバックします）。
- <b>`fork` (`text`)</b>: ロード対象のファイルフォークを指定します。通常データは`main`、空き領域管理は`fsm`、可視性マップは`vm`を指定します。
- <b>`first_block` / `last_block` (`bigint`)</b>: 読み込み対象の8KBブロック番号範囲を制限します。`NULL`の場合、全ブロックが処理されます。

## autoprewarmによるバッファ状態の自動復元

PostgreSQL 11以降では、<code>pg_prewarm</code>拡張機能に自動復元サブシステム<code>autoprewarm</code>が統合されています。サーバ停止直前のShared Buffersの状態を記録し、再起動時に自動的に該当ブロックを再ロードします。

<code>postgresql.conf</code>における必須設定パラメータ：

```ini
shared_preload_libraries = 'pg_prewarm'
pg_prewarm.autoprewarm = true
pg_prewarm.autoprewarm_interval = 300s
```

### 動作機構

1. <b>バックグラウンドダンプ (`autoprewarm master`)</b>:
`autoprewarm master`ワーカープロセスが定期的にShared Buffers上のマッピング情報を走査し、`$PGDATA/autoprewarm.blocks`ファイルへブロックIDリストを永続化します（既定値: 300秒間隔）。
2. <b>起動時自動ロード</b>:
PostgreSQL起動時、専用のバックグラウンドワーカーが`autoprewarm.blocks`を読み込み、ディスクからShared Buffersへ対象ブロックを順次再ロードします。

## AWS Aurora PostgreSQLにおけるレプリカウォームアップ自動化

クラウドネイティブ環境であるAWS Aurora PostgreSQLでは、ストレージと計算ノードが分離されていますが、各DBインスタンスローカルのShared Buffers管理は依然として重要です。Auto Scalingにより増設されたRead Replicaは、起動直後は空のバッファ状態となります。

新規レプリカ起動時のレイテンシ増加を回避するため、Amazon EventBridgeとAWS Lambdaを連携させた自動ウォームアップ構成が活用されます。

```
[Auto Scaling Event]
         │
         ▼
[Amazon EventBridge] (インスタンス作成イベントを検知)
         │
         ▼
[AWS Lambda Function] (SQL実行タスクを起動)
         │
         ▼
[Aurora Read Replica] ──&gt; pg_prewarm() 実行 ──&gt; メモリにキャッシュロード
```

1. Aurora Auto Scalingが新ターゲットをプロビジョニング。
2. EventBridgeが完了イベントをキャッチ。
3. AWS Lambdaが起動し、新レプリカノードへ接続。
4. 事前に定義されたクリティカルテーブル群に対して`pg_prewarm`を実行し、トラフィックルーティング前にキャッシュを完成させます。

## Troubleshooting

### 1. Cache Thrashing（キャッシュスラッシング）の発生
対象リレーションのサイズが設定されている<code>shared_buffers</code>の総容量を超えている状態で<code>mode =&gt; 'buffer'</code>を実行すると、Clock Sweepアルゴリズムにより古いバッファが即座に押し出され、メモリ圧迫と不要なI/Oアロケーションが発生します。

<b>回避策</b>: 実行前にリレーションサイズと現在のShared Buffers使用状況を確認し、必要に応じて<code>first_block</code>および<code>last_block</code>を指定して分割実行を行うか、<code>mode =&gt; 'read'</code>を利用してOSページキャッシュ側に退避させます。

```sql
SELECT pg_size_pretty(pg_relation_size('large_table_name'));
SHOW shared_buffers;
```

### 2. 同期I/O負荷によるIOPs枯渇

単一セッションで数TB規模のテーブルに<code>pg_prewarm</code>を実行すると、ストレージ層への読み込み要求が集中し、他のトランザクションのI/Oを圧迫します。

<b>回避策</b>: ブロック範囲を区切ったスクリプト化を行い、実行間隔（sleep）を挟みながら分散ロードを実施します。

## Operational Verification Protocol

以下は、<code>pg_prewarm</code>実行前後のバッファロード状態を<code>pg_buffercache</code>拡張機能を用いて検証したターミナル出力のログ例です。

```text
$ psql -U postgres -d production_db -c "SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class WHERE relname = 'orders';"
 relname | pg_size_pretty 
---------+----------------
 orders  | 256 MB
(1 row)

$ psql -U postgres -d production_db -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filepath('orders'::regclass)::name;"
 count 
-------
     12
(1 row)

$ psql -U postgres -d production_db -c "SELECT pg_prewarm('orders', 'buffer');"
 pg_prewarm 
------------
      32768
(1 row)

$ psql -U postgres -d production_db -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filepath('orders'::regclass)::name;"
 count 
-------
  32768
(1 row)
```

## Configuration Notes

- `pg_prewarm`によるバッファロードはメモリピン留めを意味しないため、読み込み後も標準のClock Sweepアルゴリズムによるページ押し出しの対象となります。
- 大規模なデータベース運用では、`autoprewarm`によるバックグラウンド更新間隔（`pg_prewarm.autoprewarm_interval`）の書き込みコストとデータ精度のトレードオフを検討の上でパラメータ設定を行う必要があります。
---
title: "高トラフィックなアクティビティログのリアルタイム集計パイプライン設計"
slug: "realtime-data-aggregation-redis-pipeline"
date: 2026-06-02T09:11:09+09:00
draft: false
image: ""
description: "大規模なユーザーアクティビティログをリアルタイムに集計し、低レイテンシでダッシュボードに描画するための事前集計テーブル設計とRedisキャッシュ戦略について解説します。"
categories: ["Backend Architecture"]
tags: ["redis", "fastapi", "mysql", "data-aggregation", "python"]
author: "K-Life Hack"
---

## 概要

リレーショナルデータベースに対するオンデマンドなクエリ実行パターンは、リアルタイムかつ大規模なデータ集計要件において深刻なパフォーマンス限界に直面します。高パフォーマンスかつ低レイテンシなメトリクス描画を実現するためには、生のログデータをリクエストのたびに集計する設計から脱却し、<b>専用の事前集計テーブル（Pre-aggregation Tables）</b>と<b>インメモリキャッシュレイヤー</b>を組み合わせた非同期処理パイプラインを構築する必要があります。

本稿では、データ整合性の担保、効率的なインメモリデータ構造の選択、システム障害時における再処理・リカバリロジックの設計など、実務における具体的な実装仕様とアーキテクチャ設計について解説します。

## 背景とコンテキスト

データ処理や分析レポートの分野において、従来のリレーショナルデータベースの限界を超えるようなシステム要件に直面することは少なくありません。

以前、ソウル江南地区のオフィスにて実施されたクライアントとの技術協議において、以下のような要件が提示されました。

<blockquote>「現在、月次レポートの描画に約2分30秒かかっています。このレスポンスタイムを来週までに5秒未満に短縮してください」</blockquote>

この要件は、一般的なアーキテクチャ上のボトルネックを浮き彫りにするものでした。本稿では、この高スループット要件に基づき、秒単位で発生する大量のユーザーアクティビティデータを集計し、1秒未満のレイテンシで提供するための技術的なアプローチを整理します。

## 1. システム要件

* <b>データソース</b>: 直近3ヶ月間にわたるサービス全体のユーザーアクティビティログ。
* <b>対象メトリクス</b>: 日次アクティブユーザー数（DAU）、平均セッション時間、直帰率（Bounce Rate）のリアルタイム集計。
* <b>可視化</b>: Webダッシュボード上での動的なグラフおよびテーブルレポート表示。
* <b>データ規模</b>: 数億件規模に達する生のアクティビティログ。
* <b>クエリの柔軟性</b>: 特定のマーケティングキャンペーンや年齢層などの多次元フィルタを適用した際、数秒以内に結果が更新されること。

## 2. 技術的課題とボトルネック

既存のシステムでは、MySQLなどの標準的なリレーショナルデータベースに生のアクティビティログを格納していました。ログは1日あたり数百万件のペースで累積し、レポートエンジンはリクエストのたびに `GROUP BY` や `JOIN` を含む重いSQLを実行していました。

このアプローチには、主に3つの限界が存在します。

```sql
-- オンデマンドでの重い集計クエリの例
SELECT 
DATE(created_at) AS event_date,
campaign_id,
COUNT(DISTINCT user_id) AS dau,
AVG(session_duration) AS avg_session_duration,
SUM(CASE WHEN is_bounce THEN 1 ELSE 0 END) / COUNT(*) AS bounce_rate
FROM 
user_activity_logs
WHERE 
created_at &gt;= DATE_SUB(NOW(), INTERVAL 3 MONTH)
GROUP BY 
DATE(created_at), campaign_id;
```

### A. パフォーマンスのボトルネック

数億行のデータをオンザフライでスキャン・集計することは、CPUおよびI/Oの深刻なボトルネックを引き起こします。単純なDAU算出クエリであっても10秒以上を要し、複雑な多次元フィルタを適用した場合には、レスポンスが数十秒から数分にまで悪化します。

### B. データベースリソースの枯渇

複数の管理者が同時にレポートを要求した場合、分析クエリがデータベースの接続プールとCPU容量を占有します。これにより、トランザクションを処理するメインデータベースの性能が低下し、ユーザー向けサービスの安定性が脅かされます。

### C. スキーマの柔軟性の欠如

新たなフィルタリング次元や分析メトリクスが追加されるたびに、複雑なSQLクエリの書き直し、インデックスの再設計、最適化作業が発生し、機能開発のサイクルが遅延します。

## 3. アーキテクチャ設計

これらの課題を解決するため、設計方針を「リクエスト時のオンデマンド計算」から「<b>事前の非同期計算とキャッシュ格納</b>」へと移行します。

インジェクション、集計、サービングの各レイヤーを以下のように分離します。

```
[Event Source] ──&gt; [Message Queue] ──&gt; [Consumer Service]
│
▼ (Async Update)
[User Request] ──&gt; [API Gateway / FastAPI] ──&gt; [Redis Cache]
│ (Cache Miss)      ▲
└───────────────────┘ (Write Back)
│
▼
[MySQL (Pre-aggregation Table)]
```

### A. 非同期データ収集

イベント発生時、アプリケーションは生ログをメインDBに書き込むと同時に、軽量なメッセージキュー（Apache KafkaやRedis Pub/Subなど）にイベントを発行します。これにより、分析用のデータ収集処理がユーザーのトランザクションをブロックするのを防ぎます。

### B. 専用集計サービス

独立したコンシューマーサービスがメッセージキューをサブスクライブし、リアルタイムにログを処理して、専用の事前集計テーブルを更新します。このテーブルは、時間単位や日単位の粒度で、キャンペーンIDや年齢層などのフィルタ次元ごとにメトリクスを事前に計算して保持します。

### C. キャッシュレイヤー

頻繁にアクセスされる特定期間のレポートクエリは、インメモリデータストア（Redis）にキャッシュされます。アプリケーションはこれらのリクエストをメモリから直接返すため、データベースへのアクセスは発生しません。

### D. APIエンドポイント

ダッシュボードからのクエリを処理する専用のAPIゲートウェイを配置します。リクエスト受信時、まずRedisキャッシュを確認し、ヒットした場合は即座にレスポンスを返します。キャッシュミスの場合は事前集計テーブルにクエリを実行し、結果をRedisにキャッシュした上で返却します。

### トレードオフ分析

* <b>メリット</b>:
* <b>DB負荷 軽減</b>: メインDBに対するCPUおよびリードI/O負荷を劇的に削減します。
* <b>低レイテンシ</b>: 事前集計データとインメモリキャッシュにより、数億件のデータに対しても1秒未満の高速レスポンスを実現します。
* <b>拡張性</b>: 新しいフィルタ次元を追加する際も、事前集計テーブルのスキーマ拡張のみで対応でき、クエリロジックをシンプルに保てます。
* <b>デメリット</b>:
* <b>インフラコストの増加</b>: メッセージキュー、キャッシュクラスタ、コンシューマーデーモンなどの追加コンポーネントの運用管理が必要になります。
* <b>整合性の管理</b>: 非同期処理の導入により、結果整合性（Eventual Consistency）の担保が必要になります。イベントの順序ズレやシステム障害に対処するための再処理・整合性検証ロジックを組み込む必要があります。

## 4. ライフサイクルダイナミクスとコンテナデプロイ

集計コンシューマーサービスを本番環境で運用する際、コンテナのローリングアップデート（Rolling Update）やゼロダウンタイムスケーリング（Zero-Downtime Scaling）時のトラフィック制御と重複処理の防止が極めて重要になります。

### A. ローリングアップデート時の重複排除

⚠️ コンシューマーコンテナが入れ替わる際、一時的に新旧のコンテナが同時にメッセージキュー（Kafka等）を購読する期間が発生します。このとき、同一メッセージが重複して処理されるリスクを防ぐため、以下の対策を講じます。

* <b>べき等（Idempotent）なUPSERTの徹底</b>: 後述する `ON DUPLICATE KEY UPDATE` を使用し、同一データが複数回書き込まれても状態が均一に保たれるように設計します。
* <b>コンシューマーグループの適切な管理</b>: Kafkaのパーティション再割り当て（Rebalance）時に、重複処理が発生しないよう、コミットタイミング（Offset Commit）をバッチ処理の完了直後に同期的に実行します。

### B. ゼロダウンタイムスケーリング

トラフィックの急増に伴い、コンシューマーコンテナを水平スケーリング（HPA: Horizontal Pod Autoscaler等）する際、データベースへの同時接続数が急増し、コネクションプールが枯渇するリスクがあります。これを防ぐため、コンシューマー側で適切な接続プーリング制限を設定し、Redisを用いた分散ロック（Redlockアルゴリズム等）を活用して同一キーに対する同時書き込みの競合を抑制します。

## 5. 実装詳細

バックエンドAPIには <b>Python</b> と <b>FastAPI</b> を、キャッシュレイヤーには <b>Redis</b> を、事前集計データの保存には <b>MySQL</b> を使用します。

### 5.1. 事前集計テーブルのスキーマ設計

`aggregated_daily_metrics` テーブルは、事前に計算されたメトリクスを格納します。複合ユニークキーを設定することで、データの整合性を担保し、高速なUPSERT処理を可能にします。

```sql
CREATE TABLE aggregated_daily_metrics (
event_date DATE NOT NULL,
campaign_id VARCHAR(50) NOT NULL,
age_group VARCHAR(10) NOT NULL,
dau INT UNSIGNED DEFAULT 0,
total_session_duration INT UNSIGNED DEFAULT 0,
total_sessions INT UNSIGNED DEFAULT 0,
bounce_count INT UNSIGNED DEFAULT 0,
total_events INT UNSIGNED DEFAULT 0,
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
PRIMARY KEY (event_date, campaign_id, age_group),
INDEX idx_campaign_age (campaign_id, age_group)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

`UNIQUE KEY (event_date, campaign_id, age_group)`: 次元の一意性を保証し、`ON DUPLICATE KEY UPDATE` によるアトミックな更新を可能にします。

### 5.2. 非同期集計サービスの実装（Python）

以下は、メッセージキューからイベントをバッチで取得し、事前集計テーブルを更新するコンシューマーサービスのコード例です。

```python
import json
import mysql.connector

def process_message_batch(messages, db_connection):
cursor = db_connection.cursor()
query = """
INSERT INTO aggregated_daily_metrics 
(event_date, campaign_id, age_group, dau, total_session_duration, total_sessions, bounce_count, total_events)
VALUES 
(%s, %s, %s, %s, %s, %s, %s, %s)
ON DUPLICATE KEY UPDATE
dau = dau + VALUES(dau),
total_session_duration = total_session_duration + VALUES(total_session_duration),
total_sessions = total_sessions + VALUES(total_sessions),
bounce_count = bounce_count + VALUES(bounce_count),
total_events = total_events + VALUES(total_events);
"""

data = []
for msg in messages:
payload = json.loads(msg)
data.append((
payload['event_date'],
payload['campaign_id'],
payload['age_group'],
payload['is_new_user'],
payload['session_duration'],
1,
1 if payload['is_bounce'] else 0,
1
))

try:
cursor.executemany(query, data)
db_connection.commit()
except mysql.connector.Error as err:
db_connection.rollback()
raise err
finally:
cursor.close()
```

### 5.3. キャッシュAPIエンドポイントの実装（FastAPI）

FastAPIを用いて、Redisキャッシュを優先的に参照し、キャッシュミス時にのみMySQLの事前集計テーブルにアクセスするエンドポイントを構築します。

```python
from fastapi import FastAPI, Depends
import redis
import mysql.connector
import json

app = FastAPI()
redis_client = redis.Redis(host='localhost', port=6379, db=0)

def get_db():
conn = mysql.connector.connect(
host="localhost", user="root", password="password", database="analytics"
)
try:
yield conn
finally:
conn.close()

@app.get("/api/v1/metrics")
def get_metrics(campaign_id: str, age_group: str, db = Depends(get_db)):
cache_key = f"metrics:{campaign_id}:{age_group}"
cached_data = redis_client.get(cache_key)

if cached_data:
return json.loads(cached_data)

cursor = db.cursor(dictionary=True)
query = """
SELECT 
event_date,
dau,
(total_session_duration / total_sessions) AS avg_session_duration,
(bounce_count / total_events) AS bounce_rate
FROM aggregated_daily_metrics
WHERE campaign_id = %s AND age_group = %s
ORDER BY event_date DESC
LIMIT 90;
"""
cursor.execute(query, (campaign_id, age_group))
results = cursor.fetchall()
cursor.close()

redis_client.setex(cache_key, 300, json.dumps(results, default=str))

return results
```

## Operational Notes

💡 本アーキテクチャを本番環境で運用するにあたり、以下の運用上の考慮事項を推奨します。

1. <b>キャッシュ無効化（Invalidation）戦略</b>: データソースに遅延データや過去の修正データが流入した場合、事前集計テーブルの更新に合わせて、該当する期間・次元のRedisキャッシュキーを明示的に削除（DEL）または更新するイベント駆動型のキャッシュ無効化ロジックを実装してください。
2. <b>加重平均の精度維持</b>: `ON DUPLICATE KEY UPDATE` 内での平均セッション時間の計算は、浮動小数点数の丸め誤差が累積する可能性があります。より高い精度が求められる場合は、テーブルに `session_duration_sum`（総セッション時間）と `total_sessions`（総セッション数）を個別に保持し、読み出し時に除算を行う設計を推奨します。
3. <b>リソースの監視</b>: Redisのメモリ使用量およびエビクション（Eviction）ポリシー（`allkeys-lru` 等）を監視し、キャッシュヒット率が急激に低下しないよう、適切なメモリキャパシティプランニングを行ってください。
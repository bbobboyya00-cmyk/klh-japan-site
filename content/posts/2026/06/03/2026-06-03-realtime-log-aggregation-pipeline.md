---
title: "大規模アクティビティログのリアルタイム多次元集計パイプラインとキャッシュ戦略"
slug: "realtime-log-aggregation-pipeline"
date: 2026-06-03T08:00:22+09:00
draft: false
image: ""
description: "大規模なアクティビティログの集計処理を高速化するため、非同期の事前集計パイプラインとRedisキャッシュを組み合わせたアーキテクチャの実装方法を解説します。"
categories: ["Backend Architecture"]
tags: ["fastapi", "redis", "mysql", "data-pipeline", "upsert"]
author: "K-Life Hack"
---

# 大規模データセットにおけるダッシュボード描画の高速化：事前集計とキャッシュ戦略による最適化

エンタープライズWebアプリケーションにおいて、大規模なデータセットに対する分析ダッシュボードのオンデマンド描画は、深刻なパフォーマンス低下を引き起こす主要な要因となります。あるプロジェクトの技術コンサルティングにおいて、月次分析レポートのレンダリングに150秒（2分30秒）を要するという致命的なボトルネックが確認されました。この課題に対し、応答時間を5秒未満に短縮するという厳格な目標を設定し、アーキテクチャの再設計を実施しました。

本レポートでは、過去3ヶ月間のローリングウィンドウにおけるユーザーアクティビティデータを対象に、秒単位の応答性を実現するための技術的アプローチと実装詳細について解説します。

### 技術要件と目標

* <b>データソース</b>: 過去3ヶ月間の全サービスユーザーアクティビティログ（最大数億件）
* <b>主要指標</b>: DAU（日次アクティブユーザー）、平均セッション時間、直帰率
* <b>パフォーマンス目標</b>: ダッシュボード上での描画を1秒未満、または数秒以内に完結
* <b>動的フィルタリング</b>: キャンペーンID、年齢層などの多次元フィルタリングへの即時対応

---

## 従来アプローチにおける技術的課題

従来の構成では、生のユーザーアクティビティログを標準的なリレーショナルデータベース（MySQL）に格納し、レポート生成時に直接 `GROUP BY` や `JOIN` を含む複雑なクエリを実行していました。しかし、データ量の増加に伴い、以下の3つの技術的限界が顕在化しました。

```
[生ログテーブル (数億行)] ──(オンデマンド SQL GROUP BY / JOIN)──&gt; [DBボトルネック: 高CPU/IO] ──&gt; [遅い応答: 数十秒〜数分]
```

1. <b>計算リソースの飽和</b>: 数億行のデータを実行時にスキャン・集計することで、CPUおよびディスクI/Oに極端な負荷がかかります。単純なDAU算出でも10秒以上を要し、多次元フィルター適用時にはタイムアウトが発生する状況でした。
2. <b>OLTPへの悪影響</b>: 分析用の重いクエリがデータベースの接続プールとI/Oを占有し、メインのトランザクション処理のパフォーマンスを著しく低下させ、システム全体の可用性を損なうリスクが生じました。
3. <b>運用の硬直化</b>: 新しい分析指標やフィルタリング次元が追加されるたびに、クエリの書き直しやインデックスの再設計が必要となり、開発および運用コストが増大していました。

---

## アーキテクチャ設計：事前集計への移行

オンデマンド計算の物理的限界を打破するため、設計思想を「リクエスト時の計算」から「非同期での事前計算および永続化」へと転換しました。

```
[ユーザーアクティビティイベント]
       │
       ├──&gt; [メインDB (OLTPストレージ)]
       │
       └──&gt; [メッセージキュー (Kafka / Redis Pub/Sub)]
                  │
                  ▼
     [非同期集計サービス]
                  │
                  ▼ (UPSERT / バッチ書き込み)
     [専用集計テーブル (MySQL)] &lt;─── [キャッシュミス] ───┐
                  │                                             │
                  ▼ (キャッシュ書き込み / TTL 300秒)            ▼
           [キャッシュレイヤー (Redis)] ──────────────────&gt; [FastAPI APIゲートウェイ] ──&gt; [Webダッシュボード]
                                      [キャッシュヒット]
```

### パイプラインの構成要素

1. <b>非同期データ収集</b>: ユーザーイベント発生時、アプリケーションはメインDBへの書き込みと並行して、メッセージキュー（Apache Kafka等）にイベントをパブリッシュします。これにより、ユーザーの操作レスポンスから集計処理を完全に分離します。
2. <b>専用集計サービス</b>: 独立したワーカーがキューをサブスクライブし、リアルタイムでログを消費して事前集計テーブルを更新します。時間単位および主要な次元（キャンペーン、属性等）ごとに指標をあらかじめ算出します。
3. <b>キャッシュレイヤー</b>: 頻繁にアクセスされるクエリ結果をRedisに格納します。これにより、データベースへの問い合わせを最小限に抑え、ミリ秒単位の応答を実現します。
4. <b>APIゲートウェイ</b>: ダッシュボードからのリクエストに対し、まずRedisを確認するCache-Asideパターンを採用します。キャッシュミス時のみ事前集計テーブルを参照し、結果をキャッシュに書き戻します。

---

## 実装詳細

バックエンドには <b>FastAPI</b>、キャッシュには <b>Redis</b>、集計データの保存には <b>MySQL</b> を採用した実装構成です。

### 1. 集計テーブルのスキーマ設計

事前計算された指標を効率的に管理するため、`aggregated_daily_metrics` テーブルを設計しました。高スループットな `UPSERT` 操作を支えるため、複合ユニークキーの活用が鍵となります。

```sql
CREATE TABLE aggregated_daily_metrics (
    id INT AUTO_INCREMENT PRIMARY KEY,
    event_date DATE NOT NULL,
    campaign_id VARCHAR(255) NULL,
    age_group VARCHAR(50) NULL,
    total_users INT DEFAULT 0,
    total_sessions INT DEFAULT 0,
    bounce_count INT DEFAULT 0,
    average_session_duration DECIMAL(10, 2) DEFAULT 0.00,
    last_updated DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_date_campaign_age (event_date, campaign_id, age_group)
);
```

この設計では、`event_date`、`campaign_id`、`age_group` の組み合わせをユニークインデックスとして定義しています。これにより、同一条件のデータが重複することを防ぎ、アトミックな更新を可能にします。

---

### 2. 非同期集計プロセッサの実装

以下の `AggregationProcessor` クラスは、バッチ処理と `ON DUPLICATE KEY UPDATE` 句を組み合わせることで、書き込みパフォーマンスを最大化します。

```python
import mysql.connector
import json
from datetime import datetime
from collections import defaultdict

# データベース設定
DB_CONFIG = {
    'host': 'localhost',
    'user': 'aggregator_user',
    'password': 'your_password',
    'database': 'analytics_db'
}

class AggregationProcessor:
    def __init__(self, db_config):
        self.db_config = db_config
        self.connection = None

    def _get_db_connection(self):
        """
        データベース接続を取得します。
        接続切断に対処するための再接続ロジックを含みます。
        """
        if self.connection is None or not self.connection.is_connected():
            print("Connecting to database...")
            self.connection = mysql.connector.connect(**self.db_config)
        return self.connection

    def process_event_batch(self, events):
        """
        データベースI/Oのオーバーヘッドを最小限に抑えるため、イベントのバッチを処理します。
        """
        if not events:
            return

        # バッチを集計するための一時的なインメモリ構造
        aggregated_data = defaultdict(lambda: {
            'total_users': set(),  # ユニークユーザーを自動的に重複排除するためのセット
            'total_sessions': 0,
            'bounce_count': 0,
            'session_durations': []  # 平均値計算用のセッション時間を格納するリスト
        })

        # バッチ内の各イベントを処理してインメモリ集計を構築
        for event in events:
            # 必須フィールドが欠落している不正なイベントをスキップ
            required_fields = ['user_id', 'session_id', 'event_type', 'timestamp', 'campaign_id', 'age_group']
            if not all(k in event for k in required_fields):
                print(f"Skipping malformed event: {event}")
                continue

            # 次元の抽出
            event_date = datetime.fromisoformat(event['timestamp']).strftime('%Y-%m-%d')
            campaign_id = event['campaign_id'] if event['campaign_id'] else 'NULL'
            age_group = event['age_group'] if event['age_group'] else 'NULL'

            # 複合キーの定義
            key = (event_date, campaign_id, age_group)

            # ユニークユーザーの追跡
            aggregated_data[key]['total_users'].add(event['user_id'])

            # セッションおよび直帰イベントの処理
            if event['event_type'] == 'session_start':
                aggregated_data[key]['total_sessions'] += 1
            elif event['event_type'] == 'session_end':
                session_duration = event.get('duration', 0)
                aggregated_data[key]['session_durations'].append(session_duration)
            elif event['event_type'] == 'bounce_event':
                aggregated_data[key]['bounce_count'] += 1

        self._update_database(aggregated_data)

    def _update_database(self, aggregated_data):
        """
        MySQLでアトミックなUPSERT (INSERT ... ON DUPLICATE KEY UPDATE) を実行します。
        """
        conn = self._get_db_connection()
        cursor = conn.cursor()

        # 同時更新を効率的に処理するためのアトミックなUPSERTクエリ
        upsert_query = """
            INSERT INTO aggregated_daily_metrics (
                event_date, campaign_id, age_group, total_users, total_sessions, bounce_count, average_session_duration
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                total_users = total_users + VALUES(total_users),
                total_sessions = total_sessions + VALUES(total_sessions),
                bounce_count = bounce_count + VALUES(bounce_count),
                average_session_duration = (
                    (average_session_duration * total_sessions) + (VALUES(average_session_duration) * VALUES(total_sessions))
                ) / (total_sessions + VALUES(total_sessions))
        """

        records_to_upsert = []
        for key, metrics in aggregated_data.items():
            event_date, campaign_id, age_group = key
            
            # このバッチ内のユニークユーザー数を算出
            current_total_users = len(metrics['total_users'])
            
            # このバッチ内の平均セッション時間を算出
            avg_duration = sum(metrics['session_durations']) / len(metrics['session_durations']) if metrics['session_durations'] else 0.0

            records_to_upsert.append((
                event_date,
                None if campaign_id == 'NULL' else campaign_id,
                None if age_group == 'NULL' else age_group,
                current_total_users,
                metrics['total_sessions'],
                metrics['bounce_count'],
                avg_duration
            ))

        try:
            # ネットワーク往復を最小限に抑えるため、バッチUPSERTを実行
            cursor.executemany(upsert_query, records_to_upsert)
            conn.commit()
            print(f"Successfully processed {len(records_to_upsert)} aggregated records.")
        except mysql.connector.Error as err:
            conn.rollback()
            print(f"Database error: {err}")
        finally:
            cursor.close()
```

💡 <b>実装のポイント</b>: マイクロバッチ処理によりネットワーク往復を削減し、Pythonの `set` を用いたインメモリ重複排除によって、DB書き込み前の負荷を軽減しています。また、アトミックな `UPSERT` により、アプリケーション側での `SELECT` を伴う確認処理を排除しました。

---

### 3. キャッシュ対応APIエンドポイント

ダッシュボードにデータを提供するAPIレイヤーでは、決定論的なキャッシュキー生成とTTL管理を徹底しています。

```python
from fastapi import FastAPI, Depends, HTTPException
from redis import Redis
import mysql.connector
import json
from datetime import date
from typing import Optional

app = FastAPI()

REDIS_HOST = 'localhost'
REDIS_PORT = 6379
DB_CONFIG = {
    'host': 'localhost',
    'user': 'api_user',  # API専用の読み取り専用ユーザー
    'password': 'your_password',
    'database': 'analytics_db'
}

# Redis接続プールの初期化
redis_client = Redis(host=REDIS_HOST, port=REDIS_PORT, db=0)

# データベース接続の依存関係
def get_db_connection():
    conn = None
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        yield conn
    finally:
        if conn and conn.is_connected():
            conn.close()

@app.get("/analytics/daily_metrics")
async def get_daily_metrics(
    start_date: date,
    end_date: date,
    campaign_id: Optional[str] = None,
    age_group: Optional[str] = None,
    db_conn: mysql.connector.connection.MySQLConnection = Depends(get_db_connection)
):
    # 1. クエリパラメータに基づいて一意のキャッシュキーを生成
    cache_key_parts = [
        f"daily_metrics:{start_date.isoformat()}:{end_date.isoformat()}",
        f"campaign:{campaign_id if campaign_id else 'all'}",
        f"age_group:{age_group if age_group else 'all'}"
    ]
    cache_key = ":".join(cache_key_parts)

    # 2. Redisキャッシュの確認 (キャッシュヒットパス)
    cached_data = redis_client.get(cache_key)
    if cached_data:
        print(f"Cache hit for key: {cache_key}")
        return json.loads(cached_data)

    print(f"Cache miss for key: {cache_key}. Fetching from DB...")

    # 3. キャッシュミス時にデータベースに問い合わせ
    cursor = db_conn.cursor(dictionary=True)
    
    query = """
        SELECT 
            event_date, campaign_id, age_group, total_users, total_sessions, bounce_count, average_session_duration 
        FROM 
            aggregated_daily_metrics 
        WHERE 
            event_date BETWEEN %s AND %s
    """
    params = [start_date, end_date]

    # 動的フィルタリングロジックの処理
    if campaign_id:
        query += " AND campaign_id = %s"
        params.append(campaign_id)
    else:
        query += " AND campaign_id IS NULL"  # 事前集計されたグローバル指標を取得

    if age_group:
        query += " AND age_group = %s"
        params.append(age_group)
    else:
        query += " AND age_group IS NULL"  # 事前集計されたグローバル指標を取得

    try:
        cursor.execute(query, params)
        results = cursor.fetchall()

        # JSONシリアライズのために日付オブジェクトを文字列フォーマットに変換
        for row in results:
            if isinstance(row['event_date'], date):
                row['event_date'] = row['event_date'].isoformat()

        # 4. 結果を5分間のTTL (300秒) でRedisに保存
        if results:
            redis_client.setex(cache_key, 300, json.dumps(results))

        return results

    except mysql.connector.Error as err:
        raise HTTPException(status_code=500, detail=f"Database error: {err}")
    finally:
        cursor.close()
```

🛠️ <b>最適化のポイント</b>: クエリパラメータの組み合わせから一意のキャッシュキーを生成し、5分間（300秒）のTTLを設定しています。これにより、データの鮮度を保ちつつ、データベースへの冗長なアクセスを物理的に遮断します。

---

## 結論と成果

オンデマンドの生ログ集計から非同期事前集計パイプラインへ移行した結果、数億行のスキャンに伴う計算オーバーヘッドを完全に排除することに成功しました。

複合ユニークキーを活用した集計テーブル設計と、Redisによるキャッシュ戦略を組み合わせることで、ダッシュボードの応答時間は150秒からミリ秒単位へと劇的に改善されました。このアーキテクチャは、データ量が増大し続けるエンタープライズ環境においても高いスケーラビリティを発揮し、安定したユーザー体験を提供するための堅牢な基盤となります。
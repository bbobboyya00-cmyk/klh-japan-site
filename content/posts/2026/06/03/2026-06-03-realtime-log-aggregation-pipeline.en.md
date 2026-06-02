---
title: "Real-Time Multidimensional Aggregation Pipeline and Caching Strategy for Large-Scale Activity Logs"
slug: "realtime-log-aggregation-pipeline"
date: 2026-06-03T08:00:22+09:00
draft: false
image: ""
description: "This article explains how to implement an architecture combining an asynchronous pre-aggregation pipeline and Redis cache to accelerate aggregation processing of large-scale activity logs."
categories: ["Backend Architecture"]
tags: ["fastapi", "redis", "mysql", "data-pipeline", "upsert"]
author: "K-Life Hack"
---

# Accelerating Dashboard Rendering in Large-Scale Datasets: Optimization via Pre-Aggregation and Caching Strategies

In enterprise web applications, on-demand rendering of analytical dashboards against large-scale datasets is a major factor causing severe performance degradation. In a technical consulting project, a critical bottleneck was identified where rendering a monthly analytical report took 150 seconds (2 minutes and 30 seconds). To address this challenge, we set a strict target of reducing response times to under 5 seconds and redesigned the architecture.


This report explains the technical approach and implementation details for achieving sub-second responsiveness targeting user activity data within a rolling window of the past three months.



### Technical Requirements and Goals

* <b>Data Source</b>: All service user activity logs for the past 3 months (up to hundreds of millions of records)
* <b>Key Metrics</b>: DAU (Daily Active Users), average session duration, bounce rate
* <b>Performance Goal</b>: Complete rendering on the dashboard in under 1 second, or within a few seconds
* <b>Dynamic Filtering</b>: Immediate support for multidimensional filtering such as campaign ID and age group

---

## Technical Challenges in the Conventional Approach

In the conventional configuration, raw user activity logs were stored in a standard relational database (MySQL), and complex queries containing <code>GROUP BY</code> and <code>JOIN</code> were executed directly at the time of report generation. However, as the volume of data increased, three technical limitations became apparent.



```
[Raw Log Table (Hundreds of Millions of Rows)] ──(On-Demand SQL GROUP BY / JOIN)──&gt; [DB Bottleneck: High CPU/IO] ──&gt; [Slow Response: Tens of Seconds to Minutes]
```

1. <b>Saturation of Computational Resources</b>: Scanning and aggregating hundreds of millions of rows at runtime places an extreme load on CPU and disk I/O. Even a simple DAU calculation took more than 10 seconds, and timeouts occurred when applying multidimensional filters.
2. <b>Adverse Impact on OLTP</b>: Heavy analytical queries occupied database connection pools and I/O, significantly degrading the performance of main transactional processing and risking the availability of the entire system.
3. <b>Operational Rigidity</b>: Every time a new analytical metric or filtering dimension was added, rewriting queries and redesigning indexes were required, increasing development and operational costs.

---

## Architectural Design: Transition to Pre-Aggregation

To break through the physical limits of on-demand computation, we shifted our design philosophy from "computation at request time" to "asynchronous pre-computation and persistence."



```
[User Activity Events]
       │
       ├──&gt; [Main DB (OLTP Storage)]
       │
       └──&gt; [Message Queue (Kafka / Redis Pub/Sub)]
                  │
                  ▼
     [Asynchronous Aggregation Service]
                  │
                  ▼ (UPSERT / Batch Write)
     [Dedicated Aggregation Table (MySQL)] &lt;─── [Cache Miss] ───┐
                  │                                             │
                  ▼ (Cache Write / TTL 300s)                    ▼
           [Caching Layer (Redis)] ──────────────────&gt; [FastAPI API Gateway] ──&gt; [Web Dashboard]
                                      [Cache Hit]
```

### Pipeline Components

1. <b>Asynchronous Data Collection</b>: When a user event occurs, the application publishes the event to a message queue (such as Apache Kafka) in parallel with writing to the main DB. This completely decouples the aggregation processing from the user's operational response.
2. <b>Dedicated Aggregation Service</b>: Independent workers subscribe to the queue, consume logs in real time, and update pre-aggregated tables. Metrics are pre-calculated hourly and by key dimensions (campaigns, attributes, etc.).
3. <b>Caching Layer</b>: Frequently accessed query results are stored in Redis. This minimizes database queries and achieves millisecond-level responses.
4. <b>API Gateway</b>: For requests from the dashboard, a Cache-Aside pattern is adopted, checking Redis first. Only on a cache miss is the pre-aggregated table queried, and the result is written back to the cache.

---

## Implementation Details

The implementation configuration uses <b>FastAPI</b> for the backend, <b>Redis</b> for caching, and <b>MySQL</b> for storing aggregated data.



### 1. Aggregation Table Schema Design

To efficiently manage pre-calculated metrics, we designed the <code>aggregated_daily_metrics</code> table. To support high-throughput <code>UPSERT</code> operations, leveraging composite unique keys is key.



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

In this design, the combination of <code>event_date</code>, <code>campaign_id</code>, and <code>age_group</code> is defined as a unique index. This prevents duplicate data under the same conditions and enables atomic updates.



---

### 2. Implementation of Asynchronous Aggregation Processor

The <code>AggregationProcessor</code> class maximizes write performance by combining batch processing with the <code>ON DUPLICATE KEY UPDATE</code> clause.



```python
import mysql.connector
import json
from datetime import datetime
from collections import defaultdict

# Database configuration
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
        Retrieve database connection.
        Includes reconnection logic to handle disconnections.
        """
        if self.connection is None or not self.connection.is_connected():
            print("Connecting to database...")
            self.connection = mysql.connector.connect(**self.db_config)
        return self.connection

    def process_event_batch(self, events):
        """
        Process a batch of events to minimize database I/O overhead.
        """
        if not events:
            return

        # Temporary in-memory structure for batch aggregation
        aggregated_data = defaultdict(lambda: {
            'total_users': set(),  # Set to automatically deduplicate unique users
            'total_sessions': 0,
            'bounce_count': 0,
            'session_durations': []  # List to store session durations for average calculation
        })

        # Process each event in the batch to build in-memory aggregation
        for event in events:
            # Skip malformed events missing required fields
            required_fields = ['user_id', 'session_id', 'event_type', 'timestamp', 'campaign_id', 'age_group']
            if not all(k in event for k in required_fields):
                print(f"Skipping malformed event: {event}")
                continue

            # Extract dimensions
            event_date = datetime.fromisoformat(event['timestamp']).strftime('%Y-%m-%d')
            campaign_id = event['campaign_id'] if event['campaign_id'] else 'NULL'
            age_group = event['age_group'] if event['age_group'] else 'NULL'

            # Define composite key
            key = (event_date, campaign_id, age_group)

            # Track unique users
            aggregated_data[key]['total_users'].add(event['user_id'])

            # Process session and bounce events
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
        Execute atomic UPSERT (INSERT ... ON DUPLICATE KEY UPDATE) in MySQL.
        """
        conn = self._get_db_connection()
        cursor = conn.cursor()

        # Atomic UPSERT query to handle concurrent updates efficiently
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
            
            # Calculate unique user count in this batch
            current_total_users = len(metrics['total_users'])
            
            # Calculate average session duration in this batch
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
            # Execute batch UPSERT to minimize network round trips
            cursor.executemany(upsert_query, records_to_upsert)
            conn.commit()
            print(f"Successfully processed {len(records_to_upsert)} aggregated records.")
        except mysql.connector.Error as err:
            conn.rollback()
            print(f"Database error: {err}")
        finally:
            cursor.close()
```

💡 <b>Key Implementation Points</b>: Micro-batch processing reduces network round trips, and in-memory deduplication using Python's <code>set</code> reduces the load before writing to the DB. Furthermore, atomic <code>UPSERT</code> eliminates verification processing involving <code>SELECT</code> on the application side.



---

### 3. Cache-Enabled API Endpoint

In the API layer that provides data to the dashboard, deterministic cache key generation and TTL management are thoroughly enforced.



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
    'user': 'api_user',  # Read-only user dedicated to API
    'password': 'your_password',
    'database': 'analytics_db'
}

# Initialize Redis connection pool
redis_client = Redis(host=REDIS_HOST, port=REDIS_PORT, db=0)

# Database connection dependency
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
    # 1. Generate a unique cache key based on query parameters
    cache_key_parts = [
        f"daily_metrics:{start_date.isoformat()}:{end_date.isoformat()}",
        f"campaign:{campaign_id if campaign_id else 'all'}",
        f"age_group:{age_group if age_group else 'all'}"
    ]
    cache_key = ":".join(cache_key_parts)

    # 2. Check Redis cache (Cache hit path)
    cached_data = redis_client.get(cache_key)
    if cached_data:
        print(f"Cache hit for key: {cache_key}")
        return json.loads(cached_data)

    print(f"Cache miss for key: {cache_key}. Fetching from DB...")

    # 3. Query database on cache miss
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

    # Handle dynamic filtering logic
    if campaign_id:
        query += " AND campaign_id = %s"
        params.append(campaign_id)
    else:
        query += " AND campaign_id IS NULL"  # Retrieve pre-aggregated global metrics

    if age_group:
        query += " AND age_group = %s"
        params.append(age_group)
    else:
        query += " AND age_group IS NULL"  # Retrieve pre-aggregated global metrics

    try:
        cursor.execute(query, params)
        results = cursor.fetchall()

        # Convert date objects to string format for JSON serialization
        for row in results:
            if isinstance(row['event_date'], date):
                row['event_date'] = row['event_date'].isoformat()

        # 4. Store results in Redis with a 5-minute TTL (300 seconds)
        if results:
            redis_client.setex(cache_key, 300, json.dumps(results))

        return results

    except mysql.connector.Error as err:
        raise HTTPException(status_code=500, detail=f"Database error: {err}")
    finally:
        cursor.close()
```

🛠️ <b>Optimization Points</b>: A unique cache key is generated from the combination of query parameters, and a TTL of 5 minutes (300 seconds) is configured. This physically blocks redundant access to the database while maintaining data freshness.



---

## Conclusion and Results

As a result of transitioning from on-demand raw log aggregation to an asynchronous pre-aggregation pipeline, we successfully eliminated the computational overhead associated with scanning hundreds of millions of rows.


By combining an aggregation table design leveraging composite unique keys with a caching strategy using Redis, dashboard response times were dramatically improved from 150 seconds to the millisecond level. This architecture exhibits high scalability even in enterprise environments where data volume continues to grow, serving as a robust foundation for delivering a stable user experience.


---
title: "Real-Time Aggregation Pipeline Design for High-Traffic Activity Logs"
slug: "realtime-data-aggregation-redis-pipeline"
date: 2026-06-03T09:11:10+09:00
draft: false
image: ""
description: "This article explains pre-aggregation table design and Redis caching strategies for aggregating large-scale user activity logs in real time and rendering dashboards with low latency."
categories: ["Backend Architecture"]
tags: ["redis", "fastapi", "mysql", "data-aggregation", "python"]
author: "K-Life Hack"
---

## Overview

On-demand query execution patterns against relational databases face severe performance limits under real-time, large-scale data aggregation requirements. To achieve high-performance, low-latency metrics rendering, it is necessary to move away from designs that aggregate raw log data on every request and instead build an asynchronous processing pipeline that combines <b>dedicated pre-aggregation tables</b> and an <b>in-memory caching layer</b>.


This article explains concrete implementation specifications and architectural designs in practice, including ensuring data consistency, selecting efficient in-memory data structures, and designing reprocessing and recovery logic during system failures.



## Background and Context

In the fields of data processing and analytical reporting, it is not uncommon to face system requirements that exceed the limits of traditional relational databases.


Previously, during a technical consultation with a client at an office in the Gangnam district of Seoul, the following requirement was presented:


<blockquote>"Currently, rendering the monthly report takes about 2 minutes and 30 seconds. Please reduce this response time to less than 5 seconds by next week."</blockquote>
This requirement highlighted a common architectural bottleneck. Based on this high-throughput requirement, this article outlines a technical approach to aggregate massive volumes of user activity data generated per second and serve it with sub-second latency.



## 1. System Requirements

* <b>Data Source</b>: User activity logs across the entire service over the past 3 months.
* <b>Target Metrics</b>: Real-time aggregation of Daily Active Users (DAU), average session duration, and bounce rate.
* <b>Visualization</b>: Dynamic graph and table report display on a web dashboard.
* <b>Data Scale</b>: Raw activity logs reaching the scale of hundreds of millions of records.
* <b>Query Flexibility</b>: Results must update within a few seconds when multi-dimensional filters such as specific marketing campaigns or age groups are applied.

## 2. Technical Challenges and Bottlenecks

In the existing system, raw activity logs were stored in a standard relational database such as MySQL. Logs accumulated at a rate of millions of records per day, and the reporting engine executed heavy SQL queries containing `GROUP BY` and `JOIN` on every request.


There are three main limitations to this approach.



```sql
-- Example of heavy on-demand aggregation query
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

### A. Performance Bottleneck

Scanning and aggregating hundreds of millions of rows on the fly causes severe CPU and I/O bottlenecks. Even a simple DAU calculation query takes more than 10 seconds, and when complex multi-dimensional filters are applied, the response time degrades to tens of seconds or even minutes.



### B. Database Resource Exhaustion

When multiple administrators request reports simultaneously, analytical queries occupy the database connection pool and CPU capacity. This degrades the performance of the main database processing transactions, threatening the stability of user-facing services.



### C. Lack of Schema Flexibility

Every time a new filtering dimension or analytical metric is added, it requires rewriting complex SQL queries, redesigning indexes, and performing optimization work, which delays the feature development cycle.



## 3. Architectural Design

To solve these challenges, we shift the design policy from "on-demand calculation at request time" to "<b>prior asynchronous calculation and cache storage</b>."


The ingestion, aggregation, and serving layers are separated as follows:



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

### A. Asynchronous Data Collection

When an event occurs, the application writes the raw log to the main DB and simultaneously publishes the event to a lightweight message queue (such as Apache Kafka or Redis Pub/Sub). This prevents the data collection process for analysis from blocking user transactions.



### B. Dedicated Aggregation Service

An independent consumer service subscribes to the message queue, processes logs in real time, and updates the dedicated pre-aggregation tables. This table pre-calculates and holds metrics at hourly or daily granularities for each filter dimension, such as campaign ID or age group.



### C. Caching Layer

Frequently accessed report queries for specific periods are cached in an in-memory data store (Redis). The application returns these requests directly from memory, eliminating database access.



### D. API Endpoints

A dedicated API gateway is deployed to handle queries from the dashboard. Upon receiving a request, it first checks the Redis cache and immediately returns a response if there is a hit. In the case of a cache miss, it queries the pre-aggregation table, caches the result in Redis, and then returns it.



### Trade-off Analysis

* <b>Pros</b>:
  * <b>Reduced DB Load</b>: Dramatically reduces CPU and read I/O load on the main DB.
  * <b>Low Latency</b>: Achieves sub-second fast responses even for hundreds of millions of records using pre-aggregated data and in-memory cache.
  * <b>Scalability</b>: Adding new filter dimensions can be handled simply by extending the schema of the pre-aggregation table, keeping the query logic simple.
* <b>Cons</b>:
  * <b>Increased Infrastructure Cost</b>: Requires operational management of additional components such as message queues, cache clusters, and consumer daemons.
  * <b>Consistency Management</b>: Introducing asynchronous processing requires ensuring eventual consistency. It is necessary to incorporate reprocessing and consistency verification logic to handle event out-of-order delivery and system failures.

## 4. Lifecycle Dynamics and Container Deployment

When operating the aggregation consumer service in a production environment, traffic control and prevention of duplicate processing during container rolling updates and zero-downtime scaling are extremely critical.



### A. Deduplication During Rolling Updates

⚠️ When consumer containers are replaced, there is a temporary period where both old and new containers subscribe to the message queue (such as Kafka) simultaneously. To prevent the risk of duplicate processing of the same message during this time, the following measures are taken:



* <b>Enforcing Idempotent UPSERTs</b>: Use `ON DUPLICATE KEY UPDATE` (described later) to ensure that the state remains consistent even if the same data is written multiple times.
* <b>Proper Consumer Group Management</b>: To prevent duplicate processing during Kafka partition rebalancing, execute offset commits synchronously immediately after batch processing completes.

### B. Zero-Downtime Scaling

When horizontally scaling consumer containers (e.g., via HPA: Horizontal Pod Autoscaler) in response to traffic spikes, there is a risk that concurrent connections to the database will surge, exhausting the connection pool. To prevent this, set appropriate connection pooling limits on the consumer side and utilize distributed locks using Redis (such as the Redlock algorithm) to suppress concurrent write conflicts on the same key.



## 5. Implementation Details

We use <b>Python</b> and <b>FastAPI</b> for the backend API, <b>Redis</b> for the caching layer, and <b>MySQL</b> to store pre-aggregated data.



### 5.1. Pre-aggregation Table Schema Design

The `aggregated_daily_metrics` table stores pre-calculated metrics. Setting a composite unique key ensures data consistency and enables high-speed UPSERT processing.



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

`UNIQUE KEY (event_date, campaign_id, age_group)`: Guarantees the uniqueness of dimensions and enables atomic updates using `ON DUPLICATE KEY UPDATE`.



### 5.2. Implementation of Asynchronous Aggregation Service (Python)

The consumer service retrieves events in batches from a message queue and updates the pre-aggregation table.



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

### 5.3. Implementation of Caching API Endpoint (FastAPI)

We build an endpoint using FastAPI that preferentially references the Redis cache and accesses the MySQL pre-aggregation table only on a cache miss.



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

💡 When operating this architecture in a production environment, the following operational considerations are recommended:



1. <b>Cache Invalidation Strategy</b>: If delayed data or historical corrections flow into the data source, implement event-driven cache invalidation logic that explicitly deletes (DEL) or updates the corresponding Redis cache keys for the affected periods and dimensions in sync with the pre-aggregation table updates.
2. <b>Maintaining Weighted Average Precision</b>: Calculating the average session duration within `ON DUPLICATE KEY UPDATE` may accumulate floating-point rounding errors. If higher precision is required, we recommend a design that separately maintains `session_duration_sum` (total session duration) and `total_sessions` (total session count) in the table, and performs division at read time.
3. <b>Resource Monitoring</b>: Monitor Redis memory usage and eviction policies (such as `allkeys-lru`) and perform appropriate memory capacity planning to prevent a sudden drop in the cache hit rate.
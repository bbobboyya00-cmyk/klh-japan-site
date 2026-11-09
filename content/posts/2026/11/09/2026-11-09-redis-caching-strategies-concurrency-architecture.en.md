---
title: "Redis Caching Strategies and Failure Mitigation Design in High-Load Web Environments"
slug: "redis-caching-strategies-concurrency-architecture"
date: 2026-11-09T11:20:09+09:00
draft: false
image: ""
description: "To resolve RDBMS I/O bottlenecks under high traffic, this document outlines the technical design and operational verification logs for Redis-based caching strategies, stampede prevention measures, and memory exhaustion countermeasures (maxmemory-policy)."
categories: ["Backend Architecture"]
tags: ["redis", "cache-aside", "maxmemory-policy", "cache-stampede", "redis-cli"]
author: "K-Life Hack"
---

In phases where web system traffic increases, the concentration of repetitive read queries against a relational database management system (RDBMS) becomes a primary factor leading to disk I/O saturation and database connection pool exhaustion. An architecture that relies solely on scaling up the storage layer inevitably suffers from deteriorating latency and escalating costs. To eliminate bottlenecks in highly concurrent environments, it is necessary to standardize a caching architecture that offloads read traffic by placing Redis, an in-memory data store, in front of the persistence layer.


This document compiles technical verification results regarding the rationale for adopting Redis in web infrastructure, selection criteria for key caching topologies, cache stampede prevention, and memory limit management.



## Read Load Localization and Redis Characteristics

Because Redis retains and processes all data in main memory, it maintains sub-millisecond response latency compared to standard RDBMSs that involve disk seeks. Furthermore, its native support for diverse data structures—rather than operating merely as a simple key-value store—serves as an architectural advantage in system design.



- <b>String</b>: Caching serialized object data and JSON strings
- <b>Hash</b>: Structured retention of objects with multiple fields and discrete updates of specific fields
- <b>List / Set</b>: Implementation of queue structures and unique user membership checks
- <b>Sorted Set (ZSet)</b>: Score-based real-time aggregation and sliding-window rate limiter implementations

By leveraging these data structures, Redis can do more than serve as a repository for query results; it can efficiently consolidate distributed infrastructure responsibilities such as session persistence and rate limiting.



## Cache Pattern Design and Trade-offs

A cache access pattern suited to the requirements must be defined by balancing data consistency, fault tolerance, and overall system complexity.



### Cache-Aside (Lazy Loading) Pattern

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

In the Cache-Aside pattern, the application first queries Redis for data. If the cache exists (Cache Hit), that value is returned immediately to the client. If the cache does not exist (Cache Miss), data is fetched from the backend RDBMS, written to Redis with a TTL, and then returned in the response.


A key characteristic of this pattern is that even if a Redis node temporarily goes down, total service outage can be avoided as long as the application maintains fallback to the RDBMS. In addition, because only requested data is loaded into the cache, the memory footprint is kept to a minimum.



### Write-Through and Write-Back Patterns

- <b>Write-Through</b>: The application writes to the cache, and the cache layer performs a synchronous write to the RDBMS within the same transaction. While data consistency is ensured, dual write overhead occurs for every update operation.
- <b>Write-Back (Write-Behind)</b>: Writes are executed only to Redis, and a response is returned immediately. Persistence to the underlying storage layer is flushed asynchronously in batches by a background process. While this maximizes write throughput, it entails the risk of losing unflushed data if the Redis instance crashes abnormally.

## Fault Tolerance Design and Operational Countermeasures

### Mitigating Cache Stampede (Thundering Herd)

The moment the TTL of an extremely high-traffic key expires, numerous concurrent worker threads detect a Cache Miss simultaneously and issue identical queries concurrently to the RDBMS. This causes a sudden spike in database CPU utilization and cascades into connection timeouts.


To prevent this issue, fixed-value TTL configurations should be avoided, and expiration times configured with randomized variation (Jitter) should be introduced.



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

Probabilistically dispersing the TTL reduces the risk of all requests executing the fallback process simultaneously.



### Memory Exhaustion (OOM) Countermeasures and Eviction Policies

Continuing operations without configuring an upper limit on cache capacity leads to excessive host memory consumption, triggering process termination by the OS OOM Killer or new write errors. The physical memory limit and eviction policy must be explicitly specified in redis.conf.



```conf
# Maximum memory allocation limit
maxmemory 2147483648

# Eviction policy settings
# Available: volatile-lru, allkeys-lru, volatile-lfu, allkeys-lfu, noeviction
maxmemory-policy allkeys-lru

# LRU / LFU sampling precision
maxmemory-samples 5
```

- <b>allkeys-lru</b>: Evicts keys starting from the least recently used. Suitable for general web workloads adhering to the Pareto principle.
- <b>allkeys-lfu</b>: Evaluates access frequency using a logarithmic access counter and evicts low-frequency keys. Useful for preventing keys accessed in transient one-off bursts from being retained.
- <b>noeviction</b>: The default setting, where write operations return an OOM command not allowed error when the memory limit is reached. This behavior should be avoided when using Redis as a temporary caching layer.

## Troubleshooting

### 1. OOM Error Upon Reaching Memory Limit

<b>Symptom:</b> The following errors occur continuously on the application side during SET operations to Redis.



```text
(error) OOM command not allowed when used memory &gt; 'maxmemory'.
```

<b>Root Cause Analysis:</b> maxmemory-policy remained configured as noeviction, and additions of new keys or data updates were attempted while the limit had been reached.


<b>Action Taken:</b> Issued the CONFIG SET command to the running Redis instance to dynamically change the eviction policy, followed by persisting the change to the configuration file.



```bash
redis-cli config set maxmemory-policy allkeys-lru
redis-cli config rewrite
```

### 2. Connection Latency Due to TCP Connection Backlog Limitation

<b>Symptom:</b> During traffic spikes, connection establishment latency to Redis increases, and Connection Timeouts are logged on the client side.


<b>Root Cause Analysis:</b> Occurs when the kernel's socket listen backlog setting (net.core.somaxconn) is low and cannot accommodate Redis's tcp-backlog (default: 511).


<b>Action Taken:</b> Modify kernel parameters on the host OS to expand the socket queue length.



```bash
sudo sysctl -w net.core.somaxconn=2048
echo "net.core.somaxconn = 2048" | sudo tee -a /etc/sysctl.conf
```

## Verification Results and Operational Status

To verify consistency in the infrastructure layer after applying the configurations, memory utilization, connection listeners, and eviction statistics of the Redis process were retrieved via the terminal.



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

It was confirmed that used_memory was maintained within the configured 2.00GB limit, and that autonomous memory boundary management under the allkeys-lru policy functioned properly as evidenced by the increase in evicted_keys.



## Operational Notes

Deploying a Redis cache as a single instance is an approach that offers immediate efficacy in mitigating RDBMS read load. However, to prevent the caching layer itself from becoming a single point of failure (SPOF), implementing redundant failover mechanisms is mandatory in subsequent operational phases.


As future milestones, it is necessary to build a highly fault-tolerant data platform by verifying Redis cluster configurations utilizing StatefulSets in Kubernetes environments, as well as automatic master failover mechanisms using Sentinel.


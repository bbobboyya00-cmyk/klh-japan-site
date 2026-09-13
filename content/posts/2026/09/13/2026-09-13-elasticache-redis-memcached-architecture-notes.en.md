---
title: "Amazon ElastiCache Architecture & Verification: Selection Criteria for Redis vs. Memcached and Caching Strategies"
slug: "elasticache-redis-memcached-architecture-notes"
date: 2026-09-13T10:07:57+09:00
draft: false
image: ""
description: "Detailed explanation of selection criteria for Redis and Memcached in Amazon ElastiCache, caching strategies such as Lazy Loading and Write-Through, security design, and session management architecture."
categories: ["Backend Architecture"]
tags: ["amazon-elasticache"]
author: "K-Life Hack"
---

Implementing an in-memory cache is an essential design pattern for mitigating I/O bottlenecks and query spikes at the database layer. While disk-based RDBMS (such as Amazon RDS or Amazon Aurora) require response times on the order of milliseconds (10 ms to over 100 ms), placing hot data in the in-memory layer (RAM) enables data fetching on the order of microseconds to sub-milliseconds (μs to 1 ms). This article summarizes the architectural characteristics of Amazon ElastiCache, a fully managed in-memory data store, selection criteria for caching patterns, technical differences between the Redis and Memcached engines, and operational verification points.



## Caching Strategies and Access Patterns

Because ElastiCache is not a transparent database proxy, explicit cache control logic must be implemented at the application layer.



### 1. Lazy Loading (Cache-Aside)

A pattern in which the application queries the cache first, and only upon a cache miss falls back to the primary database and writes the retrieved data back to the cache.



* <b>Pros</b>: Only data that is actually accessed is stored in memory, making it a resource-efficient design. Continuous operation remains possible via DB fallback even during cache node failures.
* <b>Cons</b>: On a cache miss, multiple round trips occur ("App → Cache → DB → Cache → Client"), increasing initial latency. Additionally, there is a risk of stale data remaining when the DB is updated directly.

### 2. Write-Through

A pattern where data is written or updated in both the database and the cache layer simultaneously within the same transaction.



* <b>Pros</b>: Data freshness in the cache is always guaranteed, eliminating the risk of reading stale data.
* <b>Cons</b>: Latency increases because every write operation involves writes to both the DB and the cache. Furthermore, data that is never read also occupies cache space, potentially causing memory resource depletion (churn).

### 3. TTL (Time To Live) Expiration Policy

By configuring a TTL (Time To Live) in conjunction with Lazy Loading, the upper bound of data freshness can be controlled while maintaining memory efficiency.



```bash
# Store data under key 'user:123' with an expiration time of 300 seconds (5 minutes)
SET user:123 "session_payload" EX 300
```

## Engine Comparison: Redis vs. Memcached

The appropriate engine must be selected based on system requirements. Choose Redis when high availability, persistence, or advanced data structures are required; choose Memcached when a simple, multi-threaded key-value store is needed.



| Comparison Item | ElastiCache for Redis | ElastiCache for Memcached |
| :--- | :--- | :--- |
| <b>Data Structures</b> | String, List, Set, Sorted Set, Hash, Bitmap, Geo, etc. | Simple Key-Value only (String / Blob) |
| <b>Replication</b> | Primary-Replica configuration (Up to 5 nodes per shard) | None (Each node is independent) |
| <b>Availability Architecture</b> | Multi-AZ with Auto-Failover | None (Node failure = Cache miss) |
| <b>Data Persistence</b> | AOF log / RDB snapshot (S3 integration) | Not supported (Volatile memory only) |
| <b>Threading Model</b> | Single-threaded (Core event loop) | Multi-threaded (Can utilize multi-core CPUs) |
| <b>Clustering</b> | Cluster mode (Up to 500 shards) | Client-side distribution via consistent hashing |
| <b>Authentication</b> | Redis AUTH / AWS IAM Authentication (Redis 7.0+) | SASL Authentication |

## Security and Network Design

As a baseline, ElastiCache must be placed in a private subnet within a VPC with public routing blocked.



* <b>Network Isolation</b>: In the security group inbound rules, allow traffic to the respective ports (Redis: `6379`, Memcached: `11211`) only from security groups of authorized application layers (EC2/ECS/Lambda).
* <b>Encryption</b>: 
* Encryption at rest: Apply AES-256 encryption using customer managed keys (CMKs) in AWS KMS (Key Management Service).
* Encryption in transit: Enable TLS/SSL encryption for client-to-node and node-to-node communications.
* <b>Authentication &amp; Authorization</b>: IAM policies control control-plane APIs (cluster creation, modifications, etc.), while data-plane access is controlled via Redis AUTH or IAM authentication (Redis 7.0+).

```bash
# Example of TLS connection and AUTH token authentication using redis-cli
redis-cli -h my-redis-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379 --tls -a "YourSecureAuthToken"
```

## Distributed Session Storage Implementation Architecture

To achieve a stateless web tier, user sessions are offloaded from local EC2 instances to ElastiCache for Redis.



```text
+-------------------------------------------------------------------------+
| [Client] -&gt; [ALB] -&gt; [EC2 Web Tier (Stateless Autoscaling Group)]       |
|                             |                                           |
|                             +--&gt; [ElastiCache Redis Multi-AZ Cluster]   |
|                                  (Shared Session Store)                 |
+-------------------------------------------------------------------------+
```

With this design, sticky sessions (session affinity) to specific EC2 nodes become unnecessary, ensuring session disconnection does not occur when instances are added or removed via Auto Scaling.



## Typical Use Cases and Command Examples

### 1. Real-Time Leaderboards (Redis Sorted Sets)

Eliminates heavy `ORDER BY` queries on relational databases by aggregating rankings in-memory.



```bash
# Add or update scores (O(log(N)))
ZADD leaderboard 1200 "user_01"
ZADD leaderboard 1850 "user_02"
ZADD leaderboard 1500 "user_03"

# Retrieve the top 3 users and their scores
ZREVRANGE leaderboard 0 2 WITHSCORES
```

### 2. Event Notification &amp; Fan-out (Redis Pub/Sub)

```bash
# Subscriber side
SUBSCRIBE channel:notifications

# Publisher side
PUBLISH channel:notifications "payload_update_event"
```

## Troubleshooting

### 1. Connection Timeout Caused by Security Groups or VPC Routing

When a `Connection timed out` occurs while attempting to connect to an ElastiCache cluster, verify the VPC subnet routing tables or security group ingress settings.



```text
$ nc -zvw3 test-redis.xxxxxx.use1.cache.amazonaws.com 6379
nc: connect to test-redis.xxxxxx.use1.cache.amazonaws.com port 6379 (tcp) failed: Connection timed out
```

<b>Resolution Steps</b>:
1. Verify whether the connecting client and ElastiCache reside in the same VPC or in subnets properly connected via VPC Peering or Transit Gateway.
2. Verify that the inbound rules of the security group attached to ElastiCache allow TCP port `6379` (or `11211` for Memcached) from the source CIDR or security group ID.

### 2. MOVED Redirect Error When Cluster Mode Is Enabled

Executing queries against a Redis cluster with Cluster Mode Enabled using a non-cluster-aware client or standalone connection configuration returns a `MOVED` error.



```text
$ redis-cli -h test-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379
127.0.0.1:6379&gt; GET user:data:999
(error) MOVED 12450 10.0.2.45:6379
```

<b>Resolution Steps</b>:
* When connecting via CLI, add the `-c` (cluster mode) flag to automatically follow redirects.
* In the application client library, enable the cluster connection driver (specifying the Cluster Configuration Endpoint).

```bash
redis-cli -c -h test-cluster.xxxxxx.clustercfg.use1.cache.amazonaws.com -p 6379
```

### 3. Memory Exhaustion and Out-Of-Memory (OOM) Command Rejection

If the memory limit (`maxmemory`) is reached due to write volume and no appropriate eviction policy is configured, write commands will be rejected.



```text
(error) OOM command not allowed when used memory &gt; 'maxmemory'.
```

<b>Resolution Steps</b>:
* Check `maxmemory-policy` in the parameter group and change it to `volatile-lru` or `allkeys-lru` depending on requirements.
* Audit application code to ensure TTLs are consistently set on cache keys.

## Operational Verification Logs

Below is an example log showing connectivity and replication status verification for a Redis node.



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

* <b>Engine Selection</b>: Choose Memcached if you only require simple object caching and high multi-threaded concurrency performance; choose Redis if you leverage replication, failover, persistence, or advanced data structures.
* <b>Cache Invalidation Design</b>: To prevent inconsistencies caused by missed cache updates, always use TTLs when adopting Lazy Loading to ensure the maximum period of inconsistency stays within system requirements.
* <b>Failover Resilience</b>: In production Redis environments, enable Multi-AZ to maintain an architecture that minimizes downtime via automatic failover during primary node failures.
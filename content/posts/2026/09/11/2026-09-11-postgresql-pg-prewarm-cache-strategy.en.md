---
title: "Preloading PostgreSQL Shared Buffers with pg_prewarm and Aurora Scaling Control"
slug: "postgresql-pg-prewarm-cache-strategy"
date: 2026-09-11T10:30:16+09:00
draft: false
image: ""
description: "As a workaround for Shared Buffers depletion and latency spikes during PostgreSQL cold starts, this article examines the internal behavior of the pg_prewarm module and autoprewarm worker, as well as automation procedures in AWS Aurora environments."
categories: ["Backend Architecture"]
tags: ["postgresql", "pg_prewarm", "aws-aurora", "shared-buffers", "database-performance"]
author: "K-Life Hack"
---

In infrastructure operations, immediately after a database node restart or maintenance, the Shared Buffers in memory are in an initialized state (cold start). If high traffic flows in under this state, PostgreSQL must synchronously read data blocks from storage, causing disk I/O bottlenecks and significant deterioration of query latency.


To prevent such warm-up delays and ensure predictable I/O performance, this document outlines cache preloading techniques using the standard module <code>pg_prewarm</code> and the operational mechanism of the <code>autoprewarm</code> background worker available in PostgreSQL 11 and later.



## Basic Structure and Operating Modes of pg_prewarm

<code>pg_prewarm</code> provides the functionality to load data blocks of a specified relation (table or index) directly into the OS page cache or PostgreSQL Shared Buffers.


As a basic setup procedure, enable the extension within the database.



```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
```

The basic query for loading a relation into Shared Buffers is as follows:



```sql
SELECT pg_prewarm('target_relation_name');
```

The detailed signature of the <code>pg_prewarm</code> function and the specifications of each parameter can be configured as follows:



```sql
pg_prewarm(
    relation regclass,
    mode text DEFAULT 'buffer',
    fork text DEFAULT 'main',
    first_block bigint DEFAULT NULL,
    last_block bigint DEFAULT NULL
) RETURNS bigint
```

Functional definition of each parameter:



- <b>`relation` (`regclass`)</b>: Specifies the target table name, index name, or OID.
- <b>`mode` (`text`)</b>: Selects the memory transfer mechanism.
  - `buffer`: Loads directly into PostgreSQL Shared Buffers (default).
  - `read`: Performs synchronous reads (`read()`) into the OS page cache without passing through Shared Buffers.
  - `prefetch`: Issues asynchronous OS prefetch requests (`posix_fadvise()`) (falls back to synchronous reads if unsupported by the OS).
- <b>`fork` (`text`)</b>: Specifies the file fork to be loaded. Specify `main` for standard data, `fsm` for free space map, and `vm` for visibility map.
- <b>`first_block` / `last_block` (`bigint`)</b>: Restricts the range of 8KB block numbers to be read. If `NULL`, all blocks are processed.

## Automatic Buffer State Restoration via autoprewarm

In PostgreSQL 11 and later, the automatic restoration subsystem <code>autoprewarm</code> is integrated into the <code>pg_prewarm</code> extension. It records the state of Shared Buffers immediately before server shutdown and automatically reloads the relevant blocks upon restart.


Required configuration parameters in <code>postgresql.conf</code>:



```ini
shared_preload_libraries = 'pg_prewarm'
pg_prewarm.autoprewarm = true
pg_prewarm.autoprewarm_interval = 300s
```

### Operational Mechanism

1. <b>Background Dump (`autoprewarm master`)</b>:
The `autoprewarm master` worker process periodically scans the mapping information in Shared Buffers and persists the block ID list to the `$PGDATA/autoprewarm.blocks` file (default interval: 300 seconds).
2. <b>Automatic Load on Startup</b>:
During PostgreSQL startup, a dedicated background worker reads `autoprewarm.blocks` and sequentially reloads target blocks from disk into Shared Buffers.

## Automating Replica Warm-up in AWS Aurora PostgreSQL

In AWS Aurora PostgreSQL, a cloud-native environment, storage and compute nodes are decoupled; however, managing local Shared Buffers on each DB instance remains critical. Read Replicas added via Auto Scaling start with empty buffers immediately after launch.


To avoid latency increases when launching a new replica, an automated warm-up configuration integrating Amazon EventBridge and AWS Lambda is utilized.



```
[Auto Scaling Event]
         │
         ▼
[Amazon EventBridge] (Detects instance creation event)
         │
         ▼
[AWS Lambda Function] (Triggers SQL execution task)
         │
         ▼
[Aurora Read Replica] ──&gt; Execute pg_prewarm() ──&gt; Load cache into memory
```

1. Aurora Auto Scaling provisions a new target.
2. EventBridge intercepts the completion event.
3. AWS Lambda triggers and connects to the new replica node.
4. Executes `pg_prewarm` on predefined critical table groups to populate the cache prior to traffic routing.

## Troubleshooting

### 1. Occurrence of Cache Thrashing

If <code>mode =&gt; 'buffer'</code> is executed when the size of the target relation exceeds the total configured capacity of <code>shared_buffers</code>, the Clock Sweep algorithm will immediately evict older buffers, leading to memory pressure and unnecessary I/O allocations.


<b>Workaround</b>: Verify the relation size and current Shared Buffers utilization prior to execution. If necessary, execute in chunks by specifying <code>first_block</code> and <code>last_block</code>, or use <code>mode =&gt; 'read'</code> to offload to the OS page cache instead.



```sql
SELECT pg_size_pretty(pg_relation_size('large_table_name'));
SHOW shared_buffers;
```

### 2. IOPS Depletion Due to Synchronous I/O Load

Executing <code>pg_prewarm</code> on multi-terabyte tables within a single session concentrates read requests on the storage layer, saturating I/O for other transactions.


<b>Workaround</b>: Implement scripting with partitioned block ranges and execute distributed loading with sleep intervals in between.



## Operational Verification Protocol

Below is an example terminal log verifying buffer loading states before and after executing <code>pg_prewarm</code> using the <code>pg_buffercache</code> extension.



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

- Buffer loading via `pg_prewarm` does not imply memory pinning; loaded pages remain subject to eviction by the standard Clock Sweep algorithm.
- In large-scale database operations, parameter settings must be configured after considering the trade-off between write costs and data accuracy associated with the background update interval of `autoprewarm` (`pg_prewarm.autoprewarm_interval`).
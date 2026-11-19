---
title: "Cache Stampede Mitigation in Redis Caching Strategies and Implementation of Redisson Distributed Locks"
slug: "redis-cache-stampede-redisson-distributed-lock"
date: 2026-11-19T11:35:04+09:00
draft: false
image: ""
description: "Explains Cache Stampede avoidance techniques for Redis in high-traffic environments and the exact implementation structure of Pub/Sub-based distributed locks using Redisson."
categories: ["Backend Architecture"]
tags: ["cache-stampede"]
author: "K-Life Hack"
---

In web application architectures centered on relational databases (RDBMS), disk I/O and connection pool exhaustion caused by sudden traffic spikes are factors that induce system-wide response delays and timeouts. Introducing Redis, an in-memory data store, as a caching layer can be expected to improve read performance; however, improper cache design or invalidation strategies risk triggering issues such as database load concentration caused by the expiration of specific keys (Cache Stampede) or data inconsistency during concurrent processing.


This article explains the selection criteria for major caching patterns, the implementation of distributed locks using Redisson, as well as Cache Stampede mitigation and memory management techniques in production operations.



## 1. Classification and Selection Criteria for Cache Patterns

An appropriate caching pattern must be selected based on data consistency requirements and write latency tolerance.



```
+-----------------------------------------------------------------------------------+
|                                CACHING PATTERNS                                  |
+--------------------------+--------------------------+-----------------------------+
|      Cache-Aside         |      Write-Through       |   Write-Back (Write-Behind) |
|  (Read Optimization)     |   (Consistency First)    |    (Write Optimization)     |
+--------------------------+--------------------------+-----------------------------+
|  1. App reads Cache      |  1. App writes Cache     |  1. App writes Cache only   |
|  2. Miss -&gt; Read DB      |  2. Cache writes DB      |  2. Async batch updates DB  |
|  3. Populate Cache       |     (Synchronously)      |                             |
+--------------------------+--------------------------+-----------------------------+
```

### Cache-Aside (Look-Aside)

This is a common pattern aimed at optimizing read operations. The application queries Redis first; upon a cache miss, it retrieves data from the RDBMS and writes it back to Redis. Even if a Redis node fails, system availability is maintained because operations fall back to the database. However, a trade-off exists where requests hit the DB all at once when a hot key's Time-To-Live (TTL) expires.


When updating data, the standard sequence is to "delete the Redis key after updating the DB," but to prevent race conditions with concurrent reads, short-duration TTL settings or the Delayed Double Delete pattern must be considered.



### Write-Through

During write operations, updates are performed synchronously to both the Redis cache and the RDBMS. High consistency between the cache and the database is maintained, allowing up-to-date data to be served constantly from the cache. On the other hand, latency increases because synchronous double writes occur for every write operation, and unreferenced data can also pressure cache memory capacity.



### Write-Back (Write-Behind)

The application writes only to Redis and returns a response immediately. A background asynchronous process periodically commits changes to the RDBMS via batch processing. This is suitable for absorbing high-frequency write traffic, but if the Redis instance crashes before asynchronous processing completes, non-persisted data risks being permanently lost.



## 2. Implementation of Distributed Locks and Concurrency Control Using Redisson

Standard Java locks on a single instance (such as <code>synchronized</code> or <code>ReentrantLock</code>) do not function in a distributed application environment composed of multiple nodes. Furthermore, pessimistic locking in RDBMS (<code>SELECT ... FOR UPDATE</code>) rapidly consumes connection pools under high concurrency and becomes a cause of deadlocks.


Redisson utilizes Redis's single-threaded event loop and Pub/Sub event notification mechanism to provide safe distributed locks (<code>RLock</code>) while avoiding wasteful CPU consumption caused by spinlocks.



```java
package com.example.service;

import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.concurrent.TimeUnit;

@Service
public class StockService {

    private final RedissonClient redissonClient;
    private final ItemRepository itemRepository;

    public StockService(RedissonClient redissonClient, ItemRepository itemRepository) {
        this.redissonClient = redissonClient;
        this.itemRepository = itemRepository;
    }

    public void decreaseStock(Long itemId, int quantity) {
        RLock lock = redissonClient.getLock("stock:" + itemId);
        boolean acquired = false;
        try {
            // Wait up to 3 seconds for lock acquisition; automatically release 5 seconds after acquisition
            acquired = lock.tryLock(3, 5, TimeUnit.SECONDS);
            if (!acquired) {
                throw new IllegalStateException("Lock acquisition timed out for item: " + itemId);
            }
            // Execute the database transaction within the lock acquisition boundary
            executeDecreaseTransactional(itemId, quantity);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("Thread interrupted during lock acquisition", e);
        } finally {
            if (acquired &amp;&amp; lock.isLocked() &amp;&amp; lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }

    @Transactional
    public void executeDecreaseTransactional(Long itemId, int quantity) {
        Item item = itemRepository.findById(itemId)
                .orElseThrow(() -&gt; new IllegalArgumentException("Item not found: " + itemId));
        item.decrease(quantity);
        itemRepository.save(item);
    }
}
```

When operating distributed locks, if an explicit <code>leaseTime</code> is not specified in <code>tryLock</code>, Redisson activates the Watchdog feature, automatically extending the lock expiration to 30 seconds every 10 seconds as long as the thread remains alive.



## 3. Cache Stampede Avoidance and Production Operation Checklist

The phenomenon where a large number of threads simultaneously access the database and attempt to execute recomputations at the exact moment the TTL of a hot key heavily accessed by traffic expires is called a Cache Stampede.



### Mitigation Strategies

1. 💡 <b>TTL Jitter (Adding Random Jitter):</b>
When setting the TTL for each key, dynamically add a random fluctuation of $\pm 10\% \sim 20\%$ to the base duration to disperse simultaneous expirations.

2. 🛠️ <b>Distributed Recomputation Lock (Single-Threaded Recomputation):</b>
Design the system so that upon a cache miss, only the single request that acquired the distributed lock retrieves data from the DB and performs recomputation, while other requests wait briefly or return stale cache data (Stale Payload).

3. ⚠️ <b>Probabilistic Early Recomputation (PER):</b>
Based on access frequency and recomputation cost, probabilistically calculate and update the cache in the background before the TTL completely expires.

### Memory and Eviction Policy Optimization

・ <b>Standardization of <code>maxmemory</code> Settings:</b> If <code>maxmemory</code> is not set, there is a risk that the Redis process will be forcibly terminated by the OS OOM Killer.

・ <b>Eviction Strategy Selection:</b> Select <code>volatile-lru</code> when targeting only keys with a TTL configured, or <code>allkeys-lru</code> when targeting all keys as a dedicated cache layer. The use of <code>noeviction</code> in a cache layer is strictly prohibited.

・ <b>Enforcement of Non-blocking Deletions:</b> Using the synchronous command <code>DEL</code> when deleting keys with large data structures will halt single-threaded processing. Enforce the use of <code>UNLINK</code>, which performs asynchronous memory deallocation.

## Troubleshooting

### Inconsistency Between Transaction Boundaries and Lock Release (Dirty Reads)

If <code>lock.unlock()</code> is invoked inside a method annotated with <code>@Transactional</code>, the lock is released before the DB commit completes. If another thread acquires the lock at this precise moment, a race condition occurs where it references the uncommitted stale state. <b>Lock acquisition and release must strictly be performed outside of DB transactions</b>.



### Exceptions Caused by Releasing Unowned Locks

If a thread's lock has already been automatically released due to TTL expiration, executing <code>unlock()</code> on a lock owned by another thread throws an <code>IllegalMonitorStateException</code>. Always verify ownership using <code>lock.isHeldByCurrentThread()</code> prior to release.



### System Verification Logs

Verify memory status and operational health in production environments periodically via CLI logs or similar means.



```text
$ redis-cli info memory
# Memory
used_memory:268435456
used_memory_human:256.00M
used_memory_rss:314572800
used_memory_rss_human:300.00M
mem_fragmentation_ratio:1.17
mem_allocator:jemalloc-5.3.0

$ redis-cli slowlog get 5
1) 1) (integer) 12
   2) (integer) 1700000000
   3) (integer) 15200
   4) 1) "UNLINK"
      2) "stock:cache:1004"

$ redis-cli eval "return redis.call('ttl', KEYS[1])" 1 "stock:1001"
(integer) 298
```

## Lessons Learned

In operating a highly concurrent caching infrastructure using Redis, it is indispensable not merely to use it as a data retention layer, but to comprehensively design for adding TTL jitter, concurrency control for recomputations, and memory overflow prevention measures (leveraging <code>maxmemory</code> and <code>UNLINK</code>). By implementing proper distributed lock boundary design and operational monitoring, stable operation with minimized DB load can be achieved even under high traffic conditions.


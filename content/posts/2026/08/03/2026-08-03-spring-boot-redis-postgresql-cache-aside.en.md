---
title: "Implementation and Failure Design of the Redis Cache-Aside Pattern in a Spring Boot and PostgreSQL Environment"
slug: "spring-boot-redis-postgresql-cache-aside"
date: 2026-08-03T10:08:22+09:00
draft: false
image: ""
description: "Explains how to build a Cache-Aside pattern using Spring Boot and Redis to reduce PostgreSQL read load, key considerations for AOP proxies, and failure design using error handlers."
categories: ["Backend Architecture"]
tags: ["spring-boot-redis-cache"]
author: "K-Life Hack"
---

In architectures with increasing database access frequency, concentrating direct queries on relational databases such as PostgreSQL causes latency degradation and resource exhaustion. Especially in systems with a high proportion of read requests, placing an in-memory data store in front of the persistence layer to temporarily cache query results is an effective design.


This article outlines the implementation steps for integrating Redis as a secondary cache in a Spring Boot application using the Cache-Aside pattern, as well as fallback processing during infrastructure failures.



## Architecture Configuration and Role Allocation

To balance data reliability and search performance, the responsibilities of PostgreSQL and Redis are clearly separated.



| Item | PostgreSQL | Redis |
| :--- | :--- | :--- |
| <b>Primary Responsibility</b> | Persistence of authoritative data (Source of Truth) | Temporary storage of query results (cache) |
| <b>Data Persistence</b> | Persistent storage to disk | Volatile (evicted upon reaching TTL or under memory pressure) |
| <b>Data Model</b> | Relational structure (SQL) | Key-value structure |
| <b>Consistency Guarantee</b> | Adherence to ACID transactions | Improved response speed via low-latency processing |

⚠️ Even if all Redis instances completely stop, the application must maintain a state where it can retrieve canonical data from PostgreSQL and continue processing.



## Processing Flow of the Cache-Aside Pattern

In the Cache-Aside (Lazy-Loading) pattern, the application primarily controls reading from and writing to the cache.



1. When receiving a request from a client, first check whether the specified key exists in Redis.
2. <b>Cache Hit</b>: If the key exists, return the value from Redis without accessing PostgreSQL.
3. <b>Cache Miss</b>: If the key does not exist, execute a query against PostgreSQL, write the retrieved result to Redis along with the specified TTL (Time-To-Live), and then return it to the client.

## Dependencies and Application Configuration

Add the starters for Spring Cache abstraction and Redis integration to <code>build.gradle</code>.



```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-cache'
    implementation 'org.springframework.boot:spring-boot-starter-data-redis'
}
```

Define the basic cache properties in <code>application.properties</code>. In production environments, connection information should be injected via environment variables.



```properties
spring.cache.type=redis
spring.data.redis.host=${REDIS_HOST:localhost}
spring.data.redis.port=${REDIS_PORT:6379}
spring.data.redis.password=${REDIS_PASSWORD:}
spring.cache.redis.time-to-live=10m
spring.cache.redis.cache-null-values=false
spring.cache.redis.key-prefix=my-service:
```

💡 <b>spring.cache.redis.cache-null-values=false</b>: Setting to prevent caching null values when the database query result is null.


💡 <b>spring.cache.redis.key-prefix</b>: Adds a prefix to prevent key collisions in multi-service environments.



## Enabling Cache Abstraction and Annotation Implementation

Create a configuration class annotated with <code>@EnableCaching</code> to enable cache processing via AOP proxies.



```java
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableCaching
public class CacheConfig {
}
```

Annotate service methods performing read operations with <code>@Cacheable</code>.



```java
import lombok.RequiredArgsConstructor;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class PlaceService {

    private final PlaceRepository placeRepository;

    @Cacheable(
        cacheNames = "placeDetail",
        key = "#placeId"
    )
    public PlaceDetail getDetail(Long placeId) {
        return placeRepository.findDetail(placeId);
    }
}
```

The generated Redis key format will be similar to <code>my-service:placeDetail::100</code>. Note that the Redis TTL countdown is not extended by <code>GET</code> operations; it counts uniformly from the time a write (<code>SET</code>) is performed.


During updates or deletions, use <code>@CacheEvict</code> to explicitly remove stale data.



```java
import lombok.RequiredArgsConstructor;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class PlaceService {

    private final PlaceRepository placeRepository;

    @Transactional
    @CacheEvict(
        cacheNames = "placeDetail",
        key = "#place.placeId"
    )
    public void update(Place place) {
        placeRepository.update(place);
    }

    @Transactional
    @CacheEvict(
        cacheNames = "placeDetail",
        key = "#placeId"
    )
    public void delete(Long placeId) {
        placeRepository.delete(placeId);
    }
}
```

## Fault Tolerance Design (CacheErrorHandler)

By default, Spring Cache rethrows exceptions when connection failures or timeouts occur with Redis, causing the entire request to error out. To fall back to PostgreSQL and continue processing even when Redis is down, implement a custom <code>CacheErrorHandler</code>.



```java
import lombok.extern.slf4j.Slf4j;
import org.springframework.cache.Cache;
import org.springframework.cache.annotation.CachingConfigurer;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.interceptor.CacheErrorHandler;
import org.springframework.context.annotation.Configuration;

@Slf4j
@Configuration
@EnableCaching
public class CacheConfig implements CachingConfigurer {

    @Override
    public CacheErrorHandler errorHandler() {
        return new CacheErrorHandler() {
            @Override
            public void handleCacheGetError(RuntimeException exception, Cache cache, Object key) {
                log.warn("Cache GET failed. Bypassing to DB. Cache={}, Key={}", cache.getName(), key);
            }

            @Override
            public void handleCachePutError(RuntimeException exception, Cache cache, Object key, Object value) {
                log.warn("Cache PUT failed. Proceeding without caching. Cache={}, Key={}", cache.getName(), key);
            }

            @Override
            public void handleCacheEvictError(RuntimeException exception, Cache cache, Object key) {
                log.warn("Cache EVICT failed. Cache={}, Key={}", cache.getName(), key);
            }

            @Override
            public void handleCacheClearError(RuntimeException exception, Cache cache) {
                log.warn("Cache CLEAR failed. Cache={}", cache.getName());
            }
        };
    }
}
```

## Troubleshooting

### 1. Cache Invalidation Due to Spring AOP Self-Invocation

When calling a method annotated with <code>@Cacheable</code> from another method within the same class (e.g., <code>this.getDetail(id)</code>), the Spring AOP proxy is bypassed. As a result, cache processing is not executed, and the database is always accessed.


🛠️ <b>Mitigation</b>: Separate the logic so that the target method for caching is always called from an external component/service.



### 2. Key Bloat When Applying Cache to Multivariate Search Queries

Generating cache keys by combining multiple search conditions (such as <code>keyword</code>, <code>category</code>, <code>page</code>, etc.) increases cardinality and lowers the cache hit rate. Furthermore, it unnecessarily consumes Redis memory space.


🛠️ <b>Mitigation</b>: Avoid applying cache to dynamic composite search queries and design the caching strategy primarily around single-entity primary key lookups (PK Lookups).



### 3. Cache Inconsistency During Network Partitions

If <code>@CacheEvict</code> to Redis fails due to network disruption after a successful update in PostgreSQL, the error handler prevents the application from crashing, but stale data remains in Redis.


🛠️ <b>Mitigation</b>: In domains requiring strict data consistency, consider setting a shorter TTL or implementing asynchronous retry/event-driven data invalidation mechanisms.



## Verification Command Logs

Steps for starting the Redis container in a local environment and checking key status.



```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
```

Terminal verification example:



```text
$ docker compose up -d redis
[+] Running 1/1
 Container app-redis-1  Started

$ docker compose exec redis redis-cli PING
PONG

$ docker compose exec redis redis-cli --scan --pattern "*placeDetail*"
my-service:placeDetail::100

$ docker compose exec redis redis-cli TTL "my-service:placeDetail::100"
(integer) 582

$ docker compose exec redis redis-cli DEL "my-service:placeDetail::100"
(integer) 1

$ docker compose exec redis redis-cli TTL "my-service:placeDetail::100"
(integer) -2
```

If the return value of the <code>TTL</code> command is <code>-2</code>, the key does not exist (expired or evicted); <code>-1</code> means no expiration; a positive integer represents the remaining time in seconds.



## Operational Notes

Introducing a caching layer using Redis contributes to reducing PostgreSQL load. However, because in-memory data stores are subject to memory limits (<code>maxmemory</code>) and eviction policies, systems must be designed under the assumption that data may be unexpectedly lost.


Prioritizing cache application for data with low update frequencies and high read frequencies, combined with fault fallback mechanisms via <code>CacheErrorHandler</code>, is essential for stable system operations.


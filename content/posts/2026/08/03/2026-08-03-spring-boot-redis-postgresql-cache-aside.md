---
title: "Spring BootとPostgreSQL環境におけるRedis Cache-Asideパターンの実装と障害設計"
slug: "spring-boot-redis-postgresql-cache-aside"
date: 2026-08-03T10:08:21+09:00
draft: false
image: ""
description: "PostgreSQLの読み取り負荷軽減を目的としたSpring BootとRedisによるCache-Asideパターンの構築手法、AOPプロキシの注意点、エラーハンドラによる障害設計を解説します。"
categories: ["Backend Architecture"]
tags: ["spring boot redis cache"]
author: "K-Life Hack"
---

データベースのアクセス頻度が増大するアーキテクチャでは、PostgreSQLなどのリレーショナルデータベースへの直接的なクエリ集中がレイテンシの悪化やリソース枯渇を引き起こします。特に参照リクエストの割合が高いシステムでは、永続化層の前にインメモリデータストアを配置し、クエリ結果を一時的にキャッシュする設計が有効です。

本稿では、Spring BootアプリケーションにおいてRedisをセカンダリカッシュとして組み込み、Cache-Asideパターンを適用する実装手順と、インフラ障害時のフォールバック処理について整理します。

## アーキテクチャ構成と役割分担

データの信頼性と検索性能を両立させるため、PostgreSQLとRedisの責務を明確に分離します。

| 項目 | PostgreSQL | Redis |
| :--- | :--- | :--- |
| <b>プライマリ責任</b> | 正規データ（Source of Truth）の永続化 | クエリ結果の一時保存（キャッシュ） |
| <b>データ永続性</b> | ディスクへの永続保存 | 揮発性（TTL到達またはメモリ圧迫で消去） |
| <b>データモデル</b> | リレーショナル構造（SQL） | キー・バリュー構造 |
| <b>整合性保証</b> | ACIDトランザクションの遵守 | 低レイテンシ処理による応答速度の向上 |

⚠️ Redisインスタンスが全停止した場合でも、アプリケーションはPostgreSQLから正規データを取得して処理を継続できる状態を維持する必要があります。

## Cache-Asideパターンの処理フロー

Cache-Aside（Lazy-Loading）パターンでは、アプリケーションが主体となってキャッシュの参照と書き込みを制御します。

1. クライアントからのリクエスト受信時、まずRedisに対して指定のキーが存在するか確認します。
2. <b>Cache Hit</b>: キーが存在する場合、PostgreSQLへのアクセスを行わずにRedisの値を返却します。
3. <b>Cache Miss</b>: キーが存在しない場合、PostgreSQLへクエリを発行し、取得した結果を指定のTTL（Time-To-Live）とともにRedisへ書き込んだ上でクライアントへ返却します。

## 依存関係とアプリケーション設定

build.gradle にSpring Cache抽象化とRedis連携用のスターターを追加します。

```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-cache'
    implementation 'org.springframework.boot:spring-boot-starter-data-redis'
}
```

application.properties にキャッシュの基本プロパティを定義します。本番環境では環境変数経由で接続情報を注入します。

```properties
spring.cache.type=redis
spring.data.redis.host=${REDIS_HOST:localhost}
spring.data.redis.port=${REDIS_PORT:6379}
spring.data.redis.password=${REDIS_PASSWORD:}
spring.cache.redis.time-to-live=10m
spring.cache.redis.cache-null-values=false
spring.cache.redis.key-prefix=my-service:
```

💡 <b>spring.cache.redis.cache-null-values=false</b>: データベース検索結果が null の場合にキャッシュへ空値を保存しない設定です。
💡 <b>spring.cache.redis.key-prefix</b>: マルチサービス環境でのキー衝突を防止するため、プレフィックスを付与します。

## キャッシュ抽象化の有効化とアノテーション実装

@EnableCaching を付与した設定クラスを作成し、AOPプロキシによるキャッシュ処理を有効化します。

```java
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableCaching
public class CacheConfig {
}
```

参照処理を行うサービスメソッドに @Cacheable を付与します。

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

生成されるRedisキーの形式は my-service:placeDetail::100 のようになります。なお、RedisのTTLカウントダウンは GET 操作によって延長されず、書き込み（SET）が行われた時点から一律でカウントされます。

更新・削除時には @CacheEvict を使用して古いデータ（Stale Data）を明示的に削除します。

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

## 障害耐性の設計（CacheErrorHandler）

標準状態のSpring Cacheは、Redisへの接続失敗やタイムアウト発生時に例外をそのままスローするため、リクエスト全体がエラーとなります。Redisの停止時にもPostgreSQLへフォールバックして処理を継続させるため、カスタム CacheErrorHandler を実装します。

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

### 1. Spring AOPのSelf-Invocation（自クラス内呼び出し）によるキャッシュ無効化

同一クラス内の別メソッドから @Cacheable が付与されたメソッドを呼び出した場合（例: this.getDetail(id)）、SpringのAOPプロキシを経由しないため、キャッシュ処理が実行されず常にデータベースへアクセスが行われます。
🛠️ <b>対策</b>: キャッシュ対象メソッドは必ず外部のコンポーネント/サービスから呼び出す構造に分離します。

### 2. 多変量検索クエリに対するキャッシュ適用時のキー肥大化

複数の検索条件（keyword, category, page 等）を組み合わせてキャッシュキーを生成すると、カーディナリティが高くなりキャッシュヒット率が低下します。また、Redisのメモリ領域を不要に圧迫する原因となります。
🛠️ <b>対策</b>: 動的な複合検索クエリへのキャッシュ適用は避け、エンティティ単体の主キー検索（PK Lookups）を中心にキャッシュ設計を行います。

### 3. ネットワーク分断時のキャッシュ不整合

PostgreSQLの更新処理成功後、Redisへの @CacheEvict がネットワーク障害等で失敗した場合、エラーハンドラによりアプリケーションはクラッシュしませんが、古いデータがRedisに残存します。
🛠️ <b>対策</b>: データ整合性が厳格に求められるドメインでは、TTLを短く設定するか、非同期の再処理・イベント駆動によるデータ無効化機構を検討します。

## 動作検証コマンドログ

ローカル環境でのRedisコンテナ起動およびキーの状態確認手順です。

```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
```

ターミナルでの動作検証例:

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

TTL コマンドの戻り値が -2 の場合はキーが存在しない（消失または消去済み）、-1 は期限なし、正の整数は残存時間を表します。

## Operational Notes

Redisを用いたキャッシュ階層の導入は、PostgreSQLの負荷削減に寄与します。ただし、インメモリデータストアはメモリ限界値（maxmemory）や逐出ポリシー（eviction policy）の影響を受けるため、データが予期せず消失する前提で設計を行う必要があります。

更新頻度が低く参照頻度が高いデータに対して優先的にキャッシュを適用し、CacheErrorHandler による障害時のフォールバックを組み込むことが、安定したシステム運用の条件となります。
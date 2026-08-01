---
title: "大規模アクセスに耐えるチケット予約バックエンドの設計とRedis・MySQL連携パターン"
slug: "snaptix-high-concurrency-ticketing-backend"
date: 2026-08-01T10:09:03+09:00
draft: false
image: ""
description: "大規模アクセスが集中するチケット予約システムにおける、排他ロックの回避、JWTによるステートレス認証、Redis counterを用いた在庫制御と障害時のフォールバック構成の技術実装メモです。"
categories: ["Backend Architecture"]
tags: ["jwt token validation"]
author: "K-Life Hack"
---

```json
{
  "title": "先着順チケット販売プラットフォームにおけるRedisとSpring Securityを活用した高トラフィック制御アーキテクチャ",
  "meta_description": "アクセススパイク時におけるデータベース保護、Redisアトミック操作による在庫制御、Spring Securityの循環参照回避、および障害隔離設計の技術レポート。",
  "content": "先着順のチケット販売プラットフォーム構築において、アクセススパイク時のデータベース保護と整合性の維持は極めて重要な課題です。従来のペシミスティックロック（`SELECT ... FOR UPDATE`）に依存する設計では、短時間に集中するリクエストによってMySQLの接続プールが枯渇し、クエリレイテンシの増大やデッドロックを誘発するリスクが高まります。このような制約に対応するため、ホットパストラザクションからデータベースの排他ロックを分離し、インメモリ処理と非同期制御を組み合わせたアーキテクチャへの移行が必要となります。\n\n## 認証サブシステムの設計と循環参照の回避\n\n認証層には、ステートレスなJWT（JSON Web Token）とセキュアなHTTP Cookieを採用しています。AccessTokenおよびRefreshTokenはリクエストヘッダーで直接扱わず、`HttpOnly`、`Secure`、`SameSite=Strict` フラグを付与したCookie経由で伝達することでセキュリティを担保します。\n\nSpring Security構成において、セキュリティ設定クラスと暗号化コンポーネント間の循環依存（Circular Dependency）を防ぐため、`PasswordEncoder` ビーンを独立した設定クラスへ切り出しています。\n\n

```kotlin
@Configuration
class BeanConfig {
@Bean
fun passwordEncoder(): PasswordEncoder {
return BCryptPasswordEncoder()
}
}
```

\n\nHTTPリクエスト処理時、`JwtAuthenticationFilter` は `UsernamePasswordAuthenticationFilter` の前に実行され、Cookieからトークンを抽出・検証して `SecurityContextHolder` に `AuthenticatedUser` プリンシパルを設定します。認証エラー（401 Unauthorized）および認可エラー（403 Forbidden）の捕捉は、カスタムの `CustomAuthenticationEntryPoint` と `CustomAccessDeniedHandler` によって統一されたJSON形式でクライアントに返却されます。\n\n## イベント在庫制御とRedis MGETによるバッチ参照\n\nイベント販売時における在庫減算処理は、MySQLへの直接更新を避け、Redis上のアトミックなデータ操作（Luaスクリプトおよび `DECRBY` 命令）によって行われます。イベントおよびエリアごとの在庫データは以下のキー形式でRedis内に保持されます。\n\n- イベントメタデータキャッシュ: `event:info:{eventPublicId}` (TTL: 1時間)\n- エリア別リアルタイム在庫: `ZONE:{zoneInternalId}:stock` (Integer String)\n- 注文要求ストリームキュー: `queue:order:{eventId}` (Redis Stream)\n\n大量のエリア在庫情報を取得する際、個別キーに対する単一読み込みはネットワーク往復オーバーヘッド（RTT）を増大させます。これを回避するため、`MGET` を活用したパイプライン化参照を実装しています。\n\n

```kotlin
@Component
class StockRedisGateway(
private val redisTemplate: StringRedisTemplate
) {
fun getAll(zoneIds: List<long>): Map<long, long?=""> {
if (zoneIds.isEmpty()) return emptyMap()
val keys = zoneIds.map { "ZONE:$it:stock" }
val values = redisTemplate.opsForValue().multiGet(keys) ?: return emptyMap()

return zoneIds.zip(values).toMap().mapValues { entry -&gt;
entry.value?.toLongOrNull()
}
}
}
```

\n\nRedisノードの障害時やネットワーク断絶時には、即座に例外を捕捉し、データベース上の確定済み予約数から残数を算出する動的フォールバック（`total_capacity - confirmed_count`）へ切り替える設計としています。\n\n## 非同期アラート機構と障害隔離\n\nインフラ障害やデータ不整合を検知するアラートシステムは、メインのビジネスロジック（注文・決済処理）をブロックしないよう非同期スレッドプール（`alertExecutor`）で隔離して実行されます。また、短期間に大量の同一通知がスラックへ送信される事態を防ぐため、インメモリの `ConcurrentHashMap` を用いたローカルスロットリング制御（`AlertThrottler`）を導入しています。\n\nスロットリング判定にRedisを利用しない理由は、Redis自体が障害によってダウンしている局面でもアラート機能が正常に自己完結して動作する必要があるためです。\n\n## Troubleshooting\n\n### 1. Spring Security構成における BeanCurrentlyInCreationException\n- <b>現象</b>: `SecurityConfig` 内に `BCryptPasswordEncoder` を直接 `@Bean` 定義し、それを `UserDetailsService` や `AuthService` に注入した際、コンテナ初期化時に循環依存エラーが発生しアプリケーションが起動に失敗する。\n- <b>原因</b>: セキュリティフィルターチェーンの組み立てフェーズと、認証処理で利用するサービス層のビーン生成フェーズが相互に参照し合っていたため。\n- <b>対策</b>: `BeanConfig` という独立した設定クラスを新規に作成し、`PasswordEncoder` の定義を分離抽出することで依存関係のサイクルを遮断。\n\n### 2. Exposed ORMの batchInsert における低パフォーマンスと単一実行\n- <b>現象</b>: 管理者によるイベントおよび複数ゾーンの括弧一括登録時、Exposedの `batchInsert` を呼び出しているにもかかわらず、個別の `INSERT` 文が逐次実行されレスポンスが著しく低下する。\n- <b>原因</b>: MySQL JDBCドライバの設定においてバッチリライトが無効化されており、マルチ行挿入ステートメントへ変換されていなかったため。\n- <b>対策</b>: JDBC接続URLのプロパティに `rewriteBatchedStatements=true` を明示的に追加。これにより複数行の単一クエリへ変換され、一括書き込みが正常に機能することを確認。\n\n### 3. イベント終了処理（CLOSED）時のRedisキー消去漏れ\n- <b>現象</b>: ステータス変更APIによってイベントを `CLOSED` 状態へ切り替えた際、ネットワークの一時的な瞬断により `ZONE:{zoneId}:stock` や `queue:order:{eventId}` などの運用キーが消去されず残存する。\n- <b>原因</b>: データベース状態の更新トランザクション完了後、非非同期のクリーンアップ処理中で一部の削除命令が例外により中断されていたため。\n- <b>対策</b>: 消去処理の失敗をログに記録し、未消去キーを検出・再処理するバックグラウンドの定期実行タスクを導入して不整合を自動修復。\n\n## システム動作検証プロトコル\n\n本システムにおける認証Cookieの発行およびステータス検証、プロセス状態を確認するためのターミナル実行ログの記録例です。\n\n

```text
$ curl -i -X POST http://localhost:8080/api/v1/auth/login \
-H "Content-Type: application/json" \
-d '{"email":"admin@snaptix.internal","password":"SecurePassword123!"}'

HTTP/1.1 200 OK
Set-Cookie: accessToken=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIiwicm9sZSI6IlJPTEVfQURNSU4ifQ...; Path=/; Secure; HttpOnly; SameSite=Strict
Set-Cookie: refreshToken=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIiwicm9sZSI6IlJPTEVfQURNSU4ifQ...; Path=/; Secure; HttpOnly; SameSite=Strict
Content-Type: application/json;charset=UTF-8

{"userId":1,"email":"admin@snaptix.internal"}

$ ss -tulpn | grep :8080
tcp   LISTEN 0      100              *:8080            *:*    users:(("java",pid=41029,fd=38))

$ docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
NAMES               STATUS              PORTS
snaptix-redis       Up 2 hours          0.0.0.0:6379-&gt;6379/tcp
snaptix-mysql       Up 2 hours          0.0.0.0:3306-&gt;3306/tcp, 33060/tcp
```

\n\n## Key Takeaways\n\n1. 高コンカレンシーな在庫管理においては、データベースの行排他ロックを避け、Redisのアトミック操作とストリーム構造にトラフィックを受け止める構成が有効です。\n2. 認証機構でCookieベースのJWTを運用する際は、循環依存の回避やエラーレスポンスの統一化など、フレームワーク特有の初期化構造に留意する必要があります。\n3. キャッシュ層（Redis）の障害発生を前提とし、データベースからの動的算出へ安全にフォールバックする回路をあらかじめ組み込むことがシステムの堅牢性を左右します。"
}
```</long,></long>
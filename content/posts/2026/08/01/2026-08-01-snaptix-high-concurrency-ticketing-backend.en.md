---
title: "Designing a Ticket Reservation Backend to Handle High-Volume Traffic and Redis-MySQL Integration Patterns"
slug: "snaptix-high-concurrency-ticketing-backend"
date: 2026-08-01T10:09:05+09:00
draft: false
image: ""
description: "This is a technical implementation note on avoiding exclusive locks, stateless authentication using JWT, inventory control with Redis counters, and fallback configurations during failures in a ticket reservation system facing high-volume traffic spikes."
categories: ["Backend Architecture"]
tags: ["jwt-token-validation"]
author: "K-Life Hack"
---

## Security Configuration

The security configuration defines the password encoding mechanism using BCryptPasswordEncoder to secure user credentials.



```json
{
  "title": "先着順チケット販売プラットフォームにおけるRedisとSpring Securityを活用した高トラフィック制御アーキテクチャ",
  "meta_description": "アクセススパイク時におけるデータベース保護、Redisアトミック操作による在庫制御、Spring Securityの循環参照回避、および障害隔離設計の技術レポート。",
  "content": "先着順のチケット販売プラットフォーム構築において、アクセススパイク時のデータベース保護と整合性の維持は極めて重要な課題です。従来のペシミスティックロック（`SELECT ... FOR UPDATE`）に依存する設計では、短時間に集中するリクエストによってMySQLの接続プールが枯渇し、クエリレイテンシの増大やデッドロックを誘発するリスクが高まります。このような制約に対応するため、ホットパストラザクションからデータベースの排他ロックを分離し、インメモリ処理と非同期制御を組み合わせたアーキテクチャへの移行が必要となります。

## 認証サブシステムの設計と循環参照の回避

認証層には、ステートレスなJWT（JSON Web Token）とセキュアなHTTP Cookieを採用しています。AccessTokenおよびRefreshTokenはリクエストヘッダーで直接扱わず、`HttpOnly`、`Secure`、`SameSite=Strict` フラグを付与したCookie経由で伝達することでセキュリティを担保します。

Spring Security構成において、セキュリティ設定クラスと暗号化コンポーネント間の循環依存（Circular Dependency）を防ぐため、`PasswordEncoder` ビーンを独立した設定クラスへ切り出しています。



```kotlin

## Redis Gateway Implementation

The Redis gateway implementation retrieves stock data for multiple zone IDs using a multi-get operation to minimize network round trips.



```



HTTPリクエスト処理時、`JwtAuthenticationFilter` は `UsernamePasswordAuthenticationFilter` の前に実行され、Cookieからトークンを抽出・検証して `SecurityContextHolder` に `AuthenticatedUser` プリンシパルを設定します。認証エラー（401 Unauthorized）および認可エラー（403 Forbidden）の捕捉は、カスタムの `CustomAuthenticationEntryPoint` と `CustomAccessDeniedHandler` によって統一されたJSON形式でクライアントに返却されます。

## イベント在庫制御とRedis MGETによるバッチ参照

イベント販売時における在庫減算処理は、MySQLへの直接更新を避け、Redis上のアトミックなデータ操作（Luaスクリプトおよび `DECRBY` 命令）によって行われます。イベントおよびエリアごとの在庫データは以下のキー形式でRedis内に保持されます。

- イベントメタデータキャッシュ: `event:info:{eventPublicId}` (TTL: 1時間)
- エリア別リアルタイム在庫: `ZONE:{zoneInternalId}:stock` (Integer String)
- 注文要求ストリームキュー: `queue:order:{eventId}` (Redis Stream)

大量のエリア在庫情報を取得する際、個別キーに対する単一読み込みはネットワーク往復オーバーヘッド（RTT）を増大させます。これを回避するため、`MGET` を活用したパイプライン化参照を実装しています。



```kotlin

## Authentication and Infrastructure Verification

Verification of the authentication endpoint demonstrates successful token generation and cookie issuance. System port allocation and container status confirm the operational state of the dependent services.



```



Redisノードの障害時やネットワーク断絶時には、即座に例外を捕捉し、データベース上の確定済み予約数から残数を算出する動的フォールバック（`total_capacity - confirmed_count`）へ切り替える設計としています。

## 非同期アラート機構と障害隔離

インフラ障害やデータ不整合を検知するアラートシステムは、メインのビジネスロジック（注文・決済処理）をブロックしないよう非同期スレッドプール（`alertExecutor`）で隔離して実行されます。また、短期間に大量の同一通知がスラックへ送信される事態を防ぐため、インメモリの `ConcurrentHashMap` を用いたローカルスロットリング制御（`AlertThrottler`）を導入しています。

スロットリング判定にRedisを利用しない理由は、Redis自体が障害によってダウンしている局面でもアラート機能が正常に自己完結して動作する必要があるためです。

## Troubleshooting

### 1. Spring Security構成における BeanCurrentlyInCreationException
- <b>現象</b>: `SecurityConfig` 内に `BCryptPasswordEncoder` を直接 `@Bean` 定義し、それを `UserDetailsService` や `AuthService` に注入した際、コンテナ初期化時に循環依存エラーが発生しアプリケーションが起動に失敗する。
- <b>原因</b>: セキュリティフィルターチェーンの組み立てフェーズと、認証処理で利用するサービス層のビーン生成フェーズが相互に参照し合っていたため。
- <b>対策</b>: `BeanConfig` という独立した設定クラスを新規に作成し、`PasswordEncoder` の定義を分離抽出することで依存関係のサイクルを遮断。

### 2. Exposed ORMの batchInsert における低パフォーマンスと単一実行
- <b>現象</b>: 管理者によるイベントおよび複数ゾーンの括弧一括登録時、Exposedの `batchInsert` を呼び出しているにもかかわらず、個別の `INSERT` 文が逐次実行されレスポンスが著しく低下する。
- <b>原因</b>: MySQL JDBCドライバの設定においてバッチリライトが無効化されており、マルチ行挿入ステートメントへ変換されていなかったため。
- <b>対策</b>: JDBC接続URLのプロパティに `rewriteBatchedStatements=true` を明示的に追加。これにより複数行の単一クエリへ変換され、一括書き込みが正常に機能することを確認。

### 3. イベント終了処理（CLOSED）時のRedisキー消去漏れ
- <b>現象</b>: ステータス変更APIによってイベントを `CLOSED` 状態へ切り替えた際、ネットワークの一時的な瞬断により `ZONE:{zoneId}:stock` や `queue:order:{eventId}` などの運用キーが消去されず残存する。
- <b>原因</b>: データベース状態の更新トランザクション完了後、非非同期のクリーンアップ処理中で一部の削除命令が例外により中断されていたため。
- <b>対策</b>: 消去処理の失敗をログに記録し、未消去キーを検出・再処理するバックグラウンドの定期実行タスクを導入して不整合を自動修復。

## システム動作検証プロトコル

本システムにおける認証Cookieの発行およびステータス検証、プロセス状態を確認するためのターミナル実行ログの記録例です。



```text

```


## Key Takeaways

1. In high-concurrency inventory management, avoiding database row-level exclusive locks and instead handling traffic via Redis atomic operations and stream structures is highly effective.
2. When operating cookie-based JWTs in authentication mechanisms, attention must be paid to framework-specific initialization structures, such as avoiding circular dependencies and unifying error responses.
3. Assuming potential failures in the cache layer (Redis), pre-building a circuit to safely fall back to dynamic calculations from the database is crucial for system robustness."
}
```
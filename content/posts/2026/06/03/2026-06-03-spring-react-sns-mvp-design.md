---
title: "Spring Boot 3.3とReact 18を用いた画像共有SNSのMVP実装設計"
slug: "spring-react-sns-mvp-design"
date: 2026-06-03T18:03:03+09:00
draft: false
image: ""
description: "Spring Boot 3.3とReactを用いたSNS開発の技術仕様。JWT認証、JPAデータモデル、フィード生成ロジックを含むMVP構築のロードマップを解説します。"
categories: ["Backend Architecture"]
tags: ["spring-boot-3", "react-18", "jwt-authentication", "jpa-hibernate", "postgresql"]
author: "K-Life Hack"
---

# Instagramクローン開発におけるシステムアーキテクチャと実装ロードマップ

画像共有、ソーシャルグラフ、およびリアルタイムのインタラクションを核としたSNSの開発における、アーキテクチャ設計と実装ロードマップを定義します。本ドキュメントでは、Spring Boot 3.3およびReact 18を基盤としたMVP（Minimum Viable Product）の構築に焦点を当てます。

## 1. プロジェクトの定義とMVPスコープ

本プロジェクトの目的は、ユーザーが写真をアップロードし、フォローしているユーザーの投稿を時系列で閲覧し、「いいね」や「コメント」を通じて交流できるWebサービスを構築することです。開発の複雑性を制御するため、フェーズ1（MVP）では以下の機能にスコープを限定します。

### MVP機能マトリクス

| カテゴリ | MVP実装範囲 | フェーズ2以降の検討事項 |
| :--- | :--- | :--- |
| <b>アカウント</b> | サインアップ、ログイン、プロフィール管理 | OAuth2.0、2要素認証（2FA） |
| <b>関係性</b> | フォロー / アンフォロー | ブロック機能、非公開アカウント |
| <b>投稿</b> | 単一画像アップロード、キャプション、削除 | 動画、複数画像（カルーセル）、フィルタ |
| <b>フィード</b> | フォロー中ユーザーの時系列リスト | AIレコメンデーション、無限スクロール最適化 |
| <b>インタラクション</b> | いいね、コメント（作成・一覧） | 返信（スレッド）、ブックマーク |

## 2. 技術スタックの選定理由：Decoupled Architecture

SNS特有の動的なUX（ページ遷移なしのインタラクション）を実現するため、Spring Boot + Thymeleafのモノリス構成ではなく、Spring Boot + Reactの分離構成を採用します。

*   <b>UXの向上</b>: ReactによるSPA（Single Page Application）構成により、無限スクロールや非同期の「いいね」処理など、アプリライクな操作感を提供します。
*   <b>拡張性</b>: 将来的なモバイルアプリ（React Native等）への展開を見据え、バックエンドをREST APIとして独立させます。
*   <b>開発コスト</b>: 初期設定（CORS、JWT、DTO設計）のコストは増加しますが、長期的なメンテナンス性とスケーラビリティにおいて優位性があります。

## 3. データモデリングとERD設計

リレーショナルデータベース（PostgreSQL）を用いた、コアエンティティの設計仕様です。

### 主要テーブル構造

*   <b>users</b>: `id`, `email`, `password_hash`, `username`, `avatar_url`, `bio`, `created_at`
*   <b>follows</b>: `follower_id`, `following_id`, `created_at` (複合主キー)
*   <b>posts</b>: `id`, `user_id`, `image_url`, `caption`, `created_at`
*   <b>likes</b>: `user_id`, `post_id`, `created_at` (複合主キー)
*   <b>comments</b>: `id`, `post_id`, `user_id`, `body`, `created_at`

### フィード生成ロジック（MVP版）

初期段階では、以下のクエリロジックによりフィードを生成します。ユーザー規模が拡大した場合は、Redisを用いたタイムラインキャッシュへの移行を検討します。

```sql
SELECT p.* 
FROM posts p
JOIN follows f ON p.user_id = f.following_id
WHERE f.follower_id = :currentUserId
ORDER BY p.created_at DESC
LIMIT 20 OFFSET :offset;
```

## 4. バックエンド実装仕様 (Spring Boot 3.3)

### プロジェクト構造

```text
src/main/java/com/example/instagram
├── config          // SecurityConfig, WebMvcConfig, CloudConfig
├── controller      // AuthController, PostController, UserController
├── dto             // Request/Response DTOs
├── entity          // JPA Entities (User, Post, Follow, etc.)
├── repository      // JpaRepository Interfaces
└── service         // Business Logic (AuthService, PostService)
```

### セキュリティと認証 (JWT)

ステートレスな認証を実現するため、JWT（JSON Web Token）を採用します。パスワードはBCryptでハッシュ化し、トークンは以下のライフサイクルで運用します。

*   <b>Access Token</b>: `Authorization: Bearer` ヘッダーで送信。有効期限は15分〜1時間。
*   <b>Refresh Token</b>: `HttpOnly` クッキーに保存。有効期限は7日〜14日。

```java
public String generateAccessToken(UserDetails userDetails) {
    return Jwts.builder()
            .setSubject(userDetails.getUsername())
            .setIssuedAt(new Date())
            .setExpiration(new Date(System.currentTimeMillis() + ACCESS_TOKEN_EXPIRY))
            .signWith(SignatureAlgorithm.HS512, secretKey)
            .compact();
}
```

## 5. パフォーマンスと運用の最適化

### JPA N+1問題の回避

フィード取得時、投稿ごとにユーザー情報を取得するN+1問題を回避するため、`fetch join`または`EntityGraph`を適用します。

```java
@Query("SELECT p FROM Post p JOIN FETCH p.user WHERE p.user.id IN :followingIds")
List<post> findAllByUserIdInOrderByCreatedAtDesc(@Param("followingIds") List<long> followingIds);
```

### 画像ストレージの管理

画像ファイルはDBに直接保存せず、AWS S3またはローカルストレージに保存し、DBにはそのURLのみを格納します。アップロード時には、最大5MBの制限と、jpg/png/webpの拡張子バリデーションを実装します。

## 6. 開発ロードマップ (6週間)

1.  <b>Week 1: Foundation</b>: 🛠️ Docker環境構築、Flywayによるスキーマ設計、JWT認証の実装。
2.  <b>Week 2: Profile &amp; Posts</b>: 🛠️ 画像アップロードロジック、プロフィールCRUD、投稿APIの実装。
3.  <b>Week 3: Social Graph</b>: 🛠️ フォロー/アンフォロー機能、フィード生成サービスの構築。
4.  <b>Week 4: Interaction</b>: 🛠️ いいね・コメントAPI、カウントロジックの実装。
5.  <b>Week 5: Integration</b>: 🛠️ Reactフロントエンドとの結合、Optimistic UI（楽観的更新）の適用。
6.  <b>Week 6: Deployment</b>: 🚀 HTTPS設定、ロギング、バックアップ体制の整備とデプロイ。

## Operational Notes

💡 MVP開発において最も避けるべきは「オーバーエンジニアリング」です。初期段階でマイクロサービス化や複雑なAIアルゴリズムを導入せず、まずはモノリスなバックエンドとSPAの疎結合構成を安定させることに注力します。フィードのパフォーマンスがボトルネックとなった時点で、インデックスの最適化やキャッシュ戦略を段階的に導入するのが現実的なアプローチです。</long></post>
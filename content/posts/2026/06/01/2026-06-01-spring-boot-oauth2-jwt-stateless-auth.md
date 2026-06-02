---
title: "Spring Boot 3.xにおけるOAuth2およびJWTを用いたステートレス認証基盤の構築"
slug: "spring-boot-oauth2-jwt-stateless-auth"
date: 2026-05-27T12:04:17+09:00
draft: false
image: ""
description: "Spring Boot 3.xとSpring Security 6.xを用いた、OAuth2ソーシャルログインおよびJWT認証の実装。セッション管理からステートレスなトークンベース認証への移行、セキュリティ脆弱性への対策、およびRefresh Token Rotation（RTR）の設計について詳述します。"
categories: ["Backend Architecture"]
tags: ["spring-boot-3.2.1", "spring-security-6.2.1", "jjwt-0.12.3", "oauth2-client", "jwt-authentication"]
author: "K-Life Hack"
---

## 1. 認証アーキテクチャの変遷とステートレス化の背景

現代のマイクロサービスアーキテクチャおよびスケーラブルなWebアプリケーションにおいて、認証基盤の設計はシステムの可用性とセキュリティに直結します。従来のセッションベース認証（Stateful）は、サーバー側でセッションIDを管理し、メモリやデータベースにユーザー情報を保持する形態をとります。しかし、このモデルはサーバーの水平スケーリング時にセッション同期の問題（Session Clustering）を引き起こし、インフラストラクチャのオーバーヘッドを増大させる要因となります。

これに対し、Spring Boot 3.xおよびSpring Security 6.x環境下で推奨されるJWT（JSON Web Token）ベースの認証（Stateless）は、トークン自体にユーザー情報を内包させることで、サーバー側の状態保持を不要にします。本稿では、OAuth2によるソーシャルログインとJWTを組み合わせた、堅牢な認証パイプラインの実装について技術的な分析を行います。

## 2. JWT（RFC 7519）の構造的分析と署名メカニズム

JWTは、ドット（.）で区切られた3つのセグメント（Header.Payload.Signature）で構成される標準規格です。

1. <b>Header</b>: トークンのタイプ（JWT）と署名アルゴリズム（例：HS256）を定義します。
2. <b>Payload</b>: クレーム（Claims）と呼ばれるキー・バリュー形式のデータを含みます。iss (Issuer)、sub (Subject)、exp (Expiration)などの標準クレームに加え、ユーザーの権限（Role）などのカスタムクレームを配置します。注意点として、ペイロードはBase64URLエンコードされているだけで暗号化されていないため、パスワードなどの機密情報は含めてはなりません。
3. <b>Signature</b>: ヘッダーとペイロードをサーバー側の秘密鍵（Secret Key）でハッシュ化し、改ざんを検知します。

```java
// HMAC SHA256による署名生成の概念式
HMACSHA256(
  base64UrlEncode(header) + "." + base64UrlEncode(payload),
  secret_key
)
```

## 3. セキュリティ脆弱性への対策と実装上のガードレール

JWTの実装において、技術ログから特定された以下の脆弱性に対する防御策を講じる必要があります。

💡 <b>'none' アルゴリズム攻撃</b>: ヘッダーのalgをnoneに書き換えることで署名検証をバイパスしようとする試みに対し、バックエンド側で明示的にアルゴリズムを固定し、noneを拒否するロジックを実装します。
⚠️ <b>秘密鍵の管理</b>: 署名に使用する鍵が短い、あるいは漏洩した場合、トークンの偽造が可能になります。鍵は環境変数（application.properties等）で管理し、十分な長さを確保する必要があります。
🛠️ <b>トークンの無効化問題</b>: ステートレスな性質上、一度発行されたJWTをサーバー側で即座に失効させることは困難です。これには、Redisを用いたブラックリスト方式や、後述するリフレッシュトークン戦略を併用します。

## 4. Spring Boot 3.2.1 における実装スタック

本実装では以下のスタックを採用し、依存関係の整合性を確保します。

* Framework: Spring Boot 3.2.1
* Security: Spring Security 6.2.1
* JWT Library: jjwt 0.12.3 (0.11.5以前のバージョンからAPIが大幅に変更されている点に注意)
* Database: MySQL 8.0 / Spring Data JPA

### 4.1 SecurityConfig の構成

ステートレス環境を構築するため、SecurityFilterChainを以下のように設定し、セッション管理を無効化します。

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(AbstractHttpConfigurer::disable)
            .formLogin(AbstractHttpConfigurer::disable)
            .httpBasic(AbstractHttpConfigurer::disable)
            .authorizeHttpRequests(auth -&gt; auth
                .requestMatchers("/login", "/", "/join").permitAll()
                .requestMatchers("/admin").hasRole("ADMIN")
                .anyRequest().authenticated())
            .sessionManagement(session -&gt; session
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS));

        return http.build();
    }
}
```

## 5. フィルタアーキテクチャ：認証と認可の分離

### 5.1 LoginFilter (発行フェーズ)

ログイン試行をインターセプトし、認証成功時にJWTを発行します。成功時にはAuthorizationヘッダーにBearer <token>の形式でトークンを付与し、クライアントへ返却します。

### 5.2 JWTFilter (検証フェーズ)

OncePerRequestFilterを継承し、リクエストごとにトークンの妥当性を検証するパイプラインを構築します。まずリクエストヘッダーからトークンを抽出し、JWTUtilを用いて有効期限および署名をチェックします。有効な場合、SecurityContextHolderに認証情報をセットし、そのリクエストの間だけ一時的な認証コンテキストを形成します。

## 6. トークン戦略：Access Token と Refresh Token (RTR)

セキュリティと利便性のバランスをとるため、二種類のトークンを運用する戦略を採用します。

<b>Access Token</b>は短寿命（15分〜1時間）とし、APIリクエストの認可に使用します。一方、<b>Refresh Token</b>は長寿命（1週間〜2週間）とし、Access Tokenの再発行に使用します。これはサーバー側（Redis等）およびクライアント側（HttpOnly Cookie）で厳格に管理されます。

さらに<b>Refresh Token Rotation (RTR)</b>を導入することで、リフレッシュトークンが使用されるたびに新しいリフレッシュトークンを再発行し、古いものを無効化します。これにより、トークン奪取によるリプレイアタックのリスクを最小限に抑えることが可能です。

## 7. OAuth2 ソーシャルログインの統合

spring-boot-starter-oauth2-clientを利用し、Googleやカカオ（Kakao）などのプロバイダーとの連携を自動化します。Authorization Code Grantフローに基づき、以下のステップで処理が進行します。

ユーザーをプロバイダーの認可サーバーへリダイレクトし、同意後にリダイレクトURI経由で認可コードを取得します。その後、バックチャネルで認可コードをアクセストークンと交換し、ユーザー情報を取得します。最終的にCustomOAuth2UserServiceを介してローカルDBへの保存または更新を実施し、JWTを発行してログインを完了させます。

## 8. Operational Notes

実運用における重要な留意点は以下の通りです。まず、jjwt 0.12.3の変更点として、Jwts.parserBuilder()がJwts.parser()に統合されるなど、流れるようなインターフェースへの変更が適用されています。旧バージョンのコードを流用する際はコンパイルエラーに注意が必要です。

また、フロントエンドとバックエンドのドメインが異なる場合、SecurityConfig内で適切なCORSポリシーを設定し、Authorizationヘッダーの露出を許可する必要があります。さらに、JWTの検証失敗時（ExpiredJwtException等）にクライアントへ適切なエラーレスポンス（401 Unauthorized）を返すためのAuthenticationEntryPointの実装が強く推奨されます。

## Summary

Spring Boot 3.xにおける認証基盤の構築は、Spring Security 6.xの関数型構成への移行と、JWTによるステートレス設計が核となります。OAuth2による外部認証と、RTRを適用したJWT管理を組み合わせることで、スケーラビリティとセキュリティを両立したモダンな認証システムが実現可能です。</token>
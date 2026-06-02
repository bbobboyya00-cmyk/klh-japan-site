---
title: "Spring SecurityとJWTを用いたステートレス認証認可の設計と実装"
slug: "spring-security-jwt-stateless-auth"
date: 2026-06-03T07:15:28+09:00
draft: false
image: ""
description: "Spring SecurityとJWTを統合し、ステートレスな認証認可システムを構築するための実装ノート。Spring Boot 4.xへの移行に伴うJacksonのネームスペース変更や、フィルター層でのObjectMapperインジェクションの標準化について解説します。"
categories: ["Backend Architecture"]
tags: ["spring-security", "jwt", "jackson", "spring-boot", "authentication"]
author: "K-Life Hack"
---

### 1. Spring Security &amp; JWT 統合アーキテクチャの全体像

本実装の目的は、Spring SecurityとJSON Web Token（JWT）を統合し、セッション状態を持たないステートレスな認証および認可システムを構築することです。従来のセッションベース認証から移行することで、マイクロサービスやフロントエンド・バックエンド分離アーキテクチャに適した拡張性を確保します。

```java
@Configuration
@EnableWebSecurity
@RequiredArgsConstructor
public class SecurityConfig {

private final JwtAuthFilter jwtAuthFilter;

@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
http
.csrf(csrf -&gt; csrf.disable())
.sessionManagement(session -&gt; session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
.authorizeHttpRequests(auth -&gt; auth
.requestMatchers("/api/auth/<b>", "/api/products/</b>").permitAll()
.anyRequest().authenticated()
)
.addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class);

return http.build();
}
}
```

#### 1.1 トークンの生成と検証：`JwtProvider`

💡 <b>JwtProvider</b>は、JWT ライフサイクルを管理するユーティリティクラスとして機能します。主な役割は以下の通りです。

- <b>トークン生成</b>: ユーザーの識別子（ユーザーID、ユーザー名）や付与された権限（Roles/Authorities）を含むクレーム（Claims）を設定し、適切な有効期限を設定した上で、暗号署名されたJWT（Access Tokenおよび必要に応じてRefresh Token）を生成します。

- <b>トークンの解析と検証</b>: 署名キーを使用して受け取ったJWT文字列を解析し、署名の整合性、有効期限の検証を行います。この際、ExpiredJwtException、MalformedJwtException、UnsupportedJwtException、SignatureExceptionなどの例外を適切にハンドリングします。

- <b>認証オブジェクトの生成</b>: 検証されたトークンからクレームを抽出し、Spring Securityが解釈可能なUsernamePasswordAuthenticationToken（ユーザー詳細情報および権限情報を含む）を構築します。

#### 1.2 リクエストのインターセプト：`JwtAuthFilter`

<b>JwtAuthFilter</b>は、リクエストごとに1回のみ実行されることを保証するOncePerRequestFilterを継承したカスタムセキュリティフィルターです。

1. <b>ヘッダーの抽出</b>: HTTPリクエストのAuthorizationヘッダーからBearer プレフィックスを持つトークンを検出します。

2. <b>トークンの分離</b>: プレフィックスを除去し、生のJWT文字列を抽出します。

3. <b>検証とコンテキストへの注入</b>: 抽出したトークンをJwtProviderに渡し、検証が成功した場合は取得したAuthenticationオブジェクトをSecurityContextHolder.getContext().setAuthentication(authentication)を介してセキュリティコンテキストに登録します。

4. <b>フィルターチェーンの継続</b>: filterChain.doFilter(request, response)を呼び出し、後続のフィルターに処理を委譲します。

### 2. セキュリティ設定とエンドポイントアクセス制御

SecurityConfigクラスでは、Spring Securityのフィルターチェーン（SecurityFilterChain）を定義し、公開リソースと認証が必要な保護リソースを区別します。

#### 2.1 エンドポイント認可ルールの定義

アクセシビリティとセキュリティのバランスを考慮し、以下のようにエンドポイントを分類します。

- <b>パブリックエンドポイント（permitAll()）</b>: /api/auth/<b>（新規登録、ログイン、トークン再発行など、認証未済のユーザーがアクセスするエンドポイント）および /api/products/</b>（商品カタログの閲覧、検索、詳細表示など、未ログインの一般ユーザーにも公開するエンドポイント）。

- <b>保護対象エンドポイント（anyRequest().authenticated()）</b>: カート管理、注文処理、プロフィール更新など、上記以外のすべてのリクエストは有効なJWTを要求します。

### 3. 共同開発における構造の標準化と競合回避

複数人の開発者が並行して実装を進める環境では、統合時の競合を防ぐために、共通のアーキテクチャ基盤を早期に合意しておく必要があります。

#### 3.1 共通レスポンスおよび例外構造の統一

機能開発に入る前に、以下のコンポーネントを標準化します。

- <b>ApiResponse</b>: 成功フラグ、データ、エラー情報、タイムスタンプなどを含み、API全体のレスポンス形式を統一するラッパークラス。

- <b>ErrorCode</b>: アプリケーション固有のエラーコード、対応するHTTPステータス、およびユーザー向けエラーメッセージを定義するEnum。

- <b>GlobalExceptionHandler</b>: @RestControllerAdviceを使用し、アプリケーション全体で発生した例外を捕捉して、標準化されたApiResponse形式にシリアライズして返却するグローバルハンドラー。

#### 3.2 フィルターレイヤーにおける依存関係注入の競合解消

JwtAuthFilterの実装において、認証エラー発生時にJSONレスポンスをHTTP出力ストリームに直接書き込む処理（シリアライズ）を行う際、開発者間で実装方針の不一致が生じることがあります。

💡 <b>競合の要因</b>: 一方の開発者がローカルでnew ObjectMapper()を生成するか静的ユーティリティを使用し、もう一方がSpringコンテキストで管理されるBeanの注入を前提とするケースです。

🛠️ <b>解消策</b>: Springが管理するObjectMapperのBeanをJwtAuthFilterにコンストラクタ注入（またはLombokの@RequiredArgsConstructor）する設計に統一します。これにより、アプリケーション全体で定義されたグローバルなシリアライズ設定（日付フォーマットやプロパティ命名規則など）が、フィルター層で直接response.getWriter()を介してエラーレスポンスを出力する際にも一貫して適用されます。

### 4. Spring Boot 4.x 移行における依存関係とネームスペースの変更

⚠️ モダンなJakarta EE環境への移行に伴い、Spring Boot 4.xなどの新しいバージョンでは、コアライブラリのパッケージネームスペースに変更が生じる場合があります。

- <b>Jacksonパッケージのネームスペース移行</b>: 従来、Jackson JSONプロセッサはcom.fasterxml.jacksonパッケージ配下に配置されていました。これがSpring Boot 4.x環境（および互換ライブラリ群）への移行に伴い、パッケージ構造がtools.jacksonへと移行するケースがあります。

- <b>コードベースへの影響</b>: この変更に対応するため、インポート宣言（例：import com.fasterxml.jackson.databind.ObjectMapper; から import tools.jackson.databind.ObjectMapper;）を適切に修正する必要があります。また、ビルド設定ファイル（Mavenのpom.xmlやGradle build.gradle）において、互換性のある依存関係座標が正しく指定されているか確認し、実行時のNoClassDefFoundErrorやClassNotFoundExceptionを防止します。

### 5. 開発者体験（DX）の向上とコントローラー層のクリーン化

認証・認可レイヤーを早期に安定させることで、後続のAPI開発を担当するメンバーの生産性が向上します。

#### 5.1 `@AuthenticationPrincipal`の活用

セキュリティコンテキストに認証オブジェクトが正しく登録されていれば、コントローラーのハンドラーメソッドでSpring Securityの@AuthenticationPrincipalアノテーションを使用して、認証済みユーザーの情報を直接受け取ることができます。

```java
@RestController
@RequestMapping("/api/users")
@RequiredArgsConstructor
public class UserController {

@GetMapping("/me")
public ResponseEntity<apiresponse<userprofile>&gt; getMyProfile(
@AuthenticationPrincipal UserPrincipal userPrincipal) {
UserProfile profile = UserProfile.from(userPrincipal);
return ResponseEntity.ok(ApiResponse.success(profile));
}
}
```

このアプローチにより、コントローラー層からトークン検証やパース処理のボイラープレートコードが排除され、関心の分離が実現します。

## Key Takeaways

- <b>ステートレス設計の確立</b>: JwtProviderとJwtAuthFilterを適切に組み合わせることで、セッション管理を不要にし、システムの水平拡張性を確保します。

- <b>共通基盤の早期標準化</b>: ApiResponseやErrorCodeの定義、およびフィルター層へのObjectMapper注入ルールの統一により、チーム開発における統合時の競合を未然に防ぎます。

- <b>ライブラリ移行への備え</b>: Spring Boot 4.x環境への移行時には、Jacksonのネームスペースがcom.fasterxml.jacksonからtools.jacksonへ変更される点に留意し、インポート文とビルド依存関係を適切に管理する必要があります。

- <b>開発効率の最大化</b>: セキュリティコンテキストへの認証オブジェクト登録を早期に完了させることで、コントローラー層で@AuthenticationPrincipalを利用したクリーンな実装が可能となり、全体の開発効率が向上します。</apiresponse<userprofile>
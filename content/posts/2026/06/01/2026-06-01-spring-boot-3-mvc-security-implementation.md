---
title: "Spring Boot 3.x MVCにおけるSpring Securityの実装構成と脆弱性対策"
slug: "spring-boot-3-mvc-security-implementation"
date: 2026-06-01T09:37:26+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274231_0.webp"
description: "Spring Boot 3.x MVC環境におけるSpring Securityの統合、セッションベース認証、および主要なWeb脆弱性（XSS、CSRF、SQLi）への対策手法に関する実装ノート。"
categories: ["Backend Architecture"]
tags: ["spring-security", "spring-boot-3", "session-authentication", "csrf-protection", "xss-defense"]
author: "K-Life Hack"
---

# Spring Boot 3.x における堅牢なセキュリティアーキテクチャの構築

Webアプリケーションの堅牢性を担保するためには、Spring Securityの内部構造を深く理解し、適切なフィルタ構成を適用することが不可欠です。本稿では、Spring Boot 3.xで導入されたコンポーネントベースのセキュリティ設定と、主要な攻撃ベクトルに対する具体的な防御策について、インフラおよびアプリケーションアーキテクチャの視点から整理します。

## Web脆弱性への防御戦略

現代のWebアプリケーションにおいて、以下の4つの主要な脅威に対する防御は必須要件として定義されます。これらは、フレームワークのデフォルト機能と適切なカスタム設定を組み合わせることで制御可能です。

*   <b>XSS (Cross-Site Scripting)</b>: 悪意のあるスクリプト注入を防止するため、HTMLエスケープ処理を徹底します。また、`JSESSIONID` などの機密性の高いクッキーには `HttpOnly` フラグを付与し、クライアントサイドスクリプトからのアクセスを物理的に遮断します。
*   <b>CSRF (Cross-Site Request Forgery)</b>: 状態変更を伴うリクエスト（POST, PUT, DELETE）に対して、セッションごとに固有のCSRFトークンを発行・検証します。あわせて、クッキーの `SameSite` 属性を `Lax` または `Strict` に設定し、クロスサイトでのリクエスト送信を制限します。
*   <b>CORS (Cross-Origin Resource Sharing)</b>: 同一生成元ポリシー（SOP）を緩和する際、ワイルドカード（`*`）の使用を厳格に禁止し、信頼できる特定のオリジンのみを明示的に許可するホワイトリスト方式を採用します。
*   <b>SQL Injection</b>: パラメータ化クエリ（Prepared Statements）の使用を原則とします。Spring Data JPA などのORMフレームワークを利用することで、自動的なパラメータバインディングによる防御層を構築します。



<img alt="System operational pipeline topology flow description" fetchpriority="high" height="316" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274231_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="629"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274233_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Spring Security の内部アーキテクチャ

Spring Securityは、サーブレットコンテナのフィルタチェーンとして実装されています。リクエストがコントローラーに到達する前に、多層的なセキュリティチェックが実行されます。

*   <b>DelegatingFilterProxy</b>: 標準的なサーブレットフィルタであり、Springコンテキスト内のBean（FilterChainProxy）に処理を委譲するブリッジとして機能します。
*   <b>FilterChainProxy</b>: 複数の `SecurityFilterChain` を管理し、リクエストURLや条件に応じて適切なフィルタを順次実行する中心的なエントリポイントです。
*   <b>SecurityContextHolder</b>: 認証成功後、ユーザー情報を `SecurityContext` に保持します。デフォルトで `ThreadLocal` 戦略を採用しており、1リクエスト1スレッドモデルにおいて、スレッドセーフにユーザー詳細（Authenticationオブジェクト）へのアクセスを可能にします。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274234_2.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274235_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## SecurityFilterChain によるコンポーネントベース設定

Spring Boot 3.x 以降、従来の `WebSecurityConfigurerAdapter` の継承による設定は廃止されました。現在は、Lambda式を用いた関数型スタイルによる `SecurityFilterChain` のBean定義が推奨されています。これにより、設定の可読性と柔軟性が大幅に向上しています。

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -&gt; auth
                .requestMatchers("/admin/**").hasRole("ADMIN")
                .requestMatchers("/user/**").authenticated()
                .anyRequest().permitAll()
            )
            .formLogin(form -&gt; form
                .loginPage("/login")
                .defaultSuccessUrl("/home")
                .permitAll()
            )
            .logout(logout -&gt; logout
                .logoutUrl("/logout")
                .invalidateHttpSession(true)
                .deleteCookies("JSESSIONID")
            );
        
        return http.build();
    }
}
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274237_4.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274238_5.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## セッションベース認証の実装プラクティス

Thymeleafを利用する伝統的なMVCアプリケーションでは、セッションベースの認証が標準的な選択肢となります。実装においては、以下のセキュリティ基準を遵守する必要があります。

*   <b>パスワード暗号化</b>: `BCryptPasswordEncoder` を使用し、強力な一方向ハッシュ化アルゴリズムによる保存を徹底します。
*   <b>UserDetailsService</b>: 永続化レイヤーからユーザー情報を取得し、`UserDetails` オブジェクトとしてラップするカスタムロジックを構築します。
*   <b>セッション管理ポリシー</b>: セッションハイジャックを防止するため、同時ログイン制限や、認証成功時のセッションID固定攻撃対策（Session Fixation Protection）を適用します。

```java
http.sessionManagement(session -&gt; session
    .maximumSessions(1)
    .maxSessionsPreventsLogin(false)
);
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274239_6.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274240_7.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## メソッドレベルの認可制御

URLベースのセキュリティに加え、ビジネスロジックが記述されるサービスレイヤーやコントローラーのメソッド単位で詳細な認可制御を実施します。`@EnableMethodSecurity` を有効化することで、以下の注釈による宣言的なセキュリティ定義が可能になります。

*   <b>@Secured</b>: 特定のロールを保持しているかを確認する単純なチェックに使用します。
*   <b>@PreAuthorize</b>: SpEL（Spring Expression Language）を用いて、複雑な認可ロジックを記述できます。例えば、`@PreAuthorize("#user.id == authentication.principal.id")` のように記述することで、操作対象のリソースがログインユーザー本人のものであるかを動的に検証可能です。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274242_8.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274243_9.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## ビューおよび永続化レイヤーのセキュリティ実装

フロントエンド（Thymeleaf）およびバックエンド（MyBatis/JPA）の各レイヤーにおいても、固有の脆弱性対策が必要です。

*   <b>ThymeleafのCSRF保護</b>: `th:action` 属性を使用することで、フォーム内に隠しCSRFトークンが自動的に注入されます。
*   <b>XSS防御の徹底</b>: `th:text` による自動エスケープを基本とし、`th:utext`（エスケープなし出力）の使用は厳格に制限します。JSONリクエストのサニタイズが必要な場合は、Jacksonのカスタムシリアライザやサーブレットフィルタでの統合的な処理を検討します。
*   <b>MyBatisにおける安全なバインディング</b>: SQLインジェクションを完全に排除するため、`${value}` による直接置換を避け、必ず `#{value}` による型安全なパラメータバインディングを使用してください。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274244_10.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274245_11.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


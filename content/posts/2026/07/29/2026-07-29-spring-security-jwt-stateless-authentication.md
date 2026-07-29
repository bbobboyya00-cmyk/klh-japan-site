---
title: "Spring SecurityとJJWTによるステートレス認証の設計と実装検証"
slug: "spring-security-jwt-stateless-authentication"
date: 2026-07-29T10:11:26+09:00
draft: false
image: ""
description: "Spring Security環境においてJJWTライブラリを採用し、ステートレスなJWT認証フィルターおよびプロパティ管理を実装する手順とトラブルシューティングを解説します。"
categories: ["Backend Architecture"]
tags: ["spring-security", "jwt", "jjwt", "onceperrequestfilter", "stateless"]
author: "K-Life Hack"
---

## アーキテクチャの背景と導入の動機

マイクロサービスや分散インフラストラクチャにおける水平拡張（スケールアウト）において、従来のWebアプリケーションで用いられていたサーバーサイドセッション管理は大きなボトルネックとなります。セッション情報をメモリ上に保持する構成では、ロードバランサーでのスティッキーセッション設定や、Redis等の外部セッションストアの運用コストが発生します。

これらの構造的課題に対処するため、Spring Securityのセッション作成ポリシーをステートレス（<code>SessionCreationPolicy.STATELESS</code>）に変更し、リクエストごとに自己完結型の検証が可能なJSON Web Token（JWT）を用いた認証基盤へ移行する構成を実装します。

---

## 依存関係の定義とビルド設定

JWTの生成および検証には <code>io.jsonwebtoken</code>（JJWT）ライブラリを使用します。<code>pom.xml</code> におけるスコープ指定の不備は、本番環境での実行時例外を引き起こす原因となります。

🛠️ 特に <code>jjwt-api</code> に対する <code>&lt;scope&gt;provided&lt;/scope&gt;</code> 設定が存在する場合、アプリケーションサーバー側が該当ライブラリを提供する前提となり、単体で実行されるファットJAR構成では <code>ClassNotFoundException</code> や <code>NoClassDefFoundError</code> が発生します。コンテナ実行時にライブラリが完全にバンドルされるよう、スコープを適切に定義します。

```xml
<dependency>
<groupid>io.jsonwebtoken</groupid>
<artifactid>jjwt-api</artifactid>
<version>0.11.5</version>
</dependency>
<dependency>
<groupid>io.jsonwebtoken</groupid>
<artifactid>jjwt-impl</artifactid>
<version>0.11.5</version>
<scope>runtime</scope>
</dependency>
<dependency>
<groupid>io.jsonwebtoken</groupid>
<artifactid>jjwt-jackson</artifactid>
<version>0.11.5</version>
<scope>runtime</scope>
</dependency>
```

---

## 設定情報の外部化

トークン署名に必要なシークレットキーや有効期限（Expiration time）は、コード内にハードコーディングせず、<code>application.yml</code> 経由で環境変数から注入する設計とします。

```yaml
app:
  jwt:
    secret: ${JWT_SECRET}
    issuer: paymarket
    expiration: 3600000
```

---

## JwtProvider コンポーネントの実装

<code>JwtProvider</code> はトークンの生成、署名検証、クレーム（Claims）の抽出を一括して担うコンポーネントです。署名の検証においては、トークン内の改ざんを検知するためにHMAC-SHA鍵による厳密なチェックを実施します。

```java
package com.example.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.util.Date;

@Component
public class JwtProvider {

    private final Key key;
    private final long expirationTime;
    private final String issuer;

    public JwtProvider(
            @Value("${app.jwt.secret}") String secret,
            @Value("${app.jwt.expiration}") long expirationTime,
            @Value("${app.jwt.issuer}") String issuer) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.expirationTime = expirationTime;
        this.issuer = issuer;
    }

    public String createToken(String username) {
        Date now = new Date();
        Date validity = new Date(now.getTime() + expirationTime);

        return Jwts.builder()
                .setSubject(username)
                .setIssuer(issuer)
                .setIssuedAt(now)
                .setExpiration(validity)
                .signWith(key, SignatureAlgorithm.HS256)
                .compact();
    }

    public boolean validateToken(String token) {
        try {
            Jwts.parserBuilder().setSigningKey(key).build().parseClaimsJws(token);
            return true;
        } catch (JwtException | IllegalArgumentException e) {
            return false;
        }
    }

    public String getUsername(String token) {
        Claims claims = Jwts.parserBuilder()
                .setSigningKey(key)
                .build()
                .parseClaimsJws(token)
                .getBody();
        return claims.getSubject();
    }
}
```

---

## JwtAuthenticationFilter によるリクエストの捕捉

リクエストごとに1度だけ実行されることを保証するため、<code>OncePerRequestFilter</code> を継承したカスタムフィルターを実装します。HTTPヘッダーの <code>Authorization</code> から <code>Bearer </code> プレフィックス付きのトークンを抽出し、有効な場合に <code>SecurityContext</code> へ認証情報を登録します。

```java
package com.example.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtProvider jwtProvider;
    private final UserDetailsService userDetailsService;

    public JwtAuthenticationFilter(JwtProvider jwtProvider, UserDetailsService userDetailsService) {
        this.jwtProvider = jwtProvider;
        this.userDetailsService = userDetailsService;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String token = resolveToken(request);

        if (StringUtils.hasText(token) &amp;&amp; jwtProvider.validateToken(token)) {
            String username = jwtProvider.getUsername(token);
            UserDetails userDetails = userDetailsService.loadUserByUsername(username);
            UsernamePasswordAuthenticationToken authentication =
                    new UsernamePasswordAuthenticationToken(userDetails, null, userDetails.getAuthorities());
            SecurityContextHolder.getContext().setAuthentication(authentication);
        }

        filterChain.doFilter(request, response);
    }

    private String resolveToken(HttpServletRequest request) {
        String bearerToken = request.getHeader("Authorization");
        if (StringUtils.hasText(bearerToken) &amp;&amp; bearerToken.startsWith("Bearer ")) {
            return bearerToken.substring(7);
        }
        return null;
    }
}
```

---

## SecurityConfig によるフィルターチェーンの構成

Spring Securityのフィルターチェーンにおいて、<code>JwtAuthenticationFilter</code> を <code>UsernamePasswordAuthenticationFilter</code> より前に配置します。

```java
package com.example.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    private final JwtAuthenticationFilter jwtAuthenticationFilter;

    public SecurityConfig(JwtAuthenticationFilter jwtAuthenticationFilter) {
        this.jwtAuthenticationFilter = jwtAuthenticationFilter;
    }

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -&gt; csrf.disable())
            .sessionManagement(session -&gt; session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -&gt; auth
                .requestMatchers("/api/auth/login").permitAll()
                .anyRequest().authenticated()
            )
            .addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class);

        return http.build();
    }
}
```

---

## Troubleshooting

### 組み込み時に発生する典型的な障害パターン

⚠️ <b>1. <code>NoClassDefFoundError: io/jsonwebtoken/Jwts</code></b>
・<b>原因</b>: <code>pom.xml</code> において <code>jjwt-api</code> に <code>&lt;scope&gt;provided&lt;/scope&gt;</code> が指定されているため、ファットJAR作成時にビルド生成物へ含まれず実行時にクラスが見つからなくなります。
・<b>解決策</b>: <code>&lt;scope&gt;provided&lt;/scope&gt;</code> を除去し、ランタイムに必要な推移的依存関係を含めてパッケージングします。

⚠️ <b>2. 有効なトークンを送信しても403 Forbiddenが発生する</b>
・<b>原因</b>: フィルター内でのトークン検証後、<code>SecurityContextHolder.getContext().setAuthentication(authentication)</code> によるコンテキストへの登録が漏れている、あるいはフィルターチェーンでの挿入位置が不適切です。
・<b>解決策</b>: <code>addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)</code> を明示し、検証成功時に必ず <code>SecurityContext</code> へ認証オブジェクトを格納しているか確認します。

### ターミナルでの検証プロトコルログ

💡 認証エンドポイントおよび保護されたリソースに対する動作検証ログは以下の通りです。

```text
$ curl -i -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"secretpassword"}'

HTTP/1.1 200 OK
Content-Type: application/json
Date: Wed, 29 Jul 2026 10:00:00 GMT
Content-Length: 184

{"token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImlzcyI6InBheW1hcmtldCIsImlhdCI6MTc4NTMxMjAwMCwiZXhwIjoxNzg1MzE1NjAwfQ.example_signature_hash"}

$ curl -i -X GET http://localhost:8080/api/protected \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImlzcyI6InBheW1hcmtldCIsImlhdCI6MTc4NTMxMjAwMCwiZXhwIjoxNzg1MzE1NjAwfQ.example_signature_hash"

HTTP/1.1 200 OK
Content-Type: application/json
Date: Wed, 29 Jul 2026 10:01:00 GMT

{"status":"success","data":"Access granted to protected resource"}
```

---

## Operational Notes

💡 ステートレスなJWT認証構造では、発行されたトークンをサーバー側で即座に失効させることが原則として不可能です。本運用への適用時には、短期間の有効期限（1時間程度）を設定したアクセス・トークンと、永続ストアで管理するリフレッシュ・トークン（Refresh Token）を組み合わせる2段階の制御設計を追加導入することが推奨されます。
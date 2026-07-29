---
title: "Design and Implementation Verification of Stateless Authentication with Spring Security and JJWT"
slug: "spring-security-jwt-stateless-authentication"
date: 2026-07-29T10:11:28+09:00
draft: false
image: ""
description: "Explains the procedure and troubleshooting for adopting the JJWT library in a Spring Security environment to implement a stateless JWT authentication filter and property management."
categories: ["Backend Architecture"]
tags: ["spring-security", "jwt", "jjwt", "onceperrequestfilter", "stateless"]
author: "K-Life Hack"
---

## Architectural Background and Motivation for Adoption

In horizontal scaling (scale-out) within microservices and distributed infrastructures, traditional server-side session management used in conventional web applications becomes a major bottleneck. Architectures that maintain session information in memory incur operational costs such as sticky session configuration on load balancers or external session stores like Redis.


To address these structural challenges, we change the Spring Security session creation policy to stateless (<code>SessionCreationPolicy.STATELESS</code>) and implement an architecture that migrates to an authentication infrastructure using JSON Web Tokens (JWT) capable of self-contained verification per request.



---

## Dependency Definition and Build Configuration

The <code>io.jsonwebtoken</code> (JJWT) library is used for generating and validating JWTs. Improper scope specification in <code>pom.xml</code> can cause runtime exceptions in production environments.


🛠️ In particular, if a <code>&lt;scope&gt;provided&lt;/scope&gt;</code> setting exists for <code>jjwt-api</code>, it assumes that the application server will provide the library. In a standalone fat JAR configuration, this causes a <code>ClassNotFoundException</code> or <code>NoClassDefFoundError</code>. Define the scope appropriately so that the library is fully bundled during container execution.



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

## Externalizing Configuration Information

Secret keys required for token signing and expiration times should not be hardcoded in the code, but designed to be injected from environment variables via <code>application.yml</code>.



```yaml
app:
  jwt:
    secret: ${JWT_SECRET}
    issuer: paymarket
    expiration: 3600000
```

---

## Implementation of the JwtProvider Component

<code>JwtProvider</code> is a component responsible for token generation, signature verification, and claims extraction. For signature verification, strict checks using an HMAC-SHA key are performed to detect tampering within the token.



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

## Request Interception with JwtAuthenticationFilter

To ensure execution exactly once per request, implement a custom filter extending <code>OncePerRequestFilter</code>. Extract the token prefixed with <code>Bearer </code> from the HTTP header <code>Authorization</code>, and if valid, register the authentication information in the <code>SecurityContext</code>.



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

## Configuring the Filter Chain with SecurityConfig

In the Spring Security filter chain, place <code>JwtAuthenticationFilter</code> before <code>UsernamePasswordAuthenticationFilter</code>.



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

### Typical Failure Patterns During Integration

⚠️ <b>1. <code>NoClassDefFoundError: io/jsonwebtoken/Jwts</code></b><br/>
・<b>Cause</b>: Since <code>&lt;scope&gt;provided&lt;/scope&gt;</code> is specified for <code>jjwt-api</code> in <code>pom.xml</code>, it is not included in the build artifact during fat JAR creation, causing the class to not be found at runtime.<br/>
・<b>Solution</b>: Remove <code>&lt;scope&gt;provided&lt;/scope&gt;</code> and package with the transitive dependencies required for runtime.


⚠️ <b>2. 403 Forbidden occurs even when sending a valid token</b><br/>
・<b>Cause</b>: Context registration via <code>SecurityContextHolder.getContext().setAuthentication(authentication)</code> is missing after token verification in the filter, or the insertion position in the filter chain is improper.<br/>
・<b>Solution</b>: Explicitly specify <code>addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)</code> and verify that the authentication object is always stored in the <code>SecurityContext</code> upon successful verification.



### Verification Protocol Log in Terminal

💡 Operation verification logs for authentication endpoints and protected resources are as follows.



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

💡 In a stateless JWT authentication structure, it is in principle impossible to immediately revoke an issued token on the server side. When applying to production, it is recommended to additionally introduce a two-tier control design combining short-lived access tokens (about 1 hour) with refresh tokens managed in a persistent store.


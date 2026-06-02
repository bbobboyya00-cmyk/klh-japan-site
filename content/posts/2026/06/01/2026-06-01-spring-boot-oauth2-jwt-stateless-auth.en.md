---
title: "Construction of a Stateless Authentication Infrastructure Using OAuth2 and JWT in Spring Boot 3.x"
slug: "spring-boot-oauth2-jwt-stateless-auth"
date: 2026-05-27T12:04:17+09:00
draft: false
image: ""
description: "Implementation of OAuth2 social login and JWT authentication using Spring Boot 3.x and Spring Security 6.x. Details the migration from session management to stateless token-based authentication, countermeasures against security vulnerabilities, and the design of Refresh Token Rotation (RTR)."
categories: ["Backend Architecture"]
tags: ["spring-boot-3.2.1", "spring-security-6.2.1", "jjwt-0.12.3", "oauth2-client", "jwt-authentication"]
author: "K-Life Hack"
---

## 1. Evolution of Authentication Architecture and Background of Statelessness

In modern microservices architectures and scalable web applications, the design of the authentication infrastructure directly impacts system availability and security. Traditional session-based authentication (Stateful) involves managing session IDs on the server side and maintaining user information in memory or a database. This model causes session synchronization issues (Session Clustering) during horizontal scaling of servers, increasing infrastructure overhead.


In contrast, JWT (JSON Web Token) based authentication (Stateless), recommended under Spring Boot 3.x and Spring Security 6.x environments, eliminates the need for server-side state maintenance by including user information within the token itself. Technical analysis of implementing a robust authentication pipeline combining OAuth2 social login with JWT:



## 2. Structural Analysis and Signing Mechanism of JWT (RFC 7519)

JWT is a standard consisting of three segments separated by dots (.): Header.Payload.Signature.


1. <b>Header</b>: Defines the token type (JWT) and the signing algorithm (e.g., HS256).


2. <b>Payload</b>: Contains data in key-value format called Claims. In addition to standard claims such as iss (Issuer), sub (Subject), and exp (Expiration), custom claims such as user permissions (Role) are placed here. Since the payload is only Base64URL encoded and not encrypted, sensitive information such as passwords must not be included.


3. <b>Signature</b>: Hashes the header and payload using a server-side secret key to detect tampering.



```java
// Conceptual formula for signature generation using HMAC SHA256
HMACSHA256(
  base64UrlEncode(header) + "." + base64UrlEncode(payload),
  secret_key
)
```

## 3. Countermeasures Against Security Vulnerabilities and Implementation Guardrails

JWT implementation requires defensive measures against vulnerabilities identified from technical logs.


💡 <b>'none' algorithm attack</b>: To counter attempts to bypass signature verification by changing the header's alg to none, implement logic that explicitly fixes the algorithm on the backend side and rejects none.


⚠️ <b>Secret Key Management</b>: If the key used for signing is short or leaked, token forgery becomes possible. Keys must be managed via environment variables (e.g., application.properties) and must be of sufficient length.


🛠️ <b>Token Invalidation Issue</b>: Due to its stateless nature, it is difficult to immediately revoke an issued JWT on the server side. This is addressed by using a blacklist method with Redis or the refresh token strategy.



## 4. Implementation Stack in Spring Boot 3.2.1

Implementation stack for dependency consistency:


<b>Framework</b>: Spring Boot 3.2.1


<b>Security</b>: Spring Security 6.2.1


<b>JWT Library</b>: jjwt 0.12.3 (Note: API changed significantly from versions prior to 0.11.5)


<b>Database</b>: MySQL 8.0 / Spring Data JPA



### 4.1 Configuration of SecurityConfig

SecurityFilterChain configuration for stateless environment and session management deactivation:



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

## 5. Filter Architecture: Separation of Authentication and Authorization

### 5.1 LoginFilter (Issuance Phase)

LoginFilter intercepts login attempts and issues a JWT upon successful authentication. On success, the token is attached to the Authorization header in the format Bearer <token> and returned to the client.</token>



### 5.2 JWTFilter (Verification Phase)

JWTFilter inherits from OncePerRequestFilter to verify token validity for each request. The token is extracted from the request header, and its expiration and signature are checked using JWTUtil. Valid tokens result in authentication information being set in the SecurityContextHolder for the duration of the request.



## 6. Token Strategy: Access Token and Refresh Token (RTR)

<b>Access Token</b> is short-lived (15 minutes to 1 hour) and used for API request authorization. <b>Refresh Token</b> is long-lived (1 week to 2 weeks) and used for reissuing the Access Token. This is managed on the server side (e.g., Redis) and client side (HttpOnly Cookie).


<b>Refresh Token Rotation (RTR)</b> ensures a new refresh token is reissued and the old one is invalidated upon every use. This minimizes the risk of replay attacks due to token theft.



## 7. Integration of OAuth2 Social Login

Integration with providers such as Google and Kakao is automated via spring-boot-starter-oauth2-client. Authorization Code Grant flow processing sequence:


The user is redirected to the provider's authorization server. After consent, an authorization code is obtained via the redirect URI. The authorization code is exchanged for an access token via a back-channel, and user information is retrieved. Saving or updating to the local DB is performed via CustomOAuth2UserService, and a JWT is issued to complete the login.



## 8. Operational Notes

Operational considerations and implementation details:


jjwt 0.12.3 introduces a fluent interface where Jwts.parserBuilder() is integrated into Jwts.parser(). Appropriate CORS policy must be set within SecurityConfig to allow exposure of the Authorization header if frontend and backend domains differ. Implementation of an AuthenticationEntryPoint to return 401 Unauthorized upon JWT verification failure is required.



## Summary

Building an authentication infrastructure in Spring Boot 3.x centers on the migration to the functional configuration of Spring Security 6.x and stateless design using JWT. Combining external authentication via OAuth2 with JWT management applying RTR realizes a modern authentication system balancing scalability and security.


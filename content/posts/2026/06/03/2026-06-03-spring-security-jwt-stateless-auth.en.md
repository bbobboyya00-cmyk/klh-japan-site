---
title: "Design and Implementation of Stateless Authentication and Authorization Using Spring Security and JWT"
slug: "spring-security-jwt-stateless-auth"
date: 2026-06-03T07:15:28+09:00
draft: false
image: ""
description: "Implementation notes for building a stateless authentication and authorization system by integrating Spring Security and JWT. Covers Jackson namespace changes during migration to Spring Boot 4.x and the standardization of ObjectMapper injection in the filter layer."
categories: ["Backend Architecture"]
tags: ["spring-security", "jwt", "jackson", "spring-boot", "authentication"]
author: "K-Life Hack"
---

## 1. Overview of Spring Security &amp; JWT Integration Architecture

The implementation integrates Spring Security and JSON Web Token (JWT) to establish a stateless authentication and authorization system. By migrating from session-based authentication, the architecture ensures horizontal scalability suitable for microservices and decoupled frontend-backend environments.



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

### 1.1 Token Generation and Validation: JwtProvider

<b>JwtProvider</b> functions as a utility class managing the JWT lifecycle. <b>Token Generation</b> involves setting claims such as user identifiers and authorities with appropriate expiration dates to generate signed Access and Refresh Tokens. <b>Token Parsing and Validation</b> uses a signing key to verify integrity and handle exceptions including ExpiredJwtException, MalformedJwtException, and SignatureException. <b>Authentication Object Generation</b> extracts claims to build a UsernamePasswordAuthenticationToken compatible with Spring Security.



### 1.2 Request Interception: JwtAuthFilter

<b>JwtAuthFilter</b> extends OncePerRequestFilter to ensure execution once per request. <b>Header Extraction</b> detects tokens with the Bearer prefix in the Authorization header. <b>Token Separation</b> isolates the raw JWT string by removing the prefix. <b>Validation and Context Injection</b> passes the token to JwtProvider and, upon success, registers the Authentication object into the SecurityContextHolder. <b>Filter Chain Continuation</b> delegates processing to subsequent filters via filterChain.doFilter.



## 2. Security Configuration and Endpoint Access Control

The SecurityConfig class defines the SecurityFilterChain to distinguish between public resources and protected resources requiring valid credentials.



### 2.1 Defining Endpoint Authorization Rules

<b>Public Endpoints (permitAll())</b> include /api/auth/** for registration and login, and /api/products/** for catalog browsing and searching. <b>Protected Endpoints (anyRequest().authenticated())</b> cover operations such as cart management, order processing, and profile updates, all of which require a valid JWT.



## 3. Standardization of Structure and Conflict Avoidance in Collaborative Development

Establishing common architectural foundations early prevents integration conflicts when multiple developers work in parallel.



### 3.1 Unifying Common Response and Exception Structures

Standardizing <b>ApiResponse</b> for unified formats, <b>ErrorCode</b> for application-specific statuses, and <b>GlobalExceptionHandler</b> for centralized exception serialization ensures consistency across the API layer.



### 3.2 Resolving Dependency Injection Conflicts in the Filter Layer

Inconsistencies often occur when writing JSON responses directly to the HTTP output stream during authentication errors. <b>Cause of Conflict</b> arises from variations in ObjectMapper instantiation, such as local creation versus Spring bean injection. <b>Solution</b> involves using constructor injection or @RequiredArgsConstructor to inject the Spring-managed ObjectMapper bean into JwtAuthFilter. This ensures global serialization settings, such as date formats and naming conventions, are applied consistently even when outputting error responses directly via response.getWriter().



## 4. Dependency and Namespace Changes in Spring Boot 4.x Migration

Migration to modern Jakarta EE environments in Spring Boot 4.x involves package namespace updates. <b>Jackson Package Namespace Migration</b> shifts the Jackson processor from com.fasterxml.jackson to tools.jackson. <b>Impact on Codebase</b> requires updating import declarations to tools.jackson.databind.ObjectMapper. Build configuration files in Maven or Gradle must be verified to prevent runtime NoClassDefFoundError or ClassNotFoundException.



## 5. Improving Developer Experience (DX) and Cleaning the Controller Layer

Stabilizing the authentication layer early improves productivity for subsequent API development tasks.



### 5.1 Utilizing @AuthenticationPrincipal

When the authentication object is registered in the security context, user information can be retrieved directly in controller handlers using the @AuthenticationPrincipal annotation.



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

This approach eliminates boilerplate code for token parsing within the controller layer, achieving a clean separation of concerns.



## Key Takeaways

The <b>Stateless Design</b> established through JwtProvider and JwtAuthFilter ensures horizontal scalability. <b>Early Standardization</b> of ApiResponse and ObjectMapper injection rules prevents integration conflicts. Awareness of <b>Library Migration</b>, specifically the Jackson namespace change to tools.jackson, is essential for Spring Boot 4.x. Finally, <b>Maximizing Development Efficiency</b> is achieved by utilizing @AuthenticationPrincipal to simplify controller implementation.

</apiresponse<userprofile>
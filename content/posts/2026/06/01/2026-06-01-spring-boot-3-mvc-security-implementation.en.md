---
title: "Spring Security Implementation and Vulnerability Mitigation in Spring Boot 3.x MVC"
slug: "spring-boot-3-mvc-security-implementation"
date: 2026-06-01T09:37:26+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274231_0.webp"
description: "Implementation notes on Spring Security integration, session-based authentication, and mitigation techniques for major web vulnerabilities (XSS, CSRF, SQLi) in a Spring Boot 3.x MVC environment."
categories: ["Backend Architecture"]
tags: ["spring-security", "spring-boot-3", "session-authentication", "csrf-protection", "xss-defense"]
author: "K-Life Hack"
---

## Building Robust Security Architecture in Spring Boot 3.x

To ensure web application robustness, it is essential to deeply understand the internal structure of Spring Security and apply appropriate filter configurations. This article outlines component-based security settings introduced in Spring Boot 3.x and specific defense measures against major attack vectors from infrastructure and application architecture perspectives.



## Defense Strategies Against Web Vulnerabilities

In modern web applications, defense against the following four major threats is defined as a mandatory requirement. These can be controlled by combining framework default features with appropriate custom configurations.


<b>XSS (Cross-Site Scripting)</b>: To prevent malicious script injection, enforce HTML escaping. Additionally, apply the HttpOnly flag to sensitive cookies such as JSESSIONID to physically block access from client-side scripts.


<b>CSRF (Cross-Site Request Forgery)</b>: Issue and verify a unique CSRF token per session for requests involving state changes (POST, PUT, DELETE). Simultaneously, set the cookie's SameSite attribute to Lax or Strict to restrict cross-site request transmission.


<b>CORS (Cross-Origin Resource Sharing)</b>: When relaxing the Same-Origin Policy (SOP), strictly prohibit the use of wildcards (*) and adopt a whitelist approach that explicitly allows only specific trusted origins.


<b>SQL Injection</b>: As a rule, use parameterized queries (Prepared Statements). By utilizing ORM frameworks like Spring Data JPA, build a defense layer through automatic parameter binding.




<img alt="System operational pipeline topology flow description" fetchpriority="high" height="316" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274231_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="629"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274233_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Spring Security Internal Architecture

Spring Security is implemented as a servlet container filter chain. Multi-layered security checks are executed before a request reaches the controller.


<b>DelegatingFilterProxy</b>: A standard servlet filter that acts as a bridge, delegating processing to a bean (FilterChainProxy) within the Spring context.


<b>FilterChainProxy</b>: The central entry point that manages multiple SecurityFilterChain instances and sequentially executes appropriate filters based on request URLs or conditions.


<b>SecurityContextHolder</b>: Holds user information in the SecurityContext after successful authentication. It adopts the ThreadLocal strategy by default, enabling thread-safe access to user details (Authentication object) in a one-request-per-thread model.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274234_2.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274235_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Component-Based Configuration via SecurityFilterChain

Since Spring Boot 3.x, configuration via inheritance of WebSecurityConfigurerAdapter has been deprecated. Defining SecurityFilterChain beans using a functional style with Lambda expressions is now recommended. This significantly improves configuration readability and flexibility.



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



## Implementation Practices for Session-Based Authentication

In traditional MVC applications using Thymeleaf, session-based authentication is the standard choice. Implementation must comply with the following security standards:


<b>Password Encryption</b>: Use BCryptPasswordEncoder to ensure storage using a strong one-way hashing algorithm.


<b>UserDetailsService</b>: Construct custom logic to retrieve user information from the persistence layer and wrap it as a UserDetails object.


<b>Session Management Policy</b>: To prevent session hijacking, apply concurrent login limits and Session Fixation Protection measures upon successful authentication.



```java
http.sessionManagement(session -&gt; session
    .maximumSessions(1)
    .maxSessionsPreventsLogin(false)
);
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274239_6.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274240_7.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Method-Level Authorization Control

In addition to URL-based security, implement granular authorization control at the service layer or controller method level where business logic resides. Enabling @EnableMethodSecurity allows declarative security definitions using the following annotations:


<b>@Secured</b>: Used for simple checks to verify if a user holds a specific role.


<b>@PreAuthorize</b>: Allows writing complex authorization logic using SpEL (Spring Expression Language). For example, using @PreAuthorize("#user.id == authentication.principal.id") dynamically verifies if the target resource belongs to the logged-in user.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274242_8.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274243_9.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Security Implementation in View and Persistence Layers

Specific vulnerability countermeasures are required in both the frontend (Thymeleaf) and backend (MyBatis/JPA) layers.


<b>Thymeleaf CSRF Protection</b>: Using the th:action attribute automatically injects a hidden CSRF token into the form.


<b>Enforcing XSS Defense</b>: Base defense on automatic escaping with th:text, and strictly limit the use of th:utext (unescaped output). If sanitization of JSON requests is required, consider integrated processing via Jackson custom serializers or servlet filters.


<b>Safe Binding in MyBatis</b>: To completely eliminate SQL injection, avoid direct substitution with ${value} and always use type-safe parameter binding with #{value}.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274244_10.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/06/01/spring-boot-3-mvc-security-implementation/khack_1780274245_11.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


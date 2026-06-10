---
title: "Implementation of Migration to a Stateless JWT Authentication Infrastructure in Spring Boot and React"
slug: "spring-boot-react-jwt-migration-guide"
date: 2026-06-10T18:54:12+09:00
draft: false
image: ""
description: "Details the migration process from session-based authentication to JWT (Access/Refresh Token). Explains implementation using Spring Boot and React, countermeasures for concurrent requests, and improvement results in operational metrics."
categories: ["Backend Architecture"]
tags: ["spring-boot", "spring-security", "jwt", "react", "axios-interceptor", "stateless-auth"]
author: "K-Life Hack"
---

# Building a Scalable Authentication Infrastructure in Modern Web Applications: Migration Strategy from Session-Based to JWT

In the scalability of modern web applications, the authentication and authorization architecture is a critical pillar that goes beyond mere security requirements to dictate system availability and operational stability. In a decoupled architecture combining a Spring Boot REST API and a React SPA (Single Page Application), strategies for authentication state management, token expiration, and silent refresh directly impact system resilience.


This article describes the technical details of the process undertaken by CORNERSTONE (cornerstone.io.kr) to migrate from a traditional stateful server-side session model to a stateless JWT model utilizing dual-token rotation (Access/Refresh Token).



## Challenges of the Existing Session-Based Architecture

The system prior to migration relied on standard Spring Boot session management. As traffic increased, the following operational bottlenecks became apparent:



- <b>Operational load of session clustering</b>: Horizontal scaling required the management of sticky sessions or distributed session stores via Redis, increasing infrastructure complexity.
- <b>Authentication inconsistency during deployment</b>: During instance termination due to rolling updates or auto-scaling, users were unexpectedly logged out due to session synchronization delays.
- <b>Inconsistent error handling</b>: The backend would sometimes return 302 redirects or 500 errors upon authentication failure, making it difficult for the SPA to programmatically distinguish between expiration and server errors.

To resolve these issues, the decision was made to migrate to a stateless JWT architecture based on priorities of reliability, security, operational convenience, and development velocity.



## Target Architecture and Security Policy

The designed JWT authentication infrastructure is based on token separation, secure storage, and a standardized error contract.



| Token Type | Expiration | Storage Location | Transmission Mechanism |
| :--- | :--- | :--- | :--- |
| Access Token | 15 minutes | Client Memory (React) | Authorization Header (Bearer) |
| Refresh Token | 14 days | HttpOnly, Secure, SameSite=Lax Cookie | Cookie Header (Automatic) |

### Key Security Policies

- <b>Access Token</b>: To prevent token theft via XSS attacks, it is not stored in `localStorage` but held only in memory.
- <b>Refresh Token</b>: The `HttpOnly` attribute is applied to block access from JavaScript, and the `Secure` attribute is applied to allow only HTTPS communication.
- <b>Authorization Model</b>: Role-Based Access Control (RBAC) is adopted, and by including roles as claims in the JWT payload, authorization checks can be performed without database lookups.

## Backend Implementation: Spring Boot

A stateless verification process is realized through the configuration of a `JwtAuthenticationFilter` that extracts the token from the Authorization header for every request and validates the signature and expiration.



```java
package io.cornerstone.security.jwt;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
@RequiredArgsConstructor
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtTokenProvider jwtTokenProvider;
    private static final String AUTHORIZATION_HEADER = "Authorization";
    private static final String BEARER_PREFIX = "Bearer ";

    @Override
    protected void doFilterInternal(HttpServletRequest request, 
                                    HttpServletResponse response, 
                                    FilterChain filterChain) throws ServletException, IOException {
        
        String token = resolveAccessToken(request);

        if (StringUtils.hasText(token) &amp;&amp; jwtTokenProvider.validateAccessToken(token)) {
            Authentication authentication = jwtTokenProvider.getAuthentication(token);
            SecurityContextHolder.getContext().setAuthentication(authentication);
        }

        filterChain.doFilter(request, response);
    }

    private String resolveAccessToken(HttpServletRequest request) {
        String bearerToken = request.getHeader(AUTHORIZATION_HEADER);
        if (StringUtils.hasText(bearerToken) &amp;&amp; bearerToken.startsWith(BEARER_PREFIX)) {
            return bearerToken.substring(BEARER_PREFIX.length());
        }
        return null;
    }
}
```

## Frontend Implementation: Concurrent Request Control via Axios Interceptors

To prevent a "refresh storm" where multiple API requests simultaneously trigger 401 errors when a token expires, a queuing mechanism was built to temporarily hold subsequent requests and execute them in bulk after token reissue.



```javascript
import axios from 'axios';

const api = axios.create({
  baseURL: 'https://api.cornerstone.io.kr',
  withCredentials: true
});

let isRefreshing = false;
let failedQueue = [];

const processQueue = (error, token = null) =&gt; {
  failedQueue.forEach((prom) =&gt; {
    if (error) {
      prom.reject(error);
    } else {
      prom.resolve(token);
    }
  });
  failedQueue = [];
};

api.interceptors.response.use(
  (response) =&gt; response,
  async (error) =&gt; {
    const originalRequest = error.config;

    if (error.response?.status === 401 &amp;&amp; !originalRequest._retry) {
      if (isRefreshing) {
        return new Promise((resolve, reject) =&gt; {
          failedQueue.push({ resolve, reject });
        })
          .then((token) =&gt; {
            originalRequest.headers.Authorization = `Bearer ${token}`;
            return api(originalRequest);
          })
          .catch((err) =&gt; Promise.reject(err));
      }

      originalRequest._retry = true;
      isRefreshing = true;

      return new Promise((resolve, reject) =&gt; {
        axios.post('https://api.cornerstone.io.kr/auth/refresh', {}, { withCredentials: true })
          .then((res) =&gt; {
            const newAccessToken = res.data.accessToken;
            // Update the in-memory token store
            originalRequest.headers.Authorization = `Bearer ${newAccessToken}`;
            processQueue(null, newAccessToken);
            resolve(api(originalRequest));
          })
          .catch((err) =&gt; {
            processQueue(err, null);
            window.location.href = '/login?expired=true';
            reject(err);
          })
          .finally(() =&gt; {
            isRefreshing = false;
          });
      });
    }
    return Promise.reject(error);
  }
);
```

## Operational Troubleshooting and Edge Cases

### 1. Client and Server Clock Synchronization (Clock Skew)

Validating the JWT `exp` claim on the client side posed a risk of infinite redirects due to discrepancies in device time settings. To avoid this, client-side pre-validation was abolished, and the design was changed to trigger only on 401 responses from the server. Additionally, a 60-second leeway (allowable error) was set on the server side to account for network latency.



### 2. Authentication State Sync Across Multiple Tabs

There was an issue where if a logout occurred in one tab, other tabs would continue to hold the old in-memory token. To solve this, logic was implemented to synchronize the authentication state across browser tabs using the `StorageEvent` API.



```javascript
window.addEventListener('storage', (event) =&gt; {
  if (event.key === 'cornerstone_logout_event') {
    // Clear in-memory tokens and redirect
    window.location.href = '/login?expired=true';
  }
});
```

## Operational Metric Improvement Results

Based on observation data for 90 days post-migration, significant improvements were confirmed in both infrastructure stability and user experience.



- <b>Authentication-related support tickets</b>: Decreased from a monthly average of 32 to 11 (-65.6%)
- <b>Peak authentication failure rate</b>: Improved from 3.1% to 0.9% (-2.2%p)
- <b>Average token reissue latency</b>: Reduced from 240ms to 130ms (-45.8%)

## Lessons Learned

In migrating from stateful sessions to stateless JWT, the most important factor is not the choice of technology itself, but the formulation of a consistent policy regarding token storage, expiration, and error handling. In particular, considering edge cases such as refresh storms caused by concurrent requests and client-side clock synchronization discrepancies during the design phase is essential for stable operation in production environments. At CORNERSTONE, by establishing a strict API contract between the frontend and backend, we were able to build a scalable and fault-tolerant authentication infrastructure.


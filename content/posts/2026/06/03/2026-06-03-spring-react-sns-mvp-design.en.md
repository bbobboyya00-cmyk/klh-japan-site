---
title: "MVP Implementation Design for an Image-Sharing SNS Using Spring Boot 3.3 and React 18"
slug: "spring-react-sns-mvp-design"
date: 2026-06-03T18:03:04+09:00
draft: false
image: ""
description: "Technical specifications for SNS development using Spring Boot 3.3 and React. Explains the roadmap for building an MVP, including JWT authentication, JPA data models, and feed generation logic."
categories: ["Backend Architecture"]
tags: ["spring-boot-3", "react-18", "jwt-authentication", "jpa-hibernate", "postgresql"]
author: "K-Life Hack"
---

# System Architecture and Implementation Roadmap for Instagram Clone Development

This document defines the architectural design and implementation roadmap for an SNS platform centered on image sharing, social graphs, and real-time interactions. The development focuses on a Minimum Viable Product (MVP) utilizing Spring Boot 3.3 and React 18.



## 1. Project Definition and MVP Scope

The project objective is to construct a web service enabling photo uploads, chronological feed viewing of followed users, and interaction via likes and comments. Phase 1 scope is restricted to core features to manage development complexity.



### MVP Feature Matrix

| Category | MVP Implementation Scope | Post-Phase 2 Considerations |
| :--- | :--- | :--- |
| <b>Account</b> | Sign-up, login, profile management | OAuth 2.0, Two-Factor Authentication (2FA) |
| <b>Relationships</b> | Follow / Unfollow | Block function, private accounts |
| <b>Posts</b> | Single image upload, caption, deletion | Video, multiple images (carousel), filters |
| <b>Feed</b> | Chronological list of followed users | AI recommendations, infinite scroll optimization |
| <b>Interaction</b> | Likes, comments (creation/list) | Replies (threads), bookmarks |

## 2. Rationale for Tech Stack Selection: Decoupled Architecture

A decoupled architecture using Spring Boot and React is selected over a monolithic Spring Boot and Thymeleaf configuration to ensure a dynamic UX. This Single Page Application (SPA) structure supports infinite scrolling and asynchronous processing.



*   <b>UX Improvement</b>: The SPA configuration using React provides an app-like user experience, including infinite scrolling and asynchronous "like" processing.
*   <b>Scalability</b>: The backend is independent as a REST API, anticipating future expansion to mobile apps.
*   <b>Development Cost</b>: While initial setup costs for CORS, JWT, and DTO design increase, it offers advantages in long-term maintainability and scalability.

## 3. Data Modeling and ERD Design

Core entities are designed for a relational database environment using PostgreSQL.



### Primary Table Structure

*   <b>users</b>: `id`, `email`, `password_hash`, `username`, `avatar_url`, `bio`, `created_at`
*   <b>follows</b>: `follower_id`, `following_id`, `created_at` (Composite Primary Key)
*   <b>posts</b>: `id`, `user_id`, `image_url`, `caption`, `created_at`
*   <b>likes</b>: `user_id`, `post_id`, `created_at` (Composite Primary Key)
*   <b>comments</b>: `id`, `post_id`, `user_id`, `body`, `created_at`

### Feed Generation Logic (MVP Version)

Feed generation utilizes specific query logic. Migration to a timeline cache using Redis is planned for future scaling.



```sql
SELECT p.* 
FROM posts p
JOIN follows f ON p.user_id = f.following_id
WHERE f.follower_id = :currentUserId
ORDER BY p.created_at DESC
LIMIT 20 OFFSET :offset;
```

## 4. Backend Implementation Specifications (Spring Boot 3.3)

### Project Structure

```text
src/main/java/com/example/instagram
├── config          // SecurityConfig, WebMvcConfig, CloudConfig
├── controller      // AuthController, PostController, UserController
├── dto             // Request/Response DTOs
├── entity          // JPA Entities (User, Post, Follow, etc.)
├── repository      // JpaRepository Interfaces
└── service         // Business Logic (AuthService, PostService)
```

### Security and Authentication (JWT)

JWT (JSON Web Token) is utilized for stateless authentication. Passwords undergo BCrypt hashing. The token lifecycle includes short-term Access Tokens and long-term Refresh Tokens stored in HttpOnly cookies.



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

## 5. Performance and Operational Optimization

### Avoiding JPA N+1 Problems

To prevent JPA N+1 issues during feed retrieval, fetch join or EntityGraph is implemented.



```java
@Query("SELECT p FROM Post p JOIN FETCH p.user WHERE p.user.id IN :followingIds")
List<post> findAllByUserIdInOrderByCreatedAtDesc(@Param("followingIds") List<long> followingIds);
```

### Image Storage Management

Image assets are stored in AWS S3 or local storage, with only the corresponding URLs persisted in the database. Upload constraints include a 5MB size limit and extension validation for jpg, png, and webp.



## 6. Development Roadmap (6 Weeks)

1.  <b>Week 1: Foundation</b>: 🛠️ Docker environment setup, schema design with Flyway, implementation of JWT authentication.
2.  <b>Week 2: Profile &amp; Posts</b>: 🛠️ Image upload logic, profile CRUD, implementation of post APIs.
3.  <b>Week 3: Social Graph</b>: 🛠️ Follow/unfollow functionality, construction of feed generation service.
4.  <b>Week 4: Interaction</b>: 🛠️ Like/comment APIs, implementation of count logic.
5.  <b>Week 5: Integration</b>: 🛠️ Integration with React frontend, application of Optimistic UI.
6.  <b>Week 6: Deployment</b>: 🚀 HTTPS configuration, logging, establishment of backup systems, and deployment.

## Operational Notes

MVP development must prioritize architectural stability over complex features. Initial focus remains on the decoupled configuration of the backend and SPA. Optimization strategies such as indexing and caching are deferred until performance bottlenecks are identified.

</long></post>
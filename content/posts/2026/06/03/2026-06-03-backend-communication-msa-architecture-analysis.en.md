---
title: "Protocol Selection in Backend Communication Design and Structural Analysis of MSA Architecture"
slug: "backend-communication-msa-architecture-analysis"
date: 2026-06-03T09:17:37+09:00
draft: false
image: ""
description: "Provides a comparative analysis of REST, GraphQL, gRPC, and WebSocket, along with explanations of Saga patterns in MSA, API gateway design, and HTTPS implementation procedures in Spring Boot."
categories: ["Backend Architecture"]
tags: ["gRPC", "GraphQL", "MSA", "Saga-Pattern", "Spring-Boot", "API-Gateway"]
author: "K-Life Hack"
---

# Analysis of Communication Protocols and MSA Design Strategies in Modern Backend

In modern backend engineering, the choice of communication patterns is a critical decision that determines system performance, development productivity, and scalability. This analysis evaluates the characteristics of major communication protocols, design strategies in Microservices Architecture (MSA), and specific implementation methods.



## 1. Technical Comparison Matrix of Communication Patterns

In environments where MSA or real-time performance is required, multiple patterns are strategically combined according to the use case rather than relying on a single standard.



| Feature | REST | GraphQL | gRPC | WebSocket |
| :--- | :--- | :--- | :--- | :--- |
| <b>Paradigm</b> | Resource-oriented | Query-oriented | Procedural Call (RPC) | Event/Stream-oriented |
| <b>Network Protocol</b> | HTTP/1.1, HTTP/2 | HTTP/1.1, HTTP/2 | HTTP/2 (Required) | WebSocket (TCP) |
| <b>Data Format</b> | JSON, XML, etc. | JSON | Protocol Buffers | No restrictions (usually JSON) |
| <b>Communication Method</b> | Unidirectional (Req/Res) | Unidirectional (Req/Res) | Bidirectional Streaming | Full-duplex (Bidirectional) |
| <b>Primary Use Cases</b> | General Public APIs | Web/Mobile Frontend | Internal Inter-MSA Communication | Real-time Data Transfer |

## 2. Mechanisms and Constraints of Each Protocol

REST identifies resources via URIs and defines actions using standard HTTP methods (GET, POST, PUT, DELETE). It facilitates static caching (Cache-Control) by leveraging HTTP standard characteristics and maintains a low learning curve. Conversely, it is prone to "Over-fetching" (retrieving unnecessary data) and "Under-fetching" (requiring multiple API calls for a single screen configuration).


GraphQL uses a single endpoint (/graphql) where the client specifies the required data structure in a query. It allows for retrieving exact data in a single request, minimizing backend schema changes in response to frontend requirement changes. However, since queries are dynamic, URL-based HTTP caching is difficult, and server load may increase due to complex nested queries.


gRPC combines HTTP/2 multiplexing performance with binary serialization via Protocol Buffers (Protobuf). Being binary-based, packet sizes are minimized, enabling high-speed serialization and deserialization. It supports strict type definitions and code generation via .proto files. Constraints include the requirement for a proxy like gRPC-Web for direct browser calls and a dedicated decoder for debugging due to the binary format.


WebSocket establishes a persistent TCP-based connection via an HTTP handshake to achieve full-duplex communication. It eliminates HTTP header overhead and enables server push with low latency. However, it results in a stateful design that increases backend memory consumption to maintain connections, and reconnection logic implementation is complex.



## 3. Communication Design Strategies in Microservices

In MSA, synchronous and asynchronous patterns are used selectively to manage the degree of coupling between services.



### Synchronous Communication and Resilience

In synchronous communication using gRPC or REST, the caller waits for a response. To prevent latency accumulation in the call chain, the adoption of gRPC for internal communication is recommended. The introduction of the <b>Circuit Breaker</b> pattern is essential to prevent cascading failures.



### Asynchronous Messaging and Event-Driven

Events are published and subscribed via message brokers such as Apache Kafka or RabbitMQ. This ensures fault tolerance, as the coupling between services is low, allowing other services to continue processing even if a specific service is temporarily down.



### Distributed Transactions: Saga Pattern

To maintain data consistency in distributed database environments, the Saga pattern using Compensating Transactions is applied.



*   <b>Choreography</b>: A method where each service exchanges events and operates autonomously without central control.
*   <b>Orchestration</b>: A method where a central "Saga Manager" instructs each service on the communication to be executed.

## 4. Role and Design Requirements of API Gateways

An API Gateway functions as a single entry point for all client requests and manages the following responsibilities:



1.  <b>Routing</b>: Forwarding requests to the appropriate microservice based on the URI.
2.  <b>Authentication Aggregation</b>: Batch processing of JWT token verification at the gateway layer.
3.  <b>Load Balancing</b>: Distributing traffic to dynamic instances in coordination with Service Discovery (Eureka, Consul, etc.).
4.  <b>Rate Limiting</b>: Limiting the number of calls per IP (429 Too Many Requests) for DDoS protection and resource preservation.

To handle large volumes of traffic, solutions adopting non-blocking I/O models, such as Spring Cloud Gateway or Kong, are commonly selected.



## 5. Local HTTPS Implementation in Spring Boot

Verification of OAuth2 and SameSite cookie policies requires HTTPS in local environments. Implementation procedure using mkcert:



### Certificate Generation

```bash
# Install local CA
mkcert -install

# Generate PKCS12 certificate for localhost
mkcert -pkcs12 localhost
```

### Spring Boot Configuration (application.yml)

Placement of the generated keystore.p12 in src/main/resources/ and application of configuration settings:



```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:keystore.p12
    key-store-password: changeit
    key-store-type: PKCS12
    key-alias: localhost
```

Verification of the startup log for "Tomcat initialized with port(s): 8443 (https)". For security reasons, the .p12 file must be added to .gitignore to avoid inclusion in the repository.



## Configuration Notes

The selection of communication protocols is a product of trade-offs based on network topology, data consistency requirements, and operational costs. A multi-layered approach—utilizing gRPC for internal communication to achieve high efficiency while ensuring interoperability for external use via REST—is the standard configuration in modern backend architecture.


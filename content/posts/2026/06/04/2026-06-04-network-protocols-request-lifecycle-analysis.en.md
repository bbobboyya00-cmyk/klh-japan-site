---
title: "Network Protocols and Request Lifecycle Structure in Backend Design"
slug: "network-protocols-request-lifecycle-analysis"
date: 2026-06-04T10:09:58+09:00
draft: false
image: ""
description: "A technical guide for backend engineers covering the OSI 7-layer model, the evolution from HTTP/1.1 to HTTP/3, DNS resolution flows, the operating principles of reverse proxies and L4/L7 load balancers, and the end-to-end request lifecycle."
categories: ["Backend Architecture"]
tags: ["nginx", "http3", "dns-records", "load-balancing", "tcp-handshake"]
author: "K-Life Hack"
---

## Network Layer Stack Structure (OSI 7-Layer vs. TCP/IP 4-Layer)

Understanding the network stack is essential for designing and building backend systems. The mapping of the OSI 7-layer model to the TCP/IP 4-layer model, along with a summary of key technical elements in backend development, is structured as follows.



```text
+-----------------------------------+-----------------------------------+
| OSI 7-Layer Model                 | TCP/IP 4-Layer Model              |
+-----------------------------------+-----------------------------------+
| Layer 7: Application Layer        |                                   |
| Layer 6: Presentation Layer       | Layer 4: Application Layer        |
| Layer 5: Session Layer            |                                   |
+-----------------------------------+-----------------------------------+
| Layer 4: Transport Layer          | Layer 3: Transport Layer          |
+-----------------------------------+-----------------------------------+
| Layer 3: Network Layer            | Layer 2: Internet Layer           |
+-----------------------------------+-----------------------------------+
| Layer 2: Data Link Layer          | Layer 1: Network Access Layer     |
| Layer 1: Physical Layer           |                                   |
+-----------------------------------+-----------------------------------+
```

### Layers 5–7 (OSI) $\rightarrow$ Layer 4: Application Layer (TCP/IP)

Defines communication protocols that interact directly with application software to generate and exchange data over the network.



*   <b>HTTP/HTTPS:</b>
*   <b>REST API Design:</b> Resource structuring, utilization of appropriate HTTP methods (GET, POST, PUT, DELETE), and definition of status lines.
*   <b>Status Codes:</b> Semantic classification into success ($2xx$), client errors ($4xx$), and server errors ($5xx$).
*   <b>Header Management:</b> Control of headers such as `Cookie`, `Cache-Control`, and `CORS` (Cross-Origin Resource Sharing).
*   <b>Session and Proxy Headers:</b>
    *   `Set-Cookie`: Sent by the server to the browser to transmit session IDs or custom settings and initiate session management.
    *   `Cookie`: Returns cookie information stored in the browser back to the server in subsequent requests.
    *   `X-Forwarded-For` (XFF) and `X-Forwarded-Proto` (XFP): Used to identify the original client IP and protocol when passing through proxies or load balancers.
*   <b>gRPC:</b>
    *   A Remote Procedure Call (RPC) framework based on HTTP/2, used for high-speed, low-latency inter-service communication in microservice architectures (MSA).
    *   <b>Binary Framing:</b> Instead of text-based messages like JSON, data is serialized into a binary format called "frames," reducing payload overhead and accelerating parsing.
    *   <b>Multiplexing:</b> Creates multiple virtual bidirectional channels called "streams" within a single TCP connection, multiplexing requests and responses in parallel to eliminate Head-of-Line (HoL) blocking at the application layer.
    *   <b>HPACK:</b> A compression algorithm dedicated to HTTP/2 headers that uses static and dynamic tables to eliminate duplicate header fields, reducing bandwidth consumption.
    *   <b>Server Push:</b> A feature where the server analyzes the initial request from the client and proactively sends required resources to the client cache before the client explicitly requests them.
*   <b>Data Serialization:</b> Converts and parses structured data using formats like JSON or Protocol Buffers (Protobuf) for network transmission.
*   <b>Authentication and Authorization:</b> Implementation of secure user identification and access control using JSON Web Tokens (JWT) or session-based architectures.

### Layer 4 (OSI) $\rightarrow$ Layer 3: Transport Layer (TCP/IP)

Controls end-to-end communication reliability, flow control, and connection management between specific processes (identified by port numbers) from the source host to the destination host.



*   <b>TCP (Transmission Control Protocol):</b>
    *   <b>Connection Management:</b> Connection establishment via a <b>3-Way Handshake</b> (SYN $\rightarrow$ SYN-ACK $\rightarrow$ ACK) and connection termination via a <b>4-Way Handshake</b> (FIN $\rightarrow$ ACK $\rightarrow$ FIN $\rightarrow$ ACK).
    *   <b>Reliability Mechanisms:</b> Guarantees data ordering and delivery confirmation using sequence numbers, acknowledgments (ACK), and automatic retransmission upon packet loss.
    *   <b>Application Foundation:</b> Serves as the underlying protocol for HTTP/1.1, HTTP/2, and database connection pools (such as HikariCP).
    *   <b>Performance Features:</b>
        *   `Keep-Alive`: Reuses established TCP connections for multiple requests, reducing the overhead of repeated handshakes.
        *   `Pipelining`: A feature in HTTP/1.1 that sends the next request without waiting for the response of the previous one (though it is limited by application-layer HoL blocking).
*   <b>UDP (User Datagram Protocol):</b>
    *   A connectionless, lightweight protocol that prioritizes speed and low overhead over reliability. Packet delivery and ordering are not guaranteed.
    *   Widely used in DNS queries, WebRTC, real-time media streaming, online gaming, etc.
*   <b>Concept of Ports:</b> Logical addresses (ranging from $0$ to $65535$) used to identify and route to specific processes running on a server (e.g., port $80$ for HTTP, port $443$ for HTTPS).

### Layer 3 (OSI) $\rightarrow$ Layer 2: Internet Layer (TCP/IP)

Determines the path (routing) from source to destination across multiple networks and transfers data in packets.



*   <b>IP (IPv4 / IPv6):</b> A logical addressing system to uniquely identify hosts on a network.
*   <b>Routers and Gateways:</b> Physical or virtual devices that relay and forward traffic between different network segments (such as routing between different VPC subnets in a cloud environment).
*   <b>Subnet Mask Design:</b> Logically divides a network into smaller subnets to optimize IP address allocation and define security boundaries.

### Layers 1–2 (OSI) $\rightarrow$ Layer 1: Network Access Layer (TCP/IP)

Manages the transmission of raw bitstreams over physical media (cables, fiber optics, wireless, etc.) and data transfer between nodes within the same local network.



*   <b>MAC Address:</b> A unique physical address assigned to a network interface card (NIC) at the hardware level.
*   <b>ARP (Address Resolution Protocol):</b> A protocol that dynamically resolves a physical MAC address corresponding to a known IP address, enabling communication within a local area network (LAN).
*   <b>Switches:</b> Local network devices that analyze the destination MAC address of received frames and forward data only to the port where the appropriate device is connected.

---

## Protocol Evolution: HTTP/1.1 vs. HTTP/2 vs. HTTP/3 (QUIC)

The evolution of the HTTP protocol has focused on reducing latency, improving connection utilization efficiency, and overcoming the limitations of underlying transport protocols.



| Feature / Item | HTTP/1.1 | HTTP/2 | HTTP/3 |
| :--- | :--- | :--- | :--- |
| <b>Underlying Protocol</b> | TCP | TCP | UDP (QUIC) |
| <b>Data Format</b> | Plain Text | Binary Frame | Binary Frame |
| <b>Multiplexing</b> | ❌ (Sequential / Pipelining) | ⭕ (Multiple streams over a single connection) | ⭕ (Stream-level advanced multiplexing) |
| <b>HOLB (Head-of-Line Blocking)</b> | <b>Application Layer:</b> Delay of a preceding request blocks subsequent ones. | <b>Transport Layer:</b> Loss of a single packet blocks all streams. | <b>Resolved:</b> Packet loss only affects the corresponding stream; others continue. |
| <b>Header Compression</b> | ❌ (Plain text, redundant transmission) | ⭕ <b>HPACK</b> (Static/dynamic tables and Huffman coding) | ⭕ <b>QPACK</b> (Optimized for UDP/QUIC, prevents blocking from out-of-order delivery) |
| <b>Connection Handshake</b> | <b>Slow:</b> TCP 3-Way ($1$ RTT) + TLS ($1$-$2$ RTT) | <b>Slow:</b> TCP + TLS (requires multiple round trips before data transfer) | <b>Fast:</b> Integrated transport and cryptographic handshake (<b>1-RTT / 0-RTT</b>) |

---

## DNS (Domain Name System) Resolution Flow and Record Design

DNS is a distributed database system that translates human-readable domain names into machine-readable IP addresses.



```text
[Client] ---> (1) Local DNS Cache / Resolver
                    |
                    +---> (2) Root DNS Server (.)
                    |
                    +---> (3) TLD DNS Server (.com)
                    |
                    +---> (4) Authoritative DNS Server (example.com)
```

### 1. DNS Query Resolution Process

When a user enters `https://example.com` in a browser, the system resolves the IP address through a hierarchical lookup process.



1.  <b>Check Local DNS Cache:</b> The client device first queries a local DNS server, such as one provided by an ISP (Internet Service Provider). If a valid record exists in the cache, the IP address is returned immediately.
2.  <b>Query Root DNS Servers (.):</b> If there is no cache on the local DNS server, it queries the global root DNS servers. The root server parses the top-level domain (e.g., `.com`) and returns information for the corresponding TLD servers.
3.  <b>Query TLD DNS Servers (.com):</b> The local DNS server queries the designated `.com` TLD server. The TLD server returns the address of the name server (authoritative DNS server) of the registrar where the target domain is registered.
4.  <b>Query Authoritative DNS Servers:</b> The local DNS server queries the authoritative DNS server where the developer manages the domain records to retrieve the final IP address or record value.
5.  <b>Caching and Connection:</b> The local DNS server returns the retrieved IP address to the client and caches the result for the configured TTL (Time To Live). The browser initiates a connection to the resolved IP address.

### 2. Three Key DNS Records for Backend Design

When configuring domains on a name server, the appropriate record type must be selected based on routing objectives.



*   <b>A Record (Address Record):</b>
    *   <b>Concept:</b> Directly maps a domain name to a specific IPv4 address.
    *   <b>Configuration Example:</b> `example.com` $\rightarrow$ `13.125.1.2` (a static public IP, such as an EC2 instance).
    *   <b>Characteristics:</b> If the server's public IP changes, the value on the name server must be updated manually.
*   <b>CNAME Record (Canonical Name Record):</b>
    *   <b>Concept:</b> Maps a domain name to another domain name (alias) instead of an IP address.
    *   <b>Configuration Example:</b> `api.example.com` $\rightarrow$ `my-load-balancer-123456.amazonaws.com` (an AWS ALB domain).
    *   <b>Characteristics:</b> Used to maintain name resolution consistency for infrastructure where IP addresses change dynamically, such as load balancers or CDNs (e.g., Cloudflare).
*   <b>MX Record (Mail Exchanger Record):</b>
    *   <b>Concept:</b> Specifies the mail servers responsible for receiving email messages on behalf of the domain.
    *   <b>Configuration Example:</b> Mail addressed to `example.com` $\rightarrow$ routed to Google Workspace mail servers (`aspmx.l.google.com`).
    *   <b>Characteristics:</b> By setting priorities, you can configure a redundant setup that automatically falls back to secondary servers if the primary server goes down.

### 3. DNS Operations and Management in Practice

*   <b>TTL (Time To Live) Control:</b> TTL is a parameter that specifies the duration in seconds for which a DNS record is cached. When performing maintenance involving server migration or IP address changes, <b>lowering the TTL to a short value such as 60 seconds (1 minute) in advance</b> minimizes downtime caused by propagation delays after the switchover.
*   <b>Subdomain Routing:</b> Subdomains are divided and managed according to infrastructure roles.
    *   `example.com` $\rightarrow$ Static web server (A or CNAME)
    *   `api.example.com` $\rightarrow$ Backend API gateway (CNAME)
    *   `dev-api.example.com` $\rightarrow$ Gateway for development environment
*   <b>Utilization of TXT Records:</b> Records used to associate arbitrary text data with a domain, primarily for the following purposes:
    *   <b>Domain Ownership Verification:</b> Proves ownership by registering a specified unique string when using external services like Google Workspace or AWS SES.
    *   <b>Email Sender Authentication:</b> Configures SPF (Sender Policy Framework) or DKIM (DomainKeys Identified Mail) to prevent email spoofing and spam classification.

---

## Division of Roles: Forward Proxy vs. Reverse Proxy

A proxy server is an intermediary server that relays communication between a client and a server. It is classified into a forward proxy or a reverse proxy depending on which side of the communication it is positioned.



```text
[Forward Proxy]
[Client 1] --+
[Client 2] --+--> [Forward Proxy] ---> [Internet] ---> [Target Server]

[Reverse Proxy]
[Client] ---> [Internet] ---> [Reverse Proxy (Nginx)] ---> [WAS 1]
                                                      ---> [WAS 2]
```

### 1. Comparison of Forward Proxy and Reverse Proxy

#### Forward Proxy
*   <b>Placement:</b> Positioned within the <b>client-side</b> network.
*   <b>Proxy Target:</b> Acts on behalf of the client. The destination server only sees the proxy's IP address, hiding the actual client's IP address.
*   <b>Primary Uses:</b>
    *   Restricting access to external sites from internal corporate networks (enforcing security policies).
    *   Ensuring client anonymity or bypassing specific geographical restrictions.
    *   Saving bandwidth by caching frequently accessed external resources.

#### Reverse Proxy

*   <b>Placement:</b> Positioned at the boundary of the server infrastructure (<b>in front of backend servers</b>).
*   <b>Proxy Target:</b> Acts on behalf of the servers. Clients perceive the reverse proxy as the final destination and remain unaware of the internal server configuration.
*   <b>Representative Software:</b> Nginx, Apache HTTP Server, AWS Application Load Balancer (ALB), Cloudflare.
*   <b>Primary Uses:</b> Backend server protection, load balancing, and consolidation of SSL/TLS termination.

### 2. Why Reverse Proxies Are Essential

Exposing application servers (such as Spring Boot, Express, or Django) directly to the public internet poses security risks. Placing a reverse proxy (e.g., Nginx) in front of them provides the following benefits:



1.  <b>Load Balancing:</b> Distributes traffic across multiple backend Web Application Servers (WAS). It performs periodic health checks and automatically cuts off routing to unhealthy instances.
2.  <b>Security and Server Obfuscation:</b> Hides internal network IP addresses and port configurations from the outside. It blocks unauthorized requests at the boundary and mitigates threats like DDoS attacks in coordination with Web Application Firewalls (WAF).
3.  <b>SSL/TLS Termination:</b> Consolidates CPU-intensive encryption and decryption processes at the reverse proxy. By communicating via lightweight HTTP between the reverse proxy and the backend WAS, WAS CPU resources can be focused on executing business logic.
4.  <b>Static Content Caching:</b> Serves static files like images, CSS, and JavaScript directly to clients from the reverse proxy's disk or memory, reducing unnecessary request forwarding to the WAS.

### 3. Client IP Tracking Mechanism

When passing through a reverse proxy, the source IP address obtained by the backend WAS becomes the <b>internal IP address of the reverse proxy</b>. To record access logs and enforce rate limiting, the original client IP must be propagated.


The reverse proxy appends the following headers before forwarding requests to the backend:



*   `X-Forwarded-For (XFF)`: A comma-separated list of IP addresses of the client and the proxies it passed through. The first value is the <b>original client IP</b>.
*   `X-Real-IP`: The IP address of the immediate client (or proxy) that connected directly to the reverse proxy.

#### Configuration Example in Nginx:

```nginx
server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://backend_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## L4/L7 Load Balancers and Traffic Distribution Algorithms

Load balancers are components that distribute traffic across multiple servers to ensure high availability and fault tolerance.



```text
[L4 Load Balancer]
[Client] ---> [L4 LB (IP/Port-based)] ---> [Server A (10.0.0.1:80)]
                                      ---> [Server B (10.0.0.2:80)]

[L7 Load Balancer]
[Client] ---> [L7 LB (URL/Header-based)] ---> /api/users  ---> [User Service]
                                         ---> /api/orders ---> [Order Service]
```

### 1. Technical Differences Between L4 and L7 Load Balancers

#### L4 Load Balancer (Transport Layer)
*   <b>Operating Layer:</b> OSI Layer 4 (Transport Layer).
*   <b>Routing Criteria:</b> Distributes traffic based solely on information in IP addresses, port numbers, and TCP/UDP protocol headers.
*   <b>Characteristics:</b>
    *   Extremely fast with low resource consumption because it does not parse application-layer payloads (HTTP bodies, cookies, headers, etc.).
    *   Cannot perform SSL/TLS decryption or routing based on URL paths.
*   <b>Uses:</b> Suitable for placement at the outermost perimeter of infrastructure to rapidly distribute massive traffic to downstream L7 load balancers.

#### L7 Load Balancer (Application Layer)

*   <b>Operating Layer:</b> OSI Layer 7 (Application Layer).
*   <b>Routing Criteria:</b> Decides routing by parsing HTTP URIs, cookies, HTTP headers, and payload content.
*   <b>Characteristics:</b>
    *   Enables <b>content-based routing</b> (e.g., routing to specific microservices based on URL paths).
    *   Supports SSL/TLS termination and session persistence (Sticky Sessions) using cookie values.
    *   Consumes more CPU and memory resources compared to L4 load balancers due to packet decryption and parsing.
*   <b>Uses:</b> AWS ALB, Nginx, HAProxy, etc. Used in microservice architectures (MSA) to route requests destined for `/api/users` to a user service and `/api/orders` to an order service.

### 2. Representative Traffic Distribution Algorithms

*   <b>Round Robin:</b>
    *   <b>Mechanism:</b> Assigns requests sequentially and evenly to available servers.
    *   <b>Suitable Environment:</b> Environments where all servers have identical specifications and request processing loads do not vary significantly.
*   <b>Weighted Round Robin:</b>
    *   <b>Mechanism:</b> Assigns a static "weight" to each server, proportionally allocating more requests to higher-spec servers.
    *   <b>Suitable Environment:</b> Environments with a mix of old and new servers with differing processing capacities.
*   <b>Least Connections:</b>
    *   <b>Mechanism:</b> Prioritizes assigning requests to the server with the fewest active connections.
    *   <b>Suitable Environment:</b> Environments with long-lived connections (such as WebSockets) or highly variable processing loads per request.
*   <b>IP Hash / Source Hash:</b>
    *   <b>Mechanism:</b> Hashes the client's IP address and consistently routes requests to a specific server based on the result.
    *   <b>Suitable Environment:</b> Legacy applications that store session information in local server memory, requiring requests from the same client to always be sent to the same server.

### 3. Importance of Health Checks

*   <b>L4 Health Check:</b> Attempts a TCP 3-way handshake on the target port to verify if it is open. A weakness is that even if the application process is frozen and returning errors (such as 500 Internal Server Error), it will still be determined as "healthy" as long as the port is open.
*   <b>L7 Health Check:</b> Sends an actual HTTP request (e.g., `GET /healthz`) and verifies if a successful response, such as status code `200 OK`, is returned. It is recommended to implement a health check endpoint on the backend that also evaluates the health of dependencies, such as database connections.

### 4. Container Lifecycle and Traffic Control

During container rolling updates or zero-downtime scaling, coordination between service discovery and load balancers is essential. When containers are replaced, "connection draining"—which blocks new traffic to old containers while maintaining existing connections to gracefully migrate traffic—is executed at the L7 load balancer or reverse proxy layer.



---

## Network Debugging and Troubleshooting Workflow

When inter-service communication errors or API connection failures occur, specific command-line tools are used to identify the root cause.



```bash
# Network connectivity and diagnostic commands
ping [IP/Domain]
nslookup [Domain]
traceroute [IP/Domain]
curl [URL]
```

### 1. ping — Network Layer (L3) Connectivity Verification

*   <b>Purpose:</b> Verifies if the target host is up and reachable over the network.
*   <b>Execution Example:</b>

```bash
ping -c 4 google.com
```

*   <b>Caveat:</b> Cloud environments (such as AWS Security Groups) and corporate firewalls often block the <b>ICMP protocol</b> (the protocol used by `ping`) for security reasons. Therefore, a failed `ping` does not necessarily mean the web service is down.

### 2. nslookup — DNS Record Verification

*   <b>Purpose:</b> Verifies if a domain name resolves to the correct IP address.
*   <b>Execution Example:</b>

```bash
nslookup google.com
```

### 3. traceroute — Routing Path Tracing

*   <b>Purpose:</b> Measures the path of routers traversed from the source to the destination server, along with the latency at each hop.
*   <b>Execution Example:</b>

```bash
traceroute google.com
```

*   <b>Result Analysis:</b> If consecutive timeouts (`* * *`) occur after a specific hop, it is highly likely that packets are being blocked by a router or firewall located at that boundary.

### 4. curl — Application Layer (L7) Connectivity Verification

*   <b>Purpose:</b> Sends an actual HTTP request to inspect response headers, body, and TLS handshake details from the server.
*   <b>Execution Example:</b>

```bash
curl -v https://example.com
```

---

## End-to-End Request Lifecycle

Traces the step-by-step flow of communication from when a user enters a URL in a browser to when the data is displayed on the screen.



```text
[Browser] --(1. DNS Query)--> [DNS Server]
    |
(2. TCP/QUIC Handshake &amp; HTTPS Request)
    v
[L7 Load Balancer (ALB)] --(3. SSL Termination &amp; Route)--> [Nginx (Reverse Proxy)]
                                                                   |
                                                           (4. Forward Request)
                                                                   v
[Database] <--(6. SQL Query / Connection Pool)-- [WAS (Spring Boot / Node.js)]
```

### Step 1: Name Server Resolution (DNS Query)

1.  <b>Address Input:</b> A user enters `https://example.com/v1/users` in the browser.
2.  <b>IP Address Lookup:</b> To identify the IP address corresponding to the domain, the browser checks the local DNS cache and, if necessary, queries authoritative DNS servers (such as AWS Route 53).
3.  <b>Record Return:</b> The authoritative DNS server resolves the CNAME record (the load balancer's domain) configured for `example.com` and returns the corresponding IP address to the browser.

### Step 2: Passing Through the Edge Gateway (L7 Load Balancer &amp; SSL)

1.  <b>Connection Establishment:</b> The browser performs a TCP 3-way handshake (or a UDP-based QUIC handshake in the case of HTTP/3) with the resolved IP address of the load balancer (ALB) to establish a connection.
2.  <b>SSL Termination:</b> The ALB completes the TLS handshake with the client, decrypts the encrypted HTTPS request, and converts it into a plain HTTP request.
3.  <b>Path-Based Routing:</b> The ALB analyzes the request URI path `/v1/users` and forwards the request to the Nginx reverse proxy server located in the private subnet according to predefined routing rules.

### Step 3: Relaying via Reverse Proxy

1.  <b>Proxy Processing:</b> Nginx receives the request and prepares to forward it to the backend Web Application Server (WAS).
2.  <b>Injecting Client IP:</b> Nginx injects the client's public IP address into the `X-Forwarded-For` and `X-Real-IP` headers so that the backend WAS can identify the actual client.
3.  <b>Forwarding to WAS:</b> Nginx forwards the request to the port where the WAS is listening, either locally or within the same network.

### Step 4: Business Logic Execution and Data Retrieval (WAS &amp; DB)

1.  <b>Request Parsing:</b> The WAS (such as Spring Boot or Node.js) parses the received HTTP request and maps headers and query parameters to objects that can be handled by the application code.
2.  <b>Connection Acquisition:</b> When database access is required to execute business logic, the WAS acquires an active TCP connection from a pre-established database connection pool (such as HikariCP).
3.  <b>Query Execution:</b> The WAS sends SQL queries (e.g., `SELECT * FROM users;`) to the database server (such as MySQL or PostgreSQL) via the acquired connection.
4.  <b>Data Return:</b> The database extracts the corresponding records from memory buffers or disk and returns the results to the WAS.

### Step 5: Returning the Response

1.  <b>Serialization:</b> The WAS serializes the data retrieved from the database into a JSON payload and constructs an HTTP response object containing status code `200 OK`.
2.  <b>Reverse Path Forwarding:</b> The response is returned along the reverse path of the request.
$$\text{WAS} \longrightarrow \text{Nginx} \longrightarrow \text{ALB (SSL Re-encryption)} \longrightarrow \text{Internet} \longrightarrow \text{Client Browser}$$
3.  <b>Rendering:</b> The browser parses the received JSON data, reflects it in the DOM, and renders the information on the user's screen. This completes the request-response cycle.

---

## Key Takeaways

*   <b>Understanding Layered Models:</b> Serves as a baseline for isolating whether a network issue lies in the physical/transport layers (unopened ports, packet drops) or the application layer (DNS misconfigurations, HTTP 5xx errors) when troubleshooting.
*   <b>Protocol Selection:</b> It is crucial to understand the characteristics of each protocol—such as HTTP/2 multiplexing or HTTP/3 QUIC handshake acceleration—and reflect them in system design.
*   <b>Header Propagation:</b> In infrastructure designs with multi-tiered reverse proxies or load balancers, headers like `X-Forwarded-For` must be properly controlled to maintain client identifiability.
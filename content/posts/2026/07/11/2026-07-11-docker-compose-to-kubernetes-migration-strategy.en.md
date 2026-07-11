---
title: "Architectural Design and Node.js Runtime Optimization in the Migration from Docker Compose to Kubernetes"
slug: "docker-compose-to-kubernetes-migration-strategy"
date: 2026-07-11T10:06:07+09:00
draft: false
image: ""
description: "Explains design guidelines for Node.js runtime selection, health check implementation, and graceful shutdown during the migration phase from Docker Compose to Kubernetes."
categories: ["DevOps Logistics"]
tags: ["kubernetes", "docker-compose", "node-js-lts", "health-check", "graceful-shutdown"]
author: "K-Life Hack"
---

# Migrating from Docker Compose to Kubernetes in Node.js Environments: Technical Design for Ensuring Scalability

In infrastructure scaling, migrating from single-node management with Docker Compose to orchestration with Kubernetes (K8s) represents a fundamental shift in the operational paradigm, not just a change in tools. Manual container management and static port allocation induce human error as the number of nodes increases, raising the risk of downtime. This article uses a Node.js environment as a model case to detail the technical requirements for a successful migration from development (Compose) to production (K8s) and design guidelines to avoid practical friction.



## Node.js Runtime Strategy and Version Management

The foundation of operational stability lies in runtime selection. Based on the roadmap as of July 2026, we recommend adopting Node.js v22.22.3 (Codename: Jod), an LTS (Long Term Support) version, for production environments. While the v26 series with the latest features exists, LTS remains the most solid choice considering verification costs and compatibility with third-party libraries. To ensure build reproducibility, avoid using the node:latest tag and use tags that explicitly specify the OS distribution.



```dockerfile
FROM node:22-bookworm-slim

# Recommended to run as a non-root user for security purposes
WORKDIR /app

# Resolve dependencies (prioritizing package-lock.json)
COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

# Run the application
USER node
CMD ["node", "server.js"]
```

## Health Check Implementation: Separating Readiness and Liveness

A container being "running" does not guarantee that the service is "healthy." When looking toward a Kubernetes migration, it is necessary to clearly separate process liveness monitoring (Liveness) from the determination of whether traffic can be accepted (Readiness).



### Implementation Example with Node.js

```javascript
'use strict';
const http = require('node:http');
const os = require('node:os');

const state = {
  isReady: false,
  isShuttingDown: false
};

// Simulate initialization process at startup (e.g., DB connection check)
setTimeout(() =&gt; {
  state.isReady = true;
  console.log('Application is ready to serve traffic');
}, 5000);

const server = http.createServer((req, res) =&gt; {
  // Liveness Probe: Check if the process is alive
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }

  // Readiness Probe: Check if it is okay to route traffic
  if (req.url === '/readyz') {
    if (state.isReady &amp;&amp; !state.isShuttingDown) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'ready' }));
    }
    res.writeHead(503, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'not ready' }));
  }

  res.writeHead(200);
  res.end(`Processed by ${os.hostname()}`);
});

server.listen(3000);
```

### Definition in Docker Compose

By utilizing the fetch API standard in Node.js 18 and later, health checks can be performed without installing curl inside the container. This helps in reducing image weight and improving security.



```yaml
services:
  api:
    build: .
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/healthz').then(r=&gt;process.exit(r.ok?0:1)).catch(()=&gt;process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
```

## Graceful Shutdown and Stateless Design

In Kubernetes environments, container destruction occurs frequently due to rolling updates and node rescheduling. Implementing a "graceful shutdown"—properly handling SIGTERM signals and completing in-flight requests before exiting—is essential.



```javascript
const shutdown = (signal) =&gt; {
  console.log(`${signal} received. Starting graceful shutdown...`);
  state.isShuttingDown = true;

  server.close(() =&gt; {
    console.log('Http server closed.');
    // Handle closing DB connections etc. here
    process.exit(0);
  });

  // Forced termination timer (align with K8s terminationGracePeriodSeconds)
  setTimeout(() =&gt; {
    console.error('Could not close connections in time, forcefully shutting down');
    process.exit(1);
  }, 25000);
};

process.on('SIGTERM', () =&gt; shutdown('SIGTERM'));
process.on('SIGINT', () =&gt; shutdown('SIGINT'));
```

## Troubleshooting: Typical Challenges Faced During Migration

In the migration process, the following three points are particularly frequent bottlenecks.


1. <b>DB Connection Pool Exhaustion</b>: Connection counts that were not an issue in Docker Compose (single node) may exceed the DB's maximum connections (max_connections) the moment Pods are horizontally scaled in Kubernetes. It is necessary to limit the pool size per Pod and introduce a proxy like PgBouncer if needed.


2. <b>Zombie Process Occurrence</b>: If the shell form (CMD node server.js) is used in the Dockerfile's ENTRYPOINT, the shell may trap the SIGTERM, preventing the signal from reaching the Node.js process. Always use the JSON array format (CMD ["node", "server.js"]).


3. <b>Non-deterministic Builds</b>: Running npm install during a build can cause library versions to diverge between environments due to range specifications in package.json. Always use npm ci to perform a strict build based on package-lock.json.



## Verification of Operational Consistency

After deployment, verify whether the container processes signals as expected and responds to health checks using the following commands.



```text
# Check container status and health check results
$ docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
NAMES               STATUS                     PORTS
app-v22-jod         Up 5 minutes (healthy)     0.0.0.0:3000-&gt;3000/tcp

# Verify request to the health check endpoint
$ curl -i http://localhost:3000/readyz
HTTP/1.1 200 OK
Content-Type: application/json
Date: Sat, 11 Jul 2026 10:00:00 GMT
Connection: keep-alive
Keep-Alive: timeout=5
Transfer-Encoding: chunked

{"status":"ready"}

# Verify structured log output (JSON format)
$ docker logs app-v22-jod | head -n 5
{"level":"info","message":"Server listening on port 3000","timestamp":"2026-07-11T10:00:05Z"}
{"level":"info","message":"Application is ready to serve traffic","timestamp":"2026-07-11T10:00:10Z"}
```

## Operational Notes

Docker Compose is a "training ground" for defining reproducible operational units. By thoroughly implementing health checks, standardizing logs to stdout, and signal handling here, the cost of migrating to Kubernetes is significantly reduced. Technology selection should not be a matter of mere preference, but a business decision that balances recovery costs during failures with delivery speed.


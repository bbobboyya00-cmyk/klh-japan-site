---
title: "Building a Real-Time Observability Pipeline and Step-by-Step Load Testing of a Local Backend Using k6 and Prometheus Remote Write"
slug: "k6-prometheus-observability-pipeline"
date: 2026-06-04T14:05:30+09:00
draft: false
image: ""
description: "Conducting step-by-step load testing on a local backend utilizing k6's Prometheus Remote Write protocol. Explains the setup procedure and verification results of a real-time observability pipeline using Grafana."
categories: ["DevOps Logistics"]
tags: ["k6", "prometheus-remote-write", "grafana", "docker-compose", "load-testing"]
author: "K-Life Hack"
---

# Building and Verifying a Real-Time Observability Load Testing Pipeline with k6, Prometheus, and Grafana

This article explains the procedure for building a real-time observability pipeline combining k6, Prometheus, and Grafana, and conducting step-by-step load testing to verify the performance of a backend server in a local development environment.


In this verification, to completely eliminate any impact on the production environment, all containers and target servers are run fully enclosed within the local environment. We built a system that collects metrics output from k6 in real time via the Prometheus Remote Write protocol and visualizes them on Grafana.



## 1. Objectives of the Load Test

The main objectives of the load test in this phase are as follows:



1. <b>Applying Step-by-Step GET Request Load</b>: Send structured HTTP GET traffic to the target local backend server.

2. <b>Step-by-Step Scaling of Virtual Users (VUs)</b>: Increase and decrease the number of virtual users step-by-step (10 → 30 → 50 → 20 → 0) based on programmatic control.

3. <b>Verifying Prometheus Remote Write</b>: Confirm that metrics are pushed to the Prometheus time-series database without delay using k6's experimental feature, the `experimental-prometheus-rw` protocol.

4. <b>Ensuring Real-Time Observability</b>: Monitor key performance indicators (KPIs) such as RPS (Requests Per Second), active VUs, HTTP status codes, requests per endpoint, and 5xx error rates in real time using Grafana.

5. <b>Evaluating Server Stability</b>: Verify that no backend server crashes, resource leaks, or 5xx errors occur during peak load.

## 2. Verification Environment Configuration

To prevent unnecessary traffic flow to the production environment or service disruption, all verifications were conducted strictly within a local Docker network.



### Target Server

* <b>WGS Local Backend</b>: `http://localhost:5000`

### Monitoring and Observability Infrastructure (Docker Containers)

* <b>Grafana</b>: `http://localhost:3001`
* <b>Prometheus</b>: `http://localhost:9090`

### Component Configuration

💡 <b>k6</b>: A load generation engine that generates HTTP requests from concurrent virtual users (VUs) to the target based on a scenario script.

💡 <b>Prometheus</b>: A data store that accumulates time-series performance metrics pushed from k6.

💡 <b>Grafana</b>: A visualization platform that queries Prometheus as a data source and renders graphs in real time.

💡 <b>Docker Compose</b>: A tool that orchestrates Prometheus, Grafana, and k6 within the same isolated local network.

## 3. Preparation: Initializing the Container Environment

To prevent past test metrics from mixing into the Grafana visualization, the Prometheus and Grafana containers are completely destroyed and reinitialized before starting the test.


Run the container initialization commands in a terminal environment such as PowerShell.



```bash
```

This allows measurement to start from a clean state with past test data cleared.



## 4. Verifying Backend Server Operation

Before starting the load test, verify that the target local backend server is in a state where it can respond normally.



```bash
```

### Expected Response Headers

```http
```

If `200 OK` is returned as shown above, it can be determined that the backend has started normally and is ready to accept the load test.



## 5. Designing the k6 Load Testing Scenario

Define the implementation structure of the load testing scenario script, `06_final_recording_public_get.js`.



```javascript
```

### Key Implementation Points

🛠️ <b>http.expectedStatuses({ min: 200, max: 499 })</b>: Client errors such as `401 Unauthorized` or `404 Not Found` are evidence that the application logic is running normally, so they are excluded from being counted as "failures" by the test framework. On the other hand, `5xx` errors indicate server-side crashes or overload, so they are strictly detected as failures.

🛠️ <b>stages</b>: The total measurement time is 2 minutes and 30 seconds (150 seconds). By gradually increasing and decreasing the load, the configuration makes it easy to simulate container auto-scaling and resource limits.

🛠️ <b>tags: { endpoint: item.name }</b>: By adding metadata to each HTTP request, it becomes possible to drill down and analyze on the Grafana side whether there is a bottleneck at a specific endpoint.

## 6. Grafana Observability Dashboard and PromQL Design

To visualize the metrics accumulated in Prometheus, configure PromQL queries in Grafana's Explore interface and dashboards.



### A. RPS (Requests Per Second)

```promql
```

Calculates the average HTTP requests per second within the most recent 10-second sliding window.



### B. Active Virtual Users (VUs)

```promql
```

Tracks the current concurrent virtual users being generated by k6 in real time.



### C. Requests by HTTP Status Code

```promql
```

Groups and cumulatively displays requests that occurred in the last 2 minutes by status code (200, 401, 404, etc.).



### D. Requests by Endpoint

```promql
```

Visualizes which APIs traffic is concentrated on, based on the `endpoint` tag applied within the script.



### E. 5xx Server Error Detection

```promql
```

Monitors the occurrence of internal server errors (HTTP 500 to 599) to immediately detect system instability.


⚠️ <b>Troubleshooting Note</b>: During initial verification, an issue occurred where the Grafana graphs did not update in real time. The cause was that Grafana's Auto-Refresh Interval was left at its default. By explicitly setting this to `5s`, the 1-second interval metrics sent from k6 via Prometheus Remote Write are now rendered on the screen without delay.



## 7. Running the Load Test

Call Docker Compose from PowerShell to start the k6 container and run the load test.



```bash
```

### Command Option Explanations

🛠️ <b>--profile test</b>: Enables the k6 service belonging to the `test` profile in the Compose file.

🛠️ <b>run --rm</b>: Automatically deletes temporary containers that are no longer needed after the test completes, freeing up host resources.

🛠️ <b>-e K6_PROMETHEUS_RW_PUSH_INTERVAL=1s</b>: Shortens the default push interval to 1 second, maximizing the real-time graph responsiveness on Grafana.

🛠️ <b>-o experimental-prometheus-rw</b>: Specifies the Prometheus Remote Write protocol as the metrics output destination.

## 8. Analysis of Test Results

These are the measurement results from the final summary report output by k6 after the load test completed.



| Metrics Item | Measured Value |
| :--- | :--- |
| <b>Total HTTP Requests</b> | 32,200 |
| <b>Completed Iterations</b> | 3,220 |
| <b>Peak Virtual Users (VUs)</b> | 50 |
| <b>Interrupted Iterations</b> | 0 |
| <b>HTTP Failure Rate (Error Rate)</b> | 0.00% |
| <b>Assertion Pass Rate (Checks)</b> | 100.00% |
| <b>Average Response Time (Average Latency)</b> | 2.73 ms |
| <b>95th Percentile (p95) Response Time</b> | 5.88 ms |
| <b>99th Percentile (p99) Response Time</b> | 15.26 ms |
| <b>Maximum Response Time (Max Latency)</b> | 57.09 ms |
| <b>Average Throughput</b> | ~213.75 reqs/sec |

### Performance Evaluation

🛠️ <b>Extremely Low Latency</b>: 95% of requests were processed within 5.88 ms, showing extremely good response performance that is significantly below the target value of 2000 ms (2.0 seconds).

🛠️ <b>Achieving Error-Free Execution</b>: Out of 32,200 total requests, there were 0 (0.00%) 5xx errors or connection errors, achieving a 100.00% assertion pass rate. Even in a single-process configuration in a local environment, it was demonstrated that the backend stably handled sockets against 50 concurrent VUs.

## 9. Visualization Analysis of Observability Data

The following behaviors were confirmed from the real-time monitoring on the Grafana dashboard:



1. <b>Correlation between RPS and VUs</b>: Completely proportional to the step-by-step increase and decrease of virtual users (VUs) (10 → 30 → 50 → 20 → 0), the RPS graph drew a clean step-like parabola. This indicates that the k6 load generation engine and the data transfer pipeline to Prometheus functioned without any bottlenecks.

2. <b>Distribution of HTTP Status Codes</b>: As expected, only `200 OK` for endpoints not requiring authentication and `401 Unauthorized` for protected endpoints were recorded, and no unexpected errors such as `404` or `500` occurred at all.

3. <b>Even Distribution of Endpoints</b>: The number of requests to the 10 endpoints remained completely even, confirming that requests were distributed in a round-robin fashion as designed in the scenario, without biasing toward APIs processing specific heavy queries.

## Lessons Learned

The insights and future improvement points obtained through this verification are as follows:



💡 <b>Importance of Refresh Intervals in Real-Time Visualization</b>: When using Prometheus Remote Write, if both the push interval on the k6 side (`K6_PROMETHEUS_RW_PUSH_INTERVAL`) and the dashboard auto-refresh interval on the Grafana side are not synchronized, it can cause data to appear discontinuous or rendering to be delayed.

💡 <b>Consideration for Container-to-Container Name Resolution</b>: When accessing the local port of the host machine from k6 running within a Docker bridge network, an environment variable design that properly resolves `host.docker.internal` instead of `localhost` is essential.

💡 <b>Lack of Host Resource Monitoring</b>: In the current configuration, while the application response performance from the perspective of k6 (external monitoring) is captured, the CPU usage and memory consumption of the container itself where the backend process runs (internal monitoring) are not integrated. In the future, it is recommended to extend the configuration by incorporating a library such as `prom-client` into the Node.js backend to pull internal resource metrics into Prometheus via a `/metrics` endpoint.
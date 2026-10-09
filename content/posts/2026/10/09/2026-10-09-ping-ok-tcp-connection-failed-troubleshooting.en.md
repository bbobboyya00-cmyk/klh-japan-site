---
title: "Troubleshooting the Boundary Area Where Ping Succeeds but TCP Connection Fails"
slug: "ping-ok-tcp-connection-failed-troubleshooting"
date: 2026-10-09T10:46:33+09:00
draft: false
image: ""
description: "A technical analysis note on systematically diagnosing and resolving L3/L4/L7 boundary gaps where Ping succeeds but service connection fails, using ss, nc, tcpdump, and curl."
categories: ["Linux System Admin"]
tags: ["ss", "nc", "tcpdump", "connection-refused", "connection-timeout"]
author: "K-Life Hack"
---

In infrastructure operations, the issue where "Ping succeeds, but connections to the server (such as SSH or HTTP) fail" frequently occurs. Relying solely on ICMP for L3-level reachability verification while neglecting the verification of L4 transport layer or L7 application layer leads to delayed incident recovery and incorrect root cause identification.


The ICMP echo test indicates a successful state with low latency and 0% packet loss.



```bash
$ ping 192.168.10.100
PING 192.168.10.100 (192.168.10.100) 56(84) bytes of data.
64 bytes from 192.168.10.100: icmp_seq=1 ttl=64 time=0.3 ms
64 bytes from 192.168.10.100: icmp_seq=2 ttl=64 time=0.2 ms
```

However, initiating an SSH session or HTTP request results in a connection failure.



```bash
$ ssh 192.168.10.100
ssh: connect to host 192.168.10.100 port 22: Connection refused
```

Alternatively, a timeout occurs during the connection attempt.



```bash
$ curl http://192.168.10.100:8080
curl: (7) Failed to connect to 192.168.10.100 port 8080: Connection timed out
```

The assumption that "since Ping succeeded, the network is normal, and connection failure means the server itself is broken" is technically incorrect. This is because ICMP operates at the network layer (L3), whereas key application protocols such as SSH, HTTP, HTTPS, PostgreSQL, MySQL, and Redis rely on transport layer (L4) TCP sockets bound to specific port numbers.


This article systematically breaks down this boundary gap and establishes diagnostic methodologies centered on three core Linux utilities: `ss`, `nc`, and `tcpdump`.



## 1. Network Layer Abstraction and Service Mapping

💡 To effectively identify communication bottlenecks, target services are mapped to each layer of the OSI reference model and transport mechanisms.



* <b>ICMP</b>: Used exclusively for diagnostic and control messaging such as `ping` (no transport port exists).
* <b>SSH</b>: TCP port `22`
* <b>HTTP</b>: TCP port `80`
* <b>HTTPS</b>: TCP port `443`
* <b>PostgreSQL</b>: TCP port `5432`
* <b>MySQL / MariaDB</b>: TCP port `3306`
* <b>Redis</b>: TCP port `6379`

Because ICMP operates independently of L4 TCP listening sockets, receiving a response to an ICMP Echo Request provides no guarantee that a TCP port is open or reachable.



## 2. Low-Layer Mechanics of `ping`

Executing `ping 192.168.10.100` sends an <b>ICMP Echo Request</b> packet (Type 8) to the destination host, which returns an <b>ICMP Echo Reply</b> packet (Type 0).



```text
+------------------------+                             +------------------------+
| Client: 192.168.10.50  |                             | Server: 192.168.10.100 |
+------------------------+                             +------------------------+
            |                                                      |
            |------------ ICMP Echo Request (Type 8) -------------&gt;|
            |                                                      |
            |&lt;----------- ICMP Echo Reply (Type 0) ----------------|
            |                                                      |
```

A successful Ping merely confirms that the path from the client through local routing, gateways, the physical network, and the target IP stack back to the ICMP reply is functional. It cannot verify whether firewall rules allow TCP frames or whether an application daemon on the host is actively processing sockets.



## 3. Structure of the TCP 3-Way Handshake

When initiating a TCP-based service connection, the operating system kernel must first establish a stateful connection via the <b>TCP 3-Way Handshake</b>.



```text
Client (192.168.10.50)                                   Server (192.168.10.100:22)
      |                                                              |
      |----------------------- 1. SYN ------------------------------&gt;|
      |                                                              |
      |&lt;------------------- 2. SYN-ACK ------------------------------|
      |                                                              |
      |----------------------- 3. ACK ------------------------------&gt;|
      |                                                              |
[ ESTABLISHED ]                                                [ ESTABLISHED ]
```

1. <b>SYN</b>: The client sends a TCP frame with the `SYN` flag set to request connection initiation.
2. <b>SYN-ACK</b>: Upon receiving the `SYN`, the server checks the socket listening on port `22`, allocates a connection state buffer, and responds with `SYN-ACK`.
3. <b>ACK</b>: The client responds with `ACK`, and both endpoints transition to the `ESTABLISHED` state.

For application protocols to function, this L4 sequence must complete successfully.



## 4. Diagnosing "Ping Succeeds + TCP Connection Fails"

Define the initial diagnostic state.



```bash
$ ping 192.168.10.100
# Success (0% packet loss)

$ nc -zv 192.168.10.100 22
# Failure
```

This discrepancy allows immediate narrowing down of the failure domain. Functional ICMP indicates that L3 routing and physical links are operational, while TCP failure indicates an issue with L4 sockets, firewalls, or service daemons.



## 5. Transport Layer Probing with `nc` (Netcat)

Netcat (`nc`) functions as a TCP and UDP connection analyzer. Its primary use case in production environments is verifying raw TCP reachability to a specific socket address.


To run Netcat, specify options for port scanning.



```bash
$ nc -zv 192.168.10.100 22
```

-z`: Zero-I/O mode (scans for listening daemons without sending payload data).
* `-v`: Verbose output mode.

Determine network status from connection test execution results.



1. <b>Handshake Success</b>:

   ```text
   Connection to 192.168.10.100 22 port [tcp/ssh] succeeded!
   ```

2. <b>Failure Pattern A</b>:

   ```text
   nc: connect to 192.168.10.100 port 22 failed: Connection refused
   ```

3. <b>Failure Pattern B</b>:

   ```text
   nc: connect to 192.168.10.100 port 22 failed: Connection timed out
   ```

Understanding the distinction between <b>Connection Refused</b> and <b>Connection Timed Out</b> is critical in identifying root causes.



## 6. Mechanisms of Connection Refused and Connection Timeout

### Mechanics of Connection Refused

⚠️ A `Connection refused` error indicates that the client's `SYN` packet reached the destination host's kernel, but the host explicitly rejected the connection and returned a TCP <b>Reset (`RST`)</b> frame.



```text
Client                                                       Server
  |                                                             |
  |--------------------------- SYN ----------------------------&gt;| (Destination host reached)
  |                                                             | (No listening process)
  |&lt;------------------------ TCP RST ---------------------------|
```

#### Primary Causes:

1. <b>Service Daemon Stopped</b>: The process (`sshd`, `nginx`, `mysqld`, etc.) is not running.
2. <b>Incorrect Service Port</b>: The application is listening on a non-default port (e.g., `2222` instead of `22`).
3. <b>Bound Interface Mismatch</b>: The daemon is bound strictly to `127.0.0.1` rather than `0.0.0.0`.
4. <b>Active Packet Filtering</b>: The localhost firewall is configured to explicitly return TCP Reset packets (REJECT) rather than dropping them (DROP).

### Mechanics of Connection Timeout

A `Connection timed out` error occurs when the client sends a `SYN` packet, but <b>no response whatsoever is returned</b> before the socket timeout threshold expires.



```text
Client                                                   Network / Firewall / Target
  |                                                             |
  |--------------------------- SYN ----------------------------&gt;|
  |                                                             | ===&gt; [ Drop / Block ]
  |                     (No Response)                              |
  | ... Timeout ...                                        |
```

#### Primary Causes:

1. <b>Network Security Drop</b>: Cloud security groups, network ACLs, or hardware firewalls are silently dropping inbound traffic.
2. <b>Host-Level Firewall Drop</b>: `iptables`, `firewalld`, or `nftables` are configured with a `DROP` action.
3. <b>Routing Failure</b>: Incorrect default routing or missing static routes at intermediate network switches or routers.
4. <b>Asymmetric Routing / Return Path Failure</b>: The server receives the `SYN` and sends a `SYN-ACK`, but the packet is dropped or misrouted on the return path.

## 7. Inspecting Local Sockets with `ss`

The `ss` (Socket Statistics) utility inspects active internal sockets on Linux platforms and serves as a modern replacement for the legacy `netstat` tool.


Run the diagnostic command to check socket state.



```bash
$ sudo ss -lntp
```

#### Flag Specifications:

* `-l`: Displays only listening (`LISTEN`) sockets.
* `-n`: Displays numeric addresses and ports (prevents overhead from DNS and service name resolution).
* `-t`: Displays TCP sockets.
* `-p`: Displays process IDs and names associated with sockets (requires `root` or `sudo` privileges).

Executing the command outputs socket information.



```text
State      Recv-Q Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN     0      128           0.0.0.0:22         0.0.0.0:*      users:(("sshd",pid=1234,fd=3))
LISTEN     0      128           0.0.0.0:80         0.0.0.0:*      users:(("nginx",pid=1500,fd=6))
LISTEN     0      128         127.0.0.1:8080       0.0.0.0:*      users:(("java",pid=2000,fd=20))
```

## 8. Analyzing Bind Addresses: `127.0.0.1` vs `0.0.0.0`

The `Local Address:Port` bind configuration dictates external reachability.

### Loopback Isolation Case (`127.0.0.1:8080`)

Indicates a state where the socket is bound exclusively to the loopback address.



```text
LISTEN  0  128  127.0.0.1:8080  0.0.0.0:*
```

The application process (`java`) is bound exclusively to the <b>loopback interface (`lo`)</b>.



```text
[ External Client ]                                [ Target Server ]
  192.168.10.50                                      192.168.10.100
        |                                                  |
        |--- HTTP request to 192.168.10.100:8080 ---------&gt;| [ Physical Interface ]
                                                           |       |
                                                           |   (Blocked / No socket)
                                                           |       v
                                                           | [ Loopback Interface ]
                                                           |   127.0.0.1:8080 (Java Daemon)
```

<b>Local Verification</b>: Executing `curl http://127.0.0.1:8080` on the server succeeds.
* <b>Remote Verification</b>: Executing `curl http://192.168.10.100:8080` from an external client fails.

### Wildcard IPv4 Bind (`0.0.0.0:8080`)

Indicates a state where the socket is bound across all interfaces.



```text
LISTEN  0  128  0.0.0.0:8080  0.0.0.0:*
```

The socket accepts inbound TCP traffic through <b>all active IPv4 network interfaces</b> assigned to the host (e.g., `ens160` with IP `192.168.10.100`). If permitted by firewalls, connections from external clients are possible.



```text
+-------------------------------------------------------------+
| Server: 192.168.10.100                                      |
|                                                             |
| Interface ens160 [ 192.168.10.100 ] &lt;--- [ External Request ] |
|          |                                                  |
|          v                                                  |
| Service bound to 0.0.0.0:8080 (Listening on all interfaces) |
+-------------------------------------------------------------+
```

## 9. Real-World Troubleshooting Cases

### Case 1: Ping Succeeds, but SSH Fails (`Connection Refused`)

#### Environment Configuration:

* <b>Client</b>: `192.168.10.50`
* <b>Server</b>: `192.168.10.100`
* <b>Target Service</b>: SSH (TCP port `22`)

#### Step 1: Client-Side Diagnostics

```bash
$ ping 192.168.10.100
# Result: 64 bytes from 192.168.10.100: icmp_seq=1 ttl=64 time=0.3 ms (Success)

$ nc -zv 192.168.10.100 22
# Result: nc: connect to 192.168.10.100 port 22 failed: Connection refused
```

#### Step 2: Server-Side Socket Inspection

Log in to the server's local console or out-of-band (OOB) management interface.



```bash
$ sudo ss -lntp
# Output result:
# LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1500,fd=6))
```

*TCP port 22 is absent from the listener table.*



#### Step 3: Verifying Service State and Resolution

```bash
$ sudo systemctl status sshd
# Output: Active: inactive (dead)

$ sudo systemctl start sshd
$ sudo systemctl enable sshd

$ sudo ss -lntp | grep ':22'
# Output: LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=3102,fd=3))
```

Re-executing `nc -zv 192.168.10.100 22` on the client side results in a successful connection.



---

### Case 2: Process Running, but External Access Fails (`Bind Mismatch`)

#### Diagnostic State:

Executing `ss -lntp` on the application server yields the socket state.



```text
LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("node",pid=4211,fd=18))
```

#### Reachability Testing:

* <b>From Target Server</b>: `curl http://127.0.0.1:8080` $\longrightarrow$ <b>200 OK</b>
* <b>From Remote Client</b>: `curl http://192.168.10.100:8080` $\longrightarrow$ <b>Connection Refused</b>

#### Diagnostics and Solution:

The application (Node.js, Spring Boot, Nginx, etc.) configuration is restricted to `localhost`. Modify the host configuration (e.g., `server.host = 0.0.0.0` or `LISTEN 0.0.0.0:8080`) and restart the service to expose the socket to external interfaces.



---

### Case 3: Service Bound, but External Connection Times Out

#### Diagnostic State:

The server's socket table is properly exposed.



```bash
$ sudo ss -lntp | grep ':8080'
LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("java",pid=8820,fd=7))
```

However, client-side execution fails.



```bash
$ nc -zv 192.168.10.100 8080
nc: connect to 192.168.10.100 port 8080 failed: Connection timed out
```

#### Firewall Inspection:

Because the output is `Timeout` rather than `Refused`, an inline network device or host firewall rule is silently dropping packets.


Inspect localhost rules.



```bash
$ sudo firewall-cmd --list-all
# Check if '8080/tcp' exists in the services and ports section

$ sudo nft list ruleset
```

If ICMP is globally permitted in `firewalld` but port 8080 is excluded, `ping` passes through while L4 TCP traffic to port 8080 is dropped.



```text
Client (192.168.10.50)                                   Server (192.168.10.100)
      |                                                             |
      |----------------------- TCP SYN ----------------------------&gt;|
      |                                                             |
      |                                              [ Host Firewall (nftables) ]
      |                                              [ Action: DROP Port 8080   ]
      |                                                             |
      | &lt;=== Timeout (SYN-ACK is not sent) =========================|
```

## 10. Deep Packet Diagnostics with `tcpdump`

`nc` reports connection results, and `ss` indicates socket listening state. However, `tcpdump` captures actual packet movement and reveals state transitions at the frame level.


Run packet capture on the target server.



```bash
$ sudo tcpdump -nn -i ens160 tcp port 8080
```

-n`: Do not resolve hostnames.
* `-nn`: Do not resolve hostnames or port names (displays numeric IPs and ports).
* `-i ens160`: Monitors traffic on target network interface `ens160`.
* `tcp port 8080`: Filters strictly TCP packets passing through port 8080.

## 11. Packet Pattern Analysis with `tcpdump`

### Scenario A: Normal TCP 3-Way Handshake

```text
10:00:01.001 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S], seq 1001
10:00:01.002 IP 192.168.10.100.8080 &gt; 192.168.10.50.52344: Flags [S.], seq 2001, ack 1002
10:00:01.003 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [.], seq 1002, ack 2002
```

Flags [S]`: Initial SYN frame from client.
* `Flags [S.]`: SYN-ACK response from server.
* `Flags [.]`: ACK frame from client.
* <b>Diagnosis</b>: L4 handshake completed and connection established (`ESTABLISHED`).

### Scenario B: Sustained Unanswered Inbound SYN

```text
10:00:01.001 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S], seq 1001
10:00:04.005 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S], seq 1001
10:00:10.009 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S], seq 1001
```

<b>Observation</b>: The client is retransmitting TCP `SYN`. The server's interface receives the packet, but no outbound `SYN-ACK` (`[S.]`) is sent.
* <b>Diagnosis</b>: A host-level security mechanism (`iptables`, `nftables`, `SELinux`, or kernel-level IP filtering) drops the packet immediately upon ingress at the network interface layer.

### Scenario C: Server Sends SYN-ACK, but Client Retransmits SYN

```text
10:00:01.001 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S]
10:00:01.002 IP 192.168.10.100.8080 &gt; 192.168.10.50.52344: Flags [S.]
10:00:04.005 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S]
```

<b>Observation</b>: The server processes inbound `SYN` and transmits `SYN-ACK`, but the client continuously sends `SYN` frames as if no response was received.
* <b>Diagnosis</b>: A <b>return path routing failure</b> between server and client, or egress firewall filtering toward the source direction, is occurring.

```text
Client (192.168.10.50)                                   Server (192.168.10.100)
      |                                                             |
      |----------------------- 1. SYN -----------------------------&gt;|
      |                                                             |
      | X &lt;=== [ Return routing failure / Egress block ] ---------| (Sending SYN-ACK)
```

Primary causes:
1. Misconfigured local default gateway on the target server.
2. Return path drops due to asymmetric routing policies.
3. Loss of NAT table state.

### Scenario D: Immediate Reset (`RST` Immediately Following `SYN`)

```text
10:00:01.001 IP 192.168.10.50.52344 &gt; 192.168.10.100.8080: Flags [S]
10:00:01.001 IP 192.168.10.100.8080 &gt; 192.168.10.50.52344: Flags [R.]
```

<b>Observation</b>: The server immediately returns a reset frame (`[R.]`).
* <b>Diagnosis</b>: The packet passed through the host firewall, but the kernel found no process listening on TCP port 8080. Verify daemon status with `ss -lntp`.

## 12. Tracking Socket State via Kernel Counters

Run `ss -ant` to review connection state allocation across active sockets.



```bash
$ sudo ss -ant
State      Recv-Q Send-Q  Local Address:Port  Peer Address:Port
LISTEN     0      128     0.0.0.0:8080        0.0.0.0:*
ESTAB      0      0       192.168.10.100:8080 192.168.10.50:52344
SYN-RECV   0      0       192.168.10.100:8080 192.168.10.50:52345
```

### Critical Socket States and Anomalies:

1. <b>Accumulation of `SYN-SENT` (Client Side)</b>:

   ```bash
   $ ss -ant state syn-sent
   ```

Meaning*: The client application transmitted a `SYN` frame but has not received a `SYN-ACK`. Indicates outbound blocking or drop along the path.

2. <b>Accumulation of `SYN-RECV` (Server Side)</b>:

   ```bash
   $ ss -ant state syn-recv
   ```

Meaning*: The server received `SYN` and transmitted `SYN-ACK`, but remains stalled waiting for the final `ACK` from the client. Indicates inbound blocking on the client side, asymmetric routing, or a SYN flood attack.

## 13. Upper-Layer Diagnostics: Ping and TCP Succeed, but Application Fails

Define a further elevated failure state.



```bash
$ ping 192.168.10.100
# Success (L3 OK)

$ nc -zv 192.168.10.100 8080
# Success (L4 TCP connection OK)

$ curl http://192.168.10.100:8080/
# Failure / Error / HTTP 5xx / No response
```

This scenario proves that the network layer (L3) and transport layer (L4) are fully operational.



### Application Layer Debugging with `curl`

Execute verbose HTTP operations to capture handshake and protocol semantics.



```bash
$ curl -v http://192.168.10.100:8080/
```

Example of a verbose execution trace:



```text
*   Trying 192.168.10.100:8080...
* Connected to 192.168.10.100 (192.168.10.100) port 8080 (#0)
&gt; GET / HTTP/1.1
&gt; Host: 192.168.10.100:8080
&gt; User-Agent: curl/7.76.1
&gt; Accept: */*
&gt;
&lt; HTTP/1.1 504 Gateway Timeout
&lt; Server: nginx/1.20.1
&lt; Date: Mon, 10 Nov 2025 10:00:00 GMT
&lt; Content-Type: text/html
```

#### Primary Cause Categories for L7 Failures:

1. <b>Reverse Proxy Upstream Timeout</b>: Nginx accepts connections on port 8080, but fails to reach the backend running locally (e.g., Node/Java app on `127.0.0.1:8000`), returning HTTP `504 Gateway Timeout` or `502 Bad Gateway`.
2. <b>HTTP Host Header Rejection</b>: Application virtual host filters drop requests lacking a valid `Host:` request header.
3. <b>Application Thread Lock</b>: Database connection pool exhaustion or internal deadlocks prevent the application layer from transmitting payload frames despite an established L4 socket handshake.
4. <b>TLS/SSL Handshake Failure</b>: Cipher suite mismatches, expired certificates, or SNI misconfigurations cause connection termination immediately following TCP initialization on port 443.

## 14. Caveats in UDP Protocol Diagnostics

Unlike TCP, <b>UDP is connectionless</b>. There are no setup flags (`SYN`, `ACK`) or state machine checks.


Testing UDP reachability using `nc` requires the `-u` flag.



```bash
$ nc -zvu 192.168.10.100 53
```

### Diagnostic Challenges:

* UDP scanners transmit 0-byte packets. If no `ICMP Port Unreachable` frame returns, `nc` determines the port to be "open" or "open|filtered".
* Due to a high rate of false positives, reliable UDP testing requires protocol-specific query tools (e.g., `dig` for DNS UDP 53, `snmpwalk` for SNMP UDP 161) alongside active packet capture.

```bash
$ sudo tcpdump -nn -i ens160 udp port 53
```

## 15. Tool Matrix for Systems Engineers

Integrate these diagnostic tools into a unified operational workflow.



| Utility | Target Layer | Core Functionality | Primary Diagnostic Value |
| :--- | :--- | :--- | :--- |
| <b>`ping`</b> | L3 (Network) | Raw ICMP reachability and link latency evaluation | Verification of basic IP routing and physical connectivity |
| <b>`nc`</b> | L4 (Transport) | End-to-end TCP/UDP socket availability testing | Differentiation between `Connection Refused` and `Timeout` |
| <b>`ss`</b> | Host Kernel Socket | Local interface bind and socket state inspection | Confirmation that daemon processes are properly started and bound |
| <b>`tcpdump`</b> | Wire Protocol | Monitoring TCP frames on raw network interfaces | Failure location identification via sequence flag (`SYN`, `SYN-ACK`, `RST`) analysis |
| <b>`curl`</b> | L7 (Application) | HTTP/S application protocol transaction validation | Identification of web server errors, proxy misconfigurations, and backend timeouts |

## 16. Systematic Troubleshooting Flow

🛠️ When encountering an event where "Ping succeeds, but service access fails", proceed with diagnostics according to the following logical flow.



```text
[ Event Occurred: Ping is successful, but service access fails ]
                                                |
                                                v
                                 Execute: nc -zv <server_ip> <port>
                                                |
            +-----------------------------------+-----------------------------------+
            |                                   |                                   |
            v                                   v                                   v
   [ Connection Refused ]              [ Connection Timed Out ]                 [ Succeeded ]
            |                                   |                                   |
            v                                   v                                   v
 Log in to target server               Run packet capture on server:        L3/L4 layers are normal.
 Execute: ss -lntp                     tcpdump -nn -i <nic> port <port>     Verify L7 application layer.
            |                                   |                         Execute: curl -v http://<ip>:<port>
            +---------------+                   +---------------+                           |
            |               |                   |               |                           v
            v               v                   v               v                 Check app/proxy logs:
   [ Port not listed ] [ Bound to 127.0.0.1 ] [ SYN not reached ] [ SYN reached, no SYN-ACK ] - Systemd status
            |               |                   |               |                 - Nginx / App exceptions
            v               v                   v               v                 - DB connection pool
   Start daemon:       Fix app config      Check network path:   Check host firewall:
   systemctl start     0.0.0.0:<port>      - Network FW          - firewall-cmd
   <service>           Restart app         - Security Group      - nftables rules
                                           - Router settings     - Kernel IP filtering
```

## 17. Operational CLI Quick Reference

### L3 Diagnostic Commands:

```bash
# Send 4 ICMP packets to test link reachability
$ ping -c 4 192.168.10.100
```

### L4 Socket Probing Commands (`nc`):

```bash
# Investigate standard management and web service TCP ports
$ nc -zv 192.168.10.100 22
$ nc -zv 192.168.10.100 80
$ nc -zv 192.168.10.100 443
$ nc -zv 192.168.10.100 8080

# Investigate UDP domain name resolution service
$ nc -zvu 192.168.10.100 53
```

### Local Socket Inspection Commands (`ss`):

```bash
# List all active listening TCP ports including process details
$ sudo ss -lntp

# Filter for a specific target socket listener
$ sudo ss -lntp | grep ':8080'

# Display all numeric TCP connections regardless of state
$ sudo ss -ant

# Isolate connections in SYN-SENT or SYN-RECV state
$ sudo ss -ant state syn-sent
$ sudo ss -ant state syn-recv
```

### Packet Analysis Commands (`tcpdump`):

```bash
# Monitor TCP port 8080 on a specific interface
$ sudo tcpdump -nn -i ens160 tcp port 8080

# Capture raw SYN connection initialization requests globally
$ sudo tcpdump -nn -i ens160 'tcp[tcpflags] &amp; tcp-syn != 0'

# Capture all traffic associated with a specific host IP address
$ sudo tcpdump -nn -i ens160 host 192.168.10.50

# Multiplex tracking of ICMP control packets and target TCP application traffic
$ sudo tcpdump -nn -i ens160 'tcp port 8080 or icmp'
```

### Host Firewall Operations (`firewalld` / `nftables`):

```bash
# Inspect current firewalld configuration
$ sudo firewall-cmd --list-all

# Permanently add permission for TCP 8080
$ sudo firewall-cmd --add-port=8080/tcp --permanent
$ sudo firewall-cmd --reload

# Inspect low-level nftables ruleset bindings
$ sudo nft list ruleset
```

## Lessons Learned

1. <b>Ping Success Does Not Guarantee Service Health</b>: ICMP Echo replies prove only Layer 3 interface reachability and routing functionality. Layer 4 port states and Layer 7 application functionality are not verified.
2. <b>Accurate Error Message Interpretation</b>: 
* `Connection refused` indicates that the packet reached the host, but there is no active listener, or it was explicitly rejected with a `RST`. Check <b>host socket bindings</b> (`ss -lntp`).
* `Connection timed out` indicates that frames were lost on the forward or return path. Check <b>firewalls, security groups, and routing loops</b>.
3. <b>Packet Path Tracing via Wire Capture</b>: Use `tcpdump` to answer the fundamental question: "How far into the infrastructure stack did the initial SYN frame reach?"
4. <b>Step-by-Step Layer Isolation</b>: Sequentially test from L3 (`ping`) to L4 (`nc`), inspect local listening states (`ss`), verify raw frames on the wire (`tcpdump`), and finally validate at L7 (`curl`).</service></port></port></ip></port></nic></port></server_ip>
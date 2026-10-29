---
title: "Practical Network Troubleshooting and Packet Flow Diagnostics in Linux Environments"
slug: "linux-network-diagnostics-packet-analysis"
date: 2026-10-29T10:51:10+09:00
draft: false
image: ""
description: "Explains techniques for hierarchically isolating network issues in Linux production environments along the OSI reference model. Covers everything from verifying IP/routing to packet analysis with tcpdump and TCP flag validation."
categories: ["Linux System Admin"]
tags: ["tcpdump", "iproute2", "ss", "netcat", "nftables"]
author: "K-Life Hack"
---

When inter-host communication is interrupted or intermittent timeouts occur in production infrastructure, haphazard service restarts or unplanned routing changes can expand the scope of the failure and result in the loss of volatile forensic evidence. Particularly in systems involving multi-NIC configurations or overlay networks, failure causes are complexly intertwined across physical links, OS kernel routing tables, host-based packet filtering, and the transport layer (TCP/UDP). This article outlines procedures for isolating network failures and packet tracing methods in Linux environments based on a deterministic and reproducible verification methodology.



## 💡 Hierarchical Approach to Localizing the Failure Domain

When detecting network anomalies, it is necessary to logically narrow down the investigation scope through bottom-up verification from lower layers (L1/L2) to upper layers (L7), or middle-out verification depending on the symptoms.



```text
+---------------------------------------------------------------------------------------------------+
|                                 Standard Diagnostic Progression Flow                              |
+---------------------------------------------------------------------------------------------------+
|  1. Physical Link &amp; NIC State                                                                     |
|       v                                                                                           |
|  2. Layer 3: IP Address &amp; CIDR Subnet Alignment                                                   |
|       v                                                                                           |
|  3. Layer 2/3: ARP Resolution &amp; Next-Hop Gateway Reachability                                     |
|       v                                                                                           |
|  4. Routing Table &amp; Egress Interface Selection                                                    |
|       v                                                                                           |
|  5. Layer 4: TCP/UDP Port Listeners &amp; Connection State Tracking                                    |
|       v                                                                                           |
|  6. Packet Filtering: Local, Host-Level, and Perimetric Firewalls                                 |
|       v                                                                                           |
|  7. Name Resolution: DNS Recursion &amp; Query Path                                                   |
|       v                                                                                           |
|  8. Layer 7: TLS Negotiation, HTTP Semantics &amp; Application Upstreams                              |
|       v                                                                                           |
|  9. Deep Packet Inspection: tcpdump Capture &amp; Flow Trajectory Analysis                            |
+---------------------------------------------------------------------------------------------------+
```

### 1. Verification of Interface Status and Layer 3 Address Configurations

When a communication failure occurs, first verify the physical carrier status of the Network Interface Controller (NIC) and the assigned IP/subnet mask.



```bash
ip -br link
ip link show ens160
ethtool ens160
```

If the status is <code>DOWN</code> in <code>ip -br link</code> or if <code>Link detected: no</code> appears in the <code>ethtool</code> output, an issue exists in the hypervisor virtual switch port group, VLAN tag, or physical layer cabling.



```bash
ip -br addr
```

Special attention must be paid to misconfigurations of the subnet mask (CIDR prefix). If a setting that should be <code>/24</code> is accidentally defined as <code>/16</code>, traffic destined for non-adjacent segments is treated as directly connected (Link Scope). Consequently, ARP requests are broadcast locally without passing through the default gateway, causing packets to fail to reach their destination and be dropped.



### 2. Verification of Kernel Routing Table and ARP Resolution

To identify which interface a packet is egressed through from the source node, query the kernel's forwarding decision directly.



```bash
ip route
ip route get 192.168.20.50
```

From the execution results, accurately determine the selected next-hop gateway (<code>via</code>), egress interface (<code>dev</code>), and source IP address (<code>src</code>). In multi-homed configurations equipped with multiple NICs, asymmetric routing may cause return packets to take a different path and be dropped by an intermediate stateful firewall.


Next, verify whether the Layer 2 address of the next hop is resolved.



```bash
ip neigh show
```

If the status is <code>INCOMPLETE</code> or <code>FAILED</code>, no response to the ARP request has been received. VLAN misconfiguration on the switch side, physical communication disruption, or IP address conflicts should be suspected.



### 3. Layer 4 Socket Listener and Protocol Isolation

Even if ICMP reachability via <code>ping</code> succeeds, it does not guarantee that TCP/UDP application communication will be established. This is because ICMP (Echo Request/Reply) lacks the concept of transport layer ports.


To confirm port reachability from a client, execute <code>nc</code> (netcat) with a specified timeout.



```bash
nc -zv -w 3 192.168.20.50 443
```

On the server side, verify whether the socket is listening on the intended interface and port.



```bash
sudo ss -lntp
```

If the bind address is restricted to loopback, such as <code>127.0.0.1:8080</code>, all incoming traffic from external nodes will be rejected by the kernel (TCP RST). Daemons requiring external access must be bound to <code>0.0.0.0</code> or the specific address of a physical NIC.



### 4. Verification of Packet Filtering (nftables / firewalld)

If communication fails even when the socket is properly in a listening state, inspect the host-level packet filter.



```bash
sudo firewall-cmd --state
sudo firewall-cmd --list-all
sudo nft list ruleset
```

When inspecting filter configurations, thoroughly check interface zones, source IP restrictions, and protocol port allow rules based on infrastructure design, rather than merely verifying daemon running status.



## 🛠️ Packet Capture and Flow Analysis Using tcpdump

When static checks using various commands cannot identify the cause, use <code>tcpdump</code> to capture frames passing through the network interface directly.



```bash
sudo tcpdump -nn -i ens160 'host 192.168.20.50 and tcp port 443'
```

-nn`: Disables host name resolution and port service name resolution to prevent name resolution delays.
* `-i ens160`: Specifies the capture target interface.
* `'host ... and tcp port ...'`: Filters traffic using BPF (Berkeley Packet Filter).

When outputting PCAP files for detailed analysis, specify a packet count limit and manage appropriate permissions.



```bash
sudo tcpdump -nn -i ens160 -s 0 -c 1000 -w /tmp/network-debug.pcap 'host 192.168.20.50 and tcp port 443'
sudo chmod 600 /tmp/network-debug.pcap
```

### Identifying Failure Causes via TCP Handshake Signatures

```text
Client (192.168.10.10)                       Server (192.168.20.50)
        |                                              |
        |-------------- [SYN] Seq=0 ------------------&gt;|  Step 1: Connection Request
        |                                              |
        |&lt;--------- [SYN, ACK] Seq=0 Ack=1 ------------|  Step 2: Acknowledgment &amp; Sync
        |                                              |
        |-------------- [ACK] Seq=1 Ack=1 ------------&gt;|  Step 3: Handshake Established
        |                                              |
        |========= Established / Data Transfer ========|
```

The location of a bottleneck can be identified through TCP flag transitions in the capture log.



#### Pattern 1: SYN Retransmission and Silent Drop (No Response)

```text
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, win 64240, length 0
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, win 64240, length 0
```

If <code>Flags [S]</code> is transmitted from the client but no response is received, drops by intermediate network firewalls (cloud Security Groups, NACLs, etc.), routing blackholes, or lost return packets due to asymmetric routing should be suspected.



#### Pattern 2: Immediate TCP RST (Connection Refused)

```text
192.168.10.10.52000 &gt; 192.168.20.50.443: Flags [S], seq 1001, length 0
192.168.20.50.443 &gt; 192.168.10.10.52000: Flags [R.], seq 0, ack 1002, length 0
```

If <code>Flags [R.]</code> is returned immediately from the target host, it indicates that the packet reached the destination host, but no process is listening on the relevant port, the OS connection backlog queue is exhausted, or the packet filter returned an explicit <code>REJECT</code> (<code>--reject-with tcp-reset</code>).



#### Pattern 3: Stalling After Handshake Completion

If data communication stalls after <code>Flags [S]</code>, <code>Flags [S.]</code>, and <code>Flags [.]</code> are successfully established, there is no issue with Layer 4 reachability; the cause lies in a TLS handshake mismatch (SNI configuration or certificate revocation) or a communication failure between a Layer 7 proxy (such as Nginx) and the backend.



## ⚠️ Troubleshooting

The handling procedures for common scenarios encountered in actual troubleshooting sites are shown below.



### 1. HTTP 502 Bad Gateway Occurrence and Upstream Connection Diagnostics

This occurs when traffic reaches the reverse proxy from the client, but the connection from the proxy to the backend (such as a FastAPI or Go application) is severed.



```bash
# Check the backend listener from the proxy server
nc -zv -w 3 127.0.0.1 8000
sudo ss -lntp | grep ':8000'

# Inspect backend process status and logs
sudo journalctl -u backend-service --since "10 minutes ago"
sudo tail -n 50 /var/log/nginx/error.log
```

If <code>connect() failed (111: Connection refused)</code> is recorded in the Nginx error log, either the backend process is down or a bind address mismatch (discrepancy between IPv6 <code>[::1]</code> and IPv4 <code>127.0.0.1</code>) has occurred. In the case of <code>upstream timed out (110: Connection timed out)</code>, the cause is backend processing deadlock or database-induced latency.



### 2. Hardware Offload Artifacts During Capture

When <code>TSO</code> (TCP Segmentation Offload) or <code>TX Checksum Offload</code> is enabled on the NIC, checksum errors or giant packets exceeding MTU (1500 bytes) may be observed in <code>tcpdump</code>. This is an apparent artifact resulting from capturing packets immediately after the kernel offloads frame processing to the NIC, and does not indicate packet corruption. To verify the accurate state of actual frames, packet capture must be performed on the receiving host or via a network tap.



## Log Data

Representative terminal output examples obtained during diagnostics at each layer are shown below.



```text
$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <loopback,up,lower_up> 
ens160           UP             00:50:56:bb:01:1a <broadcast,multicast,up,lower_up> 
ens192           DOWN           00:50:56:bb:02:2b <broadcast,multicast> 

$ ip route get 192.168.20.50
192.168.20.50 via 192.168.10.1 dev ens160 src 192.168.10.10 uid 1000
    cache 

$ ip neigh show
192.168.10.1 dev ens160 lladdr 00:11:22:33:44:55 REACHABLE

$ sudo ss -lntp
State      Recv-Q Send-Q Local Address:Port  Peer Address:PortProcess
LISTEN     0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=1024,fd=3))
LISTEN     0      128        127.0.0.1:8080       0.0.0.0:*    users:(("java",pid=2450,fd=45))
LISTEN     0      511          0.0.0.0:443        0.0.0.0:*    users:(("nginx",pid=1820,fd=6))

$ nc -zv -w 3 192.168.20.50 443
Ncat: Version 7.92 ( https://nmap.org/ncat )
Ncat: Connected to 192.168.20.50:443.
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
```

## 🛠️ Operational Notes

When performing network analysis on hosts running in production environments, the following constraints must be adhered to:



1. <b>Strict BPF Filtering</b>: Executing unconditional `tcpdump` in high-traffic environments can cause high CPU utilization and log space exhaustion. Always specify IP and port, and limit the captured packet count using the `-c` option.
2. <b>Preservation of Volatile Information</b>: Before modifying network settings or rebooting, record the output of `ip route`, `ip neigh`, and `ss` to preserve state information at the time of the failure.
3. <b>Rigorous Layer Separation</b>: Rather than determining path viability solely by Ping success or failure, individually isolating L3 (routing), L4 (port/socket), and L7 (application protocol) is the fastest route to incident recovery.</broadcast,multicast></broadcast,multicast,up,lower_up></loopback,up,lower_up>
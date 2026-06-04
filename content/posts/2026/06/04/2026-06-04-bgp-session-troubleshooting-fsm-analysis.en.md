---
title: "Root Cause Identification and Recovery Protocol Based on Finite State Machine During BGP Session Disconnection"
slug: "bgp-session-troubleshooting-fsm-analysis"
date: 2026-06-04T14:24:45+09:00
draft: false
image: ""
description: "This article explains diagnostic commands based on Finite State Machine (FSM) transition states, identification flows for the 7 major root causes, and proactive design using BFD for rapid recovery during BGP session disconnections."
categories: ["Linux System Admin"]
tags: ["bgp", "cisco-ios", "bfd", "tcp-179", "routing-protocol"]
author: "K-Life Hack"
---

# Troubleshooting and Proactive Network Design for BGP Session Disconnections

In high-availability networks, a BGP (Border Gateway Protocol) session disconnection is an event that has an immediate and critical impact, such as loss of Internet connectivity, disconnection of site-to-site VPNs, or interruption of cloud interconnections. To minimize the Mean Time to Repair (MTTR), rapid diagnosis based on the protocol's operating principles is essential.



## 1. BGP Finite State Machine (FSM) Transition States and Key Diagnostic Points

When starting BGP session troubleshooting, it is extremely important to identify which phase of the BGP Finite State Machine (FSM) the target session is stuck in.


BGP state transitions progress in the following order: Idle → Connect → Active → OpenSent → OpenConfirm → Established.



* <b>Idle</b>: The state where the BGP process is initializing or waiting for the retry timer to start. If stuck in this state, the route to the target neighbor itself may not exist on the router.
* <b>Connect</b>: The state where the router is waiting for the completion of the TCP 3-way handshake.
* <b>Active</b>: The state where the TCP connection establishment has failed and the router is repeatedly retrying. This suggests a potential issue with L3 reachability or that TCP port 179 is blocked by a firewall, etc.
* <b>OpenSent</b>: The state where the TCP connection has been established and an OPEN message has been sent. The router is waiting for an OPEN message from the peer. A mismatch in AS number or BGP Identifier (Router ID) is suspected.
* <b>OpenConfirm</b>: The state where the OPEN message has been received and the router is waiting for a KEEPALIVE message. If an MD5 authentication mismatch or timer mismatch occurs, the session may get stuck in this state.
* <b>Established</b>: The state where the session is fully established and operating normally.

---

## 2. Execution Procedures for Initial Diagnostic Commands

When a failure occurs, execute the command sequence to isolate the failure domain.



### Step 1: Verify Overall BGP Status

```router-os
show ip bgp summary
```

Verify the "State/PfxRcd" field in the output. If this value is <b>Active</b> or <b>Idle</b>, the session is down. If a numeric value is displayed, it indicates that the session is established and that many prefixes have been received.



### Step 2: Verify Detailed Neighbor Information

```router-os
show ip bgp neighbors 192.168.1.1
```

* <b>BGP state</b>: Verifies the current FSM state.
* <b>Last reset</b>: Displays the most recent reason why the session was disconnected (e.g., "Peer closed the session" or "Hold time expired").
* <b>Notification error message</b>: Displays the sent or received BGP error codes.

### Step 3: Verify L1/L2 Interface Status

```router-os
show interfaces GigabitEthernet0/1
```

If the status is <b>Up/Up</b>, the physical layer and data link layer are normal. If it is <b>Up/Down</b>, L2 issues such as encapsulation mismatch or keepalive failure are suspected, and if it is <b>Administratively Down</b>, it has been manually shut down.



### Step 4: Verify L3 Reachability

```router-os
ping 192.168.1.1 source Loopback0
```

Perform a connectivity test by specifying the source interface. If packet loss is 100%, an L3 route does not exist; if there is partial loss, hold timer expiration due to degraded link quality is suspected.



---

## 3. Seven Major Causes and Countermeasures for BGP Session Disconnections

<b>Cause 1: TCP Connection Failure</b>


Symptom: The state is stuck in <b>Active</b>, and the peer's Router ID is displayed as <b>0.0.0.0</b>.


Countermeasure: Verify whether TCP port 179 is allowed in the Access Control List (ACL). Also, while BGP keepalives are small, update messages can be large, so verify whether there are packet drops due to MTU mismatch along the path.


<b>Cause 2: AS Number Mismatch</b>


Symptom: The state loops between <b>Active</b> and <b>Idle</b>, and an <b>OPEN message error</b> is recorded in the log.


Countermeasure: Verify whether the <b>neighbor [IP] remote-as [AS]</b> value configured on the local router matches the actual AS number of the peer router.


<b>Cause 3: Hold Timer Expiration</b>


Symptom: The session flaps intermittently, and <b>hold time expired</b> is output to the log.


Countermeasure: Check for KEEPALIVE transmission delays caused by high CPU load on the peer router, or link congestion. If rapid failure detection in milliseconds is required, consider implementing BFD (Bidirectional Forwarding Detection).


<b>Cause 4: MD5 Authentication Mismatch</b>


Symptom: The state is stuck in <b>Active</b>, and while ping succeeds, <b>MD5 digest error</b> or <b>%TCP-6-BADAUTH</b> is output to the log.


Countermeasure: Double-check the configured password for case sensitivity, special characters, and trailing spaces.


<b>Cause 5: Update Source Mismatch</b>


Symptom: When establishing a peer relationship between loopback interfaces, pinging the loopback IP succeeds, but the BGP state remains stuck in <b>Active</b>.


Countermeasure: Verify whether the update source is explicitly specified in the peer configuration.



```router-os
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 update-source Loopback0
```

<b>Cause 6: Maximum Received Prefix Limit Exceeded</b>


Symptom: The session is suddenly disconnected, and <b>Maximum prefix limit reached</b> is recorded in the log.


Countermeasure: Verify the number of received prefixes and, if necessary, increase the limit or strengthen inbound filtering.



```router-os
router bgp 65001
 neighbor 192.168.1.2 maximum-prefix 10000 80
```

<b>Cause 7: Router Resource Exhaustion</b>


Symptom: Multiple BGP sessions disconnect simultaneously, and CLI responsiveness becomes extremely slow.


Countermeasure: Check resource consumption using <b>show processes cpu sorted</b> and <b>show processes memory sorted</b>, and optimize by avoiding the receipt of unnecessary full routes, switching to receiving only default routes, etc.



---

## 4. Session Re-establishment and Verification

After applying configuration changes, clear the session to trigger renegotiation.



* <b>Soft Reset (Recommended: No impact on traffic)</b>:
```router-os
clear ip bgp 192.168.1.2 soft in
```
* <b>Hard Reset (Caution: Traffic is temporarily interrupted)</b>:
```router-os
clear ip bgp 192.168.1.2
```

After clearing, execute <b>show ip bgp summary</b> and verify that the state has transitioned to <b>Established</b> (where the number of received prefixes is displayed as a numeric value).



---

## 5. Proactive Network Design

To maintain session stability over the long term, it is recommended to implement the configuration as a template.



```router-os
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 update-source Loopback0
 neighbor 192.168.1.2 password StrongMD5Key
 neighbor 192.168.1.2 maximum-prefix 10000 80 warning-only
 neighbor 192.168.1.2 fall-over bfd
 timers bgp 10 30
```

---

## Operational Notes

* <b>Caution When Running Debugs</b>: In a production environment, executing commands like <b>debug ip bgp</b> without filters while receiving full routes carries a risk of CPU utilization reaching 100% and crashing the router. When debugging, always specify the target neighbor IP, and promptly execute <b>undebug all</b> once verification is complete.
* <b>Starting Point for Isolation</b>: Approximately 80% of BGP session failures are caused by TCP connectivity, AS number configuration, or hold timer expiration. By using "ping specifying the source interface" as the starting point for isolation to see if it succeeds, you can quickly determine whether the issue lies on the infrastructure side or the protocol configuration side.
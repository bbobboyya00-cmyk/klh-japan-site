---
title: "Packet Filtering Control with Network ACLs and Security Groups"
slug: "acl-packet-filtering-mechanics-cisco-aws"
date: 2026-09-03T10:17:21+09:00
draft: false
image: ""
description: "A summary of implementation and verification procedures for stateless and stateful controls in Cisco IOS and AWS environments, covering network ACL evaluation order, implicit deny, and wildcard mask bitwise operations."
categories: ["Linux System Admin"]
tags: ["cisco-ios", "access-list", "ip-access-group", "aws-nacl", "packet-filtering"]
author: "K-Life Hack"
---

In network perimeter traffic control, blocking unnecessary communication and protocols at the appropriate layer forms the foundation for protecting internal bandwidth and resources. Packet filtering using Access Control Lists (ACLs) is widely utilized across routers, Layer-3 switches, and virtual networks in public clouds.


This article outlines the ACL packet evaluation mechanism, standard and extended ACL implementations in Cisco IOS, an architectural comparison between stateless NACLs and stateful Security Groups in AWS, and operational troubleshooting methodologies.



## ACL Processing Pipeline and Evaluation Logic

ACLs filter packets based on source IP, destination IP, protocol type (such as IP, TCP, UDP, ICMP), and source/destination port numbers. The evaluation process operates according to the following three principles:



* <b>Top-Down Processing:</b> Rules are evaluated sequentially starting from the top entry of the list (or the lowest sequence number).
* <b>First Match Termination:</b> Once a packet matches a rule's criteria, the configured action (`permit` or `deny`) is executed immediately, and subsequent rule evaluations terminate at that point.
* <b>Implicit Deny Any:</b> An unwritten deny rule (`deny ip any any`) exists at the very end of the list. Any packet that does not match any entry is automatically dropped.

```text
[ Inbound Packet ]
       │
       ▼
┌─────────────────────────────────┐
│   Rule 1: Evaluate Condition    │──(Match)──► [ Execute Action: Permit / Deny ] ──► (End Evaluation)
└─────────────────────────────────┘
       │ (No Match)
       ▼
┌─────────────────────────────────┐
│   Rule 2: Evaluate Condition    │──(Match)──► [ Execute Action: Permit / Deny ] ──► (End Evaluation)
└─────────────────────────────────┘
       │ (No Match)
       ▼
       :
       │ (No Match)
       ▼
┌─────────────────────────────────┐
│   Implicit Deny Any (End)       │───────────► [ Packet Dropped (Drop) ]
└─────────────────────────────────┘
```

## Network Layer ACL Classification and Placement Principles

ACLs in Cisco network architecture are broadly classified into Standard ACLs and Extended ACLs.



| Attribute / Type | Standard ACL | Extended ACL |
| :--- | :--- | :--- |
| <b>Evaluation Target</b> | Source IP address only | Source/Destination IP address, protocol, port number |
| <b>Control Granularity</b> | Coarse filtering on a per-source basis | Fine-grained control per protocol and port |
| <b>Number Ranges</b> | `1–99`, `1300–1999` | `100–199`, `2000–2699` |
| <b>Recommended Placement</b> | <b>Place close to destination:</b> Because filtering evaluates only the source, placing it near the source risks blocking legitimate traffic destined for other targets. | <b>Place close to source:</b> Because both source and destination are evaluated, dropping unnecessary traffic close to the source prevents wasting transit link bandwidth. |

### Bitwise Evaluation of Wildcard Masks

ACLs use wildcard masks, which are the inverted form of subnet masks. In binary representation, `0` requires an exact match for that bit, while `1` is treated as a "don't care" (any value).


For example, specifying the wildcard mask `0.0.0.255` for subnet `192.168.1.0` means the upper 24 bits (`192.168.1`) are strictly compared while the lower 8 bits are ignored, thereby matching the entire address space from `192.168.1.0` to `192.168.1.255`.



## Filtering in Cloud Environments: AWS NACLs vs. Security Groups

In an AWS VPC environment, packet filtering is executed across two layers: the subnet boundary and the virtual machine boundary (ENI).



```text
Internet / VPC Traffic
         │
         ▼
┌────────────────────────────────────────┐
│  1st Line of Defense: Network ACL (NACL) │ ◄── Subnet Boundary (Stateless)
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  2nd Line of Defense: Security Group (SG)│ ◄── ENI / Host Boundary (Stateful)
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  Target Instance: Amazon EC2           │
└────────────────────────────────────────┘
```

| Comparison Item | Network ACL (NACL) | Security Group (SG) |
| :--- | :--- | :--- |
| <b>Scope of Application</b> | Subnet boundary | ENI (Elastic Network Interface) / Per-resource basis |
| <b>State Tracking</b> | <b>Stateless:</b> Inbound and outbound are evaluated independently. Return traffic rules must be explicitly defined. | <b>Stateful:</b> Tracks connections. Return packets for allowed inbound traffic are automatically permitted. |
| <b>Rule Evaluation Engine</b> | Top-down evaluation in numerical order (First Match). | Aggregated evaluation across all rules. <b>Allow rules only</b> can be defined (explicit deny is not supported). |
| <b>Role</b> | Coarse-grained traffic boundary control at the subnet level. | Fine-grained access control at the instance level. |

In a stateless NACL, even if an HTTP request from a client to a web server (inbound destination port 80) is permitted, communication will drop if the server's response back to the client (outbound destination ephemeral ports) is not explicitly permitted in the outbound rules.



## ACL Implementation Procedures in Cisco IOS

### Standard ACL Configuration and Interface Application

Example configuration of a standard ACL that permits traffic only from source subnet `192.168.10.0/24`.



```cisco
Router# configure terminal
Router(config)# access-list 10 permit 192.168.10.0 0.0.0.255
Router(config)# access-list 10 deny any
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# ip access-group 10 in
Router(config-if)# exit
```

The `in` parameter on an interface specifies that evaluation is performed before the router makes a routing decision upon receiving the packet. The `out` parameter specifies evaluation immediately prior to transmission from the interface after routing is complete.



### Web Traffic Control via Extended ACL

Configuration permitting only HTTP (TCP/80) traffic originating from `192.168.10.0/24` destined for web server `10.0.0.10`.



```cisco
Router(config)# access-list 100 permit tcp 192.168.10.0 0.0.0.255 host 10.0.0.10 eq 80
Router(config)# access-list 100 deny ip any any
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# ip access-group 100 in
Router(config-if)# exit
```

### Administrative Access Control (VTY Lines)

When restricting access to the router's management plane (SSH/Telnet), use the `access-class` command on virtual terminal lines rather than `ip access-group` on interfaces.



```cisco
Router(config)# line vty 0 4
Router(config-line)# access-class 10 in
Router(config-line)# exit
```

## Troubleshooting

### 1. Unintended Traffic Allowed Due to Rule Shadowing

Placing a broad permit rule above a more specific rule causes subsequent deny rules to be ignored.



* <b>Incorrect Configuration Example:</b>

  ```text
  access-list 10 permit any
  access-list 10 deny host 192.168.1.100
  ```

Traffic from `192.168.1.100` matches the first line `permit any`, and the deny rule on the second line is never evaluated.



* <b>Remediation Procedure:</b>
Place more specific conditions (specific hosts or subnets) higher in the list.



  ```text
  access-list 10 deny host 192.168.1.100
  access-list 10 permit any
  ```

### 2. Legitimate Traffic Blocked by Implicit Deny

Writing only a `deny` rule to block a single host results in all other traffic being dropped by the implicit deny at the end.



```cisco
! Incorrect: All other traffic is implicitly dropped
Router(config)# access-list 10 deny host 192.168.1.100

! Fix: Explicitly permit non-blocked traffic
Router(config)# access-list 10 permit any
```

### Verification and Status Inspection Commands

Check ACL binding status and match counters (hit counts) for each rule.



```text
Router# show access-lists
Standard IP access list 10
    10 deny   192.168.1.100 (15 matches)
    20 permit any (1420 matches)
Extended IP access list 100
    10 permit tcp 192.168.10.0 0.0.0.255 host 10.0.0.10 eq www (8340 matches)
    20 deny ip any any (120 matches)

Router# show ip interface gigabitEthernet 0/0
GigabitEthernet0/0 is up, line protocol is up
  Internet address is 192.168.10.1/24
  Broadcast address is 255.255.255.255
  Address determined by setup command
  MTU is 1500 bytes
  Helper address is not set
  Directed broadcast forwarding is disabled
  Inbound  access list is 100
  Outbound access list is not set
```

To unbind an ACL from an interface, execute `no ip access-group` in interface configuration mode.



```cisco
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# no ip access-group 100 in
```

## Operational Notes

When designing and operating ACLs, strictly adhere to the following principles:



* <b>Rule Ordering:</b> Place specific entries evaluating exact IPs/ports at the top, and broad, generalized entries at the bottom.
* <b>State Awareness:</b> In stateless environments like cloud NACLs, outbound rules must explicitly permit the ephemeral port range (e.g., TCP 1024–65535) for return traffic.
* <b>Placement and Direction:</b> Accurately define the interface perspective (`in` / `out`) as packets traverse the router; position standard ACLs close to the destination and extended ACLs close to the source.
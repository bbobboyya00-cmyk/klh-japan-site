---
title: "Design and Implementation of VPC Endpoints in AWS Systems Manager: Structural Differences Between Interface and Gateway Types"
slug: "aws-ssm-vpc-endpoint-architecture-analysis"
date: 2026-05-27T10:40:20+09:00
draft: false
image: ""
description: "A VPC endpoint design guide for operating AWS Systems Manager (SSM) in private subnets. Detailed explanation of the differences between Interface and Gateway types, security group settings, and CLI verification procedures."
categories: ["Linux System Admin"]
tags: ["aws-ssm", "vpc-endpoint", "privatelink", "security-group", "aws-cli"]
author: "K-Life Hack"
---

# AWS VPC Endpoint Design and Implementation: Structural Understanding of Secure Private Connections

<b>meta_description</b>: Detailed explanation of the operating principles of Interface and Gateway VPC endpoints, security design for SSM operations, and CLI verification processes from a system architect's perspective.

## 1. Basic Concepts and Design Philosophy of VPC Endpoints

AWS VPC endpoints are a network feature that enables resources within an Amazon Virtual Private Cloud (VPC) to connect privately to supported AWS services and VPC endpoint services without going through the public internet. With this architecture, traffic between the VPC and the service remains within the Amazon network, improving security and performance.


Typically, resources such as EC2 instances, ECS tasks, and Lambda functions deployed in private subnets use VPC endpoints to access services like AWS Systems Manager (SSM), Amazon S3, Amazon CloudWatch Logs, and Amazon ECR.



### Traffic Flow Logic

`Private Subnet Resource` → `AWS Service API Call` → `VPC Endpoint` → `AWS Service`

There are four components that must be accurately distinguished during implementation:



1. <b>VPC Endpoint</b>: The private connection feature itself.
2. <b>VPC Endpoint Service Name</b>: The specific AWS service identifier selected during creation (e.g., `com.amazonaws.ap-northeast-2.ssm`).
3. <b>Prefix List</b>: A managed object containing a group of IP address ranges (CIDR blocks).
4. <b>Endpoint Type</b>: The underlying connection method (Interface type or Gateway type).

## 2. Comparative Analysis of Network Components

VPC endpoints differ in purpose from other network features such as Transit Gateway, NAT Gateway, and EC2 Instance Connect. The primary differences are as follows:



| Category | Purpose | Representative Flow | Key Decision Criteria |
| :--- | :--- | :--- | :--- |
| <b>VPC Endpoint</b> | Private access to AWS services from internal resources | EC2 → VPCE → AWS Service | Used for accessing AWS services |
| <b>Transit Gateway</b> | Routing hub between VPCs, VPNs, and Direct Connect | VPC ↔ TGW ↔ VPC/On-premises | Used for inter-network connectivity |
| <b>NAT Gateway</b> | Outbound internet transmission from private resources | EC2 → NAT → Internet | Used for external transmission to the internet |
| <b>EIC Endpoint</b> | SSH/RDP access to EC2 without public IPs | User → EIC Endpoint → EC2 | Used as an access path to EC2 |

## 3. Strict Identification of Service Names and Prefix Lists

### 3-1. VPC Endpoint Service Name Format

The service name is an identifier used to specify the AWS service to which the endpoint connects. For the Seoul region (ap-northeast-2), the standard format is `com.amazonaws.<region>.<service-code>`.</service-code></region>



*   `com.amazonaws.ap-northeast-2.ssm` (SSM API)
*   `com.amazonaws.ap-northeast-2.ssmmessages` (Session Manager data channel)
*   `com.amazonaws.ap-northeast-2.ec2messages` (SSM Agent messaging)

### 3-2. Prefix Lists

Prefix lists are sets of CIDR blocks managed by IDs in the format `pl-xxxxxxxx`. AWS-managed prefix lists can be referenced in security groups and route tables, but prefix lists do not exist for all VPC endpoint services. They primarily play an important role in Gateway-type endpoints such as S3 and DynamoDB.



## 4. Structural Logic by Endpoint Type

### 4-1. Interface Endpoints (AWS PrivateLink)

Interface endpoints utilize AWS PrivateLink. Upon creation, an <b>Endpoint ENI</b> (Elastic Network Interface) is generated within the specified subnet.



*   <b>Logic</b>: `EC2` → `TCP 443` → `Endpoint ENI` → `AWS PrivateLink` → `AWS Service`.
*   <b>Security</b>: A security group must be attached to the Endpoint ENI to control inbound traffic.

### 4-2. Gateway Endpoints

Gateway endpoints do not use ENIs or security groups. Instead, they function by directly modifying <b>route tables</b>.



*   <b>Mechanism</b>: A route is added to the route table with the destination set to an AWS-managed prefix list (e.g., S3) and the target set to the VPC endpoint ID (`vpce-xxxxxxxx`).
*   <b>Logic</b>: `EC2` → `Route Table (Dest: S3 Prefix List, Target: VPCE)` → `S3/DynamoDB`.

## 5. Security Design of Interface Endpoints in SSM Operations

Since services such as SSM, Logs, and Monitoring use the Interface type, security group configuration is essential.



### Security Group Standard Settings

*   <b>Inbound Rules</b>: Allow <b>TCP 443</b> from the source (EC2 instance security group or internal CIDR).
*   <b>Outbound Rules</b>: Usually allow "All Traffic," but can be restricted according to organizational policy.

⚠️ <b>Note</b>: Private DNS must be enabled. This ensures that service URLs resolve to the private IP addresses of the Endpoint ENIs.



## 6. Infrastructure State Verification Procedures via CLI

To confirm that the configuration is correct, perform verification using the following steps:



### Step 1: Identify VPC Endpoints

```bash
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-xxxxxxxx --query 'VpcEndpoints[*].{ID:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType}'
```

### Step 2: Confirm Security Group Rules

```bash
aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-xxxxxxxx
```

### Step 3: Confirm DNS Resolution

```bash
nslookup ssm.ap-northeast-2.amazonaws.com
```

💡 If Private DNS is correctly configured, the result will return the private IP addresses of the Interface endpoint ENIs.



## 7. Operational Notes

*   <b>Interface Type</b>: Ensure that the ENI, security group, and Private DNS are all correctly in place.
*   <b>Gateway Type</b>: Ensure that an entry exists in the route table with the prefix list as the destination.
*   <b>SSM Requirements</b>: To make SSM fully functional, all three endpoints—`ssm`, `ssmmessages`, and `ec2messages`—are required. If any are missing, Session Manager connection failures or agent offline states will occur.
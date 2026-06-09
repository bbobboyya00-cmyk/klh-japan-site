---
title: "Implementation Architecture Analysis of Micro-segmentation and SBOM in Genians ZTNA"
slug: "genians-ztna-security-architecture-analysis"
date: 2026-06-09T14:11:58+09:00
draft: false
image: ""
description: "A technical explanation of micro-segmentation based on over 600 conditions provided by Genians ZTNA, FIDO2-compliant passkey authentication, and ensuring software supply chain transparency through SBOM."
categories: ["DevOps Logistics"]
tags: ["ztna", "micro-segmentation", "fido2", "passkey", "sbom", "cyclonedx"]
author: "K-Life Hack"
---

## Micro-segmentation Based on Over 600 Conditions

While many conventional ZTNA solutions rely on simple role-based policies, Genians ZTNA leverages the NAC (Network Access Control) technology stack to achieve extremely granular node classification. As the limitations of perimeter-based security are exposed, this identification capability becomes a critical factor in the transition from VPN to Zero Trust Network Access.



### Components of the Classification Matrix

Node group definitions combine over 600 conditions across the following four categories. This enables access control based not only on static attributes but also on dynamic context.



*   <b>Network Identifiers</b>: IP/MAC addresses, open ports, traffic patterns
*   <b>System Metadata</b>: Platform type, system information, node type, registration date
*   <b>Security Posture</b>: Anti-virus (AV) status, agent health checks, password settings, OS update status
*   <b>Context Data</b>: User accounts, custom tags, application-specific data

By combining these conditions, multi-layered conditional branching is logically constructed, such as "Allow only if a Windows 11 device that maintains the latest AV signatures and is joined to the corporate domain is accessing from an external IP."



### Two-Stage Policy Structure: Compliance and Permission

Access control is executed through the following two-stage verification process. This architecture operates based on the whitelist-based "Deny by Default" principle, where all traffic not explicitly permitted is blocked.



1.  <b>Compliance Policy</b>: Defines the minimum security standards (installation of required software, patch status, etc.) that a device must meet before being considered for access rights.
2.  <b>Permission Policy</b>: Grants specific permissions for particular services, applications, access locations, and timeframes after compliance is verified.

```json
{
  "policy_name": "Secure_Remote_Access_v1",
  "compliance_criteria": {
    "os_version": "Windows 11 22H2+",
    "antivirus": "Active",
    "patch_level": "Critical_Only",
    "agent_status": "Healthy"
  },
  "permission_rules": [
    {
      "service": "Internal_ERP",
      "access_method": "SDP_Gateway",
      "authentication": "FIDO2_Passkey",
      "action": "ALLOW"
    }
  ],
  "default_action": "DENY"
}
```

## Passwordless Implementation via Passkey Authentication

To eliminate risks from phishing attacks and password reuse, Genians ZTNA integrates passkey authentication compliant with FIDO2/WebAuthn standards. This significantly enhances the robustness of the authentication process.



### Authentication Mechanism and Security

Passkeys utilize public-key cryptography, where the private key is stored in a secure element within the user's device (smartphone or PC). Since only the public key is stored on the server side, the risk of credential leakage from the server is structurally eliminated. Furthermore, because passkeys are bound to domains, they possess characteristics that prevent misuse on phishing sites.



### Operational Scenarios

*   <b>Administrator Console</b>: Protects access to the most sensitive management endpoints with passkeys.
*   <b>Captive Web Portal (CWP)</b>: Functions as a gateway when general users access internal resources.
*   <b>Multi-factor Authentication (MFA)</b>: Can be flexibly configured as an MFA factor combined with SMS or email authentication, or as primary authentication.

If desktop hardware lacks biometric authentication, cross-device authentication is also supported, allowing smartphones (Android/Chrome, iPhone/Safari) to be used as roaming authenticators via Bluetooth, balancing convenience and security.



## Software Supply Chain Transparency via SBOM

Since the Log4j vulnerability incident, visibility into software components has become an indispensable requirement. Genians ZTNA provides an SBOM (Software Bill of Materials) for all product components to ensure supply chain transparency.



### Standard Formats and Generation Process

SBOMs are provided in industry-standard <b>CycloneDX</b> (OWASP) and <b>SPDX</b> (Linux Foundation, ISO/IEC 5962:2021) formats. They are automatically generated at build time using tools such as `Syft` or language-specific plugins, maintaining an up-to-date configuration list for each release package.



### Granularity by Component

To improve audit precision, the SBOM is provided separately for each component rather than as a single monolithic file. This allows for immediate identification of which component contains a specific library version when a CVE is reported.



| Component | Format | Example Generation Tools |
| :--- | :--- | :--- |
| Management Console (WebUI) | CycloneDX | cyclonedx-npm |
| Engine (centerd) | CycloneDX | cyclonedx-gomod |
| Agent (Windows/Linux/macOS) | CycloneDX | Syft |

## Findings

Genians ZTNA is not merely a replacement for access control; it elevates the concept of Zero Trust to a practical operational level by integrating deep NAC visibility with modern security standards like FIDO2 and SBOM. In particular, dynamic micro-segmentation combining over 600 conditions forms an extremely effective defense layer for suppressing lateral movement by ransomware. During implementation, network design considering the domain binding characteristics of passkeys, such as domain assignment to the policy server, is crucial.


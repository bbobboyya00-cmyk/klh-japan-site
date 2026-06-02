---
title: "Technical Analysis of the 'Mini Shai-Hulud' npm Ecosystem Supply Chain Attack"
slug: "npm-typosquatting-mini-shai-hulud-analysis"
date: 2026-05-30T10:33:07+09:00
draft: false
image: ""
description: "Analysis of the 'Mini Shai-Hulud' credential theft attack via npm packages in May 2026. Details stealth methods exploiting the Bun runtime, AWS/GitHub Secrets leakage risks, and specific defense measures."
categories: ["DevOps Logistics"]
tags: ["npm-security", "supply-chain-attack", "typosquatting", "aws-secrets-manager", "github-actions", "bun-runtime"]
author: "K-Life Hack"
---

# Analysis Report of the "Mini Shai-Hulud" npm Supply Chain Attack: Advanced Credential Theft Methods Exploiting the Bun Runtime

On May 28, 2026, an advanced supply chain attack campaign named "Mini Shai-Hulud" was identified in the npm ecosystem. This attack distributed 14 malicious packages within a 4-hour window, aiming to immediately extract high-value credentials from cloud environments and CI/CD pipelines. This report analyzes the technical execution flow, evolution for increased stealth, and defense measures required for infrastructure security.



## 1. Attack Origin: Typosquatting and Metadata Impersonation

The attacker targeted ecosystems related to OpenSearch and ElasticSearch, which are widely utilized in corporate environments. A maintainer account with the identifier <b>vpmdhaj</b> employed the following sophisticated methods:



*   <b>Typosquatting</b>: Adopted names such as `opensearch-setup` and `env-config-manager`, which are easily mistaken for official utility packages. This exploits developer typos or the assumption of official status.
*   <b>Metadata Manipulation</b>: The repository URL in the `package.json` was modified to point to the actual official OpenSearch GitHub repository to deceive automated audit tools and manual developer inspections.

## 2. Execution Mechanism: Exploitation of npm Lifecycle Hooks

A critical risk of this attack is that developers do not need to explicitly call the package via `require()` or `import`. The attack code is executed using the `preinstall` hook, a standard npm feature.



```json
{
  "name": "opensearch-setup",
  "version": "1.0.0",
  "scripts": {
    "preinstall": "node ./scripts/setup.js"
  }
}
```

The moment a developer executes `npm install <package-name>` in the terminal, the npm client automatically triggers the `preinstall` script. This causes the malicious payload to execute immediately on the local environment or build server before static analysis or code reviews can occur.</package-name>



## 3. Evolution of Stealth: Analysis of Second-Generation (Gen-2) Stagers

In the "Mini Shai-Hulud" campaign, detection evasion techniques evolved rapidly. The transition to "Living off the Land (LotL)" in the second generation is particularly noteworthy.



### Generation 1 (Gen-1)

Initial payloads connected directly to the attacker's C2 (Command and Control) server to download secondary binaries. This method is relatively easy to detect through network egress monitoring.



### Generation 2 (Gen-2): Living off the Land (LotL)

To evade detection, the attacker shifted to methods exploiting legitimate binaries.



1.  <b>Acquisition of Legitimate Runtime</b>: The script downloads the signed, legitimate <b>Bun runtime (v1.3.13)</b> directly from the official GitHub release page (`github.com/oven-sh/bun/releases/download`).
2.  <b>Payload Execution</b>: A hidden malicious script of approximately 195KB within the package is executed using the downloaded legitimate Bun runtime. Consequently, EDR (Endpoint Detection and Response) systems process it as a standard process by a trusted binary, bypassing anomaly detection.

## 4. Target Assets and Post-Exploitation Impact

The executed payload begins scanning the core components of cloud-native environments. AWS environments and CI/CD pipelines are the primary targets.



*   <b>AWS Infrastructure Credential Theft</b>: Attempts to access EC2 Instance Metadata Service (IMDSv2) and ECS task metadata to obtain temporary IAM role information. It automatically scans AWS Secrets Manager across <b>more than 16 AWS regions</b> to extract API keys, database credentials, and encryption keys.
*   <b>CI/CD Pipeline Hijacking</b>: Identifies if the execution environment is GitHub Actions and targets `GITHUB_TOKEN` and other secrets stored in environment variables. This enables repository manipulation or backdoor injection into build artifacts.
*   <b>Cascading Supply Chain Compromise</b>: Uses stolen npm deployment tokens to publish unauthorized updates to other legitimate open-source packages managed by the victim, expanding the scope of damage.

## 5. Recommended Defense and Mitigation Measures

To protect environments from fluid supply chain attacks, the following technical controls are recommended.



### I. Disabling Automatic Script Execution

The most effective way to prevent exploitation of lifecycle hooks is to explicitly prohibit script execution during installation.



```bash
npm install --ignore-scripts
```

```bash
npm config set ignore-scripts true
```

### II. Immediate Credential Rotation

If there is evidence of suspicious package installation or if build environments were active after May 28, 2026, immediately update the following information:



*   AWS IAM users and STS temporary credentials
*   HashiCorp Vault access tokens
*   GitHub Actions Personal Access Tokens (PAT) and repository secrets
*   npm registry publishing tokens

### III. Enhanced Network and Process Monitoring

*   <b>Egress Filtering</b>: Monitor for unexpected binary downloads from Node.js or pnpm processes to the release section of `github.com`.
*   <b>Process Auditing</b>: Check for the presence of processes initialized with the environment variable `__DAEMONIZED=1`. This is a signature used by "Mini Shai-Hulud" when attempting background persistence.

## 6. Conclusion

"Mini Shai-Hulud" is a typical example of a modern supply chain attack that evades security products by exploiting legitimate runtimes. Based on Zero Trust principles, it is essential to strictly manage dependency locking and restrict script execution.



## Summary

*   <b>Attack Method</b>: Typosquatting, immediate execution via `preinstall` hooks, LotL attacks using the Bun runtime.
*   <b>Primary Targets</b>: AWS Secrets Manager, GitHub Actions tokens, npm deployment tokens.
*   <b>Countermeasures</b>: Strict enforcement of `--ignore-scripts`, monitoring for suspicious binary downloads, and rapid token rotation.
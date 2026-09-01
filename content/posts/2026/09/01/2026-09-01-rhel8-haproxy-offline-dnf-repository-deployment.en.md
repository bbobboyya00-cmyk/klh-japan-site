---
title: "HAProxy Offline Dependency Resolution and Local Repository Construction Procedure on RHEL 8"
slug: "rhel8-haproxy-offline-dnf-repository-deployment"
date: 2026-09-01T10:17:30+09:00
draft: false
image: ""
description: "Explains the procedure and troubleshooting for acquiring HAProxy and all its dependent RPM packages using the dnf command, creating a local repository with createrepo, and performing offline deployment in an isolated RHEL 8 network environment."
categories: ["Linux System Admin"]
tags: ["haproxy", "dnf", "rhel8", "createrepo", "rpm", "offline-repository"]
author: "K-Life Hack"
---

In enterprise air-gapped environments or DMZ zones where direct connection to external networks is restricted due to security constraints, installation errors caused by missing dependent libraries are a frequent challenge when deploying the HAProxy load balancer anew. RHEL 8 adopts DNF (Dandified YUM) as its standard package management system, strongly requiring an operational design where all dependencies (Dependency Graph) are resolved and packages are acquired in advance in an online environment, and then configured as a local repository on the target verification machine.



## Extracting Packages and All Dependencies in an Online Environment

To prepare the package set to be brought into the air-gapped network, first extract HAProxy and the shared libraries required for its runtime (`openssl-libs`, `pcre2`, `systemd`, etc.) on a workstation node with internet connectivity.


Rather than acquiring only the main RPM, execute with a combination of the `--resolve` and `--alldeps` options to collect all libraries not yet installed in the target environment without omission.



```bash
sudo dnf download --resolve --alldeps --destdir=/tmp/haproxy_rpms haproxy
```

### Parameter Configuration Specifications

- `--resolve`: Analyzes the dependency tree and identifies all RPM files required for operation as download targets.
- `--alldeps`: Forces all dependent packages to be downloaded without omitting them, even if the libraries already exist on the host executing the download.
- `--destdir=/tmp/haproxy_rpms`: Outputs the downloaded RPMs collectively to the specified directory.

When explicitly acquiring a specific version (e.g., `haproxy-2.2.0-1.el8`), verify the list of versions in the repository and specify the version string.



```bash
# Check available duplicate and older versions
sudo dnf --showduplicates list haproxy

# Explicitly download a specific version
sudo dnf download --destdir=/tmp/haproxy_rpms haproxy-2.2.0-1.el8
```

## Creating and Deploying a Local Repository in an Offline Environment

After transferring the acquired RPMs to the target server in the air-gapped environment via USB flash drive or internal storage, initialize a local filesystem-based DNF repository.



### 1. Generating Repository Metadata

Navigate to the destination directory and create XML-formatted metadata (`repodata`) using the `createrepo` utility.



```bash
cd /tmp/haproxy_rpms
sudo createrepo .
```

### 2. Configuring the Repository Definition File

Create a `.repo` configuration file pointing to the local repository under `/etc/yum.repos.d/`.



```bash
cat &lt;&lt; EOF | sudo tee /etc/yum.repos.d/haproxy-local.repo
[haproxy-local]
name=HAProxy Local Repository
baseurl=file:///tmp/haproxy_rpms
enabled=1
gpgcheck=0
EOF
```

### 3. Executing Installation from the Local Repository

Once configuration is complete, reference the local metadata and execute the installation.



```bash
sudo dnf clean all
sudo dnf install -y haproxy
```

## Troubleshooting

Below are representative troubleshooting steps for errors caused by permissions, SELinux, and dependency mismatches during local repository operations and package installations in an offline environment.



### 1. `/tmp` Directory Permissions and SELinux Context Denials

When placing a repository under `/tmp`, metadata read errors may occur due to SELinux access controls or system temporary file cleanup jobs (`systemd-tmpfiles`).


<b>Example Symptoms:</b>

```text
Error: Failed to download metadata for repo 'haproxy-local': Cannot download repomd.xml: Cannot open file
```

<b>Workaround:</b>
Change the repository location to a persistent directory such as `/opt/local_repos/haproxy` and reapply the appropriate SELinux context.



```bash
sudo mkdir -p /opt/local_repos/haproxy
sudo mv /tmp/haproxy_rpms/* /opt/local_repos/haproxy/
sudo restorecon -Rv /opt/local_repos/haproxy
```

Rebuild the cache after updating `baseurl` in `/etc/yum.repos.d/haproxy-local.repo` to `file:///opt/local_repos/haproxy`.



### 2. GPG Signature Verification Error

When `gpgcheck=1` is set, the installation will be aborted if the public key has not been imported.


<b>Workaround:</b>
For local verification purposes, set `gpgcheck=0` or import the official Red Hat GPG key in advance.



```bash
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
```

### 3. System Verification Log Protocol

Example terminal verification commands and execution logs to confirm service status and system socket health after deployment completion.



```text
$ sudo systemctl enable --now haproxy
Created symlink /etc/systemd/system/multi-user.target.wants/haproxy.service -&gt; /usr/lib/systemd/system/haproxy.service.

$ sudo systemctl status haproxy
● haproxy.service - HAProxy Load Balancer
   Loaded: loaded (/usr/lib/systemd/system/haproxy.service; enabled; vendor preset: disabled)
   Active: active (running) since Tue 2026-09-01 10:15:30 KST; 12s ago
 Main PID: 14820 (haproxy)
    Tasks: 2 (limit: 23800)
   Memory: 7.4M
   CGroup: /system.slice/haproxy.service
           ├─14820 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid
           └─14822 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid

$ haproxy -v
HA-Proxy version 2.2.9-3.el8 2021/08/10
Configuration file is /etc/haproxy/haproxy.cfg
```

## Configuration Notes

- <b>Ensuring Completeness of Package Dependencies</b>: When executing `dnf download --resolve --alldeps` in a staging environment, using a node with an OS build version and minimal installation (Minimal Install) equivalent to the target environment as much as possible helps prevent missing dependent libraries.
- <b>Periodic Update of Repository Indexes</b>: Whenever packages are added or replaced, always execute `createrepo --update /opt/local_repos/haproxy` to recalculate the metadata index.
- <b>Alignment with Security Policies</b>: In production environments, maintaining `gpgcheck=1` and automating the checksum comparison and signature verification process for downloaded RPMs is recommended.
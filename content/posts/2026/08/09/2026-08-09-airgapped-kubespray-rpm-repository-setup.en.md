---
title: "Procedure for Building a Local RPM Repository for Kubespray in an Air-Gapped Environment"
slug: "airgapped-kubespray-rpm-repository-setup"
date: 2026-08-09T10:04:14+09:00
draft: false
image: ""
description: "Explains the procedure for bulk acquisition of dependent RPMs using dnf and setting up a local Yum repository for Kubespray deployment in an air-gapped environment isolated from external networks."
categories: ["DevOps Logistics"]
tags: ["kubespray", "dnf", "rpm", "containerd", "rocky-linux"]
author: "K-Life Hack"
---

When performing automated Kubernetes cluster construction using Kubespray in an air-gapped environment completely isolated from external networks, it is necessary to procure the required packages for bootstrap processing and OS-level initialization in advance. Simply obtaining and bringing in single RPM packages from an internet-connected environment frequently leads to package installation errors during provisioning due to OS minor version mismatches or missing dependency trees.


This article outlines the procedure for fully collecting all required RPM packages using the dependency resolution flags of <code>dnf</code> on an internet-connected staging host, assuming a Rocky Linux 9.7 environment, and building and verifying a local Yum repository on an internal network Web server.



## 1. Staging Environment Preparation and Dependency Resolution Mechanism

The internet-connected staging host is configured with the same OS distribution and architecture as the target air-gapped nodes. To traverse the package dependency tree and collect all downstream dependencies without omission, the <code>dnf download</code> command is used after installing the <code>dnf-plugins-core</code> plugin.



```bash
sudo dnf install -y dnf-plugins-core

# Create payload storage directories
mkdir -p /data/kubespray-rpms/os
mkdir -p /data/kubespray-rpms/docker-ce-stable
```

### Key Option Specifications for the dnf download Command

Specify the following flags for downloading dependencies:



* `--resolve`: Automatically analyzes the entire required dependency graph for the specified packages.
* `--alldeps`: Forces all RPM files included in the dependency tree to be targeted for download, even if the packages are already installed on the staging host.

```bash
dnf download --resolve --alldeps --destdir=<target_directory> <package_name>
```

## 2. RPM Package Acquisition Procedure

### 2.1 Downloading OS Base Packages and Kubernetes Network Dependencies

Collect the basic tools, network control utilities, and Python bindings required for Ansible execution and Kubespray node setup.



```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  python3 \
  python3-libselinux \
  conntrack-tools \
  socat \
  iproute \
  iproute-tc \
  iptables \
  ipset \
  ipvsadm \
  ethtool \
  chrony \
  rsync \
  tar \
  unzip \
  curl \
  openssl \
  ca-certificates \
  ebtables
```

*Note: If the <code>ebtables</code> package is not provided or is deprecated in Enterprise Linux 9 series repositories such as Rocky Linux 9, exclude <code>ebtables</code> from the target list before execution.



```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  python3 python3-libselinux conntrack-tools socat iproute iproute-tc \
  iptables ipset ipvsadm ethtool chrony rsync tar unzip curl openssl ca-certificates
```

### 2.2 Acquiring Container Runtime Dependencies (containerd.io)

Because the standard OS repositories do not contain a production-level <code>containerd.io</code> package, register the official Docker CE repository to retrieve it.



```bash
# Add the Docker CE Stable repository
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Download containerd and SELinux policies
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/docker-ce-stable \
  containerd.io \
  container-selinux
```

When adopting the <code>container_manager: containerd</code> configuration in Kubespray, the full <code>docker-ce</code> engine set is not required; configuration is possible with only <code>containerd.io</code> and <code>container-selinux</code>.



## 3. Creating an Archive and Deploying the Local Repository

Check the volume of the acquired packages and bundle them as a compressed archive.



```bash
cd /data
tar czf kubespray-rpms-rocky9.7.tgz kubespray-rpms
```

Transfer the created archive to an internal mirror server (e.g., Nginx) and extract it under the document root.



```bash
sudo mkdir -p /usr/share/nginx/html/ROCKY_9.7
sudo tar xzf kubespray-rpms-rocky9.7.tgz -C /usr/share/nginx/html/ROCKY_9.7
```

After extraction, execute the <code>createrepo_c</code> utility to generate repository metadata (repodata).



```bash
sudo createrepo_c /usr/share/nginx/html/ROCKY_9.7/kubespray-rpms/os
sudo createrepo_c /usr/share/nginx/html/ROCKY_9.7/kubespray-rpms/docker-ce-stable
```

## 4. Client Node Configuration and Verification

On the target nodes within the air-gapped environment, disable external repository configurations and create <code>/etc/yum.repos.d/kubespray-local.repo</code> to reference the created local repository.



```ini
[kubespray-os]
name=Kubespray OS RPMs
baseurl=http://harbor.devstack.co.kr/ROCKY_9.7/kubespray-rpms/os
enabled=1
gpgcheck=0

[kubespray-containerd]
name=Kubespray Containerd RPMs
baseurl=http://harbor.devstack.co.kr/ROCKY_9.7/kubespray-rpms/docker-ce-stable
enabled=1
gpgcheck=0
```

## Troubleshooting

### Case 1: `createrepo_c` Does Not Exist on the Mirror Server

If the <code>createrepo_c</code> command is not installed on the repository server itself within the air-gapped environment, metadata generation cannot be performed, causing <code>dnf makecache</code> to fail.


<b>Remediation Procedure:</b><br/>On the internet-connected staging host, acquire <code>createrepo_c</code> itself along with its dependencies in advance, and include it in the payload to bring over.



```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  createrepo_c
```

### Case 2: Repository Index Synchronization Error and Package Not Found Issues

After configuring the local repository, if old cache remains when executing <code>dnf list</code>, errors indicating missing packages will occur. Explicit execution of cache clearing and index rebuilding is required.


<b>Verification Log Example:</b>



```text
$ sudo dnf clean all
15 files removed

$ sudo dnf makecache
Kubespray OS RPMs                                3.2 MB/s | 2.1 MB     00:00    
Kubespray Containerd RPMs                        1.8 MB/s |  12 kB     00:00    
Metadata cache created successfully.

$ sudo dnf repolist
repo id               repo name
kubespray-containerd  Kubespray Containerd RPMs
kubespray-os          Kubespray OS RPMs

$ dnf list containerd.io conntrack-tools socat
Available Packages
conntrack-tools.x86_64            1.4.7-2.el9                kubespray-os        
containerd.io.x86_64              1.7.25-3.1.el9             kubespray-containerd
socat.x86_64                      1.7.4.1-5.el9              kubespray-os
```

## Lessons Learned

1. <b>Forced Full Dependency Acquisition</b>: Without the `--alldeps` option, packages already installed on the staging host will be skipped, posing a risk of missing dependencies on the nodes in the air-gapped environment.
2. <b>Isolated Management of Container Runtime</b>: Version conflicts can be avoided by individually retrieving `containerd.io` from the Docker CE repository and indexing it separately from standard OS repositories.
3. <b>Pre-generation of repodata</b>: Creating metadata with `createrepo_c` on the repository server before making it available to clients is a mandatory requirement for healthy Yum/DNF package distribution.</package_name></target_directory>
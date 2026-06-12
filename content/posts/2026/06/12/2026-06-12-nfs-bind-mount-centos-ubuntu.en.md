---
title: "NFS Export Configuration Using Bind Mount in a CentOS 7.9 Environment"
slug: "nfs-bind-mount-centos-ubuntu"
date: 2026-06-12T14:10:56+09:00
draft: false
image: ""
description: "NFS configuration procedures and troubleshooting using Bind Mount to safely share data under /root on CentOS 7.9 with an Ubuntu client."
categories: ["Linux System Admin"]
tags: ["nfs-utils", "bind-mount", "centos-7", "ubuntu-client", "selinux-policy"]
author: "K-Life Hack"
---

In Linux server operations, it may become necessary to share data under specific user directories (especially /root) via NFS. However, the strict permission settings (700/750) of the /root directory hinder directory tree traversal by NFS clients, serving as a primary cause of 'Permission Denied'. To circumvent this restriction without changing the physical location of the original data, this document details implementation procedures adopting a "Bind Mount" strategy to map data to a path dedicated to NFS export.



## 1. System Configuration and Design Requirements

In this configuration, /root/webapps/data on CentOS 7.9 is used as the source and bound to /srv/nfs/data, which is accessible from the Ubuntu client. This achieves secure data sharing while avoiding permission inheritance issues from parent directories.



* <b>NFS Server:</b> CentOS Linux release 7.9.2009 (192.168.0.100)
* <b>NFS Client:</b> Ubuntu (192.168.0.200)
* <b>Source Path:</b> /root/webapps/data (Restrictive permissions)
* <b>Export Path:</b> /srv/nfs/data (Proxy path)

## 2. Server-Side Implementation (CentOS 7.9)

### 2.1. Package Installation and Directory Preparation

First, install nfs-utils, which provides NFS server functionality, and create the endpoint for export.



```bash
yum install -y nfs-utils
mkdir -p /srv/nfs/data
```

### 2.2. Path Mapping via Bind Mount

Instead of exporting the directory under /root directly, bind it under /srv. This allows the NFS daemon to access the data without being subject to /root's permission restrictions.



```bash
mount --bind /root/webapps/data /srv/nfs/data
```

To maintain this setting after a reboot, add the following entry to /etc/fstab.



```etc
/root/webapps/data    /srv/nfs/data    none    bind    0 0
```

### 2.3. NFS Export Configuration

Define access permissions for specific client IPs in /etc/exports.



```etc
/srv/nfs/data    192.168.0.200(rw,sync,no_root_squash,no_subtree_check)
```

* <b>rw:</b> Grants read and write permissions.
* <b>sync:</b> Ensures data consistency by responding only after writes are completed.
* <b>no_root_squash:</b> Treats the root user on the client side as the root user on the server side (consider carefully based on operational requirements).
* <b>no_subtree_check:</b> Disables subtree checking to improve reliability.

After applying the settings, verify the export status.



```bash
exportfs -ra
exportfs -v
```

### 2.4. Service Management and RPC Registration

Start the NFS service and the port mapper (rpcbind).



```bash
systemctl enable --now rpcbind
systemctl enable --now nfs-server
```

## 3. Client-Side Implementation (Ubuntu)

On the Ubuntu client side, prepare the mount using the nfs-common package.



```bash
apt-get update
apt-get install -y nfs-common
mkdir -p /mnt/nfs_data
mount -t nfs 192.168.0.100:/srv/nfs/data /mnt/nfs_data
```

## 4. Security and Firewall Configuration

### 4.1. Firewalld Configuration (CentOS 7)

Allow the NFS, rpc-bind, and mountd services.



```bash
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

### 4.2. SELinux Adjustments

If SELinux is enabled, access via NFS may be denied. Assign the appropriate context.



```bash
setsebool -P nfs_export_all_rw 1
semanage fcontext -a -t public_content_rw_t "/srv/nfs/data(/.*)?"
restorecon -Rv /srv/nfs/data
```

## 5. Troubleshooting

### 5.1. RPC Communication Error (clnt_create: RPC: Unable to receive)

* <b>Cause:</b> nfs-server is not running, or ports 2049/111 are blocked by the firewall.
* <b>Countermeasure:</b> Check systemctl status nfs-server and verify the port listening status with rpcinfo -p.

### 5.2. Permission Denied

* <b>Cause:</b> Bind Mount is not correctly performed, or IP restrictions in /etc/exports are inappropriate.
* <b>Countermeasure:</b> Run mount | grep data on the server side to re-verify the bind status.

## 6. Implementation Verification Log

This protocol log demonstrates normal operation after configuration completion.



```text
[Server] # ls -ld /root/webapps/data
drwxr-xr-x 2 root root 4096 Jun 15 10:00 /root/webapps/data

[Client] # df -h | grep nfs
192.168.0.100:/srv/nfs/data   50G   1.2G   49G   3% /mnt/nfs_data

[Client] # touch /mnt/nfs_data/verify.log
[Client] # ls -l /mnt/nfs_data/verify.log
-rw-r--r-- 1 root root 0 Jun 15 10:05 /mnt/nfs_data/verify.log
```

## Operational Notes

In NFS operations, when sharing data under privileged directories such as /root, establishing an abstraction layer via Bind Mount—rather than exposing the physical path directly—is extremely effective for balancing security and operational flexibility. Particularly in the CentOS 7 series, where complex issues often arise due to the interaction between SELinux policies and NFS, thorough management of mount point contexts is recommended.


---
title: "Integrated Implementation of Virtualization, Authentication, and Log Management on Ubuntu Server Infrastructure"
slug: "ubuntu-server-infra-integration-guide"
date: 2026-06-03T09:05:17+09:00
draft: false
image: ""
description: "A record of initial setup and security hardening procedures for KVM virtualization, DHCP, NTP, NIS/NFS, rsyslog, and Kerberos-based authentication integration on Ubuntu Server."
categories: ["Linux System Admin"]
tags: ["kvm", "rsyslog", "kerberos", "nfs-server", "chrony", "ubuntu-server"]
author: "K-Life Hack"
---

# Building a KVM Virtualization Infrastructure and Integrated Network Management Services on Ubuntu Server

This technical report details the implementation of a KVM-based virtualization environment on Ubuntu Server. The scope includes the configuration of core network services (DHCP, NTP), centralized management systems (NIS, NFS, rsyslog), and the integration of Kerberos for unified authentication.



## 1. Deploying the KVM Virtualization Environment

The infrastructure leverages KVM (Kernel-based Virtual Machine) to host multiple guest operating systems on a single physical node. The deployment process involves installing the virtualization stack and configuring user permissions for the libvirt daemon.



```bash
# Package installation
sudo apt update &amp;&amp; sudo apt -y install qemu-kvm qemu-system libvirt-bin bridge-utils virt-manager

# Granting user privileges
sudo adduser ubuntu libvirt

# D-Bus session configuration
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
export DBUS_SESSION_BUS_PID=$(pgrep -u $(id -u) dbus-daemon)
```

Virtual machine lifecycle management is handled via the <b>virsh</b> command-line interface. The environment supports cloning existing instances, such as Windows 7 or CentOS 7 images, to streamline deployment.



```bash
# Verify VM list
virsh -c qemu:///system list --all

# Example of VM cloning
virt-clone --original win7 --name win7-2 --file /var/lib/libvirt/images/win7-2.qcow2
```

## 2. Network Infrastructure Services (DHCP &amp; NTP)

Automated IP address management is implemented using a DHCP server targeting the 192.168.100.0/24 subnet. This ensures consistent network parameters for all connected clients.



```conf
# /etc/dhcp/dhcpd.conf configuration
subnet 192.168.100.0 netmask 255.255.255.0 {
  range 192.168.100.100 192.168.100.110;
  option domain-name-servers 8.8.8.8;
  option routers 192.168.100.1;
  default-lease-time 600;
  max-lease-time 7200;
}
```

Time synchronization is maintained through Chrony to ensure log accuracy across the distributed system. The NTP service is permitted through the host firewall to allow client synchronization.



```bash
# Verify chrony synchronization
chronyc tracking

# Firewall configuration
sudo firewall-cmd --permanent --add-service=ntp
sudo firewall-cmd --reload
```

## 3. Centralized Management via NIS and NFS

User account information is centralized using NIS (Network Information Service), while shared storage is provided via NFS (Network File System) to facilitate data persistence across nodes.



```bash
# NIS domain configuration
sudo ypdomainname kahn.edu

# Database initialization
sudo /usr/lib/yp/ypinit -m
```

The NFS server exports specific directories with defined access controls. Clients mount these exports to access centralized data volumes.



```bash
# /etc/exports
/NFS 192.168.100.204(rw,sync,no_root_squash)
```

## 4. Log Aggregation via rsyslog

Centralized logging is established using rsyslog. The server is configured with templates to categorize incoming logs from remote hosts based on their hostname and the originating program.



```conf
# /etc/rsyslog.conf server-side configuration
$template TmplAuth, "/var/log/%HOSTNAME%/%PROGRAMNAME%.log"
$template TmplMsg, "/var/log/%HOSTNAME%/messages.log"

authpriv.* ?TmplAuth
*.warn;authpriv.none;mail.none;cron.none ?TmplMsg
```

Client nodes are configured to forward all log data to the central aggregator at 192.168.100.203.



## 5. Kerberos (KDC) Authentication Integration

A Kerberos Key Distribution Center (KDC) is deployed to provide ticket-based authentication, enabling Single Sign-On (SSO) for SSH services within the KAHN.EDU realm.



```bash
# Principal registration
kadmin.local -q "addprinc admin/admin"
kadmin.local -q "addprinc ubuntu"

# Host keytab extraction
kadmin.local -q "ktadd host/ubun-1.kahn.edu"
```

SSH configurations are updated to support GSSAPI authentication, allowing users to authenticate using Kerberos tickets instead of passwords.



## 6. External Storage Integration via FreeNAS

FreeNAS is utilized to manage a ZFS pool (MySHARE) composed of multiple SCSI disks. When mounting these volumes on Linux clients, the <b>nolock</b> option is applied to prevent conflicts with the RPC lock daemon.



```bash
# Client-side mount execution
sudo mount -t nfs -o nolock 192.168.100.180:/mnt/MySHARE/MyLIN /mnt/FreeNAS
```

## Operational Notes

*   <b>SELinux Considerations</b>: SELinux policies may interfere with NIS or Chrony operations. Mitigation involves using <b>setenforce 0</b> for troubleshooting or defining specific policy exceptions. ⚠️
*   <b>Network Constraints</b>: The use of a single network interface limits high-availability features like VM live migration. Future iterations require NIC teaming or advanced bridge configurations. 🛠️
*   <b>NFS Permissions</b>: The <b>no_root_squash</b> parameter is essential for ensuring that the client-side root user maintains administrative write access to the shared storage. 💡
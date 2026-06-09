---
title: "Provisioning and Shared Storage Configuration of a 2-Node Oracle 19c RAC in a VMware Environment"
slug: "vmware-oracle-19c-rac-provisioning"
date: 2026-06-05T18:12:54+09:00
draft: false
image: ""
description: "A technical note on OS configuration, shared disks, ASMLib, and Grid Infrastructure initial setup for building a 2-node Oracle 19c RAC environment on a VMware virtualization platform."
categories: ["Linux System Admin"]
tags: ["oracle-19c", "oracle-rac", "vmware-workstation", "asmlib", "grid-infrastructure"]
author: "K-Life Hack"
---

# Provisioning Procedure for a 2-Node Oracle 19c RAC in a VMware Environment

This document describes the procedures for creating virtual machines, configuring the OS, setting up shared storage, provisioning ASMLib, and performing the initial setup of Grid Infrastructure to build a 2-node Oracle 19c Real Application Clusters (RAC) database environment on a VMware virtualization platform.



## 1. Virtual Machine Provisioning (Node 1: ORA191)

Create the first node (hostname: <b>ORA191</b>) as the baseline virtual machine.



### 1.1. Hardware Specifications and VM Settings

* <b>VM Name</b>: `ORA191`
* <b>Processors</b>: <b>8 vCPUs</b> (to handle parallel processing and cluster overhead)
* <b>Memory</b>: <b>12 GB</b> (to meet the minimum requirements for Oracle Grid Infrastructure and Database instances)
* <b>Network</b>: The primary network adapter is configured as <b>NAT</b> for external connectivity (for downloading packages)
* <b>I/O Controller</b>: LSI Logic SAS (recommended default)
* <b>Virtual Disk Type</b>: <b>SCSI</b>
* <b>Disk Capacity</b>: 
  * Allocate a single virtual disk file (`.vmdk`) of <b>50 GB</b> for the system area
  * 💡 To prevent disk space shortages during database creation or patching, an allocation of <b>100 GB</b> or more is recommended in actual verification environments.
  * Select "Store virtual disk as a single file" and consider applying the pre-allocate option to improve performance.

---

## 2. OS Installation and Basic Configuration

Install Oracle Linux or CentOS on the virtual machine.



### 2.1. Localization and Software Selection

* <b>Language</b>: English (United States)
* <b>Date &amp; Time</b>: Set the timezone to <b>Asia/Seoul</b> and synchronize the system clock
* <b>Software Selection</b>: Select <b>Server with GUI</b> to use graphical tools such as OUI and Grid Setup. Additionally, add the following package groups:
  * <b>KDE</b> (or any preferred desktop environment)
  * <b>Compatibility Libraries</b>
  * <b>Development Tools</b>
  * <b>System Administration Tools</b>

### 2.2. Manual Disk Partitioning

Perform manual partitioning on the 50 GB virtual disk (`sda`).



#### Partition Configuration:

1. `/boot`: <b>1000 MB</b> (standard partition, `ext4` or `xfs`)
2. `swap`: <b>24000 MB</b> (24 GB, to accommodate the 12 GB RAM requirement)
3. `/` (root): <b>All remaining capacity</b>
⚠️ A warning about erasing the existing partition table may appear during partitioning, but for a new installation, you can proceed without issue.



### 2.3. Network and Hostname Configuration

In the network configuration screen, select "Configure" for the primary interface (`ens33`).



1. <b>General Tab</b>: Check <b>"Automatically connect to this network when it is available"</b> to ensure automatic connection on boot.
2. <b>Connection Priority</b>: Leave the connection priority at the default value of `0`.
3. <b>Hostname</b>: Set the static hostname to `ora191` and apply.

---

## 3. Post-OS Installation Customization

### 3.1. VMware Shared Folders Configuration

To facilitate file transfers such as installation media between the host OS and guest OS, set "Shared Folders" to "Always enabled" in the VMware settings and mount the host-side directory.



### 3.2. Running the Oracle Pre-installation RPM

Use the `oracle-database-preinstall-19c` package to automate the configuration of kernel parameters, resource limits (limits.conf), and the creation of required OS users and groups. If the package manager (`yum`) is locked by a background process, terminate the process using the following steps before running it.



```bash
rm -f /var/run/yum.pid
yum install -y oracle-database-preinstall-19c
```

### 3.3. Customizing Users and Groups

In addition to the `oracle` user created by the pre-installation RPM, manually create the `grid` user for Grid Infrastructure and adjust the group configuration.



```bash
groupadd -g 54321 oinstall
groupadd -g 54322 dba
groupadd -g 54323 oper
useradd -u 1200 -g oinstall -G dba,oper grid
usermod -u 1201 -g oinstall -G dba,oper oracle
```

#### Verifying the Configuration:

Run the `id oracle` command to verify that the mapping is correct.



* `uid=1201(oracle)`
* `gid=54321(oinstall)`
* `groups=54321(oinstall),54322(dba),54323(oper)`

---

## 4. Configuring Environment Variables and Shell Limits

### 4.1. Oracle User Environment Variables (`/home/oracle/.bash_profile`)

Add the following settings to the `.bash_profile` of the `oracle` user.



```bash
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/product/19.3.0/dbhome_1
export ORACLE_SID=ORA191
export PATH=$ORACLE_HOME/bin:$PATH
umask 022
```

* `ORACLE_SID`: Must be unique for each node in a 2-node RAC.
* `umask 022`: Controls the default permissions for newly created files and directories.

### 4.2. Grid User Environment Variables (`/home/grid/.bash_profile`)

Add the following settings to the `.bash_profile` of the `grid` user.



```bash
export ORACLE_BASE=/u01/app/grid
export ORACLE_HOME=/u01/app/19.3.0/grid
export ORACLE_SID=+ASM1
export PATH=$ORACLE_HOME/bin:$PATH
umask 022
```

* `ORACLE_SID`: Specifies `+ASM1` as the ASM instance identifier for Node 1.

---

## 5. Creating Directory Structure and Setting Permissions

Log in as the `root` user, create the mount points, and assign ownership and permissions.



```bash
mkdir -p /u01/app/19.3.0/grid
mkdir -p /u01/app/grid
mkdir -p /u01/app/oracle
chown -R grid:oinstall /u01
chown -R oracle:oinstall /u01/app/oracle
chmod -R 775 /u01
```

---

## 6. Network Design and Name Resolution

### 6.1. Verifying Interfaces

Verify the status of the primary interface using the `ip addr` command.



```bash
ip addr show ens33
```

Confirm that the physical and logical layers are active via the `<up,lower_up>` flags.</up,lower_up>



### 6.2. Static Name Resolution Configuration (`/etc/hosts`)

For environments without a DNS server, add the following mappings to `/etc/hosts` on both nodes.



```text
# Public
192.168.10.11  ora191
192.168.10.12  ora192

# Private
172.16.40.11   ora191-priv
172.16.40.12   ora192-priv

# Virtual IP (VIP)
192.168.10.21  ora191-vip
192.168.10.22  ora192-vip

# SCAN
192.168.10.31  ora-scan
```

* <b>Private IP</b>: Dedicated bandwidth for interconnect and Cache Fusion between nodes.
* <b>Virtual IP (VIP)</b>: High-availability IP managed by Oracle Clusterware.
* <b>SCAN (Single Client Access Name)</b>: Common entry point for clients to connect to the cluster.

### 6.3. Hostname and Time Synchronization Configuration

Set the static hostname and disable unnecessary firewalls. Also, configure NTP to prevent cluster eviction caused by time drift between nodes.



```bash
hostnamectl set-hostname ora191
systemctl stop firewalld
systemctl disable firewalld
```

---

## 7. Node Cloning and Node 2 Specific Configuration

Clone Node 2 (`ORA192`) based on the shut-down Node 1 (`ORA191`).



### 7.1. Performing a Full Clone

1. Select "Clone" from the VMware management menu.
2. Select "Clone from current state".
3. <b>Clone Type</b>: Select <b>Full Clone</b>.
4. Specify the target VM name as `ORA192`.

### 7.2. Customizing Hostname and Environment Variables on Node 2

Start `ORA192`, log in as the `root` user, and perform specific configurations.



```bash
hostnamectl set-hostname ora192
```

Modify the ASM SID in `/home/grid/.bash_profile` for the `grid` user.



```bash
sed -i 's/+ASM1/+ASM2/g' /home/grid/.bash_profile
```

Modify the database SID in `/home/oracle/.bash_profile` for the `oracle` user.



```bash
sed -i 's/ORA191/ORA192/g' /home/oracle/.bash_profile
```

---

## 8. Installing ASMLib

To simplify ASM disk management, install the following packages on <b>both nodes</b>.



```bash
yum install -y oracleasm-support kmod-oracleasm
yum install -y oracleasmlib
```

---

## 9. Shared Storage Configuration (Editing VMware VMX Files)

Oracle RAC requires shared disks that can be read and written to simultaneously by both nodes.



### 9.1. Adding Shared Disks to Node 1 (`ORA191`)

1. Select "Add > Hard Disk" from the configuration screen of `ORA191`.
2. Select <b>SCSI</b> and allocate the required capacity.
3. Open the "Advanced" properties of each added disk and check <b>Independent</b> and <b>Persistent</b>.

### 9.2. Editing the `.vmx` Configuration File

Edit the `.vmx` file of each node so that both VMs can access the same disk without lock conflicts. Add the following parameters to the end of both files.



```text
disk.locking = "FALSE"
diskLib.dataCacheMaxSize = "0"
scsi0.sharedBus = "virtual"
```

* `disk.locking = "FALSE"`: Disables disk locking by VMware.
* `scsi0.sharedBus = "virtual"`: Enables SCSI bus sharing between multiple VMs.

---

## 10. Adding a Private Network Adapter

Add a second network adapter for the interconnect between nodes.



1. Select "Add > Network Adapter" from the settings of `ORA191`.
2. Set the network connection type to <b>Host-only</b>.
3. Click "Generate" under "Advanced" to generate a unique MAC address.
4. Perform the same steps for `ORA192` and ensure you regenerate the MAC address.

---

## 11. Configuring the Private Network Interface (ens36)

### 11.1. Node 1 (`ORA191`) Configuration

Change the IPv4 settings to "Manual" and configure as follows:



* <b>Address</b>: `172.16.40.11`
* <b>Netmask</b>: `255.255.255.0`

### 11.2. Node 2 (`ORA192`) Configuration

* <b>Address</b>: `172.16.40.12`
* <b>Netmask</b>: `255.255.255.0`

---

## 12. Provisioning ASM Disks

### 12.1. Initializing ASMLib (Both Nodes)

Run the initialization utility as the `root` user on <b>both nodes</b>.



```bash
oracleasm configure -i
```

* Owner user: `grid`
* Owner group: `dba`
* Start on boot: `y`
* Scan on boot: `y`

```bash
oracleasm init
```

### 12.2. Disk Partitioning (Node 1 Only)

Partition the added shared disks on <b>Node 1 only</b>.



```bash
fdisk /dev/sdb
# n -> p -> 1 -> default -> default -> w
```

### 12.3. Creating ASM Disks (Node 1 Only)

```bash
oracleasm createdisk ASMDISK01 /dev/sdb1
```

### 12.4. Scanning Disks on Node 2

Run a scan to make Node 2 recognize the created disks.



```bash
# Node 1
oracleasm scandisks
# Node 2
oracleasm scandisks
oracleasm listdisks
```

---

## 13. Grid Infrastructure of Installation

### 13.1. Pre-installation Tasks

To prevent DNS conflicts, stop `avahi-daemon` on <b>both nodes</b>.



```bash
systemctl stop avahi-daemon
systemctl disable avahi-daemon
```

Extract the installation media as the `grid` user on Node 1.



```bash
cd $ORACLE_HOME
unzip -q /mnt/hgfs/shared/LINUX.X64_193000_grid_home.zip
```

```bash
./gridSetup.sh
```

### 13.2. Setup Wizard Key Points

1. <b>Cluster Type</b>: Select <b>Configure a Standalone Cluster</b>.
2. <b>Cluster Node Information</b>: Add Node 2 (`ora192`, `ora192-vip`).
3. <b>SSH Connectivity</b>: Enter the password for the `grid` user and run "Setup".
4. <b>Network Interface</b>: Set `ens33` to <b>Public</b> and `ens36` to <b>1st Private</b>.
5. <b>Storage</b>: Select <b>Use ASM</b> and set the Discovery Path to `/dev/oracleasm/disks/*`.

---

## Operational Notes

The environment built in this procedure is a minimal configuration model of a 2-node RAC running on a hypervisor such as VMware Workstation. When applying this to a production environment, physical redundancy of shared storage (SAN/NAS multipath configuration) and network teaming (bonding) must be considered separately. In particular, the `disk.locking = "FALSE"` setting in `.vmx` carries a risk of data corruption if direct mounting is performed from both nodes while Clusterware is stopped, so extreme care must be taken in operational management.


---
title: "Quorum Design to Prevent Split-Brain by Expanding MariaDB Galera Cluster from 2 to 3 Nodes"
slug: "galera-cluster-three-node-expansion"
date: 2026-06-29T11:53:21+09:00
draft: false
image: ""
description: "Explains specific procedures and troubleshooting for expanding a MariaDB Galera Cluster from 2 to 3 nodes and optimizing quorum to prevent split-brain."
categories: ["Linux System Admin"]
tags: ["mariadb-galera-cluster", "quorum", "mariabackup", "sst-synchronization", "split-brain"]
author: "K-Life Hack"
---

# MariaDB Galera Cluster: Achieving High Availability by Expanding from 2 to 3 Nodes

While multi-master configurations are a powerful approach to ensuring database availability, operations sometimes begin with a 2-node configuration due to insufficient consideration during the design phase. However, a 2-node MariaDB Galera Cluster always carries the risk of the entire cluster stopping writes to prevent split-brain, as neither node can maintain a majority (quorum) when a network partition occurs. To eliminate this availability bottleneck and improve fault tolerance, expanding to a 3-node configuration is essential. This article explains the specific procedures for safely expanding from an existing 2-node configuration to a 3-node configuration and considerations for large-capacity State Snapshot Transfer (SST).



## Quorum Design and Selection of SST Method

Quorum (consensus building) in a Galera Cluster is the foundation for maintaining cluster consistency. In a 2-node configuration, if one node stops or leaves the network, the ratio of the remaining node becomes 50%, failing to satisfy the majority (&gt;50%) requirement. As a result, the "Primary Component" state is lost, and the database stops accepting queries. Conversely, in a 3-node configuration, even if one node stops, the remaining two nodes (66.7%) can maintain a majority, allowing the service to continue without interruption.


The process of synchronizing data from an existing node (Donor) to a new node (Joiner) when it joins the cluster is called SST (State Snapshot Transfer). While rsync is a standard file synchronization tool, it results in a "cold transfer" where table locks occur on the Donor node during synchronization, making it unsuitable for production environments. In contrast, mariabackup is an online backup tool provided by MariaDB that allows for asynchronous transfer with minimal blocking of the Donor node. When synchronizing 1.1 TB of data over a 1 Gbps network bandwidth, even with mariabackup, the synchronization takes approximately 3.5 hours, necessitating prior bandwidth design and the reservation of a time window.



## Phase 1: Storage Preparation and Environment Setup

To prepare for database growth, mount /var/lib/mysql to a large-capacity partition (/home/mysql).



```bash
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql
sudo restorecon -Rv /var/lib/mysql
```

Next, execute a bind mount and add the configuration to /etc/fstab so that it is maintained after a reboot.



```bash
sudo mount --bind /home/mysql /var/lib/mysql
```

Append the following line to the end of /etc/fstab.



```text
/home/mysql     /var/lib/mysql     none    bind  0 0
```

Verify the mount status.



```bash
df -h /var/lib/mysql
findmnt /var/lib/mysql
```

Execute database initialization and enable the service.



```bash
sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql
sudo systemctl enable mariadb
sudo systemctl start mariadb
```

Open the following ports in the firewall. Communication must be allowed for 3306 (for client connections), 4567 (TCP/UDP for Galera Cluster replication), 4568 (for IST), and 4444 (for SST).



## Phase 2: Software Installation and Cluster Configuration

To maintain consistency within the cluster, use the same MariaDB version (10.11.4 in this environment) on all nodes. Create a dedicated user for SST execution on the existing DB1 and DB2 nodes.



```sql
CREATE USER 'sstuser'@'localhost' IDENTIFIED BY 'your_secure_password';
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'sstuser'@'localhost';
FLUSH PRIVILEGES;
```

Edit /etc/my.cnf.d/server.cnf on all nodes and change the SST method to mariabackup.



```ini
[mariadb]
wsrep_sst_method=mariabackup
wsrep_sst_auth=sstuser:your_secure_password
```

To apply the settings, restart the existing DB1 and DB2 nodes one by one in order.



```bash
sudo systemctl restart mariadb
```

## Phase 3: Adding the Third Node (DB3)

Since the new node (DB3) must start SST from a clean state, empty the data directory.



```bash
sudo systemctl stop mariadb
sudo rm -rf /var/lib/mysql/*
sudo chown -R mysql:mysql /var/lib/mysql
```

Before starting synchronization, verify connectivity for port 4444. Wait on the DB3 (Joiner) side.



```bash
sudo dnf install -y nmap-ncat
nc -l 4444
```

Send test data from the DB2 (Donor) side.



```bash
echo test | nc -v <db3_ip_address> 4444
```

Once connectivity is confirmed, start the MariaDB service on DB3 to begin synchronization.



```bash
sudo systemctl start mariadb
```

## Phase 4: Monitoring and Troubleshooting

During the 1.1 TB data synchronization, the terminal may appear to have stopped responding. Monitor the progress from another session using the following commands. Determine if the synchronization is proceeding normally by monitoring logs and checking for disk capacity increases.



```bash
sudo journalctl -u mariadb.service -n 300 --no-pager -l

```bash

```

## Troubleshooting

⚠️ SST実行時にDonor側で認証エラーが発生する場合、`sstuser` のホスト制限や権限付与が正しく認識されていない可能性があります。その場合は、一度ユーザーを削除して再作成します。

```sql

```

ローカルソケット経由での接続テストを実行し、認証が正常に通るか確認します。

```bash

```

## Operational Verifications

同期完了後、クラスタのステータスおよびポートのリスン状態を確認します。

```text

```

## Lessons Learned

2ノード構成から3ノード構成への拡張により、スプリットブレインのリスクを排除し、クォーラムを維持した高可用性データベース基盤が確立されました。大容量データの同期においては、rsyncによるテーブルロックを避け、mariabackupによるノンブロッキングなSSTを選択することが、本番稼働中のサービス影響を最小限に抑えるための鍵となります。また、ネットワーク帯域とディスクI/Oの監視を並行して行うことで、同期プロセスの異常を早期に検知することが可能になります。</db3_ip_address>
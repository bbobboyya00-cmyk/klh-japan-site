---
title: "Building a Ransomware-Resilient Backup Infrastructure Using an Append-Only Configuration with restic and rest-server"
slug: "restic-rest-server-append-only-backup"
date: 2026-11-27T10:34:45+09:00
draft: false
image: ""
description: "Setup procedures and verification logs for DB-consistent data offloading in a Debian 13 environment and an immutable backup infrastructure powered by rest-server on a Synology NAS."
categories: ["Linux System Admin"]
tags: ["restic"]
author: "K-Life Hack"
---

# Building a Robust Backup Architecture Using an Append-Only Model

Operating various Docker containers (PostgreSQL, Redis, Qdrant), automation pipelines, and system configurations on a single NVMe storage drive on a single Linux Mini PC host carries a constant risk of data loss due to hardware degradation or filesystem corruption. To safely maintain dynamic operational data beyond source code, a backup architecture that eliminates single points of failure (SPOF) is essential.


This article details the setup procedures for an "Append-Only" backup architecture from a primary server to a network NAS (Synology DS923+). This design guarantees application-layer transaction consistency while preventing backdated deletion or tampering of backup data even if the host is compromised.



## Architecture Comparison and Selection Background

When offloading data from a Linux host, approaches such as Synology Active Backup for Business (ABB), rsync, BorgBackup, and restic are considered. However, careful evaluation is required regarding kernel compatibility and security boundaries.


<b>Synology ABB Linux Agent</b>: Relies on a proprietary kernel module (`synosnap`). In a Debian 13 (Linux Kernel 6.12) environment, there is a high risk of kernel panics or build failures during automatic updates, and it lacks mechanisms to prevent database inconsistency.


<b>rsync over SSH/SMB</b>: Allows simple synchronization, but lacks client-side encryption, deduplication, and point-in-time version management. Furthermore, if the host side is infected with ransomware, synchronized remote files risk being overwritten with encrypted data.


<b>BorgBackup</b>: Provides advanced deduplication and encryption, but requires executing third-party binaries on the DSM side, and concerns have been raised regarding bypass vectors for Append-Only restrictions.


<b>restic + rest-server (Selected)</b>: Runs the lightweight single binary `restic` on the client side, and launches the official `rest-server` in containerized `--append-only` mode on the NAS side. Under this configuration, `DELETE` and file truncation requests are rejected (403 Forbidden) at the HTTP API level, preserving historical backup snapshots even if root access on the primary server is compromised.



## System Architecture and Data Flow

```
+-------------------------------------------------------------------------+
| Linux Server (Debian 13, Kernel 6.12)                                   |
|                                                                         |
|  +----------------------+      +-------------------------------------+  |
|  | DB Engine Containers |      | System Workspace &amp; Files            |  |
|  | (Postgres, Redis,    |      | (Configs, Code, Container Mounts)   |  |
|  |  Qdrant)             |      +------------------+------------------+  |
|  +----------+-----------+                         |                     |
|             | (Logical Dump)                      |                     |
|             v                                     |                     |
|  +----------------------+                         |                     |
|  | ~/srv/backup/dumps/  |                         |                     |
|  +----------+-----------+                         |                     |
|             |                                     |                     |
|             +------------------+------------------+                     |
|                                |                                        |
|                                v                                        |
|             +-------------------------------------+                     |
|             | restic CLI (Client Engine)          |                     |
|             +------------------+------------------+                     |
|                                |                                        |
|                                | systemd Timer (Sat 02:00 JST/KST)      |
+--------------------------------|----------------------------------------+
                                 |
                                 | REST API / HTTP Port 8000
                                 v
+-------------------------------------------------------------------------+
| Synology DS923+ NAS                                                     |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  | Container Manager: restic/rest-server                             |  |
|  | Flags: --append-only | Auth: HTPasswd Authentication              |  |
|  +---------------------------------+---------------------------------+  |
|                                    | Mount                              |
|                                    v                                    |
|  +-------------------------------------------------------------------+  |
|  | Target Btrfs Shared Volume (/volume2/server-backup)               |  |
|  | Data Checksums: Enabled | Immutable Snapshots: 7-Day Retention    |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

&gt; ⚠️ <b>Warning</b>: Directly copying the data directory of a running database (e.g., `/var/lib/postgresql/data`) without taking a snapshot/quiescence point carries an extremely high probability of database corruption upon restoration. Logical dumps (such as `pg_dump`) must be executed immediately prior to the backup process.

## Step 1: Synology NAS Setup

### 1. Creating a Btrfs Shared Folder

Navigate to DSM <b>Control Panel -&gt; Shared Folder -&gt; Create</b>, name it `server-backup`, and select the Btrfs storage pool. Disable the Recycle Bin since restic manages objects internally, and check <b>Enable data checksum for advanced data integrity</b>, which is required for Btrfs silent data corruption detection. Volume encryption is disabled to prevent performance degradation from double encryption, as restic handles AES-256 client-side encryption.



### 2. Configuring Immutable Snapshots with Snapshot Replication

Open DSM <b>Snapshot Replication</b> and configure a schedule for the `server-backup` folder to run every Saturday at 06:00. Set the retention policy to 8 generations and enable <b>Immutable Snapshots</b> for 7 days. This ensures that even if the NAS administrator account is compromised, data deletion is physically impossible for a set duration.



### 3. Deploying Container Manager (`rest-server`)

Pull the `restic/rest-server:latest` image from Container Manager and launch the container with the `--append-only` option enabled. Generate user authentication accounts and verify API connectivity.



```yaml
version: '3.8'
services:
  rest-server:
    image: restic/rest-server:latest
    container_name: rest-server
    restart: always
    ports:
      - "8000:8000"
    volumes:
      - /volume2/server-backup:/data
    environment:
      - OPTIONS=--append-only
      - PASSWORD_FILE=/data/.htpasswd


コンテナ内ターミナルまたはホストシェルから認証ユーザーを作成します。

```bash

```

パスワード設定後、ファイアウォールで対象LinuxホストのIPからポート8000への通信のみを許可し、以下の疎通確認を行います。

```bash

## Step 2: Client Host (Linux Mini PC) Environment Initialization and Authentication

Create the backup directory structure on the client host, securely store secrets (authentication password and repository encryption key), and execute the common library definition file and repository initialization.



```

## ステップ2: Linuxホスト側のスクリプトおよび自動化設定

ホスト側では一般ユーザー権限で環境構築を行い、秘密情報はパーミッション `0600` で保護します。

### 1. ディレクトリと認証情報の準備

```bash

```

### 2. 共通環境変数定義 (`~/srv/backup/lib.sh`)

```bash

```

### 3. リポジトリの初期化

```bash

## Step 3: Database Dump Script Guaranteeing Transaction Consistency

Create a script to ensure transaction quiescence for running containers (PostgreSQL, Redis, Qdrant) and atomically extract consistent logical dumps.



```

### 4. データベース静止点出力スクリプト (`~/srv/backup/dump-dbs.sh`)

重複排除の効率を最大化するため、DBダンプ時の圧縮オプション（`-Z0`）はオフに設定し、生データをrestic側のZstandard圧縮メカニズムに委ねます。

```bash

## Step 4: Main Backup Script Incorporating Atomic Execution and Random Verification

Construct the main backup script with mutual exclusion (`flock`), and perform a 5% random sampling verification of the repository after backup completion to guarantee integrity.



```

### 5. メインバックアップ処理 (`~/srv/backup/backup-files.sh`)

```bash

## Step 5: Automation and Privilege Separation via systemd User Timer

Execute backup tasks using user-space `systemd` services and timers rather than root system admin privileges, achieving privilege separation and reliable automated execution.



```

### 6. systemd Timerによる自動実行化

`~/.config/systemd/user/backup-files.service`:
```ini

```

`~/.config/systemd/user/backup-files.timer`:
```ini

```

ユーザーセッション終了後もタイマーを維持するため、Lingeringを有効化して起動します。

```bash

## Step 6: Append-Only Security Verification

After completing the backup configuration, execute historical snapshot deletion commands (`forget` / `prune`) from the client side and verify that `rest-server` rejects the deletion by returning `403 Forbidden` as expected.



```

## Troubleshooting

### 1. HTTP 403 Forbidden による消去ブロックの動作検証

クライアントホストからスナップショットの消去（`forget` / `prune`）を意図的に試行し、`--append-only` が正しく機能しているか検証します。

```bash

```

実行結果プロトコルログ:

```text

As the verification results indicate, snapshot deletion requests from the client side are reliably blocked by `rest-server`'s Append-Only constraints, confirming that logical database consistency and data health via random checks are properly maintained.


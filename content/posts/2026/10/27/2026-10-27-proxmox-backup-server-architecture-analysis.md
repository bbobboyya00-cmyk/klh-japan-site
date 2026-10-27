---
title: "Proxmox Backup Serverの重複排除メカニズムとバックアップ運用設計"
slug: "proxmox-backup-server-architecture-analysis"
date: 2026-10-27T10:50:01+09:00
draft: false
image: ""
description: "Proxmox Backup ServerにおけるChunkベース重複排除、暗号化境界の制約、Live Restoreの内部動作と運用上のトラブルシューティング手順を整理します。"
categories: ["Linux System Admin"]
tags: ["proxmox backup"]
author: "K-Life Hack"
---

仮想化基盤の規模拡大に伴い、仮想マシン（VM）の増加とデータストレージの膨張はバックアップウィンドウの長時間化を招きます。従来のフルイメージバックアップを定常的に繰り返す設計では、ネットワーク帯域の枯渇およびストレージコストの増大が避けられず、RPO（目標復旧時点）の短縮を著しく阻害します。

Proxmox Backup Server（PBS）は、データ転送の最適化とストレージ使用量の削減を目的として設計されたバックアップソリューションです。本稿では、PBSの内部アーキテクチャ、重複排除のメカニズム、暗号化境界における制約、および運用トラブルシューティングについて整理します。

## 差分転送とChunkベース重複排除アーキテクチャ

PBSは、QEMU dirty bitmapsを活用した差分転送機構を備えています。変更されたブロックのみを検出して転送するため、帯域幅の消費を大幅に抑制できます。

```
+-----------------------------------------------------------------------+
|                     Incremental Backup Workflow                       |
+-----------------------------------------------------------------------+
|  Proxmox VE (Client Side)                                             |
|   1. Track modified blocks (QEMU dirty bitmaps)                       |
|   2. Split modified data into chunk payload                           |
|   3. Encrypt / Compress locally                                       |
|                                                                       |
|                     === Network Bandwidth Transit ===                 |
|                       (Transmits ONLY new chunks)                     |
|                                 ||                                    |
|                                 \/                                    |
|  Proxmox Backup Server (Datastore)                                    |
|   4. Deduplicate against existing chunk catalog                       |
|   5. Write new chunks &amp; update snapshot manifest index                |
+-----------------------------------------------------------------------+
```

バックアップデータは、平均約4MBの可変サイズChunkに分割され、各Chunkに対してSHA-256ハッシュが算出されます。

### 重複排除の動作原則

* <b>参照カウントによる最適化</b>: 同一データストア内にすでに存在するChunkハッシュが検出された場合、既存Chunkの参照カウント（インデックスマニフェスト）のみを更新し、実データの重複書き込みを行いません。
* <b>マルチVM環境における効果</b>: 同一のベースOSイメージを共有する複数VM環境において、重複排除の効果が顕著に現れます。
* <b>データ圧縮</b>: データの圧縮にはZSTDアルゴリズムが採用されています。

### 暗号化境界による重複排除の制約

PBSにおけるクライアントサイド暗号化（AES-256-GCM）を使用する場合、データは転送前にProxmox VEホスト側で暗号化されます。異なる暗号化キーで処理された暗号文は、元データが同一であっても暗号解読不能な異なるハッシュ値を生成するため、<b>異なるキー間で重複排除は機能しません</b>。マルチテナント設計時には、セキュリティ分離と重複排除率のトレードオフを考慮する必要があります。

## マニフェストインデックスとLive Restore

従来の増分バックアップとは異なり、PBSはバックアップポイントごとに独立したマニフェストファイルを保持します。

```
+-----------------------------------------------------------------------+
|                     Manifest Indexing Architecture                    |
+-----------------------------------------------------------------------+
|  Snapshot Index (Point-in-Time)                                       |
|   |-- Pointer -&gt; Chunk #00123 (Base OS data)                          |
|   |-- Pointer -&gt; Chunk #04567 (Application binary)                    |
|   |-- Pointer -&gt; Chunk #89012 (Modified DB block)                     |
+-----------------------------------------------------------------------+
```

復元時には差分チェーンを順次適用する必要がなく、マニフェストが参照するChunkを単一パスで直接読み出すことで、任意のリストアポイントへアクセス可能です。

また、QEMU VMに対する<b>Live Restore</b>機能により、全データのリストア完了を待たずにVMを即座に起動できます。ゲストOSが未転送領域へアクセス要求を出した際、該当するChunkがネットワーク経由で優先的に取得・割り当てられます。

## データ整合性検証（Verification）

サイレントデータ破損（Bit Rot）やストレージ障害に対応するため、PBSは定期的な検証ジョブ（Verification Tasks）を実行します。

* <b>非暗号化Chunk</b>: SHA-256ハッシュの再計算による検証。
* <b>暗号化Chunk</b>: PBSサーバー側は復号キーを保持しないため、データ構造のチェックサム（CRC-32）による完全性確認を実施。

## Troubleshooting

PBS運用中に発生する代表的な障害パターンと、その対処手順を示します。

### 1. 暗号化キーミスマッチによる重複排除率の低下

* <b>事象</b>: 複数のVMで同一のOSイメージを使用しているにもかかわらず、ストレージ消費量が減少せず重複排除が効かない。
* <b>原因</b>: 異なるPVEノードまたはジョブで個別の暗号化キーが指定されており、Chunkのハッシュが一致していない。
* <b>対策</b>: 同一テナントまたは同一セキュリティ境界内のVMグループに対して、同一のバックアップキーを共有設定する。

```bash
proxmox-backup-client key create /etc/pve/priv/storage/pbs-shared-key.enc
pvesm set pbs-datastore --encryption-key /etc/pve/priv/storage/pbs-shared-key.enc
```

### 2. Live Restore実行時のディスクI/Oおよびネットワークボトルネック

* <b>事象</b>: Live RestoreでVMを起動した直後、ゲストOS内部でI/O Waitが高騰しサービス応答が低下する。
* <b>原因</b>: ゲストOSの起動プロセスやランタイムアクセスが集中し、PBSデータストアからのオンデマンドChunk取得が帯域・IOPSの上限に達している。
* <b>対策</b>: PBSとPVE間のネットワーク帯域を10GbE以上に確保し、PBSのデータストアにNVMe/SSDアレイを採用する。緊急時以外は通常のバックグラウンドリストアの利用を検討する。

### 3. VerificationジョブによるCorrupt Chunkの検出

* <b>事象</b>: 定期検証ジョブにて `verification failed: chunk does not match integrity check` エラーがログに記録される。
* <b>原因</b>: ストレージメディアのデータ劣化またはネットワーク書き込み時のパケット破損。
* <b>対策</b>: 破損マニフェストおよびChunkを特定し、リモート同期（Sync Job）または最新バックアップによる置き換えを実施する。

```bash
proxmox-backup-manager datastore verify datastore1
proxmox-backup-manager task log UPID:pbs-server:00001234:00005678:datastore1
```

## 運用検証ログプロトコル

PBSノードにおけるデータストア状況およびポートリスニングの検証ログ例を以下に示します。

```text
# proxmox-backup-manager datastore status datastore1
┌────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
│ Name       │ Total        │ Used         │ Available    │ History      │
╞════════════╪══════════════╪══════════════╪══════════════╪══════════════╡
│ datastore1 │ 1.96 TiB     │ 412.50 GiB   │ 1.55 TiB     │ Deduplication│
└────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
Deduplication Factor: 3.42x

# ss -tulpn | grep proxmox-backup
tcp   LISTEN 0      4096                *:8007            *:*    users:(("proxmox-backup-",pid=1240,fd=6))

# proxmox-backup-client status --repository user@pbs!realm@pbs-server:datastore1
┌────────────────┬──────────────────────────────────────────┐
│ Field          │ Value                                    │
├────────────────┼──────────────────────────────────────────┤
│ datastore      │ datastore1                               │
│ total          │ 2153922822144 (1.96 TiB)                 │
│ used           │ 442918502400 (412.50 GiB)                │
│ avail          │ 1711004319744 (1.55 TiB)                 │
└────────────────┴──────────────────────────────────────────┘
```

## Operational Notes

Proxmox Backup Serverは、Chunkベースの重複排除と差分転送により、ストレージ効率とリストア速度の両立を実現します。ただし、クライアント暗号化の適用方針、ネットワーク帯域の確保、および定期的なVerificationジョブの自動化を行わなければ、障害発生時の迅速な復旧を阻害する要因となります。アーキテクチャの特性を理解した設計と事前検証を推奨します。
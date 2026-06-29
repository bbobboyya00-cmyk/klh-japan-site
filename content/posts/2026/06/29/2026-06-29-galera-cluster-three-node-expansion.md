---
title: "MariaDB Galera Clusterを2ノードから3ノードへ拡張しスプリットブレインを防ぐクォーラム設計"
slug: "galera-cluster-three-node-expansion"
date: 2026-06-29T11:53:20+09:00
draft: false
image: ""
description: "MariaDB Galera Clusterを2ノードから3ノードへ拡張し、クォーラムを最適化してスプリットブレインを防ぐための具体的な手順とトラブルシューティングを解説します。"
categories: ["Linux System Admin"]
tags: ["mariadb-galera-cluster", "quorum", "mariabackup", "sst-synchronization", "split-brain"]
author: "K-Life Hack"
---

# MariaDB Galera Cluster: 2ノードから3ノードへの拡張による高可用性の実現

データベースの可用性を担保する上で、マルチマスター構成は強力なアプローチですが、設計段階での考慮不足により2ノード構成で運用を開始してしまうケースがあります。しかし、2ノード構成のMariaDB Galera Clusterは、ネットワーク分断が発生した際にどちらのノードも過半数（クォーラム）を維持できず、スプリットブレインを防ぐためにクラスタ全体が書き込みを停止するリスクを常に抱えています。この可用性のボトルネックを解消し、耐障害性を向上させるためには、3ノード構成への拡張が不可欠です。本稿では、既存の2ノード構成から3ノード構成へ安全に拡張するための具体的な手順と、大容量データ同期（SST）における注意点について解説します。

## クォーラムの設計とSST方式の選定

Galera Clusterにおけるクォーラム（合意形成）は、クラスタの整合性を維持するための基盤です。2ノード構成では、1台のノードが停止またはネットワークから離脱した場合、残されたノードの割合は50%となり、過半数（&gt;50%）を満たせなくなります。結果として「Primary Component」状態が失われ、データベースはクエリの受付を停止します。一方、3ノード構成であれば、1台のノードが停止しても残りの2ノード（66.7%）で過半数を維持できるため、サービスを無停止で継続可能です。

新規ノード（Joiner）がクラスタに参加する際、既存ノード（Donor）からデータを同期するプロセスをSST（State Snapshot Transfer）と呼びます。rsyncは標準的なファイル同期ツールですが、同期中にDonorノードのテーブルロックが発生する「コールド転送」となるため、本番環境での利用には適しません。これに対し、mariabackupはMariaDBが提供するオンラインバックアップツールであり、Donorノードのブロックを最小限に抑えた非同期転送が可能です。💡 1Gbpsのネットワーク帯域において、1.1 TBのデータを同期する場合、mariabackupを使用しても約3.5時間の同期時間を要するため、事前の帯域設計と時間枠の確保が必要です。

## Phase 1: ストレージの準備と環境構築

データベースの肥大化に備え、`/var/lib/mysql` を大容量パーティション（`/home/mysql`）にマウントします。

```bash
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql
sudo restorecon -Rv /var/lib/mysql
```

次に、バインドマウントを実行し、再起動後も維持されるよう `/etc/fstab` に設定を追加します。

```bash
sudo mount --bind /home/mysql /var/lib/mysql
```

/etc/fstab` の末尾に以下の行を追記します。

```text
/home/mysql     /var/lib/mysql     none    bind  0 0
```

マウント状態を確認します。

```bash
df -h /var/lib/mysql
findmnt /var/lib/mysql
```

データベース初期化を実行し、サービスを有効化します。

```bash
sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql
sudo systemctl enable mariadb
sudo systemctl start mariadb
```

ファイアウォールで以下のポートを開放します。3306（クライアント接続用）、4567（Galera Cluster レプリケーション用 TCP/UDP）、4568（IST用）、4444（SST用）の各通信を許可する必要があります。

## Phase 2: ソフトウェアインストールとクラスタ設定

クラスタ内の整合性を保つため、すべてのノードで同一のMariaDBバージョン（本環境では 10.11.4）を使用します。既存のDB1およびDB2ノードで、SST実行用の専用ユーザーを作成します。

```sql
CREATE USER 'sstuser'@'localhost' IDENTIFIED BY 'your_secure_password';
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'sstuser'@'localhost';
FLUSH PRIVILEGES;
```

すべてのノードの `/etc/my.cnf.d/server.cnf` を編集し、SST方式を `mariabackup` に変更します。

```ini
[mariadb]
wsrep_sst_method=mariabackup
wsrep_sst_auth=sstuser:your_secure_password
```

設定を反映するため、既存のDB1、DB2を1台ずつ順番に再起動します。

```bash
sudo systemctl restart mariadb
```

## Phase 3: 3番目のノード（DB3）の追加

新規ノード（DB3）は、クリーンな状態からSSTを開始する必要があるため、データディレクトリを空にします。

```bash
sudo systemctl stop mariadb
sudo rm -rf /var/lib/mysql/*
sudo chown -R mysql:mysql /var/lib/mysql
```

同期開始前に、ポート4444の疎通確認を行います。DB3（Joiner）側で待機します。

```bash
sudo dnf install -y nmap-ncat
nc -l 4444
```

DB2（Donor）側からテストデータを送信します。

```bash
echo test | nc -v <db3_ip_address> 4444
```

疎通が確認できたら、DB3のMariaDBサービスを起動して同期を開始します。

```bash
sudo systemctl start mariadb
```

## Phase 4: モニタリングとトラブルシューティング

1.1 TBのデータ同期中は、ターミナルが応答を停止したように見えます。別セッションから以下のコマンドで進捗を監視します。ログの監視およびディスク容量の増加を確認することで、同期が正常に進行しているかを判断します。

```bash
sudo journalctl -u mariadb.service -n 300 --no-pager -l

```bash
watch -n 5 'date; du -sh /var/lib/mysql; df -h /var/lib/mysql'
```

## Troubleshooting

⚠️ SST実行時にDonor側で認証エラーが発生する場合、`sstuser` のホスト制限や権限付与が正しく認識されていない可能性があります。その場合は、一度ユーザーを削除して再作成します。

```sql
DROP USER 'sstuser'@'localhost';
CREATE USER 'sstuser'@'localhost' IDENTIFIED BY 'your_secure_password';
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'sstuser'@'localhost';
FLUSH PRIVILEGES;
```

ローカルソケット経由での接続テストを実行し、認証が正常に通るか確認します。

```bash
sudo mariadb -usstuser -p --socket=/var/lib/mysql/mysql.sock -e "SELECT 1;"
```

## Operational Verifications

同期完了後、クラスタのステータスおよびポートのリスン状態を確認します。

```text
$ mariadb -u root -p -e "show status like 'wsrep_cluster_size';"
+--------------------+-------+
| Variable_name      | Value |
+--------------------+-------+
| wsrep_cluster_size | 3     |
+--------------------+-------+

$ mariadb -u root -p -e "show status like 'wsrep_local_state_comment';"
+---------------------------+--------+
| Variable_name             | Value  |
+---------------------------+--------+
| wsrep_local_state_comment | Synced |
+---------------------------+--------+

$ ss -tulpn | grep -E '3306|4567|4568|4444'
tcp   LISTEN 0      150          0.0.0.0:3306       0.0.0.0:*    users:(("mariadbd",pid=1234,fd=19))
tcp   LISTEN 0      128          0.0.0.0:4567       0.0.0.0:*    users:(("mariadbd",pid=1234,fd=15))
tcp   LISTEN 0      128          0.0.0.0:4568       0.0.0.0:*    users:(("mariadbd",pid=1234,fd=17))
tcp   LISTEN 0      128          0.0.0.0:4444       0.0.0.0:*    users:(("mariadbd",pid=1234,fd=16))
```

## Lessons Learned

2ノード構成から3ノード構成への拡張により、スプリットブレインのリスクを排除し、クォーラムを維持した高可用性データベース基盤が確立されました。大容量データの同期においては、rsyncによるテーブルロックを避け、mariabackupによるノンブロッキングなSSTを選択することが、本番稼働中のサービス影響を最小限に抑えるための鍵となります。また、ネットワーク帯域とディスクI/Oの監視を並行して行うことで、同期プロセスの異常を早期に検知することが可能になります。</db3_ip_address>
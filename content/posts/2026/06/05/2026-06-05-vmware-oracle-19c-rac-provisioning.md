---
title: "VMware環境における2ノードOracle 19c RACのプロビジョニングと共有ストレージ設定"
slug: "vmware-oracle-19c-rac-provisioning"
date: 2026-06-05T18:12:54+09:00
draft: false
image: ""
description: "VMware仮想化プラットフォーム上に2ノードのOracle 19c RAC環境を構築するための、OS設定、共有ディスク、ASMLib、Grid Infrastructure初期設定の技術ノート。"
categories: ["Linux System Admin"]
tags: ["oracle-19c", "oracle-rac", "vmware-workstation", "asmlib", "grid-infrastructure"]
author: "K-Life Hack"
---

# VMware環境における2ノードOracle 19c RACのプロビジョニング手順

本稿では、VMware仮想化プラットフォーム上に2ノードのOracle 19c Real Application Clusters (RAC) データベース環境を構築するための、仮想マシンの作成、OS設定、共有ストレージ構成、ASMLibのプロビジョニング、およびGrid Infrastructureの初期セットアップ手順について記述します。

## 1. 仮想マシンのプロビジョニング (ノード1: ORA191)

最初のノード（ホスト名: <b>ORA191</b>）をベースライン仮想マシンとして作成します。

### 1.1. ハードウェア仕様およびVM設定

* <b>VM名</b>: `ORA191`
* <b>プロセッサ</b>: <b>8 vCPU</b>（並列処理およびクラスタのオーバーヘッドに対応するため）
* <b>メモリ</b>: <b>12 GB</b>（Oracle Grid InfrastructureおよびDatabaseインスタンスの最小要件を満たすため）
* <b>ネットワーク</b>: 1次ネットワークアダプタは外部接続（パッケージダウンロード用）のために<b>NAT</b>に設定
* <b>I/Oコントローラ</b>: LSI Logic SAS（推奨デフォルト）
* <b>仮想ディスクタイプ</b>: <b>SCSI</b>
* <b>ディスク容量</b>: 
* システム領域として<b>50 GB</b>の単一仮想ディスクファイル（`.vmdk`）を割り当て
* 💡 データベース作成やパッチ適用時の容量不足を防ぐため、実際の検証環境では<b>100 GB</b>以上の割り当てを推奨します。
* ディスクは「単一ファイルとして格納」を選択し、パフォーマンス向上のために事前割り当て（Pre-allocate）オプションの適用を検討します。

---

## 2. OSのインストールと基本設定

Oracle LinuxまたはCentOSを仮想マシンにインストールします。

### 2.1. ローカリゼーションとソフトウェア選択

* <b>言語</b>: English (United States)
* <b>日付と時刻</b>: タイムゾーンを <b>Asia/Seoul</b> に設定し、システムクロックを同期
* <b>ソフトウェア選択</b>: OUIやGrid Setupなどのグラフィカルツールを使用するため、<b>Server with GUI</b> を選択。さらに以下のパッケージグループを追加します。
* <b>KDE</b>（または任意のデスクトップ環境）
* <b>Compatibility Libraries</b>
* <b>Development Tools</b>
* <b>System Administration Tools</b>

### 2.2. 手動ディスクパーティショニング

50 GBの仮想ディスク（`sda`）に対して手動パーティショニングを実行します。

#### パーティション構成:

1. `/boot`: <b>1000 MB</b>（標準パーティション、`ext4` または `xfs`）
2. `swap`: <b>24000 MB</b>（24 GB、12 GBのRAM要件に対応するため）
3. `/`（ルート）: <b>残りの全容量</b>

⚠️ パーティショニング時に既存のパーティションテーブルを消去する警告が表示される場合がありますが、新規インストールの場合はそのまま進行して問題ありません。

### 2.3. ネットワークとホスト名の設定

ネットワーク設定画面で、プライマリインターフェース（`ens33`）の「Configure」を選択します。

1. <b>Generalタブ</b>: <b>"Automatically connect to this network when it is available"</b> にチェックを入れ、起動時に自動接続されるようにします。
2. <b>接続優先度</b>: 優先度（Connection Priority）はデフォルトの `0` のままとします。
3. <b>ホスト名</b>: 静的ホスト名を `ora191` に設定し、適用します。

---

## 3. OSインストール後のカスタマイズ

### 3.1. VMware共有フォルダの設定
ホストOSとゲストOS間でのインストールメディア等のファイル転送を容易にするため、VMwareの設定から「Shared Folders」を「Always enabled」に設定し、ホスト側のディレクトリをマウントします。

### 3.2. Oracle Pre-installation RPMの実行

`oracle-database-preinstall-19c` パッケージを使用して、カーネルパラメータ、リソース制限（limits.conf）、および必要なOSユーザーとグループの作成を自動化します。パッケージマネージャー（`yum`）がバックグラウンドプロセスによってロックされている場合は、以下の手順でプロセスを終了させてから実行します。

```bash
rm -f /var/run/yum.pid
yum install -y oracle-database-preinstall-19c
```

### 3.3. ユーザーおよびグループのカスタマイズ

プリインストールRPMによって作成された `oracle` ユーザーに加え、Grid Infrastructure用の `grid` ユーザーを手動で作成し、グループ構成を調整します。

```bash
groupadd -g 54321 oinstall
groupadd -g 54322 dba
groupadd -g 54323 oper
useradd -u 1200 -g oinstall -G dba,oper grid
usermod -u 1201 -g oinstall -G dba,oper oracle
```

#### 設定の確認:

`id oracle` コマンドを実行し、マッピングが正確に行われているか確認します。
* `uid=1201(oracle)`
* `gid=54321(oinstall)`
* `groups=54321(oinstall),54322(dba),54323(oper)`

---

## 4. 環境変数とシェル制限の設定

### 4.1. Oracleユーザーの環境変数 (`/home/oracle/.bash_profile`)
`oracle` ユーザーの `.bash_profile` に以下の設定を追加します。

```bash
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/product/19.3.0/dbhome_1
export ORACLE_SID=ORA191
export PATH=$ORACLE_HOME/bin:$PATH
umask 022
```

* `ORACLE_SID`: 2ノードRACではノードごとに一意である必要があります。
* `umask 022`: 新規作成されるファイルおよびディレクトリのデフォルト権限を制御します。

### 4.2. Gridユーザーの環境変数 (`/home/grid/.bash_profile`)

`grid` ユーザーの `.bash_profile` に以下の設定を追加します。

```bash
export ORACLE_BASE=/u01/app/grid
export ORACLE_HOME=/u01/app/19.3.0/grid
export ORACLE_SID=+ASM1
export PATH=$ORACLE_HOME/bin:$PATH
umask 022
```

* `ORACLE_SID`: ノード1のASMインスタンス識別子として `+ASM1` を指定します。

---

## 5. ディレクトリ構造の作成と権限設定

`root` ユーザーでログインし、マウントポイントを作成して所有権と権限を割り当てます。

```bash
mkdir -p /u01/app/19.3.0/grid
mkdir -p /u01/app/grid
mkdir -p /u01/app/oracle
chown -R grid:oinstall /u01
chown -R oracle:oinstall /u01/app/oracle
chmod -R 775 /u01
```

---

## 6. ネットワーク設計と名前解決

### 6.1. インターフェースの確認
`ip addr` コマンドでプライマリインターフェースの状態を確認します。

```bash
ip addr show ens33
```
`<up,lower_up>` フラグにより、物理層および論理層がアクティブであることを確認します。

### 6.2. 静的な名前解決設定 (`/etc/hosts`)

DNSサーバーを使用しない環境向けに、両ノードの `/etc/hosts` に以下のマッピングを追加します。

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

* <b>Private IP</b>: ノード間のインターコネクトおよびCache Fusion専用の帯域です。
* <b>Virtual IP (VIP)</b>: Oracle Clusterwareが管理する高可用性IP。
* <b>SCAN (Single Client Access Name)</b>: クライアントがクラスタへ接続するための共通エントリポイントです。

### 6.3. ホスト名と時刻同期の設定

静的ホスト名を設定し、不要なファイアウォールを無効化します。また、ノード間の時刻ズレによるクラスタ強制終了（Eviction）を防ぐため、NTPを設定します。

```bash
hostnamectl set-hostname ora191
systemctl stop firewalld
systemctl disable firewalld
```

---

## 7. ノードのクローン作成とノード2の個別設定

シャットダウンしたノード1（`ORA191`）をベースに、ノード2（`ORA192`）をクローン作成します。

### 7.1. フルクローンの実行

1. VMwareの管理メニューから「Clone」を選択します。
2. 「Clone from current state」を選択します。
3. <b>Clone Type</b>: <b>Full Clone</b> を選択します。
4. 移行先VM名を `ORA192` に指定します。

### 7.2. ノード2のホスト名および環境変数のカスタマイズ

`ORA192` を起動し、`root` ユーザーでログインして個別設定を行います。

```bash
hostnamectl set-hostname ora192
```

`grid` ユーザーの `/home/grid/.bash_profile` のASM SIDを修正します。

```bash
sed -i 's/+ASM1/+ASM2/g' /home/grid/.bash_profile
```

`oracle` ユーザーの `/home/oracle/.bash_profile` のデータベースSIDを修正します。

```bash
sed -i 's/ORA191/ORA192/g' /home/oracle/.bash_profile
```

---

## 8. ASMLibのインストール

ASMディスクの管理を容易にするため、<b>両方のノード</b>で以下のパッケージをインストールします。

```bash
yum install -y oracleasm-support kmod-oracleasm
yum install -y oracleasmlib
```

---

## 9. 共有ストレージ設定 (VMware VMXファイルの編集)

Oracle RACでは、両ノードから同時に読み書き可能な共有ディスクが必要です。

### 9.1. ノード1 (`ORA191`) への共有ディスク追加

1. `ORA191` の設定画面から「Add > Hard Disk」を選択。
2. <b>SCSI</b> を選択し、必要な容量を割り当てます。
3. 追加した各ディスクの「Advanced」プロパティを開き、<b>Independent</b> および <b>Persistent</b> にチェックを入れます。

### 9.2. `.vmx` 設定ファイルの編集

両方のVMがロック競合を起こさずに同一ディスクにアクセスできるよう、各ノードの `.vmx` ファイルを編集します。両方のファイルの末尾に以下のパラメータを追加します。

```text
disk.locking = "FALSE"
diskLib.dataCacheMaxSize = "0"
scsi0.sharedBus = "virtual"
```

* `disk.locking = "FALSE"`: VMwareによるディスクロックを無効化します。
* `scsi0.sharedBus = "virtual"`: 複数VM間でのSCSIバス共有を可能にします。

---

## 10. プライベートネットワークアダプタの追加

ノード間のインターコネクト用に、2枚目のネットワークアダプタを追加します。

1. `ORA191` の設定から「Add > Network Adapter」を選択。
2. ネットワーク接続タイプを <b>Host-only</b> に設定。
3. 「Advanced」から「Generate」をクリックし、一意のMACアドレスを生成します。
4. `ORA192` に対しても同様の手順を実行し、必ずMACアドレスを再生成してください。

---

## 11. プライベートネットワークインターフェースの設定 (ens36)

### 11.1. ノード1 (`ORA191`) の設定
IPv4設定を「Manual」に変更し、以下のように設定します。
* <b>Address</b>: `172.16.40.11`
* <b>Netmask</b>: `255.255.255.0`

### 11.2. ノード2 (`ORA192`) の設定

* <b>Address</b>: `172.16.40.12`
* <b>Netmask</b>: `255.255.255.0`

---

## 12. ASMディスクのプロビジョニング

### 12.1. ASMLibの初期化 (両ノード)
<b>両方のノード</b>で `root` ユーザーとして初期化ユーティリティを実行します。

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

### 12.2. ディスクパーティショニング (ノード1のみ)

追加した共有ディスクを、<b>ノード1のみ</b>でパーティショニングします。

```bash
fdisk /dev/sdb
# n -> p -> 1 -> default -> default -> w
```

### 12.3. ASMディスクの作成 (ノード1のみ)

```bash
oracleasm createdisk ASMDISK01 /dev/sdb1
```

### 12.4. ノード2でのディスクスキャン

作成したディスクをノード2に認識させるため、スキャンを実行します。

```bash
# Node 1
oracleasm scandisks
# Node 2
oracleasm scandisks
oracleasm listdisks
```

---

## 13. Grid Infrastructureのインストール

### 13.1. インストール前処理
DNS競合を防ぐため、<b>両ノード</b>で `avahi-daemon` を停止します。

```bash
systemctl stop avahi-daemon
systemctl disable avahi-daemon
```

ノード1の `grid` ユーザーでインストールメディアを展開します。

```bash
cd $ORACLE_HOME
unzip -q /mnt/hgfs/shared/LINUX.X64_193000_grid_home.zip
```

```bash
./gridSetup.sh
```

### 13.2. セットアップウィザードの要点

1. <b>Cluster Type</b>: <b>Configure a Standalone Cluster</b> を選択。
2. <b>Cluster Node Information</b>: ノード2 (`ora192`, `ora192-vip`) を追加。
3. <b>SSH Connectivity</b>: `grid` ユーザーのパスワードを入力し「Setup」を実行。
4. <b>Network Interface</b>: `ens33` を <b>Public</b>、`ens36` を <b>1st Private</b> に設定。
5. <b>Storage</b>: <b>Use ASM</b> を選択し、Discovery Path を `/dev/oracleasm/disks/*` に設定。

---

## Operational Notes

本手順で構築した環境は、VMware Workstation等のハイパーバイザー上で動作する2ノードRACの最小構成モデルです。実稼働環境への適用にあたっては、共有ストレージの物理的な冗長化（SAN/NASマルチパス設定）や、ネットワークのチーミング（Bonding）を別途検討する必要があります。特に `.vmx` における `disk.locking = "FALSE"` 設定は、Clusterwareが停止している状態で両ノードから直接マウントを行うとデータ破損を招くリスクがあるため、運用管理には細心の注意を払ってください。</up,lower_up>
---
title: "Ubuntu Server基盤における仮想化・認証・ログ管理の統合実装"
slug: "ubuntu-server-infra-integration-guide"
date: 2026-06-01T17:05:16+09:00
draft: false
image: ""
description: "Ubuntu ServerをベースとしたKVM仮想化、DHCP、NTP、NIS/NFS、rsyslog、およびKerberosによる認証統合の初期設定とセキュリティ硬化手順の記録。"
categories: ["Linux System Admin"]
tags: ["kvm", "rsyslog", "kerberos", "nfs-server", "chrony", "ubuntu-server"]
author: "K-Life Hack"
---

# Ubuntu ServerにおけるKVM仮想化基盤とネットワーク統合管理サービスの構築

本稿では、Ubuntu ServerをホストとしたKVM仮想化環境の構築から、ネットワーク基盤サービス（DHCP, NTP）、集中管理（NIS, NFS, rsyslog）、およびKerberosによる認証統合までの実装プロセスを記述します。

## 1. KVM仮想化環境の展開

Linuxカーネル組み込みの仮想化機能であるKVMを利用し、単一の物理サーバ上で複数のVMを運用する基盤を構築します。

### インストールと権限設定

必要なパッケージを導入し、管理ユーザーを`libvirt`グループに追加します。GUIツールである`virt-manager`を正常に動作させるため、D-Busセッション変数のエクスポートが必要です。

```bash
# パッケージのインストール
sudo apt update &amp;&amp; sudo apt -y install qemu-kvm qemu-system libvirt-bin bridge-utils virt-manager

# ユーザー権限の付与
sudo adduser ubuntu libvirt

# D-Busセッションの設定
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
export DBUS_SESSION_BUS_PID=$(pgrep -u $(id -u) dbus-daemon)
```

### VMのデプロイと管理

`virsh`コマンドを用いてハイパーバイザを管理します。ISOイメージからVMを作成し、必要に応じてクローニングを実施します。

```bash
# VMリストの確認
virsh -c qemu:///system list --all

# VMのクローニング例
virt-clone --original win7 --name win7-2 --file /var/lib/libvirt/images/win7-2.qcow2
```

## 2. ネットワーク基盤サービス（DHCP &amp; NTP）

### DHCPによるIP自動割り当て

`192.168.100.0/24`サブネットを定義し、クライアントへの動的IP割り当てを構成します。

```conf
# /etc/dhcp/dhcpd.conf 設定例
subnet 192.168.100.0 netmask 255.255.255.0 {
  range 192.168.100.100 192.168.100.110;
  option domain-name-servers 8.8.8.8;
  option routers 192.168.100.1;
  default-lease-time 600;
  max-lease-time 7200;
}
```

### Chronyによる時刻同期

ログの整合性維持のため、Chronyを導入します。外部NTPサーバとの同期を確立し、ファイアウォールでNTPポートを開放します。

```bash
# chronyの同期確認
chronyc tracking

# ファイアウォール設定
sudo firewall-cmd --permanent --add-service=ntp
sudo firewall-cmd --reload
```

## 3. NISおよびNFSによる集中管理

NISを用いたユーザーアカウントの集中管理と、NFSによる共有ストレージを構成します。

### NISマスターサーバの設定

ドメイン名を`kahn.edu`に設定し、`ypinit`でデータベースを構築します。

```bash
# NISドメインの設定
sudo ypdomainname kahn.edu

# マップの作成
sudo /usr/lib/yp/ypinit -m
```

### NFS共有の構成

`/etc/exports`にてアクセス権限を定義し、クライアント側でマウントを実施します。

```bash
# /etc/exports
/NFS 192.168.100.204(rw,sync,no_root_squash)
```

## 4. rsyslogによるログ集約

複数のホストからログを収集し、ホスト名およびプログラム名ごとにディレクトリを分離して保存するテンプレートを定義します。

```conf
# /etc/rsyslog.conf サーバ側設定
$template TmplAuth, "/var/log/%HOSTNAME%/%PROGRAMNAME%.log"
$template TmplMsg, "/var/log/%HOSTNAME%/messages.log"

authpriv.* ?TmplAuth
*.warn;authpriv.none;mail.none;cron.none ?TmplMsg
```

クライアント側では、すべてのログをリモートサーバ（`192.168.100.203`）へ転送する設定を行います。

## 5. Kerberos (KDC) 認証統合

チケットベースの認証基盤を構築し、SSHのシングルサインオン（SSO）を実現します。

### KDCの構築とプリンシパル作成

`KAHN.EDU`レルムを定義し、管理ユーザーおよびホストプリンシパルを登録します。

```bash
# プリンシパルの追加
kadmin.local -q "addprinc admin/admin"
kadmin.local -q "addprinc ubuntu"

# ホストキータブの抽出
kadmin.local -q "ktadd host/ubun-1.kahn.edu"
```

### SSH GSSAPI認証の有効化

`/etc/ssh/ssh_config`にて`GSSAPIAuthentication yes`を設定することで、パスワードレスでのログインを可能にします。

## 6. FreeNASによる外部ストレージ連携

FreeNASを導入し、複数のSCSIディスクを束ねたZFSプール（MySHARE）を構築します。LinuxクライアントからNFSマウントを行う際、ロックデーモンの競合を避けるために`nolock`オプションを付与します。

```bash
# クライアント側でのマウント実行
sudo mount -t nfs -o nolock 192.168.100.180:/mnt/MySHARE/MyLIN /mnt/FreeNAS
```

## Operational Notes

*   <b>SELinuxの考慮</b>: ChronyやNISの初期化時にSELinuxが干渉する場合があるため、必要に応じて`setenforce 0`による一時的な緩和とポリシー調整を検討してください。⚠️
*   <b>ネットワーク制約</b>: 現状の構成では単一のネットワークインターフェースに依存しているため、VMのライブマイグレーションには制約が存在します。冗長化が必要な場合は、NICチーミングまたはブリッジ構成の拡張が必要です。🛠️
*   <b>NFS権限</b>: クライアント側のrootユーザーが書き込み権限を保持できるよう、サーバ側の`no_root_squash`設定を適切に管理してください。💡
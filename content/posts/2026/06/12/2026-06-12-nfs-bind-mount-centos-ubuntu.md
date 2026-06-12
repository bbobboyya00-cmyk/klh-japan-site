---
title: "CentOS 7.9環境におけるBind Mountを活用したNFSエクスポート構成"
slug: "nfs-bind-mount-centos-ubuntu"
date: 2026-06-12T14:10:56+09:00
draft: false
image: ""
description: "CentOS 7.9の/root配下にあるデータをUbuntuクライアントへ安全に共有するための、Bind Mountを用いたNFS構成手順とトラブルシューティング。"
categories: ["Linux System Admin"]
tags: ["nfs-utils", "bind-mount", "centos-7", "ubuntu-client", "selinux-policy"]
author: "K-Life Hack"
---

Linuxサーバーの運用において、特定のユーザーディレクトリ（特に/root）配下のデータをNFSで共有する必要が生じることがあります。しかし、/rootディレクトリの厳格なパーミッション設定（700/750）は、NFSクライアントによるディレクトリツリーのトラバースを阻害し、'Permission Denied'を引き起こす主要な要因となります。この制約を回避するために、元データの物理的な場所を変更することなく、NFSエクスポート専用のパスへマッピングする「Bind Mount」戦略を採用した実装手順を詳述します。

## 1. システム構成と設計要件

本構成では、CentOS 7.9上の/root/webapps/dataをソースとし、Ubuntuクライアントからアクセス可能な/srv/nfs/dataへバインドします。これにより、親ディレクトリの権限継承問題を回避しつつ、セキュアなデータ共有を実現します。

* <b>NFS Server:</b> CentOS Linux release 7.9.2009 (192.168.0.100)
* <b>NFS Client:</b> Ubuntu (192.168.0.200)
* <b>Source Path:</b> /root/webapps/data (Restrictive permissions)
* <b>Export Path:</b> /srv/nfs/data (Proxy path)

## 2. サーバー側実装 (CentOS 7.9)

### 2.1. パッケージの導入とディレクトリ準備

まず、NFSサーバー機能を提供するnfs-utilsをインストールし、エクスポート用のエンドポイントを作成します。

```bash
yum install -y nfs-utils
mkdir -p /srv/nfs/data
```

### 2.2. Bind Mountによるパスのマッピング

/root配下のディレクトリを直接エクスポートするのではなく、/srv配下へバインドします。これにより、NFSデーモンは/rootのパーミッション制約を受けずにデータへアクセス可能となります。

```bash
mount --bind /root/webapps/data /srv/nfs/data
```

再起動後もこの設定を維持するため、/etc/fstabに以下のエントリを追加します。

```etc
/root/webapps/data    /srv/nfs/data    none    bind    0 0
```

### 2.3. NFSエクスポート設定

/etc/exportsにて、特定のクライアントIPに対するアクセス権限を定義します。

```etc
/srv/nfs/data    192.168.0.200(rw,sync,no_root_squash,no_subtree_check)
```

* <b>rw:</b> 読み書き権限の付与。
* <b>sync:</b> 書き込み完了後に応答を返すことでデータ整合性を確保。
* <b>no_root_squash:</b> クライアント側のrootユーザーをサーバー側のrootとして扱う設定（運用要件に応じて慎重に検討）。
* <b>no_subtree_check:</b> サブディレクトリのチェックを無効化し、信頼性を向上。

設定反映後、エクスポート状態を確認します。

```bash
exportfs -ra
exportfs -v
```

### 2.4. サービス管理とRPC登録

NFSサービスおよびポートマッパー（rpcbind）を起動します。

```bash
systemctl enable --now rpcbind
systemctl enable --now nfs-server
```

## 3. クライアント側実装 (Ubuntu)

Ubuntuクライアント側では、nfs-commonパッケージを使用してマウントを準備します。

```bash
apt-get update
apt-get install -y nfs-common
mkdir -p /mnt/nfs_data
mount -t nfs 192.168.0.100:/srv/nfs/data /mnt/nfs_data
```

## 4. セキュリティおよびファイアウォール構成

### 4.1. Firewalld設定 (CentOS 7)

NFS、rpc-bind、mountdの各サービスを許可します。

```bash
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

### 4.2. SELinuxの調整

SELinuxが有効な場合、NFS経由のアクセスが拒否されることがあります。適切なコンテキストを付与します。

```bash
setsebool -P nfs_export_all_rw 1
semanage fcontext -a -t public_content_rw_t "/srv/nfs/data(/.*)?"
restorecon -Rv /srv/nfs/data
```

## 5. Troubleshooting

### 5.1. RPC通信エラー (clnt_create: RPC: Unable to receive)
* <b>原因:</b> nfs-serverが未起動、またはファイアウォールでポート2049/111が遮断されている。
* <b>対策:</b> systemctl status nfs-serverを確認し、rpcinfo -pでポートの待機状態を検証してください。

### 5.2. 権限拒否 (Permission Denied)

* <b>原因:</b> Bind Mountが正しく行われていない、または/etc/exportsのIP制限が不適切。
* <b>対策:</b> サーバー側でmount | grep dataを実行し、バインド状態を再確認してください。

## 6. 実装検証ログ

構成完了後の正常動作を示すプロトコルログを以下に記します。

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

NFS運用において、/rootなどの特権ディレクトリ配下のデータを共有する際は、物理パスを直接公開するのではなく、本稿で示したBind Mountによる抽象化レイヤーを設けることが、セキュリティと運用柔軟性の両立において極めて有効です。特にCentOS 7系では、SELinuxポリシーとNFSの相互作用により複雑なトラブルが発生しやすいため、マウントポイントのコンテキスト管理を徹底することが推奨されます。
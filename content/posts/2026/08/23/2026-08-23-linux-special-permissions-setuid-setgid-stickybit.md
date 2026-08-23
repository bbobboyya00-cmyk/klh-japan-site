---
title: "Linuxにおける特殊パーミッション（SetUID・SetGID・Sticky Bit）のカーネル動作と権限制御"
slug: "linux-special-permissions-setuid-setgid-stickybit"
date: 2026-08-23T10:10:06+09:00
draft: false
image: ""
description: "Linuxのst_mode構造体（16ビット）におけるSetUID、SetGID、Sticky Bitのカーネルレベル動作メカニズムとRUID/EUID権限遷移を解説します。"
categories: ["Linux System Admin"]
tags: ["setuid", "setgid", "sticky-bit", "st_mode", "euid", "chmod", "linux-security"]
author: "K-Life Hack"
---

Linux環境において複数ユーザーが単一のシステムリソースを共有して動作させる際、標準的なパーミッション構造（Owner/Group/Othersのrwx）のみでは特権操作の委譲やディレクトリ内での安全なアクセス制御を達成できません。例えば、一般ユーザーが自身のパスワードを変更する際、通常はroot権限しか書き込み権限を持たない<code>/etc/shadow</code>ファイルを更新する必要があります。こうした運用上の要件を満たすため、Linuxカーネルは16ビットのファイルモード構造（<code>st_mode</code>）の内部に特殊パーミッションビット（SetUID、SetGID、Sticky Bit）を組み込んでいます。

## st_mode（16ビット整数マスク）の構造

ファイルシステムにおいて、パーミッション情報はinode内部の<code>st_mode</code>構造体（16ビット整数）として保持されています。管理者が<code>chmod 755</code>といったコマンドを実行する際、カーネル内部では省略された最上位の8進数を含む4桁（<code>0755</code>）として評価されます。

```
+-------------------+----------------------+---------------------------------------+
| File Type Bitmask | Special Bits Bitmask |  Standard Permission Bitmask (9 bits) |
|      (4 bits)     |       (3 bits)       | User (3b) | Group (3b) | Others (3b)  |
+-------------------+----------------------+-----------+------------+--------------+
| Bit 15 - Bit 12   |  Bit 11 - Bit 9      | Bit 8 - 6 | Bit 5 - 3  | Bit 2 - 0    |
+-------------------+----------------------+-----------+------------+--------------+
```

<b>File Type Bitmask (Bit 15–12)</b>:
* `-` : Regular File
* `d` : Directory
* `c` : Character Device
* `b` : Block Device
* `s` : Socket
* `l` : Symbolic Link
* `p` : Named Pipe (FIFO)
* <b>Special Permission Bitmask (Bit 11–9)</b>:
* <b>Bit 11 (04000)</b> : SetUID
* <b>Bit 10 (02000)</b> : SetGID
* <b>Bit 9 (01000)</b> : Sticky Bit
* <b>Standard Permission Bitmask (Bit 8–0)</b>:
* Owner / Group / Others にそれぞれ割り当てられる `rwx` ビット

## SetUID (Set User ID - Octal 4000)

SetUIDが設定されたバイナリ実行ファイルを実行すると、カーネルはプロセスの実行権限（Effective User ID: EUID）を、コマンドを起動したユーザー（Real User ID: RUID）ではなく、該当ファイルの所有者IDに昇格させます。

```bash
chmod 4755 executable_file
# または
chmod u+s executable_file
```

<code>ls -l</code> 出力での表記において、所有者の実行権限（<code>x</code>）位置に表示されます。実行権限が付与されている場合は小文字の <code>s</code>（<code>-rwsr-xr-x</code>）、実行権限が不完全な場合は大文字の <code>S</code>（<code>-rwSr-xr-x</code>）として表示されます。

<code>/usr/bin/passwd</code> は代表的なSetUIDの適用品です。一般ユーザーが実行した場合でも、プロセス動作中は一時的にEUIDが <code>root</code> に変更されるため、特権ファイルである <code>/etc/shadow</code> の更新が可能となります。

## SetGID (Set Group ID - Octal 2000)

SetGIDはファイルおよびディレクトリのグループ所有権に対して動作します。

* <b>実行ファイルに対する適用</b>: 実行時にプロセスの Effective Group ID (EGID) をファイルの所有グループIDへ変更します。
* <b>ディレクトリに対する適用</b>: ディレクトリ内で新規作成されるすべてのファイルやサブディレクトリに対し、作成者のプライマリグループではなく、親ディレクトリの所有グループIDを強制的に継承させます。

```bash
chmod 2775 shared_directory
# または
chmod g+s shared_directory
```

<code>/var/mail</code> ディレクトリ（<code>drwxrwsr-x</code>）など、特定のサービスグループ（<code>mail</code>グループ）へ新規生成ファイルの書き込み権限を継承させる構成で広く利用されます。

## Sticky Bit (Octal 1000)

Sticky Bit（Restricted Deletion Flag）は、全ユーザーに書き込み権限（<code>777</code>）が付与された共有ディレクトリにおいて、他人の作成したファイルを意図せず（または悪意を持って）削除・名前変更できないよう制限するフラグです。

```bash
chmod 1777 shared_tmp
# または
chmod +t shared_tmp
```

Sticky Bitが設定されたディレクトリ内では、以下のいずれかに該当するユーザーのみがファイルの削除または名前変更を実行できます。

1. 該当ファイルの所有者
2. 該当親ディレクトリの所有者
3. スーパーユーザー（`root`）

<code>/tmp</code> ディレクトリ（<code>drwxrwxrwt</code>）はこの設定の代表例です。

## カーネルレベルのプロセス識別子

Linuxカーネルはプロセスを実行する際、権限検証のために以下の識別子を保持します。

* <b>PID (Process ID)</b>: プロセスの固有識別子
* <b>RUID (Real User ID)</b>: プロセスを起動した実際のユーザーID
* <b>EUID (Effective User ID)</b>: リソースアクセス時にカーネルが参照するアクセス権限判定用のユーザーID
* <b>RGID (Real Group ID)</b>: プロセスを起動したユーザーのプライマリグループID
* <b>EGID (Effective Group ID)</b>: アクセス権限判定時にカーネルが参照するグループID

SetUID / SetGID は、この EUID / EGID を一時的に付け替えることで権限昇格を実現します。

## Troubleshooting

### 1. `nosuid` マウントオプションによる権限昇格の無効化

⚠️ ファイルにSetUID/SetGIDフラグ（<code>4755</code>等）が正しく付与されているにもかかわらず、実行時にアクセス拒否（Permission Denied）が発生する場合、該当ファイルシステムが <code>nosuid</code> オプション付きでマウントされている可能性があります。

<code>nosuid</code> が有効なパーティション上では、カーネルは安全上の理由からSetUIDおよびSetGIDビットを完全に無視します。

💡 検証および対処フロー:

```bash
$ findmnt -n -o OPTIONS -T /path/to/binary
rw,nosuid,nodev,relatime
```

上記の出力のように <code>nosuid</code> が含まれている場合、<code>/etc/fstab</code> の設定変更または手動の再マウントで <code>exec,suid</code> を許可する必要があります。

```bash
sudo mount -o remount,suid /path/to/mountpoint
```

### 2. 大文字 `S` または `T` フラグの表示問題

⚠️ <code>ls -l</code> コマンド実行時に <code>-rwSr-xr-x</code> や <code>drwxrwxr-T</code> のように大文字で表記される場合、特殊パーミッション（SetUID/SetGID/Sticky Bit）が設定されていますが、対応する実行権限（<code>x</code>）が付与されていません。この状態では特権実行および正しいディレクトリトラバースが行われません。

🛠️ 解決手順（実行権限の再付与）:

```bash
# SetUIDにおける大文字Sの修正
chmod u+x /path/to/binary

# Sticky Bitにおける大文字Tの修正
chmod o+x /path/to/directory
```

## 監査・検証コマンドログ

💡 システム内の特殊パーミッション設定状況を確認するためのターミナル実行例です。

```text
$ ls -ld /usr/bin/passwd /var/mail /tmp
-rwsr-xr-x. 1 root root 68208 Jul 16  2022 /usr/bin/passwd
drwxrwsr-x. 2 root mail  4096 Aug 23 10:00 /var/mail
drwxrwxrwt. 15 root root  4096 Aug 23 10:00 /tmp

$ find /usr/bin /usr/sbin -perm -4000 -type f -ls
 68208   68 -rwsr-xr-x   1 root     root        68208 Jul 16  2022 /usr/bin/passwd
140521  144 -rwsr-xr-x   1 root     root       147280 Jan 18  2024 /usr/bin/sudo
210943   52 -rwsr-xr-x   1 root     root        51832 Feb  4  2024 /usr/bin/chfn

$ find /var -perm -2000 -type d -ls
 10482   4 drwxrwsr-x   2 root     mail        4096 Aug 23 10:00 /var/mail

$ findmnt -t ext4,xfs,tmpfs
TARGET SOURCE FSTYPE OPTIONS
/      /dev/sda1 xfs rw,relatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
/tmp   tmpfs  tmpfs rw,nosuid,nodev,seclabel
```

## Configuration Notes

* 🛠️ <b>SetUIDの最小化</b>: 不必要なバイナリへのSetUID付与は、ローカル権限昇格攻撃（Privilege Escalation）の脆弱性につながります。定期的に `find / -perm -4000` を実行してシステム監査を行ってください。
* 💡 <b>Capabilityへの移行</b>: 現代のLinuxシステムでは、バイナリ全体にroot権限を与えるSetUIDに代わり、必要最小限の権限（例: `CAP_NET_BIND_SERVICE`）のみを付与するLinux Capabilities (`setcap` コマンド) の利用が推奨されます。
* ⚠️ <b>Sticky Bitと共有ディレクトリ</b>: NFS等のネットワークファイルシステムを共有する際は、クライアント側のマウント設定およびUID/GIDマッピングが正確に行われているか確認してください。
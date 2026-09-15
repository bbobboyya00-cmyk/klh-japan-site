---
title: "Linux環境におけるPOSIXアクセス権限制御とアカウント管理の運用仕様"
slug: "linux-posix-permission-chown-chmod-management"
date: 2026-09-15T10:09:24+09:00
draft: false
image: ""
description: "Linuxシステムの任意アクセス制御（DAC）におけるchmod/chownによるパーミッション設計、設定ファイル操作、adduser/userdelによるアカウント削除時の動作検証を解説します。"
categories: ["Linux System Admin"]
tags: ["chmod", "chown", "linux-permissions", "userdel", "dac-access-control"]
author: "K-Life Hack"
---

マルチユーザー環境やコンテナ基盤を運用するLinuxインフラストラクチャにおいて、ディレクトリやシステムファイルに対する適切なアクセス制御（DAC: Discretionary Access Control）の設計は、セキュリティ境界を確立する上で不可欠です。パーミッション設定や所有権の定義を誤ると、不審なプロセスによる設定ファイルの改ざんや、一般ユーザーによる機密データの閲覧、アクセス拒否によるアプリケーション停止といった障害に直結します。本稿では、Linuxにおけるアクセス権限の構造、`chmod` および `chown` による権限変更、アカウントのライフサイクル管理と実務におけるトラブルシューティング手順を整理・検証します。

## 設定ファイルの操作とエディタの基本

システム設定ファイル（例: `/etc/passwd`）の確認や編集には、ターミナル上で動作するモードレスなテキストエディタ `nano` が頻繁に使用されます。

### nano エディタの起動と操作

ターゲットファイルを指定してエディタを起動します。

```bash
nano passwd
```

💡 <b>操作およびマニュアルの参照手順</b>

・<b>終了手順</b>: 編集作業完了後、`Ctrl + X` を押下します。変更が存在する場合は保存確認のプロンプトが表示されます。

・<b>ヘルプとマニュアル</b>: コマンドラインオプションの確認およびマニュアルの参照は以下のコマンドで実行します。

```bash
nano --help
man nano
```

※ `man` ページの閲覧を終了する際は `q` キーを押下します。

## ファイル属性・所有権（chown）・アクセス権限（chmod）

Linuxの任意アクセス制御（DAC）は、「所有者（Owner/User）」、「グループ（Group）」、「その他（Others）」の3つの対象クラスに対して、読み取り（`r`）、書き込み（`w`）、実行（`x`）のビットマスクを割り当てることで機能します。

### 主要な管理コマンド

・<b>`chmod` (Change Mode)</b>: ファイルおよびディレクトリのアクセス権限ビット（`r`, `w`, `x`）を変更します。

・<b>`chown` (Change Owner)</b>: ファイルやディレクトリの所有ユーザーおよび所属グループを変更します。

```bash
chown [OWNER].[GROUP] FILENAME_OR_DIRECTORY
# または以下の構文を使用します
chown [OWNER]:[GROUP] FILENAME_OR_DIRECTORY
```

---

## 実務検証シナリオ

### シナリオA: ディレクトリ権限の制限とアクセス拒否の検証

1. <b>ディレクトリの作成と所有権の再割り当て</b>

`master` ユーザーでディレクトリ `dir1` を作成します。デフォルトの `umask 022` が適用される環境では、ディレクトリは `755` (`rwxr-xr-x`) で生成されます。

   ```bash
   mkdir dir1
   sudo chown master:master dir1
   ```

2. <b>パーミッションの絞り込み</b>

`dir1` の権限を変更し、「その他（Others）」クラスのアクセス権限を完全に剥奪します。

   ```bash
   chmod 750 dir1
   ```

・<b>8進数表現の分解 (`750`)</b>:

- 所有者 (`7` -&gt; `rwx`): 読み取り、書き込み、ディレクトリトラバーサル（進入）の全権限。

- グループ (`5` -&gt; `r-x`): 読み取りおよびディレクトリトラバーサル権限。

- その他 (`0` -&gt; `---`): 全権限の剥奪。

3. <b>アクセス拒否の検証</b>

一般ユーザー `user1`（「その他」に該当）へコンテキストを切り替え、ディレクトリへ移動を試みます。

   ```bash
   su - user1
   cd /path/to/dir1
   ```

<b>結果</b>: トラバーサル権限（`x`）が存在しないため、`Permission denied` エラーが発生し進入が拒否されます。

---

### シナリオB: ファイル作成制約と動的な権限変更

1. <b>所有者によるファイル作成</b>

`master` ユーザーコンテキストで `dir1` 内にファイルを作成します。

   ```bash
   touch dir1/test1.txt
   ```

master` は `dir1` に対して `w` および `x` 権限を保持しているため、正常に作成されます。生成されたファイルのデフォルトパーミッションは `664` または `644` となります。

2. <b>非特権ユーザーによるファイル作成の失敗</b>

`user1` アカウントから `dir1` 内へのファイル生成を試みます。

   ```bash
   touch dir1/test2.txt
   ```

<b>結果</b>: `Permission denied` で失敗します。ディレクトリ内に新規エントリを作成するには、親ディレクトリに対して <b>書き込み（`w`）</b> および <b>実行（`x`）</b> の両権限が必要となります。

3. <b>「その他」クラスへの権限拡大</b>

`master` アカウントに戻り、`dir1` のパーミッションを書き換えます。

   ```bash
   chmod 757 dir1
   ```

・<b>8進数表現の分解 (`757`)</b>:

- 所有者 (`7` -&gt; `rwx`): 全権限。

- グループ (`5` -&gt; `r-x`): 読み取り・トラバーサル権限。

- その他 (`7` -&gt; `rwx`): 全権限を許可。

4. <b>再検証</b>

再度 `user1` からファイルを作成します。

   ```bash
   touch dir1/test2.txt
   ```

<b>結果</b>: 作成が正常に完了します。「その他」に付与された `7` ビットにより、`user1` によるディレクトリ構成変更が許可されます。

---

## 記号モード（Symbolic Mode）による詳細指定

8進数表記に加え、特定のフラグのみを追加・削除・設定可能な記号モードも広く利用されます。

### 記号表記の構成成分

| カテゴリ | 記号 | 説明 |
| :--- | :---: | :--- |
| <b>対象クラス</b> | `u` | <b>User</b>: ファイルの所有ユーザー |
| | `g` | <b>Group</b>: ファイルの所有グループ |
| | `o` | <b>Others</b>: その他のユーザー |
| | `a` | <b>All</b>: 全てのクラス (`u`, `g`, `o` の組み合わせ) |
| <b>演算子</b> | `+` | 権限の追加 |
| | `-` | 権限の剥奪 |
| | `=` | 権限の明示的上書き設定 |
| <b>権限フラグ</b> | `r` | 読み取り (Read) |
| | `w` | 書き込み (Write) |
| | `x` | 実行 / ディレクトリ進入 (Execute) |

### 代表的な実行コマンド例

```bash
# 所有者に書き込み権限を追加
chmod u+w filename

# グループとその他に書き込み権限を追加
chmod go+w filename

# 所有者に実行権限、グループ/その他に書き込み権限を同一パスで適用
chmod u+x,go+w filename

# 全クラスの権限を rwx に明示設定
chmod a+rwx filename
```

---

## アカウントの生命周期管理 (`adduser` / `userdel`)

アクセス制御の前提となるユーザー識別子（UID）の管理手順です。

・<b>アカウント作成</b>:

  ```bash
  adduser <username>
  ```

・<b>アカウント削除（基本）</b>:

  ```bash
  userdel <username>
  ```

※上記を実行した場合、`/etc/passwd` や `/etc/shadow` の登録情報のみが破棄され、ホームディレクトリやメールキューは残存します。

・<b>アカウントおよび関連データの完全削除 (`-r` オプション)</b>:

  ```bash
  userdel -r <username>
  ```

⚠️ <b>`-r` オプション指定時の内部処理フロー</b>

1. ユーザーアカウントエントリーの削除

2. ホームディレクトリ（`/home/<username>`）の再帰的破棄

3. スプール内の未処理メール（`/var/mail/<username>` など）の削除

---

## Troubleshooting

### 1. ディレクトリの実行権限（`x`）不足によるパス解決失敗
ファイル自体のパーミッションが `644` (`rw-r--r--`) であっても、上位ディレクトリに `x` 権限（トラバーサル権限）が付与されていない場合、プロセスはファイルへ到達できず `Permission denied` が返されます。

🛠️ <b>対処法</b>: 親ディレクトリ構造の権限を確認し、最小限の実行権限を付与します。

  ```bash
  chmod o+x /path/to/parent_directory
  ```

### 2. `userdel -r` 実行時のプロセス残存エラー

対象ユーザーがバックグラウンドプロセスを所有している場合、`userdel` コマンドは失敗します。

⚠️ <b>現象例</b>:

`userdel: user <username> is currently used by process <pid>`

🛠️ <b>対処手順</b>: 該当ユーザーのプロセスを停止してから削除を実行します。

  ```bash
  pkill -u <username>
  userdel -r <username>
  ```

---

## Operational Notes

本環境でのディレクトリ設定、ユーザー切り替え、権限変更および結果検証時のターミナルログ出力例です。

```text
master@edge-node:~$ mkdir dir1
master@edge-node:~$ sudo chown master:master dir1
master@edge-node:~$ chmod 750 dir1
master@edge-node:~$ ls -ld dir1
drwxr-x--- 2 master master 4096 Sep 15 10:00 dir1

master@edge-node:~$ su - user1
Password: 
user1@edge-node:~$ cd /home/master/dir1
-bash: cd: /home/master/dir1: Permission denied

user1@edge-node:~$ exit
logout

master@edge-node:~$ chmod 757 dir1
master@edge-node:~$ ls -ld dir1
drwxr-xr-w 2 master master 4096 Sep 15 10:02 dir1

master@edge-node:~$ su - user1
Password: 
user1@edge-node:~$ touch /home/master/dir1/test2.txt
user1@edge-node:~$ ls -l /home/master/dir1/test2.txt
-rw-r--r-- 1 user1 user1 0 Sep 15 10:03 /home/master/dir1/test2.txt
```</username></username></pid></username></username></username></username></username></username>
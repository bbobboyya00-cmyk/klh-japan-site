---
title: "Linux特殊権限の挙動特性とパーミッション設計（SUID・SGID・Sticky Bit）"
slug: "linux-special-permissions-architecture-audit"
date: 2026-11-25T10:27:00+09:00
draft: false
image: ""
description: "SUID、SGID、Sticky Bitのカーネルレベルの挙動、大文字・小文字表記の違い、findコマンドによるセキュリティ監査手法およびnosuidマウントによる特権昇格対策の実務手順を整理します。"
categories: ["Linux System Admin"]
tags: ["chmod", "suid", "sgid", "sticky-bit", "find", "nosuid"]
author: "K-Life Hack"
---

マルチテナント環境や複数プロセスが協調動作するLinuxインフラストラクチャにおいて、標準のPOSIXアクセス制御（所有者、グループ、その他に対する読み取り・書き込み・実行権限）のみでは、業務要件を満たせない場面が存在します。例えば、一般ユーザーに自身のパスワード変更を許可しつつ特権設定ファイル（`/etc/shadow`）の安全性を担保する要件や、複数エンジニアが共有ディレクトリ内で生成した成果物のグループ所有権を統一する要件、さらには`/tmp`のような共有作業領域で他者のファイルを不当に削除・改ざんされないよう保護する要件などです。

これらの要求に応えるため、Linuxカーネルは通常のアクセス権限ビットの上位に「特殊権限（Special Permissions）」を実装しています。しかし、特殊権限は設定を誤ると重大な特権昇格（Privilege Escalation）攻撃のベクターとなるため、その詳細な実行時挙動と監査手法を正確に把握しておく必要があります。

## 特殊権限のアーキテクチャと実行コンテキスト

Linuxファイルシステムにおける特殊権限は、以下の3つのビットで構成されます。

### 1. Set User ID (SUID) — 8進数ビット: `4000`

SUIDビットが付与された実行可能バイナリをユーザーが実行すると、プロセスの実効ユーザーID（EUID: Effective User ID）が実行者ではなく「バイナリの所有者（通常はroot）」に一時的に切り替わります。

代表例が `/usr/bin/passwd` です。一般ユーザーのパスワードハッシュが格納される `/etc/shadow` は通常パーミッションが `0000` または `0600`（所有者root）となっており、一般ユーザーは直接参照・変更ができません。`/usr/bin/passwd` にSUIDが設定されていることで、実行中のみroot権限で動作し、ファイルの更新が可能となります。

### 2. Set Group ID (SGID) — 8進数ビット: `2000`

SGIDはファイルとディレクトリで動作が異なります。

- <b>実行ファイルの場合</b>: 実行者のプライマリグループに関わらず、プロセスの実効グループID（EGID）が「ファイルの所属グループ」に切り替わります。
- <b>ディレクトリの場合</b>: 該当ディレクトリ配下に新規作成されたすべてのファイルおよびサブディレクトリのグループ所有権が、作成者のプライマリグループではなく「親ディレクトリの所属グループ」を強制的に継承します。開発チームなどの共有ディレクトリ構築において必須となる設定です。

### 3. Sticky Bit — 8進数ビット: `1000`

ディレクトリに対して設定される特殊権限です。Sticky Bitが付与されたディレクトリ内では、仮にディレクトリ全体のパーミッションが `777`（誰でも書き込み可能）であっても、ファイルの削除およびファイル名変更の権限が「ファイルの所有者」または「rootスーパーユーザー」に限定されます。不特定多数のユーザーやサービスがファイルを一時書き込みする `/tmp` ディレクトリに適用されています。

## パーミッション表記の解釈（s/S および t/T）

`ls -l` 出力において、特殊権限は実行権限ビットの位置に表示されます。ここで表示される文字の大小は、ベースとなる通常実行権限（`x`）の有無を示しています。

| 表記 | 権限種別 | 通常実行権（x）の状態 | システム挙動の解釈 |
| :--- | :--- | :--- | :--- |
| `rws` | SUID / SGID | 有効 | SUID/SGIDが正常に機能する標準状態 |
| `rwS` | SUID / SGID | <b>無効</b> | 特殊権限はセットされているが実行権限が欠落している不整合状態 |
| `rwt` | Sticky Bit | 有効 | Sticky Bitが正常に機能する標準状態 |
| `rwT` | Sticky Bit | <b>無効</b> | Sticky BitはセットされているがOthersの実行権限が欠落している状態 |

大文字の `S` や `T` が表示されている場合、パーミッション設定の意図と実行フラグの整合性が崩れている可能性が高いため、設定の見直しが必要です。

## 設定手順：数値（8進数）指定とシンボリック指定

特殊権限の付与・剥奪には `chmod` コマンドを使用します。

### 8進数モードによる設定

標準の3桁パーミッションの先頭に、特殊権限の合算値を付加した4桁の数値を指定します。

```bash
# SUIDの設定 (4000 + 0755 = 4755)
chmod 4755 /usr/local/bin/custom-exec

# SGIDの設定 (2000 + 0775 = 2775)
chmod 2775 /shared/devteam

# Sticky Bitの設定 (1000 + 0777 = 1777)
chmod 1777 /tmp/scratch

# 特殊権限の完全解除 (先頭を0に設定)
chmod 0755 /usr/local/bin/custom-exec
```

### シンボリックモードによる設定

対象（`u`: 所有者、`g`: グループ、`o`: その他）に対して `s` または `t` フラグを指定します。

```bash
# SUIDの付加と解除
chmod u+s /usr/local/bin/custom-exec
chmod u-s /usr/local/bin/custom-exec

# SGIDの付加と解除
chmod g+s /shared/devteam
chmod g-s /shared/devteam

# Sticky Bitの付加と解除
chmod o+t /tmp/scratch
chmod o-t /tmp/scratch
```

## システム監査と探索パイプライン

特権昇格攻撃のリスクを抑止するため、セキュリティ監査では不要なSUID/SGIDファイルの定期的な検出が必要です。`find` コマンドを使用してファイルシステム全体を監査します。

```bash
# SUIDバイナリの網羅的探索
find / -perm -4000 -type f 2&gt;/dev/null

# SGIDバイナリおよびファイルの探索
find / -perm -2000 -type f 2&gt;/dev/null

# Sticky Bitが設定されたディレクトリの探索
find / -perm -1000 -type d 2&gt;/dev/null

# SUIDまたはSGIDのいずれかが設定されたファイルの探索 (4000 + 2000 = 6000)
find / -perm -6000 -type f 2&gt;/dev/null
```

-perm -4000` は指定ビットがすべて含まれているかを判定します。権限エラーによる画面の汚染を防ぐため、標準エラー出力は `/dev/null` にリダイレクトします。

## Troubleshooting

### 1. SUIDバイナリ実行時の「Permission denied」と大文字 `S` 表記

<b>問題事象:</b> SUIDを設定したバイナリを一般ユーザーが実行しようとすると、`bash: ./binary: Permission denied` が発生し実行に失敗する。`ls -l` を確認すると `-rwSr-xr-x` のように大文字の `S` が表示されている。

<b>原因:</b> ファイルの所有者（Owner）に対する実行権限（`x`）が付与されていない状態でSUID（`u+s` または `4xxx`）が設定されたため、カーネルが実行を拒絶しています。

<b>解決ワークフロー:</b> 実行権限を付与することで、表記が小文字 `s` に変化し正常に実行可能となります。

```bash
chmod u+x /path/to/binary
```

### 2. 共有ディレクトリにおけるグループ所有権の不整合

<b>問題事象:</b> 複数ユーザーで共同編集するディレクトリにおいて、特定のユーザーが作成した新規ファイルのグループがそのユーザーのプライマリグループになってしまい、他メンバーが編集できない。

<b>原因:</b> 対象ディレクトリにSGIDが付与されていない場合、作成されたファイルのグループは作成者のデフォルトグループとなります。

<b>解決ワークフロー:</b> 対象ディレクトリのグループ所有権を共有グループに変更した上で、SGIDを付与します。

```bash
chown -R :sharedgroup /shared/workspace
chmod 2775 /shared/workspace
```

### 3. SUID経由の特権昇格リスクの構造的排除（nosuid）

<b>問題事象:</b> 共有ストレージ（NFS）やユーザーが自由に書き込み可能な領域（`/tmp`、`/home`）に悪意あるSUIDバイナリが配置された場合、ローカル特権昇格の足がかりとなる。

<b>解決ワークフロー:</b> マウントオプションに `nosuid` を明示的に指定します。これにより、カーネルレベルで該当ファイルシステム上のSUIDおよびSGIDビットの解釈が無効化されます。

`/etc/fstab` の設定例:

```text
UUID=xxxx-xxxx /home ext4 defaults,nosuid,nodev 0 2
UUID=yyyy-yyyy /tmp  ext4 defaults,nosuid,noexec,nodev 0 2
```

## 検証手順と実行ログ

設定後の権限状態およびファイルシステムの挙動確認ログです。

```text
# SUIDバイナリの確認
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68248 Mar 23  2024 /usr/bin/passwd

# Sticky Bitディレクトリの確認
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 Nov 25 10:00 /tmp

# システム内のSUID設定ファイルの抽出実行例
$ find /usr/bin -perm -4000 -type f 2&gt;/dev/null
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/passwd
/usr/bin/newgrp
/usr/bin/sudo
/usr/bin/su

# nosuid適用状況の確認
$ mount | grep nosuid
/dev/nvme0n1p3 on /home type ext4 (rw,nosuid,nodev,relatime)
tmpfs on /tmp type tmpfs (rw,nosuid,nodev)
```

## Operational Notes

1. <b>最小権限の原則:</b> 独自スクリプトや自作バイナリへのSUID付与は極力回避し、`sudo` 経由のコマンド実行制御やLinuxケーパビリティ（`setcap`）を用いた粒度の細かい権限付与を検討してください。
2. <b>スクリプトへの無効化:</b> 一般的なLinuxディストリビューションにおいて、シェルスクリプトやインタープリタ型言語スクリプトに対するSUIDビットはセキュリティ上の理由（環境変数インジェクションやレースコンディション対策）からカーネルレベルで無視されます。
3. <b>定期的な整合性スキャン:</b> 本番ホストにおいては、予期せぬファイルにSUID/SGIDが付与されていないか、CI/CDパイプラインや監視エージェントを用いて探索ログを定期取得する構成を維持することが推奨されます。
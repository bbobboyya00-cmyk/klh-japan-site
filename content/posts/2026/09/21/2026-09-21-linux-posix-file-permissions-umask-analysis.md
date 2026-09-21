---
title: "Linuxファイルパーミッション構造とumask計算の技術検証"
slug: "linux-posix-file-permissions-umask-analysis"
date: 2026-09-21T10:10:14+09:00
draft: false
image: ""
description: "POSIXアクセス制御モデルにおけるOctal表記、umaskによるビット演算減算、SUID/SGID/Sticky Bitの挙動、WebサーバーでのPermission Denied解消手順を整理します。"
categories: ["Linux System Admin"]
tags: ["linux", "posix", "umask", "chmod", "chmod-755"]
author: "K-Life Hack"
---

マルチテナント構成のインフラ拡張や自動デプロイメントパイプラインの運用において、ファイルシステムの権限設定の不整合は静的アセットのHTTP 403 Forbiddenエラーやプロセス権限昇格のリスクを直ちに引き起こします。特に、自動化スクリプトが生成する中間ファイルの権限を決定する<code>umask</code>の仕様誤認や、上位ディレクトリの実行権限（<code>x</code>ビット）欠如によるパス階層のトラバース失敗は、本番環境で多発する障害パターンです。

本稿では、POSIX標準のアクセス制御モデル、Octal表記による権限フラグ、<code>umask</code>のビット論理演算メカニズム、および特殊パーミッション（SUID/SGID/Sticky Bit）の内部挙動について詳細に解析します。

## POSIXパーミッションモデルと表記構造

Linuxファイルシステムは、アクセス対象を3つのスコープ（<code>u</code>: User, <code>g</code>: Group, <code>o</code>: Others）に分類し、それぞれに対して<code>r</code> (Read)、<code>w</code> (Write)、<code>x</code> (Execute)の3つの権限モードを割り当てます。

<code>ls -l</code> コマンドで出力される権限文字列の構造は以下の通りです。

```text
- rwx r-x r--
|  |   |   |
|  |   |   +--&gt; Others (o) : 読み取り専用 (r--)
|  |   +------&gt; Group (g)  : 読み取りおよび実行 (r-x)
|  +----------&gt; Owner (u)  : 読み取り、書き込み、実行 (rwx)
+-------------&gt; ファイルタイプ (- = 正規ファイル, d = ディレクトリ)
```

アクセス権限の挙動は、対象がファイルかディレクトリかによって大きく異なります。

| シンボル | モード | ファイルでの動作 | ディレクトリでの動作 |
| :---: | :--- | :--- | :--- |
| <b>`r`</b> | <b>Read</b> | ファイル内容の閲覧・読み込み (`cat`, `less`) | ディレクトリ内のファイル名一覧取得 (`ls`) |
| <b>`w`</b> | <b>Write</b> | ファイル内容の変更・上書き・追記 | ディレクトリ内でのファイル作成・削除・名前変更 |
| <b>`x`</b> | <b>Execute</b> | ファイルをプログラムとして実行 | ディレクトリ内部への移動・パス通過 (`cd`, 内部ファイルアクセス) |

ディレクトリに対する<code>r</code>権限のみでは内部ファイルにアクセスすることはできません。パスを通過して内部のオブジェクトを参照するには、対象ディレクトリまでのすべての階層に<code>x</code>権限が付与されている必要があります。

## Octal（8進数）表記法と計算モデル

Linuxカーネルは内部的に各スコープの権限を3ビットのバイナリマスクとして保持し、これを0〜7の8進数（Octal）で表現します。

- <b>Read (`r`)</b> = $2^2 = 4$
- <b>Write (`w`)</b> = $2^1 = 2$
- <b>Execute (`x`)</b> = $2^0 = 1$

これらの加算値により、任意の権限状態を表現します。

- `rwx` = $4 + 2 + 1 = 7$
- `rw-` = $4 + 2 + 0 = 6$
- `r-x` = $4 + 0 + 1 = 5$
- `r--` = $4 + 0 + 0 = 4$

### 代表的な本番構成パターン

- <b>`755` (`rwxr-xr-x`)</b>: 実行可能バイナリ、システムスクリプト、標準的な公開ディレクトリ。
- <b>`644` (`rw-r--r--`)</b>: 静的設定ファイル、Webサーバーアセット、実行権限を必要としないドキュメント。
- <b>`600` (`rw-------`)</b>: SSH秘密鍵（`id_rsa`）、SSL/TLS私有鍵、データベース接続クレデンシャル。
- <b>`777` (`rwxrwxrwx`)</b>: 全スコープに対する制限なしアクセス。セキュリティ設定上のアンチパターン。

## umaskの内部アーキテクチャとビット演算

<code>umask</code>（User Mask）は、新規ファイルおよびディレクトリ作成時にデフォルトで除外する権限ビットを指定する論理マスクです。

Linuxカーネルが割り当てる初期ベース権限は以下の通り設定されています。
- <b>ファイルベース権限</b>: `666` (`rw-rw-rw-`) ※セキュリティ上、デフォルトで実行権限`x`は付与されません。
- <b>ディレクトリベース権限</b>: `777` (`rwxrwxrwx`) ※トラバースを許可するため`x`が含まれます。

最終的な実効パーミッションは、ベース権限から<code>umask</code>の論理否定（NOT）とのAND演算によって算出されます。

$$\text{Effective Permission} = \text{Base Permission} \land \neg(\text{umask})$$

標準的な <code>umask 0022</code> 適用時の計算結果は以下の通りです。

1. <b>新規ファイルの計算</b>:
- ベース権限: `666` (`rw-rw-rw-`)
- `umask`: `0022` (`--- -w- -w-`)
- 適用結果: $666 - 0022 = 644$ (`rw-r--r--`)

2. <b>新規ディレクトリの計算</b>:
- ベース権限: `777` (`rwxrwxrwx`)
- `umask`: `0022` (`--- -w- -w-`)
- 適用結果: $777 - 0022 = 755$ (`rwxr-xr-x`)

## 特殊パーミッション（SUID, SGID, Sticky Bit）

標準アクセス権限の拡張として、Linuxは特殊フラグを提供します。

### 1. Set User ID (SUID)

- <b>メカニズム</b>: 実行可能ファイルを実行した際、実行者ではなくファイル所有者の権限でプロセスが起動します。
- <b>設定コマンド</b>:

  ```bash
  chmod u+s /usr/bin/custom-executable
  # Octal表記: chmod 4755 /usr/bin/custom-executable
  ```

### 2. Set Group ID (SGID)

- <b>メカニズム</b>: ディレクトリに設定した場合、内部に新規作成されたファイルやディレクトリは、作成者の主グループではなく、親ディレクトリの所有グループを自動的に継承します。
- <b>設定コマンド</b>:

  ```bash
  chmod g+s /var/shared/
  # Octal表記: chmod 2755 /var/shared/
  ```

### 3. Sticky Bit

- <b>メカニズム</b>: ディレクトリに設定した場合、他ユーザーが所有するファイルの削除や名前変更を禁止します（ファイル所有者、ディレクトリ所有者、rootのみ削除可能）。
- <b>設定コマンド</b>:

  ```bash
  chmod +t /tmp
  # Octal表記: chmod 1777 /tmp
  ```

## Troubleshooting

### 1. ディレクトリトラバース欠如による Permission Denied

Webサーバーやアプリケーションがアセットにアクセスできない場合、対象ファイル自体の権限が<code>644</code>であっても、上位パスのいずれかのディレクトリに<code>x</code>権限がないケースがあります。

<b>修正手順</b>:
全上位パスの権限状態を<code>namei</code>コマンドで検証し、ディレクトリ階層に<code>x</code>を付与します。

```bash
  namei -om /var/www/html/app/index.html
  ```

### 2. chmod -R 777 乱用による障害および修正手順

アクセス拒否の解消目的で <code>chmod -R 777</code> を実行すると、全構成ファイルに不可逆な実行権限が付与され、セキュリティチェックツールやSSHデーモンが接続を拒否する問題が発生します。

<b>修正手順</b>:
<code>find</code>コマンドを使用して、ファイルとディレクトリを分離して適切な権限をバッチ適用します。

```bash
  sudo chown -R nginx:nginx /var/www/html
  find /var/www/html -type d -exec chmod 755 {} +
  find /var/www/html -type f -exec chmod 644 {} +
  ```

## 稼働検証プロトコル

システム環境で設定適用後にパーミッション構造とトラバース可否を検証した出力結果です。

```text
  # 1. 権限構造とSELinuxコンテキストの確認
  $ ls -laZ /var/www/html
  drwxr-xr-x. 2 nginx nginx unconfined_u:object_r:httpd_sys_content_t:s0 4096 Sep 21 10:00 .
  drwxr-xr-x. 3 root  root  system_u:object_r:var_t:s0                 4096 Sep 21 09:50 ..
  -rw-r--r--. 1 nginx nginx unconfined_u:object_r:httpd_sys_content_t:s0  245 Sep 21 10:00 index.html

  # 2. 現在のシェルセッションにおける umask 値の検証
  $ umask
  0022

  # 3. HTTPレスポンス状態の判定
  $ curl -I http://localhost/index.html
  HTTP/1.1 200 OK
  Server: nginx/1.24.0
  Date: Sun, 21 Sep 2026 10:05:00 GMT
  Content-Type: text/html
  Content-Length: 245
  Connection: keep-alive
  ```

## Operational Notes

- 再帰的権限変更を行う際は、単一の `chmod -R` 実行を避け、必ず `find -type d` および `find -type f` による個別適用を実施してください。
- Webプロセス等のサービスアカウントに対するアクセス付与は、権限ビットの過剰解放ではなく、`chown` による所有権の正しい再割り当てによって解決することを原則とします。
- 共有ディレクトリ運用時は、SGID（`2755`）とSticky Bit（`1777`）を適切に組み合わせることで、マルチユーザー環境におけるアクセス権限の競合を防ぐことが可能です。
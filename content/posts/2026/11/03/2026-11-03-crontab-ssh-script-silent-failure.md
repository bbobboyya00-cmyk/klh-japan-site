---
title: "SSH対話型シェルで成功するスクリプトがcrontabでサイレント失敗する原因と対処構造"
slug: "crontab-ssh-script-silent-failure"
date: 2026-11-03T11:00:51+09:00
draft: false
image: ""
description: "SSH対話型環境とcrontabの環境変数差異によって発生するスクリプトのサイレント失敗事例を分析し、絶対パス指定、権限設定、標準出力・エラーリダイレクトの実装手順を解説します。"
categories: ["Linux System Admin"]
tags: ["crontab ssh execution"]
author: "K-Life Hack"
---

インフラ構築や運用自動化の過程において、手動でSSHターミナルから実行した際には正常に終了するスクリプトが、<code>crontab</code>によるスケジューリング実行時には無出力のまま停止、あるいはサイレントに失敗する現象は頻繁に発生します。この問題は、インタラクティブシェルとデモンプロセス経由の非対話型サブシェルにおける初期化ライフサイクルおよび環境変数の不一致に起因します。

本稿では、<code>cron</code>実行時の環境分離メカニズムを解説し、絶対パスの強制、ファイル実行権限、およびログリダイレクトストリームの構築手順を整理します。

## SSH対話型環境とcrontab実行環境の構造的差異

手動実行と<code>cron</code>実行の決定的な違いは、シェル起動時にロードされる環境変数と構成ファイルにあります。

```text
+-------------------------------------------------------------------------+
| SSH Interactive Shell Session                                           |
| Load files: ~/.bashrc, ~/.bash_profile, /etc/profile                    |
| PATH includes: /usr/local/bin, /usr/bin, /bin, user defined paths, etc. |
+-------------------------------------------------------------------------+

+-------------------------------------------------------------------------+
| Cron Daemon Execution Environment                                       |
| Load files: Minimal cron default parameters                             |
| PATH defaults to: /usr/bin:/bin                                         |
+-------------------------------------------------------------------------+
```

ユーザーがSSH経由でログインした場合、<code>~/.bashrc</code>や<code>/etc/profile</code>などの初期化スクリプトが評価され、拡張された<code>PATH</code>や独自環境変数が読み込まれます。一方、<code>cron</code>デモンは最小限の環境変数（多くの場合 <code>PATH=/usr/bin:/bin</code> のみ）が適用された非対話型サブシェルでジョブを実行します。そのため、標準パス以外の場所に配置されたバイナリや環境変数に依存するスクリプトは探索に失敗します。

## 3段階の診断および解決フレームワーク

### 1. 全コマンドおよびスクリプトへの絶対パス適用

<code>cron</code>設定において相対パスを使用すると、実行時のカレントディレクトリ解釈に不一致が生じ、エラーの原因となります。

相対パスを用いた失敗例:

```cron
* * * * * python main.py
* * * * * ./scripts/backup.sh
```

絶対パスを明示的に指定した設定例:

```cron
* * * * * /usr/bin/python3 /home/user/project/main.py
* * * * * /bin/bash /home/user/scripts/backup.sh
```

スクリプト内部で相対パスによるファイル読み込み（例: <code>cat ./config.json</code>）を行っている場合、実行ディレクトリがユーザーのホームディレクトリ（<code>/home/user</code>）に固定されるためエラーが発生します。必要に応じてスクリプトの先頭で移動処理を挿入するか、フルパスでの記述が必要です。

バイナリの絶対パスを確認するには、インタラクティブシェルで <code>which</code> コマンドを実行します。

```bash
which python3
which bash
```

### 2. ファイル実行権限（chmod）およびシバン（Shebang）の検証

スクリプトファイルに読取権限があっても実行権限（<code>+x</code>）が与えられていない場合、<code>cron</code>は処理を実行できません。

パーミッション状態の確認:

```bash
ls -l /home/user/scripts/backup.sh
```

実行権限が付与されていない場合、以下のコマンドで権限を付与します。

```bash
chmod +x /home/user/scripts/backup.sh
```

また、シェルスクリプトの1行目には適切なインタプリタを指定するシバンを明記します。

```bash
#!/bin/bash
```

### 3. 専用ログリダイレクトストリームの実装

<code>cron</code>はデフォルトで標準出力（<code>stdout</code>）および標準エラー出力（<code>stderr</code>）をターミナルに表示しません。ローカルMTA（Mail Transfer Agent）が未構成の場合、エラーログは記録されずに破棄されます。

実行結果およびエラーログをファイルへ連続記録するために、リダイレクト記述を<code>crontab</code>に追加します。

```cron
* * * * * /bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

🛠️ <b>ログリダイレクトの構造分解:</b>
・<code>&gt;&gt; /home/user/cron.log</code>: 標準出力（ファイル記述子1）をログファイルへ追記形式でリダイレクトします。
・<code>2&gt;&amp;1</code>: 標準エラー出力（ファイル記述子2）を標準出力と同じストリームへ統合します。

## Cron環境変数の明示的宣言と仮想環境の起動

<code>crontab</code>ファイルの先頭領域にグローバル環境変数を定義することで、個別の実行ラインでフルパス記述を簡略化することが可能です。

```cron
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
SHELL=/bin/bash

* * * * * backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

Pythonの仮想環境（<code>venv</code> や <code>conda</code>）を利用するスクリプトを呼び出す場合は、仮想環境内のPythonバイナリパスを直接指定して実行するのが確実な構成方法です。

```cron
* * * * * /home/user/myenv/bin/python /home/user/work/script.py &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

## Troubleshooting

### ケース1: cron実行時の Permission Denied またはサイレント失敗
⚠️ <b>原因</b>: 実行スクリプトまたは内部で呼び出すバイナリの権限不足、またはシバン未指定。
💡 <b>対処手順</b>: <code>chmod +x</code> による権限の再設定、およびスクリプト先頭行の <code>#!/bin/bash</code> 存在確認を行ってください。

### ケース2: システムログにcronの実行記録が表示されない

⚠️ <b>原因</b>: ディストリビューションの設定によって <code>/var/log/cron.log</code> 出力が無効化されている。
💡 <b>対処手順</b>: <code>/etc/rsyslog.d/50-default.conf</code> を確認し、<code># cron.*</code> 行のコメントアウトを解除後、<code>systemctl restart rsyslog</code> を実行してください。

### ケース3: スクリプト内で参照する外部ファイルの読み込み失敗

⚠️ <b>原因</b>: <code>cron</code>実行時のカレント作業ディレクトリが想定と異なる。
💡 <b>対処手順</b>: スクリプト内部の冒頭に <code>cd "$(dirname "$0")"</code> などのパス移動ロジックを組み込むか、参照ファイル全般を絶対パスに変更します。

## システム動作検証ログ

以下は、パーミッション確認、ログ出力設定、および syslog による <code>CRON</code> ジョブの動作確認ログ例です。

```text
$ ls -l /home/user/scripts/backup.sh
-rw-r--r-- 1 user group 450 Nov  3 10:00 /home/user/scripts/backup.sh

$ chmod +x /home/user/scripts/backup.sh
$ ls -l /home/user/scripts/backup.sh
-rwxr-xr-x 1 user group 450 Nov  3 10:01 /home/user/scripts/backup.sh

$ grep CRON /var/log/syslog | tail -n 3
Nov  3 10:02:01 server CRON[12345]: (user) CMD (/bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1)
Nov  3 10:03:01 server CRON[12411]: (user) CMD (/bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1)

$ tail -f /home/user/cron.log
[2026-11-03 10:02:01] Starting backup process...
[2026-11-03 10:02:02] Backup completed successfully.
```

## Operational Notes

| 診断領域 | 実施項目 | 記述・検証構文 |
| :--- | :--- | :--- |
| <b>パス定義</b> | バイナリおよびターゲットの絶対パス指定 | `/usr/bin/python3 /home/user/project/main.py` |
| <b>実行権限</b> | スクリプトファイルへの実行権限付与 | `chmod +x /home/user/scripts/backup.sh` |
| <b>ヘッダー定義</b> | 適切なしバン（Shebang）の明示 | `#!/bin/bash` |
| <b>出力制御</b> | 標準出力（1）と標準エラー（2）の結合リダイレクト | `&gt;&gt; /home/user/cron.log 2&gt;&amp;1` |
| <b>環境変数</b> | `crontab -e` 冒頭での `PATH` および `SHELL` 宣言 | `PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin` |
| <b>仮想環境</b> | venv環境内バイナリの直接指定 | `/home/user/myenv/bin/python` |
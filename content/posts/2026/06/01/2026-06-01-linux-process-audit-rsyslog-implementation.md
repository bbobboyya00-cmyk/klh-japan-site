---
title: "auditdとrsyslogを用いたプロセス監査およびログ転送の実装"
slug: "linux-process-audit-rsyslog-implementation"
date: 2026-05-24T10:21:24+09:00
draft: false
image: ""
description: "auditdによるカーネルレベルのプロセス監視ルール定義と、rsyslogを用いたリモートログ転送による改ざん防止策の実装手順を解説します。"
categories: ["Linux System Admin"]
tags: ["auditd", "rsyslog", "linux-security", "syslog", "process-monitoring"]
author: "K-Life Hack"
---

# Linuxシステムにおける監査ログ管理基盤の構築：auditdとrsyslogによるセキュアなシステムコール監視と外部転送

## 1. 監査およびログ管理における課題と背景

Linuxシステムにおいて、プロセスの実行状態やシステムコールの監視はセキュリティ確保の基本です。しかし、標準的なアプリケーションレベルのログ出力（syslogなど）のみに依存する場合、いくつかの深刻な課題が生じます。

⚠️ <b>ログの改ざんリスク:</b> 攻撃者がroot権限を奪取した場合、ローカルに保存されたプレーンテキストのログファイル（/var/log/auth.logなど）は容易に消去または改ざんされます。

⚠️ <b>システムコールレベルの可視性不足:</b> 標準のsyslogはアプリケーションが自己申告的に出力するログに依存するため、不正なバイナリが直接実行するシステムコール（ファイル書き換え、権限昇格など）を強制的に捕捉することができません。

これらの課題に対処するため、カーネルレベルでシステムコールをインターセプトするauditdと、信頼性の高いTCP接続でログを外部転送するrsyslogを組み合わせた監査基盤の実装手順を定義します。

## 2. 技術選定とトレードオフ

システム監査およびログ管理の設計において、以下のトレードオフを考慮しました。

<b>syslog と auditd の比較:</b> syslogはアプリケーション層のイベント記録に適していますが、プロセスの挙動を強制的に追跡することはできません。一方、auditdはカーネル境界でシステムコールを捕捉するため、プロセスの回避行動を防ぐことができます。ただし、ルール設定によっては大量のログが生成され、ディスクI/Oおよびストレージ容量を圧迫するトレードオフがあります。

<b>UDP転送 と TCP転送 の比較:</b> rsyslogによるリモート転送において、UDP（@）は高速ですがパケットロスのリスクがあります。TCP（@@）は接続指向であり、ネットワーク一時切断時にも再送制御が行われるため、セキュリティ監査ログの転送にはTCPを採用します。

## 3. 実装手順

### 3.1 auditdのインストールと有効化

Debian/Ubuntu環境において、以下のコマンドを実行してauditdを導入し、サービスを有効化します。

```bash
sudo apt-get update
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd
```

### 3.2 監査ルールの定義

/etc/audit/rules.d/audit.rulesにカスタムルールを追加し、重要なファイルやディレクトリへのアクセスを監視します。

```text
-w /etc/shadow -p wa -k shadow_watch
-w /etc/sudoers -p wa -k sudoers_watch
```

設定を反映させるため、監査ルールを再読み込みします。

```bash
sudo auigenrules --load
```

### 3.3 rsyslogによるリモートTCP転送設定

ローカルログの改ざんを防ぐため、/etc/rsyslog.conf（または/etc/rsyslog.d/配下の設定ファイル）にリモート転送ルールを追加します。

```text
*.* @@remote-log-server:514
```

設定変更後、rsyslogサービスを再起動します。

```bash
sudo systemctl restart rsyslog
```

## 4. 運用検証とログ解析パイプライン

### 4.1 監査ログの検索 (ausearch)

定義したキー（shadow_watch）に一致するイベントを検索し、数値を人間が読める形式に変換して表示します。

```bash
sudo ausearch -k shadow_watch -i
```

### 4.2 削除された実行バイナリの検知

💡 メモリ上で実行中でありながら、ディスク上から削除された不審なプロセスを特定します。

```bash
sudo ls -l /proc/*/exe | grep "deleted"
```

### 4.3 SSHブルートフォース攻撃の集計

/var/log/auth.logからログイン失敗回数の多いIPアドレスを抽出し、降順でソートします。

```bash
grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr
```

## 5. 導入効果

本構成の導入により、以下の効果が確認されました。

💡 <b>監査の網羅性向上:</b> /etc/shadowや/etc/sudoersに対する変更操作が、実行したユーザーID（auid）とともにカーネルレベルで確実に記録されるようになりました。

💡 <b>ログの保全性確保:</b> rsyslogのTCP転送設定により、ローカルログが消去された場合でも、リモートのログサーバー側でイベント履歴を追跡可能な状態が維持されます。
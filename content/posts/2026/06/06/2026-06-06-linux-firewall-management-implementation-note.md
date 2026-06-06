---
title: "Linuxファイアウォール管理ツールの実装仕様：firewalld, UFW, iptables, nftables"
slug: "linux-firewall-management-implementation-note"
date: 2026-06-06T18:07:48+09:00
draft: false
image: ""
description: "Rocky LinuxとUbuntuにおける主要なファイアウォール管理ツール（firewalld, UFW, iptables, nftables）の具体的な設定手順とアーキテクチャの相違点について、実務的なコマンド体系を中心に解説します。"
categories: ["Linux System Admin"]
tags: ["firewalld", "ufw", "iptables", "nftables", "linux-security"]
author: "K-Life Hack"
---

# Title: Linuxファイアウォール管理システムの技術仕様と実装：主要4ツールの制御ロジック
# Meta Description: Linux環境におけるfirewalld、UFW、iptables、nftablesの運用管理とパケットフィルタリングの最適化手法。

Linuxオペレーティングシステムにおけるネットワークセキュリティの基盤となるファイアウォール管理システムについて、主要な4つのツール（firewalld, UFW, iptables, nftables）の実装仕様を整理します。本稿では、Rocky LinuxおよびUbuntu環境を対象とした具体的な操作手順と、それぞれの制御ロジックについて記述します。

## 1. firewalld (Rocky Linux)

firewalldは、RHEL系のディストリビューションで標準的に採用されている動的ファイアウォール管理ツールです。「ゾーン」と「サービス」という抽象化された概念を用いてルールを管理します。

### 1.1 デーモンの状態確認とルール参照

管理の第一段階として、バックグラウンドデーモンの稼働状況と現在の設定値を確認します。

```bash
# デーモンの稼働状態を確認
systemctl status firewalld

# 現在適用されているすべてのルールを表示
firewall-cmd --list-all
```

### 1.2 サービスの許可設定

HTTPトラフィックなどの特定のサービスを許可する場合、永続的な設定（--permanent）とランタイムへの反映（--reload）が必要です。

```bash
# HTTPサービスを永続的に追加
firewall-cmd --permanent --add-service=http

# 設定をリロードして反映
firewall-cmd --reload

# 反映結果の確認
firewall-cmd --list-all
```

### 1.3 Rich Rulesによる詳細なアクセス制御

特定のソースIPアドレスからの通信のみを許可するなど、より細粒度な制御には「Rich Rules」を使用します。

```bash
# 特定のIP（192.168.0.100）からのHTTPアクセスを許可
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.0.100" service name="http" accept'

# 設定のリロード
firewall-cmd --reload
```

## 2. UFW (Ubuntu)

UFW (Uncomplicated Firewall)は、Ubuntuにおけるデフォルトの管理ツールであり、iptablesの操作を簡略化することを目的としています。

### 2.1 初期有効化とSSHの保護

UFWを有効化する際、リモート接続が遮断されないようSSHの許可を先行させる必要があります。

```bash
# UFWのインストール
apt update &amp;&amp; apt install ufw -y

# SSHを許可してから有効化
ufw allow ssh
ufw enable
```

### 2.2 ポートおよびサービス指定の許可

```bash
# HTTP（80番ポート）の許可
ufw allow http

# 特定のTCPポート（8080）の許可
ufw allow 8080/tcp

# 詳細なステータス確認
ufw status verbose
```

## 3. iptables

iptablesは、Linuxカーネルのnetfilterフックを直接操作する低レイヤーのユーティリティです。テーブルとチェインの概念に基づいてパケットをフィルタリングします。

### 3.1 ルールの優先順位と挿入

-I（Insert）オプションを使用することで、既存のルールの先頭に特定のルールを挿入し、優先的に適用させることが可能です。

```bash
# 現在のルールを詳細表示（行番号付き）
iptables -L -v -n

# 8080番ポートへの通信を最優先でドロップするテストルールを挿入
iptables -I INPUT 1 -p tcp --dport 8080 -j DROP

# テストルールの削除
iptables -D INPUT 1
```

### 3.2 Rocky Linuxにおけるiptablesへの切り替え

firewalldとの競合を避けるため、iptablesを直接使用する場合はfirewalldを無効化する必要があります。

```bash
# サービスのインストールとfirewalldの停止
dnf install iptables-services -y
systemctl stop firewalld
systemctl disable firewalld

# SSH（22番）の許可設定が /etc/sysconfig/iptables に存在することを確認
# 例: -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT

# サービスの起動
systemctl start iptables
systemctl enable iptables
```

### 3.3 ルールの永続化

iptablesのルールはメモリ上に保持されるため、再起動後も維持するには保存処理が必要です。

```bash
# ルールの保存
service iptables save
```

## 4. nftables

nftablesはiptablesの後継として開発され、より効率的なデータ構造と構文を備えています。テーブルやチェインを明示的に作成する構造が特徴です。

### 4.1 基本構造の定義とルール追加

```bash
# inetファミリー（IPv4/IPv6両対応）のテーブル作成
nft add table inet filter

# 入力チェインの作成（フックとプライオリティの定義）
nft add chain inet filter input { type filter hook input priority 0 \; }

# 80番ポートの許可ルール追加
nft add rule inet filter input tcp dport 80 accept

# ルールセットの確認
nft list ruleset
```

### 4.2 ハンドルを使用したルール管理

nftablesでは、各ルールに割り当てられた「ハンドル」番号を使用して削除や修正を行います。

```bash
# ハンドル番号を含めてルールセットを表示
nft --handle list ruleset

# 特定のハンドル番号（例: 5）を指定してルールを削除
nft delete rule inet filter input handle 5
```

## Closing Notes

Linuxのファイアウォール管理は、抽象化レイヤーの高いfirewalld/UFWから、カーネルに近いiptables/nftablesまで、用途に応じて選択する必要があります。特に、既存のfirewalld環境でiptablesを直接操作する場合は、サービス間の競合による意図しない通信遮断に注意を払う必要があります。最新のシステム設計においては、パフォーマンスと拡張性に優れたnftablesへの移行が推奨されます。
---
title: "Linux環境における各種ファイアウォール管理ツールの技術仕様と実装"
slug: "linux-firewall-management-systems-analysis"
date: 2026-06-05T12:01:00+09:00
draft: false
image: ""
description: "firewalld, UFW, iptables, nftablesの各ツールの動作論理、設定構文、および永続化手法を整理した技術実装ノート。Rocky LinuxおよびUbuntuでの運用を想定。"
categories: ["Linux System Admin"]
tags: ["firewalld", "ufw", "iptables", "nftables", "netfilter", "linux-security"]
author: "K-Life Hack"
---

# Linuxファイアウォール管理ツールの実装と運用比較

Linuxカーネルのnetfilterフレームワークを制御するためのフロントエンドツールは、ディストリビューションや運用要件によって異なります。本稿では、Rocky Linux (RHEL系) で標準的なfirewalld、Ubuntuで採用されるUFW、低レイヤー制御を可能にするiptables、そしてモダンな後継であるnftablesの各実装仕様について記述します。

## 1. firewalld (Rocky Linux / RHEL系)

firewalldは「ゾーン」と「サービス」という概念を用いてネットワークトラフィックを動的に管理します。ランタイム設定と永続設定を分離して管理する点が特徴であり、システム稼働中に接続を遮断することなくルールを更新できる利点があります。

### 1.1. 状態確認と基本設定

現在のデーモンの稼働状態および適用されているルールセットを確認します。アクティブなゾーンとインターフェースの紐付けを把握することが初期診断の基本となります。

```bash
# デーモンの稼働状態確認
systemctl status firewalld

# アクティブなルールおよびゾーン設定の表示
firewall-cmd --list-all
```

### 1.2. サービスの許可と永続化

HTTPなどの標準的なサービスを許可する場合、`--permanent`フラグを使用して再起動後も設定を維持させます。設定変更後はリロード処理を実行することで、ランタイム環境に反映されます。

```bash
# HTTPサービスの永続的な追加
firewall-cmd --permanent --add-service=http

# 設定の反映
firewall-cmd --reload

# 反映後の確認
firewall-cmd --list-all
```

### 1.3. Rich Rulesによる詳細なアクセス制御

特定のソースIPアドレスからのアクセスのみを許可するなど、複雑な条件が必要な場合はRich Rulesを使用します。これにより、サービス単位よりも細かい粒度でのフィルタリングが可能になります。

```bash
# 特定のIP (192.168.0.100) からのHTTPアクセスのみを許可
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.0.100" service name="http" accept'

# リロード後に適用を確認
firewall-cmd --reload
```

## 2. UFW: Uncomplicated Firewall (Ubuntu系)

UFWはiptablesの複雑な構文を抽象化し、簡潔なインターフェースを提供することを目的としています。主にデスクトップや小規模なサーバー環境において、迅速な設定展開を支援します。

### 2.1. インストールと初期有効化

Ubuntu環境では、リモートアクセス（SSH）を事前に許可してから有効化することが推奨されます。これを怠ると、有効化した瞬間にSSHセッションが切断されるリスクがあります。

```bash
# インストール
apt update
apt install ufw -y

# SSHの許可と有効化
ufw allow ssh
ufw enable
```

### 2.2. ポートおよびサービス管理

ポート番号やプロトコルを直接指定してルールを定義します。シンプルながらも、特定のサブネットからのアクセス制限など、必要な機能は網羅されています。

```bash
# HTTP (80番ポート) の許可
ufw allow http

# 特定のTCPポート (8080) の許可
ufw allow 8080/tcp

# 詳細なステータス表示
ufw status verbose
```

## 3. iptables: カーネルレベルのパケットフィルタリング

iptablesはnetfilterフレームワークと直接対話し、パケットの連鎖（Chains）に基づいて処理を決定します。長年標準として利用されており、多くのレガシーシステムや特定のネットワークアプライアンスで現役の技術です。

### 3.1. ルールの優先順位と挿入

iptablesはルールを上から順に評価するため、挿入位置（インデックス）が重要です。`-A`（追加）と`-I`（挿入）を使い分けることで、評価順序を厳密に制御します。

```bash
# 全ルールの詳細表示
iptables -L -v -n

# INPUTチェーンの先頭にDROPルールを挿入 (ポート8080を遮断)
iptables -I INPUT 1 -p tcp --dport 8080 -j DROP

# 特定のルールの削除
iptables -D INPUT 1
```

### 3.2. Rocky Linuxでのiptables-services運用

firewalldを無効化し、iptablesを直接管理する場合の手順です。静的なルールファイルを直接編集する運用スタイルに適しています。

```bash
# パッケージのインストールとfirewalldの停止
dnf install iptables-services -y
systemctl stop firewalld
systemctl disable firewalld

# サービス有効化
systemctl start iptables
systemctl enable iptables
```

### 3.3. ルールの定義と永続化

コマンドラインで追加したルールは、明示的に保存しない限り再起動時に消失します。`iptables-save`コマンドを利用して、設定をファイルに書き出す必要があります。

```bash
# Webサーバー用ポートの開放
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# 特定のソースIPからのパケットを破棄
iptables -A INPUT -s 1.2.3.4 -j DROP

# 設定の保存 (RHEL系)
service iptables save
```

## 4. nftables: モダンな後継ツール

nftablesはiptablesの後継として開発され、パフォーマンスの向上と構文の柔軟性が強化されています。テーブル、チェーン、ルールの階層構造を持ち、単一のルールで複数のアクションを処理できる効率性を備えています。

### 4.1. テーブルとチェーンの構築

nftablesでは、まずアドレスファミリー（ip, ip6, inetなど）を指定してテーブルを作成し、その中にフックポイントを定義したチェーンを構築します。

```bash
# inetファミリーにfilterテーブルを作成
nft add table inet filter

# inputチェーンの定義 (優先度0)
nft add chain inet filter input { type filter hook input priority 0 \; }

# ポート80の許可ルール追加
nft add rule inet filter input tcp dport 80 accept

# ルールセットの表示
nft list ruleset
```

### 4.2. ハンドルを使用したルール管理

nftablesでは各ルールに付与された「ハンドル」を使用して操作を行います。これにより、特定のルールを正確に削除または置換することが容易になります。

```bash
# ハンドル番号を含めたリスト表示
nft --handle list ruleset

# 特定のハンドル番号を指定して削除
nft delete rule inet filter input handle [NUMBER]
```

## Operational Notes

- <b>💡 競合の回避</b>: 同一システム上で複数のファイアウォール管理ツール（例：firewalldとiptables）を同時に有効にすると、ルールの競合や予期しないパケットドロップが発生する可能性があります。必ず一方を無効化してください。
- <b>⚠️ SSHアクセスの確保</b>: ルールを適用する際は、常に管理用セッション（SSH）が維持されることを確認してください。特に`ufw enable`や`iptables -F`（全ルール消去）を実行する際は注意が必要です。
- <b>🛠️ 永続化の確認</b>: 各ツールで永続化の手法が異なるため（`--permanent`, `service save`, `nftables.conf`など）、設定変更後は必ず再起動試験または設定ファイルの確認を実施してください。
---
title: "Linux環境におけるSSHブルートフォース攻撃ログ解析とFail2ban動的防御の構築"
slug: "ssh-bruteforce-log-analysis-fail2ban-mitigation"
date: 2026-07-31T10:03:37+09:00
draft: false
image: ""
description: "Linux認証ログの解析パイプライン構築とFail2banを用いた自動IP遮断メカニズムの導入、SSHハードニング手法について解説します。"
categories: ["Linux System Admin"]
tags: ["fail2ban"]
author: "K-Life Hack"
---

インターネットに公開されているLinuxサーバーのデフォルトSSHポート（TCP 22）は、自動化されたボットネットによる辞書攻撃やブルートフォース攻撃に常時晒されています。ノード数が増加するインフラ運用において、手動でファイアウォールルールを更新して攻撃IPをブロックする手法は人為的ミスの原因となり、レスポンス速度の観点からも限界を迎えます。

本稿では、<code>/var/log/auth.log</code> に記録される認証試行ログの解析パイプラインを構築し、Fail2banを活用して netfilter（iptables）へ動的にパケットドロップルールを注入する侵入防止システム（IPS）の構成手順を整理します。

## 認証ログ構造とテキスト解析パイプライン

Debian/Ubuntu系のディストリビューションでは、SSH認証に関するイベントは <code>/var/log/auth.log</code>（RHEL/CentOS系では <code>/var/log/secure</code>）へ出力されます。

### 攻撃ログのサンプルトレース

```syslog
May 20 14:21:05 server-node sshd[4102]: Failed password for invalid user admin from 192.168.56.120 port 54321 ssh2
May 20 14:21:07 server-node sshd[4105]: Failed password for invalid user root from 192.168.56.120 port 54322 ssh2
May 20 14:21:09 server-node sshd[4108]: Failed password for root from 192.168.56.120 port 54323 ssh2
May 20 14:21:11 server-node sshd[4111]: Accepted password for deployer from 192.168.56.10 port 51100 ssh2
```

ログ内の <code>Failed password</code> パターンは認証失敗を示します。<code>invalid user</code> が含まれる場合はローカルの <code>/etc/passwd</code> に存在しないユーザー名での試行であり、含まれない場合は実在するアカウントへの攻撃を意味します。

### CLIコマンドによる攻撃IP抽出

大量のログデータから攻撃頻度の高い上位IPアドレスを迅速に特定するため、標準のLinuxユーティリティを組み合わせたパイプラインを実行します。

```bash
grep "Failed password" /var/log/auth.log | awk '{for(i=1;i&lt;=NF;i++) if($i=="from") print $(i+1)}' | sort | uniq -c | sort -nr | head -n 10
```

<code>awk</code> ループ処理により、<code>invalid user</code> 判別の有無によって列位置が変動する場合でも、トークン <code>from</code> の直後のフィールドを確実に抽出します。

## Fail2banによる自動防御構成

ログ解析で検出された脅威インジケーターに基づき、Fail2banを用いて動的な遮断ルールを適用します。パッケージデフォルトの設定ファイルを保護するため、<code>/etc/fail2ban/jail.local</code> を作成して定義をオーバーライドします。

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime  = 1h
```

💡 <b>主要パラメーターの定義:</b>

・<b>maxretry</b>: 指定時間内に許容する最大失敗回数です。

・<b>findtime</b>: 失敗回数をカウントするウィンドウ時間です（上記設定では10分間）。

・<b>bantime</b>: 条件を満たした際にパケットを遮断する保持時間です（上記設定では1時間）。

## SSHサービスの多層防御設定

IPSの導入に加えて、SSHデーモン自体の設定（<code>/etc/ssh/sshd_config</code>）を最適化して攻撃サーフェスを縮小させます。

1. <b>ポート番号の変更</b>: デフォルトの 22 ポートから高位ポート（例: <code>22022</code>）へ変更し、広域スキャナーからの露出を低減します。

2. <b>Direct Rootログインの禁止</b>: <code>PermitRootLogin no</code> を設定し、特権ディレクトリへの直接侵入を遮断します。

3. <b>パスワード認証の無効化</b>: <code>PasswordAuthentication no</code> を設定し、公開鍵認証のみを許可することで辞書攻撃を排除します。

## Troubleshooting

Fail2ban導入時によく直面するトラブルシューティングと対処法です。

### 1. systemd環境におけるログパス認識不備

Ubuntu 22.04以降やrsyslogが標準で無効化されている環境では、<code>/var/log/auth.log</code> が生成されずFail2banが起動失敗することがあります。

⚠️ <b>症状</b>: <code>fail2ban.service</code> 起動時に <code>Have not found any log file for sshd jail</code> エラーが発生します。

🛠️ <b>対策</b>: <code>/etc/fail2ban/jail.local</code> の <code>[sshd]</code> セクションに <code>backend = systemd</code> を明示的に指定し、journaldからログを直接読み込むよう変更します。

### 2. iptables/nftables バックエンドの競合

OSのカーネルバージョンによってパケットフィルターのバックエンド（iptables-legacy vs nftables）が異なり、BANルールが正しく注入されない場合があります。

🛠️ <b>対策</b>: <code>fail2ban-client status sshd</code> を実行し、<code>Banned IP list</code> にIPが追加されているにもかかわらず通信が通る場合は、<code>/etc/fail2ban/jail.conf</code> 内の <code>banaction</code> を <code>iptables-multiport</code> から <code>nftables</code> や <code>nftables-multiport</code> に切り替えます。

## Configuration Notes

システムの稼働状態およびBANルールの適用状況を確認するためのターミナル実行ログ例です。

```text
# systemctl status fail2ban.service
● fail2ban.service - Fail2ban Service
     Loaded: loaded (/lib/systemd/system/fail2ban.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-07-31 09:00:00 UTC; 1h 15m ago
   Main PID: 1234 (fail2ban-server)
      Tasks: 5 (limit: 4677)
     Memory: 14.5M
     CGroup: /system.slice/fail2ban.service
             └─1234 /usr/bin/python3 /usr/bin/fail2ban-server -xf start

# fail2ban-client status sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  |- Total failed:     28
|  `- File list:        /var/log/auth.log
`- Actions
   |- Currently banned: 1
   |- Total banned:     3
   `- Banned IP list:   192.168.56.120

# iptables -L f2b-sshd -n -v
Chain f2b-sshd (1 references)
 pkts bytes target     prot opt in     out     source               destination         
    6   360 REJECT     all  --  *      *       192.168.56.120       0.0.0.0/0            reject-with icmp-port-unreachable
 1250 82000 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0
```
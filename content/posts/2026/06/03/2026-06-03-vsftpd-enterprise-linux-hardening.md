---
title: "Enterprise Linuxにおけるvsftpdの導入とセキュリティ硬化設定"
slug: "vsftpd-enterprise-linux-hardening"
date: 2026-05-30T17:33:07+09:00
draft: false
image: ""
description: "Enterprise Linux環境におけるvsftpdのセキュアな導入、パッシブモードの制限、chrootによる隔離、およびfirewalldの統合設定に関する実務的な技術実装ノート。"
categories: ["Linux System Admin"]
tags: ["vsftpd", "ftp-server", "linux-hardening", "firewalld", "chroot", "passive-mode"]
author: "K-Life Hack"
---

# Enterprise Linuxにおけるvsftpdの構築とセキュリティ構成：chroot隔離とパッシブモードの最適化

Enterprise Linux（RHEL, CentOS, Rocky Linux等）において、標準的なFTPデーモンとして採用されている<b>vsftpd</b> (Very Secure FTP Daemon) は、その名の通りセキュリティを最優先に設計されたアーキテクチャを持ちます。本稿では、vsftpdの導入から、パッシブモードのポート制限、chrootによるユーザー隔離、およびfirewalldを用いたネットワーク境界防御の設定まで、実務レベルの構成手順を詳述します。

## 1. パッケージの導入とサービスライフサイクルの管理

vsftpdは権限分離モデル（Privilege Separation Model）を採用しており、信頼できないネットワーク入力を処理するプロセスの権限を最小化することで、ローカル特権昇格のリスクを低減しています。まず、パッケージの存在確認とインストールを実施します。

```bash
# vsftpdパッケージのインストール
sudo yum install -y vsftpd
```

インストール完了後、systemdユニットとしてサービスを有効化し、ブート時の自動起動を設定します。また、標準の制御ポート（TCP 21）が正しくリスニングされているかを確認します。

```bash
# サービスの起動と有効化
sudo systemctl enable --now vsftpd

# リスニング状態の確認
sudo netstat -ntlp | grep 21
```

💡 `netstat`のオプションにおいて、`-n`は数値表示、`-t`はTCPプロトコル、`-l`はリスニングソケット、`-p`はプロセスIDの表示を意味します。

## 2. vsftpd.confの構成とパッシブモードの最適化

FTPにはアクティブモードとパッシブモードの2種類が存在します。アクティブモードではサーバーからクライアントへデータ接続を開始するため、クライアント側のファイアウォールやNAT環境で通信が遮断されるケースが多いです。これを回避するため、クライアントからデータ接続を開始するパッシブモード（PASV）の利用が推奨されます。

設定変更前に、既存の構成ファイルのバックアップを作成します。

```bash
sudo cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak
```

### パッシブモードとセキュリティパラメータの定義

`/etc/vsftpd/vsftpd.conf`を編集し、以下のパラメータを追記または修正します。これにより、パッシブモードで使用されるポート範囲を限定し、ファイアウォールでの制御を容易にします。

```conf
# パッシブモードの有効化とポート範囲の指定
pasv_enable=YES
pasv_min_port=50001
pasv_max_port=50010

# ユーザー隔離の設定
chroot_local_user=YES
allow_writeable_chroot=YES
```

`chroot_local_user=YES`は、ユーザーを自身のホームディレクトリ内に閉じ込め、システムルート（/）へのアクセスを制限する重要なセキュリティ設定です。しかし、セキュリティ上の理由から、chroot先のディレクトリに書き込み権限がある場合、vsftpdはログインを拒否する仕様となっています。`allow_writeable_chroot=YES`を併用することで、この制限を緩和しつつ隔離環境を維持できます。

🛠️ 設定反映のため、サービスを再起動します。

```bash
sudo systemctl restart vsftpd
```

## 3. firewalldによるネットワークアクセス制御

サーバー側のファイアウォール（firewalld）において、FTP制御ポート（21/tcp）および先ほど定義したパッシブポート範囲（50001-50010/tcp）を明示的に許可する必要があります。

```bash
# FTPサービスおよびパッシブポート範囲の許可
sudo firewall-cmd --permanent --add-service=ftp
sudo firewall-cmd --permanent --add-port=50001-50010/tcp
sudo firewall-cmd --reload
```

## 4. 検証用ユーザーの作成と隔離確認

設定の妥当性を検証するため、専用のテストユーザーを作成します。このユーザーを用いて、外部からの接続およびchrootによるディレクトリ移動制限が機能しているかを確認します。

```bash
# テストユーザーの作成
sudo useradd ftpuser
sudo passwd ftpuser
```

ログイン後、`pwd`コマンド等で自身のホームディレクトリより上位の階層へ移動できないことが確認できれば、chroot jailの構築は成功です。

## Operational Notes

実運用における最適化とリスク管理のために、以下の項目を検討してください。

- <b>ポート範囲の設計</b>: 本構成ではパッシブポートを10個（50001-50010）に制限しています。これは同時接続数が少ない環境を想定したものであり、高負荷環境では接続数に応じてこの範囲を拡張する必要があります。
- <b>SELinuxの考慮</b>: ⚠️ SELinuxがEnforcingモードの場合、`ftp_home_dir`などのブール値を適切に設定しないと、ホームディレクトリへのアクセスが拒否される場合があります。必要に応じて `setsebool -P ftp_home_dir on` 等の調整を検討してください。
- <b>暗号化の欠如</b>: 本構成は標準的なFTP（プレーンテキスト）です。機密情報を扱う場合は、`ssl_enable=YES` によるFTPS（FTP over TLS）へのアップグレードが不可欠です。
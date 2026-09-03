---
title: "ネットワークACLとセキュリティグループのパケットフィルタリング制御"
slug: "acl-packet-filtering-mechanics-cisco-aws"
date: 2026-09-03T10:17:20+09:00
draft: false
image: ""
description: "ネットワークACLの評価順序、暗黙のDeny、ワイルドカードマスクのビット演算から、Cisco IOSおよびAWS環境でのステートレス/ステートフル制御の実装と検証手順をまとめました。"
categories: ["Linux System Admin"]
tags: ["cisco-ios", "access-list", "ip-access-group", "aws-nacl", "packet-filtering"]
author: "K-Life Hack"
---

ネットワーク境界におけるトラフィック制御において、不要な通信やプロトコルを適切なレイヤで遮断することは、内部帯域の保護やリソース保護の基礎となります。ルータやLayer-3スイッチ、パブリッククラウドの仮想ネットワークでは、アクセス制御リスト（ACL）を用いたパケットフィルタリングが広く利用されています。

本稿では、ACLのパケット評価メカニズム、Cisco IOSでの標準/拡張ACL実装、AWSにおけるステートレスNACLとステートフルセキュリティグループのアーキテクチャ比較、および運用上のトラブルシューティング手法を整理します。

## ACLの処理パイプラインと評価ロジック

ACLは、送信元IP、宛先IP、プロトコル種別（IP, TCP, UDP, ICMPなど）、送信元および宛先ポート番号を基準としてパケットをフィルタリングします。その評価処理は以下の3つの原則に基づいて実行されます。

* <b>トップダウン評価（Top-Down Processing）:</b> リストの上先頭エントリ（または小さいシーケンス番号）から順に評価されます。
* <b>ファーストマッチによる処理確定（First Match Termination）:</b> パケットが条件に一致した時点で、設定されたアクション（`permit` または `deny`）が実行され、以降のルール評価は即座に終了します。
* <b>暗黙の拒否（Implicit Deny Any）:</b> リストの末尾には明示的に記述されない拒否ルール（`deny ip any any`）が存在します。すべてのエントリに一致しなかったパケットは自動的に破棄されます。

```text
[ 受信パケット ]
       │
       ▼
┌─────────────────────────────────┐
│   Rule 1: 条件一致を判定        │──(一致)──► [ アクション実行: Permit / Deny ] ──► (評価終了)
└─────────────────────────────────┘
       │ (不一致)
       ▼
┌─────────────────────────────────┐
│   Rule 2: 条件一致を判定        │──(一致)──► [ アクション実行: Permit / Deny ] ──► (評価終了)
└─────────────────────────────────┘
       │ (不一致)
       ▼
       :
       │ (不一致)
       ▼
┌─────────────────────────────────┐
│   Implicit Deny Any (末尾)      │───────────► [ パケット破棄 (Drop) ]
└─────────────────────────────────┘
```

## ネットワーク層ACLの分類と配置原則

CiscoネットワークアーキテクチャにおけるACLは、標準ACLと拡張ACLに大別されます。

| 属性 / 方式 | 標準ACL (Standard ACL) | 拡張ACL (Extended ACL) |
| :--- | :--- | :--- |
| <b>評価対象</b> | 送信元IPアドレスのみ | 送信元/宛先IPアドレス、プロトコル、ポート番号 |
| <b>制御粒度</b> | 送信元単位の大まかな遮断 | プロトコル・ポート単位の細粒度な制御 |
| <b>番号範囲</b> | `1–99`, `1300–1999` | `100–199`, `2000–2699` |
| <b>配置推奨位置</b> | <b>宛先付近に配置:</b> 送信元のみで判定するため、送信元付近に置くと他宛先の正当な通信まで遮断するリスクがある。 | <b>送信元付近に配置:</b> 送信元と宛先の両方を判定できるため、送信元近くで不要トラフィックを破棄し、中継回線の帯域浪費を防ぐ。 |

### ワイルドカードマスクのビット判定

ACLではサブネットマスクの反転形式であるワイルドカードマスクが使用されます。2進数において `0` は「そのビットが完全に一致すること」を要求し、`1` は「無視（任意の値）」として扱われます。

例として、サブネット `192.168.1.0` に対しワイルドカードマスク `0.0.0.255` を指定した場合、上位24ビット（`192.168.1`）が厳格に比較され、下位8ビットは無視されるため、`192.168.1.0` から `192.168.1.255` までのアドレス空間全体がマッチング対象となります。

## クラウド環境におけるフィルタリング：AWS NACLとセキュリティグループ

AWS VPC環境では、サブネット境界と仮想マシン境界（ENI）の2層でパケットフィルタリングが実行されます。

```text
Internet / VPC Traffic
         │
         ▼
┌────────────────────────────────────────┐
│  第1防衛線: Network ACL (NACL)         │ ◄── サブネット境界 (ステートレス)
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  第2防衛線: Security Group (SG)        │ ◄── ENI / ホスト境界 (ステートフル)
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  ターゲットインスタンス: Amazon EC2     │
└────────────────────────────────────────┘
```

| 比較項目 | ネットワークACL (NACL) | セキュリティグループ (SG) |
| :--- | :--- | :--- |
| <b>適用スコープ</b> | サブネット境界 | ENI (Elastic Network Interface) / リソース単位 |
| <b>状態追跡</b> | <b>ステートレス:</b> インバウンドとアウトバウンドを個別に評価。戻りトラフィック用ルールの定義が必須。 | <b>ステートフル:</b> コネクションを追跡。許可されたインバウンド通信の戻りパケットは自動的に許可。 |
| <b>ルール評価エンジン</b> | 番号順によるトップダウン評価（ファーストマッチ）。 | 全ルールを集約評価。<b>許可ルールのみ</b>定義可能（明示的なDenyは不可）。 |
| <b>役割</b> | サブネット単位の粗いトラフィック境界制御。 | インスタンス単位の細粒度なアクセス制御。 |

ステートレスなNACLでは、クライアントからWebサーバへのHTTPリクエスト（インバウンド宛先ポート80）を許可した場合でも、サーバからクライアントへのレスポンス（アウトバウンド宛先エフェメラルポート）がアウトバウンドルールで明示的に許可されていない場合、通信はドロップされます。

## Cisco IOSにおけるACLの実装手順

### 標準ACLの設定とインターフェース適用

送信元サブネット `192.168.10.0/24` からの通信のみを許可する標準ACLの定義例です。

```cisco
Router# configure terminal
Router(config)# access-list 10 permit 192.168.10.0 0.0.0.255
Router(config)# access-list 10 deny any
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# ip access-group 10 in
Router(config-if)# exit
```

インターフェースに対する `in` パラメータは、ルータがパケットを受信しルーティング決定を行う前に評価を実行することを意味します。`out` はルーティング完了後、インターフェースから送信される直前に評価します。

### 拡張ACLによるWebトラフィック制御

送信元 `192.168.10.0/24` からWebサーバ `10.0.0.10` 宛てのHTTP（TCP/80）トラフィックのみを許可する設定です。

```cisco
Router(config)# access-list 100 permit tcp 192.168.10.0 0.0.0.255 host 10.0.0.10 eq 80
Router(config)# access-list 100 deny ip any any
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# ip access-group 100 in
Router(config-if)# exit
```

### 管理アクセス制御（VTYライン）

ルータ自体の管理プレーン（SSH/Telnet）へのアクセスを制限する場合、インターフェース用の `ip access-group` ではなく、仮想端末ライン上で `access-class` コマンドを使用します。

```cisco
Router(config)# line vty 0 4
Router(config-line)# access-class 10 in
Router(config-line)# exit
```

## Troubleshooting

### 1. シャドーイングルール（Shadowing）による意図しない通信許可

広範な許可ルールを上位に配置すると、下位の遮断ルールが無視される事象が発生します。

* <b>誤った設定例:</b>

  ```text
  access-list 10 permit any
  access-list 10 deny host 192.168.1.100
  ```

192.168.1.100` からの通信は1行目の `permit any` に一致し、2行目の拒否ルールは評価されません。

* <b>修正手順:</b>
より具体的な条件（特定ホストやサブネット）を上位に記述します。

  ```text
  access-list 10 deny host 192.168.1.100
  access-list 10 permit any
  ```

### 2. 暗黙の拒否による正当なトラフィックの遮断

単一のホストを拒否する目的で `deny` ルールのみを記述すると、末尾の暗黙の拒否によって全トラフィックが破棄されます。

```cisco
! 誤り: 他の全通信が暗黙的にドロップされる
Router(config)# access-list 10 deny host 192.168.1.100

! 修正: 遮断対象外の通信を明示的に許可
Router(config)# access-list 10 permit any
```

### 検証とステータス確認コマンド

ACLの適用状況と各ルールのマッチカウンタ（ヒット数）を確認します。

```text
Router# show access-lists
Standard IP access list 10
    10 deny   192.168.1.100 (15 matches)
    20 permit any (1420 matches)
Extended IP access list 100
    10 permit tcp 192.168.10.0 0.0.0.255 host 10.0.0.10 eq www (8340 matches)
    20 deny ip any any (120 matches)

Router# show ip interface gigabitEthernet 0/0
GigabitEthernet0/0 is up, line protocol is up
  Internet address is 192.168.10.1/24
  Broadcast address is 255.255.255.255
  Address determined by setup command
  MTU is 1500 bytes
  Helper address is not set
  Directed broadcast forwarding is disabled
  Inbound  access list is 100
  Outbound access list is not set
```

インターフェースからACLのバインドを解除する場合は、インターフェース設定モードで `no ip access-group` を実行します。

```cisco
Router(config)# interface gigabitEthernet 0/0
Router(config-if)# no ip access-group 100 in
```

## Operational Notes

ACLを設計・運用する際は、以下の原則を厳守する必要があります。

* <b>ルールの順序性:</b> 特定のIP/ポートを評価する具体的なエントリを上位に、広範囲を対象とする一般的なエントリを下位に配置します。
* <b>ステート性の把握:</b> クラウドNACLなどのステートレス環境では、戻りパケット用のエフェメラルポート帯域（TCP 1024-65535など）をアウトバウンド側で許可する必要があります。
* <b>適用位置と方向:</b> パケットがルータを通過する際のインターフェース視点（`in` / `out`）を正確に定義し、標準ACLは宛先近く、拡張ACLは送信元近くに配置します。
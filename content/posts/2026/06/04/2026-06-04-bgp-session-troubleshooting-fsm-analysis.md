---
title: "BGPセッション切断時における有限状態機械に基づく原因特定と復旧プロトコル"
slug: "bgp-session-troubleshooting-fsm-analysis"
date: 2026-06-04T14:24:44+09:00
draft: false
image: ""
description: "BGPセッション切断時の迅速な復旧に向け、有限状態機械（FSM）の遷移状態に応じた診断コマンド、主要な7大原因の特定フロー、およびBFDを用いた予防的設計について解説します。"
categories: ["Linux System Admin"]
tags: ["bgp", "cisco-ios", "bfd", "tcp-179", "routing-protocol"]
author: "K-Life Hack"
---

# BGPセッション切断におけるトラブルシューティングと予防的ネットワーク設計

高可用性ネットワークにおいて、BGP（Border Gateway Protocol）セッションの切断は、インターネット接続の喪失、拠点間VPNの切断、クラウド相互接続の停止など、即座に重大な影響を及ぼすイベントです。平均復旧時間（MTTR）を最小限に抑えるためには、プロトコルの動作原理に基づいた迅速な診断が不可欠です。

## 1. BGP有限状態機械（FSM）の遷移状態と診断のポイント

BGPセッションのトラブルシューティングを開始する際、対象のセッションがBGP有限状態機械（FSM）のどのフェーズで停止しているかを特定することが極めて重要です。

BGPのステート遷移は、Idle → Connect → Active → OpenSent → OpenConfirm → Established の順序で進行します。

* <b>Idle</b>: BGPプロセスが初期化中、またはリトライタイマーの起動を待機している状態です。この状態で停止している場合、ルーターに対象ネイバーへのルート自体が存在しない可能性があります。
* <b>Connect</b>: TCPの3ウェイハンドシェイクの完了を待機している状態です。
* <b>Active</b>: TCP接続の確立に失敗し、再試行を繰り返している状態です。L3の到達性（Reachability）に問題があるか、ファイアウォール等でTCPポート179が遮断されている可能性を示唆します。
* <b>OpenSent</b>: TCP接続が確立され、OPENメッセージを送信した状態です。対向ルーターからのOPENメッセージを待機しています。AS番号やBGP識別子（Router ID）の不一致が疑われます。
* <b>OpenConfirm</b>: OPENメッセージを受信し、KEEPALIVEメッセージを待機している状態です。MD5認証の不一致やタイマーの不整合が発生している場合、この状態で停止することがあります。
* <b>Established</b>: セッションが完全に確立され、正常に動作している状態です。

---

## 2. 初期診断コマンドの実行手順

障害発生時には、以下のコマンドシーケンスを実行して障害ドメインを切り分けます。

### ステップ1: 全体的なBGPステータスの確認

```router-os
show ip bgp summary
```

出力結果の「State/PfxRcd」フィールドを確認します。この値が `Active` や `Idle` の場合はセッションがダウンしています。数値が表示されている場合は、セッションが確立され、その数だけプレフィックスを受信していることを示します。

### ステップ2: ネイバー詳細情報の確認

```router-os
show ip bgp neighbors 192.168.1.1
```

* <b>BGP state</b>: 現在のFSMステートを確認します。
* <b>Last reset</b>: セッションが切断された直近の理由（例: "Peer closed the session" や "Hold time expired"）が表示されます。
* <b>Notification error message</b>: 送受信されたBGPエラーコードが表示されます。

### ステップ3: L1/L2インターフェース状態の確認

```router-os
show interfaces GigabitEthernet0/1
```

ステータスが `Up/Up` であれば物理層およびデータリンク層は正常です。`Up/Down` の場合はカプセル化の不一致やキープアライブの失敗などL2の問題が疑われ、`Administratively Down` の場合は手動でシャットダウンされています。

### ステップ4: L3到達性の検証

```router-os
ping 192.168.1.1 source Loopback0
```

ソースインターフェースを指定して疎通確認を行います。パケットロスが100%の場合はL3経路が存在せず、部分的なロスの場合はリンク品質の低下によるホールドタイマー満了が疑われます。

---

## 3. BGPセッション切断における7つの主な原因と対策

### 原因1: TCP接続の失敗
💡 <b>症状</b>: ステートが `Active` で固定され、対向のRouter IDが `0.0.0.0` と表示されます。
🛠️ <b>対策</b>: アクセスリスト（ACL）でTCPポート179が許可されているか確認します。また、BGPのキープアライブはサイズが小さいものの、アップデートメッセージは大きくなるため、経路上のMTU不整合によるパケットドロップがないか確認します。

### 原因2: AS番号の不一致

💡 <b>症状</b>: ステートが `Active` と `Idle` の間をループし、ログに `OPEN message error` が記録されます。
🛠️ <b>対策</b>: 自ルーターに設定された `neighbor [IP] remote-as [AS]` の値と、対向ルーターの実際のAS番号が一致しているか確認します。

### 原因3: ホールドタイマーの満了（Hold Timer Expiration）

💡 <b>症状</b>: セッションが断続的にフラッピングし、ログに `hold time expired` が出力されます。
🛠️ <b>対策</b>: 対向ルーターのCPU高負荷によるKEEPALIVE送信遅延、または回線混雑を確認します。ミリ秒単位での高速な障害検知が必要な場合は、BFD（Bidirectional Forwarding Detection）の導入を検討します。

### 原因4: MD5認証の不一致

💡 <b>症状</b>: ステートが `Active` で停止し、pingは通るものの、ログに `MD5 digest error` や `%TCP-6-BADAUTH` が出力されます。
🛠️ <b>対策</b>: 設定されたパスワードの大文字・小文字の区別、特殊文字、末尾のスペースの有無を再確認します。

### 原因5: アップデートソース（Update Source）の不一致

💡 <b>症状</b>: ループバックインターフェース同士でピアを確立する際、ループバックIPへのpingは通るものの、BGPステートが `Active` のまま遷移しません。
🛠️ <b>対策</b>: ピア設定において、明示的にアップデートソースを指定しているか確認します。

```router-os
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 update-source Loopback0
```

### 原因6: 最大受信プレフィックス数の超過

💡 <b>症状</b>: セッションが突然切断され、ログに `Maximum prefix limit reached` と記録されます。
🛠️ <b>対策</b>: 受信プレフィックス数を確認し、必要に応じて制限値を引き上げるか、インバウンドのフィルタリングを強化します。

```router-os
router bgp 65001
 neighbor 192.168.1.2 maximum-prefix 10000 80
```

### 原因7: ルーターのリソース枯渇

💡 <b>症状</b>: 複数のBGPセッションが同時に切断され、CLIの応答が極端に遅くなります。
🛠️ <b>対策</b>: `show processes cpu sorted` および `show processes memory sorted` でリソース消費状況を確認し、不要なフルルートの受信を避け、デフォルトルートのみの受信に切り替えるなどの最適化を行います。

---

## 4. セッションの再確立と検証

設定変更を適用した後、セッションをクリアして再ネゴシエーションをトリガーします。

* <b>ソフトリセット（推奨：トラフィックへの影響なし）</b>:
```router-os
clear ip bgp 192.168.1.2 soft in
```
* <b>ハードリセット（注意：一時的にトラフィックが遮断されます）</b>:
```router-os
clear ip bgp 192.168.1.2
```

クリア後、`show ip bgp summary` を実行し、ステートが `Established`（受信プレフィックス数が数値で表示されている状態）に遷移したことを確認します。

---

## 5. 予防的なネットワーク設計

セッションの安定性を長期的に維持するため、以下の設定をテンプレートとして導入することを推奨します。

```router-os
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 update-source Loopback0
 neighbor 192.168.1.2 password StrongMD5Key
 neighbor 192.168.1.2 maximum-prefix 10000 80 warning-only
 neighbor 192.168.1.2 fall-over bfd
 timers bgp 10 30
```

---

## Operational Notes

* ⚠️ <b>デバッグ実行時の注意</b>: 本番環境において、フルルートを受信している状態で `debug ip bgp` などのコマンドをフィルタなしで実行すると、CPU使用率が100%に達しルーターがクラッシュする危険性があります。デバッグを行う際は必ず対象のネイバーIPを指定し、検証完了後は速やかに `undebug all` を実行してください。
* 💡 <b>切り分けの起点</b>: BGPセッション障害の約8割は、TCP接続性、AS番号設定、またはホールドタイマー満了に起因します。まずは「ソースインターフェースを指定したping」が通るかどうかを切り分けの起点とすることで、インフラ側の問題かプロトコル設定側の問題かを迅速に特定できます。
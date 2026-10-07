---
title: "マルチクラウド接続を安定化させる動的BGPとTransit Gatewayの設計"
slug: "multi-cloud-bgp-transit-gateway"
date: 2026-10-07T10:25:41+09:00
draft: false
image: ""
description: "AWS Transit Gateway、Azure ExpressRoute、GCP Cloud Routerを組み合わせたマルチクラウド環境における、動的BGPルーティングの設計、ルートリーク防止策、およびフェイルオーバー検証手法。"
categories: ["DevOps Logistics"]
tags: ["bgp-routing", "transit-gateway", "multi-cloud-networking", "frrouting", "hybrid-cloud"]
author: "K-Life Hack"
---

マルチクラウド環境の拡大に伴い、AWS、Azure、GCP、およびオンプレミスデータセンター間を静的ルーティングや個別のIPSec VPNで相互接続する従来の手法は、運用限界を迎えています。ノード数やVPC/VNetの増加に伴うルート情報の肥大化、手動設定によるヒューマンエラー、障害発生時のフェイルオーバー遅延は、システムの可用性を著しく低下させます。本稿では、AWS Transit Gateway（TGW）を中心としたハブ＆スポークトポロジに、動的BGP（Border Gateway Protocol）ルーティングと専用線（Direct Connect、ExpressRoute）を統合し、耐障害性とスケーラビリティを両立するマルチクラウドネットワークアーキテクチャを設計・検証します。

## 1. マルチクラウドネットワークにおける課題と解決策

### A. ネットワーク管理の複雑化
* <b>課題:</b> クラウドフットプリントの拡大に伴い、AWSの多数のVPCやAzureのVNetにおける個別のルートテーブル管理が断片化します。この「ルーティングのスパゲッティ化」は、中央集中型のポリシー適用やセキュリティ監査、障害発生時の平均復旧時間（MTTR）の長期化を招きます。
* <b>解決策:</b> ハブ＆スポーク型ネットワークトポロジの導入。AWS Transit Gatewayなどの集中型トランジットハブを活用することで、ルーティングロジックを統合し、クロスプラットフォーム間のトラフィック制御を一元化します。

### B. 動的BGPルーティングとトランジットゲートウェイの統合

* <b>課題:</b> 静的ルーティングではリンク障害に動的に適応できず、トラフィックの迂回に手動介入が必要となり、重大なダウンタイムが発生します。
* <b>解決策:</b> 動的BGPルーティングとトランジットゲートウェイの統合。BGPにより、マルチクラウド境界を越えたリアルタイムのルート伝播と経路選択が可能になります。AWS TGW、Azure ExpressRoute Gateway、GCP Cloud Router間でBGPセッションを確立することで、最適な経路を動的に学習し、自動パス冗長化と高速なフェイルオーバーを実現します。

### C. 専用線接続（Cross-Cloud Direct Connect）の活用

* <b>課題:</b> パブリックインターネット経由のVPN接続は、インターネットの混雑、パケットロス、ジッター、およびセキュリティ上の脆弱性の影響を受けやすくなります。
* <b>解決策:</b> コロケーション施設（Equinix、Megaportなど）を介してAWS Direct Connect、Azure ExpressRoute、GCP Dedicated Interconnectを相互にブリッジし、パブリックインターネットを完全にバイパスします。これにより、広帯域（1 Gbps〜100 Gbps）、低遅延、および高いデータプライバシーを確保します。

---

## 2. 比較分析: 従来構成（AS-IS） vs. 次世代構成（TO-BE）

| 比較項目 | 従来の静的ルーティング＆VPN（AS-IS） | 現代的なマルチクラウド設計（TO-BE） |
| :--- | :--- | :--- |
| <b>ネットワークトポロジ</b> | 複雑なフルメッシュ接続（VPC間/VNet間）。ノード数増加に伴い管理コストが指数関数的に増大。 | AWS Transit Gateway等のクラウドネイティブハブを中心としたシンプルな<b>ハブ＆スポーク</b>構成。 |
| <b>ルーティングの柔軟性</b> | 静的ルートテーブルの手動更新が必要。リンク障害時の切り替えに遅延が発生。 | 動的BGPルーティングによるリアルタイムの経路計算、ルート伝播、および自動フェイルオーバー。 |
| <b>帯域幅と通信安定性</b> | パブリックインターネット経由のIPSec VPNに依存。トラフィック急増時にパケットロスや遅延が発生。 | 専用プライベート回線（Direct Connect / ExpressRoute）により、インターネットをバイパスした安定帯域を確保。 |
| <b>拡張性（スケーラビリティ）</b> | 新規リージョンやクラウドの追加時に、ネットワークトポロジとセキュリティグループの再設計が必要。 | モジュラー設計。既存のトランジットハブに新しいVPC/VNetをアタッチするだけで、既存通信に影響を与えず拡張可能。 |

---

## 3. 技術仕様と実装構成例

オンプレミスまたはコロケーションルータ（FRRouting: FRR）において、AWS Transit GatewayおよびAzure ExpressRouteと動的BGPピアリングを確立するための本番環境仕様の設定例です。

```text
! FRRouting Configuration for Multi-Cloud BGP Peering
router bgp 65001
  bgp router-id 192.168.1.1
  no bgp default ipv4-unicast
  coalesce-time 1000
  !
  ! AWS Transit Gateway Peers
  neighbor 169.254.100.1 remote-as 64512
  neighbor 169.254.100.1 description AWS-TGW-Primary
  neighbor 169.254.100.5 remote-as 64512
  neighbor 169.254.100.5 description AWS-TGW-Secondary
  !
  ! Azure ExpressRoute Gateway Peer
  neighbor 10.0.0.2 remote-as 12076
  neighbor 10.0.0.2 description Azure-ExpressRoute-Gateway
  !
  address-family ipv4 unicast
    network 10.100.0.0/16
    !
    neighbor 169.254.100.1 activate
    neighbor 169.254.100.1 route-map AWS-IN in
    neighbor 169.254.100.1 route-map AWS-OUT out
    !
    neighbor 169.254.100.5 activate
    neighbor 169.254.100.5 route-map AWS-IN in
    neighbor 169.254.100.5 route-map AWS-OUT out
    !
    neighbor 10.0.0.2 activate
    neighbor 10.0.0.2 route-map AZURE-IN in
    neighbor 10.0.0.2 route-map AZURE-OUT out
  exit-address-family
!
ip prefix-list LOCAL-SUBNETS permit 10.100.0.0/16
ip prefix-list AWS-ALLOWED-IN permit 172.16.0.0/12 ge 12 le 24
ip prefix-list AZURE-ALLOWED-IN permit 10.200.0.0/16 ge 16 le 24
!
route-map AWS-OUT permit 10
  match ip address prefix-list LOCAL-SUBNETS
!
route-map AWS-IN permit 10
  match ip address prefix-list AWS-ALLOWED-IN
!
route-map AZURE-OUT permit 10
  match ip address prefix-list LOCAL-SUBNETS
  set as-path prepend 65001 65001
!
route-map AZURE-IN permit 10
  match ip address prefix-list AZURE-ALLOWED-IN
!
```

---

## 4. Troubleshooting

### A. BGP ASNの競合と重複
* <b>事象:</b> マルチクラウド環境でプライベートASN（64512〜65534）を設計する際、異なるクラウドプロバイダーやオンプレミス拠点で同一のASNを重複して割り当ててしまうと、BGPのループ防止機能（AS-Pathによるループ検知）によりルートが拒否され、通信断が発生します。
* <b>対策:</b> 💡 クラウドおよびオンプレミス全体を網羅する一元的なASN管理台帳を作成し、重複を排除します。AWS TGW（デフォルト: 64512）とオンプレミス（例: 65001）で明確にASNを分離します。

### B. ルートリークとルーティングループ

* <b>事象:</b> AWSから学習したルートを、フィルタリングなしにそのままAzureに再広告（Advertise）してしまうと、クラウド間で意図しないトランジットトラフィックが発生し、回線帯域の逼迫やルーティングループを引き起こします。
* <b>対策:</b> ⚠️ 境界ルータにおいて、プレフィックスリスト（`prefix-list`）およびルートマップ（`route-map`）を厳格に適用します。自組織が所有するローカルプレフィックスのみを広告し、他クラウドから学習したルートは再広告しないようインバウンド・アウトバウンド双方でフィルタリングを徹底します。

### C. 非対称ルーティング（Asymmetric Routing）

* <b>事象:</b> 送信トラフィックがAWS Direct Connect経由で送信され、返りのトラフィックがAzure ExpressRouteを経由するような非対称ルーティングが発生すると、ステートフルファイアウォールによってパケットが破棄されます。
* <b>対策:</b> 🛠️ BGPの `AS-Path Prepending` を使用して、バックアップ経路のASパス長を意図的に引き伸ばし、優先経路（プライマリパス）を明示的に制御します。また、必要に応じて `Local Preference` を調整し、送信トラフィックの経路を固定します。

---

## 5. 運用検証コマンドとステータス確認

設計した動的BGPルーティングが正常に機能しているか、以下の検証コマンドを用いてステータスを確認します。

### BGPネイバー接続状態の確認

```text
# show ip bgp summary

IPv4 Unicast Summary:
BGP router identifier 192.168.1.1, local AS number 65001 vrf default
BGP table version 4
RIB entries 7, using 1344 bytes
Peers 3, using 61 KiB

Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down     State/PfxRcd   PfxSnt
169.254.100.1   4      64512    1420    1425        0    0    0 23:14:05                5        1
169.254.100.5   4      64512    1418    1422        0    0    0 23:12:10                5        1
10.0.0.2        4      12076     980     985        0    0    0 08:45:12                8        1
```

### 学習したBGPルートの確認

```text
# show ip route bgp

Codes: K - kernel route, C - connected, S - static, R - RIP,
       B - BGP, O - OSPF, IA - OSPF inter area,
       V - VPNv4, NHRP - Next Hop Resolution Protocol

B&gt;* 172.16.0.0/16 [20/0] via 169.254.100.1, eth1, weight 1, 23:14:10
  *                     via 169.254.100.5, eth2, weight 1, 23:12:15
B&gt;* 10.200.0.0/16 [20/0] via 10.0.0.2, eth3, weight 1, 08:45:17
```

### 経路追跡による対称性の確認

```text
$ traceroute 172.16.10.100
traceroute to 172.16.10.100 (172.16.10.100), 30 hops max, 60 byte packets
 1  192.168.1.254 (192.168.1.254)  0.421 ms  0.388 ms  0.352 ms
 2  169.254.100.1 (169.254.100.1)  2.114 ms  2.085 ms  2.051 ms
 3  172.16.10.100 (172.16.10.100)  3.452 ms  3.411 ms  3.389 ms
```

---

## 6. Operational Notes

マルチクラウドにおける動的ルーティングの導入は、単に接続性を確保するだけでなく、運用の簡素化と障害復旧の自動化を実現するための基盤です。BGPキープアライブタイマーやホールドタイムの最適化（例: BFD（Bidirectional Forwarding Detection）の併用）を行うことで、物理リンク障害発生時にミリ秒単位での高速フェイルオーバーが可能になります。プレフィックスフィルタリングの標準化とASパス制御を徹底し、予測可能で堅牢なマルチクラウドネットワークを維持することが、インフラ全体の信頼性を担保する鍵となります。
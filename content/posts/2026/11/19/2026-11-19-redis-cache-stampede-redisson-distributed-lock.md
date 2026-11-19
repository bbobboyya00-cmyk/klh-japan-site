---
title: "Redisキャッシュ戦略におけるCache Stampede対策とRedisson分散ロックの実装"
slug: "redis-cache-stampede-redisson-distributed-lock"
date: 2026-11-19T11:35:03+09:00
draft: false
image: ""
description: "高トラフィック環境におけるRedisのCache Stampede回避手法と、Redissonを用いたPub/Subベース分散ロックの正確な実装構造を解説します。"
categories: ["Backend Architecture"]
tags: ["cache stampede"]
author: "K-Life Hack"
---

リレーショナルデータベース（RDBMS）を中心とするWebアプリケーションアーキテクチャでは、トラフィック急増に伴うディスクI/Oおよび接続プール枯渇がシステム全体の応答遅延やタイムアウトを引き起こす要因となります。インメモリデータストアであるRedisをキャッシュレイヤーとして導入することでリード性能の向上が期待できますが、不適切なキャッシュ設計や無効化戦略は、特定キーの有効期限切れによるデータベースへの負荷集中（Cache Stampede）や、並行処理時のデータ不整合といった問題を引き起こすリスクがあります。

本稿では、主要なキャッシュパターンの選定基準、Redissonを用いた分散ロックの実装、および本番運用におけるCache Stampede対策とメモリ管理手法について解説します。

## 1. キャッシュパターンの分類と適用基準

データの整合性要件や書き込み遅延の許容度に応じて、適切なキャッシュパターンを選択する必要があります。

```
+-----------------------------------------------------------------------------------+
|                                CACHING PATTERNS                                  |
+--------------------------+--------------------------+-----------------------------+
|      Cache-Aside         |      Write-Through       |   Write-Back (Write-Behind) |
|  (Read Optimization)     |   (Consistency First)    |    (Write Optimization)     |
+--------------------------+--------------------------+-----------------------------+
|  1. App reads Cache      |  1. App writes Cache     |  1. App writes Cache only   |
|  2. Miss -&gt; Read DB      |  2. Cache writes DB      |  2. Async batch updates DB  |
|  3. Populate Cache       |     (Synchronously)      |                             |
+--------------------------+--------------------------+-----------------------------+
```

### Cache-Aside (Look-Aside)

読取操作の最適化を目的とした一般的なパターンです。アプリケーションはまずRedisへ問い合わせ、キャッシュミスの発生時にRDBMSからデータを取得してRedisへ書き戻します。Redisノードに障害が発生した場合でもデータベースへフォールバックされるためシステムの可用性は維持されますが、ホットキーのTTL（Time-To-Live）失効時にリクエストが一斉にDBへ到達するトレードオフが存在します。

データ更新時には「DBを更新した後にRedisのキーを削除する」順序が標準的ですが、並行読み取りとのレースコンディションを防ぐため、短期間のTTL設定やDelayed Double Deleteパターンの検討が必要となります。

### Write-Through

書き込み操作時にRedisキャッシュとRDBMSへ同期的に更新処理を行います。キャッシュとデータベース間の整合性が高く保たれ、常に最新のデータをキャッシュから提供できます。一方で、全書き込み操作で同期二重書き込みが発生するためレイテンシが増加し、参照されないデータもキャッシュ領域を圧迫する要因となります。

### Write-Back (Write-Behind)

アプリケーションはRedisへのみ書き込みを行い、応答を即座に返します。バックグラウンドの非同期プロセスが定期的にバッチ処理でRDBMSへ変更を反映します。高頻度の書き込みトラフィックを吸収する用途に適していますが、非同期処理の完了前にRedisインスタンスがクラッシュした場合、非永続データが永久に失われるリスクがあります。

## 2. Redissonによる分散ロックの実装と並行性制御

単一インスタンス上のJava標準ロック（<code>synchronized</code>や<code>ReentrantLock</code>）は、複数ノードで構成される分散アプリケーション環境では機能しません。また、RDBMSの悲観的ロック（<code>SELECT ... FOR UPDATE</code>）は高い並列度において接続プールを急速に消費し、デッドロックの要因となります。

RedissonはRedisのシングルスレッドイベントループとPub/Subイベント通知機構を活用し、スピンロックによる無駄なCPU消費を回避しながら安全な分散ロック（<code>RLock</code>）を提供します。

```java
package com.example.service;

import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.concurrent.TimeUnit;

@Service
public class StockService {

    private final RedissonClient redissonClient;
    private final ItemRepository itemRepository;

    public StockService(RedissonClient redissonClient, ItemRepository itemRepository) {
        this.redissonClient = redissonClient;
        this.itemRepository = itemRepository;
    }

    public void decreaseStock(Long itemId, int quantity) {
        RLock lock = redissonClient.getLock("stock:" + itemId);
        boolean acquired = false;
        try {
            // ロック取得を最大3秒間待機、取得後は5秒後に自動解放
            acquired = lock.tryLock(3, 5, TimeUnit.SECONDS);
            if (!acquired) {
                throw new IllegalStateException("Lock acquisition timed out for item: " + itemId);
            }
            // データベーストランザクションはロック取得の内部境界で実行
            executeDecreaseTransactional(itemId, quantity);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("Thread interrupted during lock acquisition", e);
        } finally {
            if (acquired &amp;&amp; lock.isLocked() &amp;&amp; lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }

    @Transactional
    public void executeDecreaseTransactional(Long itemId, int quantity) {
        Item item = itemRepository.findById(itemId)
                .orElseThrow(() -&gt; new IllegalArgumentException("Item not found: " + itemId));
        item.decrease(quantity);
        itemRepository.save(item);
    }
}
```

分散ロックを運用する際、<code>tryLock</code>で明示的な <code>leaseTime</code> を指定しない場合、RedissonはWatchdog機能を起動し、スレッドが生存している限り10秒ごとにロック期限を30秒へ自動延長します。

## 3. Cache Stampedeの回避と本番運用チェックリスト

大量のリクエストが集中的に参照するホットキーのTTLが切れた瞬間、多数のスレッドが同時にデータベースへアクセスし、再計算を実行しようとする現象をCache Stampedeと呼びます。

### 緩和戦略

1. 💡 <b>TTL Jitter（ランダムジッターの付与）:</b>
各キーのTTL設定時にベース時間に加え $\pm 10\% \sim 20\%$ のランダムな揺らぎを動的に追加し、同時失効を分散させます。

2. 🛠️ <b>Distributed Recomputation Lock（再計算の単一化）:</b>
キャッシュミス発生時、分散ロックを取得できた1つのリクエストのみがDBからデータを取得して再計算を行い、他のリクエストは短時間の待機または古いキャッシュデータ（Stale Payload）を返却するように設計します。

3. ⚠️ <b>Probabilistic Early Recomputation (PER):</b>
アクセス頻度と再計算コストに基づき、TTLが完全に失効する前に確率的な計算を行ってバックグラウンドでキャッシュを更新します。

### メモリおよびエビクションポリシーの最適化

・ <b><code>maxmemory</code> 設定の標準化:</b> <code>maxmemory</code> を設定しない場合、OSのOOM KillerによってRedisプロセスが強制終了されるリスクが生じます。

・ <b>エビクション戦略の選択:</b> TTLが設定されたキーのみを対象とする場合は <code>volatile-lru</code>、専用キャッシュ層として全体を対象とする場合は <code>allkeys-lru</code> を選択します。キャッシュ層において <code>noeviction</code> の使用は厳禁です。

・ <b>非ブロッキング削除の徹底:</b> 大規模構造のキー削除時に同期コマンド <code>DEL</code> を使用すると、シングルスレッド処理が停止します。非同期でメモリ解放を行う <code>UNLINK</code> の使用を徹底します。

## Troubleshooting

### トランザクション境界とロック解放の不整合（Dirty Reads）

<code>@Transactional</code> アノテーションが付与されたメソッド内部で <code>lock.unlock()</code> が呼び出されると、DBのコミットが完了する前にロックが解放されます。この瞬間に別スレッドがロックを取得すると、未コミットの古い状態を参照する競合が発生します。<b>ロックの取得・解放は必ずDBトランザクションの外側で行う</b>必要があります。

### 権限外ロックの解放による例外発生

TTL超過により自スレッドのロックが既に自動解放されている場合、他スレッドが所有権を持つロックに対して <code>unlock()</code> を実行すると <code>IllegalMonitorStateException</code> が送出されます。解放前には必ず <code>lock.isHeldByCurrentThread()</code> による検証を行ってください。

### システム検証ログ

本番環境におけるメモリ状態および操作の健全性は、CLI ログ等を通じて定期的に検証を行います。

```text
$ redis-cli info memory
# Memory
used_memory:268435456
used_memory_human:256.00M
used_memory_rss:314572800
used_memory_rss_human:300.00M
mem_fragmentation_ratio:1.17
mem_allocator:jemalloc-5.3.0

$ redis-cli slowlog get 5
1) 1) (integer) 12
   2) (integer) 1700000000
   3) (integer) 15200
   4) 1) "UNLINK"
      2) "stock:cache:1004"

$ redis-cli eval "return redis.call('ttl', KEYS[1])" 1 "stock:1001"
(integer) 298
```

## Lessons Learned

Redisを用いた高並列キャッシュ基盤の運用においては、単なるデータ保持層としての利用にとどまらず、TTLジッターの付与や再計算の並行制御、メモリ溢れ防止策（<code>maxmemory</code> および <code>UNLINK</code> の活用）を包括的に設計することが不可欠です。適切な分散ロック境界の設計と運用モニタリングを実施することで、高トラフィック下においてもDB負荷を最小限に抑えた安定稼働が実現できます。
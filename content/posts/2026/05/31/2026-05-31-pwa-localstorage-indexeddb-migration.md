---
title: "PWAにおけるLocalStorageデータ消失の解析とlocalForageによるIndexedDB移行手順"
slug: "pwa-localstorage-indexeddb-migration"
date: 2026-05-22T10:42:03+09:00
draft: false
image: ""
description: "PWA環境でLocalStorageのデータが突然消失する挙動の根本原因を解析し、localForageを用いたIndexedDBへの移行、データ永続化の検証手順を解説します。"
categories: ["DevOps Logistics"]
tags: ["localforage", "indexeddb", "localstorage", "pwa", "storage-eviction"]
author: "K-Life Hack"
---

## PWA環境におけるLocalStorageデータ突然消失の発生事象

PWA（Progressive Web App）としてデプロイされたルーティン管理アプリケーション「Dan-Haru」において、本番稼働から約1ヶ月が経過した時点で、ユーザーの全ルーティン記録、カスタム設定、構成パラメータが完全に初期化されるデータ消失事象が発生しました。

デベロッパーツールのコンソールログには、以下の例外および空のデータ状態が記録されていました。

```javascript
// Console Log
Uncaught DOMException: Failed to execute 'setItem' on 'Storage': Setting the value of 'routine_activity_log' exceeded the quota.
localStorage.getItem('routine_app_user_data') -&gt; null
```

この事象は、アプリケーションの新規インストール直後と全く同じ状態であり、クライアントサイドのデータストアが完全に消去されたことを示しています。

## ⚠️ iOSのEvictionポリシーと5MB容量制限によるデータ消失の根本原因

このデータ消失が発生した技術的要因は、ブラウザのLocalStorage仕様およびOSのストレージ管理アルゴリズムに起因する以下の3点です。

### 1. OSによるストレージの強制クリーンアップ（Storage Eviction）

iOS/iPadOS（Safari/WebKit Webview）環境では、PWAが7日間連続して起動されない場合、またはデバイスの空き容量が極端に低下した場合、OSはLocalStorageを「一時的なキャッシュファイル」とみなして自動的に削除します。これが<b><mark>Storage Eviction</mark></b>ポリシーです。また、バックグラウンドプロセスがメモリ（RAM）逼迫により強制終了された際、LocalStorageへの書き込み処理が途中で遮断され、ファイル破損によるデータリセットが発生します。

### 2. 容量制限（5MB）の超過による書き込みエラー

LocalStorageの最大容量は5MBに制限されています。高頻度ユーザーのデータ蓄積シミュレーション（30グループ × 各30ルーティン = 計900ルーティン）を行った結果、1日あたりのデータ蓄積量は約237KBに達することが判明しました。

* `routine_activity_log` (1440分ヒートマップ): 約2.9 KB
* `WakeUpTimeHistory`: 約0.08 KB
* `RoutineGroupHistory` (30グループ): 約7.8 KB
* `TaskHistory` (900ルーティン): 約180 KB
* `routine_app_user_data` (メタデータ): 約46.2 KB
* <b>1日あたりの合計蓄積量</b>: <b>約237 KB/日</b>

このデータ密度に基づくと、5MBの制限値にはわずか<b>約21日</b>で到達し、以降の書き込みは `QuotaExceededError` をスローして失敗します。例外処理内で `localStorage.clear()` などのリセットロジックが誤って実行された場合、全データが消失します。

## 💡 localForageを用いたIndexedDB移行によるデータ永続化の実装

LocalStorageの容量制限（5MB）および揮発性を排除するため、非同期処理に対応し、デバイス空き容量の最大50%まで利用可能なIndexedDBへ移行します。ラッパーライブラリとして<b><mark>localForage</mark></b>（v1.10.0）を採用し、既存の同期処理コードを非同期処理へリファクタリングします。

### 1. localForageの初期化と移行スクリプトの実装

LocalStorageからデータを抽出し、IndexedDBへ安全にマイグレーションする処理を実装します。

```javascript
import localforage from 'localforage';

localforage.config({
driver: localforage.INDEXEDDB,
name: 'Dan-Haru',
storeName: 'user_settings'
});

async function migrateFromLocalStorage() {
const keys = [
'routine_activity_log',
'WakeUpTimeHistory',
'RoutineGroupHistory',
'TaskHistory',
'routine_app_user_data'
];

for (const key of keys) {
const localData = localStorage.getItem(key);
if (localData) {
try {
await localforage.setItem(key, JSON.parse(localData));
localStorage.removeItem(key);
} catch (error) {
console.error(`Migration failed for key ${key}:`, error);
}
}
}
}
```

### 2. データ容量を抑制するFIFO（First-In-First-Out）プルーニングの実装

データ容量の肥大化を防ぐため、30日以上経過した詳細ログを自動的に削除し、統計データのみを残すプルーニングロジックを組み込みます。

```javascript
async function pruneOldLogs() {
const thresholdDate = new Date();
thresholdDate.setDate(thresholdDate.getDate() - 30);
const limitTime = thresholdDate.getTime();

try {
const logs = await localforage.getItem('routine_activity_log') || [];
const filteredLogs = logs.filter(log =&gt; new Date(log.timestamp).getTime() &gt;= limitTime);
await localforage.setItem('routine_activity_log', filteredLogs);
} catch (error) {
console.error("Pruning failed:", error);
}
}
```

## 🛠️ 移行後のデータ永続化状態およびストレージ使用量の検証手順

移行処理が正常に動作しているか、および永続化ストレージとしてOSに認識されているかを検証します。

### 1. ブラウザのストレージ見積もりAPIによる容量検証

コンソールから `navigator.storage.estimate()` を実行し、割り当てられたクォータと現在の使用量を確認します。

```javascript
if (navigator.storage &amp;&amp; navigator.storage.estimate) {
navigator.storage.estimate().then(estimate =&gt; {
console.log(`Quota: ${estimate.quota} bytes`);
console.log(`Usage: ${estimate.usage} bytes`);
});
}
```

実行結果の出力例：

```json
{
"quota": 21474836480,
"usage": 242688
}
```

これにより、従来の5MB制限を超えてギガバイト単位のクォータが確保されていることが確認できます。

### 2. 永続化ストレージ（Persistent Storage）の要求と確認

ブラウザに対して、ストレージの自動削除対象から除外するよう明示的に要求します。

```javascript
if (navigator.storage &amp;&amp; navigator.storage.persist) {
navigator.storage.persist().then(granted =&gt; {
console.log(`Persistent storage granted: ${granted}`);
});
}
```

実行結果：

```javascript
true
```

`true` が返却されることで、OSの空き容量低下時にもIndexedDBのデータが強制削除（Eviction）されない保護状態が確立されたことを検証しました。
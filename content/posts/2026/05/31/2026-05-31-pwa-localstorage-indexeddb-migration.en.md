---
title: "Analysis of LocalStorage Data Loss in PWA and IndexedDB Migration Steps via localForage"
slug: "pwa-localstorage-indexeddb-migration"
date: 2026-05-22T10:42:03+09:00
draft: false
image: ""
description: "Analyzes the root cause of sudden LocalStorage data loss in PWA environments and explains the migration to IndexedDB using localForage and verification steps for data persistence."
categories: ["DevOps Logistics"]
tags: ["localforage", "indexeddb", "localstorage", "pwa", "storage-eviction"]
author: "K-Life Hack"
---

## Incident: Sudden LocalStorage Data Loss in PWA Environment

In "Dan-Haru," a routine management application deployed as a PWA (Progressive Web App), a data loss incident occurred approximately one month after production launch, where all user routine records, custom settings, and configuration parameters were completely initialized.


The developer tools console log recorded the following exceptions and empty data states:



```javascript
// Console Log
Uncaught DOMException: Failed to execute 'setItem' on 'Storage': Setting the value of 'routine_activity_log' exceeded the quota.
localStorage.getItem('routine_app_user_data') -&gt; null
```

This state is identical to a fresh application installation, indicating that the client-side data store was completely wiped.



## ⚠️ Root Causes of Data Loss: iOS Eviction Policy and 5MB Capacity Limit

The technical factors causing this data loss stem from the following three points related to browser LocalStorage specifications and OS storage management algorithms:



### 1. Forced Storage Cleanup by OS (Storage Eviction)

In iOS/iPadOS (Safari/WebKit Webview) environments, if a PWA is not launched for seven consecutive days, or if device free space becomes extremely low, the OS treats LocalStorage as "temporary cache files" and deletes them automatically. This is the <b><mark>Storage Eviction</mark></b> policy. Additionally, when background processes are force-terminated due to memory (RAM) pressure, write operations to LocalStorage are interrupted, leading to data resets due to file corruption.



### 2. Write Errors Due to Exceeding Capacity Limit (5MB)

The maximum capacity of LocalStorage is limited to 5MB. Data accumulation simulations for high-frequency users (30 groups × 30 routines each = 900 routines total) revealed that daily data accumulation reaches approximately 237KB.



* `routine_activity_log` (1440-minute heatmap): Approx. 2.9 KB
* `WakeUpTimeHistory`: Approx. 0.08 KB
* `RoutineGroupHistory` (30 groups): Approx. 7.8 KB
* `TaskHistory` (900 routines): Approx. 180 KB
* `routine_app_user_data` (metadata): Approx. 46.2 KB
* <b>Total daily accumulation</b>: <b>Approx. 237 KB/day</b>
Based on this data density, the 5MB limit is reached in just <b>approx. 21 days</b>, after which subsequent writes fail by throwing a `QuotaExceededError`. If reset logic such as `localStorage.clear()` is erroneously executed within exception handling, all data is lost.



## 💡 Implementing Data Persistence via IndexedDB Migration using localForage

To eliminate the 5MB capacity limit and volatility of LocalStorage, migrate to IndexedDB, which supports asynchronous processing and can utilize up to 50% of available device space. <b><mark>localForage</mark></b> (v1.10.0) is adopted as a wrapper library, and existing synchronous code is refactored into asynchronous processing.



### 1. Initialization of localForage and Implementation of Migration Script

Implement logic to extract data from LocalStorage and safely migrate it to IndexedDB.



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

### 2. Implementation of FIFO (First-In-First-Out) Pruning to Control Data Volume

To prevent data bloat, incorporate pruning logic that automatically deletes detailed logs older than 30 days while retaining only statistical data.



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

## 🛠️ Verification Procedures for Data Persistence and Storage Usage Post-Migration

Verify whether the migration process is functioning correctly and if the OS recognizes it as persistent storage.



### 1. Capacity Verification via Browser Storage Estimate API

Execute `navigator.storage.estimate()` from the console to check the allocated quota and current usage.



```javascript
if (navigator.storage &amp;&amp; navigator.storage.estimate) {
navigator.storage.estimate().then(estimate =&gt; {
console.log(`Quota: ${estimate.quota} bytes`);
console.log(`Usage: ${estimate.usage} bytes`);
});
}
```

Example output of execution results:



```json
{
"quota": 21474836480,
"usage": 242688
}
```

This confirms that a quota in the gigabyte range has been secured, exceeding the traditional 5MB limit.



### 2. Requesting and Confirming Persistent Storage

Explicitly request the browser to exclude the storage from automatic deletion targets.



```javascript
if (navigator.storage &amp;&amp; navigator.storage.persist) {
navigator.storage.persist().then(granted =&gt; {
console.log(`Persistent storage granted: ${granted}`);
});
}
```

Execution result:



```javascript
true
```

By returning `true`, it is verified that a protected state has been established where IndexedDB data is not subject to forced deletion (Eviction) even when device free space is low.


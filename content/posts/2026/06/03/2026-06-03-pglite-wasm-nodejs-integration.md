---
title: "WASMベースPostgreSQL PGliteのNodejs組み込みと検証"
slug: "pglite-wasm-nodejs-integration"
date: 2026-06-01T08:12:26+09:00
draft: false
image: ""
description: "Node.js環境でWASMベースのPostgresであるPGliteを初期化し、トランザクションを用いたバッチ挿入のベンチマークや同期処理を検証した実装ノート。"
categories: ["Backend Architecture"]
tags: ["pglite", "wasm", "postgresql", "nodejs", "embedded-database"]
author: "K-Life Hack"
---

## 概要とアーキテクチャの特徴

PGliteは、WebAssembly (WASM) にコンパイルされ、クライアントサイドJavaScriptライブラリとしてパッケージ化された、完全に動作する軽量なPostgreSQLエンジンです。ElectricSQLによって開発されたPGliteを使用することで、開発者は個別のPostgreSQLサーバー、Dockerコンテナ、または外部デーモンを必要とせずに、Node.jsランタイム、Webブラウザ、またはモバイル環境（React Native/Capacitor経由）でPostgreSQLデータベースを直接実行できます。

本稿では、Node.js環境におけるPGliteの初期化、操作、ベンチマーク、およびハイブリッド同期ワークフローのシミュレーション手順について解説します。

### 主なアーキテクチャの特徴

💡 <b>WASM駆動のPostgreSQLエンジン:</b> WebAssemblyにコンパイルされた実際のPostgreSQLエンジンを実行するため、SQL構文の互換性が維持されます。

🛠️ <b>環境に応じたストレージ抽象化:</b> Node.js環境ではローカルファイルシステムを自動的に利用してデータを永続化し、ブラウザ環境ではIndexedDBにフォールバックします。

⚡ <b>ネットワークオーバーヘッドの排除:</b> データベースクエリがインプロセスで実行されるため、従来のデータベース接続に伴うネットワーク遅延が発生しません。

---

## プロジェクトのセットアップと環境設定

ES Modulesを使用するように構成されたNode.js環境を構築し、必要なPGlite依存関係をインストールします。

```bash
# 1. プロジェクトディレクトリの作成と移動
mkdir pglite-demo
cd pglite-demo

# 2. package.jsonの初期化とES Modulesの 有効化
npm init -y
npm pkg set type="module"

# 3. PGliteライブラリのインストール
npm install @electric-sql/pglite
```

---

## 実装コード (`index.js`)

プロジェクトのルートディレクトリに `index.js` ファイルを作成し、データベースの初期化、トランザクションを使用した一括挿入ベンチマーク、標準的なCRUD操作、およびオフラインファーストの同期サイクルのシミュレーションを実行するロジックを実装します。

```javascript
import { PGlite } from "@electric-sql/pglite";

// PGliteインスタンスの初期化
// ローカルの "./pgdata" ディレクトリに永続的なPostgreSQLデータベースを作成またはロードします。
// Node.js環境ではローカルファイルシステムを対象とし、ブラウザ環境ではIndexedDBがデフォルトとなります。
const db = new PGlite("./pgdata");

async function main() {
  console.log("🚀 PGlite (Postgres in WASM) 起動中...\n");

  // 1. テーブルの初期化 (DDLの実行)
  await db.exec(`
    CREATE TABLE IF NOT EXISTS notes (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      content TEXT,
      synced BOOLEAN DEFAULT false,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `);
  console.log("✅ 'notes' テーブル準備完了 (Postgres Engine 稼働)\n");

  // ---------------------------------------------------------
  // 2. パフォーマンスベンチマーク: バルクデータの挿入
  // ---------------------------------------------------------
  console.log("📊 [ベンチマーク] メモ100件の挿入テスト開始...");
  const start = performance.now();

  // トランザクションブロックを使用して操作をバッチ処理します。
  // ネットワークオーバーヘッドがないため、メモリ内のWASM実行は高速です。
  await db.transaction(async (tx) => {
    for (let i = 0; i < 100; i++) {
      await tx.query(
        "INSERT INTO notes (title, content) VALUES ($1, $2)",
        [`メモ #${i}`, `これは ${i} 回目のテストメモです。`]
      );
    }
  });

  const end = performance.now();
  console.log(`⚡ 完了! 所要時間: ${(end - start).toFixed(2)}ms`);
  console.log(`   (1件あたりの平均処理速度: ${((end - start) / 100).toFixed(2)}ms)\n`);

  // ---------------------------------------------------------
  // 3. CRUDシナリオの実行
  // ---------------------------------------------------------
  console.log("📝 [CRUD シナリオ] 実行");

  // [Create] - 単一レコードを挿入し、作成された行を返す
  const newNote = await db.query(
    "INSERT INTO notes (title, content) VALUES ($1, $2) RETURNING *",
    ["重要ミーティング", "午後2時: Q3ロードマップ議論"]
  );
  console.log("1. メモ作成:", newNote.rows[0]);

  // [Update] - 作成されたレコードの内容を更新
  const updatedNote = await db.query(
    "UPDATE notes SET content = $1 WHERE id = $2 RETURNING *",
    ["午後3時に変更: Q3ロードマップ議論", newNote.rows[0].id]
  );
  console.log("2. メモ修正:", updatedNote.rows[0]);

  // [Read] - 直近のレコードを3件取得
  const list = await db.query("SELECT * FROM notes ORDER BY created_at DESC LIMIT 3");
  console.log("3. 直近のメモ参照 (Top 3):");
  console.table(list.rows.map(n => ({ id: n.id, title: n.title, content: n.content })));

  // ---------------------------------------------------------
  // 4. ハイブリッド同期のシミュレーション
  // ---------------------------------------------------------
  console.log("\n🔄 [同期] バックエンド同期シミュレーション...");

  // 未同期のローカルレコード (synced = false) を取得
  const unsyncedParams = await db.query("SELECT * FROM notes WHERE synced = false");
  const unsyncedCount = unsyncedParams.rows.length;

  if (unsyncedCount > 0) {
    console.log(`   -> 同期対象: ${unsyncedCount}件検出`);
    
    // リモートサーバーへのデータ送信を模したネットワーク遅延 (500ms) のシミュレーション
    await new Promise(r => setTimeout(r, 500));
    console.log("   -> ☁️ バックエンド送信完了 (Mock Server)");

    // ローカルデータベースの状態を更新し、同期済みとしてマーク
    const ids = unsyncedParams.rows.map(n => n.id);
    await db.query("UPDATE notes SET synced = true WHERE id = ANY($1)", [ids]);
    console.log("   -> ✅ ローカルDBステータスを 'Synced' に更新完了");
  } else {
    console.log("   -> 同期するデータはありません。");
  }

  // ---------------------------------------------------------
  // 実行終了
  // ---------------------------------------------------------
  console.log("\n🎉 すべてのデモが正常に完了しました。");
}

main().catch((err) => {
  console.error("❌ エラー発生:", err);
});
```

---

## 実行手順と期待される出力

スクリプトを実行するには、ターミナルで以下のコマンドを実行します。

```bash
node index.js
```

### 期待されるコンソール出力例

```text
🚀 PGlite (Postgres in WASM) 起動中...

✅ 'notes' テーブル準備完了 (Postgres Engine 稼働)

📊 [ベンチマーク] メモ100件の挿入テスト開始...
⚡ 完了! 所要時間: 42.50ms
   (1件あたりの平均処理速度: 0.43ms)

📝 [CRUD シナリオ] 実行
1. メモ作成: { id: 101, title: '重要ミーティング', ... }
2. メモ修正: { id: 101, title: '重要ミーティング', content: '午後3時に変更...', ... }
3. 直近のメモ参照 (Top 3):
┌─────────┬──────────────┬────────────────────────────┐
│ (index) │      id      │           title            │
├─────────┼──────────────┼────────────────────────────┤
│    0    │     101      │     '重要ミーティング'      │
│    1    │     100      │        'メモ #99'          │
│    2    │      99      │        'メモ #98'          │
└─────────┴──────────────┴────────────────────────────┘

🔄 [同期] バックエンド同期シミュレーション...
   -> 同期対象: 101件検出
   -> ☁️ バックエンド送信完了 (Mock Server)
   -> ✅ ローカルDBステータスを 'Synced' に更新完了

🎉 すべてのデモが正常に完了しました。
```

---

## アーキテクチャおよび性能の検証ポイント

この実装により、PGliteの3つの重要な機能特性が実証されます。

### 1. インプロセス実行による低遅延

トランザクションブロック内で100件のレコードを順次挿入する処理は、数十ミリ秒（例: <b>約42.50ms</b>、1レコードあたり<b>約0.43ms</b>）で完了します。従来のクライアント・サーバー型データベース構成では、ネットワークの往復、TCPハンドシェイク、およびコネクションプーリングのオーバーヘッドにより、同様の処理に秒単位の時間を要することがあります。PGliteは、データベースエンジンをインプロセスで実行することで、極めて低いオーバーヘッドを実現します。

### 2. PostgreSQL構文との互換性

軽量なキーバリューストアや簡易的なSQL風エンジンとは異なり、PGliteは実際のPostgreSQLエンジンを動作させています。そのため、以下を含む標準的なPostgreSQLのSQL構文をそのままサポートします。

・ 複雑なDDL (`CREATE TABLE IF NOT EXISTS`)

・ トランザクション制御 (`db.transaction`)

・ RETURNING句を伴うデータ操作 (`INSERT ... RETURNING *`)

・ 配列パラメータを用いた高度なクエリ演算 (`WHERE id = ANY($1)`)

### 3. データの永続性

このスクリプトを複数回実行すると、データが `./pgdata` ディレクトリ内に永続化されていることが確認できます。自動インクリメントされる主キー（`id`）は1にリセットされず、実行をまたいで増加し続けます（例: 2回目以降の実行では101から開始）。これにより、PGliteが単なるメモリ内の一時的なモックではなく、永続的で信頼性の高いデータベースエンジンとして機能していることが証明されます。

---

## Operational Notes

💡 <b>ストレージの選択:</b> Node.js環境ではファイルシステムが使用されますが、ブラウザ環境で動作させる場合は、自動的にIndexedDBが選択されます。環境ごとのストレージアダプタの挙動に留意してください。

⚠️ <b>リソース消費:</b> WASM上でフル機能のPostgreSQLを実行するため、メモリ消費量は一般的なキーバリューストアよりも大きくなります。リソース制限の厳しいエッジ環境や古いモバイル端末に展開する場合は、実機でのメモリプロファイリングを推奨します。

⚠️ <b>同時実行制御:</b> PGliteはシングルプロセス指向の設計となっています。同一 of データディレクトリに対して複数のNode.jsプロセスから同時に書き込みアクセスを行うと、ロック競合やデータ破損の原因となるため、適切なアクセス制御の設計が必要です。
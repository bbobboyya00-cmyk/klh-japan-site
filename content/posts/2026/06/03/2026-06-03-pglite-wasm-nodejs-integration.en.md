---
title: "Node.js Integration and Verification of WASM-Based PostgreSQL PGlite"
slug: "pglite-wasm-nodejs-integration"
date: 2026-06-01T08:12:26+09:00
draft: false
image: ""
description: "An implementation note verifying the initialization of PGlite (a WASM-based Postgres) in a Node.js environment"
categories: ["Backend Architecture"]
tags: ["en_translation"]
author: "K-Life Hack"
---

## Overview and Architectural Features

PGlite is a fully functional, lightweight PostgreSQL engine compiled to WebAssembly (WASM) and packaged as a client-side JavaScript library. Developed by ElectricSQL, PGlite allows developers to run a PostgreSQL database directly within a Node.js runtime, web browser, or mobile environment (via React Native/Capacitor) without requiring a separate PostgreSQL server, Docker container, or external daemon.


This article describes the steps for initializing, operating, benchmarking, and simulating a hybrid synchronization workflow with PGlite in a Node.js environment.



### Key Architectural Features

- 💡 <b>WASM-Driven PostgreSQL Engine:</b> Runs an actual PostgreSQL engine compiled to WebAssembly, maintaining SQL syntax compatibility.
- 🛠️ <b>Environment-Aware Storage Abstraction:</b> Automatically utilizes the local file system for data persistence in Node.js environments, and falls back to IndexedDB in browser environments.
- ⚡ <b>Elimination of Network Overhead:</b> Database queries are executed in-process, eliminating the network latency associated with traditional database connections.

---

## Project Setup and Environment Configuration

Set up a Node.js environment configured to use ES Modules and install the required PGlite dependencies.



```bash
# 1. Create and navigate to the project directory
mkdir pglite-demo
cd pglite-demo

# 2. Initialize package.json and enable ES Modules
npm init -y
npm pkg set type="module"

# 3. Install the PGlite library
npm install @electric-sql/pglite
```

---

## Implementation Code (`index.js`)

Create an `index.js` file in the project root directory and implement the logic to initialize the database, benchmark batch insertions using transactions, perform standard CRUD operations, and simulate an offline-first synchronization cycle.



```javascript
import { PGlite } from "@electric-sql/pglite";

// Initialize PGlite instance
// Creates or loads a persistent PostgreSQL database in the local "./pgdata" directory.
// Targets the local file system in Node.js environments, and defaults to IndexedDB in browser environments.
const db = new PGlite("./pgdata");

async function main() {
  console.log("🚀 Starting PGlite (Postgres in WASM)...\n");

  // 1. Initialize table (Execute DDL)
  await db.exec(`
    CREATE TABLE IF NOT EXISTS notes (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      content TEXT,
      synced BOOLEAN DEFAULT false,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `);
  console.log("✅ 'notes' table ready (Postgres Engine running)\n");

  // ---------------------------------------------------------
  // 2. Performance Benchmark: Bulk Data Insertion
  // ---------------------------------------------------------
  console.log("📊 [Benchmark] Starting insertion test of 100 notes...");
  const start = performance.now();

  // Batch operations using a transaction block.
  // Since there is no network overhead, in-memory WASM execution is fast.
  await db.transaction(async (tx) =&gt; {
    for (let i = 0; i &lt; 100; i++) {
      await tx.query(
        "INSERT INTO notes (title, content) VALUES ($1, $2)",
        [`Note #${i}`, `This is test note number ${i}.`]
      );
    }
  });

  const end = performance.now();
  console.log(`⚡ Completed! Elapsed time: ${(end - start).toFixed(2)}ms`);
  console.log(`   (Average processing speed per item: ${((end - start) / 100).toFixed(2)}ms)\n`);

  // ---------------------------------------------------------
  // 3. Execution of CRUD Scenarios
  // ---------------------------------------------------------
  console.log("📝 [CRUD Scenario] Executing");

  // [Create] - Insert a single record and return the created row
  const newNote = await db.query(
    "INSERT INTO notes (title, content) VALUES ($1, $2) RETURNING *",
    ["Important Meeting", "2:00 PM: Q3 Roadmap Discussion"]
  );
  console.log("1. Note Created:", newNote.rows[0]);

  // [Update] - Update the content of the created record
  const updatedNote = await db.query(
    "UPDATE notes SET content = $1 WHERE id = $2 RETURNING *",
    ["Changed to 3:00 PM: Q3 Roadmap Discussion", newNote.rows[0].id]
  );
  console.log("2. Note Updated:", updatedNote.rows[0]);

  // [Read] - Retrieve the 3 most recent records
  const list = await db.query("SELECT * FROM notes ORDER BY created_at DESC LIMIT 3");
  console.log("3. Recent Notes Reference (Top 3):");
  console.table(list.rows.map(n =&gt; ({ id: n.id, title: n.title, content: n.content })));

  // ---------------------------------------------------------
  // 4. Hybrid Synchronization Simulation
  // ---------------------------------------------------------
  console.log("\n🔄 [Sync] Simulating backend synchronization...");

  // Retrieve unsynced local records (synced = false)
  const unsyncedParams = await db.query("SELECT * FROM notes WHERE synced = false");
  const unsyncedCount = unsyncedParams.rows.length;

  if (unsyncedCount &gt; 0) {
    console.log(`   -&gt; Sync Target: ${unsyncedCount} items detected`);
    
    // Simulate network latency (500ms) representing data transmission to a remote server
    await new Promise(r =&gt; setTimeout(r, 500));
    console.log("   -&gt; ☁️ Backend transmission completed (Mock Server)");

    // Update local database state, marking as synced
    const ids = unsyncedParams.rows.map(n =&gt; n.id);
    await db.query("UPDATE notes SET synced = true WHERE id = ANY($1)", [ids]);
    console.log("   -&gt; ✅ Local DB status updated to 'Synced'");
  } else {
    console.log("   -&gt; No data to synchronize.");
  }

  // ---------------------------------------------------------
  // Execution End
  // ---------------------------------------------------------
  console.log("\n🎉 All demos completed successfully.");
}

main().catch((err) =&gt; {
  console.error("❌ Error occurred:", err);
});
```

---

## Execution Steps and Expected Output

To run the script, execute the following command in your terminal.



```bash
node index.js
```

### Expected Console Output Example

```text
🚀 Starting PGlite (Postgres in WASM)...

✅ 'notes' table ready (Postgres Engine running)

📊 [Benchmark] Starting insertion test of 100 notes...
⚡ Completed! Elapsed time: 42.50ms
   (Average processing speed per item: 0.43ms)

📝 [CRUD Scenario] Executing
1. Note Created: { id: 101, title: 'Important Meeting', ... }
2. Note Updated: { id: 101, title: 'Important Meeting', content: 'Changed to 3:00 PM...', ... }
3. Recent Notes Reference (Top 3):
┌─────────┬──────────────┬────────────────────────────┐
│ (index) │      id      │           title            │
├─────────┼──────────────┼────────────────────────────┤
│    0    │     101      │    'Important Meeting'     │
│    1    │     100      │        'Note #99'          │
│    2    │      99      │        'Note #98'          │
└─────────┴──────────────┴────────────────────────────┘

🔄 [Sync] Simulating backend synchronization...
   -&gt; Sync Target: 101 items detected
   -&gt; ☁️ Backend transmission completed (Mock Server)
   -&gt; ✅ Local DB status updated to 'Synced'

🎉 All demos completed successfully.
```

---

## Architectural and Performance Verification Points

This implementation demonstrates three key functional characteristics of PGlite.



### 1. Low Latency via In-Process Execution

The process of sequentially inserting 100 records within a transaction block completes in tens of milliseconds (e.g., <b>approx. 42.50ms</b>, or <b>approx. 0.43ms</b> per record). In traditional client-server database configurations, similar operations can take seconds due to network round-trips, TCP handshakes, and connection pooling overhead. PGlite achieves extremely low overhead by running the database engine in-process.



### 2. Compatibility with PostgreSQL Syntax

Unlike lightweight key-value stores or simple SQL-like engines, PGlite runs an actual PostgreSQL engine. Therefore, it natively supports standard PostgreSQL SQL syntax, including:



- Complex DDL (`CREATE TABLE IF NOT EXISTS`)
- Transaction control (`db.transaction`)
- Data manipulation with RETURNING clauses (`INSERT ... RETURNING *`)
- Advanced query operations using array parameters (`WHERE id = ANY($1)`)

### 3. Data Persistence

Running this script multiple times confirms that data is persisted within the `./pgdata` directory. The auto-incrementing primary key (`id`) does not reset to 1, but continues to increase across executions (e.g., starting from 101 on the second run). This proves that PGlite functions as a persistent, reliable database engine rather than just a temporary in-memory mock.



---

## Operational Notes

- 💡 <b>Storage Selection:</b> While the file system is used in Node.js environments, IndexedDB is automatically selected when running in browser environments. Keep in mind the behavior of the storage adapter for each environment.
- ⚠️ <b>Resource Consumption:</b> Because a full-featured PostgreSQL runs on WASM, memory consumption is higher than that of typical key-value stores. When deploying to resource-constrained edge environments or older mobile devices, real-device memory profiling is recommended.
- ⚠️ <b>Concurrency Control:</b> PGlite is designed with a single-process orientation. Simultaneous write access to the same data directory from multiple Node.js processes can cause lock contention or data corruption, requiring appropriate access control design.
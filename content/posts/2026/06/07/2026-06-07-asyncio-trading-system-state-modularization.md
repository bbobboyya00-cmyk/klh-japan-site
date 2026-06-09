---
title: "asyncioを用いたシステムトレードにおける状態管理とモジュール化の設計パターン"
slug: "asyncio-trading-system-state-modularization"
date: 2026-06-07T18:18:49+09:00
draft: false
image: ""
description: "asyncioを用いたシステムトレードにおける、状態管理の永続化、リスクベースのポジションサイジング、およびイベント駆動型パイプラインへのリファクタリング手法を解説します。"
categories: ["Backend Architecture"]
tags: ["asyncio", "python", "state-management", "algorithmic-trading", "event-driven"]
author: "K-Life Hack"
---

Pythonの<code>asyncio</code>フレームワークをベースに構築された自動システムトレードにおける、アーキテクチャの再設計とモジュール化について解説します。本システムは、Kiwoom Open API（RESTおよびWebSocketクライアントのハイブリッド）と連携し、システム的な取引戦略を実行するように設計されています。具体的には、ATR（Average True Range）のボラティリティに基づくポジションサイジング、マーク・ミネルヴィニ（Mark Minervini）のトレンドテンプレートに基づくエントリー、動的なピラミッディング、およびトレーリングストップを組み合わせたトレンドフォロー手法を実装します。

## 1. アーキテクチャの概要とリファクタリングの目的

従来の一体型（モノリシック）エンジンでは、注文執行、状態追跡、リスク管理、およびログ記録が密結合しており、保守性と拡張性に課題がありました。今回の再設計では、以下の4つの目的を達成するためにモジュール化を実施しました。

💡 <b>関心の分離（Decoupling of Concerns）</b>: 各コンポーネントを疎結合なイベント駆動型アーキテクチャへ移行します。

🛠️ <b>堅牢な状態永続化（State Persistence）</b>: ローカルのCSVファイル（<code>positions.csv</code>、<code>trades.csv</code>、<code>capital_log.csv</code>）と、リアルタイムのサーバー側残高同期を組み合わせた2層の状態復旧メカニズムを導入します。

🔄 <b>非同期イベントループの統合</b>: 注文発注、リアルタイムのWebSocketクオート処理、および動的なトレーリングストップ計算をノンブロッキングで実行します。

⚠️ <b>体系的なリスク管理</b>: 総資金の1%を許容リスク上限とする厳格なリスクバジェットルールを適用し、ATRに基づいてポジションサイズを動的に決定します。

## 2. ディレクトリ構造とモジュール構成

プロジェクトは、単一ファイル構成から、各コンポーネントが独立した役割を持つパッケージ構造へと再構成されました。これにより、API仕様の変更やロギングフォーマットの変更が他のモジュールに影響を与えないようにします。

```text
project/
│
├── main.py
├── config.py
│
├── position/
│   ├── __init__.py
│   └── position_manager.py
│
├── logs/
│   ├── __init__.py
│   ├── logger.py
│   ├── positions.csv
│   ├── trades.csv
│   └── capital_log.csv
│
└── trading/
    ├── __init__.py
    ├── order.py
    └── trailing_stop.py
```

## 3. 各モジュールの設計と実装コード

### 3.1. ポジション管理（`position/position_manager.py`）

<code>PositionManager</code>は、システムのアクティブなポジションと総資金を管理し、リスクパラメータを動的に計算する役割を担います。

```python
import os
import csv
import logging

class PositionManager:
    def __init__(self, initial_capital=10000000, risk_ratio=0.01):
        self.total_capital = initial_capital
        self.risk_ratio = risk_ratio
        self.active_positions = {}
        self.csv_path = "logs/positions.csv"
        self.load_positions()

    def load_positions(self):
        if os.path.exists(self.csv_path):
            try:
                with open(self.csv_path, mode='r', encoding='utf-8') as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        symbol = row['symbol']
                        self.active_positions[symbol] = {
                            'entry_price': float(row['entry_price']),
                            'highest_price': float(row['highest_price']),
                            'stop_loss': float(row['stop_loss']),
                            'unit_count': int(row['unit_count']),
                            'quantity': int(row['quantity'])
                        }
            except Exception as e:
                logging.error(f"Failed to load positions from CSV: {e}")

    def save_positions(self):
        os.makedirs(os.path.dirname(self.csv_path), exist_ok=True)
        try:
            with open(self.csv_path, mode='w', newline='', encoding='utf-8') as f:
                fieldnames = ['symbol', 'entry_price', 'highest_price', 'stop_loss', 'unit_count', 'quantity']
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                for symbol, pos in self.active_positions.items():
                    writer.writerow({
                        'symbol': symbol,
                        'entry_price': pos['entry_price'],
                        'highest_price': pos['highest_price'],
                        'stop_loss': pos['stop_loss'],
                        'unit_count': pos['unit_count'],
                        'quantity': pos['quantity']
                    })
        except Exception as e:
            logging.error(f"Failed to save positions to CSV: {e}")

    def calculate_position_size(self, atr, entry_price):
        risk_budget = self.total_capital * self.risk_ratio
        stop_loss_range = 2 * atr
        if stop_loss_range <= 0:
            return 0
        quantity = int(risk_budget / stop_loss_range)
        return quantity
```

### 3.2. 取引ロガー（`logs/logger.py`）

<code>TradeLogger</code>は、取引履歴を<code>trades.csv</code>に追記し、資産曲線のデータを<code>capital_log.csv</code>に記録します。また、当日の重複エントリーを防ぐための履歴解析メソッドを提供します。

```python
import os
import csv
from datetime import datetime

class TradeLogger:
    def __init__(self):
        self.trades_csv = "logs/trades.csv"
        self.capital_csv = "logs/capital_log.csv"
        os.makedirs("logs", exist_ok=True)

    def log_trade(self, symbol, action, price, quantity, pnl=0.0):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        file_exists = os.path.exists(self.trades_csv)
        with open(self.trades_csv, mode='a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(['timestamp', 'symbol', 'action', 'price', 'quantity', 'pnl'])
            writer.writerow([timestamp, symbol, action, price, quantity, pnl])

    def log_capital(self, total_capital):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        file_exists = os.path.exists(self.capital_csv)
        with open(self.capital_csv, mode='a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(['timestamp', 'total_capital'])
            writer.writerow([timestamp, total_capital])

    def has_traded_today(self, symbol):
        if not os.path.exists(self.trades_csv):
            return False
        today_str = datetime.now().strftime("%Y-%m-%d")
        with open(self.trades_csv, mode='r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                if row['symbol'] == symbol and row['timestamp'].startswith(today_str):
                    return True
        return False
```

### 3.3. 注文執行エンジン（`trading/order.py`）

<code>OrderExecutor</code>は、戦略判断とAPIクライアントの仲介を行い、注文の送信、約定確認、およびポジション管理・ロガーへの状態反映を非同期で処理します。

```python
import asyncio
import logging

class OrderExecutor:
    def __init__(self, api_client, position_manager, logger):
        self.api_client = api_client
        self.position_manager = position_manager
        self.logger = logger

    async def execute_order(self, symbol, action, quantity, price=0):
        try:
            logging.info(f"Executing order: {action} {symbol} Qty: {quantity}")
            response = await self.api_client.send_order(symbol, action, quantity, price)
            if response.get('status') == 'success':
                execution_price = response.get('price', price)
                await self._handle_execution_success(symbol, action, quantity, execution_price)
                return True
        except Exception as e:
            logging.error(f"Order execution failed for {symbol}: {e}")
        return False

    async def _handle_execution_success(self, symbol, action, quantity, price):
        if action == "BUY":
            if symbol not in self.position_manager.active_positions:
                self.position_manager.active_positions[symbol] = {
                    'entry_price': price,
                    'highest_price': price,
                    'stop_loss': price - (2 * 100),
                    'unit_count': 1,
                    'quantity': quantity
                }
            else:
                pos = self.position_manager.active_positions[symbol]
                pos['quantity'] += quantity
                pos['unit_count'] += 1
            self.logger.log_trade(symbol, "BUY", price, quantity)
        elif action == "SELL":
            if symbol in self.position_manager.active_positions:
                pnl = (price - self.position_manager.active_positions[symbol]['entry_price']) * quantity
                self.position_manager.total_capital += pnl
                del self.position_manager.active_positions[symbol]
                self.logger.log_trade(symbol, "SELL", price, quantity, pnl)
                self.logger.log_capital(self.position_manager.total_capital)
        
        self.position_manager.save_positions()
```

### 3.4. トレーリングストップ管理（`trading/trailing_stop.py`）

<code>TrailingStopManager</code>は、リアルタイムの価格更新イベントを受け取り、ストップロスの判定、ピラミッディング条件の評価、およびトレーリングストップの引き上げを順次実行するパイプラインを提供します。

```python
import asyncio
import logging

class TrailingStopManager:
    def __init__(self, position_manager, order_executor, atr_provider):
        self.position_manager = position_manager
        self.order_executor = order_executor
        self.atr_provider = atr_provider

    async def on_price_update(self, symbol, current_price):
        pos = self.position_manager.active_positions.get(symbol)
        if not pos:
            return

        atr = self.atr_provider.get_atr(symbol)
        
        if current_price > pos['highest_price']:
            pos['highest_price'] = current_price
            new_stop_loss = current_price - (2 * atr)
            if new_stop_loss > pos['stop_loss']:
                pos['stop_loss'] = new_stop_loss
                logging.info(f"Trailing stop updated for {symbol} to {new_stop_loss}")
                self.position_manager.save_positions()

        if current_price <= pos['stop_loss']:
            logging.warning(f"Stop loss triggered for {symbol} at {current_price}")
            await self.order_executor.execute_order(symbol, "SELL", pos['quantity'], current_price)
            return

        if pos['unit_count'] < 4:
            next_trigger = pos['entry_price'] + (pos['unit_count'] * 0.5 * atr)
            if current_price >= next_trigger:
                logging.info(f"Pyramidding triggered for {symbol} at {current_price}")
                add_quantity = self.position_manager.calculate_position_size(atr, current_price)
                if add_quantity > 0:
                    await self.order_executor.execute_order(symbol, "BUY", add_quantity, current_price)
```

## 4. 状態復旧とサーバー同期のライフサイクル

システム起動時およびシャットダウン時における、ローカルキャッシュと証券会社サーバー間の同期フローは以下の通りです。

```text
[System Startup]
       │
       ▼
[Load Local Cache] ──► Read positions.csv &amp; trades.csv
       │
       ▼
[Server Sync] ───────► Request Balance (kt00018) via REST API
       │
       ├─► Match active positions with server holdings
       │   ├─ If match: Keep local state &amp; update current prices
       │   └─ If mismatch: Log warning &amp; trigger reconciliation
       │
       ▼
[Initialize WebSocket] ──► Subscribe to Real-time Quotes (REAL, 0C)
       │
       ▼
[Event Loop Active] ──► Non-blocking Trailing Stop &amp; Pyramidding
```

### 資産評価額の不一致に関する技術的分析

初期同期の際、ログ上の総資金（<code>total_capital</code>）と保有ポジションの評価総額に乖離が生じる場合があります。

⚠️ <b>原因</b>: 証券サーバーから取得する残高照会（<code>kt00018</code>）には、過去の実現損益の履歴が含まれていません。そのため、ローカルの<code>total_capital</code>が初期設定値（例: 10,000,000 KRW）のまま復元された場合、含み益によって現在の保有評価額が初期資金を超える現象が発生します。

💡 <b>対策</b>: この乖離は起動時の初期化フェーズにおける一時的なものです。システムが稼働し、新規取引や決済が実行されると、<code>PositionManager</code>と<code>TradeLogger</code>が動的に実現損益を反映し、<code>total_capital</code>と実際の口座純資産が同期されます。

## 5. 本番稼働に向けた検証プロトコル

リファクタリングされたシステムの動作検証は、以下の手順に沿って実施します。

1. <b>リアルタイムフィードの疎通確認</b>: WebSocket接続後、<code>trnm: REAL</code>, <code>type: 0C</code>（リアルタイムクオート）がノンブロッキングで受信され、<code>TrailingStopManager.on_price_update</code>へ遅延なくディスパッチされていることをログで確認します。

2. <b>トレーリングストップの追従テスト</b>: 保有銘柄の価格上昇に伴い、<code>positions.csv</code>内の<code>highest_price</code>および<code>stop_loss</code>が動的に書き換えられていることを確認します。

3. <b>ピラミッディングのトリガー検証</b>: 価格がエントリー価格から $+0.5 \times \text{ATR}$ に達した際、追加注文が正常に発注され、<code>unit_count</code>がインクリメントされることを確認します。

4. <b>強制決済の動作確認</b>: ストップロス価格を下回るティックを受信した際、即座に成行決済注文が送信され、ローカルの<code>active_positions</code>から該当銘柄が削除されることを確認します。

## Lessons Learned

💡 <b>非同期イベントループにおけるI/Oの分離</b>: リアルタイムのWebSocket処理において、CSVへの同期書き込み（ブロッキングI/O）がボトルネックになる可能性があります。高頻度な取引環境では、<code>aiofiles</code>などの非同期ライブラリを使用するか、書き込み処理を別スレッド（<code>run_in_executor</code>）に逃がす設計を検討する必要があります。

⚠️ <b>状態の整合性確保</b>: ローカルのCSVキャッシュと証券サーバーの状態に不一致が生じた場合、誤発注の原因となります。起動時だけでなく、一定時間ごとにバックグラウンドでポジションの差分チェック（Reconciliation）を実行するタスクをイベントループに組み込むことが、運用の安定性向上につながります。
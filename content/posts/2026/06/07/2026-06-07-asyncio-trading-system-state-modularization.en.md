---
title: "Design Patterns for State Management and Modularization in Systematic Trading Using asyncio"
slug: "asyncio-trading-system-state-modularization"
date: 2026-06-07T18:18:50+09:00
draft: false
image: ""
description: "Explains state management persistence, risk-based position sizing, and refactoring techniques into event-driven pipelines in systematic trading using asyncio."
categories: ["Backend Architecture"]
tags: ["asyncio", "python", "state-management", "algorithmic-trading", "event-driven"]
author: "K-Life Hack"
---

This article explains the architectural redesign and modularization of an automated systematic trading system built on Python's <code>asyncio</code> framework. The system is designed to interface with the Kiwoom Open API (a hybrid REST and WebSocket client) to execute systematic trading strategies. Specifically, it implements a trend-following methodology that combines ATR (Average True Range) volatility-based position sizing, entries based on Mark Minervini's Trend Template, dynamic pyramiding, and trailing stops.



## 1. Architectural Overview and Refactoring Objectives

In the conventional monolithic engine, order execution, state tracking, risk management, and logging were tightly coupled, posing challenges for maintainability and scalability. In this redesign, modularization was implemented to achieve the following four objectives:


💡 <b>Decoupling of Concerns</b>: Transition each component to a loosely coupled, event-driven architecture.


🛠️ <b>Robust State Persistence</b>: Introduce a two-tier state recovery mechanism combining local CSV files (<code>positions.csv</code>, <code>trades.csv</code>, <code>capital_log.csv</code>) with real-time, server-side balance synchronization.


🔄 <b>Asynchronous Event Loop Integration</b>: Execute order placement, real-time WebSocket quote processing, and dynamic trailing stop calculations in a non-blocking manner.


⚠️ <b>Systematic Risk Management</b>: Apply a strict risk budget rule with a maximum risk tolerance of 1% of total capital, dynamically determining position sizes based on ATR.



## 2. Directory Structure and Module Configuration

The project has been restructured from a single-file configuration into a package structure where each component has an independent role. This ensures that changes to API specifications or logging formats do not affect other modules.



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

## 3. Design and Implementation Code of Each Module

### 3.1. Position Management (`position/position_manager.py`)

The <code>PositionManager</code> is responsible for managing the system's active positions and total capital, and dynamically calculating risk parameters.



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

### 3.2. Trade Logger (`logs/logger.py`)

The <code>TradeLogger</code> appends trade history to <code>trades.csv</code> and records equity curve data in <code>capital_log.csv</code>. It also provides history analysis methods to prevent duplicate entries on the same day.



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

### 3.3. Order Execution Engine (`trading/order.py`)

The <code>OrderExecutor</code> acts as an intermediary between strategy decisions and the API client, asynchronously handling order submission, execution confirmation, and reflecting state changes in the position manager and logger.



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

### 3.4. Trailing Stop Management (`trading/trailing_stop.py`)

The <code>TrailingStopManager</code> receives real-time price update events and provides a pipeline to sequentially execute stop-loss determination, evaluate pyramiding conditions, and raise trailing stops.



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

## 4. State Recovery and Server Synchronization Lifecycle

The synchronization flow between the local cache and the brokerage server during system startup and shutdown is as follows:



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

### Technical Analysis of Asset Valuation Discrepancies

During initial synchronization, discrepancies may arise between the logged total capital (<code>total_capital</code>) and the total valuation of held positions.


⚠️ <b>Cause</b>: The balance inquiry (<code>kt00018</code>) retrieved from the brokerage server does not include historical realized profit and loss. Therefore, if the local <code>total_capital</code> is restored at its initial setting value (e.g., 10,000,000 KRW), unrealized gains may cause the current valuation of held assets to exceed the initial capital.


💡 <b>Mitigation</b>: This discrepancy is temporary during the startup initialization phase. Once the system is running and new trades or liquidations are executed, the <code>PositionManager</code> and <code>TradeLogger</code> dynamically reflect realized profits and losses, synchronizing <code>total_capital</code> with the actual account net asset value.



## 5. Verification Protocol for Production Deployment

Verification of the refactored system's operation is conducted according to the following steps:



1. <b>Real-Time Feed Connectivity Verification</b>: Confirm via logs that after establishing the WebSocket connection, <code>trnm: REAL</code>, <code>type: 0C</code> (real-time quotes) are received in a non-blocking manner and dispatched to <code>TrailingStopManager.on_price_update</code> without delay.


2. <b>Trailing Stop Tracking Test</b>: Verify that as the price of held symbols rises, <code>highest_price</code> and <code>stop_loss</code> in <code>positions.csv</code> are dynamically updated.


3. <b>Pyramiding Trigger Verification</b>: Verify that when the price reaches $+0.5 \times \text{ATR}$ from the entry price, additional orders are successfully placed and <code>unit_count</code> is incremented.


4. <b>Forced Liquidation Operation Verification</b>: Verify that when a tick falling below the stop-loss price is received, a market liquidation order is sent immediately, and the corresponding symbol is removed from the local <code>active_positions</code>.



## Lessons Learned

💡 <b>I/O Separation in Asynchronous Event Loops</b>: In real-time WebSocket processing, synchronous writing to CSV (blocking I/O) can become a bottleneck. In high-frequency trading environments, it is necessary to consider designs that use asynchronous libraries such as <code>aiofiles</code> or offload write operations to a separate thread (<code>run_in_executor</code>).


⚠️ <b>Ensuring State Consistency</b>: Discrepancies between the local CSV cache and the brokerage server's state can cause erroneous orders. Incorporating a background task into the event loop to perform position reconciliation at regular intervals, rather than just at startup, improves operational stability.


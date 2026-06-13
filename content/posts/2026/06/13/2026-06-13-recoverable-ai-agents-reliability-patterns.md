---
title: "LLMエージェントの高信頼化における分散システムパターンの適用設計"
slug: "recoverable-ai-agents-reliability-patterns"
date: 2026-06-13T10:09:31+09:00
draft: false
image: ""
description: "LLMエージェントの非決定的な失敗に対処するため、サーキットブレーカーやSagaパターンなどの分散システム設計を適用し、本番環境に耐えうる高信頼なオーケストレーションを構築する手法を解説します。"
categories: ["Backend Architecture"]
tags: ["llm-agent", "saga-pattern", "circuit-breaker", "pydantic-validation", "distributed-systems"]
author: "K-Life Hack"
---

本番環境におけるLLM（大規模言語モデル）エージェントの運用では、外部APIやデータベースとの連携において非決定的なエラーに直面することは避けられません。例えば、決済APIの呼び出しに成功したものの、その後の在庫確保APIで503エラーが発生した場合、システムは不整合な状態（部分的成功）に陥ります。単純なループ処理のみで構築されたエージェントは、こうした分散システム特有の障害に対応できず、異常終了するか、あるいは不整合な状態を放置することになります。

本稿では、分散システムで培われた信頼性パターン（サーキットブレーカー、Sagaパターン、指数バックオフ、構造化バリデーション）をLLMオーケストレーションに適用し、堅牢なエージェントシステムを構築する設計手法について解説します。

## 1. エージェント実行における3つの障害モード

エージェントが外部環境と相互作用する際、主に以下の3つの障害モードが発生します。

* <b>障害モード1: ツール実行時の例外 (Tool Exceptions)</b>
レートリミット（HTTP 429）や一時的なネットワーク切断、タイムアウトなど。適切なリトライロジックがない場合、エージェントループ全体がクラッシュし、実行コンテキストが消失します。
* <b>障害モード2: 不正なツール出力 (Garbage Tool Outputs)</b>
ツールがエラーハンドリングを怠り、正常系を装った不正なペイロードを返却した場合、LLMはその誤った情報を前提に後続の処理を決定してしまいます。
* <b>障害モード3: 部分的成功による状態不整合 (Partial Success)</b>
複数ステップからなるワークフローにおいて、一部の処理のみが成功し、後続処理が失敗した場合。ロールバック機構がないため、システムの状態が未定義のまま放置されます。

これらの課題は、LLMの推論能力向上だけでは解決できません。確率的なLLMの振る舞いを、決定論的な状態遷移マシン（オーケストレーター）でラップする設計が必要となります。

## 2. 5層の信頼性レイヤーによる防御アプローチ

ツール呼び出しの信頼性を担保するため、以下の5つのレイヤーをネストして適用するアーキテクチャを構築します。

```
[エージェントループ]
     |
     v
+-----------------------------------------------------------------+
| 1. traced_call (実行ログ記録、所要時間計測、認証情報のマスク)   |
|    +------------------------------------------------------------+
|    | 2. Circuit Breaker (下流サービスの障害時に即座に遮断)      |
|    |    +-------------------------------------------------------+
|    |    | 3. with_retry (指数バックオフとジッターによる再試行)  |
|    |    |    +--------------------------------------------------+
|    |    |    | 4. validated_call (スキーマおよび型の厳密な検証) |
|    |    |    |    +---------------------------------------------+
|    |    |    |    | 5. call_tool (実際のツールロジックの実行)   |
+----+----+----+----+---------------------------------------------+
```

### レイヤー1: 指数バックオフとジッター (`with_retry`)

一時的なネットワークエラーから回復するため、再試行間隔を指数関数的に増加させます。また、複数のエージェントが同時に再試行して下流サービスを圧倒する「群衆雪崩（Thundering Herd）現象」を防ぐため、ランダムな揺らぎ（ジッター）を加えます。

### レイヤー2: サーキットブレーカー

完全にダウンしているサービスに対してリトライを繰り返すことは、リソースの無駄遣いであり、相手方の復旧を妨げる要因になります。連続して $N$ 回失敗した場合は回路を「OPEN」にし、以降の呼び出しを即座に遮断（フェイルファスト）します。一定時間経過後に「HALF-OPEN」状態へ遷移し、テストリクエストが成功すれば回路を「CLOSED」に戻します。

### レイヤー3: Sagaパターンと冪等性キー

ロールバックが不可能な分散トランザクションにおいて、各ステップに対応する「補償アクション（Compensating Action）」を定義します。ステップ $N$ で失敗した場合、それまでに実行した $1$ から $N-1$ のステップの補償アクションを逆順で実行し、システムを整合性のある状態に戻します。また、再試行時の二重決済を防ぐため、すべての書き込み処理に一意な「冪等性キー（Idempotency Key）」を付与します。

### レイヤー4: 構造化バリデーション (`validated_call`)

LLMが生成するツール引数は、型エラーや必須パラメータの欠落が頻発します。実行前にPydantic等を用いてスキーマ検証を行い、エラーが発生した場合はその詳細をLLMにフィードバックして自律的に修正（Self-Correction）させます。

### レイヤー5: オブザーバビリティとトレース (`traced_call`)

エージェントの動作をブラックボックス化させないため、すべてのツール呼び出しの引数、実行時間、成否を構造化ログとして記録します。その際、APIキーやパスワードなどの機密情報は自動的にマスクします。

## 3. 信頼性レイヤーの実装明細

これらのパターンを統合したPythonによる実装コードは、堅牢なエラーハンドリングと状態管理を統合的に提供します。

```python
import time
import random
import logging
import json
import uuid
from typing import Callable, Optional, Any
from pydantic import BaseModel, create_model, ValidationError

_log = logging.getLogger(__name__)

# --- レイヤー1: 指数バックオフとジッター ---
def with_retry(
    fn: Callable[..., str],
    args: dict,
    max_attempts: int = 3,
    base_delay: float = 1.0,
) -&gt; str:
    for attempt in range(max_attempts):
        try:
            return fn(**args)
        except Exception as e:
            if attempt == max_attempts - 1:
                raise
            delay = base_delay * (2 ** attempt) + random.uniform(0, 0.5)
            _log.warning("Attempt %d failed (%s) - retrying in %.1fs", attempt + 1, e, delay)
            time.sleep(delay)

# --- レイヤー2: サーキットブレーカー ---
class CircuitBreaker:
    CLOSED, OPEN, HALF_OPEN = "closed", "open", "half-open"

    def __init__(self, failure_threshold: int = 3, reset_timeout: float = 30.0) -&gt; None:
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self._failures = 0
        self._state = self.CLOSED
        self._opened_at: Optional[float] = None

    def call(self, fn: Callable[..., str], args: dict) -&gt; str:
        if self._state == self.OPEN:
            elapsed = time.time() - (self._opened_at or 0.0)
            if elapsed &lt; self.reset_timeout:
                raise RuntimeError(
                    f"Circuit open - service unavailable (resets in {self.reset_timeout - elapsed:.0f}s)"
                )
            self._state = self.HALF_OPEN

        try:
            result = fn(**args)
            if self._state == self.HALF_OPEN:
                self._reset()
            return result
        except Exception:
            self._failures += 1
            if self._failures &gt;= self.failure_threshold:
                self._state = self.OPEN
                self._opened_at = time.time()
            raise

    def _reset(self) -&gt; None:
        self._failures = 0
        self._state = self.CLOSED
        self._opened_at = None

# --- レイヤー4: 構造化バリデーション ---
_VALIDATORS: dict[str, type[BaseModel]] = {}
_TYPE_MAP = {
    "string": str,
    "integer": int,
    "number": float,
    "boolean": bool,
}

def call_tool(name: str, args: dict) -&gt; str:
    # 実際のツール実行プレースホルダー
    return f"Success: {name} executed with {args}"

def validated_call(name: str, args: dict) -&gt; str:
    validator = _VALIDATORS.get(name)
    if validator is None:
        return call_tool(name, args)
    try:
        validated = validator(**args)
        return call_tool(name, validated.model_dump(exclude_none=True))
    except ValidationError as e:
        return f"Invalid arguments for '{name}': {e}"

# --- レイヤー5: トレースとマスキング ---
def traced_call(name: str, args: dict, fn: Callable[..., str]) -&gt; str:
    sanitized = {
        k: "***" if any(w in k.lower() for w in ("key", "secret", "token", "password")) else v
        for k, v in args.items()
    }
    start = time.time()
    try:
        result = fn(**args)
        _log.info(
            "tool=%s args=%s result=%r duration=%.3fs",
            name, json.dumps(sanitized), str(result)[:120], time.time() - start,
        )
        return result
    except Exception as e:
        _log.error(
            "tool=%s args=%s error=%s duration=%.3fs",
            name, json.dumps(sanitized), e, time.time() - start,
        )
        raise

# --- ディスパッチャーの合成 ---
def _make_dispatcher(
    breakers: dict[str, CircuitBreaker],
    max_retries: int,
) -&gt; Callable[[str, dict], str]:
    def dispatch(name: str, args: dict) -&gt; str:
        def core(**kw) -&gt; str:
            return validated_call(name, kw)

        def retried(**kw) -&gt; str:
            return with_retry(core, kw, max_attempts=max_retries)

        def guarded(**kw) -&gt; str:
            return breakers[name].call(retried, kw)

        return traced_call(name, args, guarded)

    return dispatch
```

## 4. セマンティック・ハルシネーションの緩和策

構造化バリデーションは「構文的」なエラーを防ぎますが、LLMが「論理的に誤った値」を生成する<b>セマンティック・ハルシネーション（意味的幻覚）</b>を防ぐことはできません。これらは分散システムにおけるビザンチン障害（ノードが正常に動作しているように見えて誤ったデータを送信する状態）に相当します。

この問題に対処するため、以下の4つのアプローチをユースケースに応じて適用します。

| 手法 | 概要 | 学術的背景 | トレードオフ |
| :--- | :--- | :--- | :--- |
| <b>Chain-of-Verification (CoVe)</b> | 生成した回答に対し、モデル自身が検証用の質問を作成・回答し、自己修正を行う。 | Dhuliawala et al. (2024) | <b>低コスト</b>: 追加のLLM呼び出しが最小限で済み、実用的。 |
| <b>Self-Consistency</b> | 複数の推論パスをサンプリングし、多数決で最終出力を決定する。 | Wang et al. (2023) | <b>高コスト</b>: 応答遅延が大きく、リアルタイム処理には不向き。 |
| <b>LLM-as-a-Judge</b> | メインモデルの出力を、別の独立した検証用LLMが評価・検証する。 | Zheng et al. (2023) | <b>中コスト</b>: 重要な書き込み処理の直前フェーズに推奨。 |
| <b>Output Grounding (RAG)</b> | 外部知識ソースへの厳密な参照（Citation）を義務付け、根拠を検証する。 | Es et al. (2024) | <b>低〜中コスト</b>: 検索ツール設計と評価パイプラインの構築が必要。 |

## 5. Troubleshooting

⚠️ 本アーキテクチャを本番環境に導入する際、直面しやすい摩擦点（Friction Points）とその解決策を整理します。

### 摩擦点1: 分散環境におけるサーキットブレーカーの状態ドリフト

エージェントが複数のコンテナインスタンスで並行動作する場合、メモリ内（In-Memory）でサーキットブレーカーの状態を保持すると、インスタンス間で状態の不整合が発生します。あるノードでは回路が「OPEN」であるにもかかわらず、別のノードでは「CLOSED」のまま下流サービスにリクエストを送り続け、障害を悪化させることがあります。

* <b>解決策</b>: サーキットブレーカーの状態（失敗回数、最終エラー時刻、現在のステート）をRedisなどの共有データストアに外部化し、分散ロックまたはアトミックな増減操作を用いて同期します。

### 摩擦点2: LLMの自己修正ループにおける無限置換

構造化バリデーションエラーをLLMに返却して再試行させる際、プロンプトの制約が曖昧だと、LLMが同じ誤ったパラメータを繰り返し生成し、無限ループに陥るケースがあります。

* <b>解決策</b>: ディスパッチャー側で同一ツールに対する自己修正の最大試行回数（Max Self-Correction Limits、推奨値: 3回）を厳密にカウントし、上限に達した場合は即座に例外をスローして上位のSaga補償フローへ移行させます。

## 6. Verification

🛠️ 高信頼化ディスパッチャーを適用したエージェントの実行ログプロトコルは、スキーマエラーの自己修正、および一時的エラーに対するリトライとサーキットブレーカーの作動プロセスを明示します。

```text
# 1. 構造化バリデーションによる自己修正のトリガー
2026-06-13 10:42:01,102 [INFO] tool=charge_card args={"amount": "forty-nine", "card_token": "tok_123"} result='Invalid arguments for "charge_card": amount must be a float' duration=0.012s
2026-06-13 10:42:02,450 [INFO] LLM detected validation error. Retrying with corrected arguments...
2026-06-13 10:42:03,115 [INFO] tool=charge_card args={"amount": 49.00, "card_token": "tok_123"} result='Success: charge_card executed' duration=0.189s

# 2. 下流サービス障害に伴う指数バックオフの作動
2026-06-13 10:42:05,201 [WARNING] Attempt 1 failed (503 Service Unavailable) - retrying in 1.2s
2026-06-13 10:42:07,412 [WARNING] Attempt 2 failed (503 Service Unavailable) - retrying in 2.5s
2026-06-13 10:42:10,920 [ERROR] tool=send_notification args={"email": "user@example.com"} error=503 Service Unavailable duration=1.002s

# 3. 連続失敗によるサーキットブレーカーの作動（OPEN状態への遷移）
2026-06-13 10:42:11,005 [ERROR] tool=send_notification args={"email": "user@example.com"} error=Circuit open - service unavailable (resets in 30s) duration=0.001s
```

## Operational Notes

💡 LLMエージェントの信頼性設計は、プロンプトエンジニアリングの領域を超え、古典的な分散システム設計 of 領域へと回帰しています。エージェントを自律的なアクターとして本番環境にデプロイするためには、確率的な推論エンジンを決定論的なセーフティネットで包み込むことが不可欠です。本稿で示した5層の防御レイヤーを適用することで、APIのダウンタイムやLLMの構造的エラーに耐えうる、真に自律的なエージェントシステムの構築が可能となります。
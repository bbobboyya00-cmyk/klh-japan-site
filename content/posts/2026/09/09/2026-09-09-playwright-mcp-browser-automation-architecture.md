---
title: "Playwright MCPによるアクセシビリティツリー基盤のAIブラウザ操作アーキテクチャ"
slug: "playwright-mcp-browser-automation-architecture"
date: 2026-09-09T10:03:03+09:00
draft: false
image: ""
description: "Playwright MCPのアーキテクチャと設定手順を解説。アクセシビリティツリーを用いたセマンティックなDOM解析により、壊れやすいセレクタやVLM座標推定に依存しない高精度なAIブラウザ自動化を実現します。"
categories: ["Backend Architecture"]
tags: ["@playwright/mcp", "playwright", "model-context-protocol", "accessibility-tree", "browser-automation"]
author: "K-Life Hack"
---

Webブラウザの自動テストやE2E検証において、CSSセレクタやXPathのハードコードに依存した実装は、UIの微細な変更や動的なクラス名難読化（CSS-in-JS、Tailwind、本番ビルドのミニファイ）によって容易に破損します。また、近年のLLMやマルチモーダルモデルを用いたスクリーンショット座標推定アプローチは、画面解像度の違いやレスポンシブなレンダリングの揺らぎに弱く、非決定論的な操作エラーを引き起こしがちです。

こうした運用の摩擦を解消するため、Microsoftエコシステムにおいて策定が進むModel Context Protocol (MCP) をベースとした「Playwright MCP」が導入されています。本稿では、Playwright MCPが採用するアクセシビリティツリー（A11y Tree）スナップショット機構のアーキテクチャと、各種MCPクライアント環境への導入手順、および運用時の障害対策について整理します。

## 構造的アプローチ：Accessibility Tree Snapshotの仕組み

Playwright MCPは、ピクセル単位の画像認識や装飾的な<code>&lt;div&gt;</code>タグのネスト構造ではなく、OSやスクリーンリーダーが解釈するアクセシビリティツリー（Accessibility Tree）をコンテキストとしてLLMへ渡します。

```
[ Web Page / Raw DOM Tree ]
             │
             ▼
[ Accessibility Tree Engine (Playwright) ]
   ├── セマンティックロール抽出 (button, textbox, link)
   ├── 状態・属性解析 (aria-*, expanded, checked)
   └── 決定論的Element Referenceの発行
             │
             ▼
[ LLM Context Window (構造化テキスト表現) ]
```

このアーキテクチャにより、以下の優位性が得られます。

1. <b>セレクタ破損の排除</b>: 要素の役割（Role）やAccessible Nameを基準に操作対象を同定するため、CSSクラス名の変更やDOM階層の変更によるスクリプト破壊を防ぎます。
2. <b>トークン効率の最適化</b>: 画面全体のピクセルデータや長大なHTML文字列をLLMへ送信せず、意味情報のみに削ぎ落とされたツリーを送信するため、コンテキストウィンドウの消費を抑制します。
3. <b>決定論的操作</b>: 各要素に一意な参照インデックス（Element Reference）が付与され、クリックや入力の対象が明確に決定されます。

## MCPサーバの構成とクライアント設定

### 動作要件
* Node.js: 20.x系以上を推奨

### クライアント設定（mcpServers）

Claude Desktop、Cursor、Cline、VS CodeなどのMCPクライアント設定ファイル（<code>claude_desktop_config.json</code>やCursorの設定領域）に以下のJSONブロックを追加します。

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": [
        "@playwright/mcp@latest"
      ]
    }
  }
}
```

## 実行ループと内部ステートマシン

Playwright MCPは、単一の静的コマンド実行ではなく、AIエージェントとブラウザ間の閉ループ（Closed-loop）ステートマシンとして動作します。

```
┌────────────────────────────────────────────────────────┐
│                        AI Agent                        │
└───────────────────────────┬────────────────────────────┘
                            │ (1) セッション開始 / ナビゲーション指示
                            ▼
┌────────────────────────────────────────────────────────┐
│               Browser Process (Playwright)              │
└───────────────────────────┬────────────────────────────┘
                            │ (2) ページロード完了・A11yスナップショット生成
                            ▼
┌────────────────────────────────────────────────────────┐
│             Accessibility Snapshot Generator            │
└───────────────────────────┬────────────────────────────┘
                            │ (3) セマンティックツリー返却
                            ▼
┌────────────────────────────────────────────────────────┐
│                        AI Agent                        │
│         (要素参照の特定と実行アクションの推論)         │
└───────────────────────────┬────────────────────────────┘
                            │ (4) 操作コマンド送信 (Click, Fill 等)
                            ▼
┌────────────────────────────────────────────────────────┐
│           Playwright MCP Execution Pipeline            │
└───────────────────────────┬────────────────────────────┘
                            │ (5) DOM状態更新の再キャプチャ
                            ▼
                         [ 次のステップへ継続 ]
```

## 提供される主要インターフェース

Playwright MCPがクライアントへ公開する代表的なツールインターフェースは以下の通りです。

* `browser_navigate`: URLへの遷移、履歴のバック/フォワード、リロードを制御。
* `A11y Tree Target Resolution`: ロールベースで識別された要素へのClickイベントディスパッチ。
* `Semantic Form Handlers`: フォームフィールドに対する文字列入力、チェックボックス切り替え、ドロップダウン選択。
* `Screenshot Engine`: フルページまたは要素単位での画面キャプチャ抽出。
* `Storage State Persistence`: セッション情報（Cookie、`localStorage`）をシリアライズし、認証バイパスやテストシナリオの再利用を実現。
* `browser_run_code_unsafe`: LLMから直接任意のPlaywrightスクリプトを実行（※サンドボックス外実行となるため、隔離された信頼できる環境でのみ利用）。

## Troubleshooting

### 1. ブラウザバイナリの未インストールエラー
<code>npx @playwright/mcp@latest</code> 実行時、ホスト環境にChromium等のブラウザバイナリが存在しない場合、プロセス起動直後にエラーが発生します。

```text
Error: browserType.launch: Executable doesn't exist at /root/.cache/ms-playwright/chromium-1155/chrome-linux/chrome
╔═════════════════════════════════════════════════════════════════════════╗
║ Looks like Playwright was just installed or updated.                   ║
║ Please run the following command to download new browsers:             ║
║                                                                         ║
║     npx playwright install                                             ║
╚═════════════════════════════════════════════════════════════════════════╝
```

<b>対応手順:</b> ホスト環境またはコンテナ内で事前にブラウザ依存関係をインストールします。

```bash
npx playwright install --with-deps chromium
```

### 2. ヘッドレス環境におけるシステム依存ライブラリの不足

Linuxサーバ環境で実行する際、GUIレンダリングに必要な共有ライブラリが不足していると、<code>host system dependencies</code>エラーが発生します。この場合はディストリビューションに応じたパッケージの追加が必要です。

```bash
sudo npx playwright install-deps
```

### 3. デプロイ検証ログの確認

MCPプロセスが正しく常駐し、JSON-RPCプロトコルを受け付ける状態にあるかは、標準出力およびプロセス一覧で確認します。

```text
$ ps aux | grep playwright
node /usr/local/bin/npx @playwright/mcp@latest
/root/.cache/ms-playwright/chromium-1155/chrome-linux/chrome --disable-field-trial-config --disable-background-networking --enable-features=NetworkService,NetworkServiceInProcess --disable-background-timer-throttling --headless=new --remote-debugging-pipe
```

## Configuration Notes

Playwright MCPは、従来の「コードによる手続き型テスト」と「視覚モデルによる曖昧なUI操作」の双方における課題を解決するアプローチです。アクセシビリティツリーを標準インターフェースとして用いることで、堅牢なセマンティック解析に基づいたブラウザ自動化パイプラインが構築できます。実運用への組み込みにあたっては、認証状態のシリアライズ管理や実行権限の制御を適切に設計することが不可欠です。
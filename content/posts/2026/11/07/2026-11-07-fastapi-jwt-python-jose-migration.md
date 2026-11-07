---
title: "python-joseの脆弱性CVE-2026-120459・CVE-2026-85394とFastAPI認証層のPyJWT移行指針"
slug: "fastapi-jwt-python-jose-migration"
date: 2026-11-07T11:00:52+09:00
draft: false
image: ""
description: "python-joseに判明したCVE-2026-120459およびCVE-2026-85394の構造的リスクを解剖。メンテナンス停止に伴うPyJWTへの段階的移行手順と例外設計を整理します。"
categories: ["Backend Architecture"]
tags: ["python-jose", "PyJWT", "CVE-2026-120459", "CVE-2026-85394", "FastAPI", "JWT", "pipdeptree"]
author: "K-Life Hack"
---

マイクロサービスやAPIゲートウェイにおける認証認可基盤では、トークン検証処理の堅牢性がシステム全体のセキュリティ境界を規定します。特にステートレスなJWT（JSON Web Token）検証では、ライブラリ内部の実装挙動や鍵の解釈ロジックに僅かでも不備が存在すると、認可バイパスや特権昇格に直結する脆弱性を抱えることになります。これまでFastAPIなどの主要フレームワークのチュートリアルで長年採用されてきた`python-jose`において、空文字HMAC秘密鍵の許容や公開鍵アルゴリズム混同攻撃を許容する脆弱性が報告されました。上流リポジトリの保守が事実上停止している状況下において、本番環境の認証基盤を安全に維持するための移行手順と技術的背景を詳解します。

## 脆弱性の技術的背景とメカニズム

`python-jose`バージョン3.5.0以前のすべてのバージョンにおいて、以下の2件の重大な脆弱性が存在することが確認されています。

1. <b>CVE-2026-120459</b>: 長さゼロ（空文字列）のHMAC秘密鍵の許容
2. <b>CVE-2026-85394</b>: DERエンコードされたバイナリ公開鍵入力によるアルゴリズム混同攻撃

### CVE-2026-120459: 空文字HMAC鍵による検証バイパス

対称鍵暗号アルゴリズム（HS256、HS384、HS512）では、サーバー側のみが知る秘密鍵の存在を前提として署名検証を行います。しかし`python-jose`のHMAC実装クラス（`jose.backends.native.HMACKey`および`jose.backends.cryptography_backend.CryptographyHMACKey`）では、入力キーの型チェックや文字列エンコードの処理を行っているものの、バイト長が0より大きいかを検証するバリデーションが完全に欠落していました。

この欠陥により、環境変数の未定義フォールバック等で秘密鍵が`""`（空文字列）として評価された場合、攻撃者は空文字列で署名した任意のクレームペイロードを作成し、正規の署名としてサーバーに受容させることが可能になります。`algorithms=["HS256"]`のようにアルゴリズムを明示的に制限していても、鍵の長さやエントロピーそのものは検証されないため、この脆弱性を防ぐことはできません。

### CVE-2026-85394: DER公開鍵によるアルゴリズム混同

RS256などの非対称暗号では、秘密鍵で署名し公開鍵で検証します。公開鍵はクライアントや外部に公開される情報です。攻撃者が既知の公開鍵を取得し、JWTヘッダーの`alg`を`HS256`に書き換えた上で、公開鍵のバイナリデータをHMACの秘密鍵として署名を生成する手法が「アルゴリズム混同攻撃」です。

⚠️ `python-jose`は過去にCVE-2024-33663への対策として、テキスト形式のPEMヘッダー（`-----BEGIN ...`）をHMAC鍵として拒否するガードを導入しました。しかし、公開鍵がバイナリ形式のDERエンコーディング（`bytes`）で渡された場合、この正規表現ベースのチェックを完全に迂回してしまいます。さらに、`python-jose`の`jwt.decode()`は`algorithms`引数が未指定の場合にデフォルトで`None`となり、アルゴリズムの検証自体をスキップします。これにより、公開鍵を用いたHMAC署名が正当なものとして検証されてしまいます。

## 依存関係スキャンにおける検知の死角

一般的なCI/CDパイプラインに導入されている自動脆弱性スキャナー（`pip-audit`やDependabotなど）において、これら2つのCVEに対するメタデータの非同期が発生しています。

```text
[CVE-2026-85394]
  - GHSA-3qf3-8w2g-rqmx (Reviewed)
  - PYSEC-2026-4298 としてPyPIにマッピング
  - 一般的なスキャナーで検出可能

[CVE-2026-120459]
  - GHSA-7jv8-hwmh-86qc (Unreviewed)
  - PyPIの脆弱性フィードに未反映
  - Google OSVではGitコミット範囲にのみ限定され、パッケージバージョンに紐付かない
  - pip-audit等でスルーされるリスクが存在
```

自動監査ツールがCVE-2026-85394のみを検知し、「DER形式の公開鍵は扱っていないため安全」と判断して対応を見送った場合、PyPIメタデータに登録されていないCVE-2026-120459（空文字秘密鍵リスク）を見落とす危険性があります。

## リポジトリ内の依存調査と暫定防御策

本番コードベースおよび推移的依存関係（Transitive Dependencies）において、`python-jose`が利用されているかを即時に確認します。

```bash
# ソースコード内の直接インポートの探索
grep -rnE "(from|import) jose" --include="*.py" .

# 依存マニフェストの確認
grep -n "python-jose" requirements*.txt pyproject.toml poetry.lock uv.lock

# 逆引き依存ツリーの確認 (uv または pipdeptree)
uv tree --invert --package python-jose
pipdeptree --reverse --packages python-jose
```

🛠️ 直ちにコードベースを書き換えられない環境では、アプリケーション起動時におけるフェイルファスト検証を導入し、脆弱性の発火前提条件を無力化します。

```python
import os
from pydantic import field_validator
from pydantic_settings import BaseSettings

# 1. 起動時環境変数チェック
RAW_SECRET = os.environ.get("SECRET_KEY")
if not RAW_SECRET or not RAW_SECRET.strip():
    raise RuntimeError("CRITICAL: SECRET_KEY環境変数が未設定または空文字です。プロセスを停止します。")

# 2. Pydantic Settingsによるエントロピー担保
class SecuritySettings(BaseSettings):
    secret_key: str

    @field_validator("secret_key")
    @classmethod
    def validate_key_length(cls, v: str) -&gt; str:
        if not v or not v.strip() or len(v) &lt; 32:
            raise ValueError("SECRET_KEYは32文字以上の十分なエントロピーを持つ必要があります。")
        return v
```

## PyJWTへの移行実装

FastAPIの公式ドキュメント（PR #11589以降）でも標準採用されている`PyJWT`（バージョン2.15.0以上）への移行を実施します。`PyJWT`の初期バージョン（2.13.0や2.14.0）には個別のDoSや鍵混同の脆弱性が存在したため、必ず`&gt;=2.15.0`を指定します。

```bash
# パッケージの入れ替え
pip uninstall -y python-jose
pip install "pyjwt&gt;=2.15.0"

# uvを使用している場合
uv remove python-jose
uv add "pyjwt&gt;=2.15.0"
```

### APIシグネチャの差異とリファクタリング

`python-jose`と`PyJWT`では、引数の指定方法および例外クラス階層が異なります。

```python
# 移行前: python-jose (3.5.0)
from jose import JWTError, jwt
from fastapi import HTTPException, status

credentials_exception = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="認証情報を検証できませんでした",
    headers={"WWW-Authenticate": "Bearer"},
)

try:
    payload = jwt.decode(
        token,
        SECRET_KEY,
        algorithms=["HS256"],
        options={"leeway": 10}
    )
except JWTError:
    raise credentials_exception
```

これを以下の完全な`PyJWT`実装へ書き換えます。`leeway`が第一級のキーワード引数となり、例外ハンドリングのスコープが変更されます。

```python
# 移行後: PyJWT &gt;= 2.15.0
import jwt
from jwt.exceptions import InvalidTokenError, PyJWTError
from fastapi import HTTPException, status

credentials_exception = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="認証情報を検証できませんでした",
    headers={"WWW-Authenticate": "Bearer"},
)

try:
    # algorithmsパラメータは必須指定
    payload = jwt.decode(
        token,
        SECRET_KEY,
        algorithms=["HS256"],
        leeway=10
    )
except InvalidTokenError:
    # ExpiredSignatureError, DecodeError などを一括捕捉
    raise credentials_exception
except PyJWTError as err:
    # InvalidKeyError（秘密鍵不正）などシステム起因のエラーログ記録
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="トークン検証構成に致命的な不整合が存在します"
    ) from err
```

## Troubleshooting

### 移行後に予期せぬ401 Unauthorizedが多発する

💡 `python-jose`では`algorithms`引数が省略可能（デフォルト`None`）であったため、アルゴリズム指定を忘れたコードが稼働していた可能性があります。`PyJWT`では`algorithms`引数の指定が実質的に必須化されており、未指定の場合は`DecodeError`が発生します。`DecodeError`は`InvalidTokenError`を継承しているため、上記の一般的な401ハンドラーで捕捉され、ログを残さず認証失敗として返却される事象が発生します。呼び出し側の`jwt.decode()`すべてに`algorithms=["HS256"]`等の明示的な指定が存在するか確認してください。

### 秘密鍵が空の場合の500 Internal Server Errorハンドリング

⚠️ `PyJWT`は空文字列のHMACキーが渡されると`InvalidKeyError`を送出します。この例外は`InvalidTokenError`のサブクラスではなく`PyJWTError`を直接継承しています。そのため、`except InvalidTokenError:`ブロックだけを定義していると例外が捕捉されず、FastAPI内部で未ハンドリングの500エラーとして表面化します。起動時の環境変数検証を徹底することで、実行時における本例外の発生を抑止する必要があります。

### 依存パッケージ導入後のターミナル検証ログ

パッケージ更新および不要な推移的依存の削除が正常に行われたことを確認します。

```text
$ pip show python-jose
WARNING: Package(s) not found: python-jose

$ pip show pyjwt
Name: PyJWT
Version: 2.15.1
Summary: JSON Web Token implementation in Python
Home-page: https://github.com/jpadilla/pyjwt
Author: Jose Padilla
License: MIT
Location: /opt/venv/lib/python3.11/site-packages
Requires: cryptography
Required-by: 

$ python -c "import jwt; print(jwt.__version__)"
2.15.1
```

## Operational Notes

`python-jose`のリポジトリオーナーは保守を継続する意志がないことを公言しており、未マージのプルリクエスト（PR #422など）も放置されています。適切な鍵運用（32バイト以上のランダムな秘密鍵を用い、アルゴリズムを明示）が行われているシステムであれば直ちに外部攻撃を許すわけではありませんが、上流のパッチ供給が完全に停止したセキュリティクリティカルなライブラリを稼働させ続けることは運用上の負債となります。FastAPIエコシステムにおいて標準となっている`PyJWT &gt;= 2.15.0`への移行、または要件に応じた`joserfc`や`Authlib`への切り替えを速やかに完了させてください。
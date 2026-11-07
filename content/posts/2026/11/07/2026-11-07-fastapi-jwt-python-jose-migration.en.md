---
title: "Vulnerabilities CVE-2026-120459 and CVE-2026-85394 in python-jose and PyJWT Migration Guidelines for FastAPI Authentication Layer"
slug: "fastapi-jwt-python-jose-migration"
date: 2026-11-07T11:00:53+09:00
draft: false
image: ""
description: "Dissecting the structural risks of CVE-2026-120459 and CVE-2026-85394 identified in python-jose. Outlining step-by-step migration procedures and exception handling design for moving to PyJWT following maintenance discontinuation."
categories: ["Backend Architecture"]
tags: ["python-jose", "pyjwt", "cve-2026-120459", "cve-2026-85394", "fastapi", "jwt", "pipdeptree"]
author: "K-Life Hack"
---

In authentication and authorization infrastructures for microservices and API gateways, the robustness of token verification processes defines the security boundary of the entire system. Especially in stateless JWT (JSON Web Token) verification, even a slight defect in the internal implementation behavior of a library or key interpretation logic directly leads to vulnerabilities such as authorization bypass or privilege escalation. In `python-jose`, which has long been used in tutorials for major frameworks such as FastAPI, vulnerabilities that allow empty-string HMAC secret keys and public key algorithm confusion attacks have been reported. Under circumstances where maintenance of the upstream repository has virtually ceased, this article details the technical background and migration procedures required to securely maintain production authentication infrastructure.



## Technical Background and Mechanisms of the Vulnerabilities

In all versions of `python-jose` prior to and including version 3.5.0, the presence of the following two critical vulnerabilities has been confirmed:



1. <b>CVE-2026-120459</b>: Acceptance of zero-length (empty string) HMAC secret keys
2. <b>CVE-2026-85394</b>: Algorithm confusion attacks via DER-encoded binary public key input

### CVE-2026-120459: Verification Bypass via Empty-String HMAC Keys

Symmetric-key cryptographic algorithms (HS256, HS384, HS512) perform signature verification based on the premise that a secret key is known only to the server. However, in the HMAC implementation classes of `python-jose` (`jose.backends.native.HMACKey` and `jose.backends.cryptography_backend.CryptographyHMACKey`), although type checking and string encoding of the input key are performed, validation to ensure the byte length is greater than zero is completely absent.


Due to this defect, if a secret key evaluates to `""` (empty string) due to undefined environment variable fallbacks or similar causes, an attacker can construct an arbitrary claims payload signed with an empty string and have it accepted by the server as a valid signature. Even if algorithms are explicitly restricted, such as `algorithms=["HS256"]`, this vulnerability cannot be prevented because the length and entropy of the key itself are not validated.



### CVE-2026-85394: Algorithm Confusion via DER Public Keys

In asymmetric cryptography such as RS256, signatures are generated with a private key and verified with a public key. The public key is information disclosed to clients and external entities. The "algorithm confusion attack" is a technique where an attacker obtains a known public key, rewrites the `alg` header of the JWT to `HS256`, and generates a signature using the binary data of the public key as the HMAC secret key.


⚠️ As a mitigation for CVE-2024-33663 in the past, `python-jose` introduced a guard to reject text-format PEM headers (`-----BEGIN ...`) as HMAC keys. However, when a public key is passed in binary DER encoding (`bytes`), it completely circumvents this regex-based check. Furthermore, `jwt.decode()` in `python-jose` defaults to `None` when the `algorithms` argument is omitted, skipping algorithm verification entirely. As a result, HMAC signatures created with the public key are validated as legitimate.



## Blind Spots in Dependency Scanning Detection

In automated vulnerability scanners introduced in standard CI/CD pipelines (such as `pip-audit` and Dependabot), metadata synchronization discrepancies have emerged regarding these two CVEs.



```text
[CVE-2026-85394]
  - GHSA-3qf3-8w2g-rqmx (Reviewed)
  - Mapped to PyPI as PYSEC-2026-4298
  - Detectable by standard scanners

[CVE-2026-120459]
  - GHSA-7jv8-hwmh-86qc (Unreviewed)
  - Not reflected in PyPI's vulnerability feed
  - Limited to Git commit ranges only in Google OSV, not linked to package versions
  - Risk of being missed by tools such as pip-audit
```

If an automated audit tool detects only CVE-2026-85394 and remediation is deferred under the assumption that "DER-formatted public keys are not handled, so it is safe," there is a risk of overlooking CVE-2026-120459 (empty string secret key risk), which is not registered in PyPI metadata.



## Dependency Investigation and Temporary Mitigations within Repositories

Immediately inspect whether `python-jose` is utilized across the production codebase and transitive dependencies.



```bash
# Search for direct imports in source code
grep -rnE "(from|import) jose" --include="*.py" .

# Check dependency manifests
grep -n "python-jose" requirements*.txt pyproject.toml poetry.lock uv.lock

# Check reverse dependency tree (uv or pipdeptree)
uv tree --invert --package python-jose
pipdeptree --reverse --packages python-jose
```

🛠️ In environments where the codebase cannot be rewritten immediately, introduce fail-fast validation at application startup to neutralize the preconditions that trigger the vulnerabilities.



```python
import os
from pydantic import field_validator
from pydantic_settings import BaseSettings

# 1. Startup environment variable check
RAW_SECRET = os.environ.get("SECRET_KEY")
if not RAW_SECRET or not RAW_SECRET.strip():
    raise RuntimeError("CRITICAL: The SECRET_KEY environment variable is unset or empty. Halting process.")

# 2. Guarantee entropy via Pydantic Settings
class SecuritySettings(BaseSettings):
    secret_key: str

    @field_validator("secret_key")
    @classmethod
    def validate_key_length(cls, v: str) -&gt; str:
        if not v or not v.strip() or len(v) &lt; 32:
            raise ValueError("SECRET_KEY must be at least 32 characters long to ensure sufficient entropy.")
        return v
```

## Migration Implementation to PyJWT

Perform the migration to `PyJWT` (version 2.15.0 or higher), which has also been adopted as standard in the official FastAPI documentation (PR #11589 onwards). Because earlier versions of `PyJWT` (such as 2.13.0 and 2.14.0) contained distinct DoS and key confusion vulnerabilities, always specify `&gt;=2.15.0`.



```bash
# Package replacement
pip uninstall -y python-jose
pip install "pyjwt&gt;=2.15.0"

# If using uv
uv remove python-jose
uv add "pyjwt&gt;=2.15.0"
```

### API Signature Differences and Refactoring

`python-jose` and `PyJWT` differ in their argument specifications and exception class hierarchies.



```python
# Pre-migration: python-jose (3.5.0)
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

Rewrite this into the following complete `PyJWT` implementation. `leeway` becomes a first-class keyword argument, and the exception handling scope changes.



```python
# After migration: PyJWT &gt;= 2.15.0
import jwt
from jwt.exceptions import InvalidTokenError, PyJWTError
from fastapi import HTTPException, status

credentials_exception = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Could not validate credentials",
    headers={"WWW-Authenticate": "Bearer"},
)

try:
    # The algorithms parameter is required
    payload = jwt.decode(
        token,
        SECRET_KEY,
        algorithms=["HS256"],
        leeway=10
    )
except InvalidTokenError:
    # Catch ExpiredSignatureError, DecodeError, etc. together
    raise credentials_exception
except PyJWTError as err:
    # Log system-level errors such as InvalidKeyError (invalid secret key)
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="Fatal inconsistency in token validation configuration"
    ) from err
```

## Troubleshooting

### Frequent Unexpected 401 Unauthorized Errors After Migration

💡 Because the `algorithms` argument was optional (defaulting to `None`) in `python-jose`, code running without an algorithm specification may have been operational. In `PyJWT`, specifying the `algorithms` argument is practically mandatory, and omitting it raises a `DecodeError`. Because `DecodeError` inherits from `InvalidTokenError`, it gets caught by the standard 401 handler described above, resulting in authentication failures being returned without generating logs. Verify that all calling `jwt.decode()` invocations contain an explicit specification such as `algorithms=["HS256"]`.



### Handling 500 Internal Server Error When the Secret Key Is Empty

⚠️ When an empty-string HMAC key is provided, `PyJWT` raises `InvalidKeyError`. This exception inherits directly from `PyJWTError` rather than being a subclass of `InvalidTokenError`. Therefore, if only an `except InvalidTokenError:` block is defined, the exception will not be caught and will surface as an unhandled 500 error inside FastAPI. Thorough environment variable validation at startup is necessary to suppress the occurrence of this exception at runtime.



### Terminal Verification Logs After Installing Dependent Packages

Verify that package updates and removal of unnecessary transitive dependencies have been executed successfully.



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

The repository owner of `python-jose` has publicly stated that they have no intention of continuing maintenance, and unmerged pull requests (such as PR #422) remain abandoned. While systems implementing proper key hygiene (using random secret keys of 32 bytes or more and explicitly specifying algorithms) do not immediately expose themselves to external attacks, continuing to operate a security-critical library whose upstream patch supply has completely ceased constitutes operational debt. Promptly complete the migration to `PyJWT &gt;= 2.15.0`, which is the standard across the FastAPI ecosystem, or transition to `joserfc` or `Authlib` depending on requirements.


#!/usr/bin/env python3
"""Supabase 셀프호스팅용 .env 보안 키 생성기.

JWT_SECRET을 랜덤 생성하고, 그것으로 서명된 ANON_KEY / SERVICE_ROLE_KEY(JWT)를 만든다.
외부 의존성 없이 파이썬 표준 라이브러리만 사용.

사용법:
    python3 generate_keys.py            # 화면에 출력
    python3 generate_keys.py > keys.env # 파일로 저장 (커밋 금지!)
"""

import base64
import hashlib
import hmac
import json
import secrets
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(secret: str, role: str, years: int = 10) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": now,
        "exp": now + years * 365 * 24 * 3600,
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    signature = hmac.new(
        secret.encode(), signing_input.encode(), hashlib.sha256
    ).digest()
    return signing_input + "." + b64url(signature)


def main() -> None:
    jwt_secret = secrets.token_urlsafe(48)  # 64자 랜덤
    postgres_password = secrets.token_urlsafe(24)
    dashboard_password = secrets.token_urlsafe(16)

    print("# supabase/docker/.env 에 아래 값을 붙여넣으세요.")
    print("# 이 출력물은 절대 git에 커밋하지 마세요!")
    print()
    print(f"POSTGRES_PASSWORD={postgres_password}")
    print(f"JWT_SECRET={jwt_secret}")
    print(f"ANON_KEY={make_jwt(jwt_secret, 'anon')}")
    print(f"SERVICE_ROLE_KEY={make_jwt(jwt_secret, 'service_role')}")
    print(f"DASHBOARD_PASSWORD={dashboard_password}")


if __name__ == "__main__":
    main()

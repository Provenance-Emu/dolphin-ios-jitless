from __future__ import annotations
import httpx

class DeviceError(Exception):
    pass

class Device:
    def __init__(self, base: str = "127.0.0.1:8723", timeout: float = 30):
        self.base = base if base.startswith("http") else f"http://{base}"
        self.client = httpx.Client(base_url=self.base, timeout=timeout)

    def _unwrap(self, r: httpx.Response) -> dict:
        try:
            body = r.json()
        except ValueError:
            raise DeviceError(f"{r.status_code}: non-JSON response") from None
        if r.status_code >= 400 or not body.get("ok", False):
            raise DeviceError(f"{r.status_code}: {body.get('error', 'unknown error')}")
        return body.get("data", {})

    def get(self, path: str, **params) -> dict:
        return self._unwrap(self.client.get(path, params=params or None))

    def post(self, path: str, body: dict | None = None) -> dict:
        return self._unwrap(self.client.post(path, json=body or {}))

    def get_bytes(self, path: str) -> bytes:
        r = self.client.get(path)
        if r.status_code >= 400:
            raise DeviceError(f"{r.status_code}: {r.text[:200]}")
        return r.content

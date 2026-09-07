import httpx, pytest, respx
from icube_debug.device import Device, DeviceError

BASE = "http://127.0.0.1:8723"

@respx.mock
def test_get_unwraps_envelope():
    respx.get(f"{BASE}/api/health").mock(return_value=httpx.Response(200, json={"ok": True, "data": {"fps": 60}}))
    assert Device().get("/api/health") == {"fps": 60}

@respx.mock
def test_error_envelope_raises_with_status():
    respx.post(f"{BASE}/api/debug/frame-advance").mock(return_value=httpx.Response(409, json={"ok": False, "error": "core must be paused"}))
    with pytest.raises(DeviceError, match="409: core must be paused"):
        Device().post("/api/debug/frame-advance", {"n": 1})

@respx.mock
def test_get_bytes_returns_raw_body():
    respx.get(f"{BASE}/api/debug/screenshot").mock(return_value=httpx.Response(200, content=b"\x89PNG", headers={"content-type": "image/png"}))
    assert Device().get_bytes("/api/debug/screenshot") == b"\x89PNG"

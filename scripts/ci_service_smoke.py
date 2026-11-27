#!/usr/bin/env python3
"""Black-box smoke test for the read-only Rust service boundary.

The service runs against a local mock upstream and a throwaway TLS reverse
proxy. Everything is ephemeral and loopback-only; no external service or
network is used.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import secrets
import select
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit


DEVICE_COUNT = 5
HEALTH_TIMEOUT_SECONDS = 40
HTTP_TIMEOUT_SECONDS = 10
MOCK_BODY = b'{"code":0,"data":{"ok":true}}'
MOCK_JSON_VALUE = {"code": 0, "data": {"ok": True}}
FULL_RELAY_PATH = "/novelfm/playerapi/full/mget/v1/"
FULL_RELAY_ITEM_ID = "chapter-1"
FULL_RELAY_BODY = (
    b'{"code":0,"data":{"item_infos":{"chapter-1":'
    b'{"title":"Chapter","key":"peer-key","content":"ciphertext"}},"kept":true},'
    b'"root_extra":"kept"}'
)
FULL_RELAY_BODY_LIMIT = 16 * 1024
CLIENT_PUBLIC_KEY = base64.b64encode(b"\x02").decode("ascii")
RELAY_AUTH_ENV = ("FQ_INSTALL_TOKEN", "FQ_INSTALL_SIGNING_KEY")
CM_HANDSHAKE_KEY_ENV = "FQ_CM_HANDSHAKE_KEY"
CM_HANDSHAKE_KEY = base64.b64encode(bytes(range(16))).decode("ascii")

ALLOWED_GET_PATHS = (
    "/api/v1/books/123",
    "/api/v1/books/123/detail",
    "/api/v1/books/123/directory",
    "/api/v1/books/123/directory/novel",
    "/api/v1/books/123/directory/fanqie",
    "/api/v1/novels/123",
)

FORBIDDEN_GET_PATHS = (
    "/api/v1/account/fanqie/library",
    "/api/v1/account/fanqie/history",
    "/api/v1/chapters/123",
    "/api/v1/chapters/123/",
    "/api/v1/chapters/123/timeline",
    "/api/v1/chapters/123/timepoints",
    "/src/x",
    "/src/",
    "/api/v1/shuqi/chapter",
    "/api/v1/shuqi/search/",
    "/api/v1/comments/1/digg",
    "/api/v1/books/123/reviews",
    "/api/v1/books/123/tones",
    "/api/v1/books/123/share",
    "/api/v1/manga/1",
    "/api/v1/series/1",
    "/api/v1/videos/1",
    "/api/v1/search",
    "/api/v1/search/",
    "/api/v1/authors/1",
    "/api/v1/items/1",
    "/api/v1/books/123/video-match",
    "/api/v1/books/123/chapters/summary",
    "/api/v1/audio/books/123",
    "/api/v1/audio/books/123/",
    "/api/v1/audio/books/123/chapters/456",
    "/api/v1/audio/play",
    "/api/v1/audio/wkcontent/123",
)

RAW_FORBIDDEN_GET_PATHS = (
    "/api/v1/books/123%2Fchapters",
    "/api/v1/books/123%2f..%2fchapters",
    "/api/v1/books/123%5Cchapters",
    "/api/v1/books/123%252Fchapters",
    "/api/v1/books/123/detail%2F..%2F..%2Fchapters",
    "/api/v1/%62ooks/123",
    "/api/v1/chapters/123?api=books&book_id=123",
)

METHOD_PATH = "/api/v1/books/123"
FORBIDDEN_METHODS = ("POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS")


class SmokeError(RuntimeError):
    """A smoke-test failure whose message is safe to write to evidence."""


def log(message: str) -> None:
    print(f"[service-smoke] {message}", flush=True)


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def sha256_file(path: Path) -> Tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def build_fixtures(root: Path) -> Dict[str, Path]:
    config_dir = root / "config"
    config_dir.mkdir(parents=True, exist_ok=True)

    config_path = config_dir / "config.json"
    write_json(
        config_path,
        {
            "algorithm_type": "8404",
            "port": 0,
            "zwsm": "suffix",
            "anti_crawler": {"enabled": False, "redirect_url": ""},
            "network_proxy": {"enabled": False, "url": ""},
            "admin": {"token": "", "update_server_url": ""},
            "upstream": {
                "version_name": "6.5.1.32",
                "version_code": "65132",
                "manifest_version_code": "65132",
                "update_version_code": "65132",
                "user_agent": "",
            },
        },
    )

    devices = []
    for index in range(DEVICE_COUNT):
        devices.append(
            {
                "device_id": f"{1_000_000_000_000_000 + index:016d}",
                "install_id": f"{9_000_000_000_000_000_000 + index}",
                "secret_key": f"{index + 1:032x}",
                "platform": "android",
                "status": "active",
                "created_time": "2026-01-01 00:00:00",
                "last_used": f"2026-01-01 00:00:{index:02d}",
                "use_count": index,
                "cdid": f"ci-cdid-{index}",
            }
        )

    pool_path = config_dir / "device_pool.json"
    write_json(
        pool_path,
        {"android": devices, "last_update": "2026-01-01 00:00:05"},
    )

    key_path = config_dir / "pool.key"
    key_path.write_text(
        base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
        encoding="ascii",
    )
    os.chmod(key_path, 0o600)

    filter_path = config_dir / "filter.json"
    write_json(filter_path, {"routes": {}})

    return {
        "config": config_path,
        "pool": pool_path,
        "pool_key": key_path,
        "filter": filter_path,
    }


class MockUpstream(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), MockUpstreamHandler)
        self._counts: Dict[str, int] = {}
        self._counts_lock = threading.Lock()

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"

    def record(self, path: str) -> None:
        with self._counts_lock:
            self._counts[path] = self._counts.get(path, 0) + 1

    def counts(self) -> Dict[str, int]:
        with self._counts_lock:
            return dict(sorted(self._counts.items()))


class MockUpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        self._respond()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 0:
            self.rfile.read(min(length, 1024 * 1024))
        self._respond()

    def _respond(self) -> None:
        path = urlsplit(self.path).path or "/"
        self.server.record(path)
        body = FULL_RELAY_BODY if path == FULL_RELAY_PATH else MOCK_BODY
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, _format: str, *args: Any) -> None:
        return


class TlsProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(
        self,
        backend_port: int,
        certificate: Path,
        private_key: Path,
    ) -> None:
        self.backend = ("127.0.0.1", backend_port)
        self.tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls_context.load_cert_chain(
            certfile=str(certificate),
            keyfile=str(private_key),
        )
        super().__init__(("127.0.0.1", 0), TlsProxyHandler)


class TlsProxyHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        try:
            self.request.settimeout(HTTP_TIMEOUT_SECONDS)
            client = self.server.tls_context.wrap_socket(
                self.request,
                server_side=True,
            )
        except (OSError, ssl.SSLError):
            return

        backend: Optional[socket.socket] = None
        try:
            backend = socket.create_connection(
                self.server.backend,
                timeout=HTTP_TIMEOUT_SECONDS,
            )
            client.settimeout(HTTP_TIMEOUT_SECONDS)
            backend.settimeout(HTTP_TIMEOUT_SECONDS)
            self._forward_request(client, backend)
            self._relay(client, backend)
        except (OSError, ssl.SSLError):
            return
        finally:
            for stream in (client, backend):
                if stream is None:
                    continue
                try:
                    stream.close()
                except OSError:
                    pass

    def _forward_request(
        self,
        client: ssl.SSLSocket,
        backend: socket.socket,
    ) -> None:
        request = bytearray()
        while b"\r\n\r\n" not in request:
            chunk = client.recv(65536)
            if not chunk:
                raise OSError("client closed before request headers")
            request.extend(chunk)
            if len(request) > 65536:
                raise OSError("request headers too large")

        head, separator, remainder = bytes(request).partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        if not lines or not lines[0]:
            raise OSError("empty request")

        rewritten = [lines[0]]
        host_written = False
        for line in lines[1:]:
            if line.lower().startswith(b"host:"):
                if not host_written:
                    rewritten.append(
                        f"Host: 127.0.0.1:{self.server.backend[1]}".encode("ascii")
                    )
                    host_written = True
                continue
            rewritten.append(line)
        if not host_written:
            rewritten.append(
                f"Host: 127.0.0.1:{self.server.backend[1]}".encode("ascii")
            )

        backend.sendall(b"\r\n".join(rewritten) + separator + remainder)

    @staticmethod
    def _relay(client: ssl.SSLSocket, backend: socket.socket) -> None:
        peers = {client: backend, backend: client}
        open_reads = {client, backend}
        while open_reads:
            readable, _, _ = select.select(
                list(open_reads),
                [],
                [],
                HTTP_TIMEOUT_SECONDS,
            )
            if not readable:
                return
            for source in readable:
                try:
                    data = source.recv(65536)
                except (OSError, ssl.SSLError):
                    return
                destination = peers[source]
                if not data:
                    open_reads.discard(source)
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    continue
                try:
                    destination.sendall(data)
                except OSError:
                    return


def generate_tls_certificate(root: Path) -> Tuple[Path, Path]:
    openssl = shutil.which("openssl")
    if openssl is None:
        raise SmokeError("openssl is required to create the local test certificate")

    config_path = root / "openssl.cnf"
    certificate = root / "certificate.pem"
    private_key = root / "private-key.pem"
    config_path.write_text(
        "\n".join(
            (
                "[req]",
                "prompt = no",
                "distinguished_name = distinguished_name",
                "x509_extensions = extensions",
                "",
                "[distinguished_name]",
                "CN = 127.0.0.1",
                "",
                "[extensions]",
                "subjectAltName = IP:127.0.0.1",
                "basicConstraints = critical,CA:TRUE",
                "keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign",
                "extendedKeyUsage = serverAuth",
                "",
            )
        ),
        encoding="ascii",
    )

    result = subprocess.run(
        [
            openssl,
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-nodes",
            "-days",
            "1",
            "-config",
            str(config_path),
            "-keyout",
            str(private_key),
            "-out",
            str(certificate),
        ],
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise SmokeError("openssl failed to create the local test certificate")
    os.chmod(private_key, 0o600)
    return certificate, private_key


def start_server_thread(
    server: Any,
    name: str,
) -> threading.Thread:
    thread = threading.Thread(
        target=server.serve_forever,
        name=name,
        daemon=True,
    )
    thread.start()
    return thread


def stop_server(server: Any, thread: threading.Thread) -> None:
    try:
        server.shutdown()
    except Exception:
        pass
    try:
        server.server_close()
    except Exception:
        pass
    thread.join(timeout=5)


def start_service(
    binary: Path,
    fixtures: Dict[str, Path],
    root: Path,
    port: int,
    mock_origin: str,
) -> subprocess.Popen[bytes]:
    command = [
        str(binary),
        "--config",
        str(fixtures["config"]),
        "--pool",
        str(fixtures["pool"]),
        "--pool-key-file",
        str(fixtures["pool_key"]),
        "--filter",
        str(fixtures["filter"]),
        "--listen",
        f"127.0.0.1:{port}",
        "--mock-upstream",
        mock_origin,
    ]
    environment = os.environ.copy()
    for name in RELAY_AUTH_ENV:
        environment.pop(name, None)
    environment[CM_HANDSHAKE_KEY_ENV] = CM_HANDSHAKE_KEY
    return subprocess.Popen(
        command,
        cwd=str(root),
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def stop_service(process: Optional[subprocess.Popen[bytes]]) -> None:
    if process is None:
        return
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def assert_non_loopback_refused(
    binary: Path,
    fixtures: Dict[str, Path],
    root: Path,
) -> None:
    command = [
        str(binary),
        "--config",
        str(fixtures["config"]),
        "--pool",
        str(fixtures["pool"]),
        "--pool-key-file",
        str(fixtures["pool_key"]),
        "--filter",
        str(fixtures["filter"]),
        "--listen",
        "0.0.0.0:0",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=str(root),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SmokeError("non-loopback service did not exit") from exc
    output = (result.stderr + result.stdout).decode("utf-8", "replace").lower()
    if result.returncode == 0 or "loopback" not in output:
        raise SmokeError(
            f"non-loopback listener was not refused (exit {result.returncode})"
        )


def http_request(
    method: str,
    path: str,
    port: int,
    *,
    use_tls: bool,
    body: Optional[bytes] = None,
    headers: Optional[Dict[str, str]] = None,
) -> Tuple[int, bytes]:
    scheme = "https" if use_tls else "http"
    url = f"{scheme}://127.0.0.1:{port}{path}"
    data = body if body is not None else (b"" if method not in ("GET", "HEAD") else None)
    request_headers = {"Accept": "application/json", "Connection": "close"}
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers=request_headers,
    )

    handlers: List[Any] = [urllib.request.ProxyHandler({})]
    if use_tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        handlers.append(urllib.request.HTTPSHandler(context=context))
    opener = urllib.request.build_opener(*handlers)

    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status, response.read(65536)
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(65536)
        except (OSError, http.client.HTTPException):
            body = b""
        finally:
            exc.close()
        return exc.code, body
    except (
        OSError,
        ssl.SSLError,
        http.client.HTTPException,
        urllib.error.URLError,
    ) as exc:
        raise SmokeError(
            f"{method} {path} transport failed ({type(exc).__name__})"
        ) from exc


def raw_http_status(
    port: int,
    target: str,
    *,
    host: Optional[str] = None,
    origin: Optional[str] = None,
) -> int:
    connection = http.client.HTTPConnection(
        "127.0.0.1",
        port,
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    try:
        connection.putrequest(
            "GET",
            target,
            skip_host=True,
            skip_accept_encoding=True,
        )
        connection.putheader("Host", host or f"127.0.0.1:{port}")
        connection.putheader("Accept", "application/json")
        connection.putheader("Connection", "close")
        if origin:
            connection.putheader("Origin", origin)
        connection.endheaders()
        response = connection.getresponse()
        response.read(65536)
        return response.status
    except (OSError, http.client.HTTPException) as exc:
        raise SmokeError(
            f"raw GET {target} transport failed ({type(exc).__name__})"
        ) from exc
    finally:
        connection.close()


def health_devices(body: bytes) -> Optional[int]:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    devices = payload.get("devices")
    return devices if isinstance(devices, int) else None


def wait_for_health(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + HEALTH_TIMEOUT_SECONDS
    last_state = "not reachable"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise SmokeError(
                f"service exited before becoming healthy (exit {process.returncode})"
            )
        try:
            status, body = http_request("GET", "/health", port, use_tls=False)
        except SmokeError:
            time.sleep(0.25)
            continue
        if status == 200:
            devices = health_devices(body)
            if devices == DEVICE_COUNT:
                return
            last_state = f"status 200 with devices={devices!r}"
        else:
            last_state = f"status {status}"
        time.sleep(0.25)
    raise SmokeError(f"service health was not ready: {last_state}")


def record_check(
    checks: List[Dict[str, Any]],
    phase: str,
    method: str,
    path: str,
    expected_status: int,
    actual_status: int,
) -> None:
    checks.append(
        {
            "phase": phase,
            "method": method,
            "path": path,
            "expected_status": expected_status,
            "status": actual_status,
            "passed": actual_status == expected_status,
        }
    )


def run_smoke(
    args: argparse.Namespace,
    root: Path,
    evidence: Dict[str, Any],
) -> None:
    binary = Path(args.binary).expanduser()
    if not binary.is_file():
        raise SmokeError(f"service binary not found: {binary}")
    binary = binary.resolve()
    digest, size = sha256_file(binary)
    evidence["binary"] = {
        "path": str(binary),
        "sha256": digest,
        "size": size,
    }

    fixtures = build_fixtures(root)
    checks: List[Dict[str, Any]] = []
    evidence["checks"] = checks
    assert_non_loopback_refused(binary, fixtures, root)
    checks.append(
        {
            "phase": "loopback_guard",
            "method": "START",
            "path": "--listen 0.0.0.0:0",
            "expected_status": "non-zero exit",
            "status": "refused",
            "passed": True,
        }
    )
    mock = MockUpstream()
    mock_thread = start_server_thread(mock, "service-smoke-mock")
    service: Optional[subprocess.Popen[bytes]] = None
    proxy: Optional[TlsProxyServer] = None
    proxy_thread: Optional[threading.Thread] = None

    try:
        service_port = free_tcp_port()
        service = start_service(
            binary,
            fixtures,
            root,
            service_port,
            mock.origin,
        )
        wait_for_health(service, service_port)
        log(f"health ready with devices={DEVICE_COUNT}")

        certificate, private_key = generate_tls_certificate(root)
        proxy = TlsProxyServer(service_port, certificate, private_key)
        proxy_thread = start_server_thread(proxy, "service-smoke-tls")

        tls_port = int(proxy.server_address[1])

        health_status, health_body = http_request(
            "GET",
            "/health",
            tls_port,
            use_tls=True,
        )
        devices = health_devices(health_body) if health_status == 200 else None
        checks.append(
            {
                "phase": "https_health",
                "method": "GET",
                "path": "/health",
                "expected_status": 200,
                "status": health_status,
                "devices": devices,
                "passed": health_status == 200 and devices == DEVICE_COUNT,
            }
        )

        for path in ALLOWED_GET_PATHS:
            status, body = http_request("GET", path, tls_port, use_tls=True)
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload = None
            checks.append(
                {
                    "phase": "allowed_read",
                    "method": "GET",
                    "path": path,
                    "expected_status": 200,
                    "status": status,
                    "body_matches": payload == MOCK_JSON_VALUE,
                    "passed": status == 200 and payload == MOCK_JSON_VALUE,
                }
            )
        upstream_baseline = mock.counts()

        for path in FORBIDDEN_GET_PATHS:
            status, _ = http_request("GET", path, tls_port, use_tls=True)
            record_check(checks, "forbidden_read", "GET", path, 404, status)

        for method in FORBIDDEN_METHODS:
            status, _ = http_request(
                method,
                METHOD_PATH,
                tls_port,
                use_tls=True,
            )
            record_check(
                checks,
                "method_boundary",
                method,
                METHOD_PATH,
                405,
                status,
            )

        for path in RAW_FORBIDDEN_GET_PATHS:
            status = raw_http_status(service_port, path)
            record_check(
                checks,
                "raw_forbidden_read",
                "GET",
                path,
                404,
                status,
            )

        status = raw_http_status(service_port, METHOD_PATH, host="evil.example")
        record_check(
            checks,
            "authority_boundary",
            "GET",
            "Host: evil.example",
            403,
            status,
        )
        status = raw_http_status(
            service_port,
            METHOD_PATH,
            host=f"127.0.0.1:{service_port + 1}",
        )
        record_check(
            checks,
            "authority_boundary",
            "GET",
            "Host: wrong port",
            403,
            status,
        )
        status = raw_http_status(
            service_port,
            METHOD_PATH,
            origin="http://evil.example",
        )
        record_check(
            checks,
            "authority_boundary",
            "GET",
            "Origin: http://evil.example",
            403,
            status,
        )
        status = raw_http_status(
            service_port,
            "/health",
            origin=f"http://127.0.0.1:{service_port}",
        )
        record_check(
            checks,
            "authority_boundary",
            "GET",
            "Origin: loopback",
            200,
            status,
        )

        upstream_after = mock.counts()
        if upstream_after != upstream_baseline:
            raise SmokeError("a rejected request reached the upstream")

        valid_full_request = json.dumps(
            {
                "book_id": "book-1",
                "item_ids": [FULL_RELAY_ITEM_ID],
                "client_public_key": CLIENT_PUBLIC_KEY,
            }
        ).encode("utf-8")
        json_headers = {"Content-Type": "application/json"}

        for method in ("GET", "OPTIONS"):
            status, _ = http_request(
                method,
                "/api/v1/chapters/full",
                tls_port,
                use_tls=True,
            )
            record_check(
                checks,
                "full_relay_method",
                method,
                "/api/v1/chapters/full",
                405,
                status,
            )

        invalid_requests = (
            ("bad json", b"{"),
            (
                "multiple items",
                json.dumps(
                    {
                        "book_id": "book-1",
                        "item_ids": [FULL_RELAY_ITEM_ID, "chapter-2"],
                        "client_public_key": CLIENT_PUBLIC_KEY,
                    }
                ).encode("utf-8"),
            ),
            (
                "bad client key",
                json.dumps(
                    {
                        "book_id": "book-1",
                        "item_ids": [FULL_RELAY_ITEM_ID],
                        "client_public_key": "Ag",
                    }
                ).encode("utf-8"),
            ),
        )
        for label, body in invalid_requests:
            status, _ = http_request(
                "POST",
                "/api/v1/chapters/full",
                tls_port,
                use_tls=True,
                body=body,
                headers=json_headers,
            )
            record_check(
                checks,
                "full_relay_validation",
                f"POST ({label})",
                "/api/v1/chapters/full",
                400,
                status,
            )

        status, _ = http_request(
            "POST",
            "/api/v1/chapters/full",
            tls_port,
            use_tls=True,
            body=b"x" * (FULL_RELAY_BODY_LIMIT + 1),
            headers=json_headers,
        )
        record_check(
            checks,
            "full_relay_validation",
            "POST (oversized)",
            "/api/v1/chapters/full",
            413,
            status,
        )
        if mock.counts() != upstream_after:
            raise SmokeError("a rejected Relay request reached the upstream")

        upstream_before_success = mock.counts()
        status, body = http_request(
            "POST",
            "/api/v1/chapters/full",
            tls_port,
            use_tls=True,
            body=valid_full_request,
            headers=json_headers,
        )
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = None
        item = (
            payload.get("data", {})
            .get("item_infos", {})
            .get(FULL_RELAY_ITEM_ID, {})
            if isinstance(payload, dict)
            else {}
        )
        relay_ok = (
            isinstance(payload, dict)
            and payload.get("code") == 0
            and item.get("key") == "peer-key"
            and item.get("content") == "ciphertext"
            and payload.get("data", {}).get("kept") is True
            and payload.get("root_extra") == "kept"
            and payload.get("relay", {}).get("protocol") == 1
            and payload.get("relay", {}).get("content_suffix") == "suffix"
        )
        checks.append(
            {
                "phase": "full_relay_success",
                "method": "POST",
                "path": "/api/v1/chapters/full",
                "expected_status": 200,
                "status": status,
                "relay_metadata": relay_ok,
                "passed": status == 200 and relay_ok,
            }
        )
        upstream_after_success = mock.counts()
        expected_counts = dict(upstream_before_success)
        expected_counts[FULL_RELAY_PATH] = (
            expected_counts.get(FULL_RELAY_PATH, 0) + 1
        )
        if upstream_after_success != expected_counts:
            raise SmokeError("the successful Relay did not reach exactly one upstream request")
        evidence["upstream_request_counts"] = upstream_after_success

        failed = [check for check in checks if not check["passed"]]
        if failed:
            summary = ", ".join(
                f"{check['method']} {check['path']} -> {check['status']} "
                f"(expected {check['expected_status']})"
                for check in failed
            )
            raise SmokeError(f"HTTP boundary checks failed: {summary}")
        log(f"service boundary checks passed ({len(checks)} checks)")
    finally:
        stop_service(service)
        if proxy is not None and proxy_thread is not None:
            stop_server(proxy, proxy_thread)
        stop_server(mock, mock_thread)
        evidence.setdefault("upstream_request_counts", mock.counts())


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the read-only Rust service boundary smoke test.",
    )
    parser.add_argument(
        "--binary",
        required=True,
        help="Path to the fqapi_server release binary.",
    )
    parser.add_argument(
        "--evidence",
        required=True,
        help="Path for the JSON evidence file.",
    )
    return parser.parse_args(argv)


def write_evidence(path: Path, evidence: Dict[str, Any]) -> None:
    write_json(path, evidence)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    evidence: Dict[str, Any] = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "passed": False,
        "checks": [],
    }

    try:
        with tempfile.TemporaryDirectory(prefix="fq-service-smoke-") as temp_dir:
            run_smoke(args, Path(temp_dir), evidence)
        evidence["passed"] = True
        log("smoke passed")
    except BaseException as exc:
        if isinstance(exc, SmokeError):
            message = str(exc)
        else:
            message = type(exc).__name__
        evidence["error"] = message
        log(f"smoke failed: {message}")

    try:
        write_evidence(Path(args.evidence), evidence)
    except OSError as exc:
        evidence["passed"] = False
        log(f"could not write evidence ({type(exc).__name__})")
        return 1
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())

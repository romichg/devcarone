"""The Go download proxy must route authenticated tunnels over IPv4."""

import base64
import importlib.util
import os
from pathlib import Path
import socket
from socketserver import BaseRequestHandler, ThreadingTCPServer
import threading
import unittest
from unittest import mock


PROXY_PATH = Path(__file__).resolve().parents[1] / "go-ipv4-proxy.py"
spec = importlib.util.spec_from_file_location("go_ipv4_proxy", PROXY_PATH)
with mock.patch.dict(os.environ, {"DEVCAR_GO_PROXY_TOKEN": "test-token"}):
    proxy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proxy)


class EchoHandler(BaseRequestHandler):
    def handle(self):
        self.request.sendall(self.request.recv(4).upper())


class GoIpv4ProxyTests(unittest.TestCase):
    def test_authenticated_connect_uses_ipv4_and_preserves_stream(self):
        with ThreadingTCPServer(("127.0.0.1", 0), EchoHandler) as upstream:
            upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
            upstream_thread.start()
            with proxy.ThreadingHTTPServer(("127.0.0.1", 0), proxy.Handler) as server:
                server_thread = threading.Thread(target=server.serve_forever, daemon=True)
                server_thread.start()
                real_getaddrinfo = socket.getaddrinfo
                families = []

                def ipv4_address(host, port, family, kind):
                    self.assertEqual((host, port, kind),
                                     ("example.com", 443, socket.SOCK_STREAM))
                    families.append(family)
                    return real_getaddrinfo("127.0.0.1", upstream.server_address[1],
                                            socket.AF_INET, socket.SOCK_STREAM)

                with mock.patch.object(proxy.socket, "getaddrinfo", side_effect=ipv4_address):
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                        client.settimeout(3)
                        client.connect(server.server_address)
                        credential = base64.b64encode(b"go:test-token").decode()
                        client.sendall((
                            "CONNECT example.com:443 HTTP/1.1\r\n"
                            f"Proxy-Authorization: Basic {credential}\r\n\r\n"
                        ).encode())
                        response = b""
                        while b"\r\n\r\n" not in response:
                            response += client.recv(4096)
                        self.assertIn(b"200 Connection Established", response)
                        client.sendall(b"ping")
                        self.assertEqual(client.recv(4), b"PING")
                self.assertEqual(families, [socket.AF_INET])
                server.shutdown()
            upstream.shutdown()

    def test_connect_without_proxy_authentication_is_rejected(self):
        with proxy.ThreadingHTTPServer(("127.0.0.1", 0), proxy.Handler) as server:
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                client.settimeout(3)
                client.connect(server.server_address)
                client.sendall(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
                self.assertIn(b"407 Proxy authentication required", client.recv(4096))
            server.shutdown()


if __name__ == "__main__":
    unittest.main()

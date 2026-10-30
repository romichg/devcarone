#!/usr/bin/env python3
"""Temporary authenticated HTTPS CONNECT proxy with IPv4-only upstream sockets."""

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import secrets
import select
import socket
import sys


TOKEN = os.environ["DEVCAR_GO_PROXY_TOKEN"]
AUTHORIZATION = "Basic " + base64.b64encode(f"go:{TOKEN}".encode()).decode()
HOST = re.compile(r"[A-Za-z0-9.-]+\Z")


class Handler(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        if not secrets.compare_digest(
            self.headers.get("Proxy-Authorization", ""), AUTHORIZATION
        ):
            self.send_error(407, "Proxy authentication required")
            return
        host, separator, port = self.path.rpartition(":")
        if separator != ":" or port != "443" or not HOST.fullmatch(host):
            self.send_error(403, "Only HTTPS hostnames are allowed")
            return

        upstream = None
        try:
            addresses = socket.getaddrinfo(
                host, 443, socket.AF_INET, socket.SOCK_STREAM
            )
            for _, kind, protocol, _, address in addresses:
                try:
                    upstream = socket.socket(socket.AF_INET, kind, protocol)
                    upstream.settimeout(10)
                    upstream.connect(address)
                    break
                except OSError:
                    upstream.close()
                    upstream = None
            if upstream is None:
                self.send_error(502, "IPv4 upstream connection failed")
                return

            self.send_response(200, "Connection Established")
            self.end_headers()
            self.connection.settimeout(None)
            upstream.settimeout(None)
            while True:
                readable, _, _ = select.select((self.connection, upstream), (), ())
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(data)
        except OSError:
            # The Go command receives a connection error and fails closed.
            return
        finally:
            if upstream is not None:
                upstream.close()

    def log_message(self, *_args):
        pass


def main():
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        port_file = sys.argv[1]
        descriptor = os.open(port_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(f"{server.server_port}\n")
        server.serve_forever()


if __name__ == "__main__":
    main()

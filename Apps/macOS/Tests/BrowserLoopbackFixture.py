"""Own loopback-only HTTP fixture; no project/user files are served."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import socket


class Handler(BaseHTTPRequestHandler):
    counts = {}

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        count = self.counts.get(self.path, 0) + 1
        self.counts[self.path] = count
        print(json.dumps({"path": self.path, "count": count}), flush=True)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/a")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if self.path not in ("/a", "/b"):
            self.send_error(404)
            return
        label = self.path[1:].upper()
        other = "b" if label == "A" else "a"
        data = (
            f"<!doctype html><html><head><title>Skynet Browser QA {label}</title>"
            f"</head><body><h1>SKYNET_BROWSER_{label}</h1><p>Request {count}</p>"
            f'<a href="/{other}">Go to {other.upper()}</a></body></html>'
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        print(json.dumps({"port": server.server_port}), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass

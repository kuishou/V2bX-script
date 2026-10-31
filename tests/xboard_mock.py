#!/usr/bin/env python3
# 最小化的 Xboard UniProxy/config 模拟服务端，仅用于离线测试 initconfig.sh。
# 行为参照 Xboard app/Http/Middleware/Server.php 与 ServerService::buildNodeConfig：
#   token 错误 -> 422 "Invalid token"；节点不存在 -> 400 "Server does not exist"；
#   hysteria2 是 hysteria 的别名。
# usage: python3 xboard_mock.py PORT TOKEN
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
ALIASES = {"v2ray": "vmess", "hysteria2": "hysteria"}
NODES = {
    (1, "vless"): {"protocol": "vless", "server_port": 443, "tls": 2, "flow": "xtls-rprx-vision"},
    (2, "hysteria"): {"protocol": "hysteria", "server_port": 8443, "version": 2,
                      "server_name": "hy.example.com", "up_mbps": 100, "down_mbps": 100},
    (3, "trojan"): {"protocol": "trojan", "server_port": 2083, "tls": 1, "server_name": "tj.example.com"},
    (4, "shadowsocks"): {"protocol": "shadowsocks", "server_port": 23456, "cipher": "aes-128-gcm"},
}
USERS = {"users": [{"id": 1, "uuid": "8c5a4b1e-3c55-4a5b-9e0e-2a7f5d1c9b01", "speed_limit": 0, "device_limit": 0}]}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_api(self):
        u = urlparse(self.path)
        prefix = "/api/v1/server/UniProxy/"
        if not u.path.startswith(prefix):
            return self.send(404, {"message": "Not Found"})
        action = u.path[len(prefix):]
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if q.get("token") != TOKEN:
            return self.send(422, {"message": "Invalid token", "errors": {"token": ["Invalid token"]}})
        t = q.get("node_type", "")
        t = ALIASES.get(t, t)
        node = NODES.get((int(q.get("node_id", "0") or 0), t))
        if not node:
            return self.send(400, {"status": "fail", "message": "Server does not exist"})
        if action == "config":
            return self.send(200, dict(node, base_config={"push_interval": 60, "pull_interval": 60}))
        if action == "user":
            return self.send(200, USERS)
        if action == "alivelist":
            return self.send(200, {"alive": {}})
        if action in ("push", "alive", "status"):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            return self.send(200, {"data": True})
        return self.send(404, {"message": "Not Found"})

    do_GET = handle_api
    do_POST = handle_api


HTTPServer(("127.0.0.1", PORT), H).serve_forever()

#!/usr/bin/env python3
# 最小化的 Xboard 节点接口模拟服务端，仅用于离线测试 initconfig.sh。
# v1（/api/v1/server/UniProxy/*，全局通讯密钥）行为参照
#   app/Http/Middleware/Server.php 与 ServerService::buildNodeConfig：
#   token 错误 -> 422 "Invalid token"；节点不存在 -> 400 "Server does not exist"；
#   hysteria2 是 hysteria 的别名。
# v2（/api/v2/server/*）行为参照 app/Http/Middleware/ServerV2.php：
#   带 machine_id 时按机器令牌鉴权，不看 node_type：
#     机器 ID / 令牌不匹配 -> 401 "Machine not found or invalid token"
#     机器已停用           -> 403 "Machine is disabled"
#     节点未绑定到该机器或未启用 -> 400 "Node not found on this machine"
#   不带 machine_id 时按全局通讯密钥鉴权，节点只按 ID 查找。
# 设置环境变量 XBOARD_MOCK_LOG 时，把每个请求的 "方法 路径?查询" 追加到该文件。
# usage: python3 xboard_mock.py PORT TOKEN [MACHINE_TOKEN]
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
MACHINE_TOKEN = sys.argv[3] if len(sys.argv) > 3 else "machine-token-0123456789abcdef01"
LOG = os.environ.get("XBOARD_MOCK_LOG")
ALIASES = {"v2ray": "vmess", "hysteria2": "hysteria"}
NODES = {
    1: {"protocol": "vless", "server_port": 443, "tls": 2, "flow": "xtls-rprx-vision"},
    2: {"protocol": "hysteria", "server_port": 8443, "version": 2,
        "server_name": "hy.example.com", "up_mbps": 100, "down_mbps": 100},
    3: {"protocol": "trojan", "server_port": 2083, "tls": 1, "server_name": "tj.example.com"},
    4: {"protocol": "shadowsocks", "server_port": 23456, "cipher": "aes-128-gcm"},
}
# 机器：7 启用，8 已停用
MACHINES = {7: {"token": MACHINE_TOKEN, "active": True},
            8: {"token": "disabled-machine-token-00000000", "active": False}}
# 节点绑定的机器与是否启用：节点 3 未绑定机器，节点 4 绑定到 7 但未启用
NODE_MACHINE = {1: (7, True), 2: (7, True), 3: (None, True), 4: (7, False)}
USERS = {"users": [{"id": 1, "uuid": "8c5a4b1e-3c55-4a5b-9e0e-2a7f5d1c9b01", "speed_limit": 0, "device_limit": 0}]}


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


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

    def fail(self, code, message):
        return self.send(code, {"status": "fail", "message": message, "data": None, "error": None})

    def auth_v1(self, q):
        if q.get("token") != TOKEN:
            self.send(422, {"message": "Invalid token", "errors": {"token": ["Invalid token"]}})
            return None
        t = q.get("node_type", "")
        t = ALIASES.get(t, t)
        node = NODES.get(to_int(q.get("node_id")) or 0)
        if not node or node["protocol"] != t:
            self.fail(400, "Server does not exist")
            return None
        return node

    def auth_v2(self, q):
        if q.get("machine_id"):
            mid, nid = to_int(q.get("machine_id")), to_int(q.get("node_id"))
            if mid is None or nid is None or not q.get("token"):
                self.send(422, {"message": "The given data was invalid.", "errors": {}})
                return None
            m = MACHINES.get(mid)
            if not m or m["token"] != q["token"]:
                self.fail(401, "Machine not found or invalid token")
                return None
            if not m["active"]:
                self.fail(403, "Machine is disabled")
                return None
            bound, enabled = NODE_MACHINE.get(nid, (None, False))
            if nid not in NODES or bound != mid or not enabled:
                self.fail(400, "Node not found on this machine")
                return None
            return NODES[nid]
        if q.get("token") != TOKEN:
            self.send(422, {"message": "Invalid token", "errors": {"token": ["Invalid token"]}})
            return None
        node = NODES.get(to_int(q.get("node_id")) or 0)
        if not node:
            self.fail(400, "Server does not exist")
            return None
        return node

    def handle_api(self):
        if LOG:
            with open(LOG, "a") as f:
                f.write("%s %s\n" % (self.command, self.path))
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        for prefix, auth in (("/api/v1/server/UniProxy/", self.auth_v1), ("/api/v2/server/", self.auth_v2)):
            if u.path.startswith(prefix):
                action = u.path[len(prefix):]
                break
        else:
            return self.send(404, {"message": "Not Found"})
        node = auth(q)
        if node is None:
            return None
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

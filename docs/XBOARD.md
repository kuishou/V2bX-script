# V2bX 对接 Xboard：深度分析与安全方案

本文是对本仓库脚本（`install.sh` / `V2bX.sh` / `initconfig.sh`）的深度审计结果，以及对接 [Xboard](https://github.com/cedar2025/Xboard) 的推荐部署方案。
分析依据：本仓库 `main`、[liusu2100-sys/V2bX](https://github.com/liusu2100-sys/V2bX) `dev_new`（V2bX v0.4.x，sing-box 1.13 / xray-core / hysteria 2.6.4）、Xboard `master`（2026-10）。

---

## 1. 对接原理

V2bX 通过 Xboard 的 **UniProxy** 接口工作，所有请求都带 `node_type`、`node_id`、`token` 三个查询参数：

| 接口 | 方法 | 作用 | 默认频率 |
| --- | --- | --- | --- |
| `/api/v1/server/UniProxy/config` | GET | 拉取节点配置（端口、协议参数、TLS/Reality、路由规则），支持 ETag | `server_pull_interval`（60 秒） |
| `/api/v1/server/UniProxy/user` | GET | 拉取可用用户（UUID、限速、设备数），msgpack/JSON，支持 ETag | 同上 |
| `/api/v1/server/UniProxy/push` | POST | 上报流量 | `server_push_interval`（60 秒） |
| `/api/v1/server/UniProxy/alive` / `alivelist` | POST / GET | 在线 IP 上报 / 设备数限制 | 同上 |

鉴权（Xboard `app/Http/Middleware/Server.php`）：

- `token` 必须等于后台「系统配置 → 服务端 → **通讯密钥**」（`server_token`，至少 16 位）。**这个密钥是全局的，所有节点共用。**
- `node_type` 会被规范化：`v2ray → vmess`、`hysteria2 → hysteria`。因此 Xboard 里的 Hysteria2 节点是「**Hysteria 节点 + 版本 2**」，V2bX 中 `NodeType` 填 `hysteria2`。
- 节点协议由面板决定；V2bX 本地只决定**内核**（xray / sing / hysteria2）、**证书**和本地路由。

> **核心风险**：拿到通讯密钥 = 可以对任意节点 ID 调用 `UniProxy/user`，拉取整个机场所有用户的 UUID / 密码，还能伪造流量上报。所以密钥的存储、传输、日志都必须按"最高机密"处理。

### 1.1 机器令牌（推荐）

新版 Xboard 提供 **机器令牌**：在后台的机器管理中为每台服务器创建一台"机器"，把该服务器上的节点绑定到这台机器，即可得到 **机器 ID** 和该机器专属的 **令牌**（32 位随机串，可重置、可停用）。此时 V2bX 改走 v2 接口，查询参数为 `machine_id`、`node_id`、`token`（**不带 `node_type`**）：

| 接口 | 方法 | 作用 |
| --- | --- | --- |
| `/api/v2/server/config` | GET | 拉取节点配置（与 v1 内容相同） |
| `/api/v2/server/user` | GET | 拉取可用用户 |
| `/api/v2/server/push` | POST | 上报流量 |
| `/api/v2/server/alive` / `alivelist` | POST / GET | 在线 IP 上报 / 设备数限制 |

鉴权（Xboard `app/Http/Middleware/ServerV2.php`）：

| 情况 | 面板返回 | 脚本提示 |
| --- | --- | --- |
| 机器 ID 不存在或令牌不匹配 | 401 `Machine not found or invalid token` | 机器 ID 或机器令牌错误 |
| 机器已停用 | 403 `Machine is disabled` | 机器已在 Xboard 中停用 |
| 节点不存在、未绑定到该机器或未启用 | 400 `Node not found on this machine` | 节点不在该机器上 |

与全局通讯密钥相比：

- **泄露范围小**：一台服务器被攻破，只能访问绑定在这台机器上的节点，拿不到其他节点的用户；
- **可单独处置**：怀疑泄露时在面板中停用该机器或重置其令牌即可，不必轮换全局密钥、改动所有节点；
- v1 的 `Server` 中间件在 Xboard 中已标注 `@deprecated use ServerV2`，v2 是今后的主路径。

注意事项：

- **需要 V2bX 核心支持 `MachineID`**：即 [liusu2100-sys/V2bX PR #1](https://github.com/liusu2100-sys/V2bX/pull/1)（分支 `feat/xboard-machine-token`，提交 `b1e8646`），且已发布包含该改动的新版本。旧版核心会忽略 `MachineID`，仍走 v1 接口并把机器令牌当作通讯密钥，结果是对接失败（`Invalid token`）。
- **`NodeID` 必须是节点的数字 ID**：v2 中间件只按 `id` 匹配，不支持节点 code。
- 节点协议由面板决定；v2 接口不再校验 `node_type`，所以脚本会自行比对面板返回的 `protocol` 与本地 `NodeType`（`hysteria2` 对应面板 `hysteria`），不一致时提示"节点协议不符"。

生成的节点配置（其余字段与全局通讯密钥模式完全相同）：

```json
{
    "Core": "sing",
    "ApiHost": "https://xboard.example.com",
    "ApiKey": "机器令牌",
    "MachineID": 7,
    "NodeID": 1,
    "NodeType": "vless",
    ...
}
```

`MachineID` 缺省或为 `0` 时就是原来的 v1 + 全局通讯密钥，已有配置无需任何修改。

---

## 2. 审计发现与处理结果

按严重程度排列。"已修复" 均已在本仓库脚本中实现并通过测试（见第 6 节）。

### 2.1 安全问题

| # | 等级 | 问题 | 处理 |
| --- | --- | --- | --- |
| S1 | **高** | `/etc/V2bX/config.json`（含全局通讯密钥、DNS API 凭据）以默认 644 权限写入，本机任何用户 / 被入侵的低权限服务都能读到 | **已修复**：目录 700、配置文件 600；systemd 加 `UMask=0077`；V2bX 核心把证书私钥写成 644 的问题也因此变为 600 |
| S2 | **高** | 向导允许 `http://` 面板地址，通讯密钥在**每个请求的 URL 中**明文传输 | **已修复**：只接受 `https://`（本机 `127.0.0.1`/`localhost` 除外），内网确需 http 时须显式 `V2BX_ALLOW_HTTP=1` |
| S3 | **高** | 菜单 16 会停用 firewalld/ufw、`setenforce 0`、清空全部 iptables 规则 | **已修复**：改为「放行指定端口」，自动识别 ufw / firewalld / iptables(+ip6tables)，只追加 TCP+UDP 放行规则、幂等、不动默认策略 |
| S4 | 中 | 面板地址 / 密钥原样拼进 JSON heredoc，含 `"` 或 `\` 时写坏配置，存在 JSON 注入 | **已修复**：所有用户输入经 `json_escape`，拒绝控制字符；生成后用 jq / python3 校验，失败不覆盖原配置 |
| S5 | 中 | Release 缺少 `.dgst` 时只警告继续安装 | **已修复**：默认缺失即中止（本仓库 CI 总会生成 `.dgst`），需要时 `V2BX_REQUIRE_CHECKSUM=0` 显式关闭 |
| S6 | 中 | 安装 / 更新时先 `rm -rf /usr/local/V2bX` 再下载，下载失败或校验失败会让节点直接瘫痪 | **已修复**：在同一文件系统的暂存目录中下载、校验、解压，全部成功后原子替换；失败时现有安装不变 |
| S7 | 中 | 用户传入的版本号直接拼进下载 URL | **已修复**：版本号只允许 `[0-9A-Za-z._-]` |
| S8 | 中 | V2bX 以 root 运行且无任何沙箱 | **已修复**：systemd 加固（`NoNewPrivileges`、`ProtectSystem=full`、`ProtectHome=read-only`、只允许写 `/etc/V2bX` 与 `/usr/local/V2bX`、禁止加载内核模块 / 改 sysctl、能力集收缩到网络与文件所需）；按 systemd 版本选择指令（兼容 CentOS 7 的 219）；`V2BX_HARDEN=0` 可关闭 |
| S9 | 中 | hysteria2 ACL 使用 `geosite:` / `geoip:`，hysteria 会在运行时从 GitHub 下载**未校验**的 geo 数据 | **已修复**：ACL 改为纯 CIDR，只阻断内网 / 回环 / 链路本地 / CGNAT 地址 |
| S10 | 低 | 输入通讯密钥、DNS Token 时明文回显 | **已修复**：`read -s` 不回显 |
| S11 | 低 | 对接检测若用 `curl "...&token=xxx"`，密钥会出现在 `ps` 进程列表 | **已规避**：检测时通过 `curl -K -`（stdin 配置）传参并 URL 编码，命令行和输出中都不出现密钥 |
| S12 | 低 | `install.sh` 结束时无条件删除当前目录下的 `install.sh`（可能误删用户文件） | **已修复**：删除该行 |
| S13 | 低 | 卸载直接 `rm -rf /etc/V2bX`，证书与配置不可恢复 | **已修复**：卸载前打包到 `/root/V2bX-config-<时间>.tar.gz`（600） |

### 2.2 功能缺陷（会导致配置"静默失效"）

| # | 问题 | 影响 | 处理 |
| --- | --- | --- | --- |
| F1 | sing 节点写的是 `TCPFastOpen` / `SniffEnabled`，V2bX 实际解析的键是 `EnableTFO` / `EnableSniff`；而且 V2bX 的 sing 内核**根本不使用** `EnableSniff`，是否嗅探只由 `sing_origin.json` 的路由规则决定，原版生成的该文件里没有 sniff 动作 | TFO 开关被忽略；sing 节点从未嗅探，**按协议匹配的规则（如屏蔽 BT）从未生效**，客户端以 IP 发起的连接也匹配不到域名规则 | **已修复**：改用 `EnableTFO`；`sing_origin.json` 第一条规则为 `sniff` 动作，屏蔽改用 `reject` 动作（官方 sing-box 1.13 已删除 `block` 出站），DNS 改用新写法；不再写入无效的 `EnableSniff` |
| F2 | 写的是 `MinReportTraffic`，实际键名是 `ReportMinTraffic` | 设置被忽略 | **已修复** |
| F3 | 证书模式 `self` 被描述为"自签或已有证书"，而 V2bX 中 `self`=自动自签、`file`=已有证书 | 选了"已有证书"实际被覆盖为自签 | **已修复**：拆分为 http / dns / file / self 四种 |
| F4 | dns 模式写入占位 `"EnvName": "env1"`，必然申请失败 | 需手动改配置 | **已修复**：向导直接询问服务商与凭据（Cloudflare 引导使用最小权限 API Token） |
| F5 | 多节点时 `isreality` / `istls` 沿用上一个节点的回答 | 第二个节点证书配置错误 | **已修复**：每个节点独立变量 |
| F6 | xray 内核可以选 Hysteria2 / Tuic 等它不支持的协议；非法输入默认变成 shadowsocks | 生成无法启动的配置 | **已修复**：按内核限制可选协议，非法输入重新询问 |
| F7 | `V2bX.sh` 与 `initconfig.sh` 各有一份 500 行的生成逻辑且已分叉（`route.json` 缺少最后一条出站规则、`core_hysteria2` 未初始化） | 两个入口生成的配置不同 | **已修复**：生成逻辑只保留在 `initconfig.sh`，安装到 `/usr/local/V2bX/`，管理脚本 source 它 |
| F8 | IPv6 检测把 `::1` 也算作 IPv6，几乎总是返回"支持" | sing 监听 / DNS 策略判断错误 | **已修复**：只看 `scope global` 地址 |
| F9 | 旧配置固定备份为 `config.json.bak`，第二次生成就覆盖掉第一次的备份 | 无法回滚 | **已修复**：带时间戳备份，保留最近 5 份 |
| F10 | `V2bX config` 编辑后不检查语法直接重启 | 一个逗号就让节点掉线 | **已修复**：JSON 不合法时不重启 |
| F11 | OpenRC（Alpine）没有日志，`V2bX log` 直接退出 | 无法排错 | **已修复**：日志写入 `/var/log/V2bX.log` |
| F12 | 原版默认带一份大而全的域名屏蔽列表（gov、bank、taobao、visa、360……） | 大量正常访问被静默阻断 | **改为可选**（默认关闭）；默认只阻断内网地址与 BT。推荐在 Xboard「路由管理」下发 |
| F13 | xray 核心没有写 `XrayConnectionConfig`，V2bX 默认 `connIdle` 只有 30 秒（Xray 官方默认 300） | 空闲 30 秒的连接被断开：SSH、IM、游戏大厅等长连接频繁掉线 | **已修复**：写入 `connIdle: 300`（内存 ≤ 600MB 时 120），`downlinkOnly` 改为官方默认 5 |
| F14 | xray 节点写 `"DNSType": "UseIPv4"`；但未命中路由的流量走 `custom_outbound.json` 的第一个出站，节点自身出站（`EnableDNS` / `DNSType` / `SendIP`）根本不被使用，且 `DNSType` 只在 `EnableDNS: true` 时才被读取 | 设置无效 | **已修复**：不再写 `DNSType`；改为生成 `dns.json`（`queryStrategy`），并按是否有公网 IPv6 设置第一个出站的 `domainStrategy`（`UseIPv4` / `UseIPv4v6`）；无 IPv6 时 route.json 屏蔽 `::/0`，客户端可立即回退 |
| F15 | hy2config 解析器为 `system`，出站模式为默认 `auto`；`initStreamReceiveWindow` 因 V2bX 的赋值错误实际不生效 | 无 IPv6 的机器可能先尝试 IPv6 再失败 | **已修复**：解析器改为 `udp` 1.1.1.1；出站 `mode` 按 IPv6 情况设为 `"4"` / `"46"`，无 IPv6 时 ACL 拒绝 `::/0`，并以 `direct(all)` 结尾；不再写不生效的 `initStreamReceiveWindow` / `disablePathMTUDiscovery` |

### 2.3 新增的 Xboard 对接能力

- **实时对接校验**：向导每添加一个节点就请求 `UniProxy/config`，区分 *密钥错误 / 节点不存在或协议不符 / 404 地址错误 / CDN-WAF 拦截 / 网络或 TLS 错误*，并检查 Hysteria 版本是否与选择一致。
- **按面板配置自动决策**：Reality（`tls=2`）与无 TLS（`tls=0`）节点自动跳过证书；证书域名默认取面板中的 `server_name`。
- **`V2bX check`**（菜单 17）：随时检测 `config.json` 中所有节点的对接状态（需要 jq 或 python3）。
- **机器令牌**：向导在填写面板地址后询问鉴权方式（默认全局通讯密钥，行为不变；可选机器令牌，额外填写机器 ID）。选择机器令牌时，节点配置写入 `"MachineID": <id>`，向导和 `V2bX check` 改为请求 `/api/v2/server/config`，并能区分机器令牌错误 / 机器已停用 / 节点未绑定到该机器或未启用。见 1.1 节。

---

## 3. 推荐方案（最安全且可落地）

### 3.1 Xboard 面板侧

0. **优先使用机器令牌**（需要 V2bX 核心支持，见 1.1 节）：每台服务器在 Xboard 中建一台机器，把该服务器上的节点绑定上去并启用；节点上运行向导时鉴权方式选 `2. 机器令牌`，填写机器 ID 与令牌。下面关于通讯密钥的各条在机器令牌模式下同样适用于机器令牌（HTTPS、接口白名单、不写访问日志）；全局通讯密钥即使不再使用，也应保持为强随机值。

1. **通讯密钥用强随机值**，并只在节点配置中出现：

   ```bash
   openssl rand -hex 24      # 48 位十六进制，填入「系统配置 → 服务端 → 通讯密钥」
   ```

2. **面板必须 HTTPS**（脚本已强制）。

3. **节点接口只允许节点 IP 访问**（效果最好的一条：即便密钥泄露，外部也用不了）。在 Xboard 前面的 Nginx 中：

   ```nginx
   # 节点通讯接口：只允许你的节点服务器
   location ~ ^/api/v[12]/server/ {
       allow 203.0.113.10;     # 节点 1
       allow 203.0.113.11;     # 节点 2
       deny  all;
       access_log off;         # token 在 URL 里，不写访问日志
       proxy_pass http://127.0.0.1:7001;   # 按你的 Xboard 部署修改
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
   }
   ```

   不方便维护白名单时，至少保留 `access_log off`（或把日志格式中的 `$request` 换成 `$uri`），避免密钥落入日志与日志收集系统。

4. **使用 Cloudflare 时**：节点通讯建议走单独的**源站直连域名**（如 `node-api.example.com`，灰云 + 源站证书 + 上面的 IP 白名单）；若必须经过 CF，请为 `/api/v1/server/` 路径对节点 IP 配置 WAF 跳过规则，否则 Bot Fight / 质询页会让 V2bX 拉到一个 HTML 页面（`V2bX check` 会提示"返回 200 但不是节点配置"）。

5. **审计规则放在面板**：在 Xboard「路由管理」中配置屏蔽规则并绑定到节点，统一下发、统一修改，无需登录每台节点。

6. **轮换通讯密钥**（怀疑泄露或定期轮换）：
   1) 在 Xboard 修改通讯密钥；
   2) 立即在每台节点执行 `V2bX config`，把各节点的 `ApiKey` 改为新密钥并保存（会自动校验 JSON 并重启）；
   3) `V2bX check` 确认对接正常。
   在第 1、2 步之间节点会短暂无法同步（已下发的用户连接不受影响）。

   **使用机器令牌时**只需处理受影响的那台服务器：在 Xboard 中重置该机器的令牌（或先停用该机器），再在这台服务器上执行 `V2bX config` 把它所有节点的 `ApiKey` 改为新令牌，`V2bX check` 确认即可，其他服务器不受影响。

### 3.2 节点侧

| 项目 | 推荐 |
| --- | --- |
| 安装 | 先下载再审阅后执行：`curl -fLo install.sh https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh && less install.sh && bash install.sh` |
| 内核 | Hysteria2 / TUIC / AnyTLS 用 **sing**；VLESS-Reality、VMess、Trojan、Shadowsocks 用 **xray** 或 sing 均可（同机多协议时都用 sing 可只跑一个内核） |
| 证书 | **dns 模式** + Cloudflare 仅含 `Zone.DNS` 权限、只限对应域名的 API Token；不需要开放 80 端口 |
| 防火墙 | 保持开启，用 `V2bX open_ports` 只放行节点端口（UDP 协议记得同时放 UDP）；同时检查云厂商安全组 |
| 沙箱 | 保持默认的 systemd 加固；证书若需写到其他目录，用 `systemctl edit V2bX` 追加 `ReadWritePaths=` 而不是关闭加固 |
| 自检 | 每次改配置后 `V2bX check`；面板中确认节点在线 |
| SSH | 与本脚本无关但同样关键：禁用密码登录、仅密钥登录，节点上不要运行其他对外服务 |

### 3.3 部署流程

1. Xboard：创建节点（记下节点**数字 ID**、协议、端口；Hysteria2 选 Hysteria + 版本 2），配置好通讯密钥、HTTPS 与接口白名单；使用机器令牌时再创建机器、把节点绑定到该机器并启用，记下机器 ID 与令牌。
2. 节点：`bash install.sh`，首次安装选 `y` 进入向导，按提示填写（鉴权方式回车为全局通讯密钥，选 `2` 为机器令牌）；向导会当场验证对接。
3. `V2bX open_ports` 放行节点端口，云厂商安全组同样放行。
4. `V2bX check` 与 `V2bX log` 确认；1～2 分钟后面板显示节点在线。

---

## 4. 剩余风险与后续改进

| 风险 | 说明 | 建议 |
| --- | --- | --- |
| 全局通讯密钥 | 仍选择全局通讯密钥时，一台节点被攻破即泄露整个面板的节点凭据 | **改用机器令牌**（见 1.1 节）：向导中鉴权方式选 `2`，节点配置写入 `MachineID`，只能访问绑定在该机器上的节点，可单独停用 / 重置。前提是 V2bX 核心已合并 [liusu2100-sys/V2bX PR #1](https://github.com/liusu2100-sys/V2bX/pull/1) 并发布新版本；在此之前请继续使用全局通讯密钥 |
| v1 接口已标记弃用 | Xboard 中 v1 的 `Server` 中间件已标注 `@deprecated use ServerV2` | 机器令牌模式已走 v2；全局通讯密钥模式仍走 v1，将来 v1 被移除前应迁移到机器令牌 |
| 密钥在 URL 中 | 由 V2bX 核心决定（查询参数），会出现在面板反代日志中 | 面板侧 `access_log off`；核心改造时可改用请求头 |
| 脚本跟随 `main` 分支 | `V2bX update_shell` 及安装入口没有签名校验，信任根是 GitHub 账号 | 开启 2FA、分支保护；可选：发布带 tag 的版本并用 minisign 签名 |
| `.dgst` 与 zip 同在一个 Release | 只能防传输损坏 / 镜像篡改，不能防 Release 被替换 | 可在 CI 中用 cosign / minisign 对 zip 签名，脚本内置公钥校验 |
| `ProtectSystem=full` | 证书写到 `/etc/V2bX` 之外时自动申请会失败 | 见 3.2「沙箱」 |

---

## 5. 环境变量开关

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `V2BX_REQUIRE_CHECKSUM=0` | 1（强制） | Release 缺少 `.dgst` 时仍继续安装（不推荐） |
| `V2BX_HARDEN=0` | 1 | 安装时不写入 systemd 沙箱指令 |
| `V2BX_ALLOW_HTTP=1` | 0 | 向导允许 `http://` 面板地址（仅内网 / 专线） |
| `V2BX_INSECURE=1` | 0 | TLS 证书错误时允许跳过校验重试一次（仅 CA 过旧的 EOL 系统） |
| `V2BX_CONF_DIR` | `/etc/V2bX` | 向导的配置目录（测试用） |

---

## 6. 测试

| 测试 | 命令 | 覆盖 |
| --- | --- | --- |
| 向导 + 对接（离线，自带 Xboard 模拟服务端，含 v1 与 v2 路由） | `docker run --rm -v "$PWD":/t:ro python:3.12-slim bash -c 'apt-get update -qq && apt-get install -y -qq curl jq >/dev/null; bash /t/tests/initconfig.sh /t/initconfig.sh'` | 86 项：地址校验、密钥错误 / 节点不存在识别、hysteria2 别名、多节点多内核、特殊字符转义、Reality 自动跳过证书、dns 凭据、权限、备份、`V2bX check`；机器令牌：请求路径与参数（带 `machine_id`、不带 `node_type`）、401 令牌错误 / 403 机器停用 / 节点未绑定或未启用 / 协议不符的识别、生成的 `MachineID`、非法机器 ID 与节点 code 的拒绝、嵌套 `ApiConfig` 写法；全局通讯密钥模式不写 `MachineID` 且只请求 v1 |
| bash 4.2（CentOS 7 同版本） | 同上，镜像换成 `bash:4.2`（`apk add curl jq python3`） | 同上 + 无 jq 时的 python3 回退 |
| SHA-256 校验 | `bash tests/checksum.sh install.sh` | 4 项 |
| 系统识别 | `bash tests/smoke.sh install.sh` | 见 README |

另外已在带真实 systemd 的 Debian 12 容器中验证：从 GitHub 实际下载 v0.4.0 并校验 → 向导对接模拟 Xboard → 在加固后的 unit 下 xray / sing / hysteria2 三种内核均正常启动、监听面板下发的端口；错误版本号不会破坏现有安装；端口放行幂等且不改变防火墙默认策略。

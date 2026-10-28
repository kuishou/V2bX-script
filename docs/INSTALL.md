# V2bX 节点一键安装教程（新手版）

本教程介绍如何用本仓库的优化版 `install.sh` 在一台 Linux VPS 上安装 [V2bX](https://github.com/liusu2100-sys/V2bX) 节点后端，并对接 Xboard / V2board 面板。

> **说明**
>
> - 本项目已完全自托管：安装脚本 `install.sh`、管理命令 `V2bX`（`V2bX.sh`）和配置生成向导（`initconfig.sh`）都来自本仓库 [liusu2100-sys/V2bX-script](https://github.com/liusu2100-sys/V2bX-script)；V2bX 程序从自己的分支 [liusu2100-sys/V2bX 的 Releases](https://github.com/liusu2100-sys/V2bX/releases) 下载。安装过程不再访问任何第三方地址，也没有统计上报。维护方法见 [MAINTAIN.md](MAINTAIN.md)。
> - 参考资料（原作者的第三方文档站，仅供查阅，安装不依赖它）：<https://v2bx.v-50.me/>，配置文件详解见 [配置文件说明](https://v2bx.v-50.me/v2bx/v2bx-pei-zhi-wen-jian-shuo-ming/config)、证书见 [自动申请证书说明](https://v2bx.v-50.me/v2bx/gong-neng-shuo-ming/cert)。
> - 文中所有 **`https://你的面板域名`、`你的通讯密钥`、`node.example.com`、节点 ID `1`** 等都是 **示例占位符**，请替换成你自己的真实信息。

## 目录

1. [准备工作](#1-准备工作)
2. [各系统前置步骤](#2-各系统前置步骤)
3. [一键安装](#3-一键安装)
4. [安装过程中的交互说明](#4-安装过程中的交互说明)
5. [配置文件 /etc/V2bX/config.json](#5-配置文件-etcv2bxconfigjson)
6. [管理命令](#6-管理命令)
7. [验证是否安装成功](#7-验证是否安装成功)
8. [常见问题排查](#8-常见问题排查)
9. [更新与卸载](#9-更新与卸载)

---

## 1. 准备工作

### 1.1 服务器（VPS）要求

| 项目 | 要求 |
| --- | --- |
| 系统 | CentOS / RHEL / Rocky / AlmaLinux / Oracle Linux 7+、Fedora、Ubuntu 16.04+、Debian 8+、Alpine Linux、Arch Linux（详见 [README](../README.md#支持的系统)） |
| 架构 | **64 位**：`x86_64/amd64`、`aarch64/arm64`、`s390x`。**不支持 32 位系统** |
| 网络 | 有 **公网 IP**，并且服务器能访问 GitHub（`api.github.com`、`github.com`、`raw.githubusercontent.com`） |
| 权限 | 必须使用 **root 用户** 运行（非 root 会提示「必须使用root用户运行此脚本」并退出） |
| 端口 | 节点端口（在面板里设置的端口）需要在 **系统防火墙** 和 **云服务商安全组** 中放行；Hysteria / Hysteria2 / TUIC 等基于 UDP 的协议需要放行 **UDP**；使用 `http` 模式自动申请证书时还需要放行 **80/TCP** |
| 域名/证书 | 仅在节点需要 TLS（如 Trojan、开启 TLS 的 VLESS/VMess、Hysteria2、TUIC、AnyTLS）时需要：准备一个已解析到本机 IP 的域名（如 `node.example.com`），或者已有的证书文件 |

> CentOS 7 **无法使用 hysteria1/2 协议**（安装脚本会给出相同提示）。

查看系统架构与版本：

```bash
uname -m                 # x86_64 / aarch64 / s390x 均可
cat /etc/os-release      # 查看发行版与版本号
```

切换到 root：

```bash
sudo -i
```

### 1.2 面板端（Xboard / V2board）准备

在安装节点之前，先在面板后台准备好以下 4 项信息，安装时要用到：

| 配置项（config.json） | 含义 | 在面板中哪里找 |
| --- | --- | --- |
| `ApiHost` | 面板地址，例如 `https://你的面板域名` | 你访问面板的网址（协议 + 域名，**末尾不要带 `/` 或其他路径**） |
| `ApiKey` | 面板的 **通讯密钥** | 面板后台「系统配置」中服务端/节点相关设置里的 **通讯密钥**（Xboard 中对应设置项 `server_token`，要求至少 16 位） |
| `NodeID` | 节点 ID（纯数字） | 在面板「节点管理」中 **新建节点** 后，节点列表里显示的 ID |
| `NodeType` | 节点协议类型 | 新建节点时选择的协议，对应关系见下表 |

`NodeType` 可填写的值（来自 V2bX 源码，大小写不敏感）：

| 面板中的节点协议 | `NodeType` |
| --- | --- |
| Shadowsocks | `shadowsocks` |
| VMess（V2ray） | `vmess`（写 `v2ray` 也会被当成 `vmess`） |
| VLESS | `vless` |
| Trojan | `trojan` |
| Hysteria（v1） | `hysteria` |
| Hysteria2 | `hysteria2` |
| TUIC | `tuic` |
| AnyTLS | `anytls` |

操作步骤（概括）：

1. 登录面板后台 → 系统配置，设置/复制 **通讯密钥**。
2. 面板后台 → 节点管理 → 新建节点：选择协议，填写节点地址（你的 VPS IP 或域名）、端口等，保存。
3. 记下该节点的 **节点 ID** 和 **协议类型**。

> 节点的端口、传输方式、TLS 等参数都在 **面板** 中设置，V2bX 启动后会自动从面板拉取，无需在本机重复填写端口。

---

## 2. 各系统前置步骤

一键安装命令需要 `bash` 和 `curl`（或 `wget`）。其余依赖（`wget curl unzip tar socat ca-certificates` 以及 cron 等）会由安装脚本自动安装。

### 2.1 Alpine Linux（必须先装 bash）

Alpine 默认没有 bash，而安装脚本和管理脚本都依赖 bash：

```bash
apk update
apk add bash curl
```

> Alpine 使用 **OpenRC** 管理服务（不是 systemd），对应命令见 [第 6 节](#6-管理命令)。

### 2.2 Debian / Ubuntu 最小化系统（没有 curl / wget）

```bash
apt-get update
apt-get install -y curl wget ca-certificates
```

### 2.3 CentOS / RHEL 系 / Fedora

```bash
yum install -y curl wget      # CentOS 7
dnf install -y curl wget      # CentOS 8+/Rocky/Alma/Fedora
```

### 2.4 Arch Linux

```bash
pacman -Sy --noconfirm --needed curl wget
```

### 2.5 已停止维护（EOL）的系统：切换到归档软件源

CentOS 7/8、Debian 8/9 的官方软件源已经下线，`yum` / `apt-get` 会报 404 或找不到软件源。安装脚本 **只会给出提示，不会修改你的软件源**。如果依赖安装失败，请先按下面的方法切换到官方归档源再重新运行安装命令。

> 修改前建议先备份：`cp -a /etc/yum.repos.d /etc/yum.repos.d.bak` 或 `cp /etc/apt/sources.list /etc/apt/sources.list.bak`。

#### CentOS 7 → vault.centos.org

```bash
sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
       -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
       /etc/yum.repos.d/CentOS-*.repo
yum clean all && yum makecache
```

如果之后 EPEL 源报错（安装脚本会在 RHEL 系上顺带安装 `epel-release`），可以把 EPEL 7 指向 Fedora 的归档地址：

```bash
sed -i -e 's|^metalink=|#metalink=|g' \
       -e 's|^#baseurl=http://download.example/pub/epel/7|baseurl=https://archives.fedoraproject.org/pub/archive/epel/7|g' \
       /etc/yum.repos.d/epel.repo
yum clean all && yum makecache
```

#### CentOS 8 → vault.centos.org

```bash
sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
       -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
       /etc/yum.repos.d/CentOS-*.repo
dnf clean all && dnf makecache
```

（CentOS 8 的源文件名为 `CentOS-Linux-*.repo`，上面的通配符 `CentOS-*.repo` 已经包含。）

#### Debian 8 (jessie) → archive.debian.org

```bash
cat > /etc/apt/sources.list <<'SRC'
deb http://archive.debian.org/debian jessie main contrib non-free
deb http://archive.debian.org/debian-security jessie/updates main contrib non-free
SRC
apt-get -o Acquire::Check-Valid-Until=false update
```

#### Debian 9 (stretch) → archive.debian.org

```bash
cat > /etc/apt/sources.list <<'SRC'
deb http://archive.debian.org/debian stretch main contrib non-free
deb http://archive.debian.org/debian-security stretch/updates main contrib non-free
SRC
apt-get -o Acquire::Check-Valid-Until=false update
```

> 归档源中 **没有** `jessie-updates` / `stretch-updates`，如果 `sources.list` 或 `/etc/apt/sources.list.d/` 里还有这些行，请删除或注释掉。
> 使用 `http://` 而不是 `https://`，因为老系统的 apt 可能不支持 https 源。

---

## 3. 一键安装

以 **root** 身份执行以下任意一种方式。

### 方式一：curl（推荐）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh)
```

### 方式二：wget

```bash
wget -N https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh && bash install.sh
```

（安装结束时脚本会自动删除当前目录下的 `install.sh`。）

### 安装指定版本

在命令末尾加上 V2bX 的版本号（即 [Releases](https://github.com/liusu2100-sys/V2bX/releases) 页面中的 tag，例如 `v0.4.0`）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh) v0.4.0
```

不带版本号时，脚本会通过 GitHub API 查询并安装最新版本。

### 安装脚本做了什么

1. 检查 root 权限，识别系统、架构（不支持 32 位）、版本（如 CentOS ≤ 6、Ubuntu < 16、Debian < 8 会拒绝安装）。
2. 选择包管理器（yum/dnf、apt-get、apk、pacman）和服务管理方式（systemd 或 OpenRC）。
3. 安装依赖：`wget curl unzip tar socat ca-certificates` + cron（RHEL 系另装 `epel-release`、`crontabs cronie`；Arch 装 `cronie`；Alpine 另装 `bash`）。
4. 下载 `V2bX-linux-<架构>.zip`，解压到 **`/usr/local/V2bX/`**（注意：该目录会被 **整个删除后重建**）。
5. 创建配置目录 **`/etc/V2bX/`**，复制 `geoip.dat`、`geosite.dat`；若 `config.json`、`dns.json`、`route.json`、`custom_outbound.json`、`custom_inbound.json` 不存在则复制默认文件（**已有的配置不会被覆盖**）。
6. 创建服务并设置开机自启：
   - systemd：`/etc/systemd/system/V2bX.service`
   - OpenRC（Alpine）：`/etc/init.d/V2bX`
7. 下载管理脚本到 `/usr/bin/V2bX`，并创建软链接 `/usr/bin/v2bx`。
8. **首次安装**（之前没有 `/etc/V2bX/config.json`）：**不会自动启动** V2bX，而是询问是否运行配置生成向导；
   **重新安装/更新**（已有 `config.json`）：自动启动服务并显示「V2bX 重启成功」或「V2bX 可能启动失败…」。

---

## 4. 安装过程中的交互说明

首次安装完成后，屏幕会打印管理命令的用法，然后出现：

```text
检测到你为第一次安装V2bX,是否立即生成对接 Xboard 的配置文件？(y/n):
```

- 输入 **`n`**：安装结束。此时 `/etc/V2bX/config.json` 只是一个 **示例配置**（`ApiHost` 为 `http://127.0.0.1`、`ApiKey` 为 `test`），服务没有启动。请按 [第 5 节](#5-配置文件-etcv2bxconfigjson) 手动修改后执行 `V2bX start`，或之后随时运行 `V2bX generate` 进入向导。
- 输入 **`y`**：进入配置生成向导（与 `V2bX generate` 相同）。**每添加一个节点，向导都会实时请求 Xboard 校验面板地址、通讯密钥、节点 ID 和协议**，并根据面板下发的配置自动判断是否需要证书：

| 步骤 | 提示文字 | 怎么填 |
| --- | --- | --- |
| 1 | `确定继续? [Y/n]` | 回车继续。旧配置会备份为 `config.json.bak.<时间>`（保留最近 5 份） |
| 2 | `请输入 Xboard 面板地址` | 面板根地址，如 `https://xboard.example.com`。**必须是 https://**（本机 `http://127.0.0.1` 除外），结尾的 `/` 会自动去掉 |
| 3 | `请输入通讯密钥（输入不回显）` | Xboard「系统配置 → 服务端 → 通讯密钥」（≥16 位） |
| 4 | `后续节点是否使用相同的面板地址和通讯密钥?` | 一般回车（是） |
| 5 | `请选择节点核心类型：1. xray 2. singbox 3. hysteria2` | Hysteria/TUIC/AnyTLS 只能用 **singbox**；选 **hysteria2** 内核时协议自动为 Hysteria2 |
| 6 | `请输入 Xboard 节点 ID` | 面板「节点管理」中的节点 ID |
| 7 | `请选择节点协议` | 必须与面板中节点协议一致。Xboard 的 Hysteria 节点：版本 1 选 Hysteria，版本 2 选 Hysteria2 |
| 8 | `正在检测 Xboard 对接…` | 自动完成。失败时会说明原因（密钥错误 / 节点不存在或协议不符 / 404 地址错误 / 被 CDN 拦截等），可选择仍然继续 |
| 9 | `请选择证书模式` | 仅需要证书时出现（Trojan/VMess/VLESS 开启 TLS、Hysteria/TUIC/AnyTLS）；Reality 与 Shadowsocks 自动跳过。证书域名默认取面板中的 `server_name` |
| 10 | `是否继续添加节点?` | 一个 V2bX 可以同时对接多个节点 |
| 11 | `是否额外启用原版域名审计列表?` | 默认否，见下方说明 |

证书模式说明：

- **1. http**：自动申请，要求域名已解析到本机且 **80 端口可用**。
- **2. dns**（推荐）：通过 DNS 服务商 API 自动申请，向导会直接询问凭据。Cloudflare 请使用仅有 `Zone.DNS` 编辑权限的 **API Token**（`CF_DNS_API_TOKEN`），不要用 Global API Key；其它服务商按 [lego 文档](https://go-acme.github.io/lego/dns/) 输入变量名和值。
- **3. file**：使用已有的证书文件（默认 `/etc/V2bX/fullchain.cer`、`/etc/V2bX/cert.key`）。
- **4. self**：自动生成自签名证书，客户端需允许不安全证书，不推荐。

向导完成后会生成：`/etc/V2bX/config.json`、`custom_outbound.json`、`route.json`、`sing_origin.json`、`hy2config.yaml`（均为 600 权限，目录 700），并自动 **重启 V2bX**。之后可随时用 `V2bX check` 再次检测所有节点的对接状态。

> 本地审计规则默认只阻断 **内网 / 回环地址**（防止用户借节点访问服务器内网或云厂商元数据接口 169.254.169.254）和 **BT 下载**。原版那份大而全的域名屏蔽列表（会屏蔽 gov / bank / taobao / 360 等）改为可选；更推荐在 Xboard「路由管理」中按节点统一下发审计规则。

---

## 5. 配置文件 /etc/V2bX/config.json

配置文件为 JSON 格式，结构为：

- `Log`：V2bX 自身日志。
- `Cores`：要启用的内核（`xray` / `sing` / `hysteria2`），可以有多个。
- `Nodes`：要对接的节点，可以有多个（多个面板、多个节点）。

修改配置后需重启：`V2bX restart`（或用 `V2bX config` 用 vi 编辑，退出后会自动重启）。V2bX 默认也会监视配置文件变化。

### 5.1 示例：xray 内核 + 一个 VLESS 节点

下面的内容与配置向导选择「xray」生成的结构一致（**所有值都是示例**）：

```json
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": [
        {
            "Type": "xray",
            "Log": {
                "Level": "error",
                "ErrorPath": "/etc/V2bX/error.log"
            },
            "OutboundConfigPath": "/etc/V2bX/custom_outbound.json",
            "RouteConfigPath": "/etc/V2bX/route.json"
        }
    ],
    "Nodes": [
        {
            "Core": "xray",
            "ApiHost": "https://你的面板域名",
            "ApiKey": "你的通讯密钥",
            "NodeID": 1,
            "NodeType": "vless",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "none",
                "RejectUnknownSni": false,
                "CertDomain": "node.example.com",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        }
    ]
}
```

> `custom_outbound.json` 和 `route.json` 在安装时已复制到 `/etc/V2bX/`，所以这个 xray 示例可以直接使用。

### 5.2 示例：sing 内核（singbox）节点

使用 sing 内核时，`Cores` 和节点部分改为：

```json
    "Cores": [
        {
            "Type": "sing",
            "Log": {
                "Level": "error",
                "Timestamp": true
            },
            "NTP": {
                "Enable": false,
                "Server": "time.apple.com",
                "ServerPort": 0
            },
            "OriginalPath": "/etc/V2bX/sing_origin.json"
        }
    ],
    "Nodes": [
        {
            "Core": "sing",
            "ApiHost": "https://你的面板域名",
            "ApiKey": "你的通讯密钥",
            "NodeID": 2,
            "NodeType": "hysteria2",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            "EnableTFO": false,
            "CertConfig": {
                "CertMode": "http",
                "RejectUnknownSni": false,
                "CertDomain": "node.example.com",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        }
    ]
```

> **注意**：`OriginalPath` 指向的 `/etc/V2bX/sing_origin.json` **只有运行过配置向导（`V2bX generate`）才会生成**，单纯安装不会创建。如果手动编写 sing 配置而文件不存在，V2bX 会报 `read original config error`。解决：运行一次 `V2bX generate`，或者删除 `OriginalPath` 这一行，或者自己创建该文件（格式见 [Singbox内核自定义配置说明](https://v2bx.v-50.me/v2bx/gong-neng-shuo-ming/singbox-nei-he-zi-ding-yi-pei-zhi-shuo-ming)）。安装时自带的示例 `config.json` 就是 sing 内核并引用了这个文件。

多个节点：在 `Nodes` 数组里复制一份节点对象（用逗号分隔），改成另一个 `NodeID` / `NodeType` 即可；如果用到了不同内核，`Cores` 里也要加上对应内核。

### 5.3 证书配置 CertConfig

| 字段 | 说明 |
| --- | --- |
| `CertMode` | `none`：不使用 TLS（Shadowsocks、Reality 节点用这个）；`http`：通过 HTTP 自动申请，需要 **80 端口**；`dns`：通过 DNS 服务商 API 自动申请；`file`：使用 `CertFile`/`KeyFile` 指定的已有证书；`self`：路径下没有文件时自动生成自签名证书 |
| `CertDomain` | 证书域名，应与面板中节点地址/SNI 使用的域名一致，例如 `node.example.com` |
| `CertFile` / `KeyFile` | 证书和私钥路径。`self` 模式下请把你的证书放到这里；自动申请的证书也会保存到这里 |
| `Email` | 申请证书时使用的邮箱 |
| `Provider` | `dns` 模式的 DNS 服务商，名称见 <https://go-acme.github.io/lego/dns/>（如 `cloudflare`） |
| `DNSEnv` | `dns` 模式需要的环境变量（向导生成的 `"EnvName": "env1"` 只是占位，**必须替换**） |
| `RejectUnknownSni` | 仅 xray 内核：SNI 与证书域名不匹配时拒绝握手，默认 `false` |

`dns` 模式示例（Cloudflare，令牌为示例）：

```json
"CertConfig": {
    "CertMode": "dns",
    "RejectUnknownSni": false,
    "CertDomain": "node.example.com",
    "CertFile": "/etc/V2bX/fullchain.cer",
    "KeyFile": "/etc/V2bX/cert.key",
    "Email": "you@example.com",
    "Provider": "cloudflare",
    "DNSEnv": {
        "CF_DNS_API_TOKEN": "你的Cloudflare API令牌"
    }
}
```

`self` 模式：把证书文件上传后放到对应位置，例如：

```bash
cp 你的证书.pem /etc/V2bX/fullchain.cer
cp 你的私钥.key /etc/V2bX/cert.key
V2bX restart
```

### 5.4 config.json 与面板字段对照

| config.json | 面板中的位置 / 含义 |
| --- | --- |
| `ApiHost` | 面板访问地址（如 `https://你的面板域名`）。V2bX 会请求 `ApiHost` + `/api/v1/server/UniProxy/...` |
| `ApiKey` | 系统配置中的 **通讯密钥** |
| `NodeID` | 节点管理中该节点的 **ID** |
| `NodeType` | 节点的 **协议类型**（见 [1.2](#12-面板端xboard--v2board准备) 对照表） |
| `Core` | 本机使用哪个内核运行该节点（`xray` / `sing` / `hysteria2`），必须在 `Cores` 中启用 |
| `CertConfig` | 节点开启 TLS 时本机如何获取证书；端口、传输协议等其余参数由面板下发 |

---

## 6. 管理命令

安装后可以用 `V2bX`（或小写 `v2bx`）管理，以下内容来自本仓库的管理脚本 `V2bX.sh`。

### 6.1 交互菜单

直接输入：

```bash
V2bX
```

会显示菜单（输入数字选择）：

| 编号 | 功能 |
| --- | --- |
| 0 | 修改配置（用 vi 打开 `/etc/V2bX/config.json`，保存退出后自动重启） |
| 1 | 安装 V2bX |
| 2 | 更新 V2bX |
| 3 | 卸载 V2bX |
| 4 / 5 / 6 | 启动 / 停止 / 重启 V2bX |
| 7 | 查看 V2bX 状态 |
| 8 | 查看 V2bX 日志 |
| 9 / 10 | 设置 / 取消 开机自启 |
| 11 | 一键安装 bbr（最新内核，调用第三方脚本 ylx2016 tcpx.sh；已固定版本并校验 SHA-256，运行前需确认；⚠️ 会更换内核，请先快照/备份） |
| 12 | 查看 V2bX 版本 |
| 13 | 生成 X25519 密钥（Reality 节点用） |
| 14 | 升级 V2bX 维护脚本（重新下载 `/usr/bin/V2bX`） |
| 15 | 生成 V2bX 配置文件（配置向导） |
| 16 | 放行指定端口（TCP+UDP，自动识别 ufw / firewalld / iptables，只添加规则，不关闭防火墙） |
| 17 | 检测 Xboard 对接（逐个请求 config.json 中节点的 UniProxy 接口） |
| 18 | 退出脚本 |

### 6.2 子命令

```text
V2bX              - 显示管理菜单 (功能更多)
V2bX start        - 启动 V2bX
V2bX stop         - 停止 V2bX
V2bX restart      - 重启 V2bX
V2bX status       - 查看 V2bX 状态
V2bX enable       - 设置 V2bX 开机自启
V2bX disable      - 取消 V2bX 开机自启
V2bX log          - 查看 V2bX 日志
V2bX x25519       - 生成 x25519 密钥
V2bX generate     - 生成 V2bX 配置文件（对接 Xboard）
V2bX check        - 检测与 Xboard 的对接
V2bX open_ports   - 放行指定端口
V2bX update       - 更新 V2bX
V2bX update x.x.x - 安装 V2bX 指定版本
V2bX install      - 安装 V2bX
V2bX uninstall    - 卸载 V2bX
V2bX version      - 查看 V2bX 版本
```

另外还有 `V2bX config`（编辑配置并自动重启）和 `V2bX update_shell`（升级管理脚本）。

### 6.3 等价的系统命令

| 操作 | systemd（CentOS/Ubuntu/Debian/Arch 等） | OpenRC（Alpine） |
| --- | --- | --- |
| 启动 | `systemctl start V2bX` | `rc-service V2bX start` |
| 停止 | `systemctl stop V2bX` | `rc-service V2bX stop` |
| 重启 | `systemctl restart V2bX` | `rc-service V2bX restart` |
| 状态 | `systemctl status V2bX --no-pager -l` | `rc-service V2bX status` |
| 开机自启 | `systemctl enable V2bX` | `rc-update add V2bX default` |
| 取消自启 | `systemctl disable V2bX` | `rc-update del V2bX` |
| 日志 | `journalctl -u V2bX.service -e --no-pager -f` | 见下方说明 |

> **Alpine 查看日志**：管理脚本在 Alpine 上执行 `V2bX log` 会提示「alpine系统暂不支持日志查看」。排错时可以先停止服务，再在前台运行 V2bX 直接看输出（`Ctrl+C` 结束后记得重新启动服务）：
>
> ```bash
> rc-service V2bX stop
> /usr/local/V2bX/V2bX server -c /etc/V2bX/config.json
> rc-service V2bX start
> ```
>
> 这个前台运行方法在 systemd 系统上同样适用（把 `rc-service` 换成 `systemctl`）。

---

## 7. 验证是否安装成功

1. **看服务状态**

   ```bash
   V2bX status
   ```

   systemd 系统中看到 `Active: active (running)` 即为运行中；直接执行 `V2bX`（打开菜单）时，菜单底部会显示 `V2bX状态: 已运行` 和 `是否开机自启: 是`。

2. **看日志**

   ```bash
   V2bX log
   ```

   （等同 `journalctl -u V2bX.service -e --no-pager -f`，按 `Ctrl+C` 退出。）没有持续出现报错，即说明已成功从面板获取节点信息。

3. **看端口是否在监听**（把 `443` 换成面板中设置的节点端口）

   ```bash
   ss -lntup | grep 443
   ```

4. **看面板**：回到面板「节点管理」，该节点状态应变为 **在线**。节点与面板是定时同步的（Xboard 默认拉取/推送间隔为 60 秒），请稍等 1～2 分钟再刷新。

5. **查看版本**

   ```bash
   V2bX version
   ```

---

## 8. 常见问题排查

### 8.1 下载失败 / 无法访问 GitHub

- 提示 **「检测 V2bX 版本失败，可能是超出 Github API 限制…」**：GitHub API 有访问频率限制，可以稍后重试，或 **直接指定版本号** 安装以跳过 API 查询：

  ```bash
  bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh) v0.4.0
  ```

- 提示 **「下载 V2bX 失败，请确保你的服务器能够下载 Github 的文件」** 或 **「下载 V2bX vX.X.X 失败，请确保此版本存在」**：检查版本号是否存在于 [Releases](https://github.com/liusu2100-sys/V2bX/releases)（需要带 `v` 前缀），并测试网络：

  ```bash
  curl -I https://github.com
  curl -I https://raw.githubusercontent.com
  curl -s https://api.github.com/repos/liusu2100-sys/V2bX/releases/latest | grep tag_name
  ```

- 一键命令运行后 **什么都没发生 / 报语法错误**：通常是 `raw.githubusercontent.com` 无法访问，下载到的内容为空或是错误页。可先用 `curl -I` 测试，或检查服务器 DNS（`cat /etc/resolv.conf`）。
- 安装后 `V2bX` 命令不存在：管理脚本下载失败。可单独重新下载：

  ```bash
  curl -fLs -o /usr/bin/V2bX https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/V2bX.sh
  chmod +x /usr/bin/V2bX
  ```

### 8.1.1 「TLS 证书校验失败」/「SHA-256 校验失败」

- **TLS 证书校验失败**：通常是系统 CA 证书过旧或系统时间不对。先更新证书并同步时间（如 `apt-get install -y ca-certificates` / `yum install -y ca-certificates`，见 [8.6](#86-时间不同步)），再重新运行。脚本默认**不会**自动跳过证书校验；确认网络可信又必须临时绕过时，可在命令前加 `V2BX_INSECURE=1`（不推荐）。
- **SHA-256 校验失败，已中止安装**：下载的程序包与 Release 中 `.dgst` 记录的哈希不一致（下载不完整或被篡改）。脚本已自动删除该文件，请稍后重试或换网络；不要手动绕过。

### 8.2 依赖安装失败 / 软件源报错

- 提示 **「软件源更新失败，请检查软件源配置（EOL 系统请切换至归档源）」** 或 **「以下依赖未能安装: …」**：按 [2.5 节](#25-已停止维护eol的系统切换到归档软件源) 切换归档源，然后手动安装缺失的软件，再重新运行安装命令。
- 提示 **「未找到可用的包管理器…」**：请手动安装 `wget curl unzip tar socat ca-certificates`。
- 提示 **「未检测到系统版本，请联系脚本作者！」**：系统不在支持列表内。

### 8.3 端口不通 / 客户端连不上

1. 确认 V2bX 在运行、端口在监听（见 [第 7 节](#7-验证是否安装成功)）。
2. **云服务商安全组** 放行节点端口（TCP；Hysteria/Hysteria2/TUIC 还需 UDP）。
3. 放行系统防火墙（以 443 为例，请换成你的端口）：

   ```bash
   # firewalld（CentOS/RHEL/Rocky/Alma）
   firewall-cmd --permanent --add-port=443/tcp
   firewall-cmd --permanent --add-port=443/udp
   firewall-cmd --reload

   # ufw（Ubuntu/Debian）
   ufw allow 443/tcp
   ufw allow 443/udp
   ```

4. 面板中节点的 **地址**（IP/域名）和 **端口** 要正确，客户端需要重新更新订阅。

### 8.4 证书错误

- **http 模式** 申请失败：域名是否已解析到本机公网 IP（`ping node.example.com`）；**80 端口** 是否被 Nginx/Apache 等占用（`ss -lntp | grep ':80 '`）且防火墙/安全组已放行。
- **dns 模式**：`Provider` 和 `DNSEnv` 是否已按 <https://go-acme.github.io/lego/dns/> 填写正确（旧版向导生成的 `"EnvName": "env1"` 只是占位，需要改成真实变量）。
- **file 模式**：`CertFile` / `KeyFile` 路径下是否有正确的证书和私钥；证书域名需与 `CertDomain` 及客户端 SNI 一致。
- **证书放在 /etc/V2bX 以外的目录、且使用 http/dns 自动申请**：systemd 沙箱只允许 V2bX 写 `/etc/V2bX` 和 `/usr/local/V2bX`，请把 `CertFile`/`KeyFile` 放到 `/etc/V2bX` 下，或执行 `systemctl edit V2bX` 追加 `ReadWritePaths=你的目录`。
- 配置是否用错：Shadowsocks 和 VLESS Reality 节点应使用 `"CertMode": "none"`。

### 8.5 节点不在线 / 日志中报 API 错误

最常见的原因是 `ApiHost`、`ApiKey`、`NodeID`、`NodeType` 与面板不一致：

- `ApiHost`：必须带 `http://` 或 `https://`，**末尾不要带 `/`**，且服务器能访问面板域名。
- `ApiKey`：必须与面板「通讯密钥」**完全一致**（注意多余的空格）。
- `NodeID`：是面板节点列表中的 ID，**纯数字，不加引号**。
- `NodeType`：必须与面板中该节点的协议一致，例如面板建的是 Trojan 节点，这里就必须是 `trojan`。

最简单的办法是运行 **`V2bX check`**：它会逐个请求 config.json 中各节点的 Xboard 接口（通讯密钥不会出现在命令行和输出里），并给出具体原因：

| 提示 | 原因 |
| --- | --- |
| 通讯密钥错误 | `ApiKey` 与 Xboard「通讯密钥」不一致 |
| 节点不存在 | `NodeID` 不存在，或 `NodeType` 与面板协议不符（Hysteria2 在 Xboard 中是「Hysteria 节点 + 版本 2」） |
| 接口不存在 (404) | `ApiHost` 不是 Xboard 站点根地址 |
| 请求被拒绝 (403/503)、或返回 200 但不是节点配置 | 被 Cloudflare / WAF 拦截：为节点 IP 放行，或让 `ApiHost` 直连源站 |

`V2bX check` 需要 `jq` 或 `python3` 解析配置。

- 手写 sing 配置后启动失败并提示 `read original config error`：见 [5.2](#52-示例sing-内核singbox节点) 的注意事项。
- 修改配置后忘了重启：执行 `V2bX restart`。
- 配置 JSON 格式错误（少逗号、多逗号、中文引号）：如系统装有 python3，可用 `python3 -m json.tool /etc/V2bX/config.json` 检查语法。

### 8.6 时间不同步

服务器时间偏差过大会导致 VMess 等协议连接失败、证书申请异常。检查并同步时间：

```bash
date                               # 查看当前时间
timedatectl set-ntp true           # systemd 系统开启自动校时
/usr/local/V2bX/V2bX synctime      # 使用 V2bX 自带命令从 NTP 服务器同步（默认 time.apple.com）
```

（`synctime` 是 V2bX 程序本身的子命令，需要用完整路径 `/usr/local/V2bX/V2bX` 调用，不能用管理脚本 `V2bX`。）上游文档建议使用 VMess 时可开启 sing 内核配置中的 `NTP.Enable`。

---

## 9. 更新与卸载

### 9.1 更新

**方法一**：重新运行一键命令即可，已有的 `/etc/V2bX/config.json` 等配置 **不会被覆盖**，安装完成后会自动启动服务：

```bash
# 更新到最新版
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh)

# 更新/回退到指定版本
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh) v0.4.0
```

**方法二（管理脚本自带）**：

```bash
V2bX update            # 交互输入版本，直接回车为最新版
V2bX update v0.4.0     # 指定版本
```

> `V2bX update` / `V2bX install` 下载并运行的就是 **本仓库** 的 `install.sh`（与方法一完全相同），V2bX 程序来自 [liusu2100-sys/V2bX 的 Releases](https://github.com/liusu2100-sys/V2bX/releases)，两种方法效果一致。

更新管理脚本本身（从本仓库重新下载 `V2bX.sh` 到 `/usr/bin/V2bX`）：

```bash
V2bX update_shell
```

> 旧版本管理脚本：如果服务器上的 `/usr/bin/V2bX` 是以前从原作者仓库安装的，它的 `update` / `update_shell` 仍指向原作者仓库。先执行一次上面「8.1」中的重新下载命令（或重新运行一键安装命令），之后就会全部使用本仓库。

### 9.2 卸载

```bash
V2bX uninstall
```

确认后会：停止服务、取消开机自启、删除服务文件（systemd：`/etc/systemd/system/V2bX.service`；Alpine：`/etc/init.d/V2bX`），并删除 **`/etc/V2bX/`（包括你的配置和证书）** 和 **`/usr/local/V2bX/`**。如需保留配置，请先备份：

```bash
cp -a /etc/V2bX /root/V2bX-config-backup
```

卸载后管理脚本仍保留，如需删除：

```bash
rm -f /usr/bin/V2bX /usr/bin/v2bx
```

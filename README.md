# V2bX 一键安装脚本（自托管 · 兼容性优化版）

> 🔐 **对接 Xboard 的审计结论与安全部署方案：[docs/XBOARD.md](docs/XBOARD.md)**
>
> 📖 **新手请先看：[详细安装教程（docs/INSTALL.md）](docs/INSTALL.md)** —— 包含面板准备、各系统前置步骤、安装交互说明、配置文件示例、管理命令与常见问题排查。

本项目源自 [wyx2685/V2bX-script](https://github.com/wyx2685/V2bX-script)（感谢原作者），现已**完全自托管、由本人维护**：

- 安装脚本 `install.sh`、管理脚本 `V2bX.sh`、配置向导 `initconfig.sh` 都在本仓库 [liusu2100-sys/V2bX-script](https://github.com/liusu2100-sys/V2bX-script)；
- V2bX 程序从自己的分支 [liusu2100-sys/V2bX](https://github.com/liusu2100-sys/V2bX) 的 [Releases](https://github.com/liusu2100-sys/V2bX/releases) 下载（由该仓库的 GitHub Actions 构建）；
- `V2bX install` / `V2bX update` / `V2bX update_shell` 也全部使用以上两个仓库；
- 已移除第三方统计上报；下载始终校验 TLS 证书；V2bX 程序包解压前校验 SHA-256；第三方 BBR 脚本固定版本并校验。详见 [docs/MAINTAIN.md 第 5 节「安全说明 / 外部依赖」](docs/MAINTAIN.md#5-安全说明--外部依赖)。

安装路径、systemd / OpenRC 服务文件、提示文字与颜色、版本参数均与原版一致，并改进了系统识别、版本判断、包管理器选择和依赖安装的兼容性与健壮性。

> 维护者请看：[docs/MAINTAIN.md](docs/MAINTAIN.md)（发布新版本、同步上游、修改仓库地址、剩余外部依赖）。

## 快速开始

1. 在面板（Xboard / V2board）后台新建节点，记下 **面板地址**、**通讯密钥**、**节点 ID** 和 **节点协议**。
2. 以 root 身份在 VPS 上执行（Alpine 需先 `apk add bash curl`）：

   ```bash
   bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh)
   ```

3. 首次安装时按提示输入 `y` 进入配置生成向导，填写上面的信息；或者输入 `n`，之后手动编辑 `/etc/V2bX/config.json` 再执行 `V2bX start`。
4. 用 `V2bX status` / `V2bX log` 检查运行状态，并在面板中确认节点在线。

详细步骤与排错见 [docs/INSTALL.md](docs/INSTALL.md)。

## 支持的系统

| 系统 | 版本 | 包管理器 | 服务管理 |
| --- | --- | --- | --- |
| CentOS / RHEL / Rocky Linux / AlmaLinux / Oracle Linux | 7 及以上 | yum（7）/ dnf（8+） | systemd |
| Fedora（及 Amazon Linux 等 RHEL 系衍生版） | 当前版本 | dnf / yum | systemd |
| Ubuntu | 16.04 及以上 | apt-get | systemd |
| Debian | 8 及以上 | apt-get | systemd |
| Alpine Linux | 当前版本 | apk | OpenRC |
| Arch Linux（及 Manjaro 等衍生版） | 滚动更新 | pacman | systemd |

架构：`x86_64/amd64`、`aarch64/arm64`、`s390x`（与上游相同，不支持 32 位系统）。

> **Alpine 用户**：脚本本身及安装的管理脚本都需要 bash，请先执行 `apk add bash`。
>
> **CentOS 7 / 8、Debian 8 / 9 等已停止维护（EOL）的系统**：官方软件源可能已下线，脚本只会给出提示、不会修改你的软件源。
> 如依赖安装失败，请自行切换至归档源（如 `vault.centos.org`、`archive.debian.org`）后重试。
> 另外 CentOS 7 无法使用 hysteria1/2 协议（与上游相同）。

## 使用方法

使用 root 用户执行：

```bash
# 安装最新版本
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh)

# 安装指定版本（与上游参数一致）
bash <(curl -Ls https://raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/install.sh) v0.x.x
```

详细说明见 [安装教程](docs/INSTALL.md)。

安装完成后与上游一样使用 `V2bX` / `v2bx` 命令管理：`V2bX start|stop|restart|status|log|update|generate|uninstall ...`

安装位置（与上游一致）：

- 程序：`/usr/local/V2bX/`
- 配置：`/etc/V2bX/`
- 服务：`/etc/systemd/system/V2bX.service`（systemd）或 `/etc/init.d/V2bX`（OpenRC）
- 管理脚本：`/usr/bin/V2bX`（以及软链接 `/usr/bin/v2bx`）

## 相对上游的改动

- **完全自托管**：所有下载地址集中在每个脚本顶部的 “Repository constants” 常量块（`REPO_OWNER`、`SCRIPT_REPO`、`SCRIPT_BRANCH`、`CORE_REPO`），改一处即可；移除 `api.v-50.me` 统计请求；首次安装的教程链接指向本仓库文档。
- **Xboard 对接**：配置向导每添加一个节点都会实时请求 Xboard 校验面板地址 / 通讯密钥 / 节点 ID / 协议，并根据面板下发的 TLS 设置自动决定是否需要证书；新增 `V2bX check` 随时检测所有节点。修复了 sing 节点 `EnableTFO`、`ReportMinTraffic` 等键名错误（原先被静默忽略）；`sing_origin.json` 加入 sniff 动作，使屏蔽 BT 等按协议匹配的规则真正生效（V2bX 的 sing 内核不使用 `EnableSniff`，嗅探只由该文件的路由规则决定）。详见 [docs/XBOARD.md](docs/XBOARD.md)。
- **密钥保护**：`/etc/V2bX` 700、配置文件 600（Xboard 通讯密钥对所有节点通用）；面板地址强制 `https://`；密钥输入不回显、不出现在命令行。
- **安装原子化**：在暂存目录中下载、校验、解压，成功后才替换现有安装；`.dgst` 缺失默认中止。
- **systemd 沙箱**：`NoNewPrivileges`、`ProtectSystem=full`、只允许写 `/etc/V2bX` 与 `/usr/local/V2bX`、收缩能力集（`V2BX_HARDEN=0` 可关闭）。
- **防火墙**：菜单 16 由「关闭防火墙、清空 iptables」改为「放行指定端口」。
- **TLS**：去掉 `--no-check-certificate`，始终校验证书；证书错误时不再自动跳过校验，只有显式设置 `V2BX_INSECURE=1` 才跳过校验重试一次（系统 CA 过旧时使用，不推荐）。
- **完整性校验**：下载 `V2bX-linux-<arch>.zip` 后用同一 Release 的 `.zip.dgst` 校验 SHA-256，不匹配立即中止；菜单 11 的第三方 BBR 脚本固定到指定 commit 并校验 SHA-256，运行前需确认；菜单 16（关闭防火墙）运行前需确认。管理脚本 / 安装脚本先下载到临时文件，下载失败不会覆盖已有的 `/usr/bin/V2bX`。

- **系统识别**：优先读取 `/etc/os-release` 的 `ID` / `ID_LIKE`（不直接 source，避免副作用），识别 centos、rhel、rocky、almalinux、ol、fedora、ubuntu、debian、alpine、arch 及其衍生版；
  缺少 os-release 时依次回退到 `/etc/redhat-release`、`/etc/alpine-release`、`/etc/arch-release`、`/etc/lsb-release`、`/etc/debian_version`，最后才使用上游的 `/etc/issue`、`/proc/version` 规则（容器中 `/proc/version` 反映的是宿主机内核，容易误判）。
- **版本判断**：只取主版本号整数（`16.04`→16、`8.9`→8），兼容缺少 `VERSION_ID` 的系统（Arch 滚动版、Debian testing/sid）；版本限制只作用于对应的原生发行版（如 Fedora、Amazon Linux 不再套用 “CentOS 7+” 规则）；无法识别版本号时给出提示而不是误判退出。
- **包管理器**：RHEL 系优先 dnf、否则 yum；dnf 使用 `--setopt=strict=0`，某个包不存在时不会导致整批依赖安装失败；apt 使用 `apt-get` + `DEBIAN_FRONTEND=noninteractive`（避免交互卡住）；pacman 使用 `--noconfirm --needed`；apt/apk/pacman 批量安装失败时自动逐个重试。
- **依赖修正**：Arch 上的 `cron` 只是虚拟包名（由多个提供者满足），改为明确安装 `cronie`；RHEL 系额外安装 `cronie`；Alpine 额外列出 `bash`；Ubuntu 的两次安装合并为一次；`epel-release` 仅在 RHEL 克隆版上安装（Fedora 上不存在）。
- **安装后检查**：依赖安装后检查 wget / curl / unzip / tar 是否可用，缺失时给出提示。
- **EOL 提示**：CentOS 7/8、Debian 8/9 给出软件源已归档的提示，不修改任何软件源配置。
- **服务管理识别**：根据实际运行的 init 系统（`/run/systemd/system`、`systemctl`、OpenRC）选择 systemd 或 OpenRC，无法判断时回退到上游规则（Alpine 用 OpenRC，其他用 systemd）；在主流系统上结果与上游完全一致。
- **32 位检测**：系统缺少 `getconf` 时不再被误判为 32 位系统而退出。
- **Bug 修复**：
  - 更新安装后的 “V2bX 重启成功 / 可能启动失败” 判断：上游在 `check_status` 与 `$?` 之间插入了 `echo`，导致永远显示成功；现改为 `if check_status; then`。
  - 保持上游 “不带参数即安装最新版” 的语义（不会把空参数当作版本号）。
- **代码结构**：拆分为函数、变量全部加引号，通过 `bash -n` 与 `shellcheck` 检查；兼容 CentOS 7 的 bash 4.2。
  可通过 `V2BX_INSTALL_SOURCE_ONLY=1 source install.sh` 只加载函数用于测试（正常执行时无影响）。

## 仓库结构

| 文件 | 说明 |
| --- | --- |
| `install.sh` | 一键安装 / 更新脚本 |
| `V2bX.sh` | 管理脚本（安装为 `/usr/bin/V2bX`、`/usr/bin/v2bx`） |
| `initconfig.sh` | 配置生成向导与 Xboard 对接检测（安装到 `/usr/local/V2bX/initconfig.sh`，被 `install.sh` 与 `V2bX generate/check` source） |
| `docs/INSTALL.md` | 详细安装教程 |
| `docs/MAINTAIN.md` | 维护说明 |
| `docs/XBOARD.md` | 深度审计结论与 Xboard 安全对接方案 |
| `tests/smoke.sh` | 冒烟测试 |
| `tests/initconfig.sh` + `tests/xboard_mock.py` | 配置向导与 Xboard 对接的离线端到端测试 |

## 测试

`tests/smoke.sh` 只加载脚本函数，测试系统识别、版本检查、包管理器与 init 选择以及依赖安装（不下载 V2bX、不创建服务），例如：

```bash
docker run --rm -v "$PWD":/t:ro centos:7 bash /t/tests/smoke.sh /t/install.sh
docker run --rm -v "$PWD":/t:ro alpine sh -c 'apk add bash && bash /t/tests/smoke.sh /t/install.sh --install-base'
```

# 维护说明（MAINTAIN）

本项目已经完全自托管，由 **liusu2100-sys** 自己维护。涉及两个 GitHub 仓库：

| 仓库 | 作用 | 默认分支 |
| --- | --- | --- |
| [liusu2100-sys/V2bX-script](https://github.com/liusu2100-sys/V2bX-script)（本仓库） | 安装脚本、管理脚本、配置向导、文档 | `main` |
| [liusu2100-sys/V2bX](https://github.com/liusu2100-sys/V2bX) | V2bX 程序源码（fork 自 wyx2685/V2bX），用 GitHub Actions 构建并发布 Release | `dev_new` |

用户服务器上的所有下载都只访问这两个仓库（经由 GitHub）。

---

## 1. 仓库结构

### 本仓库 V2bX-script

```text
install.sh        一键安装/更新脚本（V2bX update / install 也是调用它）
V2bX.sh           管理脚本，安装到 /usr/bin/V2bX（以及软链接 /usr/bin/v2bx）
initconfig.sh     配置生成向导 + Xboard 对接检测（唯一的生成逻辑来源），安装到 /usr/local/V2bX/initconfig.sh，
                  install.sh 首次安装与 V2bX generate / check 都 source 它
docs/XBOARD.md    深度审计结论与 Xboard 安全对接方案
docs/INSTALL.md   安装教程（给用户看）
docs/MAINTAIN.md  本文件（给维护者看）
tests/smoke.sh    冒烟测试（只加载函数，测试系统识别等，不真正安装）
tests/checksum.sh 离线测试 SHA-256 校验（正确 / 篡改 / 两种 .dgst 格式）
tests/initconfig.sh + tests/xboard_mock.py  向导与 Xboard 对接的离线端到端测试
```

脚本之间的调用关系：

```text
用户执行 bash <(curl ... install.sh)
  ├─ GET https://api.github.com/repos/liusu2100-sys/V2bX/releases/latest   → 取最新 tag
  ├─ GET https://github.com/liusu2100-sys/V2bX/releases/download/<tag>/V2bX-linux-<arch>.zip
  │     （zip 内含 V2bX 程序、geoip.dat、geosite.dat、示例 json 配置）
  ├─ GET raw.githubusercontent.com/liusu2100-sys/V2bX-script/main/V2bX.sh      → /usr/bin/V2bX
  └─ GET .../main/initconfig.sh                                                → /usr/local/V2bX/initconfig.sh
  （以上全部先放在 /usr/local/.V2bX-stage.* 暂存目录，校验、解压成功后才替换 /usr/local/V2bX）

V2bX update / V2bX install   → 下载并运行本仓库 main 分支的 install.sh
V2bX update_shell            → 重新下载本仓库 main 分支的 V2bX.sh
```

`<arch>` 只用到三种：`64`（x86_64）、`arm64-v8a`（aarch64）、`s390x`。

### V2bX 仓库（fork）

- `.github/workflows/release.yml`：构建并发布 Release（见第 2 节）。
- `.github/build/friendly-filenames.json`：GOOS/GOARCH → 资产文件名（如 `linux-amd64` → `linux-64`），**不要改名**，否则 install.sh 找不到文件。
- `example/*.json`：会被打包进 zip（`config.json`、`dns.json`、`route.json`、`custom_outbound.json`、`custom_inbound.json`），install.sh 首次安装时复制到 `/etc/V2bX/`。

---

## 2. 发布新的 V2bX 版本

install.sh 永远安装 **GitHub「Latest」Release**（草稿和预发布不算），所以发布流程就是「打 tag → Actions 构建 → 自动变成 Latest」。

```bash
git clone https://github.com/liusu2100-sys/V2bX.git
cd V2bX
git checkout dev_new
# ……修改代码 / 合并上游（见第 3 节）……
git push origin dev_new

git tag v0.4.1            # tag 必须以 v 开头
git push origin v0.4.1
```

推送 tag 后，Actions 里的 **Build and Release** 工作流会：

1. `release`：为该 tag 创建一个 **草稿（draft）** Release（已存在则跳过）；
2. `build`：并行编译所有平台，每个平台上传 `V2bX-<平台>.zip` 和 `V2bX-<平台>.zip.dgst`（md5/sha1/sha256/sha512），文件名与上游完全相同；**install.sh 会用 `.dgst` 里的 SHA-256 校验 zip，所以不要删掉或改变 `.dgst` 的格式**；
3. `publish`：**全部平台编译成功后**才把 Release 发布并标记为 Latest。

在此之前用户安装拿到的仍是上一个版本，不会出现「Release 已有但文件还没传完」的情况。若有平台编译失败，Release 保持草稿，修复后重新推送一个新 tag，或在 Actions 页面手动运行（见下）。

其他操作：

- **重新构建/补传某个已有 tag**：GitHub → V2bX 仓库 → Actions → Build and Release → Run workflow，`tag` 填 `v0.4.1`。会用 `--clobber` 覆盖同名文件。
- **只测试编译、不发布**：Run workflow 时 `tag` 留空；或推送修改了 `*.go` / `go.mod` / `go.sum` 的提交到 `dev_new`（只生成 Actions Artifacts，不动 Release）。
- **让服务器更新**：发布完成后在服务器执行 `V2bX update`（或重新运行一键安装命令）。
- **回退**：`V2bX update v0.4.0`。如果新版本有严重问题，也可以在 GitHub 上把旧版本 Release 重新设为 Latest（编辑 Release → 勾选 *Set as the latest release*），或删除/改为草稿新版本。
- **验证发布结果**：

  ```bash
  curl -s https://api.github.com/repos/liusu2100-sys/V2bX/releases/latest | grep tag_name
  curl -sIL -o /dev/null -w '%{http_code}\n' \
    https://github.com/liusu2100-sys/V2bX/releases/download/v0.4.1/V2bX-linux-64.zip   # 应为 200
  ```

注意：

- 第一次在 fork 上使用 Actions 时，如果 Actions 页面提示 “Workflows aren't being run on this forked repository”，点一下 **I understand my workflows, go ahead and enable them**。
- 用 `git push` 推送 `.github/workflows/` 下的文件时，个人访问令牌（PAT）需要 `workflow` 权限，否则会被 GitHub 拒绝。
- 当前的 `v0.4.0` Release 是 **上游 v0.4.0 的镜像**：文件从 wyx2685/V2bX 的 v0.4.0 原样下载，逐个用上游 `.dgst` 校验 SHA-256 后上传，tag 指向同一个提交 `3deccaa`。以后的版本由本仓库自己构建。

---

## 3. 同步上游（可选）

上游仍在更新时，可以把改动合并进来：

### V2bX 程序

```bash
cd V2bX
git remote add upstream https://github.com/wyx2685/V2bX.git   # 只需一次
git fetch upstream --tags
git checkout dev_new
git merge upstream/dev_new          # 有冲突就解决后 git commit
git push origin dev_new
# 想发布就打 tag（可以沿用上游版本号，例如上游出了 v0.4.2）：
git tag v0.4.2 && git push origin v0.4.2
```

注意：合并时 `.github/workflows/release.yml` 可能冲突，**保留本仓库的版本**（它负责在 tag 推送时发布 Release，上游版本依赖 Release 事件和第三方 Action）。`git fetch upstream --tags` 会拉下上游的 tag，推送时只推你自己要发布的那个 tag，不要 `git push --tags`。

### 管理脚本

```bash
cd V2bX-script
git remote add upstream https://github.com/wyx2685/V2bX-script.git   # 只需一次
git fetch upstream
git diff main upstream/master -- V2bX.sh initconfig.sh install.sh    # 先看上游改了什么
```

不建议直接 merge（本仓库的脚本改动较多）。推荐看完 diff 后，把需要的改动手工搬过来，然后：

- 确认没有引入新的第三方地址：`grep -n 'wyx2685\|http' V2bX.sh initconfig.sh install.sh`
- 确认上游没有重新加入统计请求（例如 `api.v-50.me/counter_v2bx`），也没有重新加入 `--no-check-certificate` / `curl -k` 或 `bash <(curl …)`（新第三方脚本须固定 commit + SHA-256，见第 5 节）
- 跑检查：`bash -n *.sh && shellcheck -S error install.sh V2bX.sh initconfig.sh`

---

## 4. 修改仓库主人 / 地址（改一处即可）

每个脚本顶部都有一个 **Repository constants** 常量块：

```bash
REPO_OWNER="${V2BX_REPO_OWNER:-liusu2100-sys}"
SCRIPT_REPO="${V2BX_SCRIPT_REPO:-${REPO_OWNER}/V2bX-script}"   # 脚本仓库
SCRIPT_BRANCH="${V2BX_SCRIPT_BRANCH:-main}"                    # 脚本分支
CORE_REPO="${V2BX_CORE_REPO:-${REPO_OWNER}/V2bX}"              # 程序仓库（Releases）
```

- 换 GitHub 用户名 / 组织：只改 `REPO_OWNER`。
- 仓库改名或分支改名：改 `SCRIPT_REPO` / `CORE_REPO` / `SCRIPT_BRANCH`。
- 需要改的文件：`install.sh`、`V2bX.sh`、`initconfig.sh`（三个脚本各自独立运行，所以各有一份，**改的时候三个都改成一样**），再把文档里的链接（`README.md`、`docs/INSTALL.md`、本文件）批量替换：

  ```bash
  grep -rl 'liusu2100-sys' README.md docs | xargs sed -i 's#liusu2100-sys#新用户名#g'
  ```

- 临时测试别的仓库（不改文件）：所有常量都可以用 `V2BX_` 前缀的环境变量覆盖，例如

  ```bash
  V2BX_REPO_OWNER=someone bash install.sh
  ```

- `V2bX.sh` 里还有 `BBR_SCRIPT_COMMIT` / `BBR_SCRIPT_SHA256_DEFAULT`（菜单 11，第三方 BBR 脚本，固定版本 + 校验，见第 5 节）。

---

## 5. 安全说明 / 外部依赖

原则：**可以依赖第三方脚本或资源，但必须走 HTTPS、尽量固定版本（commit / digest）并做完整性校验，危险操作前明确提示。**
本节是 2026-10 安全审计的结果，新增依赖时请同步更新此表。

### 5.1 依赖清单

| 依赖 | 用途 | 何时用到 | 风险 | 缓解措施 |
| --- | --- | --- | --- | --- |
| 一键安装入口 `bash <(curl -Ls …/V2bX-script/main/install.sh)` | 安装 | 用户手动执行 | 中（curl\|bash，以 root 运行 `main` 分支最新内容） | 只来自本仓库，HTTPS；信任根是本仓库的写权限（保护好 GitHub 账号 / 开启 2FA）。谨慎用户可先 `curl -o install.sh …` 查看后再 `bash install.sh`。 |
| `raw.githubusercontent.com/…/V2bX-script/main/{V2bX.sh,initconfig.sh,install.sh}` | 管理脚本、配置向导；`V2bX update/install/update_shell` 重新下载 | 安装 / 更新 / 首次生成配置 | 中（跟随 `main` 分支，无单独校验） | 同源于本仓库，HTTPS + 证书校验；先下载到临时文件，失败不覆盖已有文件。 |
| `api.github.com/repos/liusu2100-sys/V2bX/releases/latest` | 获取最新版本号 | 安装 / 更新（未指定版本时） | 低 | HTTPS；只取 tag 名。 |
| `github.com/liusu2100-sys/V2bX/releases/download/<tag>/V2bX-linux-<arch>.zip` + `.zip.dgst` | V2bX 程序 + geoip/geosite + 示例配置 | 安装 / 更新 | 低（已修复） | **解压前用 `.dgst` 中的 SHA-256 校验，不匹配立即中止（fail closed）**；`.dgst` 缺失时默认也中止，设 `V2BX_REQUIRE_CHECKSUM=0` 才放行。校验工具依次尝试 `sha256sum`（coreutils / busybox）、`shasum -a 256`、`openssl dgst -sha256`，都没有则中止。注意 `.dgst` 与 zip 同在一个 Release，只能防传输损坏 / CDN 或镜像篡改，不能防 Release 本身被替换。 |
| TLS 证书 | 所有下载 | 始终 | 低（已修复） | 以前证书错误时会自动 `--no-check-certificate` / `curl -k` 重试（可被中间人利用），**现已改为默认不重试**；只有显式设置 `V2BX_INSECURE=1` 才跳过校验重试一次（zip 仍会做 SHA-256 校验）。 |
| 系统软件源（yum/dnf/apt/apk/pacman）、`epel-release` | 安装 wget curl unzip tar cron socat ca-certificates | 安装 | 低 | 发行版官方源，包有 GPG 签名；EPEL 来自 CentOS extras 源（已签名）。EOL 系统需自行切换归档源。 |
| ylx2016/Linux-NetSpeed `tcpx.sh` | 菜单 11「一键安装 bbr」 | 仅用户选择菜单 11 时 | **高**（第三方 root 脚本，会换内核） | **已固定到 commit `dc2197d4dcb7…` 并校验 SHA-256 `7d0cb5cd…`**，下载到临时文件，显示风险说明，需输入 `y` 确认才运行。自定义 `V2BX_BBR_SCRIPT_URL` 时可配 `V2BX_BBR_SCRIPT_SHA256`，否则提示“未校验”。脚本自身的剩余风险见 5.2。 |
| 菜单 16「放行指定端口」 | 添加 ufw / firewalld / iptables 放行规则 | 仅用户选择菜单 16 时 | 低 | 已替换原先「关闭防火墙、`setenforce 0`、清空 iptables」的实现；只追加 TCP+UDP 规则、幂等、不改默认策略。 |
| Xboard 通讯密钥（`/etc/V2bX/config.json`） | 节点对接 | 始终 | **高**（全局密钥，泄露即可拉取所有用户） | 目录 700 / 文件 600、systemd `UMask=0077`；面板地址强制 HTTPS；对接检测通过 `curl -K -` 传参。面板侧加固见 [XBOARD.md](XBOARD.md) 第 3 节。 |
| systemd 沙箱 | 限制 V2bX 进程 | 始终 | — | `install.sh` 的 `systemd_hardening` 按 systemd 版本生成；`V2BX_HARDEN=0` 关闭。 |
| 证书申请（V2bX 内置 lego → Let's Encrypt / DNS 服务商 API） | 节点 TLS 证书 | `CertMode` 为 `http`/`dns` 时 | 低 | V2bX 程序内部完成，HTTPS；DNS API 密钥保存在 `/etc/V2bX/config.json`（仅 root 可读为宜）。 |
| GitHub Actions：`actions/checkout`、`actions/setup-go`、`actions/upload-artifact`、`actions/download-artifact`、`docker/*-action`、`github/codeql-action` | V2bX 仓库构建 / 发布 / Docker 镜像 / CodeQL | CI | 低（已修复） | **全部固定到完整 commit SHA**（行尾注释写版本）；Docker 工作流 `permissions: contents: read, packages: write`；`steps.meta.outputs.json` 改为通过环境变量传入脚本（避免注入）；CodeQL 从已退役的 v2 升到 v3。 |
| Go 工具链（`actions/setup-go` 下载，自带校验）与 Go 模块（`proxy.golang.org`） | 编译 V2bX | CI 构建时 | 低 | 版本锁定在 `go.mod` / `go.sum`，`go mod download` 会对照 `go.sum` 与 sum.golang.org 校验。Go 从 1.25.0 升到 **1.25.14**（包含此后的标准库安全修复）。 |
| Loyalsoldier/v2ray-rules-dat `geoip.dat` / `geosite.dat` | 打包进 zip 的路由规则 | **仅 CI 构建时** | 低（已加固） | HTTPS（`--proto '=https'`），**下载同目录的 `.sha256sum` 并校验，不匹配则构建失败**。上游每天更新，极少数情况下 dat 与 sha256sum 恰好在更新瞬间不一致，重跑即可。 |
| Docker 基础镜像 `golang:1.25.14-alpine`、`alpine:3.24` | Docker 镜像构建 | 仅 Docker 工作流 | 低（已加固） | `Dockerfile` 中按 **digest 固定**（`tag@sha256:…`），升级时 tag 与 digest 一起改。 |
| ghcr.io | 发布 Docker 镜像 | 仅手动发布 Release / 手动运行 Docker 工作流 / PR | 低 | 与一键安装无关；不需要可在 Actions 中禁用该工作流。 |
| v2bx.v-50.me 文档站 | 文档参考链接 | 不访问 | 无 | 脚本不会访问。 |
| 统计 / 遥测 | — | — | 无 | 已移除上游的 `api.v-50.me/counter_v2bx` 统计请求，脚本不上报任何信息。 |

### 5.2 第三方脚本 `tcpx.sh` 审阅结果（commit `dc2197d4dcb72729860eed0f3aa96efb78963461`，2026-08-18）

固定版本只能保证「运行的就是审阅过的那份」，脚本本身的行为仍然有以下风险，使用前请知悉：

- 自带的下载函数 `safe_wget` **一律使用 `wget --no-check-certificate`**；检测到国内网络（访问 cloudflare.com/cdn-cgi/trace 判断）时，GitHub 资源会经第三方镜像（gh-proxy.com、ghproxy.net、fastgit.cc、githubdog.com、tvv.tw、ghfast.top）下载；对下载的脚本只检查“非空且首行是 shebang”，没有哈希校验。
- 会安装作者自己构建、**未签名**的内核包（GitHub `ylx2016/kernel` Release），以及 ELRepo / XanMod / Liquorix 等第三方内核源（XanMod 用 signed-by 密钥，源地址为 `http://deb.xanmod.org`；Liquorix 执行其官网的加源脚本）；部分旧内核从 `http://snapshot.debian.org`（明文 HTTP）下载并 `dpkg -i`。
- 修改 grub 默认启动项、sysctl；换内核可能导致无法开机。
- 菜单里的其它选项还会运行更多远程脚本：`tcp.hy2.sh`（Brutal）、`uk0/lotspeed` install.sh、`Kylin010/tcpfit`（以 `bash <(curl …)` 直接运行，未落盘校验）。
- 首次运行会把自身复制到 `/usr/local/bin/tcpx`；其「更新脚本」菜单从 `master` 分支下载最新版（不再受本仓库固定的版本约束）。
- 按关键字审阅（下载、执行、systemd、crontab、SELinux、上报）未发现遥测 / 上报、关闭 SELinux 或写 crontab 的行为；未逐行审阅全部约 3000 行。

**升级固定版本的方法**：在 GitHub 上选新的 commit，下载 `https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/<commit>/tcpx.sh` 审阅（至少 `grep -nE 'curl|wget|bash <|http://'`），然后把 `V2bX.sh` 顶部的 `BBR_SCRIPT_COMMIT` 与 `BBR_SCRIPT_SHA256_DEFAULT`（`sha256sum tcpx.sh`）一起更新。

### 5.3 环境变量开关

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `V2BX_INSECURE=1` | 关 | 证书错误时允许跳过 TLS 校验重试一次（不推荐，仅用于 CA 证书过旧的 EOL 系统）。 |
| `V2BX_REQUIRE_CHECKSUM=0` | 强制校验 | Release 缺少 `.dgst` 时仍继续安装（默认中止，不推荐关闭）。 |
| `V2BX_HARDEN=0` | 开 | 安装时不写入 systemd 沙箱指令。 |
| `V2BX_ALLOW_HTTP=1` | 关 | 配置向导允许 `http://` 面板地址（通讯密钥明文传输，仅内网）。 |
| `V2BX_BBR_SCRIPT_URL` / `V2BX_BBR_SCRIPT_SHA256` | 内置固定值 | 替换菜单 11 的 BBR 脚本地址及其 SHA-256。 |

### 5.4 GitHub Actions 版本升级

工作流中的 `uses:` 必须写完整 commit SHA，例如：

```yaml
uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
```

查某个 tag 对应的 SHA：`gh api repos/actions/checkout/commits/v4.4.0 --jq .sha`。可以开启 Dependabot（`package-ecosystem: github-actions`）自动提 PR 升级。

---

## 6. 发布脚本改动后的检查清单

```bash
bash -n install.sh V2bX.sh initconfig.sh
shellcheck -S error install.sh V2bX.sh initconfig.sh
grep -n 'wyx2685' install.sh V2bX.sh initconfig.sh   # 只允许出现在注释里（致谢）
docker run --rm -v "$PWD":/t:ro debian:12 bash /t/tests/smoke.sh /t/install.sh
docker run --rm -v "$PWD":/t:ro debian:12 bash /t/tests/checksum.sh /t/install.sh
docker run --rm -v "$PWD":/t:ro python:3.12-slim bash -c 'apt-get update -qq && apt-get install -y -qq curl jq >/dev/null; bash /t/tests/initconfig.sh /t/initconfig.sh'
docker run --rm -v "$PWD":/t:ro bash:4.2 bash -c 'apk add -q curl jq python3; bash /t/tests/initconfig.sh /t/initconfig.sh'   # CentOS 7 同版本 bash
grep -nE 'no-check-certificate|curl -k|bash <\(curl' install.sh V2bX.sh initconfig.sh   # 只允许出现在 V2BX_INSECURE 分支和注释里
git push origin main
```

推送到 `main` 后立即生效（raw.githubusercontent.com 可能有几分钟缓存）。

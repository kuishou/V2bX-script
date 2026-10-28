#!/bin/bash
# V2bX management script (installed as /usr/bin/V2bX and /usr/bin/v2bx).
# Self-hosted by liusu2100-sys; originally from wyx2685/V2bX-script
# (credit: upstream). No third-party telemetry.

# ---------------------------------------------------------------------------
# Repository constants: change the owner / repos / branch HERE (keep them in
# sync with install.sh and initconfig.sh). Each value can also be overridden
# by an environment variable of the same name prefixed with V2BX_.
# ---------------------------------------------------------------------------
REPO_OWNER="${V2BX_REPO_OWNER:-liusu2100-sys}"
SCRIPT_REPO="${V2BX_SCRIPT_REPO:-${REPO_OWNER}/V2bX-script}"   # install.sh / V2bX.sh / initconfig.sh
SCRIPT_BRANCH="${V2BX_SCRIPT_BRANCH:-main}"
CORE_REPO="${V2BX_CORE_REPO:-${REPO_OWNER}/V2bX}"              # V2bX binaries (GitHub Releases)
SCRIPT_URL_BASE="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}"
CORE_REPO_URL="https://github.com/${CORE_REPO}"
# Optional third-party BBR / kernel script used by menu item 11 only.
# Pinned to a reviewed commit + SHA-256 (see docs/MAINTAIN.md "安全说明").
# To upgrade: pick a new commit, review tcpx.sh, update BOTH values.
BBR_SCRIPT_COMMIT="dc2197d4dcb72729860eed0f3aa96efb78963461"   # ylx2016/Linux-NetSpeed master @ 2026-08-18
BBR_SCRIPT_SHA256_DEFAULT="7d0cb5cdc964fa0887ccec8caaa937fc430d3335c957b1c90701eee9ee45eaef"
BBR_SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/${BBR_SCRIPT_COMMIT}/tcpx.sh"
BBR_SCRIPT_URL="${V2BX_BBR_SCRIPT_URL:-${BBR_SCRIPT_URL_DEFAULT}}"
if [[ -n "${V2BX_BBR_SCRIPT_URL:-}" ]]; then
    BBR_SCRIPT_SHA256="${V2BX_BBR_SCRIPT_SHA256:-}"      # custom URL: checksum only if given
else
    BBR_SCRIPT_SHA256="${BBR_SCRIPT_SHA256_DEFAULT}"
fi
# Set V2BX_INSECURE=1 to allow ONE retry without TLS verification after a
# certificate error (outdated CA bundle). Off by default.
V2BX_INSECURE="${V2BX_INSECURE:-0}"
# ---------------------------------------------------------------------------

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

# 管理脚本只需要知道 init 系统（OpenRC 或 systemd）；系统版本检查由 install.sh 负责。
if [[ -d /run/systemd/system ]] || { command -v systemctl >/dev/null 2>&1 && [[ ! -f /etc/init.d/V2bX ]]; }; then
    release="systemd"
elif [[ -f /etc/alpine-release ]] || command -v rc-service >/dev/null 2>&1; then
    # 沿用上游变量名：release=alpine 表示使用 OpenRC
    release="alpine"
else
    release="systemd"
fi

confirm() {
    if [[ $# -gt 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启V2bX" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

# Download URL to FILE with TLS verification (-f: fail on HTTP errors).
# A TLS / certificate error is only retried without verification when the
# user explicitly set V2BX_INSECURE=1.
fetch_tls() {
    local url="$1" out="$2" rc
    curl -fLs -o "${out}" "${url}"
    rc=$?
    case "${rc}" in
        35|51|58|60|77|83)
            echo -e "${red}TLS 证书校验失败：${url}${plain}"
            if [[ "${V2BX_INSECURE}" == "1" ]]; then
                echo -e "${yellow}V2BX_INSECURE=1：跳过证书校验重试一次${plain}"
                curl -kfLs -o "${out}" "${url}"
                rc=$?
            else
                echo -e "${yellow}系统 CA 证书可能过旧（或系统时间不正确），请更新 ca-certificates 后重试；确需临时跳过校验可设置 V2BX_INSECURE=1（不推荐）${plain}"
            fi
            ;;
    esac
    return ${rc}
}

# Print the SHA-256 of FILE (sha256sum from coreutils/busybox, shasum, or openssl).
sha256_of() {
    local f="$1" h=""
    if command -v sha256sum >/dev/null 2>&1; then
        h=$(sha256sum "${f}" 2>/dev/null | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        h=$(shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        h=$(openssl dgst -sha256 "${f}" 2>/dev/null | awk '{print $NF}')
    fi
    [[ -n "${h}" ]] || return 1
    echo "${h}" | tr '[:upper:]' '[:lower:]'
}

# Download install.sh from SCRIPT_REPO and run it with the given arguments.
run_install_script() {
    local tmp rc
    tmp=$(mktemp /tmp/V2bX-install.XXXXXX) || return 1
    if ! fetch_tls "${SCRIPT_URL_BASE}/install.sh" "${tmp}" || [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        echo -e "${red}下载安装脚本失败：${SCRIPT_URL_BASE}/install.sh，请检查本机能否连接 Github${plain}"
        return 1
    fi
    bash "${tmp}" "$@"
    rc=$?
    rm -f "${tmp}"
    return ${rc}
}

install() {
    run_install_script
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
    # shellcheck disable=SC2086  # empty $version means "latest" (upstream behaviour)
    run_install_script $version
    if [[ $? == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 V2bX，请使用 V2bX log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "V2bX在修改配置后会自动尝试重启"
    "${EDITOR:-vi}" /etc/V2bX/config.json
    chmod 600 /etc/V2bX/config.json 2>/dev/null
    if load_initconfig >/dev/null 2>&1 && ! json_validate /etc/V2bX/config.json; then
        echo -e "${red}config.json 不是合法的 JSON，已取消重启，请重新编辑（V2bX config）${plain}"
        return 1
    fi
    restart
    check_status
    case $? in
        0)
            echo -e "V2bX状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动V2bX或V2bX自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -rp "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "V2bX状态: ${red}未安装${plain}"
    esac
}

uninstall() {
    confirm "确定要卸载 V2bX 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop
        rc-update del V2bX
        rm /etc/init.d/V2bX -f
    else
        systemctl stop V2bX
        systemctl disable V2bX
        rm /etc/systemd/system/V2bX.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    if [[ -d /etc/V2bX ]]; then
        local bak
        bak="/root/V2bX-config-$(date +%Y%m%d%H%M%S).tar.gz"
        if (umask 077 && tar -czf "${bak}" -C /etc V2bX 2>/dev/null); then
            echo -e "已备份配置到 ${bak}（含通讯密钥，仅 root 可读，确认不需要后请删除）"
        fi
    fi
    rm /etc/V2bX/ -rf
    rm /usr/local/V2bX/ -rf
    rm -f /usr/bin/v2bx

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/V2bX -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}V2bX已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 启动成功，请使用 V2bX log 查看运行日志${plain}"
        else
            echo -e "${red}V2bX可能启动失败，请稍后使用 V2bX log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop
    else
        systemctl stop V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}V2bX 停止成功${plain}"
    else
        echo -e "${red}V2bX停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX restart
    else
        systemctl restart V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 重启成功，请使用 V2bX log 查看运行日志${plain}"
    else
        echo -e "${red}V2bX可能启动失败，请稍后使用 V2bX log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX status
    else
        systemctl status V2bX --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add V2bX
    else
        systemctl enable V2bX
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 设置开机自启成功${plain}"
    else
        echo -e "${red}V2bX 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del V2bX
    else
        systemctl disable V2bX
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 取消开机自启成功${plain}"
    else
        echo -e "${red}V2bX 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ -f /var/log/V2bX.log ]]; then
            tail -n 100 -f /var/log/V2bX.log
        else
            echo -e "${red}未找到 /var/log/V2bX.log，请重新运行 V2bX update 以启用 OpenRC 日志${plain}\n"
        fi
    else
        journalctl -u V2bX.service -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    # Third-party script (not maintained in this repo), see docs/MAINTAIN.md.
    # Downloaded to a temp file, checked against a pinned SHA-256, and only run
    # after explicit confirmation.
    local tmp got
    echo -e "${yellow}即将运行第三方脚本 ylx2016/Linux-NetSpeed tcpx.sh（以 root 身份）：${plain}"
    echo -e "  来源: ${BBR_SCRIPT_URL}"
    echo -e "  它可能：更换内核并修改 grub 引导、添加第三方软件源（ELRepo/XanMod/Liquorix）、"
    echo -e "  修改 sysctl，并在其菜单中继续下载其它脚本/内核（其下载函数不校验 TLS 证书，国内网络下还会经第三方 GitHub 镜像下载）。"
    echo -e "  更换内核有导致无法开机的风险，请先做好快照/备份。"
    tmp=$(mktemp /tmp/V2bX-tcpx.XXXXXX) || return 1
    if ! fetch_tls "${BBR_SCRIPT_URL}" "${tmp}" || [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        echo -e "${red}下载 BBR 脚本失败：${BBR_SCRIPT_URL}${plain}"
        return 1
    fi
    if [[ -n "${BBR_SCRIPT_SHA256}" ]]; then
        if ! got=$(sha256_of "${tmp}"); then
            rm -f "${tmp}"
            echo -e "${red}未找到 sha256sum / shasum / openssl，无法校验脚本，已取消${plain}"
            return 1
        fi
        if [[ "${got}" != "$(echo "${BBR_SCRIPT_SHA256}" | tr '[:upper:]' '[:lower:]')" ]]; then
            rm -f "${tmp}"
            echo -e "${red}BBR 脚本 SHA-256 校验失败（期望 ${BBR_SCRIPT_SHA256}，实际 ${got}），已取消运行${plain}"
            return 1
        fi
        echo -e "${green}SHA-256 校验通过: ${got}${plain}"
    else
        echo -e "${red}警告：自定义的 V2BX_BBR_SCRIPT_URL 未提供 V2BX_BBR_SCRIPT_SHA256，脚本内容未经校验！${plain}"
    fi
    if ! confirm "确认运行该第三方脚本吗?" "n"; then
        rm -f "${tmp}"
        echo -e "已取消"
        return 0
    fi
    bash "${tmp}"
    rm -f "${tmp}"
}

update_shell() {
    local tmp
    tmp=$(mktemp /tmp/V2bX-sh.XXXXXX)
    if fetch_tls "${SCRIPT_URL_BASE}/V2bX.sh" "${tmp}" && [[ -s "${tmp}" ]] && bash -n "${tmp}"; then
        mv -f "${tmp}" /usr/bin/V2bX
        rm -f /usr/local/V2bX/initconfig.sh
        [[ -d /usr/local/V2bX ]] && load_initconfig >/dev/null
    else
        rm -f "${tmp}"
        false
    fi
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/V2bX
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        if systemctl is-active --quiet V2bX; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep V2bX)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled V2bX)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}V2bX已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装V2bX${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "V2bX状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "V2bX状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "V2bX状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

generate_x25519_key() {
    echo -n "正在生成 x25519 密钥："
    /usr/local/V2bX/V2bX x25519
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_V2bX_version() {
    echo -n "V2bX 版本："
    /usr/local/V2bX/V2bX version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

# 加载配置向导 / Xboard 检测函数（initconfig.sh 是生成逻辑的唯一来源）。
# 优先使用安装时放到 /usr/local/V2bX 的版本，缺失时从脚本仓库下载。
load_initconfig() {
    local f=/usr/local/V2bX/initconfig.sh tmp
    if [[ ! -s "${f}" ]]; then
        tmp=$(mktemp /tmp/V2bX-initconfig.XXXXXX) || return 1
        if ! fetch_tls "${SCRIPT_URL_BASE}/initconfig.sh" "${tmp}" || [[ ! -s "${tmp}" ]]; then
            rm -f "${tmp}"
            echo -e "${red}下载配置向导失败：${SCRIPT_URL_BASE}/initconfig.sh${plain}"
            return 1
        fi
        mkdir -p /usr/local/V2bX
        install -m 644 "${tmp}" "${f}"
        rm -f "${tmp}"
    fi
    # shellcheck source=/dev/null
    source "${f}"
}

run_generate() {
    if load_initconfig && generate_config_file; then
        echo -e "${green}正在重新启动 V2bX 服务${plain}"
        restart 0
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

# 检测 config.json 中每个节点与 Xboard 的对接情况
xboard_check() {
    if load_initconfig; then
        if xboard_check_config; then
            echo -e "${green}所有节点对接正常${plain}"
        else
            echo -e "${red}存在对接失败的节点，请根据上面的提示检查 Xboard 配置${plain}"
        fi
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

# 放行指定端口（TCP+UDP）。只添加放行规则，不关闭防火墙、不清空已有规则。
open_ports() {
    local ports p ok_any=0 fw=""
    echo -e "${yellow}请输入需要放行的端口，多个用空格或逗号分隔（如 443 8443），可写范围 20000-20100${plain}"
    echo -e "${yellow}提示：节点端口以 Xboard 中的「连接端口/服务端口」为准；http 证书模式还需放行 80${plain}"
    read -rp "端口: " ports
    ports=${ports//,/ }
    for p in ${ports}; do
        if [[ ! "${p}" =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ ]] || [[ ${p%-*} -lt 1 || ${p#*-} -gt 65535 ]]; then
            echo -e "${red}端口格式错误：${p}${plain}"
            return 1
        fi
    done
    [[ -z "${ports}" ]] && echo "未输入端口" && return 0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        fw="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        fw="firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        fw="iptables"
    else
        echo -e "${yellow}未检测到 ufw / firewalld / iptables，本机可能没有启用防火墙；请同时检查云厂商安全组${plain}"
        return 0
    fi
    echo -e "使用 ${fw} 放行：${ports}"
    for p in ${ports}; do
        case "${fw}" in
            ufw)
                ufw allow "${p/-/:}/tcp" >/dev/null && ufw allow "${p/-/:}/udp" >/dev/null && ok_any=1 ;;
            firewalld)
                firewall-cmd -q --permanent --add-port="${p}/tcp" && firewall-cmd -q --permanent --add-port="${p}/udp" && ok_any=1 ;;
            iptables)
                local proto ipt
                for ipt in iptables ip6tables; do
                    command -v "${ipt}" >/dev/null 2>&1 || continue
                    for proto in tcp udp; do
                        "${ipt}" -C INPUT -p "${proto}" --dport "${p/-/:}" -j ACCEPT 2>/dev/null ||
                            "${ipt}" -I INPUT -p "${proto}" --dport "${p/-/:}" -j ACCEPT
                    done
                done
                ok_any=1 ;;
        esac
    done
    case "${fw}" in
        firewalld) firewall-cmd -q --reload ;;
        iptables)
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1
            elif [[ -d /etc/sysconfig ]] && command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/sysconfig/iptables 2>/dev/null
            else
                echo -e "${yellow}提示：iptables 规则重启后可能失效，可安装 iptables-persistent 保存${plain}"
            fi
            ;;
    esac
    [[ ${ok_any} == 1 ]] && echo -e "${green}放行完成。若仍无法连接，请检查云厂商安全组${plain}"
}

show_usage() {
    echo "V2bX 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "V2bX              - 显示管理菜单 (功能更多)"
    echo "V2bX start        - 启动 V2bX"
    echo "V2bX stop         - 停止 V2bX"
    echo "V2bX restart      - 重启 V2bX"
    echo "V2bX status       - 查看 V2bX 状态"
    echo "V2bX enable       - 设置 V2bX 开机自启"
    echo "V2bX disable      - 取消 V2bX 开机自启"
    echo "V2bX log          - 查看 V2bX 日志"
    echo "V2bX x25519       - 生成 x25519 密钥"
    echo "V2bX generate     - 生成 V2bX 配置文件（对接 Xboard）"
    echo "V2bX check        - 检测与 Xboard 的对接"
    echo "V2bX update       - 更新 V2bX"
    echo "V2bX update x.x.x - 安装 V2bX 指定版本"
    echo "V2bX install      - 安装 V2bX"
    echo "V2bX uninstall    - 卸载 V2bX"
    echo "V2bX version      - 查看 V2bX 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}V2bX 后端管理脚本，${plain}${red}不适用于docker${plain}
--- ${CORE_REPO_URL} ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 V2bX
  ${green}2.${plain} 更新 V2bX
  ${green}3.${plain} 卸载 V2bX
————————————————
  ${green}4.${plain} 启动 V2bX
  ${green}5.${plain} 停止 V2bX
  ${green}6.${plain} 重启 V2bX
  ${green}7.${plain} 查看 V2bX 状态
  ${green}8.${plain} 查看 V2bX 日志
————————————————
  ${green}9.${plain} 设置 V2bX 开机自启
  ${green}10.${plain} 取消 V2bX 开机自启
————————————————
  ${green}11.${plain} 一键安装 bbr (最新内核)
  ${green}12.${plain} 查看 V2bX 版本
  ${green}13.${plain} 生成 X25519 密钥
  ${green}14.${plain} 升级 V2bX 维护脚本
  ${green}15.${plain} 生成 V2bX 配置文件（对接 Xboard）
  ${green}16.${plain} 放行指定端口（不会关闭防火墙）
  ${green}17.${plain} 检测 Xboard 对接
  ${green}18.${plain} 退出脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -rp "请输入选择 [0-18]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) install_bbr ;;
        12) check_install && show_V2bX_version ;;
        13) check_install && generate_x25519_key ;;
        14) update_shell ;;
        15) run_generate ;;
        16) open_ports ;;
        17) xboard_check ;;
        18) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-18]${plain}" ;;
    esac
}


if [[ $# -gt 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "update") check_install 0 && update 0 "$2" ;;
        "config") config "$@" ;;
        "generate") run_generate 0 ;;
        "check") xboard_check 0 ;;
        "open_ports") open_ports ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "x25519") check_install 0 && generate_x25519_key 0 ;;
        "version") check_install 0 && show_V2bX_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage
    esac
else
    show_menu
fi

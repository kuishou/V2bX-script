#!/bin/bash
# 一键配置 + Xboard 对接检测（配置生成逻辑的唯一来源）
# Self-hosted by liusu2100-sys; originally from wyx2685/V2bX-script
# (credit: upstream).
#
# 本文件只提供函数，不直接执行任何操作：
#   * install.sh 首次安装时 source 本文件并调用 generate_config_file；
#   * install.sh 会把本文件安装到 /usr/local/V2bX/initconfig.sh，
#     管理脚本 V2bX.sh 的 generate / check 命令 source 它。
# generate_config_file 只负责写配置，不重启服务（由调用方决定），
# 成功返回 0，用户取消或出错返回非 0。
#
# 兼容 bash >= 4.2（CentOS 7），避免使用更新的语法。

# ---------------------------------------------------------------------------
# Repository constants (only defaults: values already set by the sourcing
# script are kept).
# ---------------------------------------------------------------------------
REPO_OWNER="${REPO_OWNER:-${V2BX_REPO_OWNER:-liusu2100-sys}}"
SCRIPT_REPO="${SCRIPT_REPO:-${V2BX_SCRIPT_REPO:-${REPO_OWNER}/V2bX-script}}"
SCRIPT_BRANCH="${SCRIPT_BRANCH:-${V2BX_SCRIPT_BRANCH:-main}}"
CORE_REPO="${CORE_REPO:-${V2BX_CORE_REPO:-${REPO_OWNER}/V2bX}}"
# ---------------------------------------------------------------------------

# 配置目录（测试时可用 V2BX_CONF_DIR 指向临时目录）
CONF_DIR="${V2BX_CONF_DIR:-/etc/V2bX}"
# 允许使用 http:// 面板地址（通讯密钥会明文传输，仅建议内网/本机面板使用）
V2BX_ALLOW_HTTP="${V2BX_ALLOW_HTTP:-0}"

red="${red:-\033[0;31m}"
green="${green:-\033[0;32m}"
yellow="${yellow:-\033[0;33m}"
plain="${plain:-\033[0m}"

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------

# 转义为 JSON 字符串内容（不含两侧引号）
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '%s' "${s}"
}

# 只允许可打印字符（拒绝控制字符，避免写坏配置文件）
is_printable() {
    [[ -n "$1" && "$1" != *[[:cntrl:]]* ]]
}

# 检查系统是否有可用的公网 IPv6 地址（::1 / fe80:: 不算）
check_ipv6_support() {
    if command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

# 校验 JSON 文件；没有 jq / python3 时跳过（返回 0）
json_validate() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq empty "${f}" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${f}" >/dev/null 2>&1
    else
        return 0
    fi
}

# 原子写入：内容来自 stdin，先写临时文件再 mv，权限 600
# usage: write_secure FILE < content
write_secure() {
    local dst="$1" tmp
    tmp=$(mktemp "${dst}.tmp.XXXXXX") || return 1
    chmod 600 "${tmp}"
    cat > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${dst}"
}

# 备份已有文件为 FILE.bak.<时间戳>，并只保留最近 5 份
backup_file() {
    local f="$1" ts
    [[ -f "${f}" ]] || return 0
    ts=$(date +%Y%m%d%H%M%S)
    cp -p "${f}" "${f}.bak.${ts}" && chmod 600 "${f}.bak.${ts}"
    # shellcheck disable=SC2012  # 文件名由本脚本生成，不含特殊字符
    ls -1t "${f}".bak.* 2>/dev/null | tail -n +6 | while read -r old; do rm -f "${old}"; done
}

# 收紧配置目录权限：通讯密钥对 Xboard 所有节点通用，泄露即可拉取全部用户
secure_conf_dir() {
    mkdir -p "${CONF_DIR}"
    chmod 700 "${CONF_DIR}"
    find "${CONF_DIR}" -maxdepth 1 -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.key' -o -name '*.bak*' \) \
        -exec chmod 600 {} + 2>/dev/null
}

# ---------------------------------------------------------------------------
# Xboard 对接
#   V2bX 使用 Xboard 的 UniProxy 接口：
#     GET  {ApiHost}/api/v1/server/UniProxy/config?node_type=&node_id=&token=
#     GET  .../user   POST .../push   POST .../alive   GET .../alivelist
#   token 为 Xboard 后台「系统配置 → 服务端 → 通讯密钥」(server_token，>=16 位，
#   所有节点共用)；node_id 为「节点管理」中的节点 ID；node_type 必须与节点协议一致。
#   Xboard 中 Hysteria2 节点的类型是 hysteria（版本选 2），V2bX 里填 hysteria2，
#   面板会把 hysteria2 视为 hysteria 的别名。
# ---------------------------------------------------------------------------

# 规范化并校验面板地址，结果写入全局变量 ApiHost
# 返回 1 表示地址不可用
normalize_api_host() {
    local h="$1" hostpart
    h="${h#"${h%%[![:space:]]*}"}"
    h="${h%"${h##*[![:space:]]}"}"
    while [[ "${h}" == */ ]]; do h="${h%/}"; done
    if ! is_printable "${h}" || [[ "${h}" == *[[:space:]\"\'\\]* ]]; then
        echo -e "${red}面板地址包含非法字符${plain}"
        return 1
    fi
    if [[ ! "${h}" =~ ^https?://[^/]+ ]]; then
        echo -e "${red}面板地址必须以 https:// 开头，例如 https://xboard.example.com${plain}"
        return 1
    fi
    if [[ "${h}" == http://* ]]; then
        hostpart="${h#http://}"
        hostpart="${hostpart%%/*}"
        hostpart="${hostpart%:*}"
        case "${hostpart}" in
            127.0.0.1|localhost|"[::1]") ;;
            *)
                if [[ "${V2BX_ALLOW_HTTP}" != "1" ]]; then
                    echo -e "${red}拒绝使用 http:// 面板地址：通讯密钥会以明文出现在每个请求的 URL 中，可被中间人截获，进而拉取 Xboard 所有节点的用户 UUID。${plain}"
                    echo -e "${yellow}请为面板配置 HTTPS；确属内网/专线可设置 V2BX_ALLOW_HTTP=1 后重试。${plain}"
                    return 1
                fi
                echo -e "${yellow}警告：使用 http:// 面板地址（V2BX_ALLOW_HTTP=1），通讯密钥将明文传输${plain}"
                ;;
        esac
    fi
    ApiHost="${h}"
}

# 校验通讯密钥，结果写入全局变量 ApiKey
check_api_key() {
    local k="$1"
    if ! is_printable "${k}" || [[ "${k}" == *[[:space:]]* ]]; then
        echo -e "${red}通讯密钥不能为空，且不能包含空白或控制字符${plain}"
        return 1
    fi
    if [[ ${#k} -lt 16 ]]; then
        echo -e "${yellow}提示：Xboard 要求通讯密钥至少 16 位，当前只有 ${#k} 位，请确认是否填错${plain}"
    fi
    ApiKey="${k}"
}

# 请求 Xboard UniProxy/config 接口。
# 通讯密钥通过 curl 的 stdin 配置传入，不会出现在命令行（ps 可见）中。
# usage: xboard_probe HOST KEY NODE_ID NODE_TYPE
# 输出：响应体保存在全局变量 probe_body，HTTP 状态码在 probe_code
# 返回：0 成功；1 失败（已打印原因）
xboard_probe() {
    local host="$1" key="$2" id="$3" type="$4" tmp msg
    probe_body=""
    probe_code=""
    command -v curl >/dev/null 2>&1 || { echo -e "${yellow}未安装 curl，跳过面板连通性检测${plain}"; return 1; }
    tmp=$(mktemp) || return 1
    probe_code=$(
        {
            printf 'url = "%s/api/v1/server/UniProxy/config"\n' "$(json_escape "${host}")"
            printf 'get\n'
            printf 'data-urlencode = "node_type=%s"\n' "$(json_escape "${type}")"
            printf 'data-urlencode = "node_id=%s"\n' "$(json_escape "${id}")"
            printf 'data-urlencode = "token=%s"\n' "$(json_escape "${key}")"
        } | curl -sS --proto '=https,http' --max-time 15 -H 'Accept: application/json' \
                -A "V2bX-script" -o "${tmp}" -w '%{http_code}' -K - 2>/dev/null
    )
    probe_body=$(head -c 65536 "${tmp}")
    rm -f "${tmp}"

    case "${probe_code}" in
        200)
            if [[ "${probe_body}" != *server_port* ]]; then
                echo -e "${red}面板返回 200 但不是节点配置，ApiHost 可能指向了错误的站点（或被 CDN/WAF 拦截返回了网页）${plain}"
                return 1
            fi
            return 0
            ;;
        000|"")
            echo -e "${red}无法连接面板 ${host}：DNS / 网络 / TLS 证书错误或超时${plain}"
            return 1
            ;;
    esac

    msg=$(printf '%s' "${probe_body}" | grep -o '"message" *: *"[^"]*"' | head -n 1 | sed -E 's/.*: *"(.*)"/\1/')
    case "${probe_body}" in
        *"Invalid token"*)
            echo -e "${red}通讯密钥错误：与 Xboard「系统配置 → 服务端 → 通讯密钥」不一致${plain}" ;;
        *"Server does not exist"*)
            echo -e "${red}节点不存在：请确认节点 ID ${id} 存在，且节点协议与所选类型 ${type} 一致（Hysteria2 在 Xboard 中为 Hysteria 节点、版本选 2）${plain}" ;;
        *"Invalid node type"*)
            echo -e "${red}面板不支持节点类型 ${type}${plain}" ;;
        *)
            case "${probe_code}" in
                404) echo -e "${red}接口不存在 (404)：请确认 ApiHost 填写的是 Xboard 站点根地址，不要带 /admin 等路径${plain}" ;;
                403|503) echo -e "${red}请求被拒绝 (${probe_code})：可能被 Cloudflare/WAF 拦截，请为节点 IP 放行或让 ApiHost 直连源站${plain}" ;;
                5*) echo -e "${red}面板服务器错误 (${probe_code})：请检查 Xboard 日志${plain}" ;;
                *) echo -e "${red}面板返回 HTTP ${probe_code}${msg:+：${msg}}${plain}" ;;
            esac
            ;;
    esac
    return 1
}

# 从 probe_body 中取简单字段（不依赖 jq；只用于提示和默认值）
probe_field_num() { printf '%s' "${probe_body}" | grep -o "\"$1\" *: *[0-9]*" | head -n 1 | grep -o '[0-9]*$'; }
probe_field_str() { printf '%s' "${probe_body}" | grep -o "\"$1\" *: *\"[^\"]*\"" | head -n 1 | sed -E 's/.*: *"(.*)"$/\1/'; }

# 检测 config.json 中所有节点能否从 Xboard 拉取配置
xboard_check_config() {
    local cfg="${CONF_DIR}/config.json" rows line host key id type n=0 bad=0
    if [[ ! -f "${cfg}" ]]; then
        echo -e "${red}未找到 ${cfg}${plain}"
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        rows=$(jq -r '.Nodes[] | (.ApiConfig // .) as $a | [$a.ApiHost, $a.ApiKey, ($a.NodeID|tostring), $a.NodeType] | map(. // "" | tostring) | join("\u001f")' "${cfg}" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        rows=$(python3 - "${cfg}" <<'PY' 2>/dev/null
import json, sys
for n in json.load(open(sys.argv[1])).get("Nodes", []):
    a = n.get("ApiConfig") or n
    print("\x1f".join(str(a.get(k, "")) for k in ("ApiHost", "ApiKey", "NodeID", "NodeType")))
PY
)
    else
        echo -e "${yellow}需要 jq 或 python3 才能解析 config.json，请先安装其一（如 apt-get install -y jq）${plain}"
        return 1
    fi
    if [[ -z "${rows}" ]]; then
        echo -e "${red}config.json 解析失败或没有节点（使用了 Include 的节点无法检测）${plain}"
        return 1
    fi
    # 字段用 \x1f 分隔（@tsv 会转义反斜杠，导致含 \ 的密钥被改写）
    while IFS=$'\x1f' read -r host key id type; do
        [[ -z "${host}" ]] && continue
        n=$((n + 1))
        host="${host%/}"
        echo -e "节点 ${n}: ${host}  ID=${id}  类型=${type}"
        if [[ "${host}" == http://* ]]; then
            echo -e "  ${yellow}警告：面板地址为 http://，通讯密钥明文传输${plain}"
        fi
        if xboard_probe "${host}" "${key}" "${id}" "${type}"; then
            echo -e "  ${green}对接正常${plain}，面板端口 $(probe_field_num server_port)"
            if [[ "${type}" == "hysteria2" && "$(probe_field_num version)" == "1" ]]; then
                echo -e "  ${yellow}面板中该节点是 Hysteria 版本 1，与 hysteria2 不一致${plain}"
            fi
        else
            bad=$((bad + 1))
        fi
    done <<< "${rows}"
    [[ ${bad} -eq 0 ]]
}

# ---------------------------------------------------------------------------
# 配置生成向导
# ---------------------------------------------------------------------------

# 读取一个 y/n，默认值为第二个参数
ask_yn() {
    local ans
    read -rp "$1 [$( [[ "$2" == y ]] && echo Y/n || echo y/N )]: " ans
    [[ -z "${ans}" ]] && ans="$2"
    [[ "${ans}" == [Yy] || "${ans}" == [Yy][Ee][Ss] ]]
}

# 询问面板地址与通讯密钥（循环直到合法）
ask_api_info() {
    local h k
    while true; do
        read -rp "请输入 Xboard 面板地址 (https://xboard.example.com)：" h
        normalize_api_host "${h}" && break
    done
    while true; do
        read -rsp "请输入通讯密钥（Xboard 系统配置 → 服务端 → 通讯密钥，输入不回显）：" k
        echo
        check_api_key "${k}" && break
    done
}

# 证书相关的提问，结果写入 certmode / certdomain / certfile / keyfile / certprovider / dnsenv_json / certemail
ask_cert_config() {
    local def_domain="$1" sel k v
    certprovider="cloudflare"
    dnsenv_json="{}"
    certemail=""
    certfile="${CONF_DIR}/fullchain.cer"
    keyfile="${CONF_DIR}/cert.key"
    echo -e "${yellow}请选择证书模式：${plain}"
    echo -e "${green}1. http  自动申请（域名已解析到本机，且 80 端口空闲可访问）${plain}"
    echo -e "${green}2. dns   自动申请（填写 DNS 服务商 API 凭据，推荐）${plain}"
    echo -e "${green}3. file  使用已有证书文件${plain}"
    echo -e "${green}4. self  自签证书（客户端需允许不安全证书，不推荐）${plain}"
    while true; do
        read -rp "请输入 [1-4]：" sel
        case "${sel}" in
            1) certmode="http"; break ;;
            2) certmode="dns"; break ;;
            3) certmode="file"; break ;;
            4) certmode="self"; break ;;
        esac
    done
    while true; do
        read -rp "请输入证书域名${def_domain:+ [默认 ${def_domain}]}：" certdomain
        [[ -z "${certdomain}" ]] && certdomain="${def_domain}"
        [[ "${certdomain}" =~ ^[A-Za-z0-9*]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && break
        echo -e "${red}域名格式不正确${plain}"
    done
    case "${certmode}" in
        http|dns)
            read -rp "ACME 账户邮箱（用于证书到期提醒，可留空）：" certemail
            is_printable "${certemail}" || certemail=""
            ;;
    esac
    if [[ "${certmode}" == "dns" ]]; then
        read -rp "DNS 服务商（lego 名称，如 cloudflare / alidns / dnspod / tencentcloud）[默认 cloudflare]：" certprovider
        [[ -z "${certprovider}" ]] && certprovider="cloudflare"
        dnsenv_json=""
        if [[ "${certprovider}" == "cloudflare" ]]; then
            echo -e "${yellow}推荐使用仅有 Zone.DNS 编辑权限的 API Token（CF_DNS_API_TOKEN），不要使用 Global API Key${plain}"
            read -rsp "请输入 CF_DNS_API_TOKEN（不回显）：" v; echo
            dnsenv_json="\"CF_DNS_API_TOKEN\": \"$(json_escape "${v}")\""
        else
            echo -e "请按 lego 文档输入该服务商需要的环境变量（https://go-acme.github.io/lego/dns/），空变量名结束"
            while true; do
                read -rp "变量名：" k
                [[ -z "${k}" ]] && break
                [[ "${k}" =~ ^[A-Z0-9_]+$ ]] || { echo -e "${red}变量名只能是大写字母、数字、下划线${plain}"; continue; }
                read -rsp "变量值（不回显）：" v; echo
                dnsenv_json="${dnsenv_json:+${dnsenv_json}, }\"${k}\": \"$(json_escape "${v}")\""
            done
        fi
        dnsenv_json="{${dnsenv_json}}"
    elif [[ "${certmode}" == "file" ]]; then
        read -rp "证书文件路径 [默认 ${certfile}]：" v; [[ -n "${v}" ]] && certfile="${v}"
        read -rp "私钥文件路径 [默认 ${keyfile}]：" v; [[ -n "${v}" ]] && keyfile="${v}"
        [[ -f "${certfile}" && -f "${keyfile}" ]] || echo -e "${yellow}提示：证书或私钥文件当前不存在，请在启动前放置好${plain}"
    fi
    if [[ "${certmode}" == "http" ]]; then
        echo -e "${yellow}提示：http 模式需要 80 端口对外可访问（防火墙放行 80/tcp）${plain}"
    fi
}

add_node_config() {
    local sel default_domain tls_val need_cert node_json listen_ip sniff_tfo
    # 每个节点独立的变量，避免沿用上一个节点的回答
    local core NodeID NodeType
    certmode="none"; certdomain=""; certfile="${CONF_DIR}/fullchain.cer"; keyfile="${CONF_DIR}/cert.key"
    certprovider="cloudflare"; dnsenv_json="{}"; certemail=""

    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. xray      （vmess / vless / trojan / shadowsocks）${plain}"
    echo -e "${green}2. singbox   （以上全部 + hysteria / hysteria2 / tuic / anytls）${plain}"
    echo -e "${green}3. hysteria2 （仅 hysteria2，官方内核）${plain}"
    while true; do
        read -rp "请输入 [1-3]：" sel
        case "${sel}" in
            1) core="xray"; core_xray=true; break ;;
            2) core="sing"; core_sing=true; break ;;
            3) core="hysteria2"; core_hysteria2=true; break ;;
            *) echo "无效的选择，请输入 1 2 3" ;;
        esac
    done

    while true; do
        read -rp "请输入 Xboard 节点 ID：" NodeID
        [[ "${NodeID}" =~ ^[1-9][0-9]{0,8}$ ]] && break
        echo "错误：节点 ID 必须是正整数"
    done

    if [[ "${core}" == "hysteria2" ]]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点协议（必须与 Xboard 中该节点的协议一致）：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        echo -e "${green}4. Trojan${plain}"
        if [[ "${core}" == "sing" ]]; then
            echo -e "${green}5. Hysteria（Xboard Hysteria 节点，版本 1）${plain}"
            echo -e "${green}6. Hysteria2（Xboard Hysteria 节点，版本 2）${plain}"
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        while true; do
            read -rp "请输入：" sel
            case "${sel}" in
                1) NodeType="shadowsocks" ;;
                2) NodeType="vless" ;;
                3) NodeType="vmess" ;;
                4) NodeType="trojan" ;;
                5) NodeType="hysteria" ;;
                6) NodeType="hysteria2" ;;
                7) NodeType="tuic" ;;
                8) NodeType="anytls" ;;
                *) NodeType="" ;;
            esac
            if [[ -n "${NodeType}" && ( "${core}" == "sing" || "${sel}" -le 4 ) ]]; then
                break
            fi
            echo "无效的选择"
        done
    fi

    # 从面板拉取节点配置，用于验证对接参数并推断 TLS 需求
    tls_val=""
    default_domain=""
    echo -e "正在检测 Xboard 对接（${ApiHost}，节点 ${NodeID}，${NodeType}）..."
    if xboard_probe "${ApiHost}" "${ApiKey}" "${NodeID}" "${NodeType}"; then
        echo -e "${green}对接成功${plain}：面板端口 $(probe_field_num server_port)"
        tls_val=$(probe_field_num tls)
        default_domain=$(probe_field_str server_name)
        if [[ "${NodeType}" == "hysteria2" && "$(probe_field_num version)" == "1" ]]; then
            echo -e "${yellow}警告：面板中该节点是 Hysteria 版本 1，请在 Xboard 中改为版本 2，或选择 Hysteria${plain}"
        fi
        if [[ "${NodeType}" == "hysteria" && "$(probe_field_num version)" == "2" ]]; then
            echo -e "${yellow}警告：面板中该节点是 Hysteria 版本 2，应选择 Hysteria2${plain}"
        fi
    else
        if ! ask_yn "对接检测失败，仍然继续生成该节点配置吗?" n; then
            return 1
        fi
    fi

    # 判断是否需要本地证书
    case "${NodeType}" in
        shadowsocks) need_cert=n ;;
        hysteria|hysteria2|tuic|anytls) need_cert=y ;;
        *)
            case "${tls_val}" in
                0) need_cert=n ;;
                2) need_cert=n; echo -e "${green}面板配置为 Reality，无需证书${plain}" ;;
                1) need_cert=y ;;
                *)
                    if ask_yn "该节点是否为 Reality 节点?" n; then
                        need_cert=n
                    elif ask_yn "该节点是否启用 TLS?" y; then
                        need_cert=y
                    else
                        need_cert=n
                    fi
                    ;;
            esac
            ;;
    esac
    [[ "${need_cert}" == y ]] && ask_cert_config "${default_domain}"
    [[ -z "${certdomain}" ]] && certdomain="example.com"

    listen_ip="0.0.0.0"
    [[ "$(check_ipv6_support)" == "1" ]] && listen_ip="::"

    # 公共字段（键名与 V2bX conf/node.go 中的 json tag 一致）
    node_json="{
            \"Core\": \"${core}\",
            \"ApiHost\": \"$(json_escape "${ApiHost}")\",
            \"ApiKey\": \"$(json_escape "${ApiKey}")\",
            \"NodeID\": ${NodeID},
            \"NodeType\": \"${NodeType}\",
            \"Timeout\": 30,"
    case "${core}" in
        xray)
            node_json+="
            \"ListenIP\": \"0.0.0.0\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"ReportMinTraffic\": 0,
            \"EnableProxyProtocol\": false,
            \"EnableUot\": true,
            \"EnableTFO\": true,"
            ;;
        sing)
            # TFO 对 QUIC 类协议无意义；嗅探由 sing_origin.json 的 sniff 动作控制，
            # V2bX 的 sing 内核不使用 EnableSniff，故不再写入
            sniff_tfo=true
            case "${NodeType}" in hysteria|hysteria2|tuic|anytls) sniff_tfo=false ;; esac
            node_json+="
            \"ListenIP\": \"${listen_ip}\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"ReportMinTraffic\": 0,
            \"EnableTFO\": ${sniff_tfo},"
            ;;
        hysteria2)
            node_json+="
            \"Hysteria2ConfigPath\": \"${CONF_DIR}/hy2config.yaml\",
            \"ListenIP\": \"\",
            \"SendIP\": \"0.0.0.0\",
            \"DeviceOnlineMinTraffic\": 200,
            \"ReportMinTraffic\": 0,"
            ;;
    esac
    node_json+="
            \"CertConfig\": {
                \"CertMode\": \"${certmode}\",
                \"RejectUnknownSni\": false,
                \"CertDomain\": \"$(json_escape "${certdomain}")\",
                \"CertFile\": \"$(json_escape "${certfile}")\",
                \"KeyFile\": \"$(json_escape "${keyfile}")\",
                \"Email\": \"$(json_escape "${certemail}")\",
                \"Provider\": \"$(json_escape "${certprovider}")\",
                \"DNSEnv\": ${dnsenv_json}
            }
        }"
    nodes_config+=("${node_json}")
    return 0
}

# 原版的本地审计域名规则（可选）。建议改为在 Xboard「路由管理」中统一下发。
audit_domain_regex() {
    cat <<'EOF'
(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com
(.+.|^)(360|so).(cn|com)
(Subject|HELO|SMTP)
(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)
(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)
(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)
(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)
(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)
(.+.|^)(360).(cn|com|net)
(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)
(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)
(.*.||)(netvigator|torproject).(com|cn|net|org)
(..||)(visa|mycard|gash|beanfun|bank).
(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)
(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)
(.*.||)(mycard).(com|tw)
(.*.||)(gash).(com|tw)
(.bank.)
(.*.||)(pincong).(rocks)
(.*.||)(taobao).(com)
(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)
(flows|miaoko).(pages).(dev)
EOF
}

# 把审计规则输出为 JSON 数组元素（带前缀，如 "regexp:"），每行缩进 INDENT
audit_json_list() {
    local prefix="$1" indent="$2" first=1 line
    while IFS= read -r line; do
        [[ ${first} -eq 1 ]] || printf ',\n'
        printf '%s"%s%s"' "${indent}" "${prefix}" "$(json_escape "${line}")"
        first=0
    done < <(audit_domain_regex)
    printf '\n'
}

# xray 的 connIdle（秒）：内存不超过 600MB 的机器用 120，其余用 300
xray_conn_idle() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    if [[ "${mem_kb}" =~ ^[0-9]+$ ]] && [[ ${mem_kb} -le 614400 ]]; then
        echo 120
    else
        echo 300
    fi
}

# xray 内部 DNS（custom_outbound 第一个出站按域名解析时使用）
write_xray_dns_json() {
    local strategy="UseIPv4"
    [[ "$(check_ipv6_support)" == "1" ]] && strategy="UseIP"
    write_secure "${CONF_DIR}/dns.json" <<EOF
{
    "servers": [
        "1.1.1.1",
        "8.8.8.8"
    ],
    "queryStrategy": "${strategy}"
}
EOF
}

# 未命中规则的流量走默认出站，即 custom_outbound.json 的第一个出站，
# 节点自身的出站（EnableDNS / DNSType / SendIP）不会被使用，所以最后一条
# 规则显式把剩余流量送到 IPv4_out
write_route_json() {
    local audit="$1"
    {
        cat <<'EOF'
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
EOF
        # 没有 IPv6 时立即拒绝 IPv6 目标，客户端可马上回退，而不是等到超时
        if [[ "$(check_ipv6_support)" != "1" ]]; then
            printf '        {\n            "outboundTag": "block",\n            "ip": [\n                "::/0"\n            ]\n        },\n'
        fi
        if [[ "${audit}" == y ]]; then
            printf '        {\n            "outboundTag": "block",\n            "domain": [\n'
            audit_json_list "regexp:" "                "
            printf '            ]\n        },\n'
        fi
        cat <<'EOF'
        {
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    } | write_secure "${CONF_DIR}/route.json"
}

# 第一个出站就是 xray 的默认出站：没有 IPv6 时只用 IPv4，有 IPv6 时优先 IPv4
write_custom_outbound_json() {
    local strategy="UseIPv4"
    [[ "$(check_ipv6_support)" == "1" ]] && strategy="UseIPv4v6"
    write_secure "${CONF_DIR}/custom_outbound.json" <<EOF
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "${strategy}"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
}

# sing 内核是否嗅探只由这里的路由规则决定：V2bX 的 sing 内核不使用
# 节点里的 EnableSniff，所以第一条必须是 sniff 动作，否则按 protocol
# 匹配的规则（如 bittorrent）永远不会命中。
# 屏蔽用 reject 动作：官方 sing-box 1.13 已删除 block 出站。
write_sing_origin_json() {
    local audit="$1" dnsstrategy="ipv4_only"
    [[ "$(check_ipv6_support)" == "1" ]] && dnsstrategy="prefer_ipv4"
    {
        cat <<EOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "cf",
        "server": "1.1.1.1"
      },
      {
        "type": "udp",
        "tag": "google",
        "server": "8.8.8.8"
      }
    ],
    "strategy": "${dnsstrategy}"
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": {
      "server": "cf",
      "strategy": "${dnsstrategy}"
    },
    "rules": [
      {
        "action": "sniff"
      },
EOF
        # 没有 IPv6 时立即拒绝 IPv6 目标，客户端可马上回退，而不是等到超时
        if [[ "${dnsstrategy}" == ipv4_only ]]; then
            printf '      {\n        "ip_cidr": [\n          "::/0"\n        ],\n        "action": "reject"\n      },\n'
        fi
        cat <<'EOF'
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "action": "reject"
EOF
        printf '      }'
        if [[ "${audit}" == y ]]; then
            printf ',\n      {\n        "domain_regex": [\n'
            audit_json_list "" "          "
            printf '        ],\n        "action": "reject"\n      }'
        fi
        printf '\n'
        cat <<'EOF'
    ],
    "final": "direct"
  }
}
EOF
    } | write_secure "${CONF_DIR}/sing_origin.json"
}

# hysteria2 的 ACL 只用 CIDR：使用 geoip/geosite 时 hysteria 会在运行时
# 从 GitHub 下载未经校验的 geo 数据文件。
# 出站：没有 IPv6 时只用 IPv4（mode "4"）并立即拒绝 IPv6 目标；
# 有 IPv6 时优先 IPv4（mode "46"）。默认的 auto 在没有 IPv6 的机器上
# 可能先尝试 IPv6 再失败。
# 注：V2bX 强制开启 PMTU 探测，并且 initStreamReceiveWindow 实际不生效
# （总是 8MB），这里只保留真正起作用的字段。
write_hy2_config() {
    local mode="4" reject_v6="    - reject(::/0)"
    if [[ "$(check_ipv6_support)" == "1" ]]; then
        mode="46"
        reject_v6=""
    fi
    {
        cat <<'EOF'
quic:
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53
    timeout: 4s
EOF
        cat <<EOF
outbounds:
  - name: direct
    type: direct
    direct:
      mode: "${mode}"
EOF
        cat <<'EOF'
acl:
  inline:
    - reject(0.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(100.64.0.0/10)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)
EOF
        [[ -n "${reject_v6}" ]] && printf '%s\n' "${reject_v6}"
        cat <<'EOF'
    - direct(all)
masquerade:
  type: 404
EOF
    } | write_secure "${CONF_DIR}/hy2config.yaml"
}

generate_config_file() {
    local cores_config="" nodes_str="" i audit=n tmp old_umask
    echo -e "${yellow}V2bX 配置文件生成向导（对接 Xboard）${plain}"
    echo -e "${yellow}说明：${plain}"
    echo -e "  1. 生成的配置保存到 ${CONF_DIR}/config.json（权限 600），原文件备份为 config.json.bak.<时间>"
    echo -e "  2. 每个节点都会实时请求 Xboard 校验面板地址 / 通讯密钥 / 节点 ID / 协议"
    echo -e "  3. 节点协议、端口、传输方式等均由 Xboard 下发，本地只配置证书与内核参数"
    if ! ask_yn "确定继续?" y; then
        return 1
    fi

    nodes_config=()
    core_xray=false
    core_sing=false
    core_hysteria2=false

    ask_api_info
    local fixed_api=y
    ask_yn "后续节点是否使用相同的面板地址和通讯密钥?" y || fixed_api=n

    while true; do
        add_node_config || echo -e "${yellow}已跳过该节点${plain}"
        ask_yn "是否继续添加节点?" n || break
        [[ "${fixed_api}" == n ]] && ask_api_info
    done

    if [[ ${#nodes_config[@]} -eq 0 ]]; then
        echo -e "${red}没有任何节点，未修改配置文件${plain}"
        return 1
    fi

    echo -e "${yellow}本地审计规则：默认只阻断内网/回环地址（防止用户借节点访问服务器内网或云厂商元数据接口）和 BT 下载。${plain}"
    echo -e "${yellow}原版还内置了一份域名审计列表（会屏蔽 gov / bank / taobao / 360 等大量域名），更推荐在 Xboard「路由管理」中按需统一下发。${plain}"
    ask_yn "是否额外启用原版域名审计列表?" n && audit=y

    if [[ "${core_xray}" == true ]]; then
        # V2bX 默认 connIdle 只有 30 秒，空闲的长连接（SSH、IM、游戏）会被断开；
        # 改用 Xray 官方默认 300 秒，小内存机器用 120 秒
        cores_config+="
    {
        \"Type\": \"xray\",
        \"Log\": {
            \"Level\": \"error\",
            \"ErrorPath\": \"${CONF_DIR}/error.log\"
        },
        \"DnsConfigPath\": \"${CONF_DIR}/dns.json\",
        \"OutboundConfigPath\": \"${CONF_DIR}/custom_outbound.json\",
        \"RouteConfigPath\": \"${CONF_DIR}/route.json\",
        \"XrayConnectionConfig\": {
            \"handshake\": 4,
            \"connIdle\": $(xray_conn_idle),
            \"uplinkOnly\": 2,
            \"downlinkOnly\": 5,
            \"bufferSize\": 64
        }
    },"
    fi
    if [[ "${core_sing}" == true ]]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Level\": \"error\",
            \"Timestamp\": true
        },
        \"NTP\": {
            \"Enable\": false,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"${CONF_DIR}/sing_origin.json\"
    },"
    fi
    if [[ "${core_hysteria2}" == true ]]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": {
            \"Level\": \"error\"
        }
    },"
    fi
    cores_config="${cores_config%,}"

    for i in "${!nodes_config[@]}"; do
        [[ ${i} -gt 0 ]] && nodes_str+=","
        nodes_str+="
        ${nodes_config[${i}]}"
    done

    mkdir -p "${CONF_DIR}"
    chmod 700 "${CONF_DIR}"
    old_umask=$(umask)
    umask 077
    _generate_write_files
    i=$?
    umask "${old_umask}"
    return ${i}
}

# generate_config_file 的写文件部分（在 umask 077 下执行）
_generate_write_files() {
    local tmp i
    tmp=$(mktemp "${CONF_DIR}/config.json.new.XXXXXX") || return 1
    cat > "${tmp}" <<EOF
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": [${cores_config}
    ],
    "Nodes": [${nodes_str}
    ]
}
EOF
    if ! json_validate "${tmp}"; then
        echo -e "${red}生成的 config.json 不是合法 JSON，已保留在 ${tmp} 供排查，原配置未改动${plain}"
        return 1
    fi

    for i in config.json dns.json route.json custom_outbound.json sing_origin.json hy2config.yaml; do
        backup_file "${CONF_DIR}/${i}"
    done
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${CONF_DIR}/config.json"
    write_xray_dns_json
    write_custom_outbound_json
    write_route_json "${audit}"
    write_sing_origin_json "${audit}"
    write_hy2_config
    secure_conf_dir

    echo -e "${green}V2bX 配置文件生成完成：${CONF_DIR}/config.json${plain}"
    if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
        :
    else
        echo -e "${yellow}提示：未安装 jq / python3，未做 JSON 语法校验${plain}"
    fi
    return 0
}

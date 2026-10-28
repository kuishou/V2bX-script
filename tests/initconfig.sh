#!/bin/bash
# 离线端到端测试 initconfig.sh：启动 Xboard 模拟服务端，按顺序喂入向导答案，
# 检查生成的配置（JSON 合法、字段名、权限、特殊字符转义、对接检测）。
# 需要：bash curl jq python3
# usage: bash tests/initconfig.sh /path/to/initconfig.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fail=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; return 1; fi; }

port=18080
token='Tok"en\with-specials-1234'
python3 "${here}/xboard_mock.py" "${port}" "${token}" &
mock=$!
trap 'kill ${mock} 2>/dev/null; rm -rf "${V2BX_CONF_DIR}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s "http://127.0.0.1:${port}/" >/dev/null 2>&1 && break
    sleep 0.3
done

export V2BX_CONF_DIR
V2BX_CONF_DIR=$(mktemp -d)
# shellcheck source=/dev/null
source "$1"

# --- 面板地址校验 ---
( normalize_api_host "http://panel.example.com" >/dev/null ); check "拒绝公网 http 面板地址" '[[ $? -ne 0 ]]'
( normalize_api_host "panel.example.com" >/dev/null );        check "拒绝缺少协议的地址" '[[ $? -ne 0 ]]'
normalize_api_host "https://panel.example.com///" >/dev/null; check "去掉结尾斜杠" '[[ "${ApiHost}" == "https://panel.example.com" ]]'
( V2BX_ALLOW_HTTP=1 normalize_api_host "http://10.0.0.2" >/dev/null ); check "V2BX_ALLOW_HTTP=1 允许 http" '[[ $? -eq 0 ]]'

# --- 直接探测 ---
xboard_probe "http://127.0.0.1:${port}" "wrong-token-xxxxxxxx" 1 vless > "${V2BX_CONF_DIR}/p.out"
check "错误密钥被识别" 'grep -q "通讯密钥错误" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${token}" 5 vless > "${V2BX_CONF_DIR}/p.out"
check "节点不存在被识别" 'grep -q "节点不存在" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${token}" 2 hysteria2 >/dev/null
check "hysteria2 作为 hysteria 别名对接成功" '[[ $? -eq 0 && "$(probe_field_num version)" == 2 ]]'

# --- 向导 ---
answers=(
    y                                   # 确定继续
    "http://127.0.0.1:${port}/"         # 面板地址
    "${token}"                          # 通讯密钥
    y                                   # 后续节点使用相同面板
    2 1 2                               # 节点1: sing / ID 1 / vless (面板 tls=2 => reality，无需证书)
    y                                   # 继续添加
    3 2                                 # 节点2: hysteria2 内核 / ID 2
    2 "" "" "" 'cf"tok\en'              # dns 证书 / 默认域名 / 邮箱留空 / cloudflare / token
    y                                   # 继续添加
    1 3 4                               # 节点3: xray / ID 3 / trojan (tls=1)
    3 "" "" ""                          # file 证书 / 默认域名 / 默认路径 x2
    y                                   # 继续添加
    1 99 1 n                            # 节点4: 不存在 -> 不继续 -> 跳过
    n                                   # 不再添加
    y                                   # 启用原版审计列表
)
printf '%s\n' "${answers[@]}" | generate_config_file > "${V2BX_CONF_DIR}/wizard.out" 2>&1
# rc / cfg 在 check 的 eval 字符串中使用
# shellcheck disable=SC2034
rc=$?
# shellcheck disable=SC2034
cfg="${V2BX_CONF_DIR}/config.json"
check "向导返回成功" '[[ ${rc} -eq 0 ]]' || sed -n '1,200p' "${V2BX_CONF_DIR}/wizard.out"
for f in config.json route.json custom_outbound.json sing_origin.json; do
    check "${f} 为合法 JSON" 'jq empty "${V2BX_CONF_DIR}/${f}"'
done
check "生成 3 个节点（跳过不存在的节点）" '[[ $(jq ".Nodes|length" "${cfg}") -eq 3 ]]'
check "通讯密钥特殊字符原样保存" '[[ "$(jq -r ".Nodes[0].ApiKey" "${cfg}")" == "${token}" ]]'
check "ApiHost 已规范化" '[[ "$(jq -r ".Nodes[0].ApiHost" "${cfg}")" == "http://127.0.0.1:${port}" ]]'
check "reality 节点 CertMode=none" '[[ "$(jq -r ".Nodes[0].CertConfig.CertMode" "${cfg}")" == none ]]'
check "sing 使用正确键名 EnableSniff/EnableTFO" '[[ "$(jq ".Nodes[0].EnableSniff" "${cfg}")" == true && "$(jq ".Nodes[0]|has(\"SniffEnabled\")" "${cfg}")" == false ]]'
check "使用 ReportMinTraffic 键名" '[[ "$(jq ".Nodes[0]|has(\"ReportMinTraffic\")" "${cfg}")" == true ]]'
check "hy2 证书域名取自面板 server_name" '[[ "$(jq -r ".Nodes[1].CertConfig.CertDomain" "${cfg}")" == hy.example.com ]]'
check "dns 模式写入 CF_DNS_API_TOKEN" '[[ "$(jq -r ".Nodes[1].CertConfig.DNSEnv.CF_DNS_API_TOKEN" "${cfg}")" == "cf\"tok\\en" ]]'
check "trojan 使用 file 证书模式" '[[ "$(jq -r ".Nodes[2].CertConfig.CertMode" "${cfg}")" == file ]]'
check "Cores 含 sing/hysteria2/xray" '[[ "$(jq -c "[.Cores[].Type]|sort" "${cfg}")" == "[\"hysteria2\",\"sing\",\"xray\"]" ]]'
check "启用审计时 route.json 含域名规则" '[[ $(jq "[.rules[]|select(.domain)]|length" "${V2BX_CONF_DIR}/route.json") -eq 1 ]]'
check "hy2 ACL 不依赖 geo 文件" '! grep -q "geoip\|geosite" "${V2BX_CONF_DIR}/hy2config.yaml"'
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
check "配置目录权限 700" '[[ "$(perm "${V2BX_CONF_DIR}")" == 700 ]]'
check "config.json 权限 600" '[[ "$(perm "${cfg}")" == 600 ]]'
check "通讯密钥未出现在向导输出中" '! grep -qF "${token}" "${V2BX_CONF_DIR}/wizard.out"'

# --- 再生成一次：旧配置被备份 ---
printf '%s\n' y "http://127.0.0.1:${port}" "${token}" y 2 1 2 n n | generate_config_file >/dev/null 2>&1
check "重新生成时备份旧 config.json" 'ls "${V2BX_CONF_DIR}"/config.json.bak.* >/dev/null 2>&1'
check "未启用审计时 route.json 无域名规则" '[[ $(jq "[.rules[]|select(.domain)]|length" "${V2BX_CONF_DIR}/route.json") -eq 0 ]]'

# --- 对接检测 ---
xboard_check_config > "${V2BX_CONF_DIR}/check.out" 2>&1
check "xboard_check_config 通过" '[[ $? -eq 0 ]]' || cat "${V2BX_CONF_DIR}/check.out"

exit ${fail}

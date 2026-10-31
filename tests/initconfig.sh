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
mtoken='Mach"ine\token-0123456789abcdef'
export V2BX_CONF_DIR XBOARD_MOCK_LOG
V2BX_CONF_DIR=$(mktemp -d)
XBOARD_MOCK_LOG="${V2BX_CONF_DIR}/requests.log"
python3 "${here}/xboard_mock.py" "${port}" "${token}" "${mtoken}" &
mock=$!
trap 'kill ${mock} 2>/dev/null; rm -rf "${V2BX_CONF_DIR}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s "http://127.0.0.1:${port}/" >/dev/null 2>&1 && break
    sleep 0.3
done

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
check "v1 检测请求 UniProxy/config 并带 node_type" 'tail -n 1 "${XBOARD_MOCK_LOG}" | grep -q "^GET /api/v1/server/UniProxy/config?node_type=hysteria2&node_id=2&token="'

# --- 直接探测：机器令牌（v2） ---
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 1 vless 7 > "${V2BX_CONF_DIR}/p.out"
check "机器令牌对接成功" '[[ $? -eq 0 && "$(probe_field_num server_port)" == 443 ]]'
# shellcheck disable=SC2016  # 单引号内容由 check 的 eval 展开
check "v2 检测请求 server/config，带 machine_id，不带 node_type" 'last=$(tail -n 1 "${XBOARD_MOCK_LOG}"); [[ "${last}" == "GET /api/v2/server/config?machine_id=7&node_id=1&token="* && "${last}" != *node_type* ]]'
xboard_probe "http://127.0.0.1:${port}" "wrong-machine-token-xxxxxxxxxxxx" 1 vless 7 > "${V2BX_CONF_DIR}/p.out"
check "机器令牌错误被识别 (401)" '[[ ${probe_code} == 401 ]] && grep -q "机器 ID 或机器令牌错误" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 1 vless 9 > "${V2BX_CONF_DIR}/p.out"
check "机器 ID 不存在被识别 (401)" 'grep -q "机器 ID 或机器令牌错误" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "disabled-machine-token-00000000" 1 vless 8 > "${V2BX_CONF_DIR}/p.out"
check "机器已停用被识别 (403)" '[[ ${probe_code} == 403 ]] && grep -q "已在 Xboard 中停用" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 3 trojan 7 > "${V2BX_CONF_DIR}/p.out"
check "节点未绑定到该机器被识别" 'grep -q "节点不在该机器上" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 4 shadowsocks 7 > "${V2BX_CONF_DIR}/p.out"
check "节点未启用被识别" 'grep -q "节点不在该机器上" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 1 trojan 7 > "${V2BX_CONF_DIR}/p.out"
check "v2 下协议不符被识别" 'grep -q "节点协议不符" "${V2BX_CONF_DIR}/p.out"'
xboard_probe "http://127.0.0.1:${port}" "${mtoken}" 2 hysteria2 7 >/dev/null
check "v2 下 hysteria2 与面板 hysteria 匹配" '[[ $? -eq 0 ]]'

# --- 向导 ---
answers=(
    y                                   # 确定继续
    "http://127.0.0.1:${port}/"         # 面板地址
    ""                                  # 鉴权方式：回车默认全局通讯密钥
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
: > "${XBOARD_MOCK_LOG}"
printf '%s\n' "${answers[@]}" | generate_config_file > "${V2BX_CONF_DIR}/wizard.out" 2>&1
# rc / cfg 在 check 的 eval 字符串中使用
# shellcheck disable=SC2034
rc=$?
# shellcheck disable=SC2034
cfg="${V2BX_CONF_DIR}/config.json"
cp "${XBOARD_MOCK_LOG}" "${XBOARD_MOCK_LOG}.wizard"
check "向导返回成功" '[[ ${rc} -eq 0 ]]' || sed -n '1,200p' "${V2BX_CONF_DIR}/wizard.out"
for f in config.json route.json custom_outbound.json sing_origin.json; do
    check "${f} 为合法 JSON" 'jq empty "${V2BX_CONF_DIR}/${f}"'
done
check "生成 3 个节点（跳过不存在的节点）" '[[ $(jq ".Nodes|length" "${cfg}") -eq 3 ]]'
check "通讯密钥特殊字符原样保存" '[[ "$(jq -r ".Nodes[0].ApiKey" "${cfg}")" == "${token}" ]]'
check "全局通讯密钥模式不写 MachineID" '[[ "$(jq "[.Nodes[]|has(\"MachineID\")]|any" "${cfg}")" == false ]]'
check "全局通讯密钥模式只请求 v1 接口" '! grep -q "/api/v2/" "${XBOARD_MOCK_LOG}.wizard"'
check "ApiHost 已规范化" '[[ "$(jq -r ".Nodes[0].ApiHost" "${cfg}")" == "http://127.0.0.1:${port}" ]]'
check "reality 节点 CertMode=none" '[[ "$(jq -r ".Nodes[0].CertConfig.CertMode" "${cfg}")" == none ]]'
check "sing 使用正确键名 EnableTFO，不写无效的嗅探键" '[[ "$(jq ".Nodes[0]|has(\"EnableTFO\")" "${cfg}")" == true && "$(jq ".Nodes[0]|has(\"EnableSniff\") or has(\"SniffEnabled\")" "${cfg}")" == false ]]'
# sing 内核的嗅探只由 sing_origin.json 的路由规则决定（sing 在 check 的 eval 字符串中使用）
# shellcheck disable=SC2034
sing="${V2BX_CONF_DIR}/sing_origin.json"
check "sing_origin 第一条规则是 sniff 动作" '[[ "$(jq -r ".route.rules[0].action" "${sing}")" == sniff ]]'
check "sing_origin 屏蔽 BT 用 reject" '[[ "$(jq -r "[.route.rules[]|select(.protocol==[\"bittorrent\"])][0].action" "${sing}")" == reject ]]'
check "sing_origin 不再使用 block 出站" '! grep -q "\"block\"" "${sing}"'
check "sing_origin DNS 使用新写法" '[[ "$(jq -r ".dns.servers[0].type" "${sing}")" == udp && "$(jq ".dns.servers[0]|has(\"address\")" "${sing}")" == false ]]'
check "启用审计时 sing_origin 含 domain_regex reject" '[[ "$(jq -r "[.route.rules[]|select(.domain_regex)][0].action" "${sing}")" == reject ]]'
# xray：连接策略、DNS 路径，以及节点里不再写无效的 DNSType
check "xray 核心写入 XrayConnectionConfig（connIdle 120/300）" '[[ "$(jq ".Cores[]|select(.Type==\"xray\").XrayConnectionConfig.connIdle" "${cfg}")" =~ ^(120|300)$ ]]'
check "xray 核心引用 dns.json" '[[ "$(jq -r ".Cores[]|select(.Type==\"xray\").DnsConfigPath" "${cfg}")" == "${V2BX_CONF_DIR}/dns.json" ]] && jq empty "${V2BX_CONF_DIR}/dns.json"'
check "xray 节点不写无效的 DNSType" '[[ "$(jq "[.Nodes[]|select(.Core==\"xray\")|has(\"DNSType\")]|any" "${cfg}")" == false ]]'
check "hy2config 解析器为 udp 且以 direct(all) 结尾" 'grep -q "^  type: udp" "${V2BX_CONF_DIR}/hy2config.yaml" && [[ "$(grep -E "^    - " "${V2BX_CONF_DIR}/hy2config.yaml" | tail -n 1)" == "    - direct(all)" ]]'
check "hy2config 不写不生效的 initStreamReceiveWindow" '! grep -q initStreamReceiveWindow "${V2BX_CONF_DIR}/hy2config.yaml"'

# 按 IPv6 情况生成：分别强制「无 IPv6」「有 IPv6」各生成一次
gen_variant() {   # usage: gen_variant 0|1 DIR
    ( v6flag="$1"
      check_ipv6_support() { echo "${v6flag}"; }
      # shellcheck disable=SC2034  # 被 source 进来的 write_* 函数使用
      CONF_DIR="$2"
      write_xray_dns_json; write_custom_outbound_json; write_route_json n
      write_sing_origin_json n; write_hy2_config )
}
v4dir="${V2BX_CONF_DIR}/variant-v4"; v6dir="${V2BX_CONF_DIR}/variant-v6"
mkdir -p "${v4dir}" "${v6dir}"
gen_variant 0 "${v4dir}"; gen_variant 1 "${v6dir}"
# shellcheck disable=SC2034
q='.[0].settings.domainStrategy'
check "无 IPv6：xray DNS 只查 IPv4、默认出站 UseIPv4" '[[ "$(jq -r .queryStrategy "${v4dir}/dns.json")" == UseIPv4 && "$(jq -r "${q}" "${v4dir}/custom_outbound.json")" == UseIPv4 ]]'
check "无 IPv6：xray 路由屏蔽 ::/0" '[[ "$(jq "[.rules[]|select(.ip==[\"::/0\"])]|length" "${v4dir}/route.json")" -eq 1 ]]'
check "无 IPv6：hy2 出站 mode 4 并拒绝 ::/0" 'grep -q "mode: \"4\"" "${v4dir}/hy2config.yaml" && grep -q "reject(::/0)" "${v4dir}/hy2config.yaml"'
check "无 IPv6：sing_origin ipv4_only 并拒绝 ::/0" '[[ "$(jq -r .dns.strategy "${v4dir}/sing_origin.json")" == ipv4_only && "$(jq "[.route.rules[]|select(.ip_cidr==[\"::/0\"])]|length" "${v4dir}/sing_origin.json")" -eq 1 ]]'
check "有 IPv6：xray DNS UseIP、默认出站 UseIPv4v6" '[[ "$(jq -r .queryStrategy "${v6dir}/dns.json")" == UseIP && "$(jq -r "${q}" "${v6dir}/custom_outbound.json")" == UseIPv4v6 ]]'
check "有 IPv6：xray 路由不屏蔽 ::/0" '[[ "$(jq "[.rules[]|select(.ip==[\"::/0\"])]|length" "${v6dir}/route.json")" -eq 0 ]]'
check "有 IPv6：hy2 出站 mode 46 且不拒绝 ::/0" 'grep -q "mode: \"46\"" "${v6dir}/hy2config.yaml" && ! grep -q "reject(::/0)" "${v6dir}/hy2config.yaml"'
check "有 IPv6：sing_origin prefer_ipv4 且不拒绝 ::/0" '[[ "$(jq -r .dns.strategy "${v6dir}/sing_origin.json")" == prefer_ipv4 && "$(jq "[.route.rules[]|select(.ip_cidr)]|length" "${v6dir}/sing_origin.json")" -eq 0 ]]'
for f in dns.json custom_outbound.json route.json sing_origin.json; do
    check "两种 IPv6 情况下 ${f} 均为合法 JSON" 'jq empty "${v4dir}/${f}" && jq empty "${v6dir}/${f}"'
done
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
printf '%s\n' y "http://127.0.0.1:${port}" 1 "${token}" y 2 1 2 n n | generate_config_file >/dev/null 2>&1
check "重新生成时备份旧 config.json" 'ls "${V2BX_CONF_DIR}"/config.json.bak.* >/dev/null 2>&1'
check "未启用审计时 route.json 无域名规则" '[[ $(jq "[.rules[]|select(.domain)]|length" "${V2BX_CONF_DIR}/route.json") -eq 0 ]]'
check "未启用审计时 sing_origin 合法且无 domain_regex" 'jq empty "${sing}" && [[ $(jq "[.route.rules[]|select(.domain_regex)]|length" "${sing}") -eq 0 ]]'

# --- 对接检测 ---
xboard_check_config > "${V2BX_CONF_DIR}/check.out" 2>&1
check "xboard_check_config 通过" '[[ $? -eq 0 ]]' || cat "${V2BX_CONF_DIR}/check.out"

# --- 向导：机器令牌 ---
mdir="${V2BX_CONF_DIR}/machine"
mkdir -p "${mdir}"
manswers=(
    y                                   # 确定继续
    "http://127.0.0.1:${port}"          # 面板地址
    2                                   # 鉴权方式：机器令牌
    0 abc 7                             # MachineID：非法输入被重新询问
    "${mtoken}"                         # 机器令牌
    y                                   # 后续节点使用相同的面板与令牌
    2 1 2                               # 节点1: sing / ID 1 / vless (reality)
    y                                   # 继续添加
    3 2                                 # 节点2: hysteria2 内核 / ID 2
    2 "" "" "" 'cf"tok\en'              # dns 证书
    y                                   # 继续添加
    1 3 4 n                             # 节点3: 未绑定到机器 -> 不继续 -> 跳过
    n                                   # 不再添加
    n                                   # 不启用审计列表
)
: > "${XBOARD_MOCK_LOG}"
# shellcheck disable=SC2034  # CONF_DIR 被 source 进来的函数使用
( CONF_DIR="${mdir}"; printf '%s\n' "${manswers[@]}" | generate_config_file ) > "${mdir}/wizard.out" 2>&1
# shellcheck disable=SC2034
rc=$?
# shellcheck disable=SC2034
mcfg="${mdir}/config.json"
check "机器令牌向导返回成功" '[[ ${rc} -eq 0 ]]' || sed -n '1,200p' "${mdir}/wizard.out"
check "机器令牌 config.json 为合法 JSON" 'jq empty "${mcfg}"'
check "机器令牌：生成 2 个节点（跳过未绑定的节点）" '[[ $(jq ".Nodes|length" "${mcfg}") -eq 2 ]]'
check "机器令牌：每个节点写入 MachineID 7（数字）" '[[ "$(jq -c "[.Nodes[].MachineID]" "${mcfg}")" == "[7,7]" ]]'
check "机器令牌：ApiKey 为机器令牌（特殊字符原样保存）" '[[ "$(jq -r ".Nodes[0].ApiKey" "${mcfg}")" == "${mtoken}" && "$(jq -r ".Nodes[1].ApiKey" "${mcfg}")" == "${mtoken}" ]]'
check "机器令牌：NodeID 为数字" '[[ "$(jq -c "[.Nodes[].NodeID]" "${mcfg}")" == "[1,2]" ]]'
check "机器令牌：非法 MachineID 被拒绝" '[[ $(grep -c "机器 ID 必须是正整数" "${mdir}/wizard.out") -eq 2 ]]'
check "机器令牌：提示核心版本要求与数字 NodeID" 'grep -q "feat/xboard-machine-token" "${mdir}/wizard.out" && grep -q "b1e8646" "${mdir}/wizard.out" && grep -q "不支持节点 code" "${mdir}/wizard.out"'
check "机器令牌：未绑定节点给出原因" 'grep -q "节点不在该机器上" "${mdir}/wizard.out"'
check "机器令牌：向导只请求 v2 接口且不带 node_type" '! grep -q "/api/v1/" "${XBOARD_MOCK_LOG}" && ! grep -q node_type "${XBOARD_MOCK_LOG}" && [[ $(grep -c "^GET /api/v2/server/config?machine_id=7&" "${XBOARD_MOCK_LOG}") -eq 3 ]]'
check "机器令牌未出现在向导输出中" '! grep -qF "${mtoken}" "${mdir}/wizard.out"'
check "机器令牌 config.json 权限 600" '[[ "$(perm "${mcfg}")" == 600 ]]'

# shellcheck disable=SC2034  # CONF_DIR 被 source 进来的函数使用
( CONF_DIR="${mdir}"; xboard_check_config ) > "${mdir}/check.out" 2>&1
check "机器令牌：xboard_check_config 通过" '[[ $? -eq 0 ]] && grep -q "机器=7" "${mdir}/check.out"' || cat "${mdir}/check.out"

# --- V2bX check：机器令牌的各种错误（含嵌套 ApiConfig 写法） ---
cdir="${V2BX_CONF_DIR}/machine-check"
mkdir -p "${cdir}"
jq --arg h "http://127.0.0.1:${port}" --arg k "${mtoken}" '
  .Nodes = [
    (.Nodes[0] | .MachineID = 8 | .ApiKey = "disabled-machine-token-00000000"),  # 停用的机器
    (.Nodes[0] | .NodeID = 3 | .NodeType = "trojan"),               # 未绑定的节点
    (.Nodes[0] | .ApiKey = "wrong-machine-token-xxxxxxxxxxxx"),     # 令牌错误
    {Core: "sing", ApiConfig: {ApiHost: $h, ApiKey: $k, NodeID: 1, NodeType: "vless", MachineID: 7}},
    (.Nodes[0] | .MachineID = "x7"),                                # 非法 MachineID
    (.Nodes[0] | .NodeID = "node-code")                             # 节点 code
  ]' "${mcfg}" > "${cdir}/config.json"
# shellcheck disable=SC2034  # CONF_DIR 被 source 进来的函数使用
( CONF_DIR="${cdir}"; xboard_check_config ) > "${cdir}/check.out" 2>&1
check "机器令牌检测：存在失败节点时返回非 0" '[[ $? -ne 0 ]]'
check "机器令牌检测：识别停用的机器" 'grep -q "机器 8 已在 Xboard 中停用" "${cdir}/check.out"'
check "机器令牌检测：识别未绑定的节点" 'grep -q "节点不在该机器上：请确认节点 ID 3" "${cdir}/check.out"'
check "机器令牌检测：识别错误令牌" 'grep -q "机器 ID 或机器令牌错误" "${cdir}/check.out"'
check "机器令牌检测：支持嵌套 ApiConfig 中的 MachineID" '[[ $(grep -c "对接正常" "${cdir}/check.out") -eq 1 ]]'
check "机器令牌检测：拒绝非数字 MachineID" 'grep -q "MachineID 必须是正整数" "${cdir}/check.out"'
check "机器令牌检测：拒绝节点 code" 'grep -q "不支持节点 code" "${cdir}/check.out"'
check "机器令牌检测输出中不含令牌" '! grep -qF "${mtoken}" "${cdir}/check.out"'

exit ${fail}

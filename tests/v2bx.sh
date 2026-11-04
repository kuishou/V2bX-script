#!/bin/bash
# 离线测试 V2bX.sh 管理脚本中的函数（不需要 root，不访问网络，不改动系统）。
# usage: bash tests/v2bx.sh /path/to/V2bX.sh
# shellcheck disable=SC2034,SC2317,SC2329  # 变量/函数由被测脚本使用或间接调用
set -u
script=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

export V2BX_SOURCE_ONLY=1 V2BX_BIN="${work}/bin/V2bX" V2BX_HOME="${work}/home"
mkdir -p "${work}/bin" "${work}/fake"

# shellcheck source=/dev/null
source "${script}"
check "V2BX_SOURCE_ONLY=1 只加载函数" '[[ "$(type -t open_ports)" == function ]]'

# 菜单交互在测试中不执行
before_show_menu() { :; }

# --- open_ports：输入校验与规范化（用假的 iptables 记录调用） ---
cat > "${work}/fake/iptables" <<'EOF'
#!/bin/sh
[ "$1" = "-C" ] && exit 1
echo "$(basename "$0") $*" >> "${FAKE_LOG}"
EOF
cp "${work}/fake/iptables" "${work}/fake/ip6tables"
chmod +x "${work}/fake/"*
export FAKE_LOG="${work}/fw.log"

run_ports() {   # usage: run_ports "输入"  -> 输出写到 ${work}/op.out，规则写到 FAKE_LOG
    : > "${FAKE_LOG}"
    printf '%s\n' "$1" | PATH="${work}/fake:/usr/bin:/bin" open_ports > "${work}/op.out" 2>&1
}
run_ports "08 443"
check "端口 08 按十进制解析为 8，无报错" 'grep -q -- "--dport 8 " "${FAKE_LOG}" && ! grep -q "value too great" "${work}/op.out"'
check "TCP/UDP × IPv4/IPv6 都放行" '[[ $(grep -c -- "--dport 443 " "${FAKE_LOG}") -eq 4 ]]'
run_ports "20000-20100,009"
check "端口范围转换为 iptables 写法" 'grep -q -- "--dport 20000:20100 " "${FAKE_LOG}" && grep -q -- "--dport 9 " "${FAKE_LOG}"'
for bad_in in "200-100" "0" "70000" "abc" "1-70000"; do
    run_ports "${bad_in}"
    check "拒绝非法端口 ${bad_in}" '[[ ! -s "${FAKE_LOG}" ]] && grep -qE "格式错误|超出范围" "${work}/op.out"'
done
run_ports ""
check "未输入端口时不调用防火墙" '[[ ! -s "${FAKE_LOG}" ]] && grep -q "未输入端口" "${work}/op.out"'

# --- update_shell：成功 / 失败路径 ---
# 本脚本定义了 install() 函数；若误调用会运行安装脚本，这里让它直接报错
run_install_script() { echo "BUG: run_install_script called" >&2; return 99; }

echo "old" > "${V2BX_BIN}"
fetch_tls() { printf '#!/bin/bash\necho new-v2bx\n' > "$2"; }
load_initconfig() { echo "load" >> "${work}/load.log"; return 0; }
( update_shell ) > "${work}/us.out" 2>&1
check "update_shell 成功时返回 0" '[[ $? -eq 0 ]] && grep -q "升级脚本成功" "${work}/us.out"'
check "update_shell 写入新脚本且权限 755" 'grep -q new-v2bx "${V2BX_BIN}" && [[ "$(stat -c %a "${V2BX_BIN}")" == 755 ]]'
check "update_shell 没有误调用 install() 函数" '! grep -q "BUG" "${work}/us.out"'
check "未安装 V2bX 时不更新配置向导、也不报失败" '[[ ! -e "${work}/load.log" ]] && ! grep -q "失败" "${work}/us.out"'

mkdir -p "${V2BX_HOME}"; echo "stale" > "${V2BX_HOME}/initconfig.sh"
( update_shell ) > "${work}/us.out" 2>&1
check "已安装时删除旧向导并重新加载" '[[ $? -eq 0 && ! -e "${V2BX_HOME}/initconfig.sh" && -s "${work}/load.log" ]]'

echo "old" > "${V2BX_BIN}"
fetch_tls() { printf 'if then fi (\n' > "$2"; }
( update_shell ) > "${work}/us.out" 2>&1
check "下载内容语法错误时不覆盖旧脚本" '[[ $? -ne 0 && "$(cat "${V2BX_BIN}")" == old ]] && grep -q "下载脚本失败" "${work}/us.out"'
fetch_tls() { return 22; }
( update_shell ) > "${work}/us.out" 2>&1
check "下载失败时不覆盖旧脚本" '[[ $? -ne 0 && "$(cat "${V2BX_BIN}")" == old ]]'

# --- load_initconfig：缺失时下载并安装到 V2BX_HOME（不得调用 install() 函数） ---
unset -f load_initconfig
# shellcheck source=/dev/null
source "${script}"
before_show_menu() { :; }
run_install_script() { echo "BUG: run_install_script called" >&2; return 99; }
rm -rf "${V2BX_HOME}"
fetch_tls() { printf 'initconfig_loaded_marker() { :; }\n' > "$2"; }
load_initconfig > "${work}/li.out" 2>&1
check "load_initconfig 下载后安装为 644 并加载" '[[ $? -eq 0 && "$(stat -c %a "${V2BX_HOME}/initconfig.sh")" == 644 && "$(type -t initconfig_loaded_marker)" == function ]]'
check "load_initconfig 没有误调用 install() 函数" '! grep -q "BUG" "${work}/li.out"'

exit ${fail}

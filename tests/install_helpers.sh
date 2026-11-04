#!/bin/bash
# 离线测试 install.sh 中不涉及网络/系统改动的辅助函数。
# usage: bash tests/install_helpers.sh /path/to/install.sh
# shellcheck disable=SC1090
V2BX_INSTALL_SOURCE_ONLY=1 source "$1"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
tmp=$(mktemp -d)
mkdir -p "${tmp}/old" "${tmp}/stage"

# --- keep_old_initconfig：新向导下载失败时沿用旧版本 ---
echo "old-wizard" > "${tmp}/old/initconfig.sh"
keep_old_initconfig "${tmp}/stage" "${tmp}/old" > "${tmp}/out" 2>&1
check "新向导缺失时沿用旧版本" '[[ "$(cat "${tmp}/stage/initconfig.sh")" == old-wizard ]] && grep -q "沿用已安装的旧版本" "${tmp}/out"'

echo "new-wizard" > "${tmp}/stage/initconfig.sh"
keep_old_initconfig "${tmp}/stage" "${tmp}/old" > "${tmp}/out" 2>&1
check "新向导下载成功时不被旧版本覆盖" '[[ "$(cat "${tmp}/stage/initconfig.sh")" == new-wizard && ! -s "${tmp}/out" ]]'

rm -f "${tmp}/stage/initconfig.sh" "${tmp}/old/initconfig.sh"
keep_old_initconfig "${tmp}/stage" "${tmp}/old" > "${tmp}/out" 2>&1
check "首次安装（没有旧版本）时什么也不做" '[[ ! -e "${tmp}/stage/initconfig.sh" && ! -s "${tmp}/out" ]]'

# --- valid_version：用户输入的版本号会拼进下载 URL ---
for v in v0.1.2 0.1.2 v1.0.0-rc1; do
    check "接受版本号 ${v}" 'valid_version "${v}"'
done
for v in "" "../x" "v1/2" "v1 2" '$(id)' "-v1"; do
    check "拒绝版本号 '${v}'" '! valid_version "${v}"'
done

rm -rf "${tmp}"
exit ${fail}

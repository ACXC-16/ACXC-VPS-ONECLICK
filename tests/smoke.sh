#!/usr/bin/env bash
# =============================================================================
#  tests/smoke.sh —— vps-init 冒烟测试
#
#  特点：全部在 --dry-run 下运行，不修改系统，可以在本地或 CI 里安全执行。
#  用法：bash tests/smoke.sh      （退出码 0 = 全部通过）
# =============================================================================
set -u

export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAKE="$WORK/fakessh"
MISSING="$WORK/fakessh-missing"
mkdir -p "$FAKE/sshd_config.d" "$MISSING" || exit 1
printf 'Port 22\nPermitRootLogin prohibit-password\nPasswordAuthentication no\n' >"$FAKE/sshd_config"

# 造两份把 /etc/ssh 指向测试目录的副本，避免在测试机上真的动 SSH 配置
sed -e "s|/etc/ssh/sshd_config\.d|${FAKE}/sshd_config.d|g" \
    -e "s|/etc/ssh/sshd_config|${FAKE}/sshd_config|g" \
    "$ROOT/init.sh" >"$WORK/init-fake.sh"
sed -e "s|/etc/ssh/sshd_config\.d|${MISSING}/sshd_config.d|g" \
    -e "s|/etc/ssh/sshd_config|${MISSING}/sshd_config|g" \
    "$ROOT/init.sh" >"$WORK/init-missing.sh"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf '  [通过] %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  [失败] %s\n' "$1"; }
check() { # $1=说明 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $2，实际 $3）"; fi
}
check_has() { # $1=说明 $2=输出文件 $3=关键字
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1（输出里没找到「$3」）"; fi
}

run_case() { # $1=输出文件，其余为参数；把 stdin 透传进去
  local out="$1"; shift
  VPS_INIT_ALLOW_NONROOT=1 bash "$@" >"$out" 2>&1
  printf '%s' "$?"
}

echo "== 0) 语法检查 =="
if bash -n "$ROOT/init.sh"; then ok "bash -n init.sh"; else bad "bash -n init.sh"; fi
if bash -n "$ROOT/tests/smoke.sh"; then ok "bash -n tests/smoke.sh"; else bad "bash -n tests/smoke.sh"; fi

echo "== 1) --help / --list / --version =="
rc="$(run_case "$WORK/help.out" "$ROOT/init.sh" --help)"
check "--help 退出码" "0" "$rc"
check_has "--help 含用法" "$WORK/help.out" "用法:"
rc="$(run_case "$WORK/list.out" "$ROOT/init.sh" --list)"
check "--list 退出码" "0" "$rc"
check_has "--list 列出 sysupdate" "$WORK/list.out" "sysupdate"
rc="$(run_case "$WORK/ver.out" "$ROOT/init.sh" --version)"
check "--version 退出码" "0" "$rc"

echo "== 2) 端口校验循环：abc / 70000 应被拒绝，52052 通过 =="
rc="$(printf 'y\nabc\n70000\n52052\ny\n' | run_case "$WORK/a.out" "$WORK/init-fake.sh" --force --dry-run --only ssh-port)"
check "退出码" "0" "$rc"
check_has "提示端口非法" "$WORK/a.out" "端口必须是 1-65535 之间的数字"
check_has "写入新端口" "$WORK/a.out" "Port 52052"
check_has "过渡期保留旧端口" "$WORK/a.out" "Port 22"
check_has "给出安全操作提示" "$WORK/a.out" "安全组"

echo "== 3) --port 2222 + --yes 无人值守 =="
rc="$(run_case "$WORK/b.out" "$WORK/init-fake.sh" --force --dry-run --yes --port 2222 --only ssh-port)"
check "退出码" "0" "$rc"
check_has "使用指定端口" "$WORK/b.out" "Port 2222"

echo "== 4) --port 越界应报错 =="
rc="$(run_case "$WORK/bad.out" "$WORK/init-fake.sh" --force --dry-run --yes --port 99999 --only ssh-port)"
check "退出码" "1" "$rc"
check_has "报端口不合法" "$WORK/bad.out" "端口不合法"

echo "== 5) root 密码：自动生成随机密码 =="
rc="$(run_case "$WORK/c.out" "$WORK/init-fake.sh" --force --dry-run --yes --only root-passwd)"
check "退出码" "0" "$rc"
check_has "dry-run 拦住 chpasswd" "$WORK/c.out" "chpasswd"

echo "== 6) root 密码：两次输入不一致应重试 =="
rc="$(printf 'y\nn\nabc12345\nxyz98765\nTestPass123\nTestPass123\n' |
  run_case "$WORK/i.out" "$WORK/init-fake.sh" --force --dry-run --only root-passwd)"
check "退出码" "0" "$rc"
check_has "提示两次不一致" "$WORK/i.out" "两次输入不一致"

echo "== 7) 交互式挑步骤：只选 tuning =="
rc="$(printf 'n\nn\nn\nn\ny\nn\ny\nn\nn\nn\n' | run_case "$WORK/d.out" "$WORK/init-fake.sh" --force --dry-run)"
check "退出码" "0" "$rc"
check_has "只执行 tuning" "$WORK/d.out" "时区 / Swap / BBR 网络加速"
check_has "跳过了 sysupdate" "$WORK/d.out" "已跳过：更新系统软件包与内核/驱动"

echo "== 8) 步骤失败要如实汇总并返回 1 =="
rc="$(run_case "$WORK/e.out" "$WORK/init-missing.sh" --force --dry-run --yes --only ssh-port)"
check "退出码" "1" "$rc"
check_has "汇总里有失败项" "$WORK/e.out" "[失败]"

echo "== 9) 参数校验 =="
rc="$(run_case "$WORK/f.out" "$WORK/init-fake.sh" --force --dry-run --yes --only nope)"
check "--only 未知步骤仍可运行" "0" "$rc"
check_has "提示步骤不存在" "$WORK/f.out" "--only 里的步骤不存在"
rc="$(run_case "$WORK/g.out" "$WORK/init-fake.sh" --bogus)"
check "未知参数退出码" "2" "$rc"
check_has "提示未知参数" "$WORK/g.out" "未知参数"
rc="$(run_case "$WORK/h.out" "$ROOT/init.sh" --port)"
check "--port 缺参数退出码" "1" "$rc"

echo "== 10) 受管配置回读（跨次运行不互相覆盖） =="
cat >"$FAKE/sshd_config.d/00-vps-init.conf" <<'EOF'
# --- vps-init managed block: start ---
Port 52052
Port 22
PermitRootLogin yes
# --- vps-init managed block: end ---
EOF
{
  printf 'MANAGED_SSHD_CONF=%s\n' "$FAKE/sshd_config.d/00-vps-init.conf"
  sed -n '/^ssh_load_managed() {/,/^}/p' "$ROOT/init.sh"
  printf 'ssh_load_managed\n'
  # shellcheck disable=SC2016  # 这里要生成字面量 %s，故意用单引号
  printf 'printf "PORTS=[%%s] PRL=[%%s] PA=[%%s]\\n" "$SSH_M_PORTS" "$SSH_M_PERMIT_ROOT_LOGIN" "$SSH_M_PASSWORD_AUTH"\n'
} >"$WORK/unit.sh"
bash "$WORK/unit.sh" >"$WORK/unit.out" 2>&1
check_has "回读端口列表" "$WORK/unit.out" "PORTS=[52052 22]"
check_has "回读 PermitRootLogin" "$WORK/unit.out" "PRL=[yes]"

echo
printf '结果：通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0

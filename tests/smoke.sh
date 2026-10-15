#!/usr/bin/env bash
# =============================================================================
#  tests/smoke.sh —— vps-init 冒烟测试
#
#  特点：全部在 --dry-run 下运行，不修改系统，可以在本地或 CI 里安全执行。
#  用法：bash tests/smoke.sh      （退出码 0 = 全部通过）
#
#  在 GitHub Actions 里运行时，每个失败项会额外抛出 ::error:: 注解，
#  这样失败原因可以直接在仓库的 Checks / Annotations 里看到，不必翻日志。
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
CUR_OUT=""

one_line() { printf '%s' "$1" | tr '\n' ' '; }

# 从输出文件里挑出最有信息量的几行，用于注解
diag() {
  grep -E '\[错误\]|\[注意\]|Port |退出码|dry-run' "$1" 2>/dev/null |
    tail -n 4 | tr '\n' '|' | sed 's/|/ | /g' | cut -c1-600
}

ok() { PASS=$((PASS + 1)); printf '  [通过] %s\n' "$1"; }

bad() {
  FAIL=$((FAIL + 1))
  printf '  [失败] %s\n' "$1"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error title=冒烟测试失败::%s\n' "$(one_line "$1")"
    if [ -n "$CUR_OUT" ] && [ -f "$CUR_OUT" ]; then
      printf '::error title=相关输出::%s\n' "$(diag "$CUR_OUT")"
    fi
  fi
}

check() { # $1=说明 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $2，实际 $3）"; fi
}

check_has() { # $1=说明 $2=输出文件 $3=关键字
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1（输出里没找到「$3」）"; fi
}

run_case() { # $1=输出文件，其余为参数；stdin 透传给被测脚本
  local out="$1"
  shift
  VPS_INIT_FORCE_STDIN=1 VPS_INIT_ALLOW_NONROOT=1 bash "$@" >"$out" 2>&1
  printf '%s' "$?"
}

echo "== 0) 语法检查 =="
if bash -n "$ROOT/init.sh"; then ok "bash -n init.sh"; else bad "bash -n init.sh"; fi
if bash -n "$ROOT/tests/smoke.sh"; then ok "bash -n tests/smoke.sh"; else bad "bash -n tests/smoke.sh"; fi

echo "== 1) --help / --list / --version =="
CUR_OUT="$WORK/help.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --help)"
check "--help 退出码" "0" "$rc"
check_has "--help 含用法" "$CUR_OUT" "用法:"
CUR_OUT="$WORK/list.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --list)"
check "--list 退出码" "0" "$rc"
check_has "--list 列出 sysupdate" "$CUR_OUT" "sysupdate"
CUR_OUT="$WORK/ver.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --version)"
check "--version 退出码" "0" "$rc"

echo "== 2) 端口校验循环：abc / 70000 应被拒绝，52052 通过 =="
CUR_OUT="$WORK/a.out"
rc="$(printf 'y\nabc\n70000\n52052\ny\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --only ssh-port)"
check "退出码" "0" "$rc"
check_has "提示端口非法" "$CUR_OUT" "端口必须是 1-65535 之间的数字"
check_has "写入新端口" "$CUR_OUT" "Port 52052"
check_has "过渡期保留旧端口" "$CUR_OUT" "Port 22"
check_has "给出安全操作提示" "$CUR_OUT" "安全组"

echo "== 3) --port 2222 + --yes 无人值守 =="
CUR_OUT="$WORK/b.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --port 2222 --only ssh-port)"
check "退出码" "0" "$rc"
check_has "使用指定端口" "$CUR_OUT" "Port 2222"

echo "== 4) --port 越界应报错 =="
CUR_OUT="$WORK/bad.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --port 99999 --only ssh-port)"
check "退出码" "1" "$rc"
check_has "报端口不合法" "$CUR_OUT" "端口不合法"

echo "== 5) root 密码：自动生成随机密码 =="
CUR_OUT="$WORK/c.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only root-passwd)"
check "退出码" "0" "$rc"
check_has "dry-run 拦住 chpasswd" "$CUR_OUT" "chpasswd"

echo "== 6) root 密码：两次输入不一致应重试 =="
CUR_OUT="$WORK/i.out"
rc="$(printf 'y\nn\nabc12345\nxyz98765\nTestPass123\nTestPass123\n' |
  run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --only root-passwd)"
check "退出码" "0" "$rc"
check_has "提示两次不一致" "$CUR_OUT" "两次输入不一致"

echo "== 7) 交互式挑步骤：只选 tuning =="
CUR_OUT="$WORK/d.out"
rc="$(printf 'n\nn\nn\nn\ny\nn\ny\nn\nn\nn\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "退出码" "0" "$rc"
check_has "只执行 tuning" "$CUR_OUT" "时区 / Swap / BBR 网络加速"
check_has "跳过了 sysupdate" "$CUR_OUT" "已跳过：只更新内核 / 驱动 / 固件"

echo "== 8) 步骤失败要如实汇总并返回 1 =="
CUR_OUT="$WORK/e.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-missing.sh" --force --dry-run --yes --only ssh-port)"
check "退出码" "1" "$rc"
check_has "汇总里有失败项" "$CUR_OUT" "[失败]"

echo "== 9) 参数校验 =="
CUR_OUT="$WORK/f.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only nope)"
check "--only 未知步骤仍可运行" "0" "$rc"
check_has "提示步骤不存在" "$CUR_OUT" "--only 里的步骤不存在"
CUR_OUT="$WORK/g.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --bogus)"
check "未知参数退出码" "2" "$rc"
check_has "提示未知参数" "$CUR_OUT" "未知参数"
CUR_OUT="$WORK/h.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --port)"
check "--port 缺参数退出码" "1" "$rc"

echo "== 10) 受管配置回读（跨次运行不互相覆盖） =="
CUR_OUT="$WORK/unit.out"
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
bash "$WORK/unit.sh" >"$CUR_OUT" 2>&1
check_has "回读端口列表" "$CUR_OUT" "PORTS=[52052 22]"
check_has "回读 PermitRootLogin" "$CUR_OUT" "PRL=[yes]"

echo "== 11) sysupdate 默认只动内核/驱动，其它软件包不动 =="
CUR_OUT="$WORK/k.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only sysupdate)"
check "退出码" "0" "$rc"
check_has "明确只升级内核/驱动/固件" "$CUR_OUT" "只升级内核 / 驱动 / 固件"
check_has "全量升级默认不执行" "$CUR_OUT" "保持不动：本次不升级其它软件包"
check_has "清理默认不执行" "$CUR_OUT" "是否清理不再需要的依赖包（apt autoremove --purge）？ -> N"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "===== 失败项的输出（便于排查） ====="
  for f in "$WORK"/*.out; do
    [ -s "$f" ] || continue
    echo "--- $(basename "$f") ---"
    tail -n 20 "$f"
  done
fi

printf '结果：通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0

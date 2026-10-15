#!/usr/bin/env bash
# =============================================================================
#  tests/smoke.sh —— ACXC16-VPS新机一键脚本 冒烟测试
#
#  特点：全部在 --dry-run 下运行，不修改系统，可以在本地或 CI 里安全执行。
#  用法：bash tests/smoke.sh      （退出码 0 = 全部通过）
#
#  在 GitHub Actions 里运行时，每个失败项会额外抛出 ::error:: 注解，
#  失败原因可以直接在仓库的 Checks / Annotations 里看到，不必翻日志。
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

diag() {
  grep -E '\[错误\]|\[注意\]|\[信息\]|状态|步骤' "$1" 2>/dev/null |
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
  if grep -qF -- "$3" "$2"; then
    ok "$1"
  else
    # 附带文件里含脚本名的实际行，便于看出空格/字符差异
    local hint=""
    hint="$(grep -m2 'ACXC16' "$2" 2>/dev/null | tr -d '\r' | tr '\n' '|' | cut -c1-120)"
    if [ -n "$hint" ]; then
      bad "$1（输出里没找到「$3」；文件里的相关行：[$hint]）"
    else
      bad "$1（输出里没找到「$3」）"
    fi
  fi
}

check_hasnt() { # $1=说明 $2=输出文件 $3=不该出现的关键字
  if grep -qF -- "$3" "$2"; then bad "$1（不应出现「$3」）"; else ok "$1"; fi
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
check_has "--help 用新名字" "$CUR_OUT" "ACXC16-VPS新机一键脚本"
CUR_OUT="$WORK/list.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --list)"
check "--list 退出码" "0" "$rc"
check_has "--list 列出 sysupdate" "$CUR_OUT" "sysupdate"
CUR_OUT="$WORK/ver.out"
rc="$(run_case "$CUR_OUT" "$ROOT/init.sh" --version)"
check "--version 退出码" "0" "$rc"
check_has "--version 版本号" "$CUR_OUT" "v1.0.0"

echo "== 2) 端口校验循环：abc / 70000 应被拒绝，52052 通过 =="
CUR_OUT="$WORK/a.out"
rc="$(printf 'y\n2\nabc\n70000\n52052\n\nn\nTestPass123\nTestPass123\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --only access)"
check "退出码" "0" "$rc"
check_has "提示端口非法" "$CUR_OUT" "端口必须是 1-65535 之间的数字"
check_has "写入新端口" "$CUR_OUT" "Port 52052"
check_has "过渡期保留旧端口" "$CUR_OUT" "Port 22"
check_has "给出安全操作提示" "$CUR_OUT" "安全组"

echo "== 3) --port 2222 + --yes 无人值守 =="
CUR_OUT="$WORK/b.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --port 2222 --only access)"
check "退出码" "0" "$rc"
check_has "使用指定端口" "$CUR_OUT" "Port 2222"

echo "== 4) --port 越界应报错 =="
CUR_OUT="$WORK/bad-port.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --port 99999 --only access)"
check "退出码" "1" "$rc"
check_has "报端口不合法" "$CUR_OUT" "端口不合法"

echo "== 5) root 密码：无人值守默认不改，必须显式指定 =="
CUR_OUT="$WORK/c.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only access)"
check "退出码" "0" "$rc"
check_has "无人值守默认不改密码" "$CUR_OUT" "无人值守模式（--yes）不会自动修改 root 密码"
check_hasnt "没有执行 chpasswd" "$CUR_OUT" "chpasswd"

CUR_OUT="$WORK/c2.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --gen-password --only access)"
check "显式 --gen-password 退出码" "0" "$rc"
check_has "生成模式会执行 chpasswd" "$CUR_OUT" "chpasswd"
check_has "生成前会先显示密码" "$CUR_OUT" "即将设置的 root 随机密码"

CUR_OUT="$WORK/c3.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --password 'MySecret12345' --only access)"
check "显式 --password 退出码" "0" "$rc"
check_has "指定密码会执行 chpasswd" "$CUR_OUT" "chpasswd"
check_hasnt "命令行明文密码不打到输出里" "$CUR_OUT" "MySecret12345"

echo "== 6) root 密码：两次输入不一致应重试 =="
CUR_OUT="$WORK/i.out"
rc="$(printf 'y\n2\n\n\nn\nabc12345\nxyz98765\nTestPass123\nTestPass123\n' |
  run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --only access)"
check "退出码" "0" "$rc"
check_has "提示两次不一致" "$CUR_OUT" "两次输入不一致"

echo "== 7) 交互菜单：状态表 + 编号菜单，选 0 退出 =="
CUR_OUT="$WORK/menu0.out"
rc="$(printf '0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "退出码" "0" "$rc"
check_has "显示脚本名与版本" "$CUR_OUT" "ACXC16-VPS新机一键脚本  v1.0.0"
check_has "显示状态表表头" "$CUR_OUT" "项目"
check_has "显示操作菜单" "$CUR_OUT" "操作菜单"
check_has "菜单里有 1)" "$CUR_OUT" "1) 更新内核 / 驱动 / 固件"
check_has "菜单里有 0) 退出" "$CUR_OUT" "0) 退出"
check_has "菜单里有更新脚本项" "$CUR_OUT" "6) 更新脚本"
check_has "菜单里有系统信息项" "$CUR_OUT" "4) 查看系统信息"
check_has "菜单里有合并后的端口/密码项" "$CUR_OUT" "2) 修改 SSH 端口 / root 密码"
check_hasnt "已删除「全部按默认执行」" "$CUR_OUT" "全部按默认执行"
check_has "没做任何操作时如实说明" "$CUR_OUT" "本次没有执行任何操作"
check_hasnt "没有 whiptail 方框" "$CUR_OUT" "whiptail"

echo "== 8) 状态表内容：每项都有状态 =="
CUR_OUT="$WORK/status.out"
rc="$(printf '0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "退出码" "0" "$rc"
check_has "内核状态" "$CUR_OUT" "当前 "
check_has "SSH 端口状态" "$CUR_OUT" "当前端口 22"
check_has "端口/密码合并成一行" "$CUR_OUT" "修改 SSH 端口 / root 密码"
check_has "工具统计" "$CUR_OUT" "工具 "
check_has "Swap 状态" "$CUR_OUT" "Swap "
check_has "BBR 状态" "$CUR_OUT" "BBR "
check_has "合并且只有一个工具项" "$CUR_OUT" "安装常用工具 / BBR网络加速 / Swap"
check_hasnt "启动时不再打印系统信息" "$CUR_OUT" "==== 系统信息 ===="

echo "== 9) 菜单里的无效输入 / 方向键乱码 / 全角数字 =="
CUR_OUT="$WORK/menu-bad.out"
rc="$(printf 'x\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "无效输入后退出码" "0" "$rc"
check_has "提示无效选择" "$CUR_OUT" "无效的选择"

CUR_OUT="$WORK/menu-esc.out"
rc="$(printf '\033[A\033[B\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "方向键乱码后退出码" "0" "$rc"
check_has "提示没认出输入" "$CUR_OUT" "没认出输入来"

CUR_OUT="$WORK/menu-fw.out"
rc="$(printf '６\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "全角数字退出码" "0" "$rc"
check_has "全角 ６ 被识别为更新脚本" "$CUR_OUT" "正在读取最新版本"

echo "== 10) 菜单 5 = 系统信息，6 = 运行日志，7 = 更新脚本 =="
CUR_OUT="$WORK/menu-info.out"
rc="$(printf '4\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "查看系统信息退出码" "0" "$rc"
check_has "打印了系统信息" "$CUR_OUT" "==== 系统信息 ===="
CUR_OUT="$WORK/menu-log.out"
rc="$(printf '5\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "查看日志退出码" "0" "$rc"
check_has "打印了日志块" "$CUR_OUT" "最近 40 行日志"
CUR_OUT="$WORK/menu-update.out"
rc="$(printf '6\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "更新脚本退出码" "0" "$rc"
check_has "提示读取最新版本" "$CUR_OUT" "正在读取最新版本"
check_has "提示会更新本地缓存" "$CUR_OUT" "拉取最新版"

echo "== 11) --yes 无人值守：按默认项顺序跑（1 更新驱动、2 端口/密码）=="
CUR_OUT="$WORK/yes.out"
rc="$(printf 'n\nn\nn\nn\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes)"
check "无人值守退出码" "0" "$rc"
check_has "计划是 2 项（extras 默认 N）" "$CUR_OUT" "步骤 1/2"
check_has "第二项是端口/密码" "$CUR_OUT" "步骤 2/2"
check_has "无人值守不改密码" "$CUR_OUT" "无人值守模式（--yes）不会自动修改 root 密码"

echo "== 12) 步骤失败要如实汇总并返回 1 =="
CUR_OUT="$WORK/e.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-missing.sh" --force --dry-run --yes --only access)"
check "退出码" "1" "$rc"
check_has "汇总里有失败项" "$CUR_OUT" "[失败]"

echo "== 13) 参数校验 =="
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

echo "== 14) 受管 SSH 配置回读（跨次运行不互相覆盖） =="
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

echo "== 15) sysupdate 默认只动内核/驱动，其它软件包不动 =="
CUR_OUT="$WORK/k.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only sysupdate)"
check "退出码" "0" "$rc"
check_has "有刷新软件源这一步" "$CUR_OUT" "1/3 刷新软件源索引"
check_has "有重启检查这一步" "$CUR_OUT" "3/3 检查是否需要重启"
check_hasnt "不再问全量升级" "$CUR_OUT" "full-upgrade"
check_hasnt "不再问清理" "$CUR_OUT" "autoremove"

echo "== 16) 选 Y 立即重启：不再等 10 秒 =="
printf 'linux-base\n' >"$WORK/reboot-required"
printf 'libc6\n' >"$WORK/reboot-required.pkgs"
export VPS_INIT_REBOOT_REQUIRED="$WORK/reboot-required"
CUR_OUT="$WORK/reboot.out"
rc="$(printf '0\ny\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "重启流程退出码" "0" "$rc"
check_has "提示需要重启" "$CUR_OUT" "系统需要重启"
check_has "dry-run 下不真重启" "$CUR_OUT" "[dry-run] 将执行 reboot"
check_hasnt "不再等待 10 秒" "$CUR_OUT" "10 秒"
unset VPS_INIT_REBOOT_REQUIRED

echo "== 17) 真实 Ubuntu 的 /etc/os-release 不能污染脚本版本号 =="
mkdir -p "$WORK/fakeos"
cat >"$WORK/fakeos/os-release" <<'EOF'
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.1 LTS"
VERSION_ID="24.04"
EOF
sed "s|/etc/os-release|$WORK/fakeos/os-release|g" "$ROOT/init.sh" >"$WORK/init-os.sh"
CUR_OUT="$WORK/osrelease.out"
rc="$(printf '4\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-os.sh" --force --dry-run)"
check "退出码" "0" "$rc"
check_has "菜单 5 能读到 os-release 的系统名" "$CUR_OUT" "Ubuntu 24.04.1 LTS"
check_has "脚本版本号仍是 v1.0.0" "$CUR_OUT" "ACXC16-VPS新机一键脚本 v1.0.0"
check_hasnt "没把 Ubuntu 的 VERSION 当成脚本版本" "$CUR_OUT" "Noble Numbat"

echo "== 18) 菜单 3 = 工具子选项：只装选中的那一组 =="
CUR_OUT="$WORK/tools.out"
rc="$(printf '3\n1\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "工具子选项退出码" "0" "$rc"
check_has "列出了子选项" "$CUR_OUT" "基础组件（下载 / 证书 / 密钥）"
check_has "标了推荐项" "$CUR_OUT" "[推荐]"
check_has "只安装选中的一组" "$CUR_OUT" "install curl wget ca-certificates gnupg"
check_hasnt "没有装没选的那些" "$CUR_OUT" "install vim nano"
check_hasnt "没选 fail2ban 就不会装它" "$CUR_OUT" "install fail2ban"

echo "== 19) 菜单 3 选 fail2ban：走它自己的安装配置流程 =="
CUR_OUT="$WORK/tools-f2b.out"
rc="$(printf '3\n8\n\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "选 fail2ban 退出码" "0" "$rc"
check_has "开始安装 fail2ban" "$CUR_OUT" "安装配置 fail2ban…"

echo "== 20) 快捷命令 acxc：脚本启动时自动安装 =="
SCDIR="$WORK/bin-shortcut"
CACHE="$WORK/cache-shortcut"
CUR_OUT="$WORK/shortcut.out"
rc="$(printf '0\n' | VPS_INIT_SHORTCUT_DIR="$SCDIR" VPS_INIT_CACHE_DIR="$CACHE" run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run)"
check "启动自动装快捷命令退出码" "0" "$rc"
check_has "启动时提示快捷命令已就绪" "$CUR_OUT" "快捷命令已就绪"
if [ -x "$SCDIR/acxc" ]; then
  ok "生成了可执行的 acxc"
  check_has "acxc 指向本仓库的发布地址" "$SCDIR/acxc" "ACXC-16/ACXC-VPS-ONECLICK"
  # shellcheck disable=SC2016  # 这里就是要检查字面量
  check_has "acxc 会转发参数" "$SCDIR/acxc" 'exec bash "$CACHE" "$@"'
else
  bad "没有生成可执行的 acxc"
fi

echo "== 21) 结束界面要列出本次设置的 SSH 端口和 root 密码 =="
STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/chpasswd" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$STUB/chpasswd"
{
  sed -e 's|^main "\$@"$||' -e 's|^exit \$?$||' "$ROOT/init.sh"
  printf 'DRY_RUN=0\nASSUME_YES=0\nCOLOR_OFF=1\nLOG_FILE="%s"\nSCRIPT_VERSION="1.0.0"\n' "$WORK/summary.log"
  printf 'passwd_apply "%s" 0 >/dev/null 2>&1\n' "$(sed -n 's/^DEFAULT_ROOT_PASSWORD="\(.*\)"$/\1/p' "$ROOT/init.sh")"
  printf 'SSH_M_PORTS="52052"\nSSH_PORT_CHANGED="52052"\n'
  printf 'print_next_steps\n'
} >"$WORK/summary.sh"
CUR_OUT="$WORK/summary.out"
PATH="$STUB:$PATH" bash "$WORK/summary.sh" >"$CUR_OUT" 2>&1
check_has "结束界面列出了本次设置的 root 密码" "$CUR_OUT" "root 密码：acxc1616"
check_has "结束界面列出了本次设置的 SSH 端口" "$CUR_OUT" "SSH 端口：52052"
check_has "提示用新密码登录" "$CUR_OUT" "ssh -p 52052 root@"
check_has "明确日志不含明文密码" "$CUR_OUT" "不含明文密码"
check_hasnt "明文密码不会写进日志文件" "$WORK/summary.log" "acxc1616"

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

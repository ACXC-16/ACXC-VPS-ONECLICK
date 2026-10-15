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

echo "== 5) root 密码：无人值守默认不改，必须显式指定 =="
CUR_OUT="$WORK/c.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --only root-passwd)"
check "退出码" "0" "$rc"
check_has "无人值守默认不改密码" "$CUR_OUT" "无人值守模式（--yes）不会自动修改 root 密码"
if grep -qF 'chpasswd' "$CUR_OUT"; then bad "不应执行 chpasswd"; else ok "没有执行 chpasswd"; fi

CUR_OUT="$WORK/c2.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --gen-password --only root-passwd)"
check "显式 --gen-password 退出码" "0" "$rc"
check_has "生成模式会执行 chpasswd" "$CUR_OUT" "chpasswd"
check_has "生成前会先显示密码" "$CUR_OUT" "即将设置的 root 随机密码"

CUR_OUT="$WORK/c3.out"
rc="$(run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --yes --password 'MySecret12345' --only root-passwd)"
check "显式 --password 退出码" "0" "$rc"
check_has "指定密码会执行 chpasswd" "$CUR_OUT" "chpasswd"
if grep -qF 'MySecret12345' "$CUR_OUT"; then
  bad "命令行传入的明文密码不应出现在输出里"
else
  ok "明文密码没有被打到输出里"
fi

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

echo "== 12) 图形界面 --ui=whiptail：勾选 / 输入框 / 取消 =="
mkdir -p "$WORK/bin"
cat >"$WORK/bin/whiptail" <<'MOCK'
#!/usr/bin/env bash
# 测试用的 mock whiptail：不画界面，按顺序从 MOCK_ANSWERS 文件里取答案，
# 结果写到 stderr（与真实 whiptail 的约定一致）。
set -u
ANSWERS="${MOCK_ANSWERS:?需要设置 MOCK_ANSWERS}"
IDX_FILE="${MOCK_ANSWERS}.idx"
idx=0
[ -f "$IDX_FILE" ] && idx="$(cat "$IDX_FILE")"
idx=$((idx + 1))
printf '%s' "$idx" >"$IDX_FILE"
answer="$(sed -n "${idx}p" "$ANSWERS")"

type=""
title=""
text=""
prev=""
for a in "$@"; do
  case "$prev" in
    --yesno|--msgbox|--checklist|--inputbox|--passwordbox) text="$a" ;;
  esac
  case "$a" in
    --yesno) type=yesno ;;
    --inputbox|--passwordbox) type=input ;;
    --checklist) type=checklist ;;
    --msgbox) type=msgbox ;;
  esac
  [ "$prev" = "--title" ] && title="$a"
  prev="$a"
done

# 记一笔"弹过什么框、写了什么"，便于断言
if [ -n "${MOCK_LOG:-}" ]; then
  printf '%s|%s|%s\n' "$type" "$title" "$text" >>"$MOCK_LOG"
fi

case "$type" in
  yesno)
    case "$answer" in
      yes) exit 0 ;;
      no) exit 1 ;;
      *) exit 255 ;;
    esac ;;
  input)
    case "$answer" in
      ok:*) printf '%s' "${answer#ok:}" >&2; exit 0 ;;
      *) exit 1 ;;
    esac ;;
  checklist)
    case "$answer" in
      check:*)
        printf '%s\n' "${answer#check:}" | tr ',' '\n' >&2
        exit 0 ;;
      *) exit 1 ;;
    esac ;;
  msgbox)
    case "$answer" in
      ok) exit 0 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$WORK/bin/whiptail"

tui_case() { # $1=输出文件 $2=答案文件，其余为参数
  local out="$1" ans="$2"
  shift 2
  rm -f "$ans.idx" "$out.log"
  MOCK_ANSWERS="$ans" MOCK_LOG="$out.log" PATH="$WORK/bin:$PATH" \
    VPS_INIT_FORCE_STDIN=1 VPS_INIT_ALLOW_NONROOT=1 \
    bash "$@" >"$out" 2>&1
  printf '%s' "$?"
}

# A：勾选只跑 sysupdate，后续三个可选项都答否
printf 'check:sysupdate\nyes\nno\nno\nno\n' >"$WORK/ans-a"
CUR_OUT="$WORK/tui-a.out"
rc="$(tui_case "$CUR_OUT" "$WORK/ans-a" "$WORK/init-fake.sh" --force --dry-run --ui=whiptail)"
check "勾选流程退出码" "0" "$rc"
check_has "弹出的第一个框是步骤勾选清单" "$CUR_OUT.log" "checklist|vps-init · 选择要执行的步骤"
check_has "勾选界面写明了按键方式" "$CUR_OUT.log" "空格 = 勾选/取消"
check_has "是否框写明了按键方式" "$CUR_OUT.log" "Tab 或 ← → 切换按钮"
check_has "只执行勾选的步骤" "$CUR_OUT" "步骤 1/1：只更新内核 / 驱动 / 固件"
check_has "全量升级仍默认否" "$CUR_OUT" "保持不动：本次不升级其它软件包"

# B：在勾选界面按取消
printf 'cancel\n' >"$WORK/ans-b"
CUR_OUT="$WORK/tui-b.out"
rc="$(tui_case "$CUR_OUT" "$WORK/ans-b" "$WORK/init-fake.sh" --force --dry-run --ui=whiptail)"
check "取消后正常退出" "0" "$rc"
check_has "提示已取消" "$CUR_OUT" "已取消选择"

# C：勾选界面一个都不选
printf 'check:\n' >"$WORK/ans-c"
CUR_OUT="$WORK/tui-c.out"
rc="$(tui_case "$CUR_OUT" "$WORK/ans-c" "$WORK/init-fake.sh" --force --dry-run --ui=whiptail)"
check "空勾选正常退出" "0" "$rc"
check_has "提示没有勾选" "$CUR_OUT" "没有勾选任何步骤"

# D：输入框填端口（确认框 yes → 输入框 52052 → 过渡期 yes → 提示框 ok）
printf 'yes\nok:52052\nyes\nok\n' >"$WORK/ans-d"
CUR_OUT="$WORK/tui-d.out"
rc="$(tui_case "$CUR_OUT" "$WORK/ans-d" "$WORK/init-fake.sh" --force --dry-run --ui=whiptail --only ssh-port)"
check "输入框流程退出码" "0" "$rc"
check_has "输入框的值传进端口配置" "$CUR_OUT" "Port 52052"
check_has "弹出了改端口提示框" "$CUR_OUT.log" "msgbox|改 SSH 端口前的检查"

# E：输入框按取消 → 步骤失败、退出码 1
printf 'yes\ncancel\n' >"$WORK/ans-e"
CUR_OUT="$WORK/tui-e.out"
rc="$(tui_case "$CUR_OUT" "$WORK/ans-e" "$WORK/init-fake.sh" --force --dry-run --ui=whiptail --only ssh-port)"
check "取消输入后步骤失败" "1" "$rc"
check_has "提示已取消输入" "$CUR_OUT" "已取消输入"

echo "== 13) 图形界面挂掉时要自动降级为文字问答，不能静默退出 =="
mkdir -p "$WORK/bin-fail"
cat >"$WORK/bin-fail/whiptail" <<'MOCK'
#!/usr/bin/env bash
# 模拟"界面不可用"：任何调用都返回错误码 3
exit 3
MOCK
chmod +x "$WORK/bin-fail/whiptail"
CUR_OUT="$WORK/tui-fail.out"
printf 'n\nn\nn\nn\ny\nn\ny\nn\nn\nn\n' |
  PATH="$WORK/bin-fail:$PATH" VPS_INIT_FORCE_STDIN=1 VPS_INIT_ALLOW_NONROOT=1 \
    bash "$WORK/init-fake.sh" --force --dry-run --ui=whiptail >"$CUR_OUT" 2>&1
rc=$?
check "降级后仍然跑完" "0" "$rc"
check_has "提示已降级" "$CUR_OUT" "已改用文字问答"
check_has "降级后仍能正常执行所选步骤" "$CUR_OUT" "步骤 1/1：时区 / Swap / BBR 网络加速"

echo "== 14) 图形界面等不到操作（超时）也要自动降级，不能卡死 =="
mkdir -p "$WORK/bin-tmo"
cat >"$WORK/bin-tmo/whiptail" <<'MOCK'
#!/usr/bin/env bash
# 模拟"等不到按键被 timeout 杀掉"（真实情况是 timeout 命令返回 124）
exit 124
MOCK
chmod +x "$WORK/bin-tmo/whiptail"
CUR_OUT="$WORK/tui-tmo.out"
printf 'n\nn\nn\nn\ny\nn\ny\nn\nn\nn\n' |
  PATH="$WORK/bin-tmo:$PATH" VPS_INIT_FORCE_STDIN=1 VPS_INIT_ALLOW_NONROOT=1 \
    bash "$WORK/init-fake.sh" --force --dry-run --ui=whiptail >"$CUR_OUT" 2>&1
rc=$?
check "超时后仍然跑完" "0" "$rc"
check_has "提示是等待超时" "$CUR_OUT" "等待操作超时"
check_has "已降级为文字问答" "$CUR_OUT" "已改用文字问答"
check_has "降级后继续执行所选步骤" "$CUR_OUT" "步骤 1/1：时区 / Swap / BBR 网络加速"

echo "== 15) 编号菜单 --ui=menu：输入数字即可选择（不依赖方向键） =="
CUR_OUT="$WORK/menu.out"
rc="$(printf '4 5\ny\nn\nn\nn\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --ui=menu)"
check "菜单模式退出码" "0" "$rc"
check_has "列出了编号菜单" "$CUR_OUT" "选择要执行的步骤"
check_has "说明可以用编号多选" "$CUR_OUT" "直接输入编号即可"
check_has "按编号选中了 fail2ban" "$CUR_OUT" "步骤 1/2：安装配置 fail2ban"
check_has "按编号选中了 tuning" "$CUR_OUT" "步骤 2/2：时区 / Swap / BBR 网络加速"

CUR_OUT="$WORK/menu-bad.out"
rc="$(printf 'abc\n0\n' | run_case "$CUR_OUT" "$WORK/init-fake.sh" --force --dry-run --ui=menu)"
check "输错编号后退出码" "0" "$rc"
check_has "提示编号不对" "$CUR_OUT" "编号不对"
check_has "输入 0 可取消" "$CUR_OUT" "已取消选择"

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

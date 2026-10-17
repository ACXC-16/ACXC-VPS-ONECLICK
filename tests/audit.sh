#!/usr/bin/env bash
# 全面自检：把每条路径都跑一遍（dry-run），抓退出码和异常输出
set -u
export PATH="/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
W="$(mktemp -d)"
mkdir -p "$W/sshd/sshd_config.d" "$W/bin" "$W/cache" "$W/log"
printf 'Port 22\n' >"$W/sshd/sshd_config"
# 用改过路径的副本，避免碰到真实系统
sed -e "s|/etc/ssh/sshd_config\.d|$W/sshd/sshd_config.d|g" \
    -e "s|/etc/ssh/sshd_config|$W/sshd/sshd_config|g" \
    -e "s|/root/acxc-vps-backup|$W/bk|g" \
    -e "s|/var/run/reboot-required|$W/reboot-required|g" \
    -e "s|/etc/fail2ban/jail\.d|$W/f2b|g" \
    -e "s|/etc/sysctl\.d/99-acxc-vps-bbr\.conf|$W/bbr.conf|g" \
    -e "s|/var/log/acxc-vps\.log|$W/log/acxc.log|g" \
    -e "s|^SWAPFILE=/swapfile$|SWAPFILE=$W/swapfile|" \
    init.sh >"$W/i.sh"
mkdir -p "$W/f2b"

PASS=0; FAIL=0
run() { # $1=名字 $2=stdin $3..=参数
  local name="$1" input="$2"; shift 2
  local out rc
  out="$(printf '%b' "$input" | ACXC_VPS_ALLOW_NONROOT=1 ACXC_VPS_FORCE_STDIN=1 \
        ACXC_VPS_SHORTCUT_DIR="$W/bin" ACXC_VPS_CACHE_DIR="$W/cache" \
        timeout 90 bash "$W/i.sh" --force "$@" 2>&1)"
  rc=$?
  local bad=""
  case "$out" in
    *"unbound variable"*) bad="UNBOUND" ;;
    *"command not found"*) bad="NOTFOUND" ;;
    *"syntax error"*) bad="SYNTAX" ;;
    *"bad substitution"*) bad="BADSUBST" ;;
    *"Segmentation fault"*) bad="SEGV" ;;
  esac
  if [ "$rc" -eq 124 ]; then bad="TIMEOUT"; fi
  if [ -n "$bad" ]; then
    FAIL=$((FAIL+1)); printf '  [FAIL] %-46s rc=%-3s %s\n' "$name" "$rc" "$bad"
    printf '%s\n' "$out" | grep -iE 'unbound variable|command not found|syntax error|bad substitution' | head -3 | sed 's/^/         /'
  else
    PASS=$((PASS+1)); printf '  [ ok ] %-46s rc=%s\n' "$name" "$rc"
  fi
}

# 额外断言：输出里必须出现某段关键字
expect() { # $1=名字 $2=stdin $3=关键字 $4..=参数
  local name="$1" input="$2" kw="$3"; shift 3
  local out rc
  out="$(printf '%b' "$input" | ACXC_VPS_ALLOW_NONROOT=1 ACXC_VPS_FORCE_STDIN=1 \
        ACXC_VPS_SHORTCUT_DIR="$W/bin" ACXC_VPS_CACHE_DIR="$W/cache" \
        timeout 90 bash "$W/i.sh" --force "$@" 2>&1)"
  rc=$?
  if printf '%s' "$out" | grep -qF "$kw"; then
    PASS=$((PASS+1)); printf '  [ ok ] %-46s rc=%s 「%s」\n' "$name" "$rc" "$kw"
  else
    FAIL=$((FAIL+1)); printf '  [FAIL] %-46s rc=%s 缺少「%s」\n' "$name" "$rc" "$kw"
    printf '%s\n' "$out" | tail -5 | sed 's/^/         /'
  fi
}

echo "### 一、命令行参数 ###"
run "--help" "" --help
run "--version" "" --version
run "--list" "" --list
run "未知参数" "" --nonsense
run "--dry-run 单独用" "" --dry-run
run "--no-color" "" --dry-run --no-color --yes --only sysupdate
run "组合：--skip access" "" --dry-run --yes --skip access

echo
echo "### 二、每步单独跑（--only）###"
for s in sysupdate access extras; do
  run "--only $s" "" --dry-run --yes --only $s
done
run "--only 全部（不指定）" "" --dry-run --yes
run "--only 不存在的步骤（应 rc=2）" "" --dry-run --yes --only nosuchstep
run "--port 越界" "" --dry-run --yes --port 99999 --only access
run "--port 0" "" --dry-run --yes --port 0 --only access
run "--port 合法" "" --dry-run --yes --port 2222 --only access
run "--password 合法" "" --dry-run --yes --password 'Abc12345!x' --only access
run "--gen-password" "" --dry-run --yes --gen-password --only access
run "--skip 不存在的步骤（应 rc=2）" "" --dry-run --yes --skip nosuchstep --only sysupdate

echo
echo "### 三、交互式菜单（每个入口）###"
expect "0) 退出" "0\n" "操作菜单" --dry-run
run "主菜单非法输入后退出" "zzz\n0\n" --dry-run
run "4) 查看系统信息" "4\n\n0\n" --dry-run
run "5) 查看运行日志" "5\n\n0\n" --dry-run
run "6) 更新脚本" "6\n\n0\n" --dry-run
run "1) 然后返回" "1\n0\n0\n" --dry-run
run "1) 选固件" "1\n2\n\n0\n" --dry-run
run "1) 全升级（回车）" "1\n\n\n0\n" --dry-run
run "1) 非法编号后返回" "1\n9\n0\n0\n" --dry-run
run "2) 改密码+改端口" "2\nAbc12345!x\n52052\ny\ny\n\n0\n" --dry-run
run "2) 全部跳过" "2\n\n\n\n0\n" --dry-run
run "2) 非法端口后返回" "2\n\n\nabc\n0\n0\n" --dry-run
run "3) 返回" "3\n0\n0\n" --dry-run
run "3) 回车=推荐项" "3\n\n0\n" --dry-run
run "3) a=全部" "3\na\n\n0\n" --dry-run
run "3) 选 1 3" "3\n1 3\n\n0\n" --dry-run
run "3) 选 11 时区" "3\n11\n4\n0\n0\n" --dry-run
run "3) 时区选 0" "3\n11\n0\n0\n0\n" --dry-run
run "3) 时区非法" "3\n11\n99\n2\n0\n0\n" --dry-run
run "3) ufw 不放行 80/443" "3\n4\nn\ny\n0\n" --dry-run
run "3) ufw 放行 80/443" "3\n4\ny\ny\n0\n" --dry-run
run "3) bbr" "3\n12\n0\n" --dry-run
run "3) 网络排障" "3\n10\n0\n" --dry-run
run "3) 非法编号" "3\n99\n0\n0\n" --dry-run
run "7) 重启脚本" "7\n3\n0\n" --dry-run
run "7) 全部重启" "7\n4\n0\n" --dry-run
run "7) 单重启 SSH" "7\n1\n\n0\n" --dry-run
run "7) 非法输入" "7\nxx\n0\n0\n" --dry-run
run "8) 删快捷命令" "8\n1\n\n0\n" --dry-run
run "8) 卸工具" "8\n2\ny\ny\n\n0\n" --dry-run
run "8) 删日志" "8\n3\n\n0\n" --dry-run
run "8) 还原配置" "8\n4\n\n\n\n\n\n\n0\n" --dry-run
run "8) 完全卸载" "8\n5\ny\n\n\n\n\n\n\n\n\n0\n" --dry-run
run "8) 非法输入" "8\nxx\n0\n0\n" --dry-run

echo
echo "### 四、重复执行（幂等）###"
run "连跑两次 sysupdate" "" --dry-run --yes --only sysupdate
run "连跑两次 extras" "" --dry-run --yes --only extras

rm -rf "$W"
echo
echo "==== 结果：通过 $PASS 项，失败 $FAIL 项 ===="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# =============================================================================
#  ACXC16-VPS新机一键脚本 —— Ubuntu / Debian VPS 初始化交互式脚本
#  版本: 1.0.0
#  仓库: https://github.com/ACXC-16/ACXC-VPS-ONECLICK
#  许可: MIT
# -----------------------------------------------------------------------------
#  一键运行（推荐，先下载再以 root 执行）：
#      curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-VPS-ONECLICK/main/init.sh | sudo bash
#    或
#      sudo bash <(curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-VPS-ONECLICK/main/init.sh)
#
#  测试用环境变量（普通用户不用管，CI / 本地测试才会用到）:
#    ACXC_VPS_ALLOW_NONROOT=1  配合 --dry-run 允许非 root 运行
#    ACXC_VPS_FORCE_STDIN=1    强制从 stdin 读取回答（测试脚本喂答案用）
#
#  设计原则：
#    * 每一步执行前都单独询问 Y/N，默认值写在 STEPS 表里
#    * 任何一步失败都不会中断整个脚本，最后统一汇总
#    * 改动系统前先备份；SSH 端口这种"改错就失联"的操作带校验与自动回滚
#    * 想加新功能：写一个 step_xxx 函数，再往 STEPS 表加一行即可（见文末注释）
# =============================================================================

# 注意：下面的步骤函数是"按名字"通过 STEPS 表间接调用的（见 run_plan），
# lint 工具看不到调用点，会把整个函数体误报为 SC2317（unreachable），这里整体关掉。
# shellcheck disable=SC2317

set -u
set -o pipefail

SCRIPT_NAME="ACXC16-VPS新机一键脚本"
SCRIPT_VERSION="1.0.0"
REPO_SLUG="ACXC-16/ACXC-VPS-ONECLICK"

DEFAULT_SSH_PORT="52052"
# 菜单里选「使用默认设置」时用的 root 密码
DEFAULT_ROOT_PASSWORD="acxc1616"
# 旧版本（vps-init 前缀）留下的路径：升级时自动改名，见 migrate_legacy_paths
LEGACY_SSHD_CONF="/etc/ssh/sshd_config.d/00-vps-init.conf"
LEGACY_F2B_CONF="/etc/fail2ban/jail.d/vps-init.local"
LEGACY_BBR_CONF="/etc/sysctl.d/99-vps-init-bbr.conf"
LEGACY_SWAP_CONF="/etc/sysctl.d/99-vps-init-swap.conf"
LEGACY_LOG="/var/log/vps-init.log"
LEGACY_BACKUP_DIR="/root/vps-init-backup"

MANAGED_SSHD_CONF="/etc/ssh/sshd_config.d/00-acxc-vps.conf"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/acxc-vps.local"
SYSCTL_BBR_CONF="/etc/sysctl.d/99-acxc-vps-bbr.conf"
SWAPFILE="/swapfile"
# 需要重启的标记文件（一般不用改；测试时会指向临时文件）
REBOOT_REQUIRED_FILE="${ACXC_VPS_REBOOT_REQUIRED:-/var/run/reboot-required}"

LOG_FILE="${ACXC_VPS_LOG:-/var/log/acxc-vps.log}"
REPLY=""
TTY_OK=0
DRY_RUN=0
ASSUME_YES=0
FORCE_OS=0
COLOR_OFF=0
OPT_PORT=""
ONLY_LIST=""
SKIP_LIST=""
NEED_REBOOT=0
FAILED_COUNT=0
OS_PRETTY="未知"
LAST_SSH_BACKUP=""
OPT_PASSWORD=""
GEN_PASSWORD=0
NEW_ROOT_PASSWORD=""
SSH_PORT_CHANGED=""
KERNEL_RELEASE=""
SSH_NEW_PORT=""
SSH_KEEP_OLD=0
SSH_OLD_PORTS=""
PASSWD_NEW=""
PASSWD_GEN=0
NO_CHANGE=0

# 交互界面：状态表 + 编号菜单（纯文字，任何终端都能用；不支持图形方框是有意为之）

# 受管的 SSH 设置（脚本重启后会从受管配置里读回来，避免覆盖上次的设置）
SSH_M_PORTS=""
SSH_M_PERMIT_ROOT_LOGIN=""
SSH_M_PASSWORD_AUTH=""

declare -a PLAN_SLUGS=() PLAN_TITLES=() PLAN_FUNCS=() PLAN_TOOLS=()
declare -a RESULT_NAMES=() RESULT_STATES=()
# 启动时的原始参数（重启脚本时原样带过去）
declare -a ORIG_ARGS=()

# ============================== 步骤注册表 ==================================
# 格式: "标识|名称|默认值(y/n)|函数名"
# 默认值只是"直接回车"时的取值，每一项都会单独询问 Y/N。
STEPS=(
  "sysupdate|更新内核 / 驱动 / 固件|y|step_sysupdate"
  "access|修改 root 密码 / SSH 端口|y|step_access"
  "extras|安装常用工具 / BBR网络加速 / Swap|n|step_extras"
)

# 快捷命令：安装成 acxc，以后直接输入 acxc 就能打开
SHORTCUT_DIR="${ACXC_VPS_SHORTCUT_DIR:-/usr/local/bin}"
SHORTCUT_NAME="acxc"
SHORTCUT_VER_MARK="acxc-shortcut-ver: 2"
# 1 = 只读配置文件、不跑 sshd -T（用于状态显示，避免启动变慢）
CSP_FAST=0
CACHE_DIR="${ACXC_VPS_CACHE_DIR:-/usr/local/share/acxc}"

# ============================== 输出与日志 ==================================
C_RST=''; C_BLD=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''; C_DIM=''

init_colors() {
  if [ "$COLOR_OFF" -eq 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_RED=$'\033[31m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'
  fi
}

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_raw() {
  [ -n "$LOG_FILE" ] || return 0
  # 注意顺序：先把 stderr 丢到 /dev/null，再打开日志文件，
  # 这样日志路径不可写时不会在终端刷出多余的报错。
  printf '%s [%s] %s\n' "$(_ts)" "$1" "$2" 2>/dev/null >>"$LOG_FILE"
  return 0
}

info()  { printf '%s\n' "  ${C_CYN}[信息]${C_RST} $*"; _log_raw INFO "$*"; }
ok()    { printf '%s\n' "  ${C_GRN}[成功]${C_RST} $*"; _log_raw OK   "$*"; }
warn()  { printf '%s\n' "  ${C_YEL}[注意]${C_RST} $*" >&2; _log_raw WARN "$*"; }
err()   { printf '%s\n' "  ${C_RED}[错误]${C_RST} $*" >&2; _log_raw ERROR "$*"; }
die()   { err "$*"; exit 1; }
title() { printf '\n%s\n' "  ${C_BLD}${C_CYN}==== $* ====${C_RST}"; _log_raw TITLE "==== $* ===="; }
kv()    { printf '  %-18s %s\n' "$1" "$2"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# 计算字符串在终端里占几列（中文等全角字符按 2 列算；用字节数换算，与 locale 无关）
# 计算字符串在终端里占几列（用于把"项目 / 状态"两列对齐）
# 纯 bash：函数内临时切到 C locale，用模式替换数出 ASCII 字节，再按 UTF-8 的
# 3 字节 = 2 列折算中文/全角字符。不依赖本机 locale，也不起任何子进程。
# 显示宽度（中文算 2 列）：结果放全局 DW，不用 $( ) 就不会起子 shell
DW=0
disp_width() {
  local s="$1" save_lc="${LC_ALL-}" ascii=""
  LC_ALL=C
  ascii="${s//[! -~]/}"                      # 只留下 ASCII 可打印字符（含空格）
  DW=$(( ${#ascii} + ((${#s} - ${#ascii}) / 3) * 2 ))
  if [ -n "$save_lc" ]; then LC_ALL="$save_lc"; else unset LC_ALL; fi
}

# 去掉字符串首尾空白
trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 执行命令：dry-run 时只打印，不真正执行
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] $*${C_RST}"
    _log_raw DRYRUN "$*"
    return 0
  fi
  _log_raw CMD "$*"
  "$@"
}

# 确定日志文件是否可写（不可写则退到 /tmp，再不行就关闭日志）
prepare_log() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then mkdir -p "$dir" 2>/dev/null || true; fi
  if ! { : 2>/dev/null >>"$LOG_FILE"; }; then
    LOG_FILE="/tmp/acxc-vps.log"
    if ! { : 2>/dev/null >>"$LOG_FILE"; }; then LOG_FILE=""; fi
  fi
  if [ -n "$LOG_FILE" ]; then chmod 600 "$LOG_FILE" 2>/dev/null || true; fi
  return 0
}

init_log() {
  _log_raw START "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} 启动（参数：$*）====="
}

# ============================== 交互输入 ====================================
# 说明：curl | bash 时脚本本身占用了 stdin，所以必须从 /dev/tty 读输入。
# 这里用子 shell 真实地打开一次 /dev/tty：只有 -r/-w 测试通过是不够的
# （容器、面板、无控制终端的场景下 /dev/tty 存在但打不开，此时要退回 stdin）。
detect_tty() {
  TTY_OK=0
  # 测试时可以用 ACXC_VPS_FORCE_STDIN=1 强制从 stdin 读答案
  if [ "${ACXC_VPS_FORCE_STDIN:-0}" = "1" ]; then return 0; fi
  if ( : </dev/tty ) 2>/dev/null && ( : >/dev/tty ) 2>/dev/null; then
    TTY_OK=1
  fi
  return 0
}

# ============================== 输入清洗 ====================================
# 清洗用户在菜单里输入的内容：去掉方向键等转义序列/控制字符，全角数字转半角，
# 各种分隔符转空格。这样即使误按方向键也不会把 ^[[A 当成有效输入。
menu_clean_input() { # $1=原始输入 → 清洗后的字符串
  local s="${1-}" i
  # 快路径：纯可打印 ASCII（绝大多数输入）直接返回，省掉子进程
  case "$s" in
    *[!\ -~]*) ;;
    *) printf '%s' "$s"; return 0 ;;
  esac
  s="$(printf '%s' "$s" | sed -e 's/\x1b\[[0-9;?]*[A-Za-z~]//g' -e 's/\^\[\[[0-9;?]*[A-Za-z~]//g')"
  s="$(printf '%s' "$s" | tr -d '\000-\037\177')"
  local -a fw=(０ １ ２ ３ ４ ５ ６ ７ ８ ９)
  for i in 0 1 2 3 4 5 6 7 8 9; do
    s="${s//${fw[$i]}/$i}"
  done
  s="${s//，/ }"; s="${s//、/ }"; s="${s//；/ }"; s="${s//;// }"
  s="${s//,/ }"; s="${s//）/ }"; s="${s//（/ }"; s="${s//#/ }"; s="${s//./ }"
  printf '%s' "$s"
}

# 读取一行（菜单用）：返回 0=拿到内容，1=读不到
read_line() { # $1=提示语 → REPLY（原样，未清洗）
  if ! _prompt_line "  $1" ""; then
    return 1
  fi
  return 0
}


_prompt_line() { # $1=提示语 $2=默认值 → REPLY
  local p="$1" d="${2-}" line=""
  if [ "$TTY_OK" -eq 1 ]; then
    if [ -n "$d" ]; then
      IFS= read -r -p "$p [$d]: " line < /dev/tty || return 1
    else
      IFS= read -r -p "$p: " line < /dev/tty || return 1
    fi
  else
    if [ -n "$d" ]; then
      IFS= read -r -p "$p [$d]: " line || return 1
    else
      IFS= read -r -p "$p: " line || return 1
    fi
  fi
  REPLY="${line:-$d}"
  return 0
}

_prompt_secret() { # $1=提示语 → REPLY（不回显）
  local p="$1" line=""
  if [ "$TTY_OK" -eq 1 ]; then
    IFS= read -r -s -p "$p" line < /dev/tty || return 1
    printf '\n' 2>/dev/null > /dev/tty
  else
    IFS= read -r -s -p "$p" line || return 1
    printf '\n' >&2
  fi
  REPLY="$line"
  return 0
}

# ask_yn "问题" [默认 y|n]：返回 0=是，1=否
ask_yn() {
  local q="$1" def="${2:-n}" hint ans
  if [ "$ASSUME_YES" -eq 1 ]; then
    if [ "$def" = y ]; then
      printf '%s\n' "${C_DIM}  [自动回答] $q -> Y${C_RST}"
      _log_raw AUTO "$q -> Y"
      return 0
    fi
    printf '%s\n' "${C_DIM}  [自动回答] $q -> N${C_RST}"
    _log_raw AUTO "$q -> N"
    return 1
  fi
  hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  while :; do
    if ! _prompt_line "  $q $hint " ""; then
      warn "读取输入失败（终端不可用）"
      return 1
    fi
    ans="$REPLY"
    [ -n "$ans" ] || ans="$def"
    case "$ans" in
      y|Y|yes|YES|Yes|是)  _log_raw ANSWER "$q -> Y"; return 0 ;;
      n|N|no|NO|No|否)     _log_raw ANSWER "$q -> N"; return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

# ask_value "提示" "默认值" → REPLY
ask_value() {
  local p="$1" def="${2-}" ans
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [自动回答] $p -> ${def:-<空>}${C_RST}"
    _log_raw AUTO "$p -> ${def:-<空>}"
    REPLY="$def"
    if [ -n "$def" ]; then return 0; fi
    return 1
  fi
  while :; do
    if ! _prompt_line "  $p" "$def"; then
      warn "读取输入失败（终端不可用）"
      return 1
    fi
    ans="$REPLY"
    if [ -n "$ans" ]; then REPLY="$ans"; return 0; fi
    warn "输入不能为空"
  done
}

# ============================== 通用小工具 ==================================
virt_type() {
  if have systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
}


in_list() { # $1=目标 $2=逗号/空格分隔的列表
  local needle="$1" hay="${2// /}"
  case ",${hay}," in
    *",${needle},"*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

gen_password() { # $1=长度，只向 stdout 输出密码
  local len="${1:-24}" pw=""
  if have openssl; then
    pw="$(openssl rand -base64 64 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$len")"
  fi
  if [ "${#pw}" -lt "$len" ] && [ -r /dev/urandom ]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len")"
  fi
  if [ "${#pw}" -lt "$len" ]; then return 1; fi
  printf '%s' "$pw"
}

# ============================== SSH 公共函数 ================================
sshd_bin() {
  if have sshd; then
    printf 'sshd'
  elif [ -x /usr/sbin/sshd ]; then
    printf '/usr/sbin/sshd'
  else
    printf ''
  fi
}

# 校验 sshd 配置；容器里缺少主机密钥不算错
# 显式指定 -f /etc/ssh/sshd_config：与默认行为一致，同时便于测试脚本替换路径
sshd_test() {
  local b out rc=0
  b="$(sshd_bin)"
  [ -n "$b" ] || return 0
  out="$("$b" -t -f /etc/ssh/sshd_config 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"no hostkeys available"*|*"Missing privilege separation directory"*|*"No such file or directory"*)
        return 0 ;;
    esac
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}

sshd_effective() { # 输出 sshd -T 的结果（失败则为空）
  local b
  b="$(sshd_bin)"
  [ -n "$b" ] || return 1
  "$b" -T -f /etc/ssh/sshd_config 2>/dev/null
}

current_ssh_ports() { # 输出当前生效端口；CSP_FAST=1 时只读配置文件、不跑 sshd -T（状态显示用）
  local out="" line="" f=""
  if [ -n "${SSH_M_PORTS:-}" ]; then printf '%s' "$SSH_M_PORTS"; return 0; fi
  # 1) 受管 drop-in（纯 bash 读，零进程）
  if [ -r "$MANAGED_SSHD_CONF" ]; then
    while IFS= read -r line; do
      case "$line" in
        Port[[:space:]]*|Port)
          line="${line#Port}"; line="${line#"${line%%[![:space:]]*}"}"
          line="${line%"${line##*[![:space:]]}"}"
          case "$line" in ''|*[!0-9]*) ;; *) out="${out}${out:+ }${line}" ;; esac ;;
      esac
    done <"$MANAGED_SSHD_CONF" 2>/dev/null
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  # 2) 主配置（纯 bash 读）
  if [ -r /etc/ssh/sshd_config ]; then
    while IFS= read -r line; do
      case "$line" in
        Port[[:space:]]*|Port)
          line="${line#Port}"; line="${line#"${line%%[![:space:]]*}"}"
          line="${line%"${line##*[![:space:]]}"}"
          case "$line" in ''|*[!0-9]*) ;; *) out="${out}${out:+ }${line}" ;; esac ;;
      esac
    done </etc/ssh/sshd_config 2>/dev/null
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  if [ "${CSP_FAST:-0}" = "1" ]; then return 0; fi
  # 3) 兜底：真正问一次 sshd（慢，但最准）
  local eff=""
  eff="$(sshd_effective)" || true
  if [ -n "$eff" ]; then
    printf '%s' "$(printf '%s\n' "$eff" | awk '/^port /{printf "%s", (n++ ? " " : "") $2}')"
    return 0
  fi
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do
      case "$line" in
        Port[[:space:]]*|Port)
          line="${line#Port}"; line="${line#"${line%%[![:space:]]*}"}"
          line="${line%"${line##*[![:space:]]}"}"
          case "$line" in ''|*[!0-9]*) ;; *) out="${out}${out:+ }${line}" ;; esac ;;
      esac
    done <"$f" 2>/dev/null
  done
  printf '%s' "$out"
  return 0
}

port_in_use() { # $1=端口
  local p="$1" out=""
  if have ss; then
    out="$(ss -tln 2>/dev/null | awk 'NR>1{print $4}')"
  elif have netstat; then
    out="$(netstat -tln 2>/dev/null | awk 'NR>2{print $4}')"
  else
    return 1
  fi
  printf '%s\n' "$out" | grep -Eq "[:.]${p}\$"
}

port_owner() { # 尽量显示占用者
  local p="$1"
  if have ss; then
    ss -tlnp 2>/dev/null | awk -v pat=":${p}\$" '$4 ~ pat {print "      " $0; exit}'
  fi
  return 0
}

ssh_service_name() {
  local u
  if have systemctl; then
    for u in ssh sshd; do
      if systemctl list-unit-files --type=service 2>/dev/null | grep -Eq "^${u}\.service"; then
        printf '%s' "$u"
        return 0
      fi
    done
  fi
  printf ''
  return 0
}

restart_ssh() {
  local unit
  unit="$(ssh_service_name)"
  if [ -n "$unit" ]; then
    run systemctl restart "$unit"
    return $?
  fi
  if have service; then
    if run service ssh restart; then return 0; fi
    run service sshd restart
    return $?
  fi
  if [ -x /etc/init.d/ssh ]; then
    run /etc/init.d/ssh restart
    return $?
  fi
  warn "未找到 SSH 服务的管理方式，请手动重启 SSH"
  return 1
}

# 生成受管配置块
ssh_managed_block() {
  local p
  if [ -z "${SSH_M_PORTS}${SSH_M_PERMIT_ROOT_LOGIN}${SSH_M_PASSWORD_AUTH}" ]; then
    return 0
  fi
  printf '%s\n' "# --- acxc-vps managed block: start ---"
  printf '%s\n' "# 本文件由 ${SCRIPT_NAME} 生成；手工修改后请执行: systemctl restart ssh"
  # shellcheck disable=SC2086
  for p in $SSH_M_PORTS; do
    printf 'Port %s\n' "$p"
  done
  if [ -n "$SSH_M_PERMIT_ROOT_LOGIN" ]; then
    printf 'PermitRootLogin %s\n' "$SSH_M_PERMIT_ROOT_LOGIN"
  fi
  if [ -n "$SSH_M_PASSWORD_AUTH" ]; then
    printf 'PasswordAuthentication %s\n' "$SSH_M_PASSWORD_AUTH"
  fi
  printf '%s\n' "# --- acxc-vps managed block: end ---"
  return 0
}

ssh_managed_keys() {
  if [ -n "$SSH_M_PORTS" ]; then printf '%s\n' Port; fi
  if [ -n "$SSH_M_PERMIT_ROOT_LOGIN" ]; then printf '%s\n' PermitRootLogin; fi
  if [ -n "$SSH_M_PASSWORD_AUTH" ]; then printf '%s\n' PasswordAuthentication; fi
  return 0
}

# 把上次运行留下的受管设置读回来，避免只跑其中一个步骤时把另一个覆盖掉
# ===================== 旧文件名迁移（vps-init → acxc-vps） ==================
# 早期版本用的是 vps-init 前缀，升级后要把这些文件改名，否则会出现两份配置：
# fail2ban 会因重复 jail 启动失败、sshd 会同时监听两个端口。
migrate_legacy_paths() {
  local moved=0 pair old new
  local -a pairs=(
    "${LEGACY_SSHD_CONF}|${MANAGED_SSHD_CONF}"
    "${LEGACY_F2B_CONF}|${FAIL2BAN_CONF}"
    "${LEGACY_BBR_CONF}|${SYSCTL_BBR_CONF}"
    "${LEGACY_SWAP_CONF}|/etc/sysctl.d/99-acxc-vps-swap.conf"
  )

  # 日志：旧内容追加进新文件，然后删掉旧的，不丢历史
  if [ -f "$LEGACY_LOG" ] && [ "$LEGACY_LOG" != "$LOG_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将把旧日志合并进 ${LOG_FILE} 并删除 ${LEGACY_LOG}"
    elif cat "$LEGACY_LOG" >>"$LOG_FILE" 2>/dev/null; then
      rm -f "$LEGACY_LOG" 2>/dev/null && info "旧日志已并入：${LEGACY_LOG} → ${LOG_FILE}"
    fi
  fi

  for pair in "${pairs[@]}"; do
    old="${pair%%|*}"; new="${pair#*|}"
    [ "$old" = "$new" ] && continue
    [ -e "$old" ] || continue
    if [ -e "$new" ]; then
      warn "发现旧文件 ${old}，而新文件 ${new} 已存在：请确认后手动删除旧文件（两个都生效可能冲突）"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将把旧文件改名：${old} → ${new}"
      continue
    fi
    if mv -f "$old" "$new" 2>/dev/null; then
      # 文件里的旧标记/注释一起换掉（管理块标记必须换，否则读不回来）
      sed -i 's/vps-init/acxc-vps/g' "$new" 2>/dev/null || true
      info "旧文件已改名：${old} → ${new}"
      moved=1
    else
      warn "旧文件改名失败：${old}（可手动执行 mv ${old} ${new}）"
    fi
  done

  # 备份目录
  if [ -d "$LEGACY_BACKUP_DIR" ] && [ ! -e /root/acxc-vps-backup ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将把旧备份目录改名：${LEGACY_BACKUP_DIR} → /root/acxc-vps-backup"
    elif mv -f "$LEGACY_BACKUP_DIR" /root/acxc-vps-backup 2>/dev/null; then
      info "旧备份目录已改名：${LEGACY_BACKUP_DIR} → /root/acxc-vps-backup"
    fi
  fi

  [ "$moved" -eq 1 ] && invalidate_status
  return 0
}

ssh_load_managed() {
  SSH_M_PORTS=""; SSH_M_PERMIT_ROOT_LOGIN=""; SSH_M_PASSWORD_AUTH=""
  local src="" parsed="" kind rest
  if [ -f "$MANAGED_SSHD_CONF" ]; then
    src="$MANAGED_SSHD_CONF"
  elif [ -f /etc/ssh/sshd_config ] && grep -qE '(vps-init|acxc-vps) managed block: start' /etc/ssh/sshd_config 2>/dev/null; then
    src="/etc/ssh/sshd_config"
  else
    return 0
  fi
  parsed="$(sed -n -E '/# --- (vps-init|acxc-vps) managed block: start ---/,/# --- (vps-init|acxc-vps) managed block: end ---/p' "$src" 2>/dev/null |
    awk 'tolower($1)=="port"{printf "P %s\n", $2}
         tolower($1)=="permitrootlogin"{printf "R %s\n", $2}
         tolower($1)=="passwordauthentication"{printf "A %s\n", $2}')"
  while IFS=' ' read -r kind rest; do
    case "$kind" in
      P) [ -n "$rest" ] && SSH_M_PORTS="${SSH_M_PORTS}${SSH_M_PORTS:+ }${rest}" ;;
      R) SSH_M_PERMIT_ROOT_LOGIN="$rest" ;;
      A) SSH_M_PASSWORD_AUTH="$rest" ;;
    esac
  done <<<"$parsed"
  return 0
}

# 注释掉主配置里的顶层指令（Match 块内的不动）
comment_out_main_key() { # $1=配置文件 $2=指令名（小写）
  local conf="$1" key="$2" tmp
  [ -f "$conf" ] || return 0
  tmp="$(mktemp)" || return 1
  awk -v key="$key" '
    {
      low = tolower($0)
      if (low ~ /^[[:space:]]*match[[:space:]]/) {
        if (low ~ /^[[:space:]]*match[[:space:]]+all[[:space:]]*$/) { inmatch = 0 } else { inmatch = 1 }
        print; next
      }
      if (!inmatch && low ~ ("^[[:space:]]*" key "[[:space:]]")) {
        printf "# %s  # acxc-vps: disabled\n", $0
        next
      }
      print
    }
  ' "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$conf" || { rm -f "$tmp"; return 1; }
  chmod 644 "$conf" 2>/dev/null || true
  rm -f "$tmp"
  return 0
}

remove_managed_inline_block() {
  local conf="$1"
  [ -f "$conf" ] || return 0
  sed -i -E '/# --- (vps-init|acxc-vps) managed block: start ---/,/# --- (vps-init|acxc-vps) managed block: end ---/d' "$conf"
  return 0
}

# 老版本 OpenSSH 没有 Include 指令时的兜底：直接改主配置
ssh_write_inline() {
  local block="$1" conf="/etc/ssh/sshd_config" k
  remove_managed_inline_block "$conf"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    comment_out_main_key "$conf" "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
  done < <(ssh_managed_keys)
  {
    printf '\n'
    printf '%s\n' "$block"
  } >>"$conf" || return 1
  return 0
}

insert_include_line() { # $1=配置文件 $2=Include 行
  local conf="$1" line="$2" tmp
  tmp="$(mktemp)" || return 1
  { printf '%s\n' "$line"; cat "$conf"; } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$conf" || { rm -f "$tmp"; return 1; }
  chmod 644 "$conf" 2>/dev/null || true
  rm -f "$tmp"
  if sshd_test; then return 0; fi
  warn "当前 OpenSSH 版本不支持 Include 指令，已撤销该行。"
  sed -i '1{/^Include \/etc\/ssh\/sshd_config\.d\/\*\.conf$/d;}' "$conf"
  return 1
}

# 写入受管配置（drop-in 优先，老系统走主配置）
ssh_write_managed() {
  local conf="/etc/ssh/sshd_config" block="" k
  block="$(ssh_managed_block)"
  if [ -z "$block" ]; then
    if [ "$DRY_RUN" -eq 0 ] && [ -f "$MANAGED_SSHD_CONF" ]; then rm -f "$MANAGED_SSHD_CONF"; fi
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 ${MANAGED_SSHD_CONF}：${C_RST}"
    printf '%s\n' "$block" | sed 's/^/    /'
    return 0
  fi
  [ -f "$conf" ] || { err "找不到 $conf"; return 1; }
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$conf" 2>/dev/null; then
    if ! insert_include_line "$conf" 'Include /etc/ssh/sshd_config.d/*.conf'; then
      ssh_write_inline "$block"
      return $?
    fi
  fi
  mkdir -p /etc/ssh/sshd_config.d || return 1
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    comment_out_main_key "$conf" "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
  done < <(ssh_managed_keys)
  printf '%s\n' "$block" >"$MANAGED_SSHD_CONF" || return 1
  chmod 644 "$MANAGED_SSHD_CONF" 2>/dev/null || true
  return 0
}

ssh_config_ok() { # [$1=必须生效的端口]
  local want="${1:-}" eff=""
  if ! sshd_test >/dev/null 2>&1; then return 1; fi
  eff="$(sshd_effective)" || true
  if [ -z "$eff" ]; then
    warn "无法通过 sshd -T 校验（可能是缺少主机密钥的容器环境），只做配置文件检查。"
    if [ -n "$want" ]; then
      grep -rqsE "^[[:space:]]*Port[[:space:]]+${want}([[:space:]]|$)" /etc/ssh/ || return 1
    fi
    return 0
  fi
  if [ -n "$want" ]; then
    printf '%s\n' "$eff" | awk '/^port /{print $2}' | grep -qx "$want" || return 1
  fi
  return 0
}

ssh_restore_backup() {
  local bak="$LAST_SSH_BACKUP"
  if [ -z "$bak" ] || [ ! -d "$bak" ]; then
    warn "没有可用备份，请手动检查 /etc/ssh/"
    return 1
  fi
  warn "正在回滚 SSH 配置到修改前…"
  if [ -f "${bak}/sshd_config" ]; then cp -a "${bak}/sshd_config" /etc/ssh/sshd_config; fi
  if [ -d "${bak}/sshd_config.d" ]; then
    # 先把备份完整还原到旁边的临时目录，成功后再整体替换：
    # 万一拷贝中途失败（磁盘满等），原来的 drop-in 目录还在，不会把 SSH 配置弄丢。
    local newd="/etc/ssh/sshd_config.d.restore.$$"
    rm -rf "$newd"
    if cp -a "${bak}/sshd_config.d" "$newd"; then
      rm -rf /etc/ssh/sshd_config.d
      mv "$newd" /etc/ssh/sshd_config.d || { warn "替换 drop-in 目录失败，备份在 $newd"; return 1; }
    else
      rm -rf "$newd"
      warn "还原 drop-in 目录失败（磁盘空间？），当前配置未改动，请手动检查 /etc/ssh/"
      return 1
    fi
  else
    rm -f "$MANAGED_SSHD_CONF"
  fi
  restart_ssh || warn "自动重启 SSH 失败，请手动执行: systemctl restart ssh"
  ok "已回滚到修改前的 SSH 配置"
  return 0
}

# ============================== 步骤 1：内核 / 驱动 =========================
# 只动"内核 + 驱动模块 + 固件 + 微码"相关的包；系统里其它软件包默认完全不碰。
# 想全量升级（full-upgrade）是单独一次询问，默认「否」。
KERNEL_PKG_RE='^(linux-(image|modules|modules-extra|firmware|generic|virtual|kvm|headers)|(intel|amd64)-microcode)'

upgradable_kernel_pkgs() { # 当前可升级的内核/驱动/固件包（每行一个）
  have apt || return 1
  apt list --upgradable 2>/dev/null | awk -F/ 'NF>1{print $1}' | grep -E "$KERNEL_PKG_RE" | sort -u
}

installed_kernel_pkgs() { # 已安装的内核/驱动/固件包
  have dpkg-query || return 1
  dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null |
    awk '$2=="install" && $3=="ok" && $4=="installed"{print $1}' |
    grep -E "$KERNEL_PKG_RE" | sort -u
}

# ==================== 步骤 1：更新内核 / 驱动 / 固件 ========================
# 把可升级的包分成三类，让用户按 1 / 2 / 3 勾选（可多选，编号之间用空格隔开）
kernel_pkg_group() { # $1=包名 → driver|firmware|kernel
  case "$1" in
    *microcode*|linux-modules-extra*) printf 'driver' ;;
    linux-firmware*)                  printf 'firmware' ;;
    *)                                printf 'kernel' ;;
  esac
}

step_sysupdate() {
  local rc=0 all="" p="" line="" sel="" tok="" ok=1
  local driver="" firmware="" kernel="" picked=""
  local -a chosen=()
  local -a g_names=("驱动（CPU 微码 / 驱动模块）" "固件（firmware）" "内核（image / modules / headers）")

  info "1/2 刷新软件源索引（只更新索引，不动任何软件）…"
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3; then
    err "apt update 失败：请检查网络 / 软件源 / 磁盘空间"
    return 1
  fi

  info "2/2 检查可升级的项目…"
  if have apt; then
    all="$(upgradable_kernel_pkgs)"
  else
    all="$(installed_kernel_pkgs)"
  fi

  if [ -z "$all" ]; then
    ok "内核 / 驱动 / 固件都已经是最新，无需升级。"
    return 0
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$(kernel_pkg_group "$p")" in
      driver)   driver="${driver}${driver:+ }${p}" ;;
      firmware) firmware="${firmware}${firmware:+ }${p}" ;;
      *)        kernel="${kernel}${kernel:+ }${p}" ;;
    esac
  done <<<"$all"

  # 组名按显示宽度补齐（中文算 2 列），只算一次
  local -a g_label=()
  for p in "${g_names[@]}"; do
    disp_width "$p"; local gp=$((34 - DW))
    [ "$gp" -lt 1 ] && gp=1
    g_label+=("$(printf '%s%*s' "$p" "$gp" "")")
  done

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\n%s\n' "  ${C_BLD}可升级的项目：${C_RST}"
    printf '  %s1)%s %s %s\n' "${C_GRN}" "${C_RST}" "${g_label[0]}" "${driver:-（无）}"
    printf '  %s2)%s %s %s\n' "${C_GRN}" "${C_RST}" "${g_label[1]}" "${firmware:-（无）}"
    printf '  %s3)%s %s %s\n' "${C_GRN}" "${C_RST}" "${g_label[2]}" "${kernel:-（无）}"
    printf '  %s0)%s 返回（什么都不做）\n' "${C_DIM}" "${C_RST}"
    printf '\n'
    info "要升级哪几项就输入哪几个编号，多个编号之间要用空格隔开（例如：1 3）；直接回车＝全升级"
    while :; do
      if ! read_line "请选择"; then return 1; fi

      if [ -z "$(trim "$REPLY")" ]; then
        picked="1 2 3"
      else
        sel="$(trim "$(menu_clean_input "$REPLY")")"
        case "$sel" in
          0|q|Q) return 0 ;;
        esac
        ok=1
        picked=""
        # shellcheck disable=SC2086
        for tok in $(printf '%s' "$sel" | tr ' ' '\n'); do
          [ -n "$tok" ] || continue
          case "$tok" in
            *[!0-9]*) ok=0; break ;;
          esac
          if [ "$tok" -lt 1 ] || [ "$tok" -gt 3 ]; then ok=0; break; fi
          case " $picked " in
            *" $tok "*) ;;
            *) picked="${picked}${picked:+ }${tok}" ;;
          esac
        done
        if [ "$ok" -eq 1 ] && [ -n "$picked" ]; then break; fi
        warn "编号不对：请输入 1 / 2 / 3，多个编号之间用空格隔开（例如：1 3）"
        continue
      fi
      break
    done
  fi
  [ "$ASSUME_YES" -eq 1 ] && picked="1 2 3"

  # shellcheck disable=SC2086
  for tok in $(printf '%s' "$picked" | tr ' ' '\n'); do
    case "$tok" in
      1) chosen+=("$driver") ;;
      2) chosen+=("$firmware") ;;
      3) chosen+=("$kernel") ;;
    esac
  done

  printf '\n'
  for line in "${chosen[@]}"; do
    line="$(trim "$line")"
    if [ -z "$line" ]; then
      info "选中的项目里有一项没有可升级的包，跳过。"
      continue
    fi
    info "升级：$(printf '%s' "$line" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    if run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
      apt-get -y install --only-upgrade $line \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      -o Dpkg::Lock::Timeout=900; then
      ok "升级完成"
    else
      warn "升级过程中出现错误"
      rc=1
    fi
  done

  if [ -f "$REBOOT_REQUIRED_FILE" ]; then
    NEED_REBOOT=1
    warn "系统需要重启才能加载新内核 / 驱动。"
  fi
  ok "完成（当前运行内核：$(uname -r)）"
  return "$rc"
}
# ============================== 步骤 2：SSH 端口 ============================
# 询问新端口 → SSH_NEW_PORT / SSH_KEEP_OLD（失败返回 1）
ssh_ask_port() {
  local old_ports="" new_port="" ssherr="" keep_old=0

  SSH_NEW_PORT=""; SSH_KEEP_OLD=0; SSH_OLD_PORTS=""

  if [ ! -f /etc/ssh/sshd_config ]; then
    err "找不到 /etc/ssh/sshd_config，本机可能没安装 OpenSSH Server"
    return 1
  fi

  old_ports="$(trim "$(current_ssh_ports)")"
  if [ -z "$old_ports" ] && [ -n "$SSH_M_PORTS" ]; then
    old_ports="$(trim "$SSH_M_PORTS")"
    info "从上次留下的受管配置里读到端口：${old_ports}"
  fi
  SSH_OLD_PORTS="$old_ports"
  info "当前生效的 SSH 端口：${old_ports:-未知}"

  ssherr="$(sshd_test 2>&1)" || {
    warn "当前 SSH 配置本身就有语法问题："
    printf '%s\n' "$ssherr" | sed 's/^/    /'
    if ! ask_yn "仍然继续修改？（脚本会先备份，可回滚）" n; then return 1; fi
  }

  new_port="$OPT_PORT"
  if [ -n "$new_port" ]; then
    if ! valid_port "$new_port"; then
      err "端口不合法（应为 1-65535 的数字）：$new_port"
      return 1
    fi
    info "使用命令行参数指定的端口：$new_port"
  else
    while :; do
      if ! ask_value "请输入新的 SSH 端口" "$DEFAULT_SSH_PORT"; then return 1; fi
      new_port="$REPLY"
      if ! valid_port "$new_port"; then
        warn "端口必须是 1-65535 之间的数字，请重新输入"
        continue
      fi
      if [ "$new_port" -lt 1024 ]; then
        warn "端口 $new_port 属于特权端口（1-1023），建议使用 1024 以上"
      fi
      case " $old_ports " in
        *" $new_port "*) info "端口 $new_port 就是当前端口，将只做配置校验"; break ;;
      esac
      if port_in_use "$new_port"; then
        warn "端口 $new_port 已被占用："
        port_owner "$new_port"
        if ! ask_yn "仍然要使用这个端口吗？" n; then continue; fi
      fi
      break
    done
  fi

  # 端口统一成不带前导零的十进制（052052 → 52052），避免写进 ufw / sshd 时出现怪值
  case "$new_port" in
    ''|*[!0-9]*) ;;
    *) new_port="$((10#$new_port))" ;;
  esac

  if [ -n "$old_ports" ]; then
    case " $old_ports " in
      *" $new_port "*) ;;
      *)
        if ask_yn "过渡期是否继续保留原有端口（$(trim "$old_ports" | tr -s ' ')）？验证新端口可用后再关闭更安全" y; then
          keep_old=1
        fi ;;
    esac
  fi

  SSH_NEW_PORT="$new_port"
  SSH_KEEP_OLD="$keep_old"
  return 0
}

# 应用端口：$1=新端口 [$2=是否保留旧端口 0/1]
ssh_apply_port() {
  local new_port="$1" keep_old="${2:-0}" old_ports="" p stamp bak other

  old_ports="$SSH_OLD_PORTS"
  [ -n "$old_ports" ] || old_ports="$(trim "$(current_ssh_ports)")"

  # 改端口前的安全提示
  printf '\n'
  warn "改 SSH 端口前请先确认："
  printf '  ① 云服务商控制台的「安全组 / 防火墙」先放行 %s/TCP\n' "$new_port"
  printf '  ② 当前 SSH 会话不要断开（重启 sshd 不会踢掉已登录的连接）\n'
  printf '  ③ 改完另开一个终端用 ssh -p %s root@<服务器IP> 验证，成功再关旧连接\n' "$new_port"
  printf '  ④ 万一连不上：用云控制台 VNC 登录后执行脚本最后打印的回滚命令\n'
  printf '\n'

  # 动手前再确认一次（默认 Y，直接回车即执行）
  if [ "$ASSUME_YES" -eq 0 ]; then
    if [ -z "$old_ports" ]; then
      printf '  %s即将修改：SSH 端口 → %s%s\n' "${C_BLD}" "$new_port" "${C_RST}"
    elif printf '%s' "$old_ports" | tr ' ' '\n' | grep -qx "$new_port"; then
      printf '  %s即将执行：校验并重载 SSH 配置（端口仍是 %s）%s\n' "${C_BLD}" "$new_port" "${C_RST}"
    elif [ "$keep_old" -eq 1 ]; then
      printf '  %s即将修改：SSH 端口 %s → %s（过渡期保留 %s）%s\n' "${C_BLD}" "$(trim "$old_ports" | tr -s ' ')" "$new_port" "$(trim "$old_ports" | tr -s ' ')" "${C_RST}"
    else
      printf '  %s即将修改：SSH 端口 %s → %s%s\n' "${C_BLD}" "$(trim "$old_ports" | tr -s ' ')" "$new_port" "${C_RST}"
    fi
    if ! ask_yn "确认现在执行？" y; then
      info "已取消，SSH 端口没有任何改动。"
      return 0
    fi
    printf '\n'
  fi

  # 本机防火墙放行
  info "检查本机防火墙…"
  if have ufw && case "$(ufw status 2>/dev/null)" in *"Status: active"*) true ;; *) false ;; esac; then
    if run ufw allow "${new_port}/tcp" >/dev/null 2>&1; then
      ok "ufw 已放行 ${new_port}/tcp"
    else
      warn "ufw 放行失败，请手动执行：ufw allow ${new_port}/tcp"
    fi
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    if run firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 && run firewall-cmd --reload >/dev/null 2>&1; then
      ok "firewalld 已放行 ${new_port}/tcp"
    else
      warn "firewalld 放行失败，请手动执行：firewall-cmd --permanent --add-port=${new_port}/tcp && firewall-cmd --reload"
    fi
  else
    info "未检测到已启用的 ufw / firewalld，跳过本机防火墙放行。"
    if have iptables && case "$(iptables -S 2>/dev/null)" in *"-P INPUT DROP"*|*"-P FORWARD DROP"*) true ;; *) false ;; esac; then
      warn "iptables 默认策略是 DROP，请自行确认新端口没有被自建规则拦截。"
    fi
  fi

  # 备份
  stamp="$(date '+%Y%m%d-%H%M%S')"
  bak="/root/acxc-vps-backup/${stamp}-ssh"
  LAST_SSH_BACKUP="$bak"
  run mkdir -p "$bak"
  run cp -a /etc/ssh/sshd_config "${bak}/sshd_config"
  if [ -d /etc/ssh/sshd_config.d ]; then
    run cp -a /etc/ssh/sshd_config.d "${bak}/sshd_config.d"
  fi
  ok "已备份 SSH 配置到 $bak"

  # 写入
  SSH_M_PORTS="$new_port"
  if [ "$keep_old" -eq 1 ]; then
    # shellcheck disable=SC2086
    for p in $old_ports; do
      [ "$p" = "$new_port" ] && continue
      SSH_M_PORTS="${SSH_M_PORTS} ${p}"
    done
  fi
  info "写入 SSH 端口配置：$(trim "$SSH_M_PORTS" | tr -s ' ')"
  if ! ssh_write_managed; then
    err "写入 SSH 配置失败，已回滚"
    ssh_restore_backup
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 跳过 sshd 校验、重启与生效确认"
    return 0
  fi

  # 校验生效
  if ! ssh_config_ok "$new_port"; then
    warn "drop-in 方式未生效，改为直接写入主配置再试一次…"
    if ! ssh_write_inline "$(ssh_managed_block)" || ! ssh_config_ok "$new_port"; then
      err "新端口未能生效，已回滚到修改前的配置"
      ssh_restore_backup
      return 1
    fi
  fi
  other="$(grep -rlsE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config.d/ 2>/dev/null | grep -v "^${MANAGED_SSHD_CONF}$" || true)"
  if [ -n "$other" ]; then
    warn "以下 drop-in 也设置了 Port，如端口异常请检查它们：$(printf '%s' "$other" | tr '\n' ' ')"
  fi
  ok "配置校验通过，sshd 生效端口：$(sshd_effective | awk '/^port /{printf "%s ", $2}')"

  # 重启并确认监听
  info "重启 SSH 服务…"
  if ! restart_ssh; then
    err "SSH 服务重启失败，正在回滚"
    ssh_restore_backup
    return 1
  fi
  sleep 1
  if port_in_use "$new_port"; then
    ok "已确认 SSH 正在监听新端口 ${new_port}"
  else
    warn "未检测到 ${new_port} 处于监听状态，请手动确认：ss -tlnp | grep ${new_port}"
  fi
  return 0
}

# 询问新密码 → PASSWD_NEW / PASSWD_GEN（PASSWD_NEW 为空 = 不改密码）
passwd_ask() {
  local pw="" gen=0 p1="" p2=""

  PASSWD_NEW=""; PASSWD_GEN=0

  warn "改密码请务必先确认：当前会话不要断开，最好用另一个终端保持登录状态。"
  info "当前 root 密码状态：$(passwd -S root 2>/dev/null || printf '未知')"

  if [ -n "$OPT_PASSWORD" ]; then
    pw="$OPT_PASSWORD"
    if [ "${#pw}" -lt 8 ]; then warn "--password 只有 ${#pw} 位，建议至少 8 位"; fi
    info "使用命令行 --password 指定的密码（注意：它可能留在 shell 历史里，稍后建议执行 history -c 或删除该行）"
  elif [ "$GEN_PASSWORD" -eq 1 ]; then
    gen=1
  elif [ "$ASSUME_YES" -eq 1 ]; then
    # 关键安全设计：无人值守时绝不偷偷改密码，否则你就拿到了一个自己不知道的密码
    warn "无人值守模式（--yes）不会自动修改 root 密码 —— 避免生成一个你不知道的密码导致自己失联。"
    info "确实要改的话请显式指定：--password '你的新密码'  或  --gen-password（生成后会把密码显示出来）"
    return 0
  elif ask_yn "是否自动生成随机强密码？（选 N 则手动输入）" n; then
    gen=1
  fi

  if [ "$gen" -eq 1 ]; then
    pw="$(gen_password 24)" || { err "生成随机密码失败"; return 1; }
    # 先生成、先给你看，确认记下来之后才真正生效
    printf '\n%s\n' "${C_BLD}${C_YEL}  ★ 即将设置的 root 随机密码（只显示这一次）：${C_RST}"
    printf '%s\n\n' "${C_BLD}      ${pw}${C_RST}"
    printf '  %s\n' "脚本不会把它写进日志，也只显示这一次；请先复制保存。"
    if ! ask_yn "已经记下这个密码了，确认现在修改 root 密码？" y; then
      info "已取消：root 密码保持不变。"
      pw=""
      return 0
    fi
  elif [ -z "$OPT_PASSWORD" ]; then
    while :; do
      if ! _prompt_secret "  请输入新的 root 密码（不回显，至少 8 位）: "; then
        err "读取密码失败"
        return 1
      fi
      p1="$REPLY"
      if [ -z "$p1" ]; then warn "密码不能为空"; continue; fi
      case "$p1" in
        *[$'\n\r']*) warn "密码不能包含换行符"; continue ;;
      esac
      if [ "${#p1}" -lt 8 ]; then
        warn "密码长度至少 8 位（当前 ${#p1} 位），请重新输入"
        continue
      fi
      if ! _prompt_secret "  请再次输入以确认: "; then
        err "读取密码失败"
        return 1
      fi
      p2="$REPLY"
      if [ "$p1" != "$p2" ]; then warn "两次输入不一致，请重新输入"; continue; fi
      break
    done
    pw="$p1"
    p1=""; p2=""
  fi

  PASSWD_NEW="$pw"
  PASSWD_GEN="$gen"
  return 0
}

# 应用密码：$1=新密码 [$2=是否随机生成 0/1]
passwd_apply() {
  local pw="$1" gen="${2:-0}" eff="" prl="" pa=""

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将执行: printf 'root:<新密码>' | chpasswd${C_RST}"
    if [ "$gen" -eq 1 ]; then info "[dry-run] 本次随机密码：$pw"; fi
    pw=""
    return 0
  fi

  if printf 'root:%s\n' "$pw" | chpasswd; then
    ok "root 密码已修改成功"
  else
    err "chpasswd 执行失败，密码未修改"
    pw=""
    return 1
  fi

  # 记下来，最后结束界面再完整列一次（不写日志）
  NEW_ROOT_PASSWORD="$pw"

  if [ "$gen" -eq 1 ]; then
    printf '\n%s\n' "${C_BLD}${C_YEL}  ★ 新生成的 root 密码（只显示这一次，请立即保存）：${C_RST}"
    printf '%s\n\n' "${C_BLD}      $pw${C_RST}"
  else
    printf '\n%s\n' "${C_BLD}${C_YEL}  ★ root 密码已设置为：${C_RST}"
    printf '%s\n\n' "${C_BLD}      $pw${C_RST}"
    if [ "$pw" = "$DEFAULT_ROOT_PASSWORD" ]; then
      warn "这是脚本内置的默认密码，容易被猜到；建议登录后尽快改成你自己的强密码。"
    fi
    printf '  %s\n' "脚本不会把明文密码写进日志；结束界面上还会再显示一次。"
  fi
  pw=""

  info "密码状态：$(passwd -S root 2>/dev/null || printf '未知')"

  # 检查 SSH 是否允许 root 用密码登录
  eff="$(sshd_effective)" || true
  if [ -z "$eff" ]; then
    warn "读不到 SSH 生效配置，跳过「登录方式」检查。"
    return 0
  fi
  prl="$(printf '%s\n' "$eff" | awk '/^permitrootlogin /{print $2}')"
  pa="$(printf '%s\n' "$eff" | awk '/^passwordauthentication /{print $2}')"
  info "当前 SSH 设置：PermitRootLogin=${prl:-未知}，PasswordAuthentication=${pa:-未知}"
  if [ "$prl" = "yes" ] && [ "$pa" = "yes" ]; then
    ok "SSH 已允许 root 用密码登录，可以直接用新密码登录。"
    return 0
  fi

  warn "当前 SSH 不允许 root 用密码登录（云镜像常见默认设置），只改密码仍然无法用密码登录 SSH。"
  if ! ask_yn "是否同时开启「root + 密码」登录 SSH？（安全性会下降，建议优先用 SSH 密钥）" n; then
    info "保持现状，请继续使用密钥登录。"
    return 0
  fi

  SSH_M_PERMIT_ROOT_LOGIN="yes"
  SSH_M_PASSWORD_AUTH="yes"
  if ! ssh_write_managed; then
    err "写入 SSH 登录配置失败"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 跳过 sshd 校验与重启"
    return 0
  fi
  if ! ssh_config_ok; then
    err "SSH 配置校验失败，请检查 /etc/ssh/sshd_config.d/"
    return 1
  fi
  if ! restart_ssh; then
    err "SSH 服务重启失败，请手动执行: systemctl restart ssh"
    return 1
  fi
  eff="$(sshd_effective)" || true
  ok "SSH 登录设置已更新：$(printf '%s\n' "$eff" | awk '/^permitrootlogin |^passwordauthentication /{printf "%s=%s ", $1, $2}')"
  warn "当前会话不会断开；请另开终端验证能登录后，再考虑关闭旧连接。"
  return 0
}


# ==================== 步骤 2：修改 SSH 端口 / root 密码 ====================
# 没有二级菜单：第一步问端口（直接回车＝52052），第二步问密码（直接回车＝不修改）
# ==================== 步骤 2：修改 root 密码 / SSH 端口 ====================
# 两步走，不需要二级菜单：第一步改 root 密码（回车＝不改），第二步改 SSH 端口（回车＝52052）
step_access() {
  local rc=0 pw="" p2=""

  if [ "$ASSUME_YES" -eq 1 ]; then
    ssh_ask_port || rc=1
    passwd_ask || rc=1
    if [ -n "$SSH_NEW_PORT" ]; then
        ssh_apply_port "$SSH_NEW_PORT" "$SSH_KEEP_OLD"
        case $? in
          0) mark_port_changed ;;
          2) info "SSH 端口保持原样。" ;;
          *) rc=1 ;;
        esac
    fi
    if [ -n "$PASSWD_NEW" ]; then
      passwd_apply "$PASSWD_NEW" "$PASSWD_GEN" || rc=1
    fi
    return "$rc"
  fi

  # ---------- 1) root 密码 ----------
  printf '\n%s\n' "  ${C_BLD}第一步：修改 root 密码${C_RST}"
  info "当前状态：$(status_passwd)"
  warn "改密码前请确认当前会话不要断开，最好保持另一个终端已登录。"
  info "直接回车＝不修改 root 密码；如果想用脚本默认密码，就输入：${DEFAULT_ROOT_PASSWORD}"
  if ! _prompt_secret "  请输入新的 root 密码（回车＝不修改）: "; then
    warn "读取密码失败，已跳过 root 密码修改。"
  else
    pw="$REPLY"
    if [ -z "$pw" ]; then
      info "没有输入密码：root 密码保持不变。"
    else
      case "$pw" in
        *[$'\n\r']*) warn "密码不能包含换行符，已跳过 root 密码修改"; pw="" ;;
      esac
      if [ -n "$pw" ] && [ "${#pw}" -lt 8 ]; then
        warn "密码长度至少 8 位（当前 ${#pw} 位），已跳过 root 密码修改"
        pw=""
      fi
      # 不是默认密码时要求再输一遍，避免打错把自己锁在外面
      if [ -n "$pw" ] && [ "$pw" != "$DEFAULT_ROOT_PASSWORD" ]; then
        if _prompt_secret "  请再次输入以确认: "; then
          p2="$REPLY"
          if [ "$pw" != "$p2" ]; then
            warn "两次输入不一致，已跳过 root 密码修改。"
            pw=""
          fi
        else
          warn "读取密码失败，已跳过 root 密码修改。"
          pw=""
        fi
      fi
      if [ -n "$pw" ]; then
        passwd_apply "$pw" 0 || rc=1
      fi
    fi
  fi
  pw=""; p2=""

  # ---------- 2) SSH 端口 ----------
  printf '\n%s\n' "  ${C_BLD}第二步：修改 SSH 端口${C_RST}"
  if ssh_ask_port; then
    ssh_apply_port "$SSH_NEW_PORT" "$SSH_KEEP_OLD"
    case $? in
      0) mark_port_changed ;;
      2) info "SSH 端口保持原样。" ;;
      *) rc=1 ;;
    esac
  else
    warn "已跳过 SSH 端口修改。"
  fi

  printf '\n'
  if [ -n "$SSH_PORT_CHANGED" ] || [ -n "$NEW_ROOT_PASSWORD" ]; then
    printf '%s\n' "  ${C_BLD}${C_GRN}本次改动：${C_RST}"
    if [ -n "$NEW_ROOT_PASSWORD" ]; then
      printf '     root 密码 → %s\n' "$NEW_ROOT_PASSWORD"
    else
      printf '     root 密码 → 未修改\n'
    fi
    [ -n "$SSH_PORT_CHANGED" ] && printf '     SSH 端口 → %s\n' "$SSH_PORT_CHANGED"
  else
    printf '%s\n' "  ${C_BLD}本次没有做任何修改。${C_RST}"
  fi
  printf '\n'

  if [ -z "$SSH_PORT_CHANGED" ] && [ -z "$NEW_ROOT_PASSWORD" ]; then
    mark_no_change
  fi
  return "$rc"
}

# ============================== 步骤 4：fail2ban ============================
step_fail2ban() {
  local port="" backend="systemd" banned=""

  info "安装 fail2ban…"
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install fail2ban; then
    err "fail2ban 安装失败"
    return 1
  fi

  port="$(printf '%s' "${SSH_M_PORTS}" | awk '{print $1}')"
  if [ -z "$port" ]; then port="$(current_ssh_ports | awk '{print $1}')"; fi
  if [ -z "$port" ]; then port="22"; fi

  if [ "$DRY_RUN" -eq 0 ]; then
    if ! dpkg -s python3-systemd >/dev/null 2>&1; then
      if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install python3-systemd >/dev/null 2>&1; then
        backend="auto"
        warn "装不上 python3-systemd，fail2ban 改用日志文件后端（backend = auto）。"
      fi
    fi
  fi

  info "写入配置 ${FAIL2BAN_CONF}（保护 SSH 端口 ${port}，后端 ${backend}）…"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 ${FAIL2BAN_CONF}：bantime=1h / findtime=10m / maxretry=4 / [sshd] port=${port}${C_RST}"
  else
    mkdir -p /etc/fail2ban/jail.d || { err "创建 /etc/fail2ban/jail.d 失败"; return 1; }
    cat >"$FAIL2BAN_CONF" <<EOF
# 由 ${SCRIPT_NAME} 生成
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = ${backend}

[sshd]
enabled = true
port    = ${port}
mode    = aggressive
EOF
  fi

  run systemctl enable fail2ban || warn "设置 fail2ban 开机自启失败"
  if ! run systemctl restart fail2ban; then
    err "fail2ban 启动失败，排查：journalctl -u fail2ban -n 50"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 跳过 fail2ban 状态确认"
    return 0
  fi

  sleep 2
  if have fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
    banned="$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/{print $NF}')"
    ok "fail2ban 已启用并保护 sshd（当前封禁 ${banned:-0} 个 IP）"
    return 0
  fi

  if [ "$backend" = "systemd" ]; then
    warn "systemd 后端未生效，改用日志文件后端重试一次…"
    sed -i 's/^backend  = systemd/backend  = auto/' "$FAIL2BAN_CONF" 2>/dev/null || true
    run systemctl restart fail2ban || true
    sleep 2
    if have fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
      ok "fail2ban 已启用（日志文件后端）"
      return 0
    fi
  fi

  warn "fail2ban 已安装但 sshd jail 未生效，请排查：fail2ban-client status / journalctl -u fail2ban -n 50"
  return 0
}

# ============================== 步骤 5：时区/Swap/BBR =======================
# ==================== UFW 防火墙 ===========================================
# 顺序很重要：先放行 SSH 端口 → 再启用；否则会把自己关在门外。
install_ufw() {
  local ports="" p="" rc=0

  if have ufw; then
    info "ufw 已经安装"
  else
    info "安装 ufw…"
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install ufw; then
      warn "ufw 安装失败，已跳过"
      return 1
    fi
    ok "ufw 已安装"
  fi

  # 当前生效的 SSH 端口（含过渡期保留的旧端口）
  ports="$(trim "$(current_ssh_ports)")"
  [ -n "$ports" ] || ports="$(trim "$SSH_M_PORTS")"
  if [ -z "$ports" ]; then
    warn "读不到 SSH 端口，为避免被关在门外，已跳过启用（可以先跑第 2 项确认端口）"
    return 1
  fi
  info "先放行 SSH 端口，再启用防火墙：$(trim "$ports" | tr -s ' ')"

  for p in $ports; do
    if run ufw allow "${p}/tcp" 2>/dev/null; then
      ok "已放行 ${p}/tcp"
    else
      warn "放行 ${p}/tcp 失败"
      rc=1
    fi
  done

  if ask_yn "是否同时放行网站常用端口 80 / 443？" y; then
    run ufw allow 80/tcp 2>/dev/null && ok "已放行 80/tcp"
    run ufw allow 443/tcp 2>/dev/null && ok "已放行 443/tcp"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n'
    warn "启用后默认拒绝所有入站连接，只放行上面列出的端口。"
    warn "万一连不上：用云控制台 VNC 登录后执行 ufw disable"
    info "[dry-run] 将执行：ufw --force enable"
    return 0
  fi

  if case "$(ufw status 2>/dev/null)" in *"Status: active"*) true ;; *) false ;; esac; then
    ok "ufw 已经在运行（规则已更新）"
  else
    printf '\n'
    warn "启用后默认拒绝所有入站连接，只放行上面列出的端口。"
    warn "如果还有别的服务要对外开放（数据库 / 面板等），启用后请立刻执行：ufw allow <端口>/tcp"
    if ! ask_yn "确认现在启用 ufw？" n; then
      info "已跳过启用；规则已经准备好，随时可以执行 ufw enable"
      return "$rc"
    fi
    if run ufw --force enable; then
      ok "ufw 已启用"
    else
      err "ufw 启用失败"
      return 1
    fi
  fi

  printf '\n'
  info "当前 ufw 规则："
  ufw status numbered 2>/dev/null | sed 's/^/    /' || true
  warn "万一连不上：用云控制台 VNC 登录后执行 ufw disable"
  return "$rc"
}

create_swap() {
  local mb="$1" avail_mb=""
  if [ "$mb" -lt 256 ]; then
    warn "Swap 至少 256MB"
    return 1
  fi
  if [ -e "$SWAPFILE" ]; then
    warn "${SWAPFILE} 已存在"
    if ! ask_yn "是否删除并重建 ${SWAPFILE}？" n; then return 1; fi
    run swapoff "$SWAPFILE" || true
    run rm -f "$SWAPFILE"
  fi

  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt $((mb + 512)) ]; then
    warn "根分区可用空间不足（${avail_mb}MB，需要约 $((mb + 512))MB）"
    if ! ask_yn "仍然继续？" n; then return 1; fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将创建 ${SWAPFILE}（${mb}MB）、启用 Swap、写入 /etc/fstab、设置 vm.swappiness=10${C_RST}"
    return 0
  fi

  info "创建 ${mb}MB Swap 文件…"
  if ! fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null; then
    warn "fallocate 不可用，改用 dd（较慢）…"
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=none; then
      err "创建 Swap 文件失败"
      rm -f "$SWAPFILE"
      return 1
    fi
  fi
  chmod 600 "$SWAPFILE" || true
  if ! mkswap "$SWAPFILE" >/dev/null 2>&1; then
    err "mkswap 失败"
    rm -f "$SWAPFILE"
    return 1
  fi
  if ! swapon "$SWAPFILE" 2>/dev/null; then
    err "swapon 失败（部分虚拟化环境不允许 Swap）"
    rm -f "$SWAPFILE" 2>/dev/null || true
    return 1
  fi
  if ! grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
    # fstab 若不以换行结尾，新条目会黏到最后一行上，可能导致开机挂载异常
    if [ -s /etc/fstab ] && [ -n "$(tail -c 1 /etc/fstab 2>/dev/null)" ]; then
      printf '\n' >>/etc/fstab
    fi
    printf '%s\n' "${SWAPFILE} none swap sw 0 0  # acxc-vps" >>/etc/fstab
  fi
  printf '%s\n' 'vm.swappiness=10' >/etc/sysctl.d/99-acxc-vps-swap.conf
  sysctl -q -w vm.swappiness=10 >/dev/null 2>&1 || true
  ok "Swap 已启用：$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')"
  return 0
}

# ---------- 时区（供"常用工具 / BBR网络加速 / Swap"里调用） ----------
# 常用时区（覆盖全球主要地区，输入编号或直接输时区名都可以）
TZ_CHOICES=(
  "Asia/Shanghai|中国（北京 / 上海）"
  "Asia/Hong_Kong|中国香港"
  "Asia/Taipei|中国台北"
  "Asia/Tokyo|日本"
  "Asia/Seoul|韩国"
  "Asia/Singapore|新加坡 / 马来西亚"
  "Asia/Bangkok|泰国 / 越南 / 印尼（UTC+7）"
  "Asia/Kolkata|印度（UTC+5:30）"
  "Asia/Dubai|阿联酋 / 中东（UTC+4）"
  "Europe/Moscow|俄罗斯莫斯科"
  "Europe/London|英国伦敦（UTC+0）"
  "Europe/Paris|法国 / 德国 / 意大利（UTC+1）"
  "America/New_York|美国东部"
  "America/Chicago|美国中部"
  "America/Denver|美国山地"
  "America/Los_Angeles|美国西部"
  "America/Sao_Paulo|巴西"
  "Australia/Sydney|澳大利亚悉尼"
  "UTC|协调世界时"
)

set_timezone() {
  local tz="Asia/Shanghai" rc=0 entry name desc i=0 tries=0

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\n%s\n' "  ${C_BLD}常用时区（输入编号即可，也可以直接输入时区名，例如 Asia/Tokyo）：${C_RST}"
    for entry in "${TZ_CHOICES[@]}"; do
      i=$((i + 1))
      name="${entry%%|*}"
      desc="${entry#*|}"
      if [ "$i" -eq 1 ]; then
        printf '  %s%2d)%s %-20s %s %s（默认）%s\n' "${C_CYN}" "$i" "${C_RST}" "$name" "$desc" "${C_DIM}" "${C_RST}"
      else
        printf '  %s%2d)%s %-20s %s\n' "${C_CYN}" "$i" "${C_RST}" "$name" "$desc"
      fi
    done
    printf '  %s%2d)%s %s\n' "${C_DIM}" 0 "${C_RST}" "保持当前时区（不改）"
    printf '\n'
    info "直接回车 = 1) Asia/Shanghai；也可以输入上面没有的时区，例如 Europe/Berlin"

    while [ "$tries" -lt 3 ]; do
      tries=$((tries + 1))
      if ! ask_value "请输入时区（编号或名称）" "Asia/Shanghai"; then return 1; fi
      tz="$REPLY"

      case "$tz" in
        0) info "保持当前时区（$(date +%Z)）"; return 0 ;;
        ''|*[!0-9]*) ;;   # 不是纯数字 → 当成时区名
        *)
          if [ "$tz" -ge 1 ] && [ "$tz" -le "${#TZ_CHOICES[@]}" ]; then
            tz="${TZ_CHOICES[$((10#$tz - 1))]%%|*}"
            info "已选择：$tz"
          else
            warn "编号超出范围（1-${#TZ_CHOICES[@]}，或 0 = 不改）"
            continue
          fi ;;
      esac

      case "$tz" in
        *[!A-Za-z0-9_/+:-]*) warn "时区格式不合法：$tz"; continue ;;
      esac
      if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$tz" ]; then
        warn "时区 $tz 不存在（用上面的编号选常用的就行）"
        continue
      fi
      break
    done

    if [ "$tries" -ge 3 ] && [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$tz" ]; then
      warn "连续输错 3 次，保持当前时区（$(date +%Z)）"
      return 1
    fi
  fi

  if have timedatectl && run timedatectl set-timezone "$tz"; then
    :
  else
    warn "timedatectl 不可用，改用直接写文件的方式"
    run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime || rc=1
    run sh -c "printf '%s\\n' '$tz' > /etc/timezone" || true
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    ok "时区已设置为 $tz（当前：$(date '+%F %T %Z')）"
  fi
  return "$rc"
}

# ---------- Swap ----------
setup_swap() {
  local mem_mb="" existing_swap="" def_swap="" swap_mb=""
  mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  existing_swap="$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  [ -n "$mem_mb" ] || mem_mb=0
  [ -n "$existing_swap" ] || existing_swap=0

  if [ "$existing_swap" -gt 0 ]; then
    ok "已经存在 Swap（${existing_swap}MB），无需创建。"
    return 0
  fi
  if [ "$mem_mb" -le 4096 ]; then def_swap="2048"; else def_swap="4096"; fi
  swap_mb="$def_swap"
  if [ "$ASSUME_YES" -eq 0 ]; then
    if ask_value "Swap 大小（MB）" "$def_swap"; then swap_mb="$REPLY"; fi
  fi
  case "$swap_mb" in
    ''|*[!0-9]*) warn "Swap 大小无效，改用默认值 ${def_swap}MB"; swap_mb="$def_swap" ;;
  esac
  create_swap "$swap_mb"
}

# ---------- BBR ----------
enable_bbr() {
  local kver="" kmaj=0 kmin=0 cc="" qd="" befor_cc=""
  kver="$(uname -r)"
  kmaj="${kver%%.*}"
  kmin="${kver#*.}"; kmin="${kmin%%.*}"
  case "$kmaj" in ''|*[!0-9]*) kmaj=0 ;; esac
  case "$kmin" in ''|*[!0-9]*) kmin=0 ;; esac

  if [ "$kmaj" -lt 4 ] || { [ "$kmaj" -eq 4 ] && [ "$kmin" -lt 9 ]; }; then
    warn "内核 ${kver} 低于 4.9，不支持 BBR，已跳过。"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 ${SYSCTL_BBR_CONF} 并执行 sysctl --system${C_RST}"
    return 0
  fi
  befor_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "内核未列出 bbr 模块，尝试加载…"
    modprobe tcp_bbr 2>/dev/null || warn "modprobe tcp_bbr 失败（容器/共享内核环境属正常）"
  fi
  cat >"$SYSCTL_BBR_CONF" <<'EOF'
# 由 acxc-vps 生成：开启 TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if [ "$cc" = "bbr" ]; then
    ok "BBR 已开启（拥塞控制：${cc}，队列：${qd:-未知}，调整前：${befor_cc:-未知}）"
  else
    warn "BBR 未生效（当前：${cc:-未知}）。OpenVZ/LXC 等共享内核环境通常不支持。"
    return 1
  fi
  return 0
}
# ============ 步骤 3：安装常用工具 / BBR网络加速 / Swap ===================
# 顺序按「使用人数 + 重要性」排；多选时编号之间要用空格隔开
# 每组格式：包名|显示名（短、好懂）|是否推荐（y = 直接回车时会装上，只标 3 个）
TOOL_ACT=""
TOOL_ITEMS=(
  "curl wget ca-certificates gnupg|下载与证书|y"
  "fail2ban|防 SSH 爆破|y"
  "swap|加虚拟内存|y"
  "ufw|防火墙|n"
  "htop tmux lsof|进程 / 端口|n"
  "vim nano|文本编辑|n"
  "git rsync unzip zip|传文件 / 解压|n"
  "bash-completion|Tab 补全|n"
  "jq tree ncdu|磁盘占用|n"
  "net-tools dnsutils mtr-tiny traceroute|网络排障|n"
  "timezone|设置时区|n"
  "bbr|BBR 加速|n"
)

# ---------- 工具项：状态查询 / 开与关 / 安装与卸载 ----------
fail2ban_state() {
  if have systemctl && systemctl is-active fail2ban >/dev/null 2>&1; then
    printf '运行中'
  elif have dpkg && dpkg -s fail2ban >/dev/null 2>&1; then
    printf '已安装（未运行）'
  else
    printf '未安装'
  fi
}

fail2ban_disable() {
  info "停止并禁用 fail2ban…"
  run systemctl stop fail2ban || true
  run systemctl disable fail2ban || true
  if [ -f "$FAIL2BAN_CONF" ]; then
    run rm -f "$FAIL2BAN_CONF" && ok "已删除配置：${FAIL2BAN_CONF}"
  fi
  ok "fail2ban 已停止并禁用（软件包保留，需要时可以再开启）"
  return 0
}

swap_state() {
  local mb
  mb="$(swap_total_mb)"
  if [ "${mb:-0}" -gt 0 ]; then printf '已启用 %sMB' "$mb"; else printf '未启用'; fi
}

swap_disable() {
  info "关闭并删除 Swap…"
  # 不是 swap 文件时 swapoff 会报错，用 || true 忽略即可
  run swapoff "$SWAPFILE" || true
  if [ -f "$SWAPFILE" ]; then
    run rm -f "$SWAPFILE" || true
  fi
  if grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
    run sed -i "\|${SWAPFILE}|d" /etc/fstab || true
  fi
  if [ -f /etc/sysctl.d/99-acxc-vps-swap.conf ]; then
    run rm -f /etc/sysctl.d/99-acxc-vps-swap.conf || true
  fi
  ok "Swap 已关闭并删除（当前：$(swap_state)）"
  return 0
}

bbr_state() {
  local cc=""
  if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    if IFS= read -r cc </proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then :; fi
  fi
  if [ "$cc" = "bbr" ]; then printf '已开启'; else printf '未开启（%s）' "${cc:-未知}"; fi
}

bbr_disable() {
  info "关闭 BBR…"
  run rm -f "$SYSCTL_BBR_CONF" || true
  run sysctl -q -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  run sysctl -q -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  ok "BBR 已关闭（当前：$(bbr_state)）"
  return 0
}

ufw_state() {
  if ! have ufw; then printf '未安装'; return 0; fi
  case "$(ufw status 2>/dev/null)" in
    *"Status: active"*) printf '已启用' ;;
    *) printf '已停止' ;;
  esac
}

ufw_port_helper() { # $1=1 放行 / 2 关闭
  local port="" act="$1"
  if ! ask_value "请输入端口号" ""; then return 0; fi
  port="$(trim "$REPLY")"
  if ! valid_port "$port"; then
    warn "端口不合法（应为 1-65535 的数字）：$port"
    return 1
  fi
  port="$((10#$port))"
  if [ "$act" -eq 2 ]; then
    case " $(current_ssh_ports) " in
      *" $port "*)
        warn "端口 ${port} 是当前 SSH 端口，关掉会让你连不上服务器！"
        if ! ask_yn "确定还要关闭吗？" n; then return 0; fi ;;
    esac
  fi
  if [ "$act" -eq 1 ]; then
    if run ufw allow "${port}/tcp" 2>/dev/null; then
      ok "已放行 ${port}/tcp"
    else
      warn "放行失败，请手动执行：ufw allow ${port}/tcp"
      return 1
    fi
  else
    if run ufw delete allow "${port}/tcp" 2>/dev/null; then
      ok "已关闭 ${port}/tcp"
    else
      warn "关闭失败（这个端口可能本来就没放行），请手动检查：ufw status numbered"
      return 1
    fi
  fi
  return 0
}

ufw_menu() {
  local line="" rc=0
  printf '\n  %s防火墙（UFW）%s　当前：%s\n' "${C_BLD}" "${C_RST}" "$(ufw_state)"
  printf '   %s1)%s 安装并启用（自动先放行 SSH 端口）\n' "${C_GRN}" "${C_RST}"
  printf '   %s2)%s 放行某个端口\n' "${C_GRN}" "${C_RST}"
  printf '   %s3)%s 关闭某个端口\n' "${C_GRN}" "${C_RST}"
  printf '   %s0)%s 跳过\n' "${C_DIM}" "${C_RST}"
  while :; do
    if ! read_line "请选择（回车=1）"; then return 0; fi
    line="$(trim "$(menu_clean_input "$REPLY")")"
    case "$line" in
      ''|1) install_ufw || rc=1; return "$rc" ;;
      2) ufw_port_helper 1 || rc=1; return "$rc" ;;
      3) ufw_port_helper 2 || rc=1; return "$rc" ;;
      0|q|Q) return 0 ;;
      *) warn "请输入 0-3" ;;
    esac
  done
}

# 安装 / 卸载 小菜单：回显 i（安装）u（卸载）空（跳过）
tool_pick_action() { # $1=标题 $2=安装文案 $3=卸载文案 → 结果放 TOOL_ACT（i/u/空）
  local line=""
  TOOL_ACT=""
  printf '\n  %s%s%s\n' "${C_BLD}" "$1" "${C_RST}"
  printf '   %s1)%s %s\n' "${C_GRN}" "${C_RST}" "${2:-安装}"
  printf '   %s2)%s %s\n' "${C_BLD}${C_YEL}" "${C_RST}" "${3:-卸载}"
  printf '   %s0)%s 跳过\n' "${C_DIM}" "${C_RST}"
  while :; do
    if ! read_line "请选择（回车=1）"; then return 0; fi
    line="$(trim "$(menu_clean_input "$REPLY")")"
    case "$line" in
      ''|1) TOOL_ACT="i"; return 0 ;;
      2) TOOL_ACT="u"; return 0 ;;
      0|q|Q) return 0 ;;
      *) warn "请输入 0 / 1 / 2" ;;
    esac
  done
}

tool_pkgs_install() { # $1=标题 $2=包名
  info "安装：${1}（$(printf '%s' "$2" | tr -s ' ')）…"
  # shellcheck disable=SC2086
  if run env DEBIAN_FRONTEND=noninteractive apt-get -y install $2; then
    ok "已安装：${1}"
    return 0
  fi
  warn "整体安装失败，改为逐个装（个别包在精简系统上可能没有）…"
  local sel="" rc=0
  for sel in $2; do
    run env DEBIAN_FRONTEND=noninteractive apt-get -y install "$sel" >/dev/null 2>&1 || {
      warn "安装失败：$sel"
      rc=1
    }
  done
  return "$rc"
}

tool_pkgs_remove() { # $1=标题 $2=包名
  if [ "$1" = "下载与证书" ]; then
    warn "卸载${1}会影响 apt 更新与下载（ca-certificates / gnupg 是很多工具的前置依赖）。"
    if ! ask_yn "确定还要卸载吗？" n; then return 0; fi
  fi
  info "卸载：${1}（$(printf '%s' "$2" | tr -s ' ')）…"
  # shellcheck disable=SC2086
  if run env DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge $2; then
    ok "已卸载：${1}"
    return 0
  fi
  warn "卸载时有报错，可稍后手动检查（dpkg -l | grep 包名）"
  return 1
}

step_extras() {
  local i=0 raw="" line="" tok="" ok=1 rcp=0 pad=0 act=""
  local -a g_pkgs=() g_title=() g_rec=() g_label=()
  local entry pkgs="" title="" rec="" sel=""

  for entry in "${TOOL_ITEMS[@]}"; do
    IFS='|' read -r pkgs title rec <<<"$entry"
    g_pkgs+=("$pkgs"); g_title+=("$title"); g_rec+=("$rec")
  done

  # 行名按显示宽度补齐（中文算 2 列），只算一次，保证 [推荐] 那一列是对齐的
  local maxw=0
  for i in "${!g_title[@]}"; do
    local w; disp_width "${g_title[$i]}"; w=$DW
    [ "$w" -gt "$maxw" ] && maxw="$w"
  done
  [ "$maxw" -lt 20 ] && maxw=20
  for i in "${!g_title[@]}"; do
    disp_width "${g_title[$i]}"; pad=$((maxw + 2 - DW))
    [ "$pad" -lt 1 ] && pad=1
    g_label+=("$(printf '%s%*s' "${g_title[$i]}" "$pad" "")")
  done

  # 外层循环：只选一项时，处理完回到本菜单；选两项以上或 a（全部）处理完回上级菜单
  while :; do
    printf '\n%s\n' "  ${C_BLD}可安装 / 可设置的项目：${C_RST}"
    for i in "${!g_title[@]}"; do
      if [ "${g_rec[$i]}" = y ]; then
        printf '  %s%2d)%s %s %s推荐%s\n' "${C_CYN}" "$((i + 1))" "${C_RST}" "${g_label[$i]}" "${C_GRN}" "${C_RST}"
      else
        printf '  %s%2d)%s %s\n' "${C_CYN}" "$((i + 1))" "${C_RST}" "${g_title[$i]}"
      fi
    done
    printf '  %s%2d)%s %s\n' "${C_DIM}" 0 "${C_RST}" "返回主菜单"
    printf '\n'
    info "多个编号之间要用空格隔开（例如：1 3 5）；直接回车＝只装标了「推荐」的项目；a＝全部"

    rcp=0
    # 内层只看输入：输错就地重问，不重画列表
    while :; do
      if [ "$ASSUME_YES" -eq 1 ]; then
        PLAN_TOOLS=()
        for i in "${!g_pkgs[@]}"; do
          [ "${g_rec[$i]}" = y ] && plan_tool_add "$i"
        done
        raw=""
      else
        if ! read_line "请选择"; then return 1; fi
        raw="${REPLY}"
      fi

      if [ -z "$(trim "$raw")" ]; then
        PLAN_TOOLS=()
        for i in "${!g_pkgs[@]}"; do
          [ "${g_rec[$i]}" = y ] && plan_tool_add "$i"
        done
      else
        line="$(trim "$(menu_clean_input "$raw")")"
        case "$line" in
          0|q|Q) mark_no_change; return 0 ;;
          a|A|all|ALL)
            PLAN_TOOLS=()
            for i in "${!g_pkgs[@]}"; do plan_tool_add "$i"; done ;;
          *)
            PLAN_TOOLS=()
            ok=1
            # shellcheck disable=SC2086
            for tok in $(printf '%s' "$line" | tr ' ' '\n'); do
              [ -n "$tok" ] || continue
              case "$tok" in
                *[!0-9]*) ok=0; break ;;
              esac
              if [ "$tok" -lt 1 ] || [ "$tok" -gt "${#g_pkgs[@]}" ]; then ok=0; break; fi
              plan_tool_add "$((10#$tok - 1))"
            done
            if [ "$ok" -ne 1 ] || [ "${#PLAN_TOOLS[@]}" -eq 0 ]; then
              warn "编号不对：请输入 1-${#g_pkgs[@]}，多个编号之间用空格隔开（例如：1 3）"
              continue
            fi ;;
        esac
      fi
      break
    done

    if [ "${#PLAN_TOOLS[@]}" -eq 0 ]; then
      info "没有选择任何项目。"
      refresh_screen
      continue
    fi

    printf '\n'
    printf '\n'
    for i in "${PLAN_TOOLS[@]}"; do
      pkgs="${g_pkgs[$i]}"
      title="${g_title[$i]}"
      act=""
      case "$pkgs" in
        timezone)
          set_timezone || rcp=1
          continue ;;
        fail2ban)
          [ "$ASSUME_YES" -eq 1 ] || tool_pick_action "防 SSH 爆破（fail2ban）　当前：$(fail2ban_state)" "安装并启用" "停止并禁用"; act="$TOOL_ACT"
          case "$act" in
            ''|i) step_fail2ban || rcp=1 ;;
            u) fail2ban_disable || rcp=1 ;;
          esac
          continue ;;
        swap)
          [ "$ASSUME_YES" -eq 1 ] || tool_pick_action "虚拟内存（Swap）　当前：$(swap_state)" "创建并启用" "关闭并删除"; act="$TOOL_ACT"
          case "$act" in
            ''|i) setup_swap || rcp=1 ;;
            u) swap_disable || rcp=1 ;;
          esac
          continue ;;
        ufw)
          if [ "$ASSUME_YES" -eq 1 ]; then
            install_ufw || rcp=1
          else
            ufw_menu || rcp=1
          fi
          continue ;;
        bbr)
          [ "$ASSUME_YES" -eq 1 ] || tool_pick_action "BBR 加速　当前：$(bbr_state)" "开启" "关闭"; act="$TOOL_ACT"
          case "$act" in
            ''|i) enable_bbr || rcp=1 ;;
            u) bbr_disable || rcp=1 ;;
          esac
          continue ;;
      esac
      # 普通软件包：安装 或 卸载
      if [ "$ASSUME_YES" -eq 1 ]; then
        act="i"
      else
        tool_pick_action "${title}（$(printf ''%s'' "$pkgs" | tr -s '' '')）" "安装" "卸载"
        act="$TOOL_ACT"
      fi
      case "$act" in
        i) tool_pkgs_install "$title" "$pkgs" || rcp=1 ;;
        u) tool_pkgs_remove "$title" "$pkgs" || rcp=1 ;;
        *) info "已跳过：${title}" ;;
      esac
    done
    printf '\n'
    if [ "$rcp" -eq 0 ]; then
      ok "选中的项目都处理完了。"
    else
      warn "有部分项目没装上，可稍后重试。"
    fi

    # 只选了一项：回到本菜单继续选；选多项 / a / 无人值守：回上级菜单
    if [ "$ASSUME_YES" -eq 0 ] && [ "${#PLAN_TOOLS[@]}" -eq 1 ]; then
      refresh_screen
      continue
    fi
    return "$rcp"
  done
}
# ============================== 计划与执行 ==================================
list_steps() {
  local entry slug title def fn
  printf '%s 可选步骤：\n' "$SCRIPT_NAME"
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    printf '  %-13s %-40s 默认: %s\n' "$slug" "$title" "$def"
  done
  printf '\n用法：--only sysupdate,access   /   --skip extras\n'
}

# 等用户按回车（看完长输出后继续）
pause_enter() {
  printf '\n  %s\n' "${C_DIM}（按回车继续）${C_RST}"
  _prompt_line "  " "" >/dev/null 2>&1 || true
  return 0
}

# 快捷命令：生成 /usr/local/bin/acxc，以后直接输入 acxc 就能打开
shortcut_body() {
  cat <<EOF
#!/bin/sh
# ACXC16-VPS新机一键脚本 的快捷命令（自动生成；删除本文件即可取消快捷方式）
# acxc-shortcut-ver: 2
URL="https://github.com/${REPO_SLUG}/releases/latest/download/init.sh"
CACHE="${CACHE_DIR}/acxc.sh"

# 有本地缓存就直接用（秒开）；只要缓存超过 1 小时，就在后台悄悄拉最新版，
# 这样下次打开就是新版，又不会拖慢这次启动。
if [ -s "\$CACHE" ]; then
  if [ -n "\$(find "\$CACHE" -mmin +60 2>/dev/null)" ] && command -v curl >/dev/null 2>&1; then
    ( curl -fsSL "\$URL" -o "\$CACHE.tmp" 2>/dev/null && mv "\$CACHE.tmp" "\$CACHE" ) >/dev/null 2>&1 &
  fi
  exec bash "\$CACHE" "\$@"
fi

# 第一次没有缓存，才同步下载
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "\$URL" -o "\$CACHE.tmp" 2>/dev/null && mv "\$CACHE.tmp" "\$CACHE"
fi
[ -s "\$CACHE" ] || { echo "下载失败：请检查网络后重试"; exit 1; }
exec bash "\$CACHE" "\$@"
EOF
}

install_shortcut() { # $1=quiet：自动安装时用，没变化就完全不说话
  local quiet="${1:-}" target="${SHORTCUT_DIR}/${SHORTCUT_NAME}" tmp="" changed=0 src=""
  if [ "$DRY_RUN" -eq 1 ] && [ -z "${ACXC_VPS_SHORTCUT_DIR:-}" ]; then
    info "[dry-run] 将安装快捷命令：${target}"
    return 0
  fi
  if ! mkdir -p "$SHORTCUT_DIR" "$CACHE_DIR" 2>/dev/null; then
    warn "无法创建目录：$SHORTCUT_DIR（需要 root 权限）"
    return 1
  fi
  # 快速判断：内容关键行都在 → 直接跳过（不建临时文件、不跑 cmp/cat）
  if [ -f "$target" ]; then
    local content=""
    content="$(< "$target")"
    if [ -n "$content" ]; then
      case "$content" in ''#!/bin/sh''*) ;; *) content="" ;; esac
    fi
    if [ -n "$content" ]; then
      case "$content" in *"$SHORTCUT_VER_MARK"*) ;; *) content="" ;; esac
    fi
    if [ -n "$content" ]; then
      # shellcheck disable=SC2016  # 这里是字面量，就是要匹配包装脚本里那行
      case "$content" in *'exec bash "$CACHE"'*) ;; *) content="" ;; esac
    fi
    if [ -n "$content" ]; then
      src="${BASH_SOURCE[0]:-}"
      if [ -n "$src" ] && [ -r "$src" ] && [ "$src" != "${CACHE_DIR}/acxc.sh" ] && [ ! -f "${CACHE_DIR}/acxc.sh" ]; then
        cp -f "$src" "${CACHE_DIR}/acxc.sh" 2>/dev/null || true
      fi
      if [ -z "$quiet" ]; then ok "快捷命令已是最新：${target}"; fi
      return 0
    fi
  fi
  tmp="$(mktemp)" || return 1
  shortcut_body >"$tmp"
  if [ ! -f "$target" ] || ! cmp -s "$tmp" "$target"; then
    if cat "$tmp" >"$target" 2>/dev/null; then
      chmod 755 "$target" 2>/dev/null || true
      changed=1
    else
      rm -f "$tmp"
      warn "写入失败：${target}（需要 root 权限）"
      return 1
    fi
  fi
  rm -f "$tmp"
  # 顺便缓存一份当前脚本，断网时也能用
  src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -r "$src" ] && [ "$src" != "${CACHE_DIR}/acxc.sh" ]; then
    cp -f "$src" "${CACHE_DIR}/acxc.sh" 2>/dev/null || true
  fi
  if [ "$changed" -eq 1 ]; then
    ok "快捷命令已就绪：直接输入 ${SHORTCUT_NAME} 就能打开（删除 ${target} 可移除）"
  elif [ -z "$quiet" ]; then
    ok "快捷命令已是最新：${target}"
  fi
  return 0
}

plan_tool_add() { # $1=工具项下标 → 记录到待安装列表（自动去重）
  local i
  for i in "${PLAN_TOOLS[@]:-}"; do
    [ "$i" = "$1" ] && return 0
  done
  PLAN_TOOLS+=("$1")
  return 0
}

plan_add() { # $1=步骤标识 → 追加到执行计划
  local entry slug title def fn
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    if [ "$slug" = "$1" ]; then
      PLAN_SLUGS+=("$slug"); PLAN_TITLES+=("$title"); PLAN_FUNCS+=("$fn")
      return 0
    fi
  done
  return 1
}

# ============================== 重启服务 ====================================
# 重启脚本本身：重新载入（更新过脚本后用它让新版立刻生效）
restart_script() {
  local src="${BASH_SOURCE[0]:-}" target="${CACHE_DIR}/acxc.sh"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将重新载入脚本：${src:-<stdin>}"
    return 0
  fi

  # 正在运行的那个文件优先（从文件运行 / 通过 acxc 运行都属于这种）
  if [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ]; then
    info "重新载入脚本：$src"
    printf '\n'
    exec bash "$src" "${ORIG_ARGS[@]}"
  fi
  # curl | bash 这种没有文件的：用本地缓存（acxc 那份）
  if [ -s "$target" ]; then
    info "重新载入本地缓存：$target"
    printf '\n'
    exec bash "$target" "${ORIG_ARGS[@]}"
  fi
  # 都没有就先刷新缓存再重启
  info "没有本地缓存，先拉一份最新版…"
  install_shortcut quiet 2>/dev/null || true
  if [ -s "$target" ]; then
    printf '\n'
    exec bash "$target" "${ORIG_ARGS[@]}"
  fi
  warn "无法重启脚本：找不到脚本文件，可以用 6) 更新脚本 先刷新本地缓存"
  return 1
}

restart_service_now() { # $1=ssh|fail2ban
  case "$1" in
    ssh)
      have sshd || { warn "本机没有 sshd，跳过。"; return 1; }
      restart_ssh ;;
    fail2ban)
      have fail2ban-client || { warn "本机没有安装 fail2ban，跳过。"; return 1; }
      if have systemctl; then
        run systemctl restart fail2ban
      else
        run service fail2ban restart
      fi ;;
    *)
      return 1 ;;
  esac
}

step_restart() {
  local choice="" rc=0
  screen_header "重启服务"
  printf '  %s1)%s 重启 SSH 服务\n' "${C_GRN}" "${C_RST}"
  printf '  %s2)%s 重启 fail2ban\n' "${C_GRN}" "${C_RST}"
  printf '  %s3)%s 重启脚本\n' "${C_GRN}" "${C_RST}"
  printf '  %s4)%s 全部重启（SSH + fail2ban + 脚本）\n' "${C_GRN}" "${C_RST}"
  printf '  %s0)%s 返回主菜单\n' "${C_DIM}" "${C_RST}"
  printf '\n'
  info "重启 SSH 不会断开你已经登录的连接。"
  while :; do
    if ! read_line "请选择"; then return 1; fi
    choice="$(trim "$(menu_clean_input "$REPLY")")"

    case "$choice" in
      0|q|Q) mark_no_change; return 0 ;;
      1)
        if restart_service_now ssh; then ok "SSH 服务已重启"; else rc=1; fi ;;
      2)
        if restart_service_now fail2ban; then ok "fail2ban 已重启"; else rc=1; fi ;;
      3)
        # 成功了就会 exec 重新载入，不会再走到下面
        restart_script || rc=1
        return "$rc" ;;
      4)
        if restart_service_now ssh; then ok "SSH 服务已重启"; else rc=1; fi
        if restart_service_now fail2ban; then ok "fail2ban 已重启"; else rc=1; fi
        # 全部重启也包含脚本本身：放在最后，重新载入后本次运行就结束了
        info "接着重启脚本（重新载入）…"
        restart_script || rc=1
        return "$rc" ;;
      "")
        info "请输入编号（0-4）；0 = 返回主菜单"
        continue ;;
      *)
        warn "无效的选择：$choice（请输入 0-4）"
        continue ;;
    esac
    printf '\n'
    return "$rc"
  done
}

# ============================== 卸载 / 清理 =================================
uninstall_shortcut() {
  if [ -f "${SHORTCUT_DIR}/${SHORTCUT_NAME}" ]; then
    if run rm -f "${SHORTCUT_DIR}/${SHORTCUT_NAME}"; then
      ok "已删除快捷命令：${SHORTCUT_DIR}/${SHORTCUT_NAME}"
    fi
  else
    info "没有找到快捷命令：${SHORTCUT_DIR}/${SHORTCUT_NAME}"
  fi
  if [ -d "$CACHE_DIR" ]; then
    if run rm -rf "$CACHE_DIR"; then
      ok "已删除脚本缓存：${CACHE_DIR}"
    fi
  fi
  return 0
}

uninstall_log() {
  local f=""
  for f in "$LOG_FILE" "$LEGACY_LOG"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if ask_yn "删除日志文件 $f ？" y; then
      run rm -f "$f" && { ok "已删除：$f"; }
    fi
  done
  return 0
}

uninstall_tools() {
  local entry pkgs="" p="" list="" skip=""
  for entry in "${TOOL_ITEMS[@]}"; do
    pkgs="${entry%%|*}"
    case "$pkgs" in
      fail2ban|timezone|swap|bbr) continue ;;
    esac
    for p in $pkgs; do
      # 这几个卸了可能影响 HTTPS / 软件源，安全起见保留
      case "$p" in
        ca-certificates|gnupg) skip="${skip}${skip:+ }${p}"; continue ;;
      esac
      if have dpkg && dpkg -s "$p" >/dev/null 2>&1; then
        list="${list}${list:+ }${p}"
      fi
    done
  done

  if [ -z "$list" ]; then
    info "没有检测到脚本装过的常用工具。"
  else
    info "将要卸载：${list}"
    if ask_yn "确认卸载上面这些软件包？" y; then
      # shellcheck disable=SC2086
      if run env DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge $list; then
        ok "已卸载常用工具"
      else
        warn "卸载时有报错，可稍后手动检查"
      fi
    else
      info "已跳过卸载软件包。"
    fi
  fi
  [ -n "$skip" ] && info "已保留（卸载会影响下载 / 证书）：${skip}"

  # CPU 微码（属于"更新过的驱动"）
  for p in intel-microcode amd64-microcode; do
    if have dpkg && dpkg -s "$p" >/dev/null 2>&1; then
      if ask_yn "是否卸载 CPU 微码包 ${p}？（一般是安全更新，卸载后建议重启）" y; then
        run env DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "$p" && ok "已卸载：$p"
      fi
    fi
  done
  info "内核与内核模块不会动（误删可能导致无法开机），需要的话请手动处理。"
  return 0
}

uninstall_configs() {
  local newest=""

  # SSH：删掉受管配置，回到系统原本的设置
  if [ -f "$MANAGED_SSHD_CONF" ]; then
    info "当前受管的 SSH 配置：$(printf '%s' "$(ssh_managed_keys 2>/dev/null)" | tr '\n' ' ')"
    if ask_yn "删除受管的 SSH 端口配置（${MANAGED_SSHD_CONF}），恢复系统原来的 SSH 设置？" y; then
      stamp="$(date '+%Y%m%d-%H%M%S')"
      run cp -a "$MANAGED_SSHD_CONF" "/root/acxc-vps-backup/removed-${stamp}-00-acxc-vps.conf" 2>/dev/null || true
      if run rm -f "$MANAGED_SSHD_CONF"; then
        ok "已删除：${MANAGED_SSHD_CONF}"
      fi
      if [ -f /etc/ssh/sshd_config ]; then
        run remove_managed_inline_block /etc/ssh/sshd_config || true
        if [ "$DRY_RUN" -eq 0 ]; then
          if ssh_config_ok; then
            restart_ssh && ok "SSH 已重启，现在使用系统原本的端口"
          else
            warn "SSH 配置校验没过，正在从备份还原…"
            newest="$(find /root/acxc-vps-backup -maxdepth 1 -name '*-ssh' -type d 2>/dev/null | sort -r | head -n 1)"
            if [ -n "$newest" ]; then
              LAST_SSH_BACKUP="$newest"
              ssh_restore_backup && ok "已从备份还原：${newest}"
            else
              err "找不到备份，请手动检查 /etc/ssh/sshd_config"
            fi
          fi
        fi
      fi
    else
      info "已跳过 SSH 配置删除。"
    fi
  else
    info "没有找到受管的 SSH 配置。"
  fi

  # fail2ban 配置（可选卸载软件包）
  if [ -f "$FAIL2BAN_CONF" ]; then
    if ask_yn "删除 fail2ban 配置（${FAIL2BAN_CONF}）？" y; then
      run rm -f "$FAIL2BAN_CONF" && { ok "已删除：${FAIL2BAN_CONF}"; }
      if have fail2ban-client; then
        if ask_yn "是否顺便卸载 fail2ban 软件包？" y; then
          run env DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge fail2ban && {
            ok "已卸载 fail2ban"
          }
        else
          if have systemctl; then run systemctl restart fail2ban || true; fi
          ok "fail2ban 配置已删除，服务已重启"
        fi
      fi
    fi
  else
    info "没有找到 fail2ban 配置。"
  fi

  # BBR
  if [ -f "$SYSCTL_BBR_CONF" ]; then
    if ask_yn "关闭并删除 BBR 设置（${SYSCTL_BBR_CONF}）？" y; then
      run rm -f "$SYSCTL_BBR_CONF" && { ok "已删除：${SYSCTL_BBR_CONF}"; }
      if [ "$DRY_RUN" -eq 0 ]; then
        sysctl --system >/dev/null 2>&1 || true
        ok "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
      fi
    fi
  fi

  # UFW：先关防火墙再卸载，避免清到一半把自己关在门外
  if have ufw; then
    if [ "$DRY_RUN" -eq 0 ] && case "$(ufw status 2>/dev/null)" in *"Status: active"*) true ;; *) false ;; esac; then
      if ask_yn "关闭 UFW 防火墙（ufw disable）？" y; then
        run ufw --force disable && ok "ufw 已关闭"
      fi
    fi
    if ask_yn "是否卸载 ufw 软件包？" y; then
      run env DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge ufw && ok "已卸载 ufw"
    fi
  fi

  # Swap
  if [ -f "$SWAPFILE" ]; then
    if ask_yn "关闭并删除 Swap 交换文件（${SWAPFILE}）？" y; then
      run swapoff "$SWAPFILE" 2>/dev/null || true
      run sed -i '\|# acxc-vps$|d' /etc/fstab || true
      run rm -f "$SWAPFILE" /etc/sysctl.d/99-acxc-vps-swap.conf && { ok "已删除 Swap 与相关配置"; }
    fi
  fi
  return 0
}

uninstall_all() {
  warn "完全卸载会：删除快捷命令与缓存、受管的 SSH / fail2ban / BBR / Swap 配置、日志、以及脚本装过的工具包。"
  warn "SSH 会恢复到系统原来的设置（如果原来的端口是 22，请确保 22 已放行，否则可能连不上）。"
  if ! ask_yn "确认要完全卸载吗？" y; then
    info "已取消。"
    return 0
  fi
  uninstall_tools
  uninstall_configs
  uninstall_log
  uninstall_shortcut
  if [ -d /root/acxc-vps-backup ]; then
    if ask_yn "是否一并删除备份目录 /root/acxc-vps-backup ？（删掉后无法再用脚本回滚）" y; then
      run rm -rf /root/acxc-vps-backup && { ok "已删除备份目录"; }
    fi
  fi
  printf '\n'
  ok "卸载流程已跑完。"
  info "如果你是把脚本下载到服务器上运行的，最后手动删掉那个文件即可，例如：rm -f ./init.sh"
  return 0
}

step_uninstall() {
  local choice=""
  screen_header "卸载 / 清理"
  printf '%s\n' "  ${C_BLD}可以只做其中几项（选 0 返回主菜单）：${C_RST}"
  printf '  %s1)%s 删除快捷命令与脚本缓存（acxc）\n' "${C_GRN}" "${C_RST}"
  printf '  %s2)%s 卸载脚本装过的常用工具（含 CPU 微码）\n' "${C_GRN}" "${C_RST}"
  printf '  %s3)%s 删除运行日志\n' "${C_GRN}" "${C_RST}"
  printf '  %s4)%s 还原 SSH / 删除 fail2ban、ufw、BBR、Swap 配置\n' "${C_GRN}" "${C_RST}"
  printf '  %s5)%s 完全卸载（1-4 全做，并可选删除备份）\n' "${C_YEL}" "${C_RST}"
  printf '  %s0)%s 返回主菜单\n' "${C_DIM}" "${C_RST}"
  printf '\n'
  while :; do
    if ! read_line "请选择"; then return 1; fi
    choice="$(trim "$(menu_clean_input "$REPLY")")"

    case "$choice" in
      0|q|Q) mark_no_change; return 0 ;;
      1) uninstall_shortcut ;;
      2) uninstall_tools ;;
      3) uninstall_log ;;
      4) uninstall_configs ;;
      5) uninstall_all ;;
      "") info "请输入编号（0-5）；0 = 返回主菜单"; continue ;;
      *) warn "无效的选择：$choice（请输入 0-5）"; continue ;;
    esac
    printf '\n'
    return 0
  done
}

# ============================== 状态表 ======================================
# 性能说明：状态表整块缓存，只有执行过操作才重算；每行状态只用本地快速命令
# （dpkg-query / /proc / passwd -S / systemctl），不跑 apt 这类慢命令。
STATUS_TABLE_CACHE=""

tools_installed_count() { # "9/10"
  local pkg="" n=0 total=0
  for pkg in curl wget vim htop tmux git rsync jq unzip lsof; do
    total=$((total + 1))
    if have "$pkg"; then n=$((n + 1)); fi
  done
  printf '%s/%s' "$n" "$total"
}

swap_total_mb() { # 纯 bash 读 /proc/meminfo，不起进程
  local line="" v=""
  if [ -r /proc/meminfo ]; then
    while IFS= read -r line; do
      case "$line" in
        SwapTotal:*) v="${line#SwapTotal:}"; break ;;
      esac
    done </proc/meminfo 2>/dev/null
  fi
  v="${v// /}"
  v="${v%%[!0-9]*}"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' $((v / 1024))
}

status_kernel() { # 当前内核 + 是否装了更新的内核（尽量不起进程）
  local running="${KERNEL_RELEASE:-}" newest="" out="" f="" list=""
  if [ -z "$running" ]; then running="$(uname -r)"; fi
  for f in /boot/vmlinuz-[0-9]*; do
    [ -e "$f" ] || continue
    list="${list}${list:+
}${f##*/vmlinuz-}"
  done
  if [ -n "$list" ]; then
    newest="$(printf '%s\n' "$list" | sort -V 2>/dev/null | tail -n 1)"
  else
    newest="$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sed -e 's|^linux-image-||' | sort -V 2>/dev/null | tail -n 1)"
  fi
  if [ -n "$newest" ] && [ "$newest" != "$running" ]; then
    out="${running} → ${newest}（重启后生效）"
  else
    out="${running}（已是最新）"
  fi
  printf '%s' "$out"
}

status_ssh() {
  local p=""
  CSP_FAST=1
  p="$(trim "$(current_ssh_ports)")"
  CSP_FAST=0
  [ -n "$p" ] || p="$(trim "$SSH_M_PORTS")"
  if [ -n "$p" ]; then
    printf '端口 %s' "$p"
  else
    printf '端口未知'
  fi
}

status_passwd() {
  local line="" st=""
  line="$(passwd -S root 2>/dev/null)" || line=""
  st="$(printf '%s' "$line" | awk '{print $2}')"
  case "$st" in
    P) printf '密码已设置' ;;
    L) printf '密码已锁定' ;;
    NP) printf '密码未设置' ;;
    '') printf '密码未知' ;;
    *) printf '密码 %s' "$st" ;;
  esac
}

status_extras() {
  local out="" sw="" cc="" gb="" line="" st_f2b="" st_ufw="" asked=0
  out="工具 $(tools_installed_count)"
  # 一次 systemctl 问出两个服务的状态，省一次进程启动
  if have systemctl; then
    asked=1
    while IFS= read -r line; do
      case "$line" in
        fail2ban|fail2ban.service) st_f2b="$line" ;;
        ufw|ufw.service) st_ufw="$line" ;;
      esac
    done < <(systemctl is-active fail2ban ufw 2>/dev/null)
  fi
  if [ "$asked" -eq 0 ]; then
    if have systemctl && systemctl is-active fail2ban >/dev/null 2>&1; then st_f2b="active"; fi
    if have systemctl && systemctl is-active ufw >/dev/null 2>&1; then st_ufw="active"; fi
  fi
  if have fail2ban-client || [ -n "$st_f2b" ]; then
    case "$st_f2b" in
      active|activating) out="${out} · fail2ban 运行中" ;;
      *) out="${out} · fail2ban 已停" ;;
    esac
  else
    out="${out} · fail2ban 未装"
  fi
  if have ufw; then
    case "$st_ufw" in
      active|activating) out="${out} · ufw 开" ;;
      *)
        if [ "$DRY_RUN" -eq 0 ] && case "$(ufw status 2>/dev/null)" in *"Status: active"*) true ;; *) false ;; esac; then
          out="${out} · ufw 开"
        else
          out="${out} · ufw 关"
        fi ;;
    esac
  fi
  sw="$(swap_total_mb)"
  if [ "$sw" -gt 0 ]; then
    if [ "$sw" -ge 1024 ]; then
      gb="$((sw / 1024)).$(((sw % 1024) * 10 / 1024))G"
      out="${out} · Swap ${gb}"
    else
      out="${out} · Swap ${sw}M"
    fi
  else
    out="${out} · 无 Swap"
  fi
  if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    if IFS= read -r cc </proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then :; fi
  fi
  if [ "$cc" = "bbr" ]; then out="${out} · BBR 开"; else out="${out} · BBR 关"; fi
  printf '%s' "$out"
}

status_access() { # 密码 + 端口，两件一起说
  printf '%s · %s' "$(status_passwd)" "$(status_ssh)"
}

status_of() { # $1=步骤标识 → 输出状态文字
  case "$1" in
    sysupdate)   status_kernel ;;
    access)      status_access ;;
    extras)      status_extras ;;
    *)           printf '—' ;;
  esac
}

# 状态表里的短名（简洁一点，跟菜单一一对应）
status_label() { # $1=步骤标识 $2=完整名称
  case "$1" in
    sysupdate) printf '内核 / 驱动 / 固件' ;;
    access)    printf 'root 密码 / SSH 端口' ;;
    extras)    printf '常用工具 / 网络加速' ;;
    *)         printf '%s' "$2" ;;
  esac
}

# 大字图标（ACXC，只拼一次，之后复用）
SCRIPT_BANNER=""
build_banner() {
  [ -n "$SCRIPT_BANNER" ] && return 0
  local nl=$'\n'
  local art=""
  art="${art} █████   █████  ██   ██  █████ ${nl}"
  art="${art}██   ██ ██       ██ ██  ██     ${nl}"
  art="${art}███████ ██        ███   ██     ${nl}"
  art="${art}██   ██ ██       ██ ██  ██     ${nl}"
  art="${art}██   ██  █████  ██   ██  █████ ${nl}"
  SCRIPT_BANNER="${art}${nl}"
  return 0
}

# 每个"画面"（主菜单 / 二级菜单 / 步骤）顶部都先来一遍这个大图标 + 一行副标题
screen_header() { # $1=副标题（可空）
  build_banner
  printf '%s' "${C_BLD}${C_CYN}${SCRIPT_BANNER}${C_RST}"
  if [ -n "${1:-}" ]; then
    printf '  %s\n\n' "${C_BLD}${1}${C_RST}"
  fi
  return 0
}
show_status_table() {
  local entry slug title def fn line="" out="" i=0 w=0 maxw=0 statw=30
  local -a labels=() statuses=() pads=()

  if [ -n "$STATUS_TABLE_CACHE" ]; then
    printf '%s' "$STATUS_TABLE_CACHE"
    return 0
  fi

  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    labels+=("$(status_label "$slug" "$title")")
    statuses+=("$(status_of "$slug")")
  done
  for title in "${labels[@]}"; do
    disp_width "$title"; w=$DW
    [ "$w" -gt "$maxw" ] && maxw="$w"
  done
  for line in "${statuses[@]}"; do
    disp_width "$line"; w=$DW
    [ "$w" -gt "$statw" ] && statw="$w"
  done
  for title in "${labels[@]}"; do
    disp_width "$title"; padn=$((maxw - DW)); [ "$padn" -lt 1 ] && padn=1
    printf -v padstr '%*s' "$padn" ""
    pads+=("${title}${padstr}")
  done

  build_banner
  printf -v out '%s  %s  v%s\n\n' "${C_BLD}${C_CYN}${SCRIPT_BANNER}" "${SCRIPT_NAME}" "$SCRIPT_VERSION"
  out="${out}${C_RST}"
  printf -v line '  %s%*s  %s\n' "项目" "$((maxw - 4))" "" "状态"
  out="${out}${line}"
  printf -v line '  %s  %s\n' "$(printf '─%.0s' $(seq 1 "$maxw"))" "$(printf '─%.0s' $(seq 1 "$statw"))"
  out="${out}${line}"
  for i in "${!labels[@]}"; do
    printf -v line '  %s  %s\n' "${pads[$i]}" "${statuses[$i]}"
    out="${out}${line}"
  done
  out="${out}
"

  STATUS_TABLE_CACHE="$out"
  printf '%s' "$out"
}

invalidate_status() { STATUS_TABLE_CACHE=""; return 0; }

# 清屏并回到最上面（只在真正的终端里清，测试 / 管道下不做任何事）
# 终端尺寸与留白：让界面落在屏幕中上部，不要贴着顶边
TERM_LINES=24
TERM_COLS=80
TERM_SIZED=0
# 是否清屏重画：1=清屏（默认）；设成 0 就全程不清屏，保留所有历史输出
CLEAR_SCREEN="${ACXC_VPS_CLEAR_SCREEN:-1}"

detect_term_size() { # 只在真终端里量一次（优先用 bash 的 LINES/COLUMNS，其次 stty / tput）
  local sz="" t=""
  [ "$TERM_SIZED" -eq 1 ] && return 0
  [ "$TTY_OK" -eq 1 ] || return 0
  TERM_SIZED=1

  # bash 自己维护的 LINES / COLUMNS（交互式 shell 里最准，且不额外起进程）
  case "${LINES:-}" in ''|*[!0-9]*) ;; *) TERM_LINES="$LINES" ;; esac
  case "${COLUMNS:-}" in ''|*[!0-9]*) ;; *) TERM_COLS="$COLUMNS" ;; esac

  # 量不到或者明显还是默认值，再用 stty / tput 补一次
  if [ "$TERM_LINES" -le 24 ] || [ "$TERM_COLS" -le 80 ]; then
    sz="$(stty size < /dev/tty 2>/dev/null)" || sz=""
    case "$sz" in
      [0-9]*' '[0-9]*)
        TERM_LINES="${sz%% *}"
        TERM_COLS="${sz##* }" ;;
      *)
        if have tput; then
          t="$(tput lines 2>/dev/null)" || t=""
          case "$t" in ''|*[!0-9]*) ;; *) TERM_LINES="$t" ;; esac
          t="$(tput cols 2>/dev/null)" || t=""
          case "$t" in ''|*[!0-9]*) ;; *) TERM_COLS="$t" ;; esac
        fi ;;
    esac
  fi

  case "$TERM_LINES" in ''|*[!0-9]*) TERM_LINES=24 ;; esac
  case "$TERM_COLS" in ''|*[!0-9]*) TERM_COLS=80 ;; esac
  [ "$TERM_LINES" -lt 10 ] && TERM_LINES=24
  return 0
}

# 顶部留白：屏幕越高留得越多（约让内容落在屏幕上部 1/3 处）
# 退场画面：清屏后留一点位置再打印一行淡淡的告别语，
# 这样 shell 提示符不会孤零零贴在左上角（看起来像脚本正常工作结束）


screen_margin() {
  local n=0 i=0
  [ "$TTY_OK" -eq 1 ] || return 0
  detect_term_size
  n=$(( (TERM_LINES - 26) / 2 ))
  [ "$n" -lt 3 ] && n=3
  [ "$n" -gt 10 ] && n=10
  for ((i = 0; i < n; i++)); do printf '\n'; done
  return 0
}




refresh_screen() {
  [ "$CLEAR_SCREEN" -eq 1 ] || return 0
  if [ "$TTY_OK" -eq 1 ] && [ -n "${TERM:-}" ]; then
    clear 2>/dev/null || printf '\033[2J\033[H'
    screen_margin
  fi
  return 0
}
# ============================== 操作菜单 ====================================
show_menu() {
  printf '%s\n' "${C_BLD}${C_CYN}操作菜单${C_RST}"
  printf '  %s\n' "1) 更新内核 / 驱动 / 固件"
  printf '  %s\n' "2) 修改 root 密码 / SSH 端口"
  printf '  %s\n' "3) 安装常用工具 / BBR网络加速 / Swap"
  printf '  %s\n' "4) 查看系统信息"
  printf '  %s\n' "5) 查看运行日志"
  printf '  %s\n' "6) 更新脚本"
  printf '  %s\n' "7) 重启服务"
  printf '  %s\n' "8) 卸载 / 清理"
  printf '  %s\n' "0) 退出"
  printf '\n'
}

# 二级菜单里什么都没做就返回时，调用它标记一下，主菜单就不会再多要一次回车
menu_read_choice() { # 结果放 REPLY（清洗后的字符串）
  local raw="" cleaned=""
  while :; do
    if ! read_line "请选择"; then
      warn "读取输入失败"
      return 1
    fi
    raw="$REPLY"
    cleaned="$(trim "$(menu_clean_input "$raw")")"
    if [ -z "$cleaned" ]; then
      if [ -n "$(trim "$raw")" ]; then
        warn "没认出输入来（可能是按了方向键）：请直接输入数字，例如 1"
        continue
      fi
      info "请输入要执行的项目编号（例如 1）；要退出请输入 0"
      continue
    fi
    REPLY="$cleaned"
    return 0
  done
}

show_log_tail() { # 看最近的日志
  local n="${1:-40}"
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    printf '\n%s\n' "${C_BLD}最近 ${n} 行日志（$LOG_FILE）：${C_RST}"
    tail -n "$n" "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" 2>/dev/null || true
  else
    warn "日志文件不存在：${LOG_FILE:-未启用}"
  fi
  printf '\n'
}

# 端口跟当前一样就不算"改动"（避免误报"本次设置"）
mark_port_changed() {
  [ -n "${SSH_NEW_PORT:-}" ] || return 0
  # 和"改之前"的端口比：改完后 current_ssh_ports 已经是新端口了，不能拿它判断
  case " ${SSH_OLD_PORTS:-} " in
    *" $SSH_NEW_PORT "*) return 0 ;;   # 原来就是这个端口，不算改动
  esac
  SSH_PORT_CHANGED="$SSH_NEW_PORT"
  return 0
}

mark_no_change() { NO_CHANGE=1; return 0; }

menu_loop() {
  local choice="" n=0
  refresh_screen
  while :; do
    show_status_table
    show_menu
    # 先把选择问清楚：输入不合法的就地重问，不重复画菜单
    while :; do
      if ! menu_read_choice; then
        printf '\n'
        return 0
      fi
      choice="$REPLY"
      case "$choice" in
        0|q|Q|exit|quit|1|2|3|4|5|6|7|8) break ;;
        *) warn "无效的选择：$choice（请输入 0-8；退出请输入 0）" ;;
      esac
    done
    NO_CHANGE=0

    case "$choice" in
      0|q|Q|exit|quit)
        # 退出时不清屏：保留上面的历史（终端里之前的输出都还在，可以往上翻）
        break ;;
      1|2|3)
        n="$choice"
        PLAN_SLUGS=(); PLAN_TITLES=(); PLAN_FUNCS=()
        if plan_add "$(step_slug_by_index "$n")"; then
          # 进二级菜单前先清屏：屏幕上只留这一步的内容
          refresh_screen
          run_plan
          invalidate_status
          # 进去看了一眼、什么都没改 → 直接回主菜单，不再多按一次回车
          if [ "$NO_CHANGE" -eq 1 ]; then
            refresh_screen
          else
            pause_enter
            refresh_screen
          fi
        else
          warn "无效的选择：$choice"
        fi
        ;;
      4)
        refresh_screen
        show_system_info
        pause_enter
        refresh_screen
        ;;
      5)
        refresh_screen
        show_log_tail 40
        pause_enter
        refresh_screen
        ;;
      6)
        refresh_screen
        update_script
        invalidate_status
        pause_enter
        refresh_screen
        ;;
      7)
        refresh_screen
        step_restart
        invalidate_status
        if [ "$NO_CHANGE" -eq 1 ]; then refresh_screen; else pause_enter; refresh_screen; fi
        ;;
      8)
        refresh_screen
        step_uninstall
        invalidate_status
        if [ "$NO_CHANGE" -eq 1 ]; then refresh_screen; else pause_enter; refresh_screen; fi
        ;;
      *)
        warn "无效的选择：$choice（请输入 0-8；退出请输入 0）"
        ;;
    esac
  done
  printf '\n'
  return 0
}

# 更新脚本：拉最新发布版，覆盖本地缓存（acxc 用的那份），并报出版本变化
update_script() {
  local url="https://github.com/${REPO_SLUG}/releases/latest/download/init.sh"
  local tmp="${CACHE_DIR}/acxc.new" newv="" oldv="$SCRIPT_VERSION"

  info "正在读取最新版本…"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将从 ${url} 拉取最新版，覆盖本地缓存：${CACHE_DIR}/acxc.sh"
    return 0
  fi
  if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    warn "无法创建目录：$CACHE_DIR（需要 root 权限）"
    return 1
  fi
  if ! curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    warn "下载失败：请检查网络或 curl 是否可用"
    rm -f "$tmp"
    return 1
  fi
  newv="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" 2>/dev/null | cut -d'"' -f2)"
  # 校验下载内容：必须是个像样的脚本，否则不覆盖现有缓存（避免把 acxc 更新成半截文件）
  if [ ! -s "$tmp" ] || ! grep -q '^SCRIPT_NAME=' "$tmp" 2>/dev/null || ! grep -q '^main ' "$tmp" 2>/dev/null; then
    warn "下载到的文件看起来不完整，已放弃这次更新（保留现有版本 v${oldv}）"
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "${CACHE_DIR}/acxc.sh" 2>/dev/null || cp -f "$tmp" "${CACHE_DIR}/acxc.sh" 2>/dev/null || true
  rm -f "$tmp"
  install_shortcut quiet 2>/dev/null || true
  if [ -n "$newv" ] && [ "$newv" != "$oldv" ]; then
    ok "脚本已更新：${oldv} → ${newv}（下次输入 ${SHORTCUT_NAME} 生效，本次仍运行 ${oldv}）"
  else
    ok "已经是最新版（v${oldv}）"
  fi
  return 0
}

step_slug_by_index() { # $1=菜单序号(1..N) → 输出步骤标识
  local i=0 entry slug title def fn
  for entry in "${STEPS[@]}"; do
    i=$((i + 1))
    IFS='|' read -r slug title def fn <<<"$entry"
    if [ "$i" = "$1" ]; then
      printf '%s' "$slug"
      return 0
    fi
  done
  return 1
}
# 校验 --only / --skip 里写的步骤名是否都存在（防止拼错后静默什么都不做）
check_step_names() {
  local want="$1" label="$2" tok known="" bad="" entry
  [ -n "$want" ] || return 0
  for entry in "${STEPS[@]}"; do
    known="${known} ${entry%%|*}"
  done
  for tok in $(printf '%s' "$want" | tr ',' ' '); do
    [ -n "$tok" ] || continue
    case " $known " in
      *" $tok "*) ;;
      *) bad="${bad}${bad:+ }${tok}" ;;
    esac
  done
  if [ -n "$bad" ]; then
    warn "${label} 里有不认识的步骤名：${bad}（可用：${known# }）"
    return 1
  fi
  return 0
}

# 非交互路径（--only / --skip / --yes）用的执行计划
build_plan() {
  local entry slug title def fn
  if [ -n "$ONLY_LIST" ] || [ -n "$SKIP_LIST" ]; then
    for entry in "${STEPS[@]}"; do
      IFS='|' read -r slug title def fn <<<"$entry"
      if [ -n "$ONLY_LIST" ] && ! in_list "$slug" "$ONLY_LIST"; then continue; fi
      if [ -n "$SKIP_LIST" ] && in_list "$slug" "$SKIP_LIST"; then
        info "按 --skip 跳过：${title}"
        continue
      fi
      plan_add "$slug"
    done
    return 0
  fi
  if [ "$ASSUME_YES" -eq 1 ]; then
    info "无人值守模式：按默认项执行"
    for entry in "${STEPS[@]}"; do
      IFS='|' read -r slug title def fn <<<"$entry"
      if [ "$def" = y ]; then plan_add "$slug"; fi
    done
    return 0
  fi
  return 0
}

confirm_plan() {
  local t
  if [ "${#PLAN_SLUGS[@]}" -eq 0 ]; then
    err "没有匹配到任何步骤，什么都没做（用 --list 查看可用步骤名）。"
    exit 2
  fi
  title "即将执行以下步骤"
  for t in "${PLAN_TITLES[@]}"; do
    printf '  * %s\n' "$t"
  done
  printf '\n'
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "当前是 --dry-run 模式：只打印将要执行的命令，不会真的修改系统。"
  fi
  if ! ask_yn "确认开始执行？" y; then
    info "已取消，未做任何修改。"
    exit 0
  fi
}

run_plan() {
  local i=0 total=${#PLAN_SLUGS[@]} rc
  while [ "$i" -lt "$total" ]; do
    screen_header "步骤 $((i + 1))/${total}：${PLAN_TITLES[$i]}"
    _log_raw STEP "开始：${PLAN_TITLES[$i]}（${PLAN_SLUGS[$i]}）"
    rc=0
    "${PLAN_FUNCS[$i]}" || rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "步骤完成：${PLAN_TITLES[$i]}"
    else
      err "步骤失败（退出码 ${rc}）：${PLAN_TITLES[$i]}"
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    RESULT_NAMES+=("${PLAN_TITLES[$i]}")
    RESULT_STATES+=("$rc")
    i=$((i + 1))
  done
}



maybe_reboot() {
  local need=0 p=""
  if [ -f "$REBOOT_REQUIRED_FILE" ]; then need=1; fi
  if [ "$NEED_REBOOT" -eq 1 ]; then need=1; fi
  if [ "$need" -eq 0 ]; then return 0; fi
  printf '\n'
  warn "系统需要重启才能加载更新后的内核/驱动。"
  if ask_yn "是否现在重启？" n; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将执行 reboot"
      return 0
    fi
    # 选 Y 就直接重启，不再等待；先把重连方式打出来
    p="$(printf '%s' "$SSH_M_PORTS" | awk '{print $1}')"
      if [ -z "$p" ]; then p="$(current_ssh_ports | awk '{print $1}')"; fi
    info "立即重启（连接马上会断开）"
    if [ -n "$p" ]; then
      printf '  重启后重新连接：ssh -p %s root@<服务器IP>\n' "$p"
    fi
    if ! run reboot; then
      warn "reboot 执行失败，请手动执行：reboot"
    fi
    return 0
  fi
  info "稍后可手动执行：reboot"
  return 0
}

# ============================== 前置检查 ====================================
banner() {
  printf '%s' "$C_BLD$C_CYN"
  printf '%s\n' "  =============================================================="
  printf '%s\n' "   ${SCRIPT_NAME} v${SCRIPT_VERSION}  —— Ubuntu / Debian VPS 初始化脚本"
  printf '%s\n' "   https://github.com/${REPO_SLUG}"
  printf '%s\n' "  =============================================================="
  printf '%s\n' "$C_RST"
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  if [ "$DRY_RUN" -eq 1 ] && [ "${ACXC_VPS_ALLOW_NONROOT:-0}" = "1" ]; then
    warn "非 root + dry-run 模式：仅供本地测试，不会修改系统。"
    return 0
  fi
  err "本脚本需要 root 权限。"
  printf '  例如：curl -fsSL https://raw.githubusercontent.com/%s/main/init.sh | sudo bash\n' "$REPO_SLUG"
  exit 1
}

check_tty() {
  if [ "$TTY_OK" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    die "读不到 /dev/tty，无法交互询问。请在真实终端里运行，或加 --yes 无人值守执行。"
  fi
  return 0
}

check_os() {
  if [ ! -r /etc/os-release ]; then
    if [ "$FORCE_OS" -eq 1 ]; then
      warn "读不到 /etc/os-release，已按 --force 继续"
      return 0
    fi
    die "读不到 /etc/os-release，无法识别系统（如确定要用可加 --force）"
  fi
  # 在子 shell 里读 /etc/os-release：这样它里面的 VERSION/NAME 等变量不会覆盖脚本自己的变量
  # shellcheck source=/dev/null
  OS_ID="$( (. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}") 2>/dev/null || printf 'unknown' )"
  # shellcheck source=/dev/null
  OS_PRETTY="$( (. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}") 2>/dev/null || printf 'unknown' )"
  # shellcheck source=/dev/null
  OS_ID_LIKE="$( (. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}") 2>/dev/null || printf '' )"
  case "$OS_ID" in
    ubuntu|debian|raspbian|linuxmint|pop|kali|armbian|devuan|deepin|neon|zorin|elementary) ;;
    *)
      case "${OS_ID_LIKE:-}" in
        *debian*) ;;
        *)
          if [ "$FORCE_OS" -eq 1 ]; then
            warn "非 Debian 系系统（${OS_PRETTY}），已按 --force 继续"
          else
            die "本脚本只支持 Ubuntu / Debian 系（检测到：${OS_PRETTY}）。如确定要用，请加 --force"
          fi ;;
      esac ;;
  esac
  if ! have apt-get; then
    if [ "$FORCE_OS" -eq 1 ]; then
      warn "未找到 apt-get，后续 apt 相关步骤会失败"
    else
      die "未找到 apt-get，本脚本依赖 apt 包管理器"
    fi
  fi
  return 0
}

show_system_info() {
  title "系统信息"
  kv "系统" "${OS_PRETTY}"
  kv "内核" "$(uname -r)"
  kv "架构" "$(uname -m)"
  kv "虚拟化" "$(virt_type)"
  if [ -r /proc/meminfo ]; then
    kv "内存" "$(awk '/^MemTotal:/{printf "%.2f GB", $2/1048576}' /proc/meminfo)"
  fi
  kv "根分区" "$(df -hP / 2>/dev/null | awk 'END{printf "%s 总 / %s 可用（已用 %s）", $2, $4, $5}')"
  kv "SSH 端口" "$(trim "$(current_ssh_ports)")"
 if [ "$DRY_RUN" -eq 1 ]; then kv "运行模式" "dry-run（不修改系统）"; fi
  if [ "$ASSUME_YES" -eq 1 ]; then kv "应答方式" "--yes（全部用默认值）"; fi
}

# ============================== 参数与主流程 ================================
usage() {
  cat <<'EOF'
ACXC16-VPS新机一键脚本 —— Ubuntu / Debian VPS 初始化交互式脚本

用法:
  直接跑就是交互式：显示状态表 + 编号操作菜单，选一项执行一项，选 0 退出
    curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash
    bash init.sh

选项:
  -y, --yes            无人值守：不显示菜单，按默认项一次性执行
                       ★ --yes 不会自动修改 root 密码：避免给你设置一个自己不知道的密码。
                         要改密码必须显式加 --password '新密码' 或 --gen-password。
      --password <密码> 明确指定新的 root 密码（会留在 shell 历史里，用完记得清）
      --gen-password   明确要求生成随机 root 密码：先把密码显示给你确认，确认后才生效
      --port <端口>    直接指定新的 SSH 端口（跳过询问，默认 52052）
      --only <列表>    只执行列出的步骤，逗号分隔，例如 --only sysupdate,access
      --skip <列表>    跳过列出的步骤，例如 --skip extras
      --dry-run        演练模式：只打印将要执行的命令，不修改系统
      --force          跳过系统版本检测（非 Ubuntu/Debian 也能跑，风险自负）
      --no-color       关闭彩色输出
      --log-file <路径> 指定日志文件（默认 /var/log/acxc-vps.log）
      --list           列出所有步骤标识与默认值后退出
  -h, --help           显示本帮助
  -V, --version        显示版本号

菜单:
  1) 更新内核 / 驱动 / 固件        2) 修改 root 密码 / SSH 端口
  3) 安装常用工具 / BBR网络加速 / Swap
  4) 查看系统信息                  5) 查看运行日志
  6) 更新脚本（拉最新发布版）       7) 重启服务
  8) 卸载 / 清理                   0) 退出

步骤标识（--only / --skip 用）:
  sysupdate  access  extras   （--only ssh-port / root-passwd 仍兼容，等同 access）

安全提示:
  * 改 SSH 端口前，请先在云服务商控制台的安全组放行新端口，并保持当前会话不要断开。
  * 修改后先另开终端确认 ssh -p <新端口> 能登录，再关闭旧连接。
  * 所有改动都会记录到日志文件（默认 /var/log/acxc-vps.log）。
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      --port) shift; OPT_PORT="${1:-}"; [ -n "$OPT_PORT" ] || die "--port 需要一个参数" ;;
      --port=*) OPT_PORT="${1#*=}" ;;
      --password) shift; OPT_PASSWORD="${1:-}"; [ -n "$OPT_PASSWORD" ] || die "--password 需要一个参数" ;;
      --password=*) OPT_PASSWORD="${1#*=}" ;;
      --gen-password) GEN_PASSWORD=1 ;;
      --only) shift; ONLY_LIST="${1:-}"; [ -n "$ONLY_LIST" ] || die "--only 需要一个参数" ;;
      --only=*) ONLY_LIST="${1#*=}" ;;
      --skip) shift; SKIP_LIST="${1:-}"; [ -n "$SKIP_LIST" ] || die "--skip 需要一个参数" ;;
      --skip=*) SKIP_LIST="${1#*=}" ;;
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE_OS=1 ;;
      --no-color) COLOR_OFF=1 ;;

      --log-file) shift; LOG_FILE="${1:-$LOG_FILE}"; [ -n "${1:-}" ] || die "--log-file 需要一个参数" ;;
      --log-file=*) LOG_FILE="${1#*=}" ;;
      --list) list_steps; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      *) err "未知参数：$1"; printf '\n'; usage; exit 2 ;;
    esac
    shift
  done
  # 1) 步骤名统一小写，避免 --only SYSUPDATE 这种写法踩坑
  ONLY_LIST="$(printf '%s' "$ONLY_LIST" | tr '[:upper:]' '[:lower:]')"
  SKIP_LIST="$(printf '%s' "$SKIP_LIST" | tr '[:upper:]' '[:lower:]')"
  # 2) 兼容旧写法：ssh-port / root-passwd 都当作 access（两者已合并为一项）
  if [ -n "$ONLY_LIST" ]; then
    ONLY_LIST="${ONLY_LIST//ssh-port/access}"
    ONLY_LIST="${ONLY_LIST//root-passwd/access}"
  fi
  if [ -n "$SKIP_LIST" ]; then
    SKIP_LIST="${SKIP_LIST//ssh-port/access}"
    SKIP_LIST="${SKIP_LIST//root-passwd/access}"
  fi
  # 3) 拼错的步骤名直接报错退出，别让脚本静默什么都不做
  if [ -n "$ONLY_LIST" ] && ! check_step_names "$ONLY_LIST" "--only"; then exit 2; fi
  if [ -n "$SKIP_LIST" ] && ! check_step_names "$SKIP_LIST" "--skip"; then exit 2; fi
  return 0
}

steps_slugs() {
  local entry slug title def fn out=""
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    out="${out}${out:+,}${slug}"
  done
  printf '%s' "$out"
}

main() {
  ORIG_ARGS=("$@")
  prepare_log
  parse_args "$@"
  init_colors
  # --log-file 可能在参数里改过路径，这里再检查一次（可写性 + 600 权限）
  prepare_log
  init_log "$@"
  require_root
  detect_tty
  check_tty
  banner
  check_os
  export DEBIAN_FRONTEND=noninteractive
  migrate_legacy_paths
  ssh_load_managed
  # 如果这次跑的是放了很久的本地缓存版，提醒一句（避免用着旧版还以为是最新）
  if [ -f "${CACHE_DIR}/acxc.sh" ] && [ -n "$(find "${CACHE_DIR}/acxc.sh" -mmin +1440 2>/dev/null)" ]; then
    warn "这份可能是旧版缓存（超过 1 天没更新）；菜单 6) 更新脚本 可立刻刷新"
  fi
  # 自动装好快捷命令（下次直接输 acxc 就能打开；内容没变则静默跳过）
  install_shortcut quiet 2>/dev/null || true

  # 指定了 --only / --skip / --yes 时：一次性执行，不进菜单
  if [ -n "$ONLY_LIST" ] || [ -n "$SKIP_LIST" ] || [ "$ASSUME_YES" -eq 1 ]; then
    build_plan
    confirm_plan
    run_plan
  else
    # 交互式：状态表 + 编号菜单，循环执行直到选 0 退出
    menu_loop
  fi

  # 退出时不再打印执行结果与提示（细节在执行时已经打印过）
  maybe_reboot
  if [ "$FAILED_COUNT" -gt 0 ]; then return 1; fi
  return 0
}

trap 'printf "\n"; err "已被中断（Ctrl+C）。已执行的步骤不会自动回滚。"; exit 130' INT TERM

main "$@"
exit $?

# =============================================================================
#  如何新增一个步骤（例如"安装 Docker"）：
#   1) 写一个函数，返回 0 表示成功、非 0 表示失败（不要用 exit）：
#
#        step_docker() {
#          if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install docker.io; then
#            err "Docker 安装失败"
#            return 1
#          fi
#          ok "Docker 安装完成"
#          return 0
#        }
#
#   2) 在文件顶部的 STEPS 表里加一行：
#
#        "docker|安装 Docker|n|step_docker"
#
#      格式为 "标识|名称|默认值(y/n)|函数名"，脚本会自动把它加进询问列表。
#
#   3) 需要"改错就失联"的操作时，参考 step_ssh_port：先备份 → 校验 → 失败自动回滚。
# =============================================================================

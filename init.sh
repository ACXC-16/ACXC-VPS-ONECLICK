#!/usr/bin/env bash
# =============================================================================
#  ACXC16-VPS新机一键脚本 —— Ubuntu / Debian VPS 初始化交互式脚本
#  版本: 1.0.0
#  仓库: https://github.com/ACXC-16/VPS-init
#  许可: MIT
# -----------------------------------------------------------------------------
#  一键运行（推荐，先下载再以 root 执行）：
#      curl -fsSL https://raw.githubusercontent.com/ACXC-16/VPS-init/main/init.sh | sudo bash
#    或
#      sudo bash <(curl -fsSL https://raw.githubusercontent.com/ACXC-16/VPS-init/main/init.sh)
#
#  测试用环境变量（普通用户不用管，CI / 本地测试才会用到）:
#    VPS_INIT_ALLOW_NONROOT=1  配合 --dry-run 允许非 root 运行
#    VPS_INIT_FORCE_STDIN=1    强制从 stdin 读取回答（测试脚本喂答案用）
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
VERSION="1.0.0"
REPO_SLUG="ACXC-16/VPS-init"

DEFAULT_SSH_PORT="52052"
MANAGED_SSHD_CONF="/etc/ssh/sshd_config.d/00-vps-init.conf"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/vps-init.local"
SYSCTL_BBR_CONF="/etc/sysctl.d/99-vps-init-bbr.conf"
SWAPFILE="/swapfile"
# 需要重启的标记文件（一般不用改；测试时会指向临时文件）
REBOOT_REQUIRED_FILE="${VPS_INIT_REBOOT_REQUIRED:-/var/run/reboot-required}"

LOG_FILE="${VPS_INIT_LOG:-/var/log/vps-init.log}"
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

# 交互界面：状态表 + 编号菜单（纯文字，任何终端都能用；不支持图形方框是有意为之）

# 受管的 SSH 设置（脚本重启后会从受管配置里读回来，避免覆盖上次的设置）
SSH_M_PORTS=""
SSH_M_PERMIT_ROOT_LOGIN=""
SSH_M_PASSWORD_AUTH=""

declare -a PLAN_SLUGS=() PLAN_TITLES=() PLAN_FUNCS=()
declare -a RESULT_NAMES=() RESULT_STATES=()

# ============================== 步骤注册表 ==================================
# 格式: "标识|名称|默认值(y/n)|函数名"
# 默认值只是"直接回车"时的取值，每一项都会单独询问 Y/N。
STEPS=(
  "sysupdate|只更新内核 / 驱动 / 固件|y|step_sysupdate"
  "ssh-port|修改 SSH 端口（默认 ${DEFAULT_SSH_PORT}）|y|step_ssh_port"
  "root-passwd|修改 root 密码|y|step_root_password"
  "fail2ban|安装配置 fail2ban|n|step_fail2ban"
  "tuning|时区 / Swap / BBR 网络加速|n|step_tuning"
  "tools|安装常用命令行工具|n|step_tools"
)

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

info()  { printf '%s\n' "${C_CYN}[信息]${C_RST} $*"; _log_raw INFO "$*"; }
ok()    { printf '%s\n' "${C_GRN}[成功]${C_RST} $*"; _log_raw OK   "$*"; }
warn()  { printf '%s\n' "${C_YEL}[注意]${C_RST} $*" >&2; _log_raw WARN "$*"; }
err()   { printf '%s\n' "${C_RED}[错误]${C_RST} $*" >&2; _log_raw ERROR "$*"; }
die()   { err "$*"; exit 1; }
title() { printf '\n%s\n' "${C_BLD}${C_CYN}==== $* ====${C_RST}"; _log_raw TITLE "==== $* ===="; }
kv()    { printf '  %-18s %s\n' "$1" "$2"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# 计算字符串在终端里占几列（中文等全角字符按 2 列算；用字节数换算，与 locale 无关）
disp_width() {
  local s="$1" total=0 ascii=0 nonascii=0
  total="$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')"
  ascii="$(printf '%s' "$s" | LC_ALL=C tr -dc '\000-\177' | LC_ALL=C wc -c | tr -d ' ')"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$ascii" in ''|*[!0-9]*) ascii=0 ;; esac
  nonascii=$((total - ascii))
  printf '%s' $((ascii + (nonascii / 3) * 2))
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
    LOG_FILE="/tmp/vps-init.log"
    if ! { : 2>/dev/null >>"$LOG_FILE"; }; then LOG_FILE=""; fi
  fi
  if [ -n "$LOG_FILE" ]; then chmod 600 "$LOG_FILE" 2>/dev/null || true; fi
  return 0
}

init_log() {
  _log_raw START "===== ${SCRIPT_NAME} v${VERSION} 启动（参数：$*）====="
}

# ============================== 交互输入 ====================================
# 说明：curl | bash 时脚本本身占用了 stdin，所以必须从 /dev/tty 读输入。
# 这里用子 shell 真实地打开一次 /dev/tty：只有 -r/-w 测试通过是不够的
# （容器、面板、无控制终端的场景下 /dev/tty 存在但打不开，此时要退回 stdin）。
detect_tty() {
  TTY_OK=0
  # 测试时可以用 VPS_INIT_FORCE_STDIN=1 强制从 stdin 读答案
  if [ "${VPS_INIT_FORCE_STDIN:-0}" = "1" ]; then return 0; fi
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

is_container() {
  case "$(virt_type)" in
    lxc|lxc-libvirt|openvz|docker|podman|systemd-nspawn|wsl) return 0 ;;
    *) return 1 ;;
  esac
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

current_ssh_ports() { # 输出当前生效的端口（空格分隔，无首尾空白）
  local eff=""
  eff="$(sshd_effective)" || true
  if [ -n "$eff" ]; then
    printf '%s' "$(printf '%s\n' "$eff" | awk '/^port /{printf "%s", (n++ ? " " : "") $2}')"
    return 0
  fi
  awk '/^[[:space:]]*Port[[:space:]]/{printf "%s", (n++ ? " " : "") $2}' /etc/ssh/sshd_config 2>/dev/null
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
  printf '%s\n' "# --- vps-init managed block: start ---"
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
  printf '%s\n' "# --- vps-init managed block: end ---"
  return 0
}

ssh_managed_keys() {
  if [ -n "$SSH_M_PORTS" ]; then printf '%s\n' Port; fi
  if [ -n "$SSH_M_PERMIT_ROOT_LOGIN" ]; then printf '%s\n' PermitRootLogin; fi
  if [ -n "$SSH_M_PASSWORD_AUTH" ]; then printf '%s\n' PasswordAuthentication; fi
  return 0
}

# 把上次运行留下的受管设置读回来，避免只跑其中一个步骤时把另一个覆盖掉
ssh_load_managed() {
  SSH_M_PORTS=""; SSH_M_PERMIT_ROOT_LOGIN=""; SSH_M_PASSWORD_AUTH=""
  local src="" parsed="" kind rest
  if [ -f "$MANAGED_SSHD_CONF" ]; then
    src="$MANAGED_SSHD_CONF"
  elif [ -f /etc/ssh/sshd_config ] && grep -q 'vps-init managed block: start' /etc/ssh/sshd_config 2>/dev/null; then
    src="/etc/ssh/sshd_config"
  else
    return 0
  fi
  parsed="$(sed -n '/vps-init managed block: start/,/vps-init managed block: end/p' "$src" 2>/dev/null |
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
        printf "# %s  # vps-init: disabled\n", $0
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
  sed -i '/# --- vps-init managed block: start ---/,/# --- vps-init managed block: end ---/d' "$conf"
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
    rm -rf /etc/ssh/sshd_config.d
    cp -a "${bak}/sshd_config.d" /etc/ssh/sshd_config.d
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

step_sysupdate() {
  local rc=0 virt pkgs="" cnt=0 major=0
  virt="$(virt_type)"
  info "虚拟化类型：${virt}"
  case "$virt" in
    openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn)
      warn "容器/OpenVZ 环境下内核与驱动由宿主机提供，本机只能更新用户态软件包。" ;;
    *)
      info "本步骤只更新内核 / 驱动模块 / 固件相关的包，系统里其它软件包默认不动。" ;;
  esac

  info "1/4 检查软件包状态（有没有装到一半中断的）…"
  if dpkg --audit 2>/dev/null | grep -q .; then
    warn "检测到未完成的软件包安装，先修复："
    run env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || warn "dpkg --configure -a 返回非零（继续）"
    run env DEBIAN_FRONTEND=noninteractive apt-get -y -f install || warn "apt-get -f install 返回非零（继续）"
  else
    ok "软件包状态正常，无需修复。"
  fi

  info "2/4 刷新软件源索引（apt update：只更新索引，不动任何软件）…"
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3; then
    err "apt update 失败：请检查网络、软件源或磁盘空间"
    return 1
  fi

  info "3/4 只升级内核 / 驱动 / 固件…"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "本机已安装的内核/驱动相关包："
    installed_kernel_pkgs 2>/dev/null | sed 's/^/    /' || true
  fi
  if have apt; then
    pkgs="$(upgradable_kernel_pkgs)"
  else
    warn "未找到 apt 命令，改为直接尝试升级已安装的内核/驱动包"
    pkgs="$(installed_kernel_pkgs)"
  fi

  if [ -z "$pkgs" ]; then
    ok "内核 / 驱动 / 固件已经是最新，无需升级。"
  else
    cnt="$(printf '%s\n' "$pkgs" | wc -l | tr -d ' ')"
    info "发现 ${cnt} 个可升级的包："
    printf '%s\n' "$pkgs" | sed 's/^/    /'
    if ask_yn "是否升级上面这些内核/驱动/固件包？" y; then
      # shellcheck disable=SC2086
      if run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
        apt-get -y install --only-upgrade $pkgs \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        -o Dpkg::Lock::Timeout=900; then
        ok "内核 / 驱动 / 固件升级完成"
      else
        warn "升级过程中出现错误，请查看上方输出与日志：${LOG_FILE:-未启用}"
        rc=1
      fi
    else
      info "已跳过内核/驱动升级。"
    fi
  fi

  info "4/4 可选项（下面几项默认都不做）…"
  if ask_yn "是否顺便升级系统里【其它所有】软件包（apt full-upgrade）？" n; then
    major=1
    run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
      apt-get -y \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      -o Dpkg::Lock::Timeout=900 \
      full-upgrade || { warn "全量升级出现错误，请查看上方输出"; rc=1; }
  else
    info "保持不动：本次不升级其它软件包。"
  fi

  if ! is_container && ! dpkg -s linux-firmware >/dev/null 2>&1; then
    if ask_yn "本机没装 linux-firmware 固件包，是否安装？（VPS 一般用不到，体积数百 MB）" n; then
      run env DEBIAN_FRONTEND=noninteractive apt-get -y install linux-firmware || warn "安装失败（软件源里可能没有该包）"
    fi
  fi

  if ask_yn "是否清理不再需要的依赖包（apt autoremove --purge）？" n; then
    run env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge || warn "autoremove 返回非零"
  fi

  if [ "$major" -eq 0 ] && ! installed_kernel_pkgs 2>/dev/null | grep -qE '^linux-(generic|image-generic|virtual|image-virtual|image-amd64|image-cloud-amd64|image-arm64|image-rt-amd64)'; then
    info "提示：本机没有内核元包（如 linux-image-generic），内核不会自动跟随更新；需要的话手动 apt install 即可。"
  fi

  if [ -f "$REBOOT_REQUIRED_FILE" ]; then
    NEED_REBOOT=1
    warn "系统需要重启才能加载新内核/驱动。"
    if [ -s "${REBOOT_REQUIRED_FILE}.pkgs" ]; then
      info "触发重启的包：$(tr '\n' ' ' <"${REBOOT_REQUIRED_FILE}.pkgs")"
    fi
  fi
  ok "内核 / 驱动更新流程结束（当前运行内核：$(uname -r)）"
  return "$rc"
}

# ============================== 步骤 2：SSH 端口 ============================
step_ssh_port() {
  if [ ! -f /etc/ssh/sshd_config ]; then
    err "找不到 /etc/ssh/sshd_config，本机可能没安装 OpenSSH Server"
    return 1
  fi

  local old_ports new_port keep_old=0 ssherr="" p stamp bak other

  old_ports="$(trim "$(current_ssh_ports)")"
  if [ -z "$old_ports" ] && [ -n "$SSH_M_PORTS" ]; then
    old_ports="$(trim "$SSH_M_PORTS")"
    info "从上次留下的受管配置里读到端口：${old_ports}"
  fi
  info "当前生效的 SSH 端口：${old_ports:-未知}"

  # 先看现有配置能不能通过校验
  ssherr="$(sshd_test 2>&1)" || {
    warn "当前 SSH 配置本身就有语法问题："
    printf '%s\n' "$ssherr" | sed 's/^/    /'
    if ! ask_yn "仍然继续修改？（脚本会先备份，可回滚）" n; then return 1; fi
  }

  # 端口选择
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

  # 过渡期是否保留旧端口
  if [ -n "$old_ports" ]; then
    case " $old_ports " in
      *" $new_port "*) ;;
      *)
        if ask_yn "过渡期是否继续保留原有端口（$(trim "$old_ports" | tr -s ' ')）？验证新端口可用后再关闭更安全" y; then
          keep_old=1
        fi ;;
    esac
  fi

  # 改端口前的安全提示
  printf '\n'
  warn "改 SSH 端口前请先确认："
  printf '  ① 云服务商控制台的「安全组 / 防火墙」先放行 %s/TCP\n' "$new_port"
  printf '  ② 当前 SSH 会话不要断开（重启 sshd 不会踢掉已登录的连接）\n'
  printf '  ③ 改完另开一个终端用 ssh -p %s root@<服务器IP> 验证，成功再关旧连接\n' "$new_port"
  printf '  ④ 万一连不上：用云控制台 VNC 登录后执行脚本最后打印的回滚命令\n'
  printf '\n'

  # 本机防火墙放行
  info "检查本机防火墙…"
  if have ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
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
    if have iptables && iptables -S 2>/dev/null | grep -qE '^-P (INPUT|FORWARD) DROP'; then
      warn "iptables 默认策略是 DROP，请自行确认新端口没有被自建规则拦截。"
    fi
  fi

  # 备份
  stamp="$(date '+%Y%m%d-%H%M%S')"
  bak="/root/vps-init-backup/${stamp}-ssh"
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

# ============================== 步骤 3：root 密码 ===========================
step_root_password() {
  local pw="" gen=0 p1="" p2="" eff="" prl="" pa=""

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

  if [ "$gen" -eq 1 ]; then
    NEW_ROOT_PASSWORD="$pw"   # 最后汇总时再显示一次，防止中途刷屏看不到
    printf '\n%s\n' "${C_BLD}${C_YEL}  ★ 新生成的 root 密码（只显示这一次，请立即保存）：${C_RST}"
    printf '%s\n\n' "${C_BLD}      $pw${C_RST}"
  else
    info "已设置为手动输入的密码（脚本不会记录明文密码）。"
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
create_swap() {
  local mb="$1" avail_mb=""
  if [ "$mb" -lt 256 ]; then
    warn "Swap 至少 256MB"
    return 1
  fi
  if [ -e "$SWAPFILE" ]; then
    warn "${SWAPFILE} 已存在"
    if ! ask_yn "是否删除并重建 ${SWAPFILE}？" n; then return 1; fi
    run swapoff "$SWAPFILE" >/dev/null 2>&1 || true
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
    return 1
  fi
  if ! grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
    printf '%s\n' "${SWAPFILE} none swap sw 0 0  # vps-init" >>/etc/fstab
  fi
  printf '%s\n' 'vm.swappiness=10' >/etc/sysctl.d/99-vps-init-swap.conf
  sysctl -q -w vm.swappiness=10 >/dev/null 2>&1 || true
  ok "Swap 已启用：$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')"
  return 0
}

step_tuning() {
  local rc=0 tz="" mem_mb="" existing_swap="" def_swap="" swap_mb="" befor_cc=""

  # ---------- 时区 ----------
  if ask_yn "设置系统时区（默认 Asia/Shanghai）？" y; then
    tz="Asia/Shanghai"
    if [ "$ASSUME_YES" -eq 0 ]; then
      if ask_value "请输入时区" "Asia/Shanghai"; then tz="$REPLY"; fi
    fi
    case "$tz" in
      *[!A-Za-z0-9_/+:-]*) warn "时区格式不合法：$tz，已跳过" ; tz="" ;;
    esac
    if [ -n "$tz" ]; then
      if [ ! -f "/usr/share/zoneinfo/$tz" ]; then
        warn "时区 $tz 不存在，保持原样（当前：$(date +%Z)）"
      else
        if have timedatectl && run timedatectl set-timezone "$tz"; then
          :
        else
          warn "timedatectl 不可用或执行失败，改用直接写文件的方式设置时区"
          run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime || rc=1
          run sh -c "printf '%s\\n' '$tz' > /etc/timezone" || true
        fi
        if [ "$DRY_RUN" -eq 0 ]; then ok "时区已设置为 $tz（当前时间：$(date '+%F %T %Z')）"; fi
      fi
    fi
  fi

  # ---------- Swap ----------
  mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  existing_swap="$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  [ -n "$mem_mb" ] || mem_mb=0
  [ -n "$existing_swap" ] || existing_swap=0

  if [ "$existing_swap" -gt 0 ]; then
    info "已存在 Swap（${existing_swap}MB），跳过创建。"
  elif ask_yn "是否创建 Swap 交换文件？（当前内存 ${mem_mb}MB）" y; then
    if [ "$mem_mb" -le 4096 ]; then def_swap="2048"; else def_swap="4096"; fi
    swap_mb="$def_swap"
    if [ "$ASSUME_YES" -eq 0 ]; then
      if ask_value "Swap 大小（MB）" "$def_swap"; then swap_mb="$REPLY"; fi
    fi
    case "$swap_mb" in
      ''|*[!0-9]*) warn "Swap 大小无效，改用默认值 ${def_swap}MB"; swap_mb="$def_swap" ;;
    esac
    create_swap "$swap_mb" || rc=1
  fi

  # ---------- BBR ----------
  local kver kmaj kmin
  kver="$(uname -r)"
  kmaj="${kver%%.*}"
  kmin="${kver#*.}"; kmin="${kmin%%.*}"
  case "$kmaj" in ''|*[!0-9]*) kmaj=0 ;; esac
  case "$kmin" in ''|*[!0-9]*) kmin=0 ;; esac

  if [ "$kmaj" -lt 4 ] || { [ "$kmaj" -eq 4 ] && [ "$kmin" -lt 9 ]; }; then
    warn "内核 ${kver} 低于 4.9，不支持 BBR，已跳过。"
  elif ask_yn "是否开启 TCP BBR 拥塞控制（网络加速）？" y; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s\n' "${C_DIM}  [dry-run] 将写入 ${SYSCTL_BBR_CONF} 并执行 sysctl --system${C_RST}"
    else
      befor_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
      if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        warn "内核未列出 bbr 模块，尝试加载…"
        modprobe tcp_bbr 2>/dev/null || warn "modprobe tcp_bbr 失败（容器/共享内核环境属正常）"
      fi
      cat >"$SYSCTL_BBR_CONF" <<'EOF'
# 由 vps-init 生成：开启 TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
      sysctl --system >/dev/null 2>&1 || true
      local cc="" qd=""
      cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
      qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
      if [ "$cc" = "bbr" ]; then
        ok "BBR 已开启（拥塞控制：${cc}，队列：${qd:-未知}，调整前为：${befor_cc:-未知}）"
      else
        warn "BBR 未生效（当前：${cc:-未知}）。OpenVZ/LXC 等共享内核环境通常不支持，需要宿主机开启。"
      fi
    fi
  fi

  return "$rc"
}

# ============================== 步骤 6：常用工具 ============================
step_tools() {
  local base="curl wget vim nano htop tmux screen unzip zip git rsync lsof ca-certificates gnupg jq tree bash-completion"
  local net="net-tools mtr-tiny traceroute dnsutils"
  local all="" p rcp=0

  if ask_yn "是否额外安装网络诊断工具（net-tools / mtr / traceroute / dnsutils）？" y; then
    all="${base} ${net}"
  else
    all="$base"
  fi

  info "将安装：$(printf '%s' "$all" | tr -s ' ')"
  # shellcheck disable=SC2086
  if run env DEBIAN_FRONTEND=noninteractive apt-get -y install $all; then
    ok "常用工具安装完成"
    return 0
  fi

  warn "整体安装失败，改为逐个安装以定位问题（个别包在精简系统上可能不存在）…"
  # shellcheck disable=SC2086
  for p in $all; do
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install "$p" >/dev/null 2>&1; then
      warn "安装失败：$p"
      rcp=1
    fi
  done
  if [ "$rcp" -eq 0 ]; then
    ok "常用工具安装完成（逐包安装方式）"
  else
    warn "部分工具安装失败，可稍后手动安装。"
  fi
  return 0
}

# ============================== 计划与执行 ==================================
list_steps() {
  local entry slug title def fn
  printf '%s 可选步骤：\n' "$SCRIPT_NAME"
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    printf '  %-13s %-40s 默认: %s\n' "$slug" "$title" "$def"
  done
  printf '\n用法：--only sysupdate,ssh-port   /   --skip tools\n'
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

# ============================== 状态表 ======================================
# 每个步骤在本机当前的真实状态，风格参考常见管理面板（项目 / 状态）
status_kernel() {
  local k="" n=""
  k="$(uname -r)"
  if have apt; then
    n="$(upgradable_kernel_pkgs 2>/dev/null | grep -c . || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      printf '内核 %s（有 %s 个驱动/内核包可升级）' "$k" "$n"
    else
      printf '内核 %s（已是最新）' "$k"
    fi
  else
    printf '内核 %s' "$k"
  fi
}

status_ssh() {
  local p=""
  p="$(trim "$(current_ssh_ports)")"
  [ -n "$p" ] || p="$(trim "$SSH_M_PORTS")"
  if [ -n "$p" ]; then
    printf '当前端口 %s' "$p"
  else
    printf '未检测到 sshd 配置'
  fi
}

status_passwd() {
  local line="" st="" d=""
  line="$(passwd -S root 2>/dev/null)" || line=""
  st="$(printf '%s' "$line" | awk '{print $2}')"
  d="$(printf '%s' "$line" | awk '{print $3}')"
  case "$st" in
    P) if [ -n "$d" ]; then printf '已设置密码（%s）' "$d"; else printf '已设置密码'; fi ;;
    L) printf '已锁定' ;;
    NP) printf '未设置密码' ;;
    '') printf '未知' ;;
    *) printf '状态 %s' "$st" ;;
  esac
}

status_fail2ban() {
  if ! have fail2ban-client; then
    printf '未安装'
    return 0
  fi
  if have systemctl && systemctl is-active fail2ban >/dev/null 2>&1; then
    printf '已安装，运行中'
  else
    printf '已安装，未运行'
  fi
}

status_tuning() {
  local tz="" sw="" cc=""
  tz="$(date +%Z 2>/dev/null)"
  sw="$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [ -n "${sw:-}" ] && [ "$sw" -gt 0 ]; then
    printf '时区 %s · Swap %sMB · TCP %s' "${tz:-?}" "$sw" "${cc:-?}"
  else
    printf '时区 %s · 无 Swap · TCP %s' "${tz:-?}" "${cc:-?}"
  fi
}

status_tools() {
  local pkg="" have_n=0 total=0
  for pkg in curl wget vim htop tmux git rsync jq unzip lsof; do
    total=$((total + 1))
    if have "$pkg"; then have_n=$((have_n + 1)); fi
  done
  printf '常用工具 %s/%s 已安装' "$have_n" "$total"
}

status_of() { # $1=步骤标识 → 输出状态文字
  case "$1" in
    sysupdate)   status_kernel ;;
    ssh-port)    status_ssh ;;
    root-passwd) status_passwd ;;
    fail2ban)    status_fail2ban ;;
    tuning)      status_tuning ;;
    tools)       status_tools ;;
    *)           printf '—' ;;
  esac
}

show_status_table() {
  local entry slug title def fn line=""
  printf '\n%s\n' "${C_BLD}${C_CYN}  ${SCRIPT_NAME}  v${VERSION}${C_RST}"
  printf '  %s\n' "${C_DIM}适用：Ubuntu / Debian    仓库：https://github.com/${REPO_SLUG}${C_RST}"
  printf '\n'
  printf '  %-34s %s\n' "项目" "状态"
  printf '  %s\n' "────────────────────────────────── ──────────────────────────────"
  local pad=0
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r slug title def fn <<<"$entry"
    line="$(status_of "$slug")"
    pad=$((30 - $(disp_width "$title")))
    [ "$pad" -lt 1 ] && pad=1
    printf '  %s%*s  %s\n' "$title" "$pad" "" "$line"
  done
  printf '\n'
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

# ============================== 操作菜单 ====================================
show_menu() {
  printf '%s\n' "${C_BLD}${C_CYN}操作菜单${C_RST}"
  printf '  %s\n' "1) 只更新内核 / 驱动 / 固件"
  printf '  %s\n' "2) 修改 SSH 端口"
  printf '  %s\n' "3) 修改 root 密码"
  printf '  %s\n' "4) 安装配置 fail2ban"
  printf '  %s\n' "5) 时区 / Swap / BBR 网络加速"
  printf '  %s\n' "6) 安装常用命令行工具"
  printf '  %s\n' "7) 查看系统信息"
  printf '  %s\n' "8) 查看运行日志"
  printf '  %s\n' "9) 全部按默认执行（1 2 3）"
  printf '  %s\n' "0) 退出"
  printf '\n'
}

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
      continue
    fi
    REPLY="$cleaned"
    return 0
  done
}

# 菜单循环：选一项 → 执行 → 回到菜单，直到选 0 退出
menu_loop() {
  local choice="" n=0 entry_slug=""
  while :; do
    show_status_table
    show_menu
    if ! menu_read_choice; then
      break
    fi
    choice="$REPLY"

    case "$choice" in
      0|q|Q|exit|quit)
        break ;;
      1|2|3|4|5|6)
        n="$choice"
        PLAN_SLUGS=(); PLAN_TITLES=(); PLAN_FUNCS=()
        if plan_add "$(step_slug_by_index "$n")"; then
          run_plan
          printf '\n'
          printf '  %s\n' "${C_DIM}（按回车继续）${C_RST}"
          _prompt_line "  " "" >/dev/null 2>&1 || true
        else
          warn "无效的选择：$choice"
        fi
        ;;
      7)
        show_system_info
        printf '\n  %s\n' "${C_DIM}（按回车继续）${C_RST}"
        _prompt_line "  " "" >/dev/null 2>&1 || true
        ;;
      8)
        show_log_tail 40
        printf '\n  %s\n' "${C_DIM}（按回车继续）${C_RST}"
        _prompt_line "  " "" >/dev/null 2>&1 || true
        ;;
      9|a|A|all|ALL)
        info "按默认项执行：1、2、3"
        PLAN_SLUGS=(); PLAN_TITLES=(); PLAN_FUNCS=()
        for entry_slug in sysupdate ssh-port root-passwd; do
          plan_add "$entry_slug"
        done
        run_plan
        printf '\n'
        ;;
      *)
        warn "无效的选择：$choice（请输入 0-9）"
        ;;
    esac
  done
  printf '\n'
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
    warn "没有选择任何步骤，退出。"
    exit 0
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
    title "步骤 $((i + 1))/${total}：${PLAN_TITLES[$i]}"
    _log_raw STEP "开始：${PLAN_TITLES[$i]}（${PLAN_SLUGS[$i]}）"
    rc=0
    "${PLAN_FUNCS[$i]}" || rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "步骤完成：${PLAN_TITLES[$i]}"
    else
      err "步骤失败（退出码 ${rc}）：${PLAN_TITLES[$i]}"
    fi
    RESULT_NAMES+=("${PLAN_TITLES[$i]}")
    RESULT_STATES+=("$rc")
    i=$((i + 1))
  done
}

print_summary() {
  local i=0 total=${#RESULT_NAMES[@]}
  FAILED_COUNT=0
  if [ "$total" -eq 0 ]; then
    info "本次没有执行任何操作。"
    return 0
  fi
  title "执行结果汇总"
  while [ "$i" -lt "$total" ]; do
    if [ "${RESULT_STATES[$i]}" = "0" ]; then
      printf '  %s  %s\n' "${C_GRN}[成功]${C_RST}" "${RESULT_NAMES[$i]}"
    else
      printf '  %s  %s\n' "${C_RED}[失败]${C_RST}" "${RESULT_NAMES[$i]}"
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    i=$((i + 1))
  done
  printf '\n'
  if [ "$FAILED_COUNT" -eq 0 ]; then
    ok "全部 ${total} 个步骤执行成功。"
  else
    warn "有 ${FAILED_COUNT} 个步骤失败，请查看上方输出与日志：${LOG_FILE:-未启用}"
  fi
}

print_next_steps() {
  local new="" keep=""
  title "接下来请注意"
  if [ -n "$NEW_ROOT_PASSWORD" ]; then
    printf '  * %s\n' "${C_BLD}${C_YEL}root 密码（本次由脚本生成，请立刻保存！）：${NEW_ROOT_PASSWORD}${C_RST}"
  fi
  if [ -n "$SSH_M_PORTS" ]; then
    new="$(printf '%s' "$SSH_M_PORTS" | awk '{print $1}')"
    keep="$(printf '%s' "$SSH_M_PORTS" | awk '{$1=""; sub(/^ +/,""); print}')"
    keep="$(trim "$keep")"
    printf '  * SSH 端口：%s' "$new"
    if [ -n "$keep" ]; then printf '（过渡期保留：%s）' "$keep"; fi
    printf '\n'
    printf '     1) 先不要关闭当前会话，另开一个终端执行：ssh -p %s root@<服务器IP>\n' "$new"
    printf '     2) 云服务商控制台的「安全组 / 防火墙」也要放行 %s/TCP，否则连不上\n' "$new"
    if [ -n "$keep" ]; then
      printf '     3) 验证新端口能登录后，编辑 %s 删掉多余的 Port 行，再执行 systemctl restart ssh\n' "$MANAGED_SSHD_CONF"
    fi
    if [ -n "$LAST_SSH_BACKUP" ]; then
      printf '     4) 万一连不上：用 VNC/控制台登录后执行 cp -a %s/. /etc/ssh/ && systemctl restart ssh\n' "$LAST_SSH_BACKUP"
    fi
  fi
  printf '  * 日志文件：%s\n' "${LOG_FILE:-未启用}"
  printf '  * 再次运行本脚本可随时追加/调整设置（重复执行是安全的）\n'
  printf '\n'
  return 0
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
    if [ -z "$p" ]; then p="$(trim "$(current_ssh_ports)")"; fi
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
  printf '%s\n' "   ${SCRIPT_NAME} v${VERSION}  —— Ubuntu / Debian VPS 初始化脚本"
  printf '%s\n' "   https://github.com/${REPO_SLUG}"
  printf '%s\n' "  =============================================================="
  printf '%s\n' "$C_RST"
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  if [ "$DRY_RUN" -eq 1 ] && [ "${VPS_INIT_ALLOW_NONROOT:-0}" = "1" ]; then
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
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  case "$OS_ID" in
    ubuntu|debian|raspbian|linuxmint|pop|kali|armbian|devuan|deepin|neon|zorin|elementary) ;;
    *)
      case "${ID_LIKE:-}" in
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
  kv "日志文件" "${LOG_FILE:-未启用}"
  if [ "$DRY_RUN" -eq 1 ]; then kv "运行模式" "dry-run（不修改系统）"; fi
  if [ "$ASSUME_YES" -eq 1 ]; then kv "应答方式" "--yes（全部用默认值）"; fi
}

# ============================== 参数与主流程 ================================
usage() {
  cat <<'EOF'
ACXC16-VPS新机一键脚本 —— Ubuntu / Debian VPS 初始化交互式脚本

用法:
  直接跑就是交互式：显示状态表 + 编号操作菜单，选一项执行一项，选 0 退出
    curl -fsSL https://github.com/ACXC-16/VPS-init/releases/latest/download/init.sh | bash
    bash init.sh

选项:
  -y, --yes            无人值守：不显示菜单，按默认项一次性执行
                       ★ --yes 不会自动修改 root 密码：避免给你设置一个自己不知道的密码。
                         要改密码必须显式加 --password '新密码' 或 --gen-password。
      --password <密码> 明确指定新的 root 密码（会留在 shell 历史里，用完记得清）
      --gen-password   明确要求生成随机 root 密码：先把密码显示给你确认，确认后才生效
      --port <端口>    直接指定新的 SSH 端口（跳过询问，默认 52052）
      --only <列表>    只执行列出的步骤，逗号分隔，例如 --only sysupdate,ssh-port
      --skip <列表>    跳过列出的步骤，例如 --skip tools,tuning
      --dry-run        演练模式：只打印将要执行的命令，不修改系统
      --text           兼容保留（界面本来就是纯文字菜单，可加可不加）
      --force          跳过系统版本检测（非 Ubuntu/Debian 也能跑，风险自负）
      --no-color       关闭彩色输出
      --log-file <路径> 指定日志文件（默认 /var/log/vps-init.log）
      --list           列出所有步骤标识与默认值后退出
  -h, --help           显示本帮助
  -V, --version        显示版本号

步骤标识（--only / --skip 用）:
  sysupdate     只更新内核 / 驱动 / 固件（其它软件包默认不动）
  ssh-port      修改 SSH 端口（默认 52052）
  root-passwd   修改 root 密码
  fail2ban      安装配置 fail2ban
  tuning        时区 / Swap / BBR
  tools         安装常用命令行工具

安全提示:
  * 改 SSH 端口前，请先在云服务商控制台的安全组放行新端口，并保持当前会话不要断开。
  * 修改后先另开终端确认 ssh -p <新端口> 能登录，再关闭旧连接。
  * 所有改动都会记录到日志文件（默认 /var/log/vps-init.log）。
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
      --ui) shift; [ -n "${1:-}" ] || die "--ui 需要一个参数"; warn "图形方框界面已移除，现在统一是状态表 + 编号菜单（--ui 仅作兼容）" ;;
      --ui=*) warn "图形方框界面已移除，现在统一是状态表 + 编号菜单（--ui 仅作兼容）" ;;
      --text) : ;;
      --menu) : ;;
      --log-file) shift; LOG_FILE="${1:-$LOG_FILE}"; [ -n "${1:-}" ] || die "--log-file 需要一个参数" ;;
      --log-file=*) LOG_FILE="${1#*=}" ;;
      --list) list_steps; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
      *) err "未知参数：$1"; printf '\n'; usage; exit 2 ;;
    esac
    shift
  done
  if [ -n "$ONLY_LIST" ]; then
    local s
    for s in $(printf '%s' "$ONLY_LIST" | tr ',' ' '); do
      in_list "$s" "$(steps_slugs)" || warn "--only 里的步骤不存在：$s"
    done
  fi
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
  prepare_log
  parse_args "$@"
  init_colors
  init_log "$@"
  banner
  require_root
  detect_tty
  check_tty
  check_os
  export DEBIAN_FRONTEND=noninteractive
  show_system_info
  ssh_load_managed

  # 指定了 --only / --skip / --yes 时：一次性执行，不进菜单
  if [ -n "$ONLY_LIST" ] || [ -n "$SKIP_LIST" ] || [ "$ASSUME_YES" -eq 1 ]; then
    build_plan
    confirm_plan
    run_plan
  else
    # 交互式：状态表 + 编号菜单，循环执行直到选 0 退出
    menu_loop
  fi

  print_summary
  print_next_steps
  maybe_reboot
  if [ "$FAILED_COUNT" -gt 0 ]; then return 1; fi
  return 0
}

trap 'printf "\n"; err "已被中断（Ctrl+C）。已执行的步骤不会自动回滚，请查看日志：${LOG_FILE:-未启用}"; exit 130' INT

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

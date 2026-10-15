# ACXC16-VPS新机一键脚本

Ubuntu / Debian VPS 初始化交互式脚本：**每一步都先问你**（可视化菜单），改错会失联的操作（SSH 端口、root 密码）带备份、校验和自动回滚。

在 VPS 上执行这一条即可（已登录 root 不用加 sudo；内容锁定在最新 Release）：

```bash
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash
```

> 不是 root（或习惯 sudo）：把 `| bash` 换成 `| sudo bash`；要带参数：`… | bash -s -- --dry-run`

**更省事（可选，装一次以后只敲 `vpsnew`）** —— 整段复制执行一次：

```bash
cat > /usr/local/bin/vpsnew <<'EOF'
#!/bin/sh
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh -o /tmp/vpsnew.sh && exec bash /tmp/vpsnew.sh "$@"
EOF
chmod +x /usr/local/bin/vpsnew
```

以后直接 psnew（每次自动拉最新版，参数照常：psnew --dry-run）。命令名想换成别的（比如 cxc16），把上面三行里的 psnew 全替换即可。

> 当前版本 **V1.0.0** · 发布页 <https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases>
> 想锁定某个具体版本：把地址里的 `latest/download` 换成 `download/v1.0.0`。

### 关于名字

| 叫什么 | 值 | 说明 |
| --- | --- | --- |
| 脚本显示名 | **ACXC16-VPS新机一键脚本** | 状态表标题、`--version`、日志里都用这个名字 |
| 仓库（URL） | `ACXC-16/ACXC-VPS-ONECLICK` | 保留 ASCII：中文仓库名在链接里会变成 `%E6%96%B0...` 这种转义，一键命令会长到没法用 |
| 服务器上的内部文件名 | 仍是 `vps-init` 前缀 | `/var/log/vps-init.log`、`/etc/ssh/sshd_config.d/00-vps-init.conf`、`/etc/fail2ban/jail.d/vps-init.local`、`/root/vps-init-backup/` 这些**已经在你机器上生效**，改名会留下孤儿配置（尤其 SSH 的 Port 会变成两个文件都在设，优先级容易出错），所以保持不变 |

---

## 界面：跑起来就是一张编号清单，你填编号就行

跑起来是**状态表 + 编号操作菜单**，跟常见的管理面板一个用法：先告诉你这台机器现在是什么状态，再让你选要做什么，**选一项做一项，做完回到菜单**，直到你选 0 退出。

```
  ACXC16-VPS新机一键脚本  v1.0.0
  适用：Ubuntu / Debian    仓库：https://github.com/ACXC-16/ACXC-VPS-ONECLICK

  项目                             状态
  ────────────────────────────────── ──────────────────────────────
  只更新内核 / 驱动 / 固件        内核 6.8.0-31-generic（有 3 个包可升级）
  修改 SSH 端口（默认 52052）     当前端口 52052
  修改 root 密码                  已设置密码（10/15/2026）
  安装配置 fail2ban               已安装，运行中
  时区 / Swap / BBR 网络加速      时区 CST · Swap 2047MB · TCP bbr
  安装常用命令行工具              常用工具 9/10 已安装

操作菜单
  1) 只更新内核 / 驱动 / 固件
  2) 修改 SSH 端口
  3) 修改 root 密码
  4) 安装配置 fail2ban
  5) 时区 / Swap / BBR 网络加速
  6) 安装常用命令行工具
  7) 查看系统信息
  8) 查看运行日志
  9) 全部按默认执行（1 2 3）
  0) 退出

  请选择: 1
```

要点：

- **纯文字菜单，只用键盘数字**，不依赖方向键 / Tab / 蓝底方框 —— FinalShell、PuTTY、Windows Terminal、面板网页终端都能用；
- 状态是**实时读出来的**（内核版本与可升级数、当前 SSH 端口、root 密码是否已设置及日期、fail2ban 是否在跑、时区/Swap/TCP 拥塞算法、常用工具的安装比例）；
- 选 `1`~`6` 执行对应项，**执行完自动回到菜单**，可以接着做下一项；`7` 看系统信息、`8` 看最近 40 行日志；
- 选 `9` 一次性按默认执行 1、2、3 三项；选 `0` 退出（会汇总本次做过哪些操作、成功/失败）；
- 支持全角数字 `８`；**误按方向键**不会出错：输入里的 `^[[A` 之类会被识别出来并提示「没认出输入来」，让你重新输入，不会卡住也不会误执行；
- 每个步骤内部的提问仍然是普通的 `[Y/n]` 文字问答（例如改端口时问你端口号、要不要保留旧端口）。

**命令的实际输出（apt 那些日志）始终是普通滚动文字**，出问题你还能直接复制给我看。

> 说明：早期版本有过"蓝底方框（whiptail）"界面，但那个界面在 FinalShell 等终端里方向键会失效、按钮按不动，**已经整个移除**，现在统一是上面这种状态表 + 编号菜单（任何终端都能用）。`--text` / `--ui` 仍可写，只是没有区别。
---

## 功能一览

| 步骤标识 | 做什么 | 默认值 |
| --- | --- | --- |
| `sysupdate` | **只更新内核 / 驱动 / 固件**（`linux-image`、`linux-modules`、`linux-firmware`、`*-microcode`），会先把可升级清单列出来让你确认；**系统里其它软件包默认一个字都不动** | **Y** |
| `ssh-port` | 修改 SSH 端口（默认 **52052**，可自定义），改前备份、改后校验，失败自动回滚 | **Y** |
| `root-passwd` | 修改 root 密码。**默认手动输入；脚本绝不会在你不知道的情况下改密码**（详见下文），并检查是否允许密码登录 | **Y**（但无人值守时会自动跳过改密码） |
| `fail2ban` | 安装配置 fail2ban 防 SSH 暴力破解（自动跟随你设置的 SSH 端口） | N |
| `tuning` | 时区（默认 Asia/Shanghai）+ Swap 交换文件 + TCP BBR 网络加速 | N |
| `tools` | 安装常用命令行工具（curl/wget/vim/htop/tmux/git/rsync/jq…） | N |

默认值只是「直接回车 / 直接回车确认」时的取值，具体每一项都可以在界面里自己勾选或跳过。

---

## 一键使用

最短的一条（root 登录直接用；非 root 把 `bash` 换成 `sudo bash`）：

```bash
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash
```

需要额外参数（比如只更新驱动、演练模式）时这样加：

```bash
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash -s -- --only sysupdate
```

> 想用**跟随 main 分支的最新提交**（而不是锁定版本）：
> `curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-VPS-ONECLICK/main/init.sh | bash`

脚本会从 `/dev/tty` 读取你的回答，所以 `curl | bash` 这种管道执行方式下交互依然正常。

运行时会先展示：

```
==== 系统信息 ====
  系统             Ubuntu 24.04.1 LTS
  内核             6.8.0-45-generic
  架构             x86_64
  虚拟化           kvm
  内存             3.83 GB
  根分区           40G 总 / 32G 可用（已用 17%）
  SSH 端口         22
  日志文件         /var/log/vps-init.log
```

然后逐项询问，最后汇总成功/失败，任何一个步骤失败都不会中断其他步骤（失败项会计入退出码，`echo $?` 能看到非 0）。

---

## 命令行参数

| 参数 | 说明 |
| --- | --- |
| `-y, --yes` | 全部询问自动用默认值回答（无人值守）。**注意：`--yes` 不会修改 root 密码**，避免给你设一个自己不知道的密码 |
| `--password <密码>` | 明确指定新的 root 密码（会留在 shell 历史里，用完记得 `history -c`） |
| `--gen-password` | 明确要求生成随机 root 密码：**先把密码显示出来、你确认后**才真正生效 |
| `--port <端口>` | 直接指定新的 SSH 端口，跳过询问 |
| `--only <列表>` | 只执行列出的步骤，逗号分隔，例如 `--only sysupdate,ssh-port` |
| `--skip <列表>` | 跳过列出的步骤，例如 `--skip tools,tuning` |
| `--dry-run` | 演练模式：只打印将要执行的命令，不修改系统 |
| `--ui <模式>` | 兼容保留（界面本来就是状态表 + 编号菜单，写不写都一样） |
| `--menu` | 兼容保留（同上） |
| `--text` | 兼容保留（同上） |
| `--force` | 跳过系统版本检测 |
| `--no-color` | 关闭彩色输出 |
| `--log-file <路径>` | 指定日志文件（默认 `/var/log/vps-init.log`） |
| `--list` | 列出所有步骤标识与默认值 |
| `-h, --help` / `-V, --version` | 帮助 / 版本号 |

常用组合：

```bash
# 先演练一遍，看看会做什么
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash -s -- --dry-run

# 只更新系统 + 改 SSH 端口，端口用 52052
sudo bash init.sh --only sysupdate,ssh-port --port 52052

# 无人值守跑全部默认步骤
sudo bash init.sh --yes
```

---

## 各步骤细节

### 1. `sysupdate`：只更新内核 / 驱动 / 固件

VPS 上说的「驱动」就是**内核 + 内核模块 + 固件包**（GPU 驱动、CPU 微码在虚拟机上由宿主机负责）。这一步**不会顺手升级你系统里的其它软件**：

1. 先检查软件包状态（`dpkg --audit`），只有真的装到一半中断了才会去修复；
2. `apt-get update` —— 只刷新软件源索引，不动任何软件；
3. 从 `apt list --upgradable` 里筛出**内核/驱动/固件相关**的包，把清单打印出来，然后问你 `是否升级上面这些包？[Y/n]`：
   - 命中的包名规则：`linux-image*`、`linux-modules*`、`linux-modules-extra*`、`linux-firmware*`、`linux-generic`/`linux-virtual`/`linux-kvm`、`intel-microcode`/`amd64-microcode`（要加别的自行改脚本里的 `KERNEL_PKG_RE`）；
   - 用 `apt-get install --only-upgrade`，只升级、绝不新装无关包；没有可升级的会直接告诉你「已经是最新」；
4. 然后是三个**默认「否」**的可选项：是否顺便把系统里**其它所有**软件包也升级（`apt full-upgrade`）、是否安装 `linux-firmware`、是否 `autoremove` 清理；
5. 检测 `/var/run/reboot-required`，如果内核更新了会在最后问你要不要重启：**选 Y 就立刻重启，不再等倒计时**（重启前会打印重连命令，例如 `ssh -p 52052 root@你的IP`）；选 N 就留给你稍后自己 `reboot`。

也就是说：**你按默认值一路回车，它只会更新驱动/内核，不会碰 nginx、MySQL、Docker 这些业务软件。**

容器 / OpenVZ 环境会明确告知：内核由宿主机提供，本机只能更新用户态软件包。

### 2. `ssh-port`：修改 SSH 端口（默认 52052）

这是最容易把自己关在门外的操作，所以做得比较小心：

1. 校验你输入的端口（必须是 1-65535 的数字，被占用会提示并显示占用进程，可重选）；
2. 询问**过渡期是否保留旧端口**（默认保留，验证新端口能登录后再关掉，这是最稳的做法）；
3. 如果本机 `ufw` / `firewalld` 已启用，自动放行新端口；
4. 把 `/etc/ssh/sshd_config` 和 `sshd_config.d/` 备份到 `/root/vps-init-backup/<时间戳>-ssh/`；
5. 写入受管配置 `/etc/ssh/sshd_config.d/00-vps-init.conf`（`00-` 前缀保证优先级高于云镜像自带的 `50-cloud-init.conf`），并注释掉主配置里写死的 `Port`；
6. `sshd -t` 校验语法 + `sshd -T` 校验新端口确实生效，不生效就自动回滚；
7. 重启 SSH 服务并确认新端口处于监听状态。

结束后会打印明确的操作指引：**先别断开当前会话**，另开终端 `ssh -p 52052 root@IP` 验证，同时记得在云服务商控制台的**安全组**放行新端口。

老版本 OpenSSH（< 7.3，没有 `Include` 指令）会自动改用直接修改主配置的方式。

### 3. `root-passwd`：修改 root 密码

**核心原则：绝不在你不知情的情况下改动密码。** 具体规则：

| 运行方式 | 行为 |
| --- | --- |
| 交互式运行（默认） | 问你「是否自动生成随机强密码？」，**默认是"否"→ 手动输入**（不回显、两次确认、至少 8 位） |
| 无人值守 `--yes` | **跳过改密码**，并明确提示：需要改就加 `--password '新密码'` 或 `--gen-password` |
| `--gen-password` | 生成 24 位随机密码 → **先把密码打在屏幕上（图形模式再弹一个框）** → 问你「已经记下这个密码了，确认现在修改？」→ 你确认后才 `chpasswd` 生效；你选否就一个字节都不改 |
| `--password '新密码'` | 用你给的密码，不做生成、不做二次询问（长度不足 8 位会提醒） |

其它保障：

- 明文密码**不会写进日志文件**（`--password` 传的值脚本也不会打印出来，有测试盯着这一点）；
- 随机密码除了当场显示，还会在**脚本最后的「接下来请注意」里再显示一次**，图形模式下再弹一个「请保存这些信息」的框 —— 防止刷屏看漏；
- 设置完会检查 `PermitRootLogin` / `PasswordAuthentication`：如果当前 SSH 不允许 root 用密码登录（云镜像默认如此），会明确告诉你「只改密码还是登不上」，并询问是否同时开启密码登录（**默认不开启**，安全性更好）。

### 4. `fail2ban`：防 SSH 暴力破解

- 安装 `fail2ban`（顺带尝试 `python3-systemd`，装不上就自动改用日志文件后端）；
- 写入 `/etc/fail2ban/jail.d/vps-init.local`：`bantime 1h` / `findtime 10m` / `maxretry 4`，`[sshd]` 的 `port` 会自动跟随你设置的 SSH 端口；
- 启动并设置开机自启，最后用 `fail2ban-client status sshd` 确认真的生效。

### 5. `tuning`：时区 / Swap / BBR

三件事各自单独询问：

- **时区**：默认 `Asia/Shanghai`，用 `timedatectl` 设置（失败则退回直接写 `/etc/localtime`）；
- **Swap**：已存在 Swap 会跳过；默认按内存大小给 2048MB（>4GB 内存给 4096MB），会先检查根分区剩余空间，写入 `/etc/fstab` 并设置 `vm.swappiness=10`；
- **BBR**：内核 ≥ 4.9 才提供；写入 `/etc/sysctl.d/99-vps-init-bbr.conf` 并 `sysctl --system`，之后会验证是否真的切到 `bbr`。OpenVZ / LXC 这类共享内核环境通常不支持，脚本会如实告诉你。

### 6. `tools`：常用命令行工具

基础包：`curl wget vim nano htop tmux screen unzip zip git rsync lsof ca-certificates gnupg jq tree bash-completion`
可选网络诊断包：`net-tools mtr-tiny traceroute dnsutils`

整体安装失败时会自动改成逐个安装，并把装不上的包名单独告诉你（精简系统上个别包确实不存在）。

---

## 安全须知（重要）

1. **改 SSH 端口之前**，先去云服务商控制台的「安全组 / 防火墙」放行新端口；脚本也能自动放行本机 `ufw` / `firewalld`，但云厂商那层它管不到。
2. **不要关掉当前 SSH 会话**。改完端口后另开一个终端验证 `ssh -p <新端口> root@IP` 能登录，再关旧连接。
3. **万一连不上**：用云厂商控制台的 VNC / 救援模式登录，然后执行（把路径换成日志里打印的那个备份目录）：

   ```bash
   cp -a /root/vps-init-backup/<时间戳>-ssh/. /etc/ssh/ && systemctl restart ssh
   ```

   或者直接删掉受管配置：`rm -f /etc/ssh/sshd_config.d/00-vps-init.conf && systemctl restart ssh`。
4. **只保留新端口**：确认新端口可用后，编辑 `/etc/ssh/sshd_config.d/00-vps-init.conf`，删掉多余的 `Port 22` 一行，再 `systemctl restart ssh`。
5. 所有操作都有日志：`/var/log/vps-init.log`（权限 600）。
6. 脚本可以反复运行，重复执行是安全的；受管配置会保留上次的设置（比如只跑「修改 root 密码」不会把 SSH 端口设置弄丢）。

---

## 如何新增一个步骤

两步就能加一个功能（比如安装 Docker）：

```bash
# 1) 在 init.sh 里写一个函数，返回 0 表示成功、非 0 表示失败（不要用 exit）
step_docker() {
  if ! run env DEBIAN_FRONTEND=noninteractive apt-get -y install docker.io; then
    err "Docker 安装失败"
    return 1
  fi
  ok "Docker 安装完成"
  return 0
}
```

```bash
# 2) 在文件顶部的 STEPS 表里加一行："标识|名称|默认值(y/n)|函数名"
STEPS=(
  ...
  "docker|安装 Docker|n|step_docker"
)
```

脚本会自动把它加进询问列表、执行计划、结果汇总里。需要动系统关键配置时，参考 `step_ssh_port` 的写法：**先备份 → 写入 → 校验 → 失败自动回滚**。

写命令时用 `run` 前缀（例如 `run systemctl restart ssh`），这样 `--dry-run` 演练模式会把它打印出来而不真正执行。

---

## 本地测试与 CI

```bash
bash -n init.sh          # 语法检查
bash tests/smoke.sh      # 冒烟测试：71 项断言，全部在 --dry-run 下跑，不改系统
shellcheck init.sh tests/smoke.sh
```

`tests/smoke.sh` 会把 `/etc/ssh` 指向临时目录后再测试，所以在你自己的机器上跑也是安全的。仓库自带 GitHub Actions：

- `.github/workflows/ci.yml`：每次 push / PR 跑语法检查 + ShellCheck + 冒烟测试；
- `.github/workflows/release.yml`：打 `v*` tag 时**先跑测试（不通过就不发）**，然后自动创建 Release 并把 `init.sh` 作为附件传上去。

测试失败时会把失败项以 **注解（Annotations）** 抛出来，不用翻日志就能看到是哪一项、期望值和实际值。

脚本里有两个只在测试时用到的环境变量（日常使用不用管）：

| 变量 | 作用 |
| --- | --- |
| `VPS_INIT_ALLOW_NONROOT=1` | 配合 `--dry-run`，允许用非 root 身份跑（本地/CI 测试用） |
| `VPS_INIT_FORCE_STDIN=1` | 强制从 stdin 读取回答，方便测试脚本自动喂 y/n |

---

## 发布到 GitHub（手把手）

前提：本机已装 Git（Windows 上装 Git for Windows 即可，安装时保持默认选项）。

**第 1 步：在 GitHub 上建空仓库**

1. 打开 <https://github.com/new>；
2. `Repository name` 填 `VPS-init`（仓库名区分大小写，地址里的 `ACXC-16/ACXC-VPS-ONECLICK` 就是按这个名字配的）；
3. 选 `Public`（要用一键脚本，仓库必须公开）；
4. **不要**勾选 `Add a README file`；
5. 点 `Create repository`。

**第 2 步：推送**

仓库地址已经配好了（`ACXC-16/ACXC-VPS-ONECLICK`），本地 Git 仓库也已初始化并提交，所以只要：

```powershell
cd C:\Users\IdeaPad5-16\Documents\deepseek-harness\default-workspace\vps-init
git push -u origin main
```

第一次 push 会弹出浏览器让你登录 GitHub 授权（Git Credential Manager），授权完就自动推送成功。

> 如果你在另一台机器上重新克隆/重建仓库，用这套命令：
>
> ```bash
> cd VPS-init
> git init -b main
> git add .
> git commit -m "feat: vps-init 首版"
> git remote add origin https://github.com/ACXC-16/ACXC-VPS-ONECLICK.git
> git push -u origin main
> ```

**第 3 步：验证一键脚本**

先确认仓库是 **Public**，然后打开这个地址，能看到脚本内容就说明 raw 链接正常：

```
https://raw.githubusercontent.com/ACXC-16/ACXC-VPS-ONECLICK/main/init.sh
```

然后在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-VPS-ONECLICK/main/init.sh | sudo bash
```

**以后更新**：改完文件后 `git add -A && git commit -m "..." && git push` 即可，`raw` 链接永远指向最新版。

---

## 改名 / 换仓库地址

GitHub 上这两样都能随时改，改完把仓库里的地址一起换掉就行：

- **改仓库名**：仓库页面 → `Settings` → `Repository name` → `Rename`（旧的网页地址 GitHub 会自动重定向）。
- **改用户名**：右上角头像 → `Settings` → `Account` → `Change username`（会同步影响所有仓库地址，旧链接同样会重定向一段时间）。

改完在本机执行（把两处占位换成新地址）：

```bash
cd vps-init
# 1) 换掉文件里的地址（README.md / init.sh / LICENSE 里的用户名或仓库名）
sed -i 's|ACXC-16/ACXC-VPS-ONECLICK|新用户名/新仓库名|g' README.md init.sh

# 2) 换掉本地仓库的远程地址
git remote set-url origin https://github.com/新用户名/新仓库名.git
git add -A && git commit -m "chore: 更新仓库地址" && git push
```

Windows 上如果没有 `sed`，用 PowerShell（无 BOM，不破坏 LF 换行）：

```powershell
cd C:\Users\IdeaPad5-16\Documents\deepseek-harness\default-workspace\vps-init
Get-ChildItem -Path . -Recurse -File -Include *.md, *.sh, LICENSE | ForEach-Object {
  $t = [System.IO.File]::ReadAllText($_.FullName) -replace 'ACXC-16/ACXC-VPS-ONECLICK', '新用户名/新仓库名'
  [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
}
git remote set-url origin https://github.com/新用户名/新仓库名.git
```

> 只改**仓库名**（用户名不变）时，把命令里的 `新用户名/新仓库名` 换成 `ACXC-16/新仓库名` 即可。

---

## 发布新版本（打 tag 自动生成 Release）

```bash
# 1) 改完代码推上去，等 CI 变绿
git add -A && git commit -m "feat: 新增 xxx" && git push

# 2) 打个版本号 tag 并推送 —— GitHub 会自动跑测试、创建 Release、附上 init.sh
git tag -a v1.0.0 -m "ACXC16-VPS新机一键脚本 V1.0.0"
git push origin v1.0.0
```

发布完成后：

- 发布页：<https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases>
- **稳定下载地址**（永远指向最新 Release，不会因为改代码而变）：
  `https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh`
- 附件里还有 `SHA256SUMS.txt`，可以核对下载到的脚本有没有被动过：

```bash
curl -fsSLO https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh
curl -fsSLO https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt
```

> 顺手把脚本头部和 `VERSION="..."` 一起更新成新版本号，Release 页面会自动生成更新说明。

---

## 常见问题

**Q：会不会把我 SSH 关在门外？**
脚本改端口前后都会校验（`sshd -t` + `sshd -T`），校验不过会自动回滚；并且默认保留旧端口做过渡。真正的风险是**云厂商安全组没放行新端口**，这点脚本只能提醒你。

**Q：`curl | bash` 的时候还能交互吗？**
能。脚本的询问统一从 `/dev/tty` 读取，不走 stdin，所以管道执行不影响交互。如果环境里连 `/dev/tty` 都没有（某些面板），就加 `--yes` 走无人值守。

**Q：Ubuntu 24.04 / Debian 12 都支持吗？**
支持，Debian 11+、Ubuntu 20.04+ 都没问题；脚本会自动识别 Debian 与 Ubuntu 系的差异（内核元包名、SSH 服务名等）。其他发行版需要 `--force`，风险自负。

**Q：能重复运行吗？**
可以。所有步骤都是幂等的设计：SSH 受管配置会保留上次设置、fail2ban 配置覆盖写入、Swap 已存在就跳过、已安装的包 apt 会直接跳过。

**Q：会不会把我系统里其它软件（nginx/MySQL/Docker…）也升级了？**
不会。第一步 `sysupdate` 只升级内核 / 驱动 / 固件相关的包，而且会把清单列给你确认；全量升级是一个单独的询问，**默认「否」**，清理也是默认「否」。只想更新驱动的话，默认值一路回车即可。

**Q：会不会给我设一个我不知道的 root 密码，把我关在门外？**
不会。默认是**手动输入**密码；无人值守 `--yes` 模式下**直接跳过改密码**；只有你明确用 `--gen-password` 时才会生成，而且会**先把密码显示出来、等你确认**之后才生效。随机密码还会在脚本结尾再显示一次，图形模式下再弹框提醒保存。

**Q：脚本会不会改我的软件源？**
不会，脚本只使用系统现有的 apt 源。

---

## 目录结构

```
vps-init/
├── init.sh                    # 主脚本（一键执行的就是它）
├── tests/smoke.sh             # 冒烟测试（71 项断言，dry-run，不改系统）
├── .github/workflows/ci.yml   # 每次 push：语法 + ShellCheck + 71 项冒烟测试
├── .github/workflows/release.yml # 打 tag：测试通过后自动发 Release（附 init.sh + SHA256）
├── .gitattributes             # 强制 LF 换行（防止 Windows 上改坏脚本）
├── LICENSE                    # MIT
└── README.md
```

---

## 许可

MIT，见 [LICENSE](LICENSE)。脚本会以 root 权限修改系统，请自行确认每一步都符合你的预期；`--dry-run` 可以先用来看一遍。

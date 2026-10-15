# vps-init

Ubuntu / Debian VPS 初始化交互式脚本：**每一步都先问你 Y/N**，改错会失联的操作（SSH 端口、root 密码）带备份、校验和自动回滚。

```bash
curl -fsSL https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh | sudo bash
```

> 仓库地址已按你的账号配置好：`qinjing-arch/VPS-init`。如果以后改了 GitHub 用户名或仓库名，按文末「改名 / 换仓库地址」一节改一处即可。

---

## 功能一览

| 步骤标识 | 做什么 | 默认值 |
| --- | --- | --- |
| `sysupdate` | 修复 dpkg 状态 → `apt update` → `apt full-upgrade`（内核 / 驱动 / 固件）→ 清理无用包 → 提示是否需要重启 | **Y** |
| `ssh-port` | 修改 SSH 端口（默认 **52052**，可自定义），改前备份、改后校验，失败自动回滚 | **Y** |
| `root-passwd` | 修改 root 密码（手动输入或自动生成随机强密码），并检查是否能密码登录 | **Y** |
| `fail2ban` | 安装配置 fail2ban 防 SSH 暴力破解（自动跟随你设置的 SSH 端口） | N |
| `tuning` | 时区（默认 Asia/Shanghai）+ Swap 交换文件 + TCP BBR 网络加速 | N |
| `tools` | 安装常用命令行工具（curl/wget/vim/htop/tmux/git/rsync/jq…） | N |

默认值只是「直接回车」时的取值，**每一项都会单独询问 y/n**。

---

## 一键使用

在 VPS 上以 root 执行（二选一）：

```bash
# 方式 1：下载后交给 sudo bash
curl -fsSL https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh | sudo bash

# 方式 2：进程替换（效果一样，有些面板里更稳）
sudo bash <(curl -fsSL https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh)
```

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
| `-y, --yes` | 全部询问自动用默认值回答（无人值守；root 密码会自动生成随机密码并打印一次） |
| `--port <端口>` | 直接指定新的 SSH 端口，跳过询问 |
| `--only <列表>` | 只执行列出的步骤，逗号分隔，例如 `--only sysupdate,ssh-port` |
| `--skip <列表>` | 跳过列出的步骤，例如 `--skip tools,tuning` |
| `--dry-run` | 演练模式：只打印将要执行的命令，不修改系统 |
| `--force` | 跳过系统版本检测 |
| `--no-color` | 关闭彩色输出 |
| `--log-file <路径>` | 指定日志文件（默认 `/var/log/vps-init.log`） |
| `--list` | 列出所有步骤标识与默认值 |
| `-h, --help` / `-V, --version` | 帮助 / 版本号 |

常用组合：

```bash
# 先演练一遍，看看会做什么
curl -fsSL https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh | sudo bash -s -- --dry-run

# 只更新系统 + 改 SSH 端口，端口用 52052
sudo bash init.sh --only sysupdate,ssh-port --port 52052

# 无人值守跑全部默认步骤
sudo bash init.sh --yes
```

---

## 各步骤细节

### 1. `sysupdate`：把驱动 / 内核更新一遍

VPS 上说的「驱动」其实就是**内核 + 固件包**（GPU 驱动、CPU 微码在虚拟机上没有意义，由宿主机负责）。脚本做的事情：

1. `dpkg --configure -a` + `apt-get -f install` 修复可能中断的安装状态；
2. `apt-get update`（带 3 次重试）；
3. `apt-get full-upgrade`，并强制保留你现有的配置文件（`--force-confdef --force-confold`），同时关闭 needrestart 的交互弹窗；
4. 可选：安装内核元包（`linux-generic` / `linux-image-amd64`）以便以后自动跟随内核更新；可选安装 `linux-firmware`；
5. 可选 `autoremove --purge` 清理；
6. 检测 `/var/run/reboot-required`，如果内核更新了会提示你重启（默认不自动重启）。

容器 / OpenVZ 环境会明确告诉你：内核由宿主机管理，这一步只能更新用户态软件包。

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

- 两种模式：手动输入（输入两次不回显、至少 8 位、不一致会重试）或自动生成 24 位随机强密码（只显示一次，请立刻保存）；
- 通过 `chpasswd` 设置，**明文密码不会写进日志文件**；
- 设置完会检查 `PermitRootLogin` / `PasswordAuthentication`：如果当前 SSH 不允许 root 用密码登录（云镜像默认如此），会明确告诉你「只改密码还是登不上」，并询问是否要同时开启密码登录（默认不开启，因为安全性会下降）。

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
bash tests/smoke.sh      # 冒烟测试：32 项断言，全部在 --dry-run 下跑，不改系统
shellcheck init.sh tests/smoke.sh
```

`tests/smoke.sh` 会把 `/etc/ssh` 指向临时目录后再测试，所以在你自己的机器上跑也是安全的。仓库自带 GitHub Actions（`.github/workflows/ci.yml`）：语法检查 + 冒烟测试 + ShellCheck，push 之后在仓库的 **Actions** 页能看到结果。

---

## 发布到 GitHub（手把手）

前提：本机已装 Git（Windows 上装 Git for Windows 即可，安装时保持默认选项）。

**第 1 步：在 GitHub 上建空仓库**

1. 打开 <https://github.com/new>；
2. `Repository name` 填 `VPS-init`（仓库名区分大小写，地址里的 `qinjing-arch/VPS-init` 就是按这个名字配的）；
3. 选 `Public`（要用一键脚本，仓库必须公开）；
4. **不要**勾选 `Add a README file`；
5. 点 `Create repository`。

**第 2 步：推送**

仓库地址已经配好了（`qinjing-arch/VPS-init`），本地 Git 仓库也已初始化并提交，所以只要：

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
> git remote add origin https://github.com/qinjing-arch/VPS-init.git
> git push -u origin main
> ```

**第 3 步：验证一键脚本**

先确认仓库是 **Public**，然后打开这个地址，能看到脚本内容就说明 raw 链接正常：

```
https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh
```

然后在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/qinjing-arch/VPS-init/main/init.sh | sudo bash
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
sed -i 's|qinjing-arch/VPS-init|新用户名/新仓库名|g' README.md init.sh

# 2) 换掉本地仓库的远程地址
git remote set-url origin https://github.com/新用户名/新仓库名.git
git add -A && git commit -m "chore: 更新仓库地址" && git push
```

Windows 上如果没有 `sed`，用 PowerShell（无 BOM，不破坏 LF 换行）：

```powershell
cd C:\Users\IdeaPad5-16\Documents\deepseek-harness\default-workspace\vps-init
Get-ChildItem -Path . -Recurse -File -Include *.md, *.sh, LICENSE | ForEach-Object {
  $t = [System.IO.File]::ReadAllText($_.FullName) -replace 'qinjing-arch/VPS-init', '新用户名/新仓库名'
  [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
}
git remote set-url origin https://github.com/新用户名/新仓库名.git
```

> 只改**仓库名**（用户名不变）时，把命令里的 `新用户名/新仓库名` 换成 `qinjing-arch/新仓库名` 即可。

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

**Q：脚本会不会改我的软件源？**
不会，脚本只使用系统现有的 apt 源。

---

## 目录结构

```
vps-init/
├── init.sh                    # 主脚本（一键执行的就是它）
├── tests/smoke.sh             # 冒烟测试（32 项断言，dry-run，不改系统）
├── .github/workflows/ci.yml   # GitHub Actions：语法 + 测试 + ShellCheck
├── .gitattributes             # 强制 LF 换行（防止 Windows 上改坏脚本）
├── LICENSE                    # MIT
└── README.md
```

---

## 许可

MIT，见 [LICENSE](LICENSE)。脚本会以 root 权限修改系统，请自行确认每一步都符合你的预期；`--dry-run` 可以先用来看一遍。

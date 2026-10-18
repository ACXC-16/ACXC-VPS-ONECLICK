# ACXC16-VPS新机一键脚本

Ubuntu / Debian VPS 初始化：一个菜单搞定内核更新、改密码/端口、装工具、BBR、Swap。

```bash
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash
```

首次运行会自动装好快捷命令，以后直接输入 **`acxc`**。

## 菜单

```
  1) 更新内核 / 驱动 / 固件
  2) 修改 root 密码 / SSH 端口
  3) 安装常用工具 / BBR网络加速 / Swap
  4) 查看系统信息
  5) 查看运行日志
  6) 更新脚本
  7) 重启服务
  8) 卸载 / 清理
  0) 退出
```

列表每行显示**当前状态**。**单选**一项时会问你「安装 / 卸载 / 开启 / 关闭 / 跳过」；**一次选两项以上或选 `a`** 就直接按选择全部安装，不再逐项确认。

## 工具项装什么

| # | 名字 | 内容 |
| --- | --- | --- |
| 1 | 下载与证书 | `curl` `wget` `ca-certificates` `gnupg` |
| 2 | 防 SSH 爆破 | `fail2ban`（安装 / 启用 / 暂停 / 卸载） |
| 3 | 加虚拟内存 | `/swapfile` + fstab（开启 / 关闭） |
| 4 | 防火墙 | `ufw`：安装启用 / 放行端口 / 关闭端口 |
| 5 | 进程 / 端口 | `htop` `tmux` `lsof` |
| 6 | 文本编辑 | `vim` `nano` |
| 7 | 传文件 / 解压 | `git` `rsync` `unzip` `zip` |
| 8 | Tab 补全 | `bash-completion` |
| 9 | 磁盘占用 | `jq` `tree` `ncdu` |
| 10 | 网络排障 | `net-tools` `dnsutils` `mtr-tiny` `traceroute` |
| 11 | 设置时区 | 19 个常用时区可选，也能直接输时区名 |
| 12 | BBR 加速 | 开启 / 关闭 BBR |

## 注意事项

- **改 SSH 端口前**先在云控制台安全组放行新端口；改完另开终端 `ssh -p 新端口 root@IP` 验证成功，再关旧连接。
- `acxc1616` 是内置默认密码，容易被猜到，登录后请尽快改成自己的强密码。
- 防火墙（UFW）是**先放行 SSH 端口再启用**；万一失联：云控制台登录后 `ufw disable`。
- 回滚 SSH 配置：`cp -a /root/acxc-vps-backup/<时间戳>-ssh/. /etc/ssh/ && systemctl restart ssh`
- 日志：`/var/log/acxc-vps.log`（菜单 `5) 查看运行日志`），卸载里可一键清掉。

## 命令行用法

```bash
bash init.sh --yes                              # 无人值守（不会改 root 密码）
bash init.sh --only sysupdate                   # 只跑某一步：sysupdate / access / extras
bash init.sh --only access --port 2222 --password '你的密码'
bash init.sh --dry-run                          # 演练，不改系统
bash init.sh --help                             # 全部参数
```

只在 Ubuntu / Debian（含衍生版）测试过；其它发行版加 `--force`，风险自负。

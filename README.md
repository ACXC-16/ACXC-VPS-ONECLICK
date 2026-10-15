# ACXC16-VPS新机一键脚本

Ubuntu / Debian VPS 初始化：状态表 + 编号菜单，选一项做一项。

```bash
curl -fsSL https://github.com/ACXC-16/ACXC-VPS-ONECLICK/releases/latest/download/init.sh | bash
```

首次运行会自动装好快捷命令，以后在 VPS 上直接输入 **`acxc`** 就能打开。

## 菜单

```
  ACXC16-VPS新机一键脚本  v1.0.0
  适用：Ubuntu / Debian    仓库：https://github.com/ACXC-16/ACXC-VPS-ONECLICK

  项目                             状态
  ────────────────────────────────── ──────────────────────────────
  更新内核 / 驱动 / 固件          内核 6.8.0-31-generic（有 3 个包可升级）
  修改 SSH 端口（默认 52052）     当前端口 52052
  修改 root 密码                  已设置密码（10/15/2026）
  常用工具 / fail2ban             常用工具 9/10 已安装 · fail2ban 运行中
  时区 / Swap / BBR 网络加速      时区 CST · Swap 2047MB · TCP bbr

操作菜单
  1) 更新内核 / 驱动 / 固件
  2) 修改 SSH 端口
  3) 修改 root 密码
  4) 安装常用工具 / fail2ban
  5) 时区 / Swap / BBR 网络加速
  6) 查看系统信息
  7) 查看运行日志
  8) 安装 / 更新快捷命令 acxc
  9) 全部按默认执行（1 2 3）
  0) 退出

  请选择:
```

选 `1`~`5` 做一件事，做完自动回到菜单；`0` 退出并汇总本次做了什么。

## 各选项

| 选项 | 做什么 |
| --- | --- |
| 1 | `apt update` 后**只升级内核 / 驱动 / 固件**相关包，其它软件一个都不动；需要重启会提示 |
| 2 | 改 SSH 端口（默认 52052）：备份 → 写入 → `sshd -t/-T` 校验 → 失败自动回滚；默认保留旧端口过渡 |
| 3 | 改 root 密码：**默认手动输入**；只有你明确选随机密码时才生成，而且先显示、你确认后才生效；无人值守不会偷偷改密码 |
| 4 | 常用工具**逐项选择**安装（每项标了 `[推荐]` / `[按需]`），fail2ban 也在里面，选中就自动装好并配置 |
| 5 | 时区（默认 Asia/Shanghai）/ Swap 交换文件 / 开启 BBR，三件各自询问 |

## 几个说明

- **改 SSH 端口前**先在云服务商安全组放行新端口；改完别关当前窗口，另开终端 `ssh -p 新端口 root@IP` 验证成功再关旧连接。
- 出问题可回滚：`cp -a /root/vps-init-backup/<时间戳>-ssh/. /etc/ssh/ && systemctl restart ssh`
- 日志：`/var/log/vps-init.log`；移除快捷命令：`rm /usr/local/bin/acxc`
- 无人值守：`| bash -s -- --yes`；只跑某项：`--only sysupdate`；演练：`--dry-run`；全部参数：`--help`
- 只在 Ubuntu / Debian（含衍生版）上测试过；其它发行版需要 `--force`，风险自负。

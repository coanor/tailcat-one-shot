# Tailcat 一键 SSH 服务

在 macOS、Linux 或 Windows 的 WSL 终端运行同一条命令：

```bash
cd ~/git/tailcat-one-shot && bash serve.sh
```

脚本会安装缺失的 Tailcat、创建或复用 `default` 密钥、启动后台服务，并打印连接地址。以后在另一台装有 Tailcat 的机器上运行它打印的 `tailcat ssh tc…` 命令即可连接。重复运行脚本不会覆盖密钥；在 macOS 上发现同名服务已经运行时，也不会重启它。

**请把连接地址当作密码。** 默认使用 `no-auth-ssh`，知道地址的人就能获得运行服务的用户 Shell。不要把地址、密钥文件或日志提交到 Git，也不要公开到 DNS、网页或聊天群。[Tailcat 官方安全说明](https://github.com/tailscale/tailcat#auth-free-ssh-server)。

## macOS：登录后自动运行

脚本创建用户 LaunchAgent，并通过 `caffeinate -is` 启动 Tailcat。`launchd` 会在进程退出后重新拉起它；`caffeinate -s` 只在接电时有效。锁屏本身不影响连接；用户注销、关机、网络中断或 Mac 实际睡眠时，远程连接不可用。合盖能否保持唤醒还取决于 Mac 的外接显示器、电源及系统设置。[Apple 的 launchd 文档](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。

如果本机已有 `~/Library/LaunchAgents/com.<用户名>.tailcat-ssh.plist`，脚本只会复用它；如果它不是用 `default` 密钥和 `caffeinate` 启动，脚本会报错，不会覆盖。已有其他交互式 Tailcat SSH 服务时，也会先报错，以免同一密钥启动两个服务。

## WSL：Windows 登录后自动运行

在 WSL 的 Bash 中运行同一条命令。脚本会安装 Linux 版 Tailcat，并为当前 Windows 用户注册计划任务。任务在 Windows 登录时启动一个持续运行的 `wsl.exe`；每五分钟检查一次，进程退出后再启动。需要启用 WSL 的 Windows 程序互操作，以及可用的 `powershell.exe`、`wslpath` 和 Linux `flock`。

这里只使用 WSL 中的 Linux Shell，不会开启 Windows 原生 SSH 服务。Windows 锁屏后仍可运行；未登录、睡眠或关机时不可连接。单独启用 WSL 的 systemd 服务**不能**保证 WSL 实例持续运行，因此脚本使用 Windows 计划任务。[微软的 WSL systemd 说明](https://learn.microsoft.com/en-us/windows/wsl/systemd)、[计划任务说明](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create)。

## Linux：开机后自动运行

在使用 systemd 和 systemd-logind 的 Linux 上运行同一条命令。脚本建立用户服务，并通过 `loginctl enable-linger` 让它在注销后和开机时继续运行；这一步可能请求 `sudo` 密码。Linux 进入睡眠时仍不可连接。[systemd 的 linger 说明](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html)。

Linux 和 WSL 缺少 Tailcat 时，脚本下载官方 v0.6.0 的 amd64 或 arm64 发布包，并校验内置的 SHA-256。macOS 优先复用现有 Tailcat，否则使用 Homebrew 或 Go 安装。已有旧版 Tailcat 会保留，脚本会自动选择对应的命令格式。[Tailcat 发布包](https://github.com/tailscale/tailcat/releases/tag/v0.6.0)。

## 查看或停止

```bash
bash serve.sh status   # 后台服务状态和连接地址
bash serve.sh address  # 只打印连接地址
bash serve.sh stop     # 停止服务，保留密钥
bash serve.sh          # 再次启动
```

如果你正通过这个 Tailcat 服务远程连接，`stop` 会立即断开当前会话。首次安装或切换现有服务，请在机器本地操作。

日志和地址保存在 `~/.local/state/tailcat-one-shot/`，目录权限为 `700`。Tailcat 的 `default` 密钥由 Tailcat 自己保存在系统用户配置目录中：macOS 通常是 `~/Library/Application Support/tailcat/keys/default.private.json`，Linux/WSL 通常是 `~/.config/tailcat/keys/default.private.json`。删除或更换密钥会改变连接地址。

## 运行检查

```bash
bash tests/test.sh
```

测试覆盖 Bash 语法、旧/新 Tailcat 参数、LaunchAgent plist 渲染、Linux systemd unit 渲染。WSL 计划任务需要在 Windows 上进行最终实机验证；仅在 macOS 上无法验证它是否已被 Windows 任务计划程序接受。

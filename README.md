# AnyRouter API Probe

这个目录用于监测 AnyRouter 号池是否可用。现在有两个主入口：

- `probe_claude_code.zsh`: Claude Code 探针，默认通过真实 `claude --print` 调用，读取 `~/.claude/settings.json`，模型 `opus[1m]`，effort `xhigh`，提示词 `hi`。
- `probe_codex.zsh`: Codex/GPT 探针，默认模型 `gpt-5.5`，通过真实 `codex exec` 发送 `hi`。

两个脚本都会读取同目录的 `API_KEY`，不会把 API key 写入日志。macOS 定时任务使用 `launchd`，默认会继承当前 shell 的代理环境变量。

## 一次性测试

```zsh
cd /Users/yang/Codes/anyrouter-api-probe
chmod +x probe_claude_code.zsh probe_codex.zsh

./probe_claude_code.zsh once
./probe_codex.zsh once
```

`once` 默认会在可用时弹出 `dialog` 提醒。若只想看终端输出：

```zsh
./probe_claude_code.zsh once --no-notify
./probe_codex.zsh once --no-notify
```

测试通知：

```zsh
./probe_claude_code.zsh test-notification
./probe_codex.zsh test-notification
```

## 开启定时 Probe

默认 15 分钟。默认启动模式是 `stop-on-available`：后台定时探测，一旦状态变为 `available`，脚本会自动执行 `stop`，移除对应的 launchd 定时任务，避免继续消耗请求额度。

```zsh
./probe_claude_code.zsh start
./probe_codex.zsh start
```
行为是：
1.重新写入 Claude 探针的 plist。
2.执行 launchctl bootout "gui/$UID" "$PLIST"，卸载已有的同名任务。
3.再 bootstrap 加载新任务。
4.立即 kickstart 触发一次探测。
所以它相当于“重启并替换 Claude 探针配置”

自由选择间隔：

```zsh
./probe_claude_code.zsh start -i 30m
./probe_codex.zsh start -i 30m
./probe_codex.zsh start -i 900s
./probe_codex.zsh start -i 1h
```

如果希望保持之前的持续轮询方式，即可用后仍然每隔固定时间继续探测，使用 `--always`：

```zsh
./probe_claude_code.zsh start -i 30m --always
./probe_codex.zsh start -i 30m --always
```

可用时弹 macOS 通知。若只想在状态从不可用变可用时通知：

```zsh
./probe_claude_code.zsh start -i 15m --notify-mode on-change
./probe_codex.zsh start -i 15m --notify-mode on-change
```

通知通道默认是 `dialog`：成功时弹出一个不会自动消失的可见对话框。`auto` 会优先使用 `terminal-notifier` 投递到 macOS 通知中心，再尝试 VS Code/`osascript`，同时播放系统声音和 terminal bell。若只能听到声音但看不到横幅，请在系统设置里检查 `Terminal Notifier` 的通知样式是否允许横幅或提醒；不是只检查 VS Code。

如果通知横幅仍被 macOS 吞掉，可以改用可见弹窗。`dialog` 默认不会自动消失，会一直停留到你点 OK：

```zsh
./probe_codex.zsh test-notification
ANYROUTER_NOTIFY_METHOD=terminal-notifier ./probe_codex.zsh test-notification
ANYROUTER_NOTIFY_METHOD=dialog ./probe_codex.zsh test-notification

./probe_codex.zsh start -i 15m --notify-method terminal-notifier
./probe_codex.zsh start -i 15m --notify-method dialog
./probe_claude_code.zsh start -i 15m --notify-method dialog
```

若希望 `dialog` 自动消失，可以设置秒数：

```zsh
ANYROUTER_NOTIFY_DIALOG_SECONDS=30 ./probe_codex.zsh start -i 15m --notify-method dialog
```

可选通道：`auto`、`terminal-notifier`、`vscode`、`osascript`、`alert`、`sound`、`bell`、`all`。

## 查看与停止

快速确认后台探针当前状态：

```zsh
./probe_claude_code.zsh health
./probe_codex.zsh health
```

重点看这几项：

- `loaded=yes`: launchd 已加载，后台定时仍有效。
- `Mode`: `stop-on-available` 表示可用后自动停止；`always` 表示持续轮询。
- `Interval`: 定时间隔秒数，例如 `1800s` 是 30 分钟。
- `last_exit=0`: 上一次脚本正常结束。
- `Last result`: 最近一次实际探测结果。

在默认 `stop-on-available` 模式下，如果 `Last result` 已经是 `available`，随后看到 `loaded=no` 或 plist 消失，通常表示探针已经按规则自动停止。若你需要它一直留在后台，请重新用 `--always` 启动：

```zsh
./probe_claude_code.zsh start -i 30m --always
./probe_codex.zsh start -i 30m --always
```

```zsh
./probe_claude_code.zsh status
./probe_codex.zsh status

./probe_claude_code.zsh tail
./probe_codex.zsh tail

./probe_claude_code.zsh stop
./probe_codex.zsh stop
```

`launchd` 不是常驻循环进程，而是按间隔唤醒脚本执行一次；所以 `status` 在两次探测之间显示 `state = not running` 是正常的。只要 plist 仍在 `~/Library/LaunchAgents/`，并且 `run interval` 是你设置的秒数，就会继续后台定时运行。

`status` 会输出完整 launchd 详情，通常只在排查问题时使用；日常确认用 `health` 更快。

Claude 探针默认每个账号最多等待 `ANYROUTER_MAX_TIME=120` 秒；account-1 超时后会继续测试 account-2。只有某个账号成功 `available` 时，才会提前停止后续账号测试以节省额度。

日志位置：

- `logs/claude-code.tsv`
- `logs/codex.tsv`

## 常用覆盖项

Claude 默认走真实 Claude Code CLI，因此会参考你的 `~/.claude/settings.json`。脚本同时显式传入 `--model 'opus[1m]'`、`--effort xhigh` 和 `--betas=context-1m-2025-08-07`：

```zsh
./probe_claude_code.zsh once --model 'opus[1m]' --prompt hi
./probe_claude_code.zsh once --settings ~/.claude/settings.json
./probe_claude_code.zsh once --mode api --api-model claude-opus-4-8
```

Codex 默认使用 `gpt-5.5`，并调用本机 `codex exec`，这和实际聊天路径更接近：

```zsh
./probe_codex.zsh once --model gpt-5.5 --prompt hi
./probe_codex.zsh once --all-accounts
```

`probe_codex.zsh` 默认一个账号成功后就停止，以减少消耗；加 `--all-accounts` 会测试 `API_KEY` 里的所有 OpenAI key。

## 结果判断

- `available`: 至少一个账号成功，号池当前可用。
- `rate_limited_or_pool_busy`: 返回 429 或等价限流错误，更像号池拥塞或代理端限流。
- `auth_failed`: key 或鉴权方式有问题。
- `timeout`: CLI 请求超过 `ANYROUTER_MAX_TIME`，默认 120 秒。
- `network_error` / `claude_cli_error` / `codex_cli_error`: 网络、代理、CLI 或请求链路异常。

探针请求尽量使用最短提示词 `hi`，但仍会消耗 API 请求额度。

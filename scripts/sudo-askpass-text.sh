#!/usr/bin/env bash
# sudo-askpass-text.sh — 纯终端 askpass（无 GUI 时用），供 sudd-text 调用。
# 通过 systemd-ask-password 把密码问询交给系统密码代理 / 你终端里的
# _systemd-ask-password-agent_。若系统中没有 agent，会原样报错。
set -euo pipefail
if command -v systemd-ask-password >/dev/null 2>&1; then
  exec systemd-ask-password --no-tty "dsh-tui 需要 root 权限，请输入 sudo 密码："
fi
echo "sudd-text: 无 systemd-ask-password，无法交互输入密码。" >&2
exit 1

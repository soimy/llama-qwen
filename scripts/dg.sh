#!/usr/bin/env bash
# dg.sh — 把一段 bash 脚本在 docker 组（newgrp docker）上下文里以 bash 执行。
#
# 背景：当前用户已加入 docker 组，但本会话进程的补充组没刷新；
# /etc/group 已含且只能用 newgrp 生效，而 newgrp 起的是用户的默认 shell（fish）。
# 这里把整段 bash 脚本 base64 成一行，让 fish 只执行一个 `bash -c`，再在里层解回 bash 跑。
#
# 用法：bash scripts/dg.sh '这里是一整段 bash 命令'
#   例：bash scripts/dg.sh 'docker compose ps'
#
# 注：需要当前 shell 在 /dev/tty 外能读到 newgrp 的 stdin（管道）即可。
set -uo pipefail
SCRIPT="${1:?usage: dg.sh '<bash script>'}"
B64="$(printf '%s' "$SCRIPT" | base64 -w0)"
printf 'bash -c "echo %s | base64 -d | bash"\n' "$B64" | newgrp docker

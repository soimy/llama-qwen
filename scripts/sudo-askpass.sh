#!/usr/bin/env bash
#
# sudo-askpass.sh — GUI/交互式 sudo 密码问询助手（供 sudo -A 使用）
#
# dsh-tui 里每次 bash 都在"无 TTY / 无 stdin"的全新 shell 中执行，普通 `sudo`
# 无法交互输入密码。本脚本充当 SUDO_ASKPASS：sudo -A 需要密码时会调用它，
# 弹出一个对话框让用户在桌面上输入密码，输入经由 stdin 返回给 sudo。
#
# 优先级：zenity (GTK) > kdialog (KDE) > yad > 若有 TTY 时纯文本提示。
#
# 用法：
#   SUDO_ASKPASS=/home/sym/Repo/llama-qwen/scripts/sudo-askpass.sh \
#     sudo -A <命令...>
# 通常无需直接调用，请使用 `sudd` 包装器（见 scripts/sudd）。

set -euo pipefail

TITLE="${SUDO_ASKPASS_TITLE:-sudo 提权}"
TEXT="${SUDO_ASKPASS_TEXT:-dsh-tui 需要 root 权限，请输入 sudo 密码：}"

# --- 1) GTK 系：zenity -----------------------------------------------------
if command -v zenity >/dev/null 2>&1; then
  exec zenity --password \
    --title="$TITLE" \
    --text="$TEXT" \
    --width=400
fi

# --- 2) KDE 系：kdialog ----------------------------------------------------
if command -v kdialog >/dev/null 2>&1; then
  exec kdialog --title "$TITLE" --password "$TEXT"
fi

# --- 3) yad -----------------------------------------------------------------
if command -v yad >/dev/null 2>&1; then
  exec yad --entry --hide-text \
    --title="$TITLE" \
    --text="$TEXT" \
    --width=400
fi

# --- 4) 兜底：若有 TTY 则用纯文本提示（基本不会走到） -------------------
if [ -t 0 ]; then
  printf '%s ' "$TEXT" >&2
  read -r -s REPLY >&2 < /dev/tty || true
  printf '\n' >&2
  printf '%s\n' "$REPLY"
  exit 0
fi

# --- 5) 全部不可用：明确报错 ----------------------------------------------
echo "sudo-askpass: 未找到 zenity/kdialog/yad，且无 TTY 可输入密码。" >&2
echo "请安装 zenity（sudo pacman -S zenity），或改用 scripts/sudd-text 输入法。" >&2
exit 1

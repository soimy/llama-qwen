#!/usr/bin/env bash
# 把已存在的容器重启策略全部改为 no（配合 docker-compose.yml 里所有服务的 restart: "no"），
# 使 docker 守护进程开机启动时不再自动拉起任何容器。
# 之后每次开机手动选择：make up（默认模型） / make up-uncensored（8081）。
#
# 用法：bash scripts/disable-autostart.sh
#   - root 或已在 docker 组：直接执行
#   - 否则自动以 sudo 执行（需已缓存 sudo 凭据，或准备好输密码）
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -eq 0 ] || id -nG | grep -qw docker; then
  DOCKER="docker"
else
  echo ">> 当前用户不在 docker 组，以下 docker 命令以 sudo 执行"
  DOCKER="sudo docker"
fi

CTRS="qwen-llama qwen-llama-uncensored qwen-openwebui qwen-searxng"

echo "==> [1/3] 应用前各容器当前重启策略："
for c in $CTRS; do
  if $DOCKER inspect "$c" >/dev/null 2>&1; then
    $DOCKER inspect --format "   {{.Name}} => {{.HostConfig.RestartPolicy.Name}}" "$c"
  else
    echo "   $c => (容器不存在, 跳过)"
  fi
done

echo "==> [2/3] 将已存在容器重启策略全部改为 no"
for c in $CTRS; do
  if $DOCKER inspect "$c" >/dev/null 2>&1; then
    $DOCKER update --restart=no "$c"
  fi
done

echo "==> [3/3] 应用后校验："
for c in $CTRS; do
  if $DOCKER inspect "$c" >/dev/null 2>&1; then
    $DOCKER inspect --format "   {{.Name}} => {{.HostConfig.RestartPolicy.Name}}" "$c"
  fi
done

echo "==> 完成。开机将不再自动拉起任何容器；需要时手动：make up / make up-uncensored"

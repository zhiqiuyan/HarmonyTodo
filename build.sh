#!/usr/bin/env bash
# 命令行构建脚本：不打开 IDE 直接产出 HAP（Windows / macOS 通用）。
# 用法：
#   ./build.sh            # debug 构建（未签名）
#   ./build.sh release    # release 构建（未签名，需另外配置签名才能上真机）
#
# 本机（Windows）注意：DevEco 自带 hvigor 的 workspace 软链接解析存在兼容问题，
# 已改用 C:\HUAWEI\hvigor-tool（无空格路径 + 已打补丁的 hvigorw.js + 预置真实依赖）。
# 如该目录缺失，请先按 README/工作日志恢复，否则会回退到 DevEco 内置 hvigor。
set -euo pipefail

MODE="${1:-debug}"

# 自动探测 DevEco Studio 安装位置
if [ -z "${DEVECO_HOME:-}" ]; then
  for c in "/c/Program Files/Huawei/DevEco Studio" "/c/Program Files/DevEco Studio" "/Applications/DevEco-Studio.app/Contents"; do
    if [ -d "$c" ]; then DEVECO_HOME="$c"; break; fi
  done
fi
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"

export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export NODE_HOME="$DEVECO_HOME/tools/node"
# jbr 布局：Windows/Linux 为 jbr，macOS 为 jbr/Contents/Home
if [ -x "$DEVECO_HOME/jbr/bin/java" ]; then
  export JAVA_HOME="$DEVECO_HOME/jbr"
else
  export JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
fi

# hvigorw：优先用无空格修复版（Windows）
if [ -x "/c/HUAWEI/hvigor-tool/bin/hvigorw" ]; then
  HVIGORW="/c/HUAWEI/hvigor-tool/bin/hvigorw"
else
  HVIGORW="$DEVECO_HOME/tools/hvigor/bin/hvigorw"
fi

export PATH="$JAVA_HOME/bin:$NODE_HOME:$NODE_HOME/bin:$(dirname "$HVIGORW"):$PATH"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if [ ! -d "$DEVECO_HOME" ]; then
  echo "未找到 DevEco Studio：$DEVECO_HOME" >&2
  exit 1
fi

echo "使用 hvigor: $HVIGORW"
"$HVIGORW" \
  assembleHap \
  --mode module \
  -p product=default \
  -p buildMode="$MODE" \
  --no-daemon

echo "---- 产物 ----"
find entry/build -name "*.hap" -exec ls -lh {} \;

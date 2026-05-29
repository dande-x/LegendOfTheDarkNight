#!/bin/bash
# 监视模式 - 用于 ai-dev-kit 项目
cd "$(dirname "$0")" || exit 1

mkdir -p ../../logs

echo "🚀 启动 Lua LSP 监视模式"

# 检测 Python（Windows 优先 python，Linux/Mac 优先 python3）
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    PYTHON_CMD=$(command -v python || command -v python3)
else
    PYTHON_CMD=$(command -v python3 || command -v python)
fi

if [ -z "$PYTHON_CMD" ]; then
    echo "❌ 错误: 未找到 Python"
    exit 1
fi

exec $PYTHON_CMD lua_lsp_server.py \
  --path ../../src \
  --output-dir ../../logs


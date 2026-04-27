#!/bin/bash
# ========================================
# openclaw-resume 环境恢复脚本
# 自动生成，请勿手动编辑
# ========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/openclaw-resume-setup.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== 开始恢复环境 ==="

# 1. 系统包
if [ -f "$SCRIPT_DIR/apt-packages.txt" ] && command -v apt-get &>/dev/null; then
    log "检查系统包差异..."

    # 提取需要安装的包
    NEED_INSTALL=""
    while IFS= read -r line; do
        pkg=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        if [ "$status" = "install" ]; then
            if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                NEED_INSTALL="$NEED_INSTALL $pkg"
            fi
        fi
    done < "$SCRIPT_DIR/apt-packages.txt"

    if [ -n "$NEED_INSTALL" ]; then
        log "安装缺失的系统包: $NEED_INSTALL"
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq $NEED_INSTALL 2>/dev/null || log "部分系统包安装失败"
        else
            log "需要 sudo 权限安装系统包"
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y -qq $NEED_INSTALL 2>/dev/null || log "部分系统包安装失败"
        fi
    else
        log "系统包无差异"
    fi
fi

# 2. Python 依赖
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    log "安装 Python 依赖..."

    # 检测差异
    if command -v pip &>/dev/null || command -v pip3 &>/dev/null; then
        PIP_CMD="pip"
        command -v pip3 &>/dev/null && PIP_CMD="pip3"

        # 对比已安装和需要安装的
        INSTALLED=$($PIP_CMD freeze 2>/dev/null || true)
        NEED_PIP=""

        while IFS= read -r req; do
            # 跳过空行和注释
            [[ -z "$req" || "$req" == \#* ]] && continue
            pkg_name=$(echo "$req" | sed 's/[<>=!].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            if ! echo "$INSTALLED" | grep -qi "^${pkg_name}=="; then
                NEED_PIP="$NEED_PIP $req"
            fi
        done < "$SCRIPT_DIR/requirements.txt"

        if [ -n "$NEED_PIP" ]; then
            $PIP_CMD install -q $NEED_PIP 2>/dev/null || log "部分 Python 包安装失败"
        else
            log "Python 依赖无差异"
        fi
    fi
fi

# 3. Node.js 依赖
if command -v npm &>/dev/null; then
    # 优先用 environment 目录下的 package.json
    if [ -f "$SCRIPT_DIR/package.json" ]; then
        log "安装 Node.js 依赖 (from environment)..."
        WORK_DIR=$(mktemp -d)
        cp "$SCRIPT_DIR/package.json" "$WORK_DIR/"
        [ -f "$SCRIPT_DIR/package-lock.json" ] && cp "$SCRIPT_DIR/package-lock.json" "$WORK_DIR/"
        cd "$WORK_DIR" && npm install --silent 2>/dev/null || log "Node.js 依赖安装失败"
        rm -rf "$WORK_DIR"
    elif [ -f "$SCRIPT_DIR/../workspace/package.json" ]; then
        log "安装 Node.js 依赖 (from workspace)..."
        cd "$SCRIPT_DIR/../workspace"
        npm install --silent 2>/dev/null || log "Node.js 依赖安装失败"
    fi
fi

log "=== 环境恢复完成 ==="

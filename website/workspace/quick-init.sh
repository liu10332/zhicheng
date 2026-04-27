#!/bin/bash
# ========================================
# openclaw-resume 一键初始化
# 用法:
#   bash quick-init.sh init <项目名> [工作目录] [PAT] [GitHub用户名]
#   bash quick-init.sh add <项目名> <文件/目录...>
#   bash quick-init.sh push <项目名> [PAT] [GitHub用户名]
#   bash quick-init.sh status <项目名>
#
# 流程:
#   1. init   → 初始化项目（创建仓库+同步文件，不推送）
#   2. add    → 手动添加额外文件
#   3. push   → 推送到 GitHub
#
# 快捷用法（一步完成）:
#   bash quick-init.sh init my-project /path/to/code && bash quick-init.sh push my-project
# ========================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step()  { echo -e "${BLUE}[→]${NC} $*"; }

RESUME_BASE="${OPENCLAW_RESUME_BASE:-$HOME/.openclaw-resume}"

# 获取状态目录
get_state_dir() {
    echo "${RESUME_BASE}/${1}"
}

# ========================================
# 子命令: init
# ========================================
cmd_init() {
    local PROJECT_NAME="${1:-}"
    local WORKSPACE_DIR="${2:-.}"
    local PAT="${3:-${OPENCLAW_RESUME_PAT:-}}"
    local GITHUB_USER="${4:-${OPENCLAW_RESUME_USER:-}}"

    if [ -z "$PROJECT_NAME" ]; then
        echo "用法: bash quick-init.sh init <项目名> [工作目录] [PAT] [GitHub用户名]"
        exit 1
    fi

    # 转换为绝对路径
    WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd)" || {
        log_error "工作目录不存在: $WORKSPACE_DIR"
        exit 1
    }

    # 交互式获取缺失信息
    if [ -z "$PAT" ]; then
        echo -n "GitHub Personal Access Token: "
        read -rs PAT
        echo ""
        [ -z "$PAT" ] && { log_error "PAT 不能为空"; exit 1; }
    fi

    if [ -z "$GITHUB_USER" ]; then
        echo -n "GitHub 用户名: "
        read -r GITHUB_USER
        [ -z "$GITHUB_USER" ] && { log_error "用户名不能为空"; exit 1; }
    fi

    # 前置检查
    log_step "检查环境..."
    command -v git &>/dev/null || { log_error "git 未安装"; exit 1; }

    git config --global user.email "${GITHUB_USER}@local" 2>/dev/null || true
    git config --global user.name "$GITHUB_USER" 2>/dev/null || true
    export GIT_TERMINAL_PROMPT=0
    git config --global http.postBuffer 524288000 2>/dev/null || true

    # 验证 PAT
    log_step "验证 GitHub PAT..."
    local HTTP_CODE
    HTTP_CODE=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $PAT" \
        "https://api.github.com/user" 2>/dev/null || echo "000")

    case "$HTTP_CODE" in
        200) log_info "PAT 验证通过" ;;
        401) log_error "PAT 无效或已过期"; exit 1 ;;
        000) log_warn "无法连接 GitHub，继续尝试..." ;;
        *)   log_warn "GitHub API 返回 $HTTP_CODE，继续..." ;;
    esac

    # 创建 GitHub 仓库
    local REPO_NAME="${PROJECT_NAME}-state"
    log_step "创建 GitHub 仓库: ${REPO_NAME}..."
    local REPO_RESULT
    REPO_RESULT=$(timeout 15 curl -s -H "Authorization: token $PAT" \
        -d "{\"name\":\"${REPO_NAME}\",\"private\":true,\"description\":\"openclaw-resume: ${PROJECT_NAME}\"}" \
        "https://api.github.com/user/repos" 2>/dev/null)

    if echo "$REPO_RESULT" | grep -q '"full_name"'; then
        log_info "仓库创建成功: ${GITHUB_USER}/${REPO_NAME}"
    elif echo "$REPO_RESULT" | grep -q 'already_exists'; then
        log_warn "仓库已存在，将使用现有仓库"
    else
        log_warn "仓库创建结果不确定，继续..."
    fi

    # 初始化本地状态目录
    local STATE_DIR
    STATE_DIR=$(get_state_dir "$PROJECT_NAME")
    local CLONE_URL="https://${PAT}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

    log_step "初始化本地状态目录..."
    mkdir -p "$STATE_DIR"

    if timeout 15 git clone "$CLONE_URL" "$STATE_DIR" 2>/dev/null; then
        log_info "仓库克隆成功"
    else
        log_info "仓库为空，本地初始化..."
        rm -rf "$STATE_DIR" 2>/dev/null
        mkdir -p "$STATE_DIR/environment" "$STATE_DIR/workspace" "$STATE_DIR/checkpoints"
        git -C "$STATE_DIR" init -b main
        git -C "$STATE_DIR" remote add origin "$CLONE_URL"
    fi

    mkdir -p "$STATE_DIR/environment" "$STATE_DIR/workspace" "$STATE_DIR/checkpoints"

    # 生成 progress.yaml
    log_step "生成进度文件..."
    local NOW
    NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    cat > "$STATE_DIR/progress.yaml" << EOF
# openclaw-resume 进度追踪文件
session:
  id: "$(date +%Y-%m-%d)-am-1"
  started: "${NOW}"
  expires_at: ""
  last_saved: "${NOW}"

position:
  project: "${PROJECT_NAME}"
  project_desc: ""
  task: ""
  step: "0"
  total_steps: "0"
  note: ""

log:
  - "$(date +%H:%M) 项目初始化完成"

checkpoints: []

todo: []
EOF

    # 同步工作文件
    log_step "同步工作文件..."
    if command -v rsync &>/dev/null; then
        rsync -a --delete \
            --exclude='node_modules' --exclude='__pycache__' --exclude='.venv' \
            --exclude='.git' --exclude='*.pyc' --exclude='.openclaw-resume' \
            "$WORKSPACE_DIR/" "$STATE_DIR/workspace/" 2>/dev/null || true
    else
        cp -r "$WORKSPACE_DIR"/* "$STATE_DIR/workspace/" 2>/dev/null || true
    fi
    log_info "工作文件已同步"

    # 捕获环境
    log_step "捕获环境依赖..."
    if command -v pip &>/dev/null; then
        pip freeze > "$STATE_DIR/environment/requirements.txt" 2>/dev/null || \
        pip3 freeze > "$STATE_DIR/environment/requirements.txt" 2>/dev/null || true
    fi
    if command -v dpkg &>/dev/null; then
        dpkg --get-selections 2>/dev/null | grep -v deinstall > "$STATE_DIR/environment/apt-packages.txt" || true
    fi
    if command -v npm &>/dev/null; then
        npm ls -g --depth=0 --json 2>/dev/null > "$STATE_DIR/environment/npm-global.json" || true
        [ -f "$WORKSPACE_DIR/package.json" ] && cp "$WORKSPACE_DIR/package.json" "$STATE_DIR/environment/" 2>/dev/null || true
    fi
    {
        echo "# 环境变量快照"
        for var in PATH PYTHONPATH LANG LC_ALL NODE_PATH HOME SHELL; do
            [ -n "${!var:-}" ] && echo "${var}=${!var}"
        done
    } > "$STATE_DIR/environment/env-vars.txt"
    log_info "环境依赖已捕获"

    # 生成 .gitignore
    cat > "$STATE_DIR/.gitignore" << 'EOF'
.env
*.key
*.pem
__pycache__/
node_modules/
.venv/
*.pyc
.DS_Store
EOF

    # 写入配置（供 add/push 读取）
    cat > "$STATE_DIR/.resume-config" << EOF
PROJECT_NAME=${PROJECT_NAME}
WORKSPACE_DIR=${WORKSPACE_DIR}
PAT=${PAT}
GITHUB_USER=${GITHUB_USER}
REPO_NAME=${PROJECT_NAME}-state
CLONE_URL=${CLONE_URL}
EOF
    chmod 600 "$STATE_DIR/.resume-config"

    # 初始提交（不推送）
    git -C "$STATE_DIR" add -A
    git -C "$STATE_DIR" commit -m "init: ${PROJECT_NAME} state initialized" 2>/dev/null || true
    git -C "$STATE_DIR" branch -M main

    echo ""
    echo "═══════════════════════════════════════════"
    log_info "✅ 项目 ${PROJECT_NAME} 初始化完成（未推送）"
    echo ""
    echo "  📁 状态目录: ${STATE_DIR}"
    echo "  📂 工作目录: ${WORKSPACE_DIR}"
    echo ""
    echo "  接下来你可以："
    echo "    1. 手动添加文件: bash quick-init.sh add ${PROJECT_NAME} <文件...>"
    echo "    2. 推送到 GitHub: bash quick-init.sh push ${PROJECT_NAME}"
    echo ""
    echo "  或一步完成: bash quick-init.sh push ${PROJECT_NAME}"
    echo "═══════════════════════════════════════════"
}

# ========================================
# 子命令: add
# ========================================
cmd_add() {
    local PROJECT_NAME="${1:-}"
    shift 2>/dev/null

    if [ -z "$PROJECT_NAME" ] || [ $# -eq 0 ]; then
        echo "用法: bash quick-init.sh add <项目名> <文件/目录...>"
        echo ""
        echo "示例:"
        echo "  bash quick-init.sh add my-project ./config.yaml"
        echo "  bash quick-init.sh add my-project ./docs/ ./README.md"
        exit 1
    fi

    local STATE_DIR
    STATE_DIR=$(get_state_dir "$PROJECT_NAME")

    if [ ! -d "$STATE_DIR/.git" ]; then
        log_error "项目 ${PROJECT_NAME} 不存在，请先运行: bash quick-init.sh init ${PROJECT_NAME}"
        exit 1
    fi

    local WORKSPACE_DST="${STATE_DIR}/workspace"
    local added=0

    for item in "$@"; do
        if [ ! -e "$item" ]; then
            log_warn "文件不存在: $item"
            continue
        fi

        local item_name
        item_name=$(basename "$item")

        if [ -d "$item" ]; then
            # 目录：递归复制目录名到 workspace
            local dir_name
            dir_name=$(basename "$item")
            cp -r "$item" "$WORKSPACE_DST/$dir_name/" 2>/dev/null && {
                log_info "已添加目录: $item → workspace/$dir_name/"
                added=$((added + 1))
            }
        else
            # 文件：如果在当前目录下则保留相对路径，否则只保留文件名
            local real_item
            real_item="$(cd "$(dirname "$item")" 2>/dev/null && pwd)/$(basename "$item")" || real_item="$item"
            local real_workspace
            real_workspace="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd)"

            if [[ "$real_item" == "$real_workspace"/* ]]; then
                # 文件在工作目录下，保留相对路径
                local rel_path="${real_item#$real_workspace/}"
                local rel_dir
                rel_dir=$(dirname "$rel_path")
                if [ "$rel_dir" != "." ]; then
                    mkdir -p "$WORKSPACE_DST/$rel_dir"
                fi
                cp "$item" "$WORKSPACE_DST/$rel_path"
                log_info "已添加文件: $item → workspace/$rel_path"
            else
                # 文件在外面，只复制文件名
                cp "$item" "$WORKSPACE_DST/"
                log_info "已添加文件: $item → workspace/$(basename "$item")"
            fi
            added=$((added + 1))
        fi
    done

    if [ $added -gt 0 ]; then
        git -C "$STATE_DIR" add -A
        git -C "$STATE_DIR" commit -m "add: 添加 ${added} 个文件" 2>/dev/null || true
        echo ""
        log_info "已添加 ${added} 个项目，运行 bash quick-init.sh push ${PROJECT_NAME} 推送"
    else
        log_warn "没有文件被添加"
    fi
}

# ========================================
# 子命令: push
# ========================================
cmd_push() {
    local PROJECT_NAME="${1:-}"
    local PAT="${2:-${OPENCLAW_RESUME_PAT:-}}"
    local GITHUB_USER="${3:-${OPENCLAW_RESUME_USER:-}}"

    if [ -z "$PROJECT_NAME" ]; then
        echo "用法: bash quick-init.sh push <项目名> [PAT] [GitHub用户名]"
        exit 1
    fi

    local STATE_DIR
    STATE_DIR=$(get_state_dir "$PROJECT_NAME")

    if [ ! -d "$STATE_DIR/.git" ]; then
        log_error "项目 ${PROJECT_NAME} 不存在，请先运行: bash quick-init.sh init ${PROJECT_NAME}"
        exit 1
    fi

    # 读取配置
    if [ -f "$STATE_DIR/.resume-config" ]; then
        source "$STATE_DIR/.resume-config"
        PAT="${2:-${PAT:-$PAT}}"
        GITHUB_USER="${3:-${GITHUB_USER:-$GITHUB_USER}}"
    fi

    # 同步最新工作文件
    if [ -n "${WORKSPACE_DIR:-}" ] && [ -d "$WORKSPACE_DIR" ]; then
        log_step "同步最新工作文件..."
        if command -v rsync &>/dev/null; then
            rsync -a --delete \
                --exclude='node_modules' --exclude='__pycache__' --exclude='.venv' \
                --exclude='.git' --exclude='*.pyc' --exclude='.openclaw-resume' \
                "$WORKSPACE_DIR/" "$STATE_DIR/workspace/" 2>/dev/null || true
        else
            cp -r "$WORKSPACE_DIR"/* "$STATE_DIR/workspace/" 2>/dev/null || true
        fi
    fi

    # 更新 last_saved
    local NOW
    NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
    sed -i "s/last_saved:.*/last_saved: \"${NOW}\"/" "$STATE_DIR/progress.yaml" 2>/dev/null || true

    # 检查是否有变化
    git -C "$STATE_DIR" add -A
    if git -C "$STATE_DIR" diff --cached --quiet; then
        log_info "没有新变化，无需推送"
        return 0
    fi

    # 统计变化
    local changes
    changes=$(git -C "$STATE_DIR" diff --cached --stat | tail -1)
    log_step "变化: $changes"

    # 提交
    git -C "$STATE_DIR" commit -m "save: $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true

    # 推送
    log_step "推送到 GitHub..."
    export GIT_TERMINAL_PROMPT=0

    if git -C "$STATE_DIR" push -u origin main 2>/dev/null; then
        echo ""
        echo "═══════════════════════════════════════════"
        log_info "🎉 推送成功！"
        echo ""
        echo "  🔗 GitHub: https://github.com/${GITHUB_USER:-user}/${PROJECT_NAME}-state"
        echo ""
        echo "  在 OpenClaw 试用环境恢复:"
        echo "    export OPENCLAW_RESUME_PAT=\"你的token\""
        echo "    export OPENCLAW_RESUME_USER=\"${GITHUB_USER:-user}\""
        echo "    source scripts/resume-restore.sh"
        echo "    resume-restore ${PROJECT_NAME}"
        echo "═══════════════════════════════════════════"
    else
        log_warn "推送失败，尝试增大缓冲..."
        git -C "$STATE_DIR" config http.postBuffer 524288000
        if timeout 60 git -C "$STATE_DIR" push -u origin main 2>/dev/null; then
            log_info "🎉 推送成功（重试后）"
        else
            log_error "推送失败！可稍后手动推送:"
            log_info "cd $STATE_DIR && git push -u origin main"
        fi
    fi
}

# ========================================
# 子命令: status
# ========================================
cmd_status() {
    local PROJECT_NAME="${1:-}"

    if [ -z "$PROJECT_NAME" ]; then
        # 列出所有项目
        echo "已初始化的项目:"
        if [ -d "$RESUME_BASE" ]; then
            for dir in "$RESUME_BASE"/*/; do
                [ -d "$dir/.git" ] && echo "  📁 $(basename "$dir")"
            done
        fi
        exit 0
    fi

    local STATE_DIR
    STATE_DIR=$(get_state_dir "$PROJECT_NAME")

    if [ ! -d "$STATE_DIR/.git" ]; then
        log_error "项目 ${PROJECT_NAME} 不存在"
        exit 1
    fi

    echo ""
    echo "📋 项目: ${PROJECT_NAME}"

    if [ -f "$STATE_DIR/.resume-config" ]; then
        source "$STATE_DIR/.resume-config"
        echo "📂 工作目录: ${WORKSPACE_DIR:-unknown}"
        echo "🔗 GitHub: https://github.com/${GITHUB_USER:-user}/${REPO_NAME:-${PROJECT_NAME}-state}"
    fi

    echo ""
    echo "最近操作:"
    grep '^\s*- "' "$STATE_DIR/progress.yaml" 2>/dev/null | tail -10

    echo ""
    echo "检查点:"
    ls "$STATE_DIR/checkpoints/" 2>/dev/null | head -10 || echo "  无"

    echo ""
    echo "文件数: $(find "$STATE_DIR/workspace" -type f 2>/dev/null | wc -l)"
    echo ""
}

# ========================================
# 主入口
# ========================================
CMD="${1:-}"
shift 2>/dev/null || true

echo ""

case "$CMD" in
    init)
        cmd_init "$@"
        ;;
    add)
        cmd_add "$@"
        ;;
    push)
        cmd_push "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    *)
        echo "╔═══════════════════════════════════════════╗"
        echo "║   openclaw-resume 一键初始化               ║"
        echo "╚═══════════════════════════════════════════╝"
        echo ""
        echo "用法: bash quick-init.sh <命令> [参数...]"
        echo ""
        echo "命令:"
        echo "  init <项目名> [工作目录] [PAT] [用户名]  初始化项目（不推送）"
        echo "  add <项目名> <文件/目录...>               添加额外文件"
        echo "  push <项目名> [PAT] [用户名]              推送到 GitHub"
        echo "  status [项目名]                           查看项目状态"
        echo ""
        echo "典型流程:"
        echo "  1. bash quick-init.sh init my-project ./code"
        echo "  2. bash quick-init.sh add my-project ./config.yaml ./docs/"
        echo "  3. bash quick-init.sh push my-project"
        echo ""
        echo "一步完成:"
        echo "  bash quick-init.sh init my-project ./code && bash quick-init.sh push my-project"
        ;;
esac

#!/bin/bash
set -euo pipefail

# ============================================================
# histb 补丁应用脚本（与内核版本无关）
#   补丁来源：https://github.com/histb-mainline/patches
#   清单规则：有 series 文件就按 series 顺序；没有就按文件名序号应用全部 *.patch
#   与内核树的匹配方式等同 quilt 的 --fuzz=0（git apply 默认要求上下文完全匹配）
#
# 用法：
#   cd <内核源码根目录>
#   bash /path/to/apply_histb_patches.sh [-y|--yes]
#
# 可用环境变量：
#   PATCHES_DIR        补丁目录，默认 ../histb-hi3798-patches
#   LOG_FILE           日志文件，默认 /tmp/histb_patch_apply.log
#   SKIP_ON_CONFLICT   1 = 跳过冲突补丁继续（默认 0，遇冲突即中止）
# ============================================================

PATCHES_DIR="${PATCHES_DIR:-../histb-hi3798-patches}"
LOG_FILE="${LOG_FILE:-/tmp/histb_patch_apply.log}"
SKIP_ON_CONFLICT="${SKIP_ON_CONFLICT:-0}"

# 非交互判定：CI=true 或 -y/--yes，避免无终端时 read 失败
AUTO_YES=0
if [[ "${CI:-}" == "true" ]]; then
    AUTO_YES=1
fi
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"  | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"   | tee -a "$LOG_FILE"; }

cleanup_on_failure() {
    log_error "补丁应用出错，正在回滚…"
    git am --abort 2>/dev/null || true
    git reset --hard HEAD >/dev/null 2>&1 || true
    log_error "已回滚，内核源码恢复干净状态"
    exit 1
}
trap cleanup_on_failure ERR INT TERM

ask_continue() {
    local prompt="$1"
    if [[ $AUTO_YES -eq 1 ]]; then
        log_warn "$prompt（非交互模式，自动继续）"
        return 0
    fi
    read -p "$prompt (y/N) " -n 1 -r || true
    echo ""
    if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
}

# 邮件格式补丁用 git am；quilt 纯 diff 补丁用 git apply + commit
apply_patch() {
    local p="$1" name
    name="$(basename "$p")"
    if head -n1 "$p" | grep -q '^From '; then
        if git am "$p" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        git am --abort 2>/dev/null || true
        return 1
    fi
    if ! git apply --index --whitespace=nowarn "$p" >>"$LOG_FILE" 2>&1; then
        return 1
    fi
    if ! git commit -q -m "apply: $name" >>"$LOG_FILE" 2>&1; then
        return 1
    fi
    return 0
}

: > "$LOG_FILE"
log_info "====== 开始 histb 补丁应用流程 ======"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "当前目录不是 Git 仓库，请在内核源码根目录运行本脚本"
    exit 1
fi

git config user.email >/dev/null 2>&1 || git config user.email "ci-builder@localhost"
git config user.name  >/dev/null 2>&1 || git config user.name  "CI Builder"

if [[ ! -d "$PATCHES_DIR" ]]; then
    log_error "补丁目录不存在：$PATCHES_DIR"
    exit 1
fi
PATCHES_DIR="$(cd "$PATCHES_DIR" && pwd)"
log_info "补丁目录：$PATCHES_DIR"

if [[ -f "$PATCHES_DIR/baseline" ]]; then
    log_info "补丁仓库 baseline："
    sed 's/^/    /' "$PATCHES_DIR/baseline" | tee -a "$LOG_FILE"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    log_warn "检测到 Git 工作区有未提交修改，继续可能导致冲突："
    git status --short | head -20 | tee -a "$LOG_FILE"
    ask_continue "是否继续？"
fi

log_info "当前内核版本：$(git describe --tags --always 2>/dev/null || echo unknown)"

PATCH_FILES=()
if [[ -f "$PATCHES_DIR/series" ]]; then
    log_info "检测到 series 文件，按 series 顺序组装清单"
    while IFS= read -r line; do
        line="${line%%#*}"
        read -r name _rest <<< "$line"
        if [[ -z "${name:-}" ]]; then
            continue
        fi
        if [[ "${name:0:1}" == "-" ]]; then
            continue
        fi
        PATCH_FILES+=( "$PATCHES_DIR/$name" )
    done < "$PATCHES_DIR/series"
else
    log_info "未找到 series 文件，按文件名序号应用根目录下全部补丁"
    mapfile -t PATCH_FILES < <(find "$PATCHES_DIR" -maxdepth 1 -name '*.patch' -type f | LC_ALL=C sort -V)
fi

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
    log_error "补丁清单为空，请检查 $PATCHES_DIR"
    exit 1
fi

for p in "${PATCH_FILES[@]}"; do
    if [[ ! -f "$p" ]]; then
        log_error "清单中的补丁不存在：$p"
        exit 1
    fi
done
log_info "共 ${#PATCH_FILES[@]} 个补丁待应用"

OK=0
SKIPPED=0
for p in "${PATCH_FILES[@]}"; do
    name="$(basename "$p")"
    if apply_patch "$p"; then
        OK=$((OK + 1))
        log_info "  [OK] $name"
    else
        log_error "  [FAIL] $name"
        if [[ "$SKIP_ON_CONFLICT" == "1" ]]; then
            git reset --hard HEAD >/dev/null 2>&1 || true
            SKIPPED=$((SKIPPED + 1))
            log_warn "  已跳过该补丁（SKIP_ON_CONFLICT=1）"
        else
            log_error "补丁与当前内核树上下文不匹配，已中止"
            log_error "详细错误见 $LOG_FILE 末尾；确认无误可设 SKIP_ON_CONFLICT=1 跳过冲突补丁"
            exit 1
        fi
    fi
done

log_info "====== 补丁应用完成 ======"
log_info "成功应用：$OK 个"
if [[ $SKIPPED -gt 0 ]]; then
    log_warn "跳过冲突：$SKIPPED 个"
fi
if [[ $OK -eq 0 ]]; then
    log_error "没有任何补丁被成功应用"
    exit 1
fi

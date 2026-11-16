#!/bin/bash
set -euo pipefail

# ==============================================
# Hi3798MV100 Linux v7.4 内核补丁一键应用脚本
# 适配 histb-mainline/patches 最新仓库结构（补丁全在根目录）
# 用法：cd <内核源码根目录> && bash /path/to/apply_hi3798mv100_v7.4_patches.sh [-y|--yes]
# ==============================================

# 配置项（可通过环境变量覆盖）
PATCHES_DIR="${PATCHES_DIR:-../histb-hi3798-patches}"
KERNEL_VERSION_REQUIRED="${KERNEL_VERSION_REQUIRED:-v7.4}"
CHIP_TARGET="${CHIP_TARGET:-hi3798mv100}"
LOG_FILE="${LOG_FILE:-/tmp/hi3798mv100_patch_apply.log}"

# 非交互模式自动确认（CI环境默认开启）
AUTO_YES=0
if [[ "${CI:-}" == "true" ]]; then
    AUTO_YES=1
fi
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
    esac
done

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"  | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"   | tee -a "$LOG_FILE"; }

# 出错自动回滚
cleanup_on_failure() {
    log_error "补丁应用出错，正在回滚..."
    git am --abort 2>/dev/null || true
    log_info "已回滚所有未完成补丁，内核已恢复干净状态"
    exit 1
}
trap cleanup_on_failure ERR INT TERM

# 交互确认封装
ask_continue() {
    local prompt="$1"
    if [[ $AUTO_YES -eq 1 ]]; then
        log_warn "$prompt 非交互模式自动继续"
        return 0
    fi
    read -p "$prompt (y/N) " -n 1 -r || true
    echo ""
    if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
}

# ==============================================
# 第一步：环境检查
# ==============================================
log_info "====== 开始Hi3798MV100 v7.4补丁应用流程 ======"
echo "" > "$LOG_FILE"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "当前目录不是Git仓库，请在内核源码根目录运行脚本"
    exit 1
fi

# 兜底配置git提交身份（CI环境默认无身份）
git config user.email >/dev/null 2>&1 || git config user.email "ci-builder@localhost"
git config user.name  >/dev/null 2>&1 || git config user.name  "CI Builder"

# 检查工作区干净度
if [[ -n $(git status --porcelain) ]]; then
    log_warn "检测到Git工作区有未提交修改，继续可能导致冲突"
    log_info "当前工作区文件状态："
    git status --short | head -20 | tee -a "$LOG_FILE"
    ask_continue "是否继续？"
fi

# 检查内核版本
current_kernel_tag=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
log_info "当前内核版本标签: $current_kernel_tag"
if [[ "$current_kernel_tag" != *"$KERNEL_VERSION_REQUIRED"* && "$current_kernel_tag" != "unknown" ]]; then
    log_warn "当前内核版本似乎不是$KERNEL_VERSION_REQUIRED，补丁可能出现冲突"
    ask_continue "确认仍要继续？"
fi

# 检查补丁目录
if [[ ! -d "$PATCHES_DIR" ]]; then
    log_error "补丁目录不存在: $PATCHES_DIR，请检查路径"
    exit 1
fi

# ==============================================
# 第二步：筛选补丁（适配新目录结构）
# ==============================================
log_info "正在筛选适用于$CHIP_TARGET $KERNEL_VERSION_REQUIRED的补丁..."

# 筛选规则：
# 1. 匹配v7.4版本前缀的补丁
# 2. 包含hi3798mv100专属补丁 + 0xx开头的公共基础依赖补丁
# 3. 排除其他芯片专属补丁（hi3716、mv200、cv200等）
# 4. 按数字序号自然排序保证依赖顺序
mapfile -t PATCH_FILES < <(
    find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -type f |
    grep -i -E "v7\.4|^[0-9]{3}-0[0-9]{2}-" |
    grep -vi -E "(hi3716|hi3798mv200|mv200h|hi3798cv200|mv100_)" |
    grep -i -E "hi3798mv100|histb|hisi|hisilicon|^[0-9]{3}-0[0-9]{2}-" |
    sort -V
)

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
    log_error "未找到符合条件的补丁文件"
    log_info "补丁目录下所有patch文件："
    ls -1 "$PATCHES_DIR"/*.patch | head -50 | tee -a "$LOG_FILE"
    exit 1
fi

log_info "共筛选出${#PATCH_FILES[@]}个待应用补丁，清单如下："
for patch in "${PATCH_FILES[@]}"; do
    log_info "  - $(basename "$patch")"
done

# ==============================================
# 第三步：补丁冲突预检查
# ==============================================
log_info "正在执行补丁冲突预检查..."
CONFLICT_FOUND=0
for patch in "${PATCH_FILES[@]}"; do
    patch_name=$(basename "$patch")
    if ! git apply --check "$patch" >/dev/null 2>&1; then
        log_error "补丁 $patch_name 存在冲突，无法应用"
        CONFLICT_FOUND=1
    fi
done

if [[ $CONFLICT_FOUND -eq 1 ]]; then
    log_error "预检查发现补丁冲突，请核对内核版本是否为$KERNEL_VERSION_REQUIRED"
    exit 1
fi
log_info "补丁预检查通过，所有补丁上下文匹配正常"

# ==============================================
# 第四步：批量应用补丁
# ==============================================
log_info "开始按顺序批量应用补丁..."
SUCCESS_COUNT=0
FAILED_COUNT=0

for patch in "${PATCH_FILES[@]}"; do
    patch_name=$(basename "$patch")
    log_info "正在应用: $patch_name"
    if git am "$patch" >> "$LOG_FILE" 2>&1; then
        log_info "  ✓ 应用成功"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "  ✗ 应用失败: $patch_name"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        git am --abort 2>/dev/null || true
        break
    fi
done

# ==============================================
# 第五步：结果统计
# ==============================================
log_info "====== 补丁应用完成 ======"
log_info "成功应用: $SUCCESS_COUNT 个补丁"
if [[ $FAILED_COUNT -gt 0 ]]; then
    log_error "应用失败: $FAILED_COUNT 个补丁"
    log_error "详细错误日志: $LOG_FILE"
    exit 1
else
    log_info "所有补丁全部应用成功！"
    log_info "接下来可以执行内核配置与编译命令"
fi

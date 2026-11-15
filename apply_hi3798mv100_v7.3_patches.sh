#!/bin/bash
set -euo pipefail

# ==============================================
# Hi3798MV100 Linux v7.3 内核补丁一键应用脚本
# 使用方法:
#   1. 将脚本放到你的内核源码根目录下
#   2. 执行 chmod +x apply_hi3798mv100_v7.3_patches.sh
#   3. 修改下面 PATCHES_DIR 为你的补丁目录绝对路径
#   4. 运行 ./apply_hi3798mv100_v7.3_patches.sh
# ==============================================

# -------------------------- 配置项（按需修改） --------------------------
PATCHES_DIR="../histb-hi3798-patches"  # 补丁仓库目录，可改为绝对路径
KERNEL_VERSION_REQUIRED="v7.3"         # 要求的内核基准版本
CHIP_TARGET="hi3798mv100"              # 目标芯片型号
LOG_FILE="./hi3798mv100_patch_apply.log"
# ------------------------------------------------------------------------

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

cleanup_on_failure() {
    log_error "补丁应用过程中出错，正在执行回滚..."
    git am --abort 2>/dev/null || true
    log_info "已回滚所有未完成的补丁操作，内核源码已恢复到干净状态"
    exit 1
}

trap cleanup_on_failure ERR INT TERM

# ==============================================
# 第一步：环境检查
# ==============================================
log_info "====== 开始Hi3798MV100 v7.3补丁应用流程 ======"
echo "" > "$LOG_FILE"

# 检查是否在git仓库中
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "当前目录不是Git仓库，请将脚本放到Linux内核源码根目录下运行"
    exit 1
fi

# 检查工作区是否干净
if [[ -n $(git status --porcelain) ]]; then
    log_warn "检测到当前Git工作区有未提交的修改，继续操作可能会导致冲突"
    read -p "是否继续？(y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
fi

# 检查当前内核版本
current_kernel_tag=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
log_info "当前内核版本标签: $current_kernel_tag"

if [[ "$current_kernel_tag" != *"$KERNEL_VERSION_REQUIRED"* ]]; then
    log_warn "当前内核版本似乎不是 $KERNEL_VERSION_REQUIRED，补丁可能会出现大量冲突"
    log_warn "建议先执行: git checkout $KERNEL_VERSION_REQUIRED"
    read -p "确认仍要继续应用补丁？(y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
fi

# 检查补丁目录是否存在
if [[ ! -d "$PATCHES_DIR" ]]; then
    log_error "补丁目录不存在: $PATCHES_DIR，请检查路径配置"
    exit 1
fi

# 检查git am是否可用
if ! command -v git &>/dev/null; then
    log_error "未检测到git命令，请先安装Git"
    exit 1
fi

# ==============================================
# 第二步：筛选正确的补丁文件
# ==============================================
log_info "正在筛选适用于 $CHIP_TARGET $KERNEL_VERSION_REQUIRED 的补丁..."

# 筛选规则：
# 1. 匹配文件名带 v7.3 版本标识
# 2. 优先包含hi3798mv100专属补丁，同时包含公共依赖补丁
# 3. 排除hi3716cv200、hi3798mv200h等其他芯片的专属补丁
# 4. 按数字序号排序，保证依赖顺序正确
mapfile -t PATCH_FILES < <(
    find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -type f |
    grep -i "v7.3" |
    grep -vi -E "(hi3716|hi3798mv200h|mv200h)" |
    sort -V
)

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
    log_error "未找到任何符合条件的补丁文件，请检查补丁目录路径和版本"
    exit 1
fi

log_info "共筛选出 ${#PATCH_FILES[@]} 个待应用补丁，清单如下："
for patch in "${PATCH_FILES[@]}"; do
    log_info "  - $(basename "$patch")"
done
echo ""

# ==============================================
# 第三步：预检查补丁冲突
# ==============================================
log_info "正在执行补丁冲突预检查..."
CONFLICT_FOUND=0
for patch in "${PATCH_FILES[@]}"; do
    patch_name=$(basename "$patch")
    if ! git am --check "$patch" >/dev/null 2>&1; then
        log_error "补丁 $patch_name 存在冲突，无法顺利应用"
        CONFLICT_FOUND=1
    fi
done

if [[ $CONFLICT_FOUND -eq 1 ]]; then
    log_error "预检查发现补丁冲突，请先核对内核版本是否严格匹配v7.3"
    log_error "如果你确定要强行应用，请手动使用 patch -p1 命令逐个处理"
    exit 1
fi
log_info "补丁预检查通过，所有补丁上下文匹配正常"
echo ""

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
        git am --abort 2>/dev/null
        break
    fi
done

# ==============================================
# 第五步：结果统计
# ==============================================
echo ""
log_info "====== 补丁应用完成 ======"
log_info "成功应用: $SUCCESS_COUNT 个补丁"
if [[ $FAILED_COUNT -gt 0 ]]; then
    log_error "应用失败: $FAILED_COUNT 个补丁"
    log_error "详细错误日志已保存到: $LOG_FILE"
    exit 1
else
    log_green "所有补丁全部应用成功！"
    log_info "接下来你可以执行 make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig 开始配置内核"
fi

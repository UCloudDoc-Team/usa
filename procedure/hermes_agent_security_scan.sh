#!/bin/bash

# Hermes-Agent 安全扫描脚本
# 基于《云上 Hermes-Agent 安全加固指南》编写
# 扫描完成后给出具体的安全加固建议

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 检查当前用户是否为root
check_root_user() {
    if [ "$(id -u)" -eq 0 ]; then
        log_warn "检测到 Hermes-Agent 可能以 root 用户运行，存在高风险！"
        echo "  建议：创建专用 hermes 用户并降权运行"
        echo "  参考命令："
        echo "    sudo useradd -m -s /bin/bash hermes"
        echo "    sudo passwd hermes"
        echo "    sudo chown -R hermes:hermes /home/hermes/.hermes"
    else
        log_success "当前非 root 用户运行，符合安全要求"
    fi
}

# 检查 Hermes 配置文件
check_hermes_config() {
    local config_path="$HOME/.hermes/config.yaml"

    if [ ! -f "$config_path" ]; then
        log_warn "未找到 Hermes 配置文件: $config_path"
        echo "  建议：确保配置文件存在并正确配置安全选项"
        return
    fi

    log_info "检查 Hermes 配置文件: $config_path"

    # 检查审批模式
    if grep -q "mode:.*off" "$config_path"; then
        log_error "发现危险配置：审批模式已关闭 (mode: off)"
        echo "  建议：设置审批模式为 manual 或 smart"
        echo "  配置示例："
        echo "    approvals:"
        echo "      mode: manual"
        echo "      timeout: 60"
    elif grep -q "mode:.*manual" "$config_path"; then
        log_success "审批模式设置为 manual（手动审批），安全性高"
    elif grep -q "mode:.*smart" "$config_path"; then
        log_info "审批模式设置为 smart（智能审批），安全性中等"
    else
        log_warn "未明确设置审批模式，可能使用默认值"
        echo "  建议：显式设置审批模式为 manual 或 smart"
    fi
}

# 检查敏感文件权限
check_sensitive_files_permissions() {
    local sensitive_files=(
        "$HOME/.hermes/.env"
        "$HOME/.hermes/config.yaml"
        "$HOME/.ssh/authorized_keys"
        "$HOME/.ssh/id_rsa"
    )

    for file in "${sensitive_files[@]}"; do
        if [ -f "$file" ]; then
            local perm=$(stat -c "%a" "$file")
            if [ "$perm" != "600" ]; then
                log_warn "敏感文件权限不安全: $file (当前权限: $perm)"
                echo "  建议：设置权限为 600"
                echo "  命令：chmod 600 $file"
            else
                log_success "敏感文件权限正确: $file"
            fi
        fi
    done

    # 检查目录权限
    local sensitive_dirs=(
        "$HOME/.hermes"
        "$HOME/.ssh"
    )

    for dir in "${sensitive_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local perm=$(stat -c "%a" "$dir")
            if [ "$perm" != "700" ]; then
                log_warn "敏感目录权限不安全: $dir (当前权限: $perm)"
                echo "  建议：设置权限为 700"
                echo "  命令：chmod 700 $dir"
            else
                log_success "敏感目录权限正确: $dir"
            fi
        fi
    done
}

# 检查 LiteLLM 依赖版本
check_litellm_version() {
    if command -v pip &>/dev/null; then
        if pip list | grep -q "litellm"; then
            local version=$(pip show litellm | grep "Version:" | cut -d' ' -f2)
            if [ -n "$version" ]; then
                # 比较版本号，检查是否低于 1.83.0
                if printf '%s\n%s\n' "1.83.0" "$version" | sort -V -C; then
                    # version >= 1.83.0
                    log_success "LiteLLM 版本安全: $version"
                else
                    log_error "LiteLLM 版本过低: $version (应 >= 1.83.0)"
                    echo "  风险：存在 CVE-2026-35030、CVE-2026-35029 等高危漏洞"
                    echo "  建议：升级 Hermes-Agent 到最新版本（不依赖 LiteLLM）"
                    echo "  或升级 LiteLLM：pip install 'litellm>=1.83.0'"
                fi
            else
                log_warn "无法确定 LiteLLM 版本"
            fi
        else
            log_success "未检测到 LiteLLM 依赖，符合安全要求"
        fi
    else
        log_warn "无法检查 LiteLLM 版本（pip 不可用）"
    fi
}

# 检查 API 密钥泄露
check_api_key_leaks() {
    local hermes_dir="$HOME/.hermes"
    if [ ! -d "$hermes_dir" ]; then
        log_warn "未找到 Hermes 目录: $hermes_dir"
        return
    fi

    # 检查 Git 历史中的密钥
    if [ -d "$hermes_dir/.git" ]; then
        if git -C "$hermes_dir" log -p 2>/dev/null | grep -qE "(sk-|xoxb-|sk-ant-)"; then
            log_error "检测到 Git 历史中可能存在 API 密钥泄露！"
            echo "  建议：清理 Git 历史或重新初始化仓库"
        else
            log_success "Git 历史中未发现明显的 API 密钥泄露"
        fi
    fi

    # 检查日志文件中的密钥
    local logs_dir="$hermes_dir/logs"
    if [ -d "$logs_dir" ]; then
        # 先检查是否存在匹配（更精确的API密钥模式）
        if grep -rE "(sk-[a-zA-Z0-9]{48}|xoxb-[a-zA-Z0-9-]{30,}|sk-ant-[a-zA-Z0-9]{40,}|apikey\s*\[?[a-zA-Z0-9-]{20,})" "$logs_dir" >/dev/null 2>&1; then
            log_error "检测到日志文件中可能存在 API 密钥泄露！"
            # 显示具体的泄漏文件和行号
            echo "  泄漏位置："
            grep -rnE "(sk-[a-zA-Z0-9]{48}|xoxb-[a-zA-Z0-9-]{30,}|sk-ant-[a-zA-Z0-9]{40,}|apikey\s*\[?[a-zA-Z0-9-]{20,})" "$logs_dir" 2>/dev/null | while read -r line; do
                echo "    $line"
            done
            echo "  建议：立即清理上述日志文件并检查密钥是否需要轮换"
        else
            log_success "日志文件中未发现明显的 API 密钥泄露"
        fi
    fi
}

# 检查 Cron 权限控制
check_cron_permissions() {
    local current_user=$(whoami)

    # 检查 cron.allow 和 cron.deny
    if [ -f /etc/cron.allow ]; then
        if grep -q "^$current_user$" /etc/cron.allow; then
            log_success "当前用户在 cron.allow 中，Cron 权限控制正确"
        else
            log_warn "当前用户不在 cron.allow 中，可能存在 Cron 权限问题"
            echo "  建议：将用户添加到 cron.allow"
            echo "  命令：echo \"$current_user\" | sudo tee -a /etc/cron.allow"
        fi
    elif [ -f /etc/cron.deny ]; then
        if ! grep -q "^ALL$" /etc/cron.deny; then
            log_warn "cron.deny 文件存在但未设置为 ALL，Cron 权限控制不足"
            echo "  建议：设置 cron.deny 为 ALL 并使用 cron.allow 精确控制"
            echo "  命令：echo \"ALL\" | sudo tee /etc/cron.deny"
        else
            log_success "cron.deny 设置为 ALL，Cron 权限控制正确"
        fi
    else
        log_warn "未配置 cron.allow 或 cron.deny，所有用户均可使用 Cron"
        echo "  建议：配置 cron.allow 仅允许必要用户"
        echo "  命令："
        echo "    echo \"$current_user\" | sudo tee /etc/cron.allow"
        echo "    echo \"ALL\" | sudo tee /etc/cron.deny"
    fi
}

# 检查虚拟环境
check_virtual_environment() {
    local venv_path="$HOME/.venv/hermes"
    if [ -d "$venv_path" ]; then
        if [ -f "$venv_path/bin/activate" ]; then
            log_success "检测到虚拟环境: $venv_path"
        else
            log_warn "虚拟环境目录存在但不完整: $venv_path"
        fi
    else
        log_warn "未检测到虚拟环境"
        echo "  建议：创建虚拟环境隔离依赖"
        echo "  命令："
        echo "    python3 -m venv ~/.venv/hermes"
        echo "    source ~/.venv/hermes/bin/activate"
    fi
}

# 检查依赖版本锁定
check_dependency_locking() {
    local requirements_file="$HOME/.hermes/requirements-lock.txt"
    if [ -f "$requirements_file" ]; then
        log_success "检测到依赖锁定文件: $requirements_file"
    else
        log_warn "未检测到依赖锁定文件"
        echo "  建议：生成依赖锁定文件以确保版本一致性"
        echo "  命令：pip freeze > ~/.hermes/requirements-lock.txt"
    fi
}

# 全局变量用于存储检查结果
check_results=()

# 添加检查结果到全局数组
add_check_result() {
    local check_name="$1"
    local status="$2"  # PASS, WARN, FAIL
    local message="$3"
    check_results+=("$check_name|$status|$message")
}

# 打印最终总结
print_final_summary() {
    echo "=============================================="
    echo "            安全扫描最终总结"
    echo "=============================================="
    echo

    for result in "${check_results[@]}"; do
        IFS='|' read -r name status message <<< "$result"
        case "$status" in
            "PASS")
                echo -e "${GREEN}[✓]${NC} $name: $message"
                ;;
            "WARN")
                echo -e "${YELLOW}[⚠]${NC} $name: $message"
                ;;
            "FAIL")
                echo -e "${RED}[✗]${NC} $name: $message"
                ;;
        esac
    done

    echo
    echo "=============================================="
    echo "扫描完成！"
    echo "请根据上述检查结果和建议进行相应的安全加固"
    echo "详细加固指南请参考：/tmp/hermes/hermes-agent安全加固指南v2.md"
    echo "=============================================="
}

# 修改检查函数以记录结果

# 检查当前用户是否为root
check_root_user() {
    if [ "$(id -u)" -eq 0 ]; then
        log_warn "检测到 Hermes-Agent 可能以 root 用户运行，存在高风险！"
        echo "  建议：创建专用 hermes 用户并降权运行"
        echo "  参考命令："
        echo "    sudo useradd -m -s /bin/bash hermes"
        echo "    sudo passwd hermes"
        echo "    sudo chown -R hermes:hermes /home/hermes/.hermes"
        add_check_result "系统权限加固" "FAIL" "以 root 用户运行，存在高风险"
    else
        log_success "当前非 root 用户运行，符合安全要求"
        add_check_result "系统权限加固" "PASS" "非 root 用户运行，符合安全要求"
    fi
}

# 检查 Hermes 配置文件
check_hermes_config() {
    local config_path="$HOME/.hermes/config.yaml"

    if [ ! -f "$config_path" ]; then
        log_warn "未找到 Hermes 配置文件: $config_path"
        echo "  建议：确保配置文件存在并正确配置安全选项"
        add_check_result "Hermes 配置文件" "WARN" "未找到配置文件"
        return
    fi

    log_info "检查 Hermes 配置文件: $config_path"

    # 检查审批模式
    if grep -q "mode:.*off" "$config_path"; then
        log_error "发现危险配置：审批模式已关闭 (mode: off)"
        echo "  建议：设置审批模式为 manual 或 smart"
        echo "  配置示例："
        echo "    approvals:"
        echo "      mode: manual"
        echo "      timeout: 60"
        add_check_result "Hermes 配置文件" "FAIL" "审批模式已关闭，存在高风险"
    elif grep -q "mode:.*manual" "$config_path"; then
        log_success "审批模式设置为 manual（手动审批），安全性高"
        add_check_result "Hermes 配置文件" "PASS" "审批模式为 manual，安全性高"
    elif grep -q "mode:.*smart" "$config_path"; then
        log_info "审批模式设置为 smart（智能审批），安全性中等"
        add_check_result "Hermes 配置文件" "PASS" "审批模式为 smart，安全性中等"
    else
        log_warn "未明确设置审批模式，可能使用默认值"
        echo "  建议：显式设置审批模式为 manual 或 smart"
        add_check_result "Hermes 配置文件" "WARN" "未明确设置审批模式"
    fi
}

# 检查敏感文件权限
check_sensitive_files_permissions() {
    local sensitive_files=(
        "$HOME/.hermes/.env"
        "$HOME/.hermes/config.yaml"
        "$HOME/.ssh/authorized_keys"
        "$HOME/.ssh/id_rsa"
    )

    local has_issues=false
    for file in "${sensitive_files[@]}"; do
        if [ -f "$file" ]; then
            local perm=$(stat -c "%a" "$file")
            if [ "$perm" != "600" ]; then
                log_warn "敏感文件权限不安全: $file (当前权限: $perm)"
                echo "  建议：设置权限为 600"
                echo "  命令：chmod 600 $file"
                has_issues=true
            fi
        fi
    done

    # 检查目录权限
    local sensitive_dirs=(
        "$HOME/.hermes"
        "$HOME/.ssh"
    )

    for dir in "${sensitive_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local perm=$(stat -c "%a" "$dir")
            if [ "$perm" != "700" ]; then
                log_warn "敏感目录权限不安全: $dir (当前权限: $perm)"
                echo "  建议：设置权限为 700"
                echo "  命令：chmod 700 $dir"
                has_issues=true
            fi
        fi
    done

    if [ "$has_issues" = true ]; then
        add_check_result "敏感文件和目录权限" "WARN" "部分文件或目录权限不安全"
    else
        log_success "所有敏感文件和目录权限均正确"
        add_check_result "敏感文件和目录权限" "PASS" "所有权限设置正确"
    fi
}

# 检查版本格式（时间格式还是数字格式）
is_date_version() {
    local version="$1"
    # 检查是否匹配 YYYY.M.D 格式（如 2026.4.8）
    if [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
        return 0  # 是时间格式
    else
        return 1  # 不是时间格式（假设是数字格式如 0.5.0）
    fi
}

# 比较时间格式版本
compare_date_versions() {
    local version1="$1"
    local version2="$2"

    # 将 YYYY.M.D 转换为 YYYYMMDD 格式进行比较
    local v1_year=$(echo "$version1" | cut -d'.' -f1)
    local v1_month=$(printf "%02d" $(echo "$version1" | cut -d'.' -f2))
    local v1_day=$(printf "%02d" $(echo "$version1" | cut -d'.' -f3))
    local v1_num="${v1_year}${v1_month}${v1_day}"

    local v2_year=$(echo "$version2" | cut -d'.' -f1)
    local v2_month=$(printf "%02d" $(echo "$version2" | cut -d'.' -f2))
    local v2_day=$(printf "%02d" $(echo "$version2" | cut -d'.' -f3))
    local v2_num="${v2_year}${v2_month}${v2_day}"

    if [ "$v1_num" -ge "$v2_num" ]; then
        return 0  # version1 >= version2
    else
        return 1  # version1 < version2
    fi
}

# 检查 Hermes-Agent 版本和 LiteLLM 依赖
check_hermes_and_litellm() {
    # 首先尝试获取 Hermes-Agent 版本
    local hermes_version=""
    if command -v hermes &>/dev/null; then
        hermes_version=$(hermes --version 2>/dev/null | head -n1 | awk '{print $NF}' | tr -d 'v')
    elif [ -f "$HOME/.hermes/version" ]; then
        hermes_version=$(cat "$HOME/.hermes/version" 2>/dev/null | tr -d 'v')
    fi

    if [ -n "$hermes_version" ]; then
        local is_safe=false
        local safe_baseline=""

        # 判断版本格式并设置相应的基准版本
        if is_date_version "$hermes_version"; then
            # 时间格式版本，基准为 2026.3.28
            safe_baseline="2026.3.28"
            if compare_date_versions "$hermes_version" "$safe_baseline"; then
                is_safe=true
            fi
        else
            # 数字格式版本，基准为 0.5.0
            safe_baseline="0.5.0"
            if printf '%s\n%s\n' "$safe_baseline" "$hermes_version" | sort -V -C; then
                is_safe=true
            fi
        fi

        if [ "$is_safe" = true ]; then
            # 版本安全，不依赖 LiteLLM
            log_success "Hermes-Agent 版本安全: v$hermes_version (不依赖 LiteLLM)"
            echo "  说明：v0.5.0 及以上版本已移除 LiteLLM 依赖，使用自研 LLM 客户端"
            echo "  新增说明：如果是时间命名的版本则与 v2026.3.28 对比，如果是数字命名的版本则与 v0.5.0 对比"
            add_check_result "Hermes-Agent 版本安全" "PASS" "v$hermes_version 不依赖 LiteLLM，符合安全要求"
        else
            # 版本较低，需要检查 LiteLLM 依赖
            log_warn "Hermes-Agent 版本较低: v$hermes_version (可能依赖 LiteLLM)"
            echo "  基准版本：$safe_baseline"

            # 检查 LiteLLM 依赖
            if command -v pip &>/dev/null; then
                if pip list | grep -q "litellm"; then
                    local litellm_version=$(pip show litellm | grep "Version:" | cut -d' ' -f2)
                    if [ -n "$litellm_version" ]; then
                        # 比较 LiteLLM 版本号，检查是否低于 1.83.0
                        if printf '%s\n%s\n' "1.83.0" "$litellm_version" | sort -V -C; then
                            # litellm_version >= 1.83.0
                            log_success "LiteLLM 版本安全: $litellm_version"
                            echo "  建议：升级 Hermes-Agent 到最新版本以移除 LiteLLM 依赖"
                            add_check_result "Hermes-Agent 版本安全" "WARN" "v$hermes_version 依赖 LiteLLM $litellm_version，建议升级"
                        else
                            log_error "LiteLLM 版本过低: $litellm_version (应 >= 1.83.0)"
                            echo "  风险：存在 CVE-2026-35030、CVE-2026-35029 等高危漏洞"
                            echo "  建议：立即升级 Hermes-Agent 到最新版本（不依赖 LiteLLM）"
                            add_check_result "Hermes-Agent 版本安全" "FAIL" "v$hermes_version 依赖不安全的 LiteLLM $litellm_version"
                        fi
                    else
                        log_warn "无法确定 LiteLLM 版本"
                        echo "  建议：升级 Hermes-Agent 到最新版本以移除 LiteLLM 依赖"
                        add_check_result "Hermes-Agent 版本安全" "WARN" "v$hermes_version 依赖 LiteLLM，版本未知"
                    fi
                else
                    log_info "未检测到 LiteLLM 依赖"
                    echo "  建议：升级 Hermes-Agent 到最新版本以获得更好的安全性和功能"
                    add_check_result "Hermes-Agent 版本安全" "WARN" "v$hermes_version 较旧，建议升级到最新版本"
                fi
            else
                log_warn "无法检查 LiteLLM 版本（pip 不可用）"
                echo "  建议：升级 Hermes-Agent 到最新版本以移除 LiteLLM 依赖并简化环境"
                add_check_result "Hermes-Agent 版本安全" "WARN" "v$hermes_version 较旧且无法验证 LiteLLM，建议升级"
            fi
        fi
    else
        # 无法获取 Hermes-Agent 版本
        log_warn "无法确定 Hermes-Agent 版本"

        # 尝试检查是否使用 LiteLLM
        if command -v pip &>/dev/null && pip list | grep -q "litellm"; then
            local litellm_version=$(pip show litellm | grep "Version:" | cut -d' ' -f2)
            if [ -n "$litellm_version" ]; then
                if printf '%s\n%s\n' "1.83.0" "$litellm_version" | sort -V -C; then
                    log_success "检测到 LiteLLM 版本安全: $litellm_version"
                    echo "  建议：升级到 Hermes-Agent 最新版本以移除 LiteLLM 依赖"
                    add_check_result "Hermes-Agent 版本安全" "WARN" "使用 LiteLLM $litellm_version，建议升级到最新版本"
                else
                    log_error "检测到不安全的 LiteLLM 版本: $litellm_version"
                    echo "  风险：存在 CVE-2026-35030、CVE-2026-35029 等高危漏洞"
                    echo "  建议：立即升级 Hermes-Agent 到最新版本（不依赖 LiteLLM）"
                    add_check_result "Hermes-Agent 版本安全" "FAIL" "使用不安全的 LiteLLM $litellm_version"
                fi
            else
                log_warn "检测到 LiteLLM 但无法确定版本"
                echo "  建议：升级 Hermes-Agent 到最新版本以移除 LiteLLM 依赖"
                add_check_result "Hermes-Agent 版本安全" "WARN" "使用 LiteLLM 版本未知，建议升级到最新版本"
            fi
        else
            log_info "未检测到 LiteLLM 依赖"
            echo "  建议：确认 Hermes-Agent 版本并升级到最新版本以获得最佳安全性"
            add_check_result "Hermes-Agent 版本安全" "WARN" "版本未知，建议确认并升级到最新版本"
        fi
    fi
}

# 检查 API 密钥泄露
check_api_key_leaks() {
    local hermes_dir="$HOME/.hermes"
    if [ ! -d "$hermes_dir" ]; then
        log_warn "未找到 Hermes 目录: $hermes_dir"
        add_check_result "API 密钥泄露检查" "WARN" "未找到 Hermes 目录"
        return
    fi

    local has_leaks=false

    # 检查 Git 历史中的密钥
    if [ -d "$hermes_dir/.git" ]; then
        if git -C "$hermes_dir" log -p 2>/dev/null | grep -qE "(sk-|xoxb-|sk-ant-)"; then
            log_error "检测到 Git 历史中可能存在 API 密钥泄露！"
            # 显示具体的泄漏文件和行号
            echo "  泄漏位置："
            grep -rnE "(sk-[a-zA-Z0-9]{48}|xoxb-[a-zA-Z0-9-]{30,}|sk-ant-[a-zA-Z0-9]{40,}|apikey\s*\[?[a-zA-Z0-9-]{20,})" "$hermes_dir" 2>/dev/null | while read -r line; do
                echo "    $line"
            done
            echo "  建议：立即清理上述日志文件并检查密钥是否需要轮换"
            has_leaks=true
        fi
    fi

    # 检查日志文件中的密钥
    local logs_dir="$hermes_dir/logs"
    if [ -d "$logs_dir" ]; then
        # 先检查是否存在匹配（更精确的API密钥模式）
        if grep -rE "(sk-[a-zA-Z0-9]{48}|xoxb-[a-zA-Z0-9-]{30,}|sk-ant-[a-zA-Z0-9]{40,}|apikey\s*\[?[a-zA-Z0-9-]{20,})" "$logs_dir" >/dev/null 2>&1; then
            log_error "检测到日志文件中可能存在 API 密钥泄露！"
            # 显示具体的泄漏文件和行号
            echo "  泄漏位置："
            grep -rnE "(sk-[a-zA-Z0-9]{48}|xoxb-[a-zA-Z0-9-]{30,}|sk-ant-[a-zA-Z0-9]{40,}|apikey\s*\[?[a-zA-Z0-9-]{20,})" "$logs_dir" 2>/dev/null | while read -r line; do
                echo "    $line"
            done
            echo "  建议：立即清理上述日志文件并检查密钥是否需要轮换"
            has_leaks=true
        fi
    fi

    if [ "$has_leaks" = true ]; then
        add_check_result "API 密钥泄露检查" "FAIL" "检测到 API 密钥泄露"
    else
        log_success "未发现明显的 API 密钥泄露"
        add_check_result "API 密钥泄露检查" "PASS" "未发现 API 密钥泄露"
    fi
}

# 检查 Cron 权限控制
check_cron_permissions() {
    local current_user=$(whoami)
    local status="WARN"
    local message="Cron 权限控制不足"

    # 检查 cron.allow 和 cron.deny
    if [ -f /etc/cron.allow ]; then
        if grep -q "^$current_user$" /etc/cron.allow; then
            log_success "当前用户在 cron.allow 中，Cron 权限控制正确"
            status="PASS"
            message="Cron 权限控制正确"
        else
            log_warn "当前用户不在 cron.allow 中，可能存在 Cron 权限问题"
            echo "  建议：将用户添加到 cron.allow"
            echo "  命令：echo \"$current_user\" | sudo tee -a /etc/cron.allow"
        fi
    elif [ -f /etc/cron.deny ]; then
        if ! grep -q "^ALL$" /etc/cron.deny; then
            log_warn "cron.deny 文件存在但未设置为 ALL，Cron 权限控制不足"
            echo "  建议：设置 cron.deny 为 ALL 并使用 cron.allow 精确控制"
            echo "  命令：echo \"ALL\" | sudo tee /etc/cron.deny"
        else
            log_success "cron.deny 设置为 ALL，Cron 权限控制正确"
            status="PASS"
            message="Cron 权限控制正确"
        fi
    else
        log_warn "未配置 cron.allow 或 cron.deny，所有用户均可使用 Cron"
        echo "  建议：配置 cron.allow 仅允许必要用户"
        echo "  命令："
        echo "    echo \"$current_user\" | sudo tee /etc/cron.allow"
        echo "    echo \"ALL\" | sudo tee /etc/cron.deny"
    fi

    add_check_result "Cron 定时任务权限" "$status" "$message"
}

# 检查虚拟环境
check_virtual_environment() {
    local venv_path="$HOME/.venv/hermes"
    if [ -d "$venv_path" ]; then
        if [ -f "$venv_path/bin/activate" ]; then
            log_success "检测到虚拟环境: $venv_path"
            add_check_result "虚拟环境" "PASS" "已配置虚拟环境"
        else
            log_warn "虚拟环境目录存在但不完整: $venv_path"
            echo "  建议：创建虚拟环境隔离依赖"
            echo "  命令："
            echo "    python3 -m venv ~/.venv/hermes"
            echo "    source ~/.venv/hermes/bin/activate"
            add_check_result "虚拟环境" "WARN" "虚拟环境不完整"
        fi
    else
        log_warn "未检测到虚拟环境"
        echo "  建议：创建虚拟环境隔离依赖"
        echo "  命令："
        echo "    python3 -m venv ~/.venv/hermes"
        echo "    source ~/.venv/hermes/bin/activate"
        add_check_result "虚拟环境" "WARN" "未配置虚拟环境"
    fi
}

# 检查依赖版本锁定
check_dependency_locking() {
    local requirements_file="$HOME/.hermes/requirements-lock.txt"
    if [ -f "$requirements_file" ]; then
        log_success "检测到依赖锁定文件: $requirements_file"
        add_check_result "依赖版本锁定" "PASS" "已配置依赖锁定文件"
    else
        log_warn "未检测到依赖锁定文件"
        echo "  建议：生成依赖锁定文件以确保版本一致性"
        echo "  命令：pip freeze > ~/.hermes/requirements-lock.txt"
        add_check_result "依赖版本锁定" "WARN" "未配置依赖锁定文件"
    fi
}

# 主函数
main() {
    echo "=============================================="
    echo "    Hermes-Agent 安全扫描工具"
    echo "    基于《云上 Hermes-Agent 安全加固指南v2》"
    echo "=============================================="
    echo

    # 初始化检查结果数组
    check_results=()

    # 1. 检查用户权限
    echo "1. 检查系统权限加固..."
    check_root_user
    echo

    # 2. 检查 Hermes 配置
    echo "2. 检查 Hermes 配置文件..."
    check_hermes_config
    echo

    # 3. 检查敏感文件权限
    echo "3. 检查敏感文件和目录权限..."
    check_sensitive_files_permissions
    echo

    # 4. 检查 Hermes-Agent 版本和 LiteLLM 依赖
    echo "4. 检查 Hermes-Agent 版本安全..."
    check_hermes_and_litellm
    echo

    # 5. 检查 API 密钥泄露
    echo "5. 检查 API 密钥泄露..."
    check_api_key_leaks
    echo

    # 6. 检查 Cron 权限
    echo "6. 检查 Cron 定时任务权限..."
    check_cron_permissions
    echo

    # 7. 检查虚拟环境
    echo "7. 检查虚拟环境..."
    check_virtual_environment
    echo

    # 8. 检查依赖锁定
    echo "8. 检查依赖版本锁定..."
    check_dependency_locking
    echo

    # 打印最终总结（只显示检查项目，不包含详细修复建议）
    print_final_summary
}

# 运行主函数
main "$@"

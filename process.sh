#!/bin/bash
#
# 广告拦截规则自动化处理脚本
# 版本: 1.0.0
# 用途: 从多个网络源下载、清洗、去重并合并广告拦截规则
# 
# 功能特性:
#   - 智能缓存机制（6小时有效期）
#   - 自动去重和规则验证
#   - 黑名单重复检测
#   - 完整的错误处理和日志
#
# 运行环境: GitHub Actions (ubuntu-latest)
# 依赖工具: bash, curl, grep, sed, sort, wc, find, stat, md5sum
#
set -eo pipefail

# 配置
CACHE_DIR="$HOME/.cache/adblock-sources"
LOG_DIR="logs"
ADBLOCK_FILE="adblock.txt"
REPORT_FILE="reports.txt"
README_FILE="README.md"

# 常量定义（魔法数字）
readonly SECONDS_PER_DAY=86400          # 一天的秒数
readonly CACHE_EXPIRY_SECONDS=21600     # 缓存有效期：6小时
readonly CACHE_RETENTION_DAYS=7         # 缓存保留天数：7天（超过7天的缓存文件会被清理）
readonly MAX_CACHE_SIZE_MB=500          # 缓存最大大小：500MB
readonly MAX_CACHE_CLEAN_SIZE_MB=400    # 缓存清理目标大小：400MB
readonly MAX_FILE_SIZE_BYTES=104857600  # 下载文件大小限制：100MB
readonly LOG_RETENTION_DAYS=10          # 日志保留天数：10天
readonly LOG_ANALYSIS_DAYS=30           # 日志分析天数：30天
readonly RULE_DROP_THRESHOLD=50         # 规则数量下降告警阈值：50%
readonly RULE_DROP_WARNING_THRESHOLD=30 # 规则数量下降警告阈值：30%

# 记录脚本开始时间（秒）
START_TIME=$(date +%s)

# 清理旧日志文件（基于timestamp精确比较）
# 参数: $1 - 日志文件路径, $2 - 保留天数
cleanup_old_logs() {
    local log_file="$1"
    local retention_days="$2"
    
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi
    
    local cutoff_timestamp=$(( $(date +%s) - retention_days * SECONDS_PER_DAY ))
    
    # 使用awk的mktime函数，避免调用外部date命令
    awk -v cutoff="$cutoff_timestamp" '
    BEGIN {
        FS="[ |:]"
        kept = 0
        last_line = ""
    }
    {
        # 保存最后一行（用于所有日志都过期的情况）
        last_line = $0
        
        # 解析日志格式：YYYY-MM-DD HH:MM:SS | STATUS | URL | TIME | LINES
        if (NF >= 5 && $1 ~ /^[0-9]{4}$/ && $2 ~ /^[0-9]{2}$/ && $3 ~ /^[0-9]{2}$/) {
            # 构建时间字符串用于mktime (YYYY MM DD HH MM SS)
            year = $1
            month = $2
            day = $3
            hour = $4
            minute = $5
            second = $6
            
            # 使用mktime转换为timestamp
            ts = mktime(year " " month " " day " " hour " " minute " " second)
            
            if (ts >= cutoff) {
                # 重新组合原始行
                $1 = $1 "-" $2 "-" $3
                $2 = $4 ":" $5 ":" $6
                for (i = 3; i <= 6; i++) {
                    $i = $(i+3)
                }
                NF = NF - 3
                print
                kept++
            }
        } else {
            # 非标准格式的行，直接保留（如注释）
            print
            kept++
        }
    }
    END {
        if (kept == 0 && last_line != "") {
            # 如果没有保留任何行但原文件有内容，保留最后一行并添加注释
            print "# 日志清理：所有旧记录已删除，保留最后一行作为参考"
            print last_line
        }
    }
    ' "$log_file" > "$log_file.tmp" 2>/dev/null
    
    if [[ -s "$log_file.tmp" ]]; then
        mv "$log_file.tmp" "$log_file"
    else
        rm -f "$log_file.tmp"
    fi
}

# 统计文件行数（安全版本）
# 参数: $1 - 文件路径
# 返回: 行数（如果文件不存在或读取失败返回0）
count_lines() {
    [[ ! -f "$1" ]] && echo 0 && return 0
    wc -l < "$1" 2>/dev/null || echo 0
}

# 创建缓存目录
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    echo "❌ 错误：无法创建缓存目录" >&2
    exit 1
fi

# 创建日志目录
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "❌ 错误：无法创建日志目录" >&2
    exit 1
fi

# 检查必要命令（包括awk，用于日志分析和统计）
for cmd in curl grep sed sort wc find stat md5sum du awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ 错误：必要命令 '$cmd' 不存在" >&2
        exit 1
    fi
done

# 创建临时工作目录（在当前目录下，GitHub Actions 可信任）
WORK_DIR=".tmp-work-$$"
if ! mkdir -p "$WORK_DIR" 2>/dev/null; then
    echo "❌ 错误：无法创建临时工作目录" >&2
    exit 1
fi

# 清理函数：删除临时工作目录
# 在脚本退出、中断或终止时自动调用
cleanup() {
    local exit_code=$?
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR" 2>/dev/null
        WORK_DIR=""  # 删除后重置变量
    fi
    return $exit_code
}
trap cleanup EXIT INT TERM

# 获取北京时间
# 返回: 格式化的北京时间字符串
beijing_time() {
    TZ='Asia/Shanghai' date '+%Y年%m月%d日 %H:%M:%S (北京时间)'
}

# 提取文件中的有效行（用于黑名单等）
# 参数: $1 - 文件路径
# 功能: 移除 BOM、空行、注释行和行尾注释
# 返回: 有效内容行（通过 stdout）
# 注意: 如果文件不存在或不可读，返回空（exit code 0）
# 示例: extract_valid_lines "blacklist.txt"
extract_valid_lines() {
    [[ ! -f "$1" ]] && return 0
    [[ ! -r "$1" ]] && return 0
    sed 's/^\xEF\xBB\xBF//;s/[[:space:]]*$//;s/^[[:space:]]*//' "$1" 2>/dev/null | \
    grep -vE '^#|^$' 2>/dev/null | \
    sed 's/[[:space:]]*#.*$//' 2>/dev/null | grep -v '^$' 2>/dev/null || true
}

# 提取白名单的有效行（保留 $important 修饰符）
# 参数: $1 - 文件路径
# 功能: 移除 BOM、空行、纯注释行，只保留 @@||domain.com^ 或 @@||domain.com^$important 格式
# 返回: 有效内容行（通过 stdout）
extract_whitelist_lines() {
    [[ ! -f "$1" ]] && return 0
    [[ ! -r "$1" ]] && return 0
    
    local line
    while IFS= read -r line; do
        # 移除 BOM 和首尾空白
        local cleaned_line=$(echo "$line" | sed 's/^\xEF\xBB\xBF//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和纯注释行
        [[ -z "$cleaned_line" || "$cleaned_line" =~ ^# ]] && continue
        
        # 移除行尾注释
        local final_line=$(echo "$cleaned_line" | sed 's/[[:space:]]*#.*$//')
        [[ -z "$final_line" ]] && continue
        
        # 只保留符合格式的规则：@@||domain.com^ 或 @@||domain.com^$important
        if [[ "$final_line" =~ ^@@\|\|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^(\$important)?$ ]]; then
            echo "$final_line"
        else
            # 其他格式不支持，跳过
            continue
        fi
    done < "$1" 2>/dev/null || true
}

# 检查必要文件
for file in sources.txt whitelist.txt blacklist.txt; do
    if [[ ! -f "$file" ]]; then
        echo "❌ 错误：$file 文件不存在" >&2
        echo "请创建 $file 文件（可以为空，但必须存在）" >&2
        exit 1
    fi
done

# 主流程（7步骤）
echo "步骤1/7: 清理过期缓存..."
# 安全检查：确保CACHE_DIR不为空且不是根目录
if [[ -z "$CACHE_DIR" || "$CACHE_DIR" == "/" ]]; then
    echo "❌ 错误：CACHE_DIR为空或为根目录，拒绝执行清理操作" >&2
    exit 1
fi
find "$CACHE_DIR" -maxdepth 1 -type f -mtime +$CACHE_RETENTION_DAYS -delete 2>/dev/null || true
old_cache_count=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)

# 检查缓存总大小，超过500MB时清理最旧的文件
cache_size_mb=$(du -s "$CACHE_DIR" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)
if [[ $cache_size_mb -gt $MAX_CACHE_SIZE_MB ]]; then
    echo "  └─ ⚠️  缓存过大(${cache_size_mb}MB)，清理中..." >&2
    # 按修改时间排序，删除最旧的文件直到小于$MAX_CACHE_CLEAN_SIZE_MB MB
    find "$CACHE_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | \
    while read -r timestamp file; do
        if [[ $cache_size_mb -gt $MAX_CACHE_CLEAN_SIZE_MB ]]; then
            file_size=$(du -s "$file" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)
            rm -f "$file" 2>/dev/null
            cache_size_mb=$((cache_size_mb - file_size))
        else
            break
        fi
    done
    echo "  └─ 清理后缓存：$(du -s "$CACHE_DIR" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)MB"
fi

# 优化：清理无效源的缓存文件（不在sources.txt、whitelist.txt、blacklist.txt中的源）
# 修复缓存键"挑食"问题：同时检查所有三个文件
all_urls=""
for file in "sources.txt" "whitelist.txt" "blacklist.txt"; do
    if [[ -f "$file" ]]; then
        urls=$(extract_valid_lines "$file")
        all_urls="${all_urls}${urls}"
    fi
done

if [[ -n "$all_urls" && -d "$CACHE_DIR" ]]; then
    # 构建有效缓存文件列表（基于所有URL的MD5）
    declare -A valid_caches_map
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        cache_file="$CACHE_DIR/$(printf '%s' "$url" | md5sum | cut -d' ' -f1)"
        valid_caches_map["$cache_file"]=1
    done <<< "$all_urls"
    
    # 删除不在有效列表中的缓存文件（保留日志文件）
    cleaned_invalid=0
    while IFS= read -r cache_file; do
        if [[ -z "${valid_caches_map[$cache_file]}" ]]; then
            rm -f "$cache_file" 2>/dev/null
            ((cleaned_invalid++)) || true
        fi
    done < <(find "$CACHE_DIR" -maxdepth 1 -type f ! -name "*.log" ! -name "*.md5" 2>/dev/null)
    
    if [[ $cleaned_invalid -gt 0 ]]; then
        echo "  └─ 清理无效缓存：$cleaned_invalid 个"
    fi
fi

echo "  └─ 保留缓存：$old_cache_count 个"

echo "步骤2/7: 下载网络源（串行模式）..."
# 下载策略说明：
# 本脚本采用串行模式逐行下载网络源，禁止并行下载
# 原因：
# 1. 避免网络拥塞：多个源同时下载可能导致网络带宽饱和
# 2. 简化错误处理：串行模式便于定位具体是哪个源失败
# 3. GitHub Actions 环境资源有限：并行下载会消耗更多内存和CPU
# 4. 缓存机制有效：已下载的源在6小时内会使用缓存，不会重复下载
# 5. 大多数源文件较小：串行下载性能影响可接受
source_list=$(extract_valid_lines "sources.txt")
if [[ -n "$source_list" ]]; then
    source_count=$(echo "$source_list" | grep -c '.' 2>/dev/null || echo 0)
else
    source_count=0
fi
echo "  └─ 待处理源：$source_count 个"

# 创建并验证输出文件
rules_file="$WORK_DIR/raw-rules.txt"
cleaned_file="$WORK_DIR/cleaned.txt"

if ! > "$rules_file" 2>/dev/null; then
    echo "❌ 错误：无法创建 raw-rules.txt 文件" >&2
    exit 1
fi

success_count=0
failed_count=0

if [[ $source_count -gt 0 ]]; then
    set +e  # 允许下载失败
    current=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        ((current++))
        
        # 显示当前处理的URL（截取前60字符）
        short_url=$(echo "$url" | cut -c1-60)
        echo "  [$current/$source_count] ${short_url}..."
        
        # 验证 URL 格式和长度
        if [[ ! "$url" =~ ^https?:// ]]; then
            echo "    └─ ❌ URL格式无效" >&2
            ((failed_count++))
            continue
        fi
        
        # 限制 URL 长度（防止命令行溢出）
        if [[ ${#url} -gt 4096 ]]; then
            echo "    └─ ❌ URL过长（${#url}字符，最大支持4096）" >&2
            ((failed_count++))
            continue
        fi
        
        cache_file="$CACHE_DIR/$(printf '%s' "$url" | md5sum | cut -d' ' -f1)"
        temp_file=$(mktemp "$WORK_DIR/download.XXXXXX")
        
        # 检查缓存
        if [[ -f "$cache_file" && -r "$cache_file" ]]; then
            # 跨平台获取文件修改时间（Linux: stat -c %Y, macOS: stat -f %m）
            file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
            cache_age=$(( $(date +%s) - file_mtime ))
            if [[ $cache_age -lt $CACHE_EXPIRY_SECONDS ]]; then
                cat "$cache_file" >> "$rules_file" 2>/dev/null || true
                echo "    └─ ✅ 使用缓存"
                ((success_count++))
                continue
            fi
        fi
        
        # 下载新文件（限制100MB），使用指数退避重试
        curl_output=$(mktemp "$WORK_DIR/curl.XXXXXX")
        download_success=0
        
        for retry in 1 2 3; do
            if curl --connect-timeout 10 --max-time 60 --retry 2 --max-filesize $MAX_FILE_SIZE_BYTES -sSL "$url" -o "$temp_file" 2>"$curl_output"; then
                download_success=1
                break
            fi
            
            if [[ $retry -lt 3 ]]; then
                # 指数退避：2^retry秒
                backoff=$((2 ** retry))
                echo "    └─ ⚠️  下载失败，$backoff 秒后重试 (第 $retry/3 次)" >&2
                sleep $backoff
            fi
        done
        
        if [[ $download_success -eq 1 ]]; then
            if [[ ! -s "$temp_file" ]]; then
                echo "    └─ ❌ 下载文件为空" >&2
                rm -f "$temp_file" "$curl_output"
                ((failed_count++))
                continue
            fi
            
            # 检测文件大小（额外保护）
            downloaded_size=$(stat -c %s "$temp_file" 2>/dev/null || echo 0)
            if [[ $downloaded_size -gt $MAX_FILE_SIZE_BYTES ]]; then
                echo "    └─ ❌ 文件过大 (${downloaded_size} bytes)" >&2
                rm -f "$temp_file" "$curl_output"
                ((failed_count++))
                continue
            fi
            
            # 检测HTML错误页面（更严格的检查）
            file_head=$(head -n 10 "$temp_file" 2>/dev/null)
            
            # 检查多个指标：
            # 1. 包含HTML标签或错误关键词
            # 2. 文件大小很小（错误页面通常很小）
            # 3. 不包含adblock规则的典型特征
            if echo "$file_head" | grep -qiE '(<!DOCTYPE html|<html|<head|<title|error|404|403|500|not found|access denied)' 2>/dev/null && \
               [[ $downloaded_size -lt 10240 ]] && \
               ! grep -qE '^\|\|' "$temp_file" 2>/dev/null; then
                echo "    └─ ❌ 返回HTML错误页面" >&2
                rm -f "$temp_file" "$curl_output"
                ((failed_count++))
                continue
            fi
            
            # 原子性操作：先移动，验证后追加
            if mv "$temp_file" "$cache_file" 2>/dev/null; then
                if cat "$cache_file" >> "$rules_file" 2>/dev/null; then
                    rules_count=$(count_lines "$cache_file")
                    echo "    └─ ✅ 下载成功 ($rules_count 行)"
                    ((success_count++))
                    
                    # 记录成功日志（用于健康度分析）
                    PERF_LOG="$LOG_DIR/performance.log"
                    # 清理旧日志，保留最近10天的所有记录
                    cleanup_old_logs "$PERF_LOG" "$LOG_RETENTION_DAYS"
                    # 检查file_mtime是否有效（避免stat失败导致计算错误）
                    if [[ $file_mtime -eq 0 ]]; then
                        download_time=0  # 如果无法获取文件时间，设置为0
                    else
                        download_time=$(($(date +%s) - file_mtime))
                    fi
                    echo "$(date '+%Y-%m-%d %H:%M:%S') | SUCCESS | $url | ${download_time}s | $rules_count lines" >> "$PERF_LOG" 2>/dev/null || true
                else
                    echo "    └─ ❌ 追加文件失败" >&2
                    ((failed_count++))
                fi
            else
                echo "    └─ ❌ 移动文件失败" >&2
                rm -f "$temp_file"
                ((failed_count++))
            fi
            rm -f "$curl_output"
        else
            # 显示 curl 错误信息
            error_msg=$(head -n 1 "$curl_output" 2>/dev/null | tr -cd '[:print:]' | cut -c1-100)
            [[ -n "$error_msg" ]] && echo "    └─ ❌ 下载失败: $error_msg" >&2 || echo "    └─ ❌ 下载失败" >&2
            rm -f "$temp_file" "$curl_output"
            ((failed_count++))
            
            # 记录失败日志到日志目录（持久化）
            FAIL_LOG="$LOG_DIR/failures.log"
            # 清理旧日志，保留最近10天的所有记录
            cleanup_old_logs "$FAIL_LOG" "$LOG_RETENTION_DAYS"
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $url | ${error_msg:-Unknown error}" >> "$FAIL_LOG" 2>/dev/null || true
        fi
    done <<< "$source_list"
    set -e  # 恢复错误退出
    
    echo "  └─ 总计：成功 $success_count | 失败 $failed_count"
    
    if [[ $success_count -eq 0 && $failed_count -gt 0 ]]; then
        echo "  └─ ⚠️  所有网络源下载失败，将仅使用本地规则" >&2
    fi
    
    [[ -s "$WORK_DIR/raw-rules.txt" ]] && echo "  └─ 原始规则：$(count_lines "$WORK_DIR/raw-rules.txt") 行"
else
    echo "  └─ ⚠️  无有效网络源" >&2
fi

echo "步骤3/7: 清洗与去重..."
if [[ -s "$WORK_DIR/raw-rules.txt" ]]; then
    raw_count=$(count_lines "$WORK_DIR/raw-rules.txt")
    echo "  └─ 原始规则：$raw_count 条"
    
    # 只保留最基础的adblock规则格式：||domain.com^
    # 使用管道连接多个grep命令，避免创建中间文件，提高性能
    
    # 清洗规则：只保留 ||domain.com^ 或 domain.com 格式
    # 使用set +e避免grep无匹配时触发set -e导致脚本退出
    # 注意：此步骤仅清洗网络源，白名单内容（含 $important）不经过此步骤
    # 白名单在步骤5中直接使用 extract_whitelist_lines 处理，保留 $important 标记
    set +e
    # 首先提取符合格式的规则：||domain.com^ 或 domain.com
    grep -E '^(\|\|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)$' "$WORK_DIR/raw-rules.txt" 2>/dev/null | \
    sort -u > "$WORK_DIR/cleaned.txt" 2>/dev/null
    set -e
    
    # 确保 cleaned.txt 存在
    [[ ! -f "$WORK_DIR/cleaned.txt" ]] && touch "$WORK_DIR/cleaned.txt"
    
    cleaned_count=$(count_lines "$WORK_DIR/cleaned.txt")
    echo "  └─ 清洗后：$cleaned_count 条"
    
    # 计算保留率
    if [[ $raw_count -gt 0 ]]; then
        retention_rate=$((cleaned_count * 100 / raw_count))
        filtered_count=$((raw_count - cleaned_count))
        echo "  └─ 保留率：$retention_rate%（保留 $cleaned_count 条，过滤 $filtered_count 条）" >&2
    fi
    
    if [[ $cleaned_count -eq 0 && $raw_count -gt 0 ]]; then
        echo "  └─ ⚠️  所有规则都被过滤，请检查规则格式" >&2
        echo "  └─ 保留格式：||domain.com^（必须以||开头，以^结尾）" >&2
        echo "  └─ 域名只能包含：字母、数字、连字符(-)、点(.)" >&2
    fi
else
    echo "  └─ ⚠️  raw-rules.txt 为空，跳过" >&2
    > "$WORK_DIR/cleaned.txt" || touch "$WORK_DIR/cleaned.txt"
fi

echo "步骤4/7: 检测黑名单重复..."
blacklist_content=$(extract_valid_lines "blacklist.txt")
{
    echo "# 重复检测报告"
    echo "# 检测时间：$(beijing_time)"
    echo "# 报告说明：显示您的 blacklist.txt 中与网络源重复的规则"
    echo ""
} > "$REPORT_FILE"

duplicate_count=0

if [[ -s "$cleaned_file" && -n "$blacklist_content" ]]; then
    # 使用awk进行高效匹配，一次性处理所有规则
    awk_script='
    BEGIN {
        duplicate = 0
    }
    NR == FNR {
        # 读取cleaned_file，存储所有规则
        rules[$0] = 1
        next
    }
    {
        # 读取黑名单，清理后检查4种模式
        rule = $0
        # 移除BOM
        gsub(/^\xEF\xBB\xBF/, "", rule)
        # 移除行尾注释
        gsub(/[[:space:]]*#.*$/, "", rule)
        # 清理首尾空白
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rule)
        
        if (rule == "") next
        
        # 尝试4种匹配模式
        if (rule in rules) {
            print rule
            duplicate++
            next
        }
        if (rule !~ /^\|\|/ && ("||" rule) in rules) {
            print rule
            duplicate++
            next
        }
        if (rule !~ /\^$/ && (rule "^") in rules) {
            print rule
            duplicate++
            next
        }
        if (rule !~ /^\|\|/ && rule !~ /\^$/ && ("||" rule "^") in rules) {
            print rule
            duplicate++
            next
        }
    }
    END {
        # 将重复数量输出到stderr
        print duplicate > "/dev/stderr"
    }
    '
    
    # 执行awk，将重复规则输出到temp-dup.txt，重复数量输出到dup-count.txt
    awk "$awk_script" "$cleaned_file" - <<< "$blacklist_content" > "$WORK_DIR/temp-dup.txt" 2> "$WORK_DIR/dup-count.txt"
    # 从文件读取重复数量
    duplicate_count=$(cat "$WORK_DIR/dup-count.txt" 2>/dev/null || echo 0)
    rm -f "$WORK_DIR/dup-count.txt"
fi

if [[ $duplicate_count -gt 0 ]]; then
    echo "  └─ 发现重复：$duplicate_count 条" >&2
    {
        echo "发现重复规则（${duplicate_count}条）："
        if [[ -s "$WORK_DIR/temp-dup.txt" ]]; then
            nl -w 1 -s '. ' "$WORK_DIR/temp-dup.txt" 2>/dev/null || cat -n "$WORK_DIR/temp-dup.txt"
        fi
        echo ""
        echo "💡 建议：可从 blacklist.txt 移除以上规则，减少冗余"
    } >> "$REPORT_FILE"
else
    echo "  └─ 无重复" >&2
    echo "✅ 检测完成：无重复规则（状态良好）" >> "$REPORT_FILE"
fi
rm -f "$WORK_DIR/temp-dup.txt"

echo "步骤5/7: 生成规则文件..."

# 规则文件备份机制：轮转备份，保留最近3个版本
if [[ -f "$ADBLOCK_FILE" && -s "$ADBLOCK_FILE" ]]; then
    # 轮转备份：bak.3 <- bak.2 <- bak.1 <- current
    rm -f "${ADBLOCK_FILE}.bak.3" 2>/dev/null
    [[ -f "${ADBLOCK_FILE}.bak.2" ]] && mv "${ADBLOCK_FILE}.bak.2" "${ADBLOCK_FILE}.bak.3" 2>/dev/null
    [[ -f "${ADBLOCK_FILE}.bak.1" ]] && mv "${ADBLOCK_FILE}.bak.1" "${ADBLOCK_FILE}.bak.2" 2>/dev/null
    cp "$ADBLOCK_FILE" "${ADBLOCK_FILE}.bak.1" 2>/dev/null
    echo "  └─ 已创建备份：${ADBLOCK_FILE}.bak.1" >&2
fi

sources_lines=$(extract_valid_lines "sources.txt")
whitelist_lines=$(extract_whitelist_lines "whitelist.txt")
blacklist_lines=$(extract_valid_lines "blacklist.txt")

total_sources=0
total_whitelist=0
total_blacklist=0
[[ -n "$sources_lines" ]] && total_sources=$(echo "$sources_lines" | grep -c '.' 2>/dev/null || echo 0)
[[ -n "$whitelist_lines" ]] && total_whitelist=$(echo "$whitelist_lines" | grep -c '.' 2>/dev/null || echo 0)
[[ -n "$blacklist_lines" ]] && total_blacklist=$(echo "$blacklist_lines" | grep -c '.' 2>/dev/null || echo 0)
total_rules=$(count_lines "$cleaned_file")
# 规则数量保护机制：检测异常波动
prev_rule_count=0
if [[ -f "${ADBLOCK_FILE}.bak.1" ]]; then
    prev_rule_count=$(grep -c -v '^!' "${ADBLOCK_FILE}.bak.1" 2>/dev/null || echo 0)
fi

{
    echo "! 标题：广告拦截规则"
    echo "! 格式版本：1.0"
    echo "! 更新时间：$(beijing_time)"
    echo "! 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "! 网络源数量：$total_sources 个"
    echo "! 自定义规则：$total_whitelist 条白名单 + $total_blacklist 条黑名单"
    echo "! 文件大小：@@FILE_SIZE_PLACEHOLDER@@"
    echo "! 运行状态：✅ 正常"
    echo ""
} > "$ADBLOCK_FILE"

# 创建临时文件用于排序
temp_whitelist="$WORK_DIR/temp_whitelist.txt"
temp_blacklist="$WORK_DIR/temp_blacklist.txt"
temp_network="$WORK_DIR/temp_network.txt"

# 处理白名单规则 - 先提取规则，然后排序
extract_whitelist_lines "whitelist.txt" > "$temp_whitelist" 2>/dev/null
if [[ -s "$temp_whitelist" ]]; then
    # 对白名单规则进行排序
    sort "$temp_whitelist" > "$temp_whitelist.sorted" 2>/dev/null
    mv "$temp_whitelist.sorted" "$temp_whitelist"
    cat "$temp_whitelist" >> "$ADBLOCK_FILE" 2>/dev/null
fi

# 处理黑名单规则 - 先提取规则并保留原始格式，然后排序
extract_valid_lines "blacklist.txt" > "$temp_blacklist" 2>/dev/null
if [[ -s "$temp_blacklist" ]]; then
    # 清洗黑名单规则：只保留 ||domain.com^ 或 domain.com 格式
    grep -E '^(\|\|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)$' "$temp_blacklist" 2>/dev/null | \
    sort > "$temp_blacklist.sorted" 2>/dev/null
    mv "$temp_blacklist.sorted" "$temp_blacklist"
    cat "$temp_blacklist" >> "$ADBLOCK_FILE" 2>/dev/null
fi

# 处理网络源规则 - 已经在前面步骤中处理过，现在排序
if [[ -s "$cleaned_file" ]]; then
    # 对网络源规则进行排序
    sort "$cleaned_file" > "$temp_network" 2>/dev/null
    if [[ -s "$temp_network" ]]; then
        cat "$temp_network" >> "$ADBLOCK_FILE" 2>/dev/null || {
            echo "❌ 错误：无法追加网络源规则" >&2
            exit 1
        }
    fi
fi

# 清理临时文件
rm -f "$temp_whitelist" "$temp_blacklist" "$temp_network" "$temp_whitelist.sorted" "$temp_blacklist.sorted" 2>/dev/null

# 计算并替换文件大小占位符
file_size=$(du -h "$ADBLOCK_FILE" 2>/dev/null | cut -f1 || echo "0K")
# 使用临时文件方式，避免不同系统上sed -i的兼容性问题
# 使用#作为分隔符，因为文件大小中不太可能包含#
sed "s#@@FILE_SIZE_PLACEHOLDER@@#$file_size#" "$ADBLOCK_FILE" > "$ADBLOCK_FILE.tmp" 2>/dev/null && mv "$ADBLOCK_FILE.tmp" "$ADBLOCK_FILE"

# 验证生成的规则文件
if [[ ! -s "$ADBLOCK_FILE" ]]; then
    echo "❌ 错误：生成的规则文件为空" >&2
    exit 1
fi

# 计算并保存MD5校验和（用于完整性验证）
md5sum "$ADBLOCK_FILE" > "$ADBLOCK_FILE.md5" 2>/dev/null

actual_rules=$( (grep -vE '^!|^$' "$ADBLOCK_FILE" | wc -l) 2>/dev/null || echo 0)

if [[ $actual_rules -eq 0 ]]; then
    echo "❌ 错误：规则文件不包含有效规则" >&2
    exit 1
fi

# 规则数量保护：检测异常波动
if [[ $prev_rule_count -gt 0 && $actual_rules -gt 0 ]]; then
    drop_rate=$(( (prev_rule_count - actual_rules) * 100 / prev_rule_count ))
    if [[ $drop_rate -gt $RULE_DROP_THRESHOLD ]]; then
        echo "⚠️  警告：规则数量异常下降 ${drop_rate}%（从 $prev_rule_count 降至 $actual_rules）" >&2
        {
            echo ""
            echo "## 🚨 规则数量异常告警"
            echo "- 下降幅度：${drop_rate}%"
            echo "- 原规则数：$prev_rule_count"
            echo "- 新规则数：$actual_rules"
            echo "- 可能原因：网络源失效、格式变更或清洗规则过严"
            echo "- 处理措施：已保留备份文件，可手动恢复"
            echo "- 备份文件：${ADBLOCK_FILE}.bak.1"
        } >> "$REPORT_FILE"
    elif [[ $drop_rate -gt 30 ]]; then
        echo "⚠️  注意：规则数量下降 ${drop_rate}%（从 $prev_rule_count 降至 $actual_rules）" >&2
    fi
fi

# 验证文件完整性
if [[ -f "$ADBLOCK_FILE.md5" ]]; then
    if ! md5sum -c "$ADBLOCK_FILE.md5" >/dev/null 2>&1; then
        echo "❌ 错误：规则文件MD5校验失败，文件可能已损坏" >&2
        exit 1
    fi
    echo "✅ MD5校验通过，校验文件已保留：$ADBLOCK_FILE.md5"
fi

echo "步骤6/7: 生成说明文档..."
# 检查是否存在README模板，存在则使用模板，否则使用默认生成
if [[ -f "README.template.md" ]]; then
    # 使用模板文件（无论是否有占位符），给用户灵活性
    cp "README.template.md" "$README_FILE" 2>/dev/null
    # 检查是否有占位符，如果有则替换
    placeholder_count=$(grep -o '@@' "$README_FILE" 2>/dev/null | wc -l)
    if [[ $placeholder_count -gt 0 ]]; then
        # 替换模板中的占位符（移除错误抑制，让错误暴露）
        sed -i "s/@@RULE_COUNT@@/$((total_rules + total_whitelist + total_blacklist))/g" "$README_FILE"
        sed -i "s/@@UPDATE_TIME@@/$(beijing_time)/g" "$README_FILE"
        sed -i "s/@@SOURCE_COUNT@@/$total_sources/g" "$README_FILE"
        sed -i "s/@@WHITELIST_COUNT@@/$total_whitelist/g" "$README_FILE"
        sed -i "s/@@BLACKLIST_COUNT@@/$total_blacklist/g" "$README_FILE"
    fi
else
    # 默认生成
    {
        echo "# 广告拦截规则仓库"
        echo ""
        echo "## 📊 当前状态"
        echo "- **规则总数**：$((total_rules + total_whitelist + total_blacklist)) 条"
        echo "- **最后更新**：$(beijing_time)"
        echo ""
        echo "## 📁 文件说明"
        echo "| 文件名 | 用途 | 编辑方式 |"
        echo "|--------|------|----------|"
        echo "| \`sources.txt\` | 网络源列表 | 网页端编辑，支持 # 注释 |"
        echo "| \`whitelist.txt\` | 白名单规则 | 网页端编辑，支持 # 注释 |"
        echo "| \`blacklist.txt\` | 黑名单规则 | 网页端编辑，支持 # 注释 |"
        echo "| \`reports.txt\` | 检测报告 | 自动生成，只读 |"
    } > "$README_FILE"
fi

# 验证说明文档
if [[ ! -s "$README_FILE" ]]; then
    echo "❌ 错误：说明文档生成失败" >&2
    exit 1
fi

# 生成详细运行报告
{
    echo "# 运行报告"
    echo "# 生成时间：$(beijing_time)"
    echo "#"
    echo "## 📊 处理统计"
    echo "- 网络源总数：$source_count 个"
    echo "- 下载成功：$success_count 个"
    echo "- 下载失败：$failed_count 个"
    echo "- 成功率：$([[ $source_count -gt 0 ]] && echo $((success_count * 100 / source_count)) || echo 0)%"
    echo "- 网络源规则：$total_rules 条"
    echo "- 白名单规则：$total_whitelist 条"
    echo "- 黑名单规则：$total_blacklist 条"
    echo "- 总规则数：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "- 文件大小：$file_size"
    echo ""
    echo "## 💾 资源使用"
    echo "- 缓存目录：$CACHE_DIR"
    echo "- 临时目录：$WORK_DIR（已清理）"
    echo "- 缓存大小：$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || echo '未知')"
    echo ""
    echo "## ⚡ 性能指标"
    echo "- 处理时间：$(($(date +%s) - START_TIME)) 秒"
    echo "- 平均下载时间：$([[ $success_count -gt 0 ]] && echo $((($(date +%s) - START_TIME) / success_count)) || echo 0) 秒/源"
    echo ""
    echo "## ✅ 生成文件"
    for file in "$ADBLOCK_FILE" "$REPORT_FILE" "$README_FILE"; do
      if [[ -f "$file" ]]; then
        echo "- ✓ $file ($(count_lines "$file") 行)"
      else
        echo "- ✗ $file (缺失)"
      fi
    done
    echo ""
    echo "## 📝 运行状态"
    if [[ $failed_count -eq 0 ]]; then
      echo "- 状态：完全成功 ✅"
    elif [[ $success_count -eq 0 ]]; then
      echo "- 状态：全部失败 ❌"
    else
      echo "- 状态：部分成功 ⚠️"
    fi
    
    # 添加源健康度统计
    FAIL_LOG="$LOG_DIR/failures.log"
    PERF_LOG="$LOG_DIR/performance.log"
    if [[ -f "$FAIL_LOG" || -f "$PERF_LOG" ]]; then
      echo ""
      echo "## 📊 源健康度分析"
      
      # 失败统计
      if [[ -f "$FAIL_LOG" ]]; then
        cutoff_timestamp=$(( $(date +%s) - LOG_ANALYSIS_DAYS * SECONDS_PER_DAY ))
        recent_failures=$(awk -v cutoff="$cutoff_timestamp" '
        BEGIN {
            FS=" | "
            count = 0
        }
        {
            datetime = $1 " " $2
            cmd = "date -d \"" datetime "\" +%s 2>/dev/null"
            if ((cmd | getline ts) > 0) {
                close(cmd)
            } else {
                close(cmd)
                ts = 0  # 如果date命令失败，设置为0（会小于cutoff）
            }
            if (ts >= cutoff) count++
        }
        END {
            print count
        }
        ' "$FAIL_LOG" 2>/dev/null || echo 0)
        
        if [[ $recent_failures -gt 0 ]]; then
            echo "- 最近${LOG_ANALYSIS_DAYS}天失败次数：$recent_failures"
            echo "- 频繁失败的源（Top 5）："
            awk -v cutoff="$cutoff_timestamp" -F'|' '
            ts >= cutoff {
                url = $2
                failures[url]++
            }
            END {
                for (url in failures) {
                    print failures[url], url
                }
            }
            ' <(awk -v cutoff="$cutoff_timestamp" '
            {
                datetime = $1 " " $2
                cmd = "date -d \"" datetime "\" +%s 2>/dev/null"
                cmd | getline ts
                close(cmd)
                if (ts >= cutoff) print
            }
            ' "$FAIL_LOG") | sort -nr | head -5 | while read -r count url; do
                echo "  - $url ($count次)"
            done
        fi
      fi
      
      # 性能统计
      if [[ -f "$PERF_LOG" ]]; then
        echo "- 性能统计（最近${LOG_ANALYSIS_DAYS}天）："
        cutoff_timestamp=$(( $(date +%s) - LOG_ANALYSIS_DAYS * SECONDS_PER_DAY ))
        
        # 平均下载时间
        avg_time=$(awk -v cutoff="$cutoff_timestamp" -F'|' '
        BEGIN {
            sum = 0
            count = 0
        }
        $3 ~ /SUCCESS/ {
            datetime = $1 " " $2
            cmd = "date -d \"" datetime "\" +%s 2>/dev/null"
            if ((cmd | getline ts) > 0) {
                close(cmd)
            } else {
                close(cmd)
                ts = 0
            }
            if (ts >= cutoff) {
                gsub(/s$/, "", $4)
                sum += $4
                count++
            }
        }
        END {
            if (count > 0) printf "%.2fs", sum/count
            else print "N/A"
        }
        ' "$PERF_LOG" 2>/dev/null || echo "N/A")
        echo "  - 平均下载时间：$avg_time"
        
        # 最快的源
        fast_source=$(awk -v cutoff="$cutoff_timestamp" -F'|' '
        $3 ~ /SUCCESS/ {
            datetime = $1 " " $2
            cmd = "date -d \"" datetime "\" +%s 2>/dev/null"
            if ((cmd | getline ts) > 0) {
                close(cmd)
            } else {
                close(cmd)
                ts = 0
            }
            if (ts >= cutoff) {
                gsub(/s$/, "", $4)
                if (NR == 1 || $4 < min_time) {
                    min_time = $4
                    fastest = $3
                }
            }
        }
        END {
            if (fastest) print fastest
        }
        ' "$PERF_LOG" 2>/dev/null | head -1)
        if [[ -n "$fast_source" ]]; then
            echo "  - 最快的源：$(echo $fast_source | cut -c1-60)"
        fi
        
        # 最慢的源
        slow_source=$(awk -v cutoff="$cutoff_timestamp" -F'|' '
        $3 ~ /SUCCESS/ {
            datetime = $1 " " $2
            cmd = "date -d \"" datetime "\" +%s 2>/dev/null"
            if ((cmd | getline ts) > 0) {
                close(cmd)
            } else {
                close(cmd)
                ts = 0
            }
            if (ts >= cutoff) {
                gsub(/s$/, "", $4)
                if (NR == 1 || $4 > max_time) {
                    max_time = $4
                    slowest = $3
                }
            }
        }
        END {
            if (slowest) print slowest
        }
        ' "$PERF_LOG" 2>/dev/null | head -1)
        if [[ -n "$slow_source" ]]; then
            echo "  - 最慢的源：$(echo $slow_source | cut -c1-60)"
        fi
      fi
    fi
} >> "$REPORT_FILE"

echo "步骤7/7: 清理临时文件..."
# 临时文件由 cleanup 函数自动清理，此处仅打印信息
echo ""
echo "✅ 所有步骤处理完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 处理统计："
echo "  • 网络源：$source_count 个（成功 $success_count | 失败 $failed_count）"
echo "  • 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
echo "  • 文件大小：$file_size"
echo "  • 处理时间：$(($(date +%s) - START_TIME)) 秒"
echo ""
echo "📁 生成文件："
echo "  ✓ $ADBLOCK_FILE"
echo "  ✓ $REPORT_FILE"
echo "  ✓ $README_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0

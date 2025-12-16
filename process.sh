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
ADBLOCK_FILE="adblock.txt"
REPORT_FILE="reports.txt"
README_FILE="README.md"

# 记录脚本开始时间（秒）
START_TIME=$(date +%s)

# 创建缓存目录
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    echo "❌ 错误：无法创建缓存目录" >&2
    exit 1
fi

# 检查必要命令
for cmd in curl grep sed sort wc find stat md5sum du; do
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

# 提取文件中的有效行
# 参数: $1 - 文件路径
# 功能: 移除 BOM、空行、注释行和行尾注释
# 返回: 有效内容行（通过 stdout）
# 注意: 如果文件不存在或不可读，返回空（exit code 0）
# 示例: extract_valid_lines "sources.txt"
extract_valid_lines() {
    [[ ! -f "$1" ]] && return 0
    [[ ! -r "$1" ]] && return 0
    sed 's/^\xEF\xBB\xBF//;s/[[:space:]]*$//;s/^[[:space:]]*//' "$1" 2>/dev/null | \
    grep -v '^#' 2>/dev/null | grep -v '^$' 2>/dev/null | \
    sed 's/[[:space:]]*#.*$//' 2>/dev/null | grep -v '^$' 2>/dev/null || true
}

# 提取白名单的有效行（保留 $important 修饰符）
# 参数: $1 - 文件路径
# 功能: 移除 BOM、空行、纯注释行，但保留 $important
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
        
        # 如果包含 $important，保留整行
        if [[ "$cleaned_line" =~ \$important ]]; then
            echo "$cleaned_line"
        else
            # 否则移除行尾注释
            local final_line=$(echo "$cleaned_line" | sed 's/[[:space:]]*#.*$//')
            [[ -n "$final_line" ]] && echo "$final_line"
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
find "$CACHE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
old_cache_count=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)

# 检查缓存总大小，超过500MB时清理最旧的文件
cache_size_mb=$(du -s "$CACHE_DIR" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)
if [[ $cache_size_mb -gt 500 ]]; then
    echo "  └─ ⚠️  缓存过大(${cache_size_mb}MB)，清理中..." >&2
    # 按修改时间排序，删除最旧的文件直到小于400MB
    find "$CACHE_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | \
    while read -r timestamp file; do
        if [[ $cache_size_mb -gt 400 ]]; then
            file_size=$(du -s "$file" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)
            rm -f "$file" 2>/dev/null
            cache_size_mb=$((cache_size_mb - file_size))
        else
            break
        fi
    done
    echo "  └─ 清理后缓存：$(du -s "$CACHE_DIR" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo 0)MB"
fi

echo "  └─ 保留缓存：$old_cache_count 个"

echo "步骤2/7: 下载网络源（串行模式）..."
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
            if [[ $cache_age -lt 21600 ]]; then
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
            if curl --connect-timeout 10 --max-time 60 --retry 2 --max-filesize 104857600 -sSL "$url" -o "$temp_file" 2>"$curl_output"; then
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
            if [[ $downloaded_size -gt 104857600 ]]; then
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
                    rules_count=$(wc -l < "$cache_file" 2>/dev/null || echo 0)
                    echo "    └─ ✅ 下载成功 ($rules_count 行)"
                    ((success_count++))
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
            error_msg=$(cat "$curl_output" 2>/dev/null | head -n 1 | tr -cd '[:print:]' | cut -c1-100)
            [[ -n "$error_msg" ]] && echo "    └─ ❌ 下载失败: $error_msg" >&2 || echo "    └─ ❌ 下载失败" >&2
            rm -f "$temp_file" "$curl_output"
            ((failed_count++))
        fi
    done <<< "$source_list"
    set -e  # 恢复错误退出
    
    echo "  └─ 总计：成功 $success_count | 失败 $failed_count"
    
    if [[ $success_count -eq 0 && $failed_count -gt 0 ]]; then
        echo "  └─ ⚠️  所有网络源下载失败，将仅使用本地规则" >&2
    fi
    
    [[ -s "$WORK_DIR/raw-rules.txt" ]] && echo "  └─ 原始规则：$(wc -l < "$WORK_DIR/raw-rules.txt") 行"
else
    echo "  └─ ⚠️  无有效网络源" >&2
fi

echo "步骤3/7: 清洗与去重..."
if [[ -s "$WORK_DIR/raw-rules.txt" ]]; then
    raw_count=$(wc -l < "$WORK_DIR/raw-rules.txt" 2>/dev/null || echo 0)
    echo "  └─ 原始规则：$raw_count 条"
    
    # 只保留最基础的adblock规则格式：||domain.com^
    # 使用管道连接多个grep命令，避免创建中间文件，提高性能
    
    # 清洗规则：排除包含特殊字符的规则（/、$、@、!、#）并验证域名格式
    # 使用set +e避免grep无匹配时触发set -e导致脚本退出
    # 注意：此步骤仅清洗网络源，白名单内容（含 $important）不经过此步骤
    # 白名单在步骤5中直接使用 extract_whitelist_lines 处理，保留 $important 标记
    set +e
    grep -E '^\|\|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^$' "$WORK_DIR/raw-rules.txt" 2>/dev/null | \
    sort -u > "$WORK_DIR/cleaned.txt" 2>/dev/null
    set -e
    
    # 确保 cleaned.txt 存在
    [[ ! -f "$WORK_DIR/cleaned.txt" ]] && touch "$WORK_DIR/cleaned.txt"
    
    cleaned_count=$(wc -l < "$WORK_DIR/cleaned.txt" 2>/dev/null || echo 0)
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
sources_lines=$(extract_valid_lines "sources.txt")
whitelist_lines=$(extract_whitelist_lines "whitelist.txt")
blacklist_lines=$(extract_valid_lines "blacklist.txt")

total_sources=0
total_whitelist=0
total_blacklist=0
[[ -n "$sources_lines" ]] && total_sources=$(echo "$sources_lines" | grep -c '.' 2>/dev/null || echo 0)
[[ -n "$whitelist_lines" ]] && total_whitelist=$(echo "$whitelist_lines" | grep -c '.' 2>/dev/null || echo 0)
[[ -n "$blacklist_lines" ]] && total_blacklist=$(echo "$blacklist_lines" | grep -c '.' 2>/dev/null || echo 0)
total_rules=$(wc -l < "$cleaned_file" 2>/dev/null || echo 0)

{
    echo "! 标题：广告拦截规则"
    echo "! 更新时间：$(beijing_time)"
    echo "! 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "! 网络源数量：$total_sources 个"
    echo "! 自定义规则：$total_whitelist 条白名单 + $total_blacklist 条黑名单"
    echo "! 文件大小：@@FILE_SIZE_PLACEHOLDER@@"
    echo "! 运行状态：✅ 正常"
    echo ""
} > "$ADBLOCK_FILE"

# 最终合并顺序：白名单 → 黑名单 → 网络源
extract_whitelist_lines "whitelist.txt" >> "$ADBLOCK_FILE" 2>/dev/null
extract_valid_lines "blacklist.txt" >> "$ADBLOCK_FILE" 2>/dev/null
if [[ -s "$cleaned_file" ]]; then
    cat "$cleaned_file" >> "$ADBLOCK_FILE" 2>/dev/null || {
        echo "❌ 错误：无法追加网络源规则" >&2
        exit 1
    }
fi

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

actual_rules=$( (grep -v '^!' "$ADBLOCK_FILE" | grep -v '^$' | wc -l) 2>/dev/null || echo 0)

if [[ $actual_rules -eq 0 ]]; then
    echo "❌ 错误：规则文件不包含有效规则" >&2
    exit 1
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
        echo "- ✓ $file ($(wc -l < "$file" 2>/dev/null || echo 0) 行)"
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

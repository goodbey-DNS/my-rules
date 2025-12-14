#!/bin/bash
# -*- coding: utf-8 -*-
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
# 依赖工具: bash, curl, grep, sed, sort, wc, find, stat
#
set -eo pipefail

# 配置
CACHE_DIR="$HOME/.cache/adblock-sources"
ADBLOCK_FILE="adblock.txt"
REPORT_FILE="reports.txt"
README_FILE="README.md"

# 创建缓存目录
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    echo "❌ 错误：无法创建缓存目录" >&2
    exit 1
fi

# 检查必要命令
for cmd in curl grep sed sort wc find stat md5sum; do
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
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null
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
    
    while IFS= read -r line; do
        # 移除 BOM 和首尾空白
        line=$(echo "$line" | sed 's/^\xEF\xBB\xBF//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和纯注释行
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 如果包含 $important，保留整行
        if [[ "$line" =~ \$important ]]; then
            echo "$line"
        else
            # 否则移除行尾注释
            clean_line=$(echo "$line" | sed 's/[[:space:]]*#.*$//')
            [[ -n "$clean_line" ]] && echo "$clean_line"
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

# 前置检查
if [[ ! -f "sources.txt" ]]; then
    echo "❌ 错误：sources.txt 文件不存在" >&2
    echo "请创建 sources.txt 并添加广告规则源地址（每行一个URL）" >&2
    exit 1
fi

# 主流程（7步骤）
echo "步骤1/7: 清理过期缓存..."
find "$CACHE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
old_cache_count=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)
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
dup_file="$WORK_DIR/temp-dup.txt"

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
        short_url=$(echo "$url" | head -c 60)
        echo "  [$current/$source_count] ${short_url}..."
        
        # 验证 URL 格式和长度
        if [[ ! "$url" =~ ^https?:// ]]; then
            echo "    └─ ❌ URL格式无效" >&2
            ((failed_count++))
            continue
        fi
        
        # 限制 URL 长度（防止命令行溢出）
        if [[ ${#url} -gt 2048 ]]; then
            echo "    └─ ❌ URL过长" >&2
            ((failed_count++))
            continue
        fi
        
        cache_file="$CACHE_DIR/$(echo -n "$url" | md5sum | cut -d' ' -f1)"
        temp_file="$WORK_DIR/download-$$-$(date +%N).tmp"
        
        # 检查缓存
        if [[ -f "$cache_file" && -r "$cache_file" ]]; then
            cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
            if [[ $cache_age -lt 21600 ]]; then
                cat "$cache_file" >> "$rules_file" 2>/dev/null || true
                echo "    └─ ✅ 使用缓存"
                ((success_count++))
                continue
            fi
        fi
        
        # 下载新文件（限制100MB）
        curl_output=$(mktemp)
        if curl --connect-timeout 10 --max-time 60 --retry 2 --max-filesize 104857600 -sSL "$url" -o "$temp_file" 2>"$curl_output"; then
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
            
            # 检测HTML错误页面
            if head -n 5 "$temp_file" | grep -qE '^(<!DOCTYPE|<html|<\?xml)' 2>/dev/null; then
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
            error_msg=$(cat "$curl_output" 2>/dev/null | head -n 1 | tr -cd '[:print:]' | head -c 100)
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
    
    [[ -s raw-rules.txt ]] && echo "  └─ 原始规则：$(wc -l < raw-rules.txt) 行"
else
    echo "  └─ ⚠️  无有效网络源" >&2
fi

echo "步骤3/7: 清洗与去重..."
if [[ -s raw-rules.txt ]]; then
    # 仅保留基础语法：||domain.com^ (不含路径、端口、参数，支持单字符域名)
    (grep '^\|\|' raw-rules.txt | \
    grep -E '^\|\|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^$' | \
    grep -v '^@@' | \
    sort -u > cleaned.txt) 2>/dev/null || true
    
    # 确保 cleaned.txt 存在
    [[ ! -f cleaned.txt ]] && touch cleaned.txt
    
    cleaned_count=$(wc -l < cleaned.txt 2>/dev/null || echo 0)
    echo "  └─ 清洗后：$cleaned_count 条"
else
    echo "  └─ ⚠️  raw-rules.txt 为空，跳过" >&2
    > cleaned.txt || touch cleaned.txt
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
> temp-dup.txt

if [[ -s cleaned.txt && -n "$blacklist_content" ]]; then
    set +e  # 允许 grep 未匹配
    
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        
        # 移除行尾注释并清理空白
        clean_rule="${rule%%\#*}"
        clean_rule=$(echo "$clean_rule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$clean_rule" ]] && continue
        
        # 标准化为 ||domain^ 格式
        normalized_rule="$clean_rule"
        [[ "$normalized_rule" != "||"* ]] && normalized_rule="||${normalized_rule}"
        [[ "$normalized_rule" != *"^" ]] && normalized_rule="${normalized_rule}^"
        
        # 完全匹配检测（基础规则对基础规则）
        if grep -Fxq "$normalized_rule" cleaned.txt 2>/dev/null; then
            echo "$rule" >> temp-dup.txt
            ((duplicate_count++))
        fi
    done <<< "$blacklist_content"
    
    set -e  # 恢复错误退出
fi

if [[ $duplicate_count -gt 0 ]]; then
    echo "  └─ 发现重复：$duplicate_count 条" >&2
    {
        echo "发现重复规则（${duplicate_count}条）："
        if [[ -s temp-dup.txt ]]; then
            nl -w 1 -s '. ' temp-dup.txt 2>/dev/null || cat -n temp-dup.txt
        fi
        echo ""
        echo "💡 建议：可从 blacklist.txt 移除以上规则，减少冗余"
    } >> "$REPORT_FILE"
else
    echo "  └─ 无重复" >&2
    echo "✅ 检测完成：无重复规则（状态良好）" >> "$REPORT_FILE"
fi
rm -f temp-dup.txt

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
total_rules=$(wc -l < cleaned.txt 2>/dev/null || echo 0)

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
set +e  # 允许文件不存在
extract_whitelist_lines "whitelist.txt" >> "$ADBLOCK_FILE" 2>/dev/null
extract_valid_lines "blacklist.txt" >> "$ADBLOCK_FILE" 2>/dev/null
if [[ -s cleaned.txt ]]; then
    cat cleaned.txt >> "$ADBLOCK_FILE" 2>/dev/null || {
        echo "❌ 错误：无法追加网络源规则" >&2
        exit 1
    }
fi
set -e  # 恢复错误退出

# 计算并替换文件大小占位符
file_size=$(du -h "$ADBLOCK_FILE" 2>/dev/null | cut -f1 || echo "0K")
# 使用临时文件方式，避免不同系统上sed -i的兼容性问题
sed "s|@@FILE_SIZE_PLACEHOLDER@@|$file_size|" "$ADBLOCK_FILE" > "$ADBLOCK_FILE.tmp" 2>/dev/null && mv "$ADBLOCK_FILE.tmp" "$ADBLOCK_FILE"

# 验证生成的规则文件
if [[ ! -s "$ADBLOCK_FILE" ]]; then
    echo "❌ 错误：生成的规则文件为空" >&2
    exit 1
fi

actual_rules=$( (grep -v '^!' "$ADBLOCK_FILE" | grep -v '^$' | wc -l) 2>/dev/null || echo 0)

if [[ $actual_rules -eq 0 ]]; then
    echo "❌ 错误：规则文件不包含有效规则" >&2
    exit 1
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

echo "步骤7/7: 清理临时文件..."
rm -f raw-rules.txt cleaned.txt temp-dup.txt

# 确保所有统计变量有效（在使用前设置默认值）
source_count=${source_count:-0}
success_count=${success_count:-0}
failed_count=${failed_count:-0}
total_rules=${total_rules:-0}
total_whitelist=${total_whitelist:-0}
total_blacklist=${total_blacklist:-0}
file_size=${file_size:-0K}

# 确保所有统计变量有效（在使用前设置默认值）
source_count=${source_count:-0}
success_count=${success_count:-0}
failed_count=${failed_count:-0}
total_rules=${total_rules:-0}
total_whitelist=${total_whitelist:-0}
total_blacklist=${total_blacklist:-0}
file_size=${file_size:-0K}

echo ""
echo "✅ 所有步骤处理完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 处理统计："
echo "  • 网络源：$source_count 个（成功 $success_count | 失败 $failed_count）"
echo "  • 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
echo "  • 文件大小：$file_size"
echo ""
echo "📁 生成文件："
echo "  ✓ $ADBLOCK_FILE"
echo "  ✓ $REPORT_FILE"
echo "  ✓ $README_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0

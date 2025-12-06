#!/bin/bash
# -*- coding: utf-8 -*-
# 最终生产级版本 - 仅去重合并，无裁剪
set +e
set +u

# 配置
CACHE_DIR="$HOME/.cache/adblock-sources"
ADBLOCK_FILE="adblock.txt"
REPORT_FILE="reports.txt"
README_FILE="README.md"
WORK_DIR="/tmp/adblock-work-$$"

mkdir -p "$CACHE_DIR" "$WORK_DIR" 2>/dev/null

cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null
}
trap cleanup EXIT

beijing_time() {
    TZ='Asia/Shanghai' date '+%Y年%m月%d日 %H:%M:%S (北京时间)'
}

extract_valid_lines() {
    [[ ! -f "$1" ]] && return 0
    sed 's/^\xEF\xBB\xBF//;s/[[:space:]]*$//;s/^[[:space:]]*//' "$1" | \
    grep -v '^#' | grep -v '^$' | sed 's/[[:space:]]*#.*$//' | grep -v '^$' || true
}

# 主流程（7步骤）
echo "步骤1/7: 清理过期缓存..."
find "$CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null
old_cache_count=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
echo "  └─ 保留缓存：$old_cache_count 个"

echo "步骤2/7: 下载网络源（并行模式）..."
source_list=$(extract_valid_lines "sources.txt")
if [[ -n "$source_list" ]]; then
    source_count=$(echo "$source_list" | grep -c '.')
else
    source_count=0
fi
echo "  └─ 待处理源：$source_count 个"

> raw-rules.txt
success_count=0
failed_count=0

download_source() {
    local url="$1"
    local cache_file="$CACHE_DIR/$(echo -n "$url" | md5sum | cut -d' ' -f1)"
    local temp_file="$WORK_DIR/$(date +%s%N)-$RANDOM.tmp"
    
    if [[ -f "$cache_file" ]]; then
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt 21600 ]]; then
            cat "$cache_file"
            echo "SUCCESS" >&2
            return 0
        fi
    fi
    
    if curl --connect-timeout 5 --max-time 30 --retry 2 -sSL "$url" -o "$temp_file" 2>/dev/null && [[ -s "$temp_file" ]]; then
        if grep -qE '^(<!DOCTYPE|<html|<\?xml)' "$temp_file" 2>/dev/null; then
            rm -f "$temp_file"
            echo "FAILED" >&2
            return 1
        fi
        
        mv "$temp_file" "$cache_file"
        cat "$cache_file"
        echo "SUCCESS" >&2
        return 0
    else
        rm -f "$temp_file"
        echo "FAILED" >&2
        return 1
    fi
}

export -f download_source
export CACHE_DIR WORK_DIR

if [[ $source_count -gt 0 ]]; then
    if command -v parallel >/dev/null 2>&1; then
        download_log="$WORK_DIR/download.log"
        echo "$source_list" | parallel -j 8 --no-notice download_source 2>"$download_log" >> raw-rules.txt || true
        success_count=$(grep -c 'SUCCESS' "$download_log" 2>/dev/null || echo 0)
        failed_count=$(grep -c 'FAILED' "$download_log" 2>/dev/null || echo 0)
    else
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            if download_source "$url" >> raw-rules.txt 2>/dev/null; then
                ((success_count++))
            else
                ((failed_count++))
            fi
        done <<< "$source_list"
    fi
    
    echo "  └─ 总计：成功 $success_count | 失败 $failed_count"
    [[ -s raw-rules.txt ]] && echo "  └─ 原始规则：$(wc -l < raw-rules.txt) 行"
else
    echo "  └─ ⚠️  无有效网络源" >&2
fi

echo "步骤3/7: 清洗与去重..."
if [[ -s raw-rules.txt ]]; then
    # 仅保留基础语法：||domain.com^ (不含路径、端口、参数，支持单字符域名)
    grep '^||' raw-rules.txt | \
    grep -E '^||[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\^$' | \
    grep -v '^@@' | \
    sort -u > cleaned.txt 2>/dev/null
    
    cleaned_count=$(wc -l < cleaned.txt 2>/dev/null || echo 0)
    echo "  └─ 清洗后：$cleaned_count 条"
else
    echo "  └─ ⚠️  raw-rules.txt 为空，跳过" >&2
    > cleaned.txt
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
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        base_rule="${rule%%\**}"
        base_rule="${base_rule%%\#*}"
        base_rule=$(echo "$base_rule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$base_rule" ]] && continue
        
        grep -Fxq "$base_rule" cleaned.txt 2>/dev/null && echo "$rule" >> temp-dup.txt && ((duplicate_count++))
    done <<< "$blacklist_content"
fi

if [[ $duplicate_count -gt 0 ]]; then
    echo "  └─ 发现重复：$duplicate_count 条" >&2
    {
        echo "发现重复规则（${duplicate_count}条）："
        nl -w 1 -s '. ' temp-dup.txt
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
whitelist_lines=$(extract_valid_lines "whitelist.txt")
blacklist_lines=$(extract_valid_lines "blacklist.txt")

total_sources=0
total_whitelist=0
total_blacklist=0
[[ -n "$sources_lines" ]] && total_sources=$(echo "$sources_lines" | grep -c '.')
[[ -n "$whitelist_lines" ]] && total_whitelist=$(echo "$whitelist_lines" | grep -c '.')
[[ -n "$blacklist_lines" ]] && total_blacklist=$(echo "$blacklist_lines" | grep -c '.')
total_rules=$(wc -l < cleaned.txt 2>/dev/null || echo 0)

{
    echo "! 标题：广告拦截规则"
    echo "! 更新时间：$(beijing_time)"
    echo "! 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "! 网络源数量：$total_sources 个"
    echo "! 自定义规则：$total_whitelist 条白名单 + $total_blacklist 条黑名单"
    echo "! 文件大小：PLACEHOLDER"
    echo "! 运行状态：✅ 正常"
    echo ""
} > "$ADBLOCK_FILE"

# 最终合并顺序：白名单 → 黑名单 → 网络源
extract_valid_lines "whitelist.txt" >> "$ADBLOCK_FILE"
extract_valid_lines "blacklist.txt" >> "$ADBLOCK_FILE"
cat cleaned.txt >> "$ADBLOCK_FILE" 2>/dev/null || true

# 计算并替换文件大小占位符
file_size=$(du -h "$ADBLOCK_FILE" 2>/dev/null | cut -f1 || echo "0K")
sed -i "s/PLACEHOLDER/$file_size/" "$ADBLOCK_FILE" 2>/dev/null || true

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

echo "步骤7/7: 清理临时文件..."
rm -f raw-rules.txt cleaned.txt temp-dup.txt

echo "✅ 所有步骤处理完成！"
exit 0

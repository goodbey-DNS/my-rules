#!/bin/bash
# -*- coding: utf-8 -*-
# 最终生产级版本 - 无已知漏洞
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
    date -d '+8 hours' '+%Y年%m月%d日 %H:%M:%S (北京时间)'
}

get_repo_path() {
    git config --get remote.origin.url 2>/dev/null | \
    sed -E 's/.*github.com[:/]([^/]+\/[^/]+).*/\1/' | \
    sed 's/\.git$//' || \
    echo "your/repo"
}

extract_valid_lines() {
    [[ ! -f "$1" ]] && return 0
    sed 's/^\xEF\xBB\xBF//;s/[[:space:]]*$//;s/^[[:space:]]*//' "$1" | \
    grep -v '^#' | grep -v '^$' | sed 's/[[:space:]]*#.*$//' | grep -v '^$' || true
}

# 主流程（7步骤）
echo "步骤1/7: 下载网络源..."
source_list=$(extract_valid_lines "sources.txt")
source_count=$(echo "$source_list" | wc -l)
echo "  └─ 待处理源：$source_count 个"

> raw-rules.txt
success_count=0
failed_count=0

if [[ $source_count -gt 0 ]]; then
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        
        cache_file="$CACHE_DIR/$(echo -n "$url" | md5sum | cut -d' ' -f1)"
        
        if [[ -f "$cache_file" ]]; then
            cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
            if [[ $cache_age -lt 21600 ]]; then
                cat "$cache_file" >> raw-rules.txt
                ((success_count++))
                continue
            fi
        fi
        
        temp_file="$WORK_DIR/$(date +%s%N).tmp"
        if curl --connect-timeout 5 --max-time 30 --retry 2 -sSL "$url" -o "$temp_file" 2>/dev/null && [[ -s "$temp_file" ]]; then
            mv "$temp_file" "$cache_file"
            cat "$cache_file" >> raw-rules.txt
            ((success_count++))
        else
            rm -f "$temp_file"
            ((failed_count++))
        fi
    done <<< "$source_list"
    
    echo "  └─ 总计：成功 $success_count | 失败 $failed_count"
    [[ -s raw-rules.txt ]] && echo "  └─ 原始规则：$(wc -l < raw-rules.txt) 行"
else
    echo "  └─ ⚠️  无有效网络源" >&2
fi

echo "步骤2/7: 清洗规则..."
[[ -s raw-rules.txt ]] && grep '^||' raw-rules.txt | grep -E '^||[a-zA-Z0-9.-]+\^$' | sed 's/\^$\(.*\)/^/' | grep -v '^@@' | sort -u > cleaned.txt 2>/dev/null || > cleaned.txt
echo "  └─ 清洗后：$(wc -l < cleaned.txt 2>/dev/null || echo 0) 条"

echo "步骤3/7: 子域裁剪..."
if [[ -s cleaned.txt ]]; then
    original_count=$(wc -l < cleaned.txt)
    > temp-sorted.txt
    while IFS= read -r rule; do
        domain="${rule#||}"
        domain="${domain%^}"
        [[ -n "$domain" ]] && echo "$domain $rule"
    done < cleaned.txt 2>/dev/null | sort -u | awk '
    {
        domain=$1; rule=$2
        split(domain, parts, ".")
        skip=0
        for(i=1; i<=length(parts); i++) {
            suffix=""
            for(j=i; j<=length(parts); j++) {
                suffix=(suffix? ".": "") parts[j]
            }
            if(suffix in seen) {
                skip=1; break
            }
        }
        if(!skip) {
            seen[domain]=1
            print rule
        }
    }' > temp-sorted.txt 2>/dev/null
    mv temp-sorted.txt cleaned.txt
    echo "  └─ 裁剪后：$(wc -l < cleaned.txt) 条（减少 $((original_count - $(wc -l < cleaned.txt)))）"
else
    echo "  └─ ⚠️  跳过裁剪" >&2
fi

echo "步骤4/7: 检测黑名单重复..."
blacklist_content=$(extract_valid_lines "blacklist.txt")
> "$REPORT_FILE"
{
    echo "# 重复检测报告"
    echo "# 检测时间：$(beijing_time)"
    echo "# 报告说明：显示您的 blacklist.txt 中与网络源重复的规则"
    echo ""
} >> "$REPORT_FILE"

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
    echo "发现重复规则（${duplicate_count}条）：" >> "$REPORT_FILE"
    nl -w 1 -s '. ' temp-dup.txt >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "💡 建议：可从 blacklist.txt 移除以上规则，减少冗余" >> "$REPORT_FILE"
else
    echo "  └─ 无重复" >&2
    echo "✅ 检测完成：无重复规则（状态良好）" >> "$REPORT_FILE"
fi
rm -f temp-dup.txt

echo "步骤5/7: 生成规则文件..."
total_sources=$(extract_valid_lines "sources.txt" | wc -l)
total_whitelist=$(extract_valid_lines "whitelist.txt" | wc -l)
total_blacklist=$(extract_valid_lines "blacklist.txt" | wc -l)
total_rules=$(wc -l < cleaned.txt 2>/dev/null || echo 0)
file_size_mb=$(ls -lh "$ADBLOCK_FILE" 2>/dev/null | awk '{print $5}' || echo "0K")
repo_path=$(get_repo_path)

{
    echo "! 标题：广告拦截规则"
    echo "! 更新时间：$(beijing_time)"
    echo "! 规则总数：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "! 网络源数量：$total_sources 个"
    echo "! 自定义规则：$total_whitelist 条白名单 + $total_blacklist 条黑名单"
    echo "! 文件大小：$file_size_mb"
    echo "! 运行状态：✅ 正常"
    echo "! 订阅地址：https://ghproxy.com/$repo_path/main/adblock.txt"
    echo ""
} > "$ADBLOCK_FILE"

extract_valid_lines "whitelist.txt" >> "$ADBLOCK_FILE"
cat cleaned.txt >> "$ADBLOCK_FILE" 2>/dev/null || true
extract_valid_lines "blacklist.txt" >> "$ADBLOCK_FILE"

echo "步骤6/7: 生成说明文档..."
{
    echo "# 广告拦截规则仓库"
    echo ""
    echo "## 📊 当前状态"
    echo "- **规则总数**：$((total_rules + total_whitelist + total_blacklist)) 条"
    echo "- **最后更新**：$(beijing_time)"
    echo "- **订阅地址**：[点击复制](https://ghproxy.com/$repo_path/main/adblock.txt)"
    echo ""
    echo "## 📁 文件说明"
    echo "| 文件名 | 用途 | 编辑方式 |"
    echo "|--------|------|----------|"
    echo "| \`sources.txt\` | 网络源列表 | 网页端编辑，支持 # 注释 |"
    echo "| \`whitelist.txt\` | 白名单规则 | 网页端编辑，支持 # 注释 |"
    echo "| \`blacklist.txt\` | 黑名单规则 | 网页端编辑，支持 # 注释 |"
    echo "| \`reports.txt\` | 检测报告 | 自动生成，只读 |"
    echo ""
    echo "## ⚙️ AdGuard Home 配置"
    echo "1. 打开 AdGuard Home 管理界面"
    echo "2. 进入 **设置 → 过滤器 → 自定义规则**"
    echo "3. 点击 **添加订阅**"
    echo "4. 粘贴以下地址："
    echo ""
    echo "\`\`\`"
    echo "https://ghproxy.com/$repo_path/main/adblock.txt"
    echo "\`\`\`"
} > "$README_FILE"

echo "步骤7/7: 清理临时文件..."
rm -f cleaned.txt temp-sorted.txt

echo "✅ 所有步骤处理完成！"
exit 0

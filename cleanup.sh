#!/bin/bash

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 需要保留的文件列表
KEEP_FILES=(
    "safetable.sh"
    "CentOS-Base.repo"
    "README.md"
    "cleanup.sh"
)

# 清理冗余文件
echo "正在清理冗余文件..."

# 遍历目录中的所有文件
for file in "$SCRIPT_DIR"/*; do
    filename=$(basename "$file")
    
    # 检查是否为目录
    if [ -d "$file" ] && [ "$filename" != ".git" ]; then
        echo "删除目录: $filename"
        rm -rf "$file"
        continue
    fi
    
    # 检查是否为需要保留的文件
    keep=false
    for keep_file in "${KEEP_FILES[@]}"; do
        if [ "$filename" == "$keep_file" ]; then
            keep=true
            break
        fi
    done
    
    # 如果不是需要保留的文件，则删除
    if [ "$keep" == false ]; then
        echo "删除文件: $filename"
        rm -f "$file"
    fi
done

echo "清理完成！"
echo "保留的文件:"
for keep_file in "${KEEP_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$keep_file" ]; then
        echo "- $keep_file"
    fi
done

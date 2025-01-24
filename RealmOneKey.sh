#!/bin/bash

# 当前脚本版本号
VERSION="1.5.2"

# 定义颜色变量
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color
BOLD="\033[1m"
UNDERLINE="\033[4m"

# 初始化状态变量
realm_status="未安装"
realm_status_color="$RED"

# 版本号比较函数
compare_versions() {
    local version1=$1
    local version2=$2
    
    # 移除可能的 'v' 前缀
    version1=${version1#v}
    version2=${version2#v}
    
    # 将版本号分割为数组
    IFS='.' read -ra ver1 <<< "$version1"
    IFS='.' read -ra ver2 <<< "$version2"
    
    # 确保两个数组长度相同
    while [ ${#ver1[@]} -lt ${#ver2[@]} ]; do
        ver1+=("0")
    done
    while [ ${#ver2[@]} -lt ${#ver1[@]} ]; do
        ver2+=("0")
    done
    
    # 比较每个部分
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [ "${ver1[i]}" -gt "${ver2[i]}" ]; then
            return 1
        elif [ "${ver1[i]}" -lt "${ver2[i]}" ]; then
            return 2
        fi
    done
    
    return 0
}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo "此脚本需要root权限才能运行，可以使用 'su -' 切换到root用户再运行。"
    exit 1
fi

# 检查realm是否已安装
if [ -f "/root/realm/realm" ]; then
    echo "检测到realm已安装。"
    realm_status="已安装"
    realm_status_color="\033[0;32m" # 绿色
else
    echo "realm未安装。"
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
fi

# 获取realm版本的函数
get_realm_version() {
    if [ -f "/root/realm/realm" ]; then
        local version=$(/root/realm/realm -v 2>/dev/null | grep -oP '(?i)realm \K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        echo "$version"
    else
        echo "未安装"
    fi
}

# 检查realm服务状态的函数
check_realm_service_status() {
    # 检查服务是否存在
    if ! systemctl list-unit-files | grep -q realm.service; then
        echo -e "\033[0;31m未安装\033[0m"
        return 1
    fi
    
    # 检查服务状态
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m运行中\033[0m"
        return 0
    else
        echo -e "\033[0;31m未运行\033[0m"
        return 1
    fi
}

# 检查服务详细状态
check_service_details() {
    local service_name="realm"
    local version=$(get_realm_version)
    
    echo -e "\n服务详细状态："
    echo "=================="
    echo -e "Realm 版本: \033[0;32m$version\033[0m"
    
    # 检查开机启动状态
    echo -n "开机启动: "
    if systemctl is-enabled --quiet realm; then
        echo -e "\033[0;32m已启用\033[0m"
    else
        echo -e "\033[0;31m未启用\033[0m"
    fi
    echo "=================="
    
    if ! systemctl is-active --quiet "$service_name"; then
        echo -e "\033[0;31m服务未运行\033[0m"
        read -n 1 -s -r -p "按任意键继续... (q退出)" key
        if [ "$key" = "q" ]; then
            echo -e "\n退出查看"
            return
        fi
        return
    fi

    systemctl status "$service_name"
    read -n 1 -s -r -p "按任意键继续... (q退出)" key
    if [ "$key" = "q" ]; then
        echo -e "\n退出查看"
    fi
}

# 部署realm的函数
deploy_realm() {
    if [ -f "/root/realm/realm" ]; then
        echo "检测到已安装realm，是否重新安装？"
        read -p "输入 Y 确认重新安装，任意键取消: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "取消安装。"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
    fi

    echo "开始安装realm..."
    
    # 创建目录
    mkdir -p /root/realm
    cd /root/realm || exit
    
    # 下载最新版本
    echo "正在下载realm..."
    if ! wget -q --show-progress https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-musl.tar.gz; then
        echo -e "\033[0;31m下载失败\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 验证下载文件
    if [ ! -f "realm-x86_64-unknown-linux-musl.tar.gz" ]; then
        echo -e "\033[0;31m下载文件不存在\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 解压文件
    echo "正在解压文件..."
    if ! tar -xzf realm-x86_64-unknown-linux-musl.tar.gz; then
        echo -e "\033[0;31m解压失败\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 验证解压后的文件
    if [ ! -f "realm" ]; then
        echo -e "\033[0;31m未找到realm可执行文件\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 设置执行权限
    chmod +x realm
    
    # 获取版本号
    local version=$(get_realm_version)
    
    # 创建服务文件
    echo "正在创建服务文件..."
    cat > /etc/systemd/system/realm.service << 'EOF'
[Unit]
Description=realm
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=/root/realm/realm -c /root/realm/config.toml
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    
    # 创建基础配置文件（如果不存在）
    if [ ! -f "/root/realm/config.toml" ]; then
        echo "正在创建配置文件..."
        cat > /root/realm/config.toml << 'EOF'
[network]
no_tcp = false
use_udp = true
EOF
    fi
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启用并启动服务
    systemctl enable realm
    if ! systemctl start realm; then
        echo -e "\033[0;31m服务启动失败\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 清理下载文件
    rm -f realm-x86_64-unknown-linux-musl.tar.gz
    
    echo -e "\n安装完成！"
    echo "=================="
    echo -e "Realm 版本: \033[0;32m$version\033[0m"
    echo -e "服务状态: \033[0;32m已启动\033[0m"
    echo "=================="
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 备份配置文件的函数
backup_config() {
    local backup_dir="/root/realm/backups"
    local config_file="/root/realm/config.toml"
    local max_backups=5
    
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        echo -e "\033[0;31m错误：未找到配置文件\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 创建备份目录并设置权限
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    
    # 检查目录权限
    if [ ! -w "$backup_dir" ]; then
        echo -e "\033[0;31m错误：备份目录无写入权限\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 生成备份文件名（带时间戳）
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$backup_dir/config_${timestamp}.toml"
    
    # 复制配置文件
    cp "$config_file" "$backup_file"
    
    # 检查备份是否成功
    if [ $? -eq 0 ]; then
        echo -e "\033[0;32m配置文件已备份到：$backup_file\033[0m"
        
        # 限制备份文件数量
        local backup_count=$(ls -1 "$backup_dir"/config_*.toml 2>/dev/null | wc -l)
        if [ "$backup_count" -gt "$max_backups" ]; then
            echo "清理旧备份文件..."
            ls -t "$backup_dir"/config_*.toml | tail -n +$((max_backups + 1)) | xargs rm -f
        fi
    else
        echo -e "\033[0;31m备份失败\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    read -n 1 -s -r -p "按任意键继续..."
    return 0
}

# 配置文件备份和恢复函数
backup_restore_config() {
    local action=$1
    local backup_dir="/root/realm/backups"
    local config_file="/root/realm/config.toml"
    
    case $action in
        "backup")
            backup_config
            ;;
        "restore")
            if [ ! -d "$backup_dir" ]; then
                echo -e "\033[0;31m错误：未找到备份目录\033[0m"
                read -n 1 -s -r -p "按任意键继续..."
                return
            fi
            
            # 列出所有备份文件
            echo "可用的备份文件："
            local i=1
            local backup_files=()
            while IFS= read -r file; do
                echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
                backup_files+=("$file")
                ((i++))
            done < <(ls -t "$backup_dir"/config_*.toml 2>/dev/null)
            
            if [ ${#backup_files[@]} -eq 0 ]; then
                echo -e "\033[0;31m没有找到可用的备份文件\033[0m"
                read -n 1 -s -r -p "按任意键继续..."
                return
            fi
            
            # 选择要恢复的备份
            read -p "请选择要恢复的备份文件编号（输入0取消）: " choice
            if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
                echo -e "\033[0;31m无效的选择\033[0m"
                read -n 1 -s -r -p "按任意键继续..."
                return
            fi
            
            if [ "$choice" -eq 0 ]; then
                echo "取消恢复"
                read -n 1 -s -r -p "按任意键继续..."
                return
            fi
            
            local selected_backup="${backup_files[$((choice-1))]}"
            
            # 验证备份文件格式
            if ! verify_config "$selected_backup"; then
                echo -e "\033[0;31m错误：选择的备份文件格式无效\033[0m"
                read -n 1 -s -r -p "按任意键继续..."
                return
            fi
            
            # 备份当前配置
            if [ -f "$config_file" ]; then
                cp "$config_file" "${config_file}.$(date +%s).bak"
            fi
            
            # 恢复配置
            cp "$selected_backup" "$config_file"
            if [ $? -eq 0 ]; then
                echo -e "\033[0;32m配置已恢复\033[0m"
                
                # 如果服务正在运行，重启服务
                if systemctl is-active --quiet realm; then
                    echo "正在重启realm服务..."
                    systemctl restart realm
                    if [ $? -eq 0 ]; then
                        echo -e "\033[0;32m服务已重启\033[0m"
                    else
                        echo -e "\033[0;31m服务重启失败\033[0m"
                    fi
                fi
            else
                echo -e "\033[0;31m恢复失败\033[0m"
            fi
            ;;
        *)
            echo -e "\033[0;31m无效的操作\033[0m"
            ;;
    esac
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 启用realm开机启动
enable_realm_autostart() {
    echo "正在启用realm开机启动..."
    if systemctl enable realm; then
        echo -e "\033[0;32m已启用realm开机启动\033[0m"
    else
        echo -e "\033[0;31m启用失败，请检查服务状态或权限\033[0m"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 禁用realm开机启动
disable_realm_autostart() {
    echo "正在禁用realm开机启动..."
    if systemctl disable realm; then
        echo -e "\033[0;32m已禁用realm开机启动\033[0m"
    else
        echo -e "\033[0;31m禁用失败，请检查服务状态或权限\033[0m"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 添加转发规则的函数
add_forward() {
    echo -e "\n添加转发规则 (在任意步骤输入 q 可退出)"
    echo "=================="
    
    # 获取本地监听地址
    local listen_addr
    while true; do
        read -p "请输入本地监听地址 (默认 0.0.0.0，输入 q 退出): " listen_addr
        if [ "$listen_addr" = "q" ]; then
            echo "取消添加转发规则。"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
        
        if [ -z "$listen_addr" ]; then
            listen_addr="0.0.0.0"
            break
        elif validate_ip "$listen_addr"; then
            break
        else
            echo -e "\033[0;31m无效的IP地址格式\033[0m"
        fi
    done
    
    # 获取本地端口
    local listen_port
    while true; do
        read -p "请输入本地端口 (1-65535，输入 q 退出): " listen_port
        if [ "$listen_port" = "q" ]; then
            echo "取消添加转发规则。"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
        
        if validate_port "$listen_port"; then
            break
        else
            echo -e "\033[0;31m无效的端口号，请输入 1-65535 之间的数字\033[0m"
        fi
    done
    
    # 获取远程地址
    local remote_addr
    while true; do
        read -p "请输入远程地址 (输入 q 退出): " remote_addr
        if [ "$remote_addr" = "q" ]; then
            echo "取消添加转发规则。"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
        
        if validate_ip "$remote_addr"; then
            break
        else
            echo -e "\033[0;31m无效的IP地址格式\033[0m"
        fi
    done
    
    # 获取远程端口
    local remote_port
    while true; do
        read -p "请输入远程端口 (1-65535，输入 q 退出): " remote_port
        if [ "$remote_port" = "q" ]; then
            echo "取消添加转发规则。"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
        
        if validate_port "$remote_port"; then
            break
        else
            echo -e "\033[0;31m无效的端口号，请输入 1-65535 之间的数字\033[0m"
        fi
    done
    
    # 确认添加
    echo -e "\n即将添加以下转发规则："
    echo "本地 $listen_addr:$listen_port -> 远程 $remote_addr:$remote_port"
    read -p "确认添加？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消添加转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 备份配置文件
    if [ -f "/root/realm/config.toml" ]; then
        cp "/root/realm/config.toml" "/root/realm/config.toml.bak"
    else
        # 如果配置文件不存在，创建基本配置
        echo "[network]
no_tcp = false
use_udp = true" > "/root/realm/config.toml"
    fi
    
    # 添加新的转发规则
    echo -e "\n[[endpoints]]
listen = \"$listen_addr:$listen_port\"
remote = \"$remote_addr:$remote_port\"" >> "/root/realm/config.toml"
    
    if [ $? -eq 0 ]; then
        echo -e "\033[0;32m转发规则添加成功\033[0m"
        
        # 重启服务以应用更改
        echo "正在重启服务以应用更改..."
        if ! systemctl restart realm; then
            echo -e "\033[0;31m警告：服务重启失败，请手动重启服务\033[0m"
        else
            echo -e "\033[0;32m服务已重启\033[0m"
            rm -f "/root/realm/config.toml.bak"
        fi
    else
        echo -e "\033[0;31m错误：无法添加转发规则\033[0m"
        if [ -f "/root/realm/config.toml.bak" ]; then
            echo "正在恢复备份..."
            mv "/root/realm/config.toml.bak" "/root/realm/config.toml"
        fi
    fi
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 查看转发规则的函数
show_forwards() {
    if [ ! -f "/root/realm/config.toml" ]; then
        echo "配置文件不存在，尚未添加任何转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    echo "当前所有转发规则："
    echo "=================="
    
    # 使用 awk 提取并显示所有规则
    awk '
    BEGIN { rule_count = 0; }
    /\[\[endpoints\]\]/ { 
        in_endpoint = 1; 
        next;
    }
    in_endpoint && /listen *=/ {
        gsub(/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"/, "");
        gsub(/"[[:space:]]*$/, "");
        listen = $0;
    }
    in_endpoint && /remote *=/ {
        gsub(/^[[:space:]]*remote[[:space:]]*=[[:space:]]*"/, "");
        gsub(/"[[:space:]]*$/, "");
        remote = $0;
        rule_count++;
        printf "%d) 本地端口 %s -> %s\n", rule_count, listen, remote;
        in_endpoint = 0;
    }
    END {
        if (rule_count == 0) {
            print "没有发现任何转发规则。";
        }
    }' "/root/realm/config.toml"
    
    echo "=================="
    read -n 1 -s -r -p "按任意键继续..."
}

# 删除转发规则的函数
delete_forward() {
    if [ ! -f "/root/realm/config.toml" ]; then
        echo "配置文件不存在，没有可删除的转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 创建临时文件
    local temp_file=$(mktemp)
    local rules_file=$(mktemp)
    local rules_count=0
    
    echo "当前转发规则："
    echo "=================="
    
    # 使用 awk 提取规则并保存到临时文件
    awk '
    BEGIN { count = 0; }
    /\[\[endpoints\]\]/ { 
        in_endpoint = 1;
        listen = "";
        remote = "";
        next;
    }
    in_endpoint && /listen *=/ {
        gsub(/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"/, "");
        gsub(/"[[:space:]]*$/, "");
        listen = $0;
    }
    in_endpoint && /remote *=/ {
        gsub(/^[[:space:]]*remote[[:space:]]*=[[:space:]]*"/, "");
        gsub(/"[[:space:]]*$/, "");
        remote = $0;
        count++;
        print listen "\t" remote;
        in_endpoint = 0;
    }
    END {
        exit count;
    }' "/root/realm/config.toml" > "$rules_file"
    
    rules_count=$?
    
    if [ $rules_count -eq 0 ]; then
        echo "没有发现任何转发规则。"
        rm -f "$temp_file" "$rules_file"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 显示规则列表
    local rule_number=1
    while IFS=$'\t' read -r listen remote; do
        echo "$rule_number) 本地端口 $listen -> $remote"
        ((rule_number++))
    done < "$rules_file"
    
    echo "=================="
    
    # 获取用户输入
    local valid_input=0
    local choice
    while [ $valid_input -eq 0 ]; do
        read -p "请输入要删除的规则编号 (1-$rules_count)，输入 0 取消: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ $choice -ge 0 ] && [ $choice -le $rules_count ]; then
                valid_input=1
            else
                echo "无效的选择，请输入 0-$rules_count 之间的数字。"
            fi
        else
            echo "无效的输入，请输入数字。"
        fi
    done
    
    if [ $choice -eq 0 ]; then
        echo "取消删除操作。"
        rm -f "$temp_file" "$rules_file"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 备份配置文件
    cp "/root/realm/config.toml" "/root/realm/config.toml.bak"
    
    # 创建新的配置文件
    echo "[network]
no_tcp = false
use_udp = true" > "$temp_file"
    
    # 重建配置文件，跳过要删除的规则
    local current_rule=0
    while IFS=$'\t' read -r listen remote; do
        ((current_rule++))
        if [ $current_rule -ne $choice ]; then
            echo -e "\n[[endpoints]]
listen = \"$listen\"
remote = \"$remote\"" >> "$temp_file"
        fi
    done < "$rules_file"
    
    # 替换原配置文件
    if ! mv "$temp_file" "/root/realm/config.toml"; then
        echo -e "\033[0;31m错误：无法更新配置文件\033[0m"
        echo "正在恢复备份..."
        mv "/root/realm/config.toml.bak" "/root/realm/config.toml"
        rm -f "$temp_file" "$rules_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 删除临时文件和备份
    rm -f "$temp_file" "$rules_file" "/root/realm/config.toml.bak"
    
    echo -e "\033[0;32m规则已删除\033[0m"
    
    # 重启服务以应用更改
    echo "正在重启服务以应用更改..."
    if ! systemctl restart realm; then
        echo -e "\033[0;31m警告：服务重启失败，请手动重启服务\033[0m"
    else
        echo -e "\033[0;32m服务已重启\033[0m"
    fi
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 启动服务的函数
start_service() {
    if ! systemctl is-active --quiet realm; then
        systemctl start realm
        echo "realm 服务已启动"
    else
        echo "realm 服务已经在运行中"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 停止服务的函数
stop_service() {
    if systemctl is-active --quiet realm; then
        systemctl stop realm
        echo "realm 服务已停止"
    else
        echo "realm 服务未在运行"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 重启服务的函数
restart_service() {
    systemctl restart realm
    echo "realm 服务已重启"
    read -n 1 -s -r -p "按任意键继续..."
}

# 卸载realm的函数
uninstall_realm() {
    echo "准备卸载realm..."
    read -p "确定要卸载realm吗？这将删除所有相关文件和配置(y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "取消卸载"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 备份配置文件
    if [ -f "/root/realm/config.toml" ]; then
        echo "备份当前配置..."
        backup_config
    fi

    # 停止服务
    echo "停止realm服务..."
    systemctl stop realm 2>/dev/null
    
    # 等待服务完全停止
    echo "等待服务停止..."
    local count=0
    while systemctl is-active --quiet realm && [ $count -lt 10 ]; do
        sleep 1
        ((count++))
    done
    
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;31m警告：服务无法完全停止\033[0m"
        read -p "是否强制继续卸载？(y/n): " force
        if [[ $force != "y" && $force != "Y" ]]; then
            echo "取消卸载"
            read -n 1 -s -r -p "按任意键继续..."
            return
        fi
    fi
    
    # 禁用服务
    echo "禁用realm服务..."
    systemctl disable realm 2>/dev/null
    
    # 删除服务文件
    echo "删除服务文件..."
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    
    # 删除realm程序和配置（保留备份）
    echo "删除realm程序和配置文件..."
    if [ -d "/root/realm/backups" ]; then
        mv "/root/realm/backups" "/root/realm_backups"
    fi
    rm -rf /root/realm
    if [ -d "/root/realm_backups" ]; then
        mv "/root/realm_backups" "/root/realm/backups"
    fi
    
    # 删除下载的脚本文件
    echo "删除脚本文件..."
    rm -f /tmp/RealmOneKey*.sh
    
    # 删除临时文件
    echo "清理临时文件..."
    rm -f /tmp/realm_*
    rm -f /tmp/RealmOneKey_*.sh
    
    # 更新状态变量
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
    
    echo -e "\033[0;32m卸载完成！\033[0m"
    if [ -d "/root/realm/backups" ]; then
        echo "配置备份保留在：/root/realm/backups"
    fi
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 更新脚本的函数
update_script() {
    echo "正在检查更新..."
    echo "当前版本：$VERSION"
    
    # 添加随机数以避免缓存
    local timestamp=$(date +%s)
    local temp_file="/tmp/RealmOneKey_${timestamp}.sh"
    local config_file="/root/realm/config.toml"
    
    echo "正在从GitHub获取最新版本..."
    # 添加no-cache参数避免缓存，并输出详细信息
    if ! curl -s -H "Cache-Control: no-cache" -o "$temp_file" "https://raw.githubusercontent.com/xspoco/RealmPortForwarding/refs/heads/main/RealmOneKey.sh?_=${timestamp}"; then
        echo "更新失败：无法连接到更新服务器"
        echo "curl错误代码：$?"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo "更新失败：下载的文件无效"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    # 显示下载的文件内容中的版本号行
    echo "远程文件版本号行："
    grep "^VERSION=" "$temp_file"
    
    # 提取远程版本号
    REMOTE_VERSION=$(grep "^VERSION=" "$temp_file" | cut -d'"' -f2)
    
    if [ -z "$REMOTE_VERSION" ]; then
        echo "无法获取远程版本号"
        echo "远程文件内容预览（前5行）："
        head -n 5 "$temp_file"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    echo "最新版本：$REMOTE_VERSION"
    
    # 使用版本比较函数
    compare_versions "$VERSION" "$REMOTE_VERSION"
    local compare_result=$?
    
    case $compare_result in
        0) 
            echo "当前已是最新版本！"
            echo "如果你确定远程有更新，请尝试以下操作："
            echo "1. 等待几分钟后再试（GitHub可能需要时间更新缓存）"
            echo "2. 使用浏览器直接访问脚本地址检查版本"
            rm -f "$temp_file"
            read -n 1 -s -r -p "按任意键继续..."
            return 0
            ;;
        1)
            echo "当前版本比远程版本更新，可能是测试版本"
            read -p "是否仍要更新到远程版本？(Y/N): " confirm
            ;;
        2)
            echo "发现新版本"
            read -p "是否更新？(Y/N): " confirm
            ;;
    esac
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消更新"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 0
    fi
    
    # 备份当前脚本和配置
    echo "备份当前配置..."
    if [ -f "$config_file" ]; then
        backup_config
    fi
    cp "$0" "${0}.backup"
    
    # 替换当前脚本
    if ! mv "$temp_file" "$0"; then
        echo "更新失败：无法替换脚本文件"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    chmod +x "$0"
    echo "脚本已更新完成！"
    echo "正在重启脚本..."
    exec "$0"
}

# 管理开机自启动的函数
manage_autostart() {
    local action=$1
    case $action in
        "enable")
            if systemctl is-enabled --quiet realm; then
                echo -e "\033[0;33mrealm服务已经设置为开机自启动\033[0m"
            else
                systemctl enable realm
                if [ $? -eq 0 ]; then
                    echo -e "\033[0;32m已成功设置realm服务开机自启动\033[0m"
                else
                    echo -e "\033[0;31m设置开机自启动失败\033[0m"
                fi
            fi
            ;;
        "disable")
            if ! systemctl is-enabled --quiet realm; then
                echo -e "\033[0;33mrealm服务已经禁用开机自启动\033[0m"
            else
                systemctl disable realm
                if [ $? -eq 0 ]; then
                    echo -e "\033[0;32m已成功禁用realm服务开机自启动\033[0m"
                else
                    echo -e "\033[0;31m禁用开机自启动失败\033[0m"
                fi
            fi
            ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
}

# 验证配置文件格式
verify_config() {
    local config_file="$1"
    # 检查文件是否为空
    if [ ! -s "$config_file" ]; then
        return 1
    fi
    
    # 检查基本的TOML格式（检查是否包含必要的字段）
    if ! grep -q "^\[.*\]" "$config_file" || ! grep -q "^port.*=.*[0-9]" "$config_file"; then
        return 1
    fi
    
    return 0
}

# 验证IP地址格式
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a ip_parts <<< "$ip"
        for part in "${ip_parts[@]}"; do
            if [ "$part" -gt 255 ] || [ "$part" -lt 0 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 验证端口号
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# 显示菜单的函数
show_menu() {
    clear
    local GREEN="\033[0;32m"
    local YELLOW="\033[1;33m"
    local RED="\033[0;31m"
    local CYAN="\033[0;36m"
    local NC="\033[0m" # No Color
    local BOLD="\033[1m"
    local UNDERLINE="\033[4m"
    
    # 标题
    echo -e "\n${YELLOW}${BOLD}Realm 一键转发脚本 ${NC}${YELLOW}v${VERSION}${NC}\n"
    
    # 状态栏
    echo -e "${UNDERLINE}系统状态${NC}"
    echo -e "  运行状态: ${realm_status_color}${realm_status}${NC}"
    echo -e "  转发状态: $(check_realm_service_status)"
    echo -e "  Realm 版本: $(get_realm_version)"
    echo
    
    # 基础功能
    echo -e "${CYAN}${BOLD}基础功能${NC}"
    echo -e "  ${GREEN}1${NC}. 部署环境          ${GREEN}2${NC}. 添加转发"
    echo -e "  ${GREEN}3${NC}. 查看转发规则      ${GREEN}4${NC}. 删除转发"
    echo
    
    # 服务控制
    echo -e "${CYAN}${BOLD}服务控制${NC}"
    echo -e "  ${GREEN}5${NC}. 启动服务          ${GREEN}6${NC}. 停止服务"
    echo -e "  ${GREEN}7${NC}. 重启服务          ${GREEN}8${NC}. 查看详细状态"
    echo
    
    # 系统管理
    echo -e "${CYAN}${BOLD}系统管理${NC}"
    echo -e "  ${GREEN}9${NC}. 一键卸载          ${GREEN}10${NC}. 检查更新"
    echo -e "  ${GREEN}11${NC}. 备份配置         ${GREEN}12${NC}. 恢复配置"
    echo -e "  ${GREEN}13${NC}. 其他选项"
    echo
    
    # 退出选项
    echo -e "  ${RED}0${NC}. 退出脚本"
    echo
    
    # 输入提示
    echo -n -e "${YELLOW}请输入选项编号: ${NC}"
}

# 主循环
while true; do
    show_menu
    read -r choice
    echo
    
    case $choice in
        1)
            deploy_realm
            ;;
        2)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再添加转发规则${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            add_forward
            ;;
        3)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再查看转发规则${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            show_forwards
            ;;
        4)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再删除转发规则${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            delete_forward
            ;;
        5)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再启动服务${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            start_service
            ;;
        6)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再停止服务${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            stop_service
            ;;
        7)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再重启服务${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            restart_service
            ;;
        8)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}请先安装 Realm（选项1）再查看服务状态${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            check_service_details
            ;;
        9)
            if [ ! -f "/root/realm/realm" ]; then
                echo -e "${RED}Realm 未安装，无需卸载${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            uninstall_realm
            ;;
        10)
            update_script
            ;;
        11)
            if [ ! -f "/root/realm/config.toml" ]; then
                echo -e "${RED}没有找到配置文件，无法备份${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            backup_config
            ;;
        12)
            if [ ! -d "/root/realm/backups" ]; then
                echo -e "${RED}没有找到备份文件夹，无法恢复${NC}"
                read -n 1 -s -r -p "按任意键继续..."
                continue
            fi
            backup_restore_config "restore"
            ;;
        13)
            echo -e "\n${CYAN}${BOLD}其他选项${NC}"
            echo -e "  ${GREEN}1${NC}. 启用realm开机启动"
            echo -e "  ${GREEN}2${NC}. 禁用realm开机启动"
            echo -n -e "${YELLOW}请输入选项编号: ${NC}"
            read -r sub_choice
            case $sub_choice in
                1)
                    enable_realm_autostart
                    ;;
                2)
                    disable_realm_autostart
                    ;;
                *)
                    echo -e "\033[0;31m无效的选项\033[0m"
                    ;;
            esac
            ;;
        0)
            echo -e "${GREEN}感谢使用！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择${NC}"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
    esac
done

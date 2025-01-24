#!/bin/bash

# 当前脚本版本号
VERSION="1.2.1"

# 版本号比较函数
compare_versions() {
    local ver1=$1
    local ver2=$2
    
    # 移除可能的'v'前缀
    ver1=${ver1#v}
    ver2=${ver2#v}
    
    # 将版本号分割为数组
    IFS='.' read -ra VER1 <<< "$ver1"
    IFS='.' read -ra VER2 <<< "$ver2"
    
    # 比较每个部分
    for ((i=0; i<${#VER1[@]} && i<${#VER2[@]}; i++)); do
        if ((10#${VER1[i]} > 10#${VER2[i]})); then
            return 1  # ver1 大于 ver2
        elif ((10#${VER1[i]} < 10#${VER2[i]})); then
            return 2  # ver1 小于 ver2
        fi
    done
    
    # 如果前面都相等，比较长度
    if ((${#VER1[@]} > ${#VER2[@]})); then
        return 1  # ver1 大于 ver2
    elif ((${#VER1[@]} < ${#VER2[@]})); then
        return 2  # ver1 小于 ver2
    else
        return 0  # 版本相等
    fi
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

# 检查realm服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m启用\033[0m" # 绿色
    else
        echo -e "\033[0;31m未启用\033[0m" # 红色
    fi
}

# 配置文件备份和恢复函数
backup_restore_config() {
    local action=$1
    local backup_dir="/root/realm/backups"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    case $action in
        "backup")
            # 创建备份目录
            mkdir -p "$backup_dir"
            if [ -f "/root/realm/config.toml" ]; then
                cp "/root/realm/config.toml" "$backup_dir/config_$timestamp.toml"
                echo "配置已备份到: $backup_dir/config_$timestamp.toml"
            else
                echo "没有找到配置文件，无法备份"
            fi
            ;;
        "restore")
            # 列出所有备份
            if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir")" ]; then
                echo "没有找到任何备份文件"
                return
            fi
            
            echo "可用的备份文件："
            local i=1
            local backups=()
            while IFS= read -r file; do
                echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
                backups+=("$file")
                ((i++))
            done < <(ls -t "$backup_dir"/config_*.toml 2>/dev/null)
            
            read -p "请选择要恢复的备份编号 (0 取消): " choice
            if [ "$choice" -gt 0 ] && [ "$choice" -le "${#backups[@]}" ]; then
                cp "${backups[choice-1]}" "/root/realm/config.toml"
                echo "配置已恢复"
                systemctl restart realm
                echo "服务已重启"
            else
                echo "取消恢复操作"
            fi
            ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
}

# 检查服务状态详细信息
check_service_details() {
    # 检查服务是否正在运行
    local is_active=$(systemctl is-active realm)
    local is_enabled=$(systemctl is-enabled realm 2>/dev/null)
    local service_pid=$(systemctl show -p MainPID realm | cut -d'=' -f2)
    local mem_usage=""
    local cpu_usage=""
    
    echo "Realm 服务状态:"
    echo "---------------"
    echo -n "运行状态: "
    if [ "$is_active" = "active" ]; then
        echo -e "\033[0;32m运行中\033[0m"
        # 获取内存和CPU使用情况
        if [ "$service_pid" -gt 0 ]; then
            mem_usage=$(ps -o rss= -p "$service_pid" 2>/dev/null)
            if [ ! -z "$mem_usage" ]; then
                mem_usage=$(awk "BEGIN {printf \"%.2f\", $mem_usage/1024}")
                echo "内存使用: ${mem_usage}MB"
            fi
            
            cpu_usage=$(ps -o %cpu= -p "$service_pid" 2>/dev/null)
            if [ ! -z "$cpu_usage" ]; then
                echo "CPU使用率: ${cpu_usage}%"
            fi
        fi
    else
        echo -e "\033[0;31m未运行\033[0m"
    fi
    
    echo -n "开机启动: "
    if [ "$is_enabled" = "enabled" ]; then
        echo -e "\033[0;32m是\033[0m"
    else
        echo -e "\033[0;31m否\033[0m"
    fi
    
    # 检查端口占用
    if [ "$is_active" = "active" ]; then
        echo -e "\n当前转发端口状态:"
        echo "---------------"
        while IFS= read -r line; do
            if [[ $line =~ listen[[:space:]]*=[[:space:]]*\"[^\"]*:([0-9]+)\" ]]; then
                local port="${BASH_REMATCH[1]}"
                if netstat -tuln | grep -q ":$port "; then
                    echo -e "端口 $port: \033[0;32m正常监听\033[0m"
                else
                    echo -e "端口 $port: \033[0;31m未监听\033[0m"
                fi
            fi
        done < "/root/realm/config.toml"
    fi
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 部署环境的函数
deploy_realm() {
    # 获取最新版本号
    echo "正在获取最新版本信息..."
    latest_version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_version" ]; then
        echo "无法获取最新版本信息，请检查网络连接。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    echo "检测到最新版本：${latest_version}"
    mkdir -p /root/realm
    cd /root/realm
    
    echo "开始下载最新版本..."
    wget -O realm.tar.gz "https://github.com/zhboner/realm/releases/download/${latest_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    if [ $? -ne 0 ]; then
        echo "下载失败，请检查网络连接。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    echo "解压文件..."
    tar -xvf realm.tar.gz
    chmod +x realm
    rm -f realm.tar.gz  # 清理下载的压缩包
    
    # 创建服务文件
    echo "[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm.service
    
    systemctl daemon-reload
    # 设置开机自启动
    systemctl enable realm
    # 更新realm状态变量
    realm_status="已安装"
    realm_status_color="\033[0;32m" # 绿色
    echo "部署完成。当前版本：${latest_version}"
    read -n 1 -s -r -p "按任意键继续..."
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

# 添加转发规则
add_forward() {
    if [ ! -d "/root/realm" ]; then
        echo "请先安装 realm（选项1）再添加转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if [ ! -f "/root/realm/config.toml" ]; then
        mkdir -p /root/realm
        echo "[network]
no_tcp = false
use_udp = true" > /root/realm/config.toml
    fi

    while true; do
        while true; do
            read -p "请输入本地监听端口 (1-65535): " local_port
            if validate_port "$local_port"; then
                break
            else
                echo "错误：无效的端口号。端口号必须在 1-65535 之间。"
            fi
        done

        while true; do
            read -p "请输入目标IP地址: " remote_ip
            if validate_ip "$remote_ip"; then
                break
            else
                echo "错误：无效的IP地址格式。"
            fi
        done

        while true; do
            read -p "请输入目标端口 (1-65535): " remote_port
            if validate_port "$remote_port"; then
                break
            else
                echo "错误：无效的端口号。端口号必须在 1-65535 之间。"
            fi
        done

        echo -e "\n[[endpoints]]
listen = \"0.0.0.0:$local_port\"
remote = \"$remote_ip:$remote_port\"" >> /root/realm/config.toml

        echo "已添加转发规则："
        echo "本地端口 $local_port -> $remote_ip:$remote_port"
        
        read -p "是否继续添加转发规则(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            echo "转发规则添加完成。"
            echo "正在重启realm服务以应用新的转发规则..."
            systemctl restart realm
            if systemctl is-active --quiet realm; then
                echo -e "\033[0;32m服务重启成功，转发规则已生效\033[0m"
            else
                echo -e "\033[0;31m服务重启失败，请检查配置或手动重启服务\033[0m"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            break
        fi
    done
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
    
    # 使用更可靠的方式解析 TOML 文件
    local in_endpoint=0
    local listen=""
    local remote=""
    
    while IFS= read -r line; do
        # 去除行首尾的空白字符
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ "$line" == "[[endpoints]]" ]]; then
            in_endpoint=1
            continue
        fi
        
        if [ $in_endpoint -eq 1 ]; then
            if [[ "$line" =~ ^listen[[:space:]]*=[[:space:]]*\"(.*)\"$ ]]; then
                listen="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^remote[[:space:]]*=[[:space:]]*\"(.*)\"$ ]]; then
                remote="${BASH_REMATCH[1]}"
                echo "本地端口 $listen -> $remote"
                listen=""
                remote=""
                in_endpoint=0
            fi
        fi
    done < "/root/realm/config.toml"

    if [ ! -s "/root/realm/config.toml" ] || ! grep -q "\[\[endpoints\]\]" "/root/realm/config.toml"; then
        echo "没有发现任何转发规则。"
    fi
    
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

    # 创建临时文件来存储规则和它们的行号
    local temp_file=$(mktemp)
    local rule_count=0
    
    echo "当前转发规则："
    echo "=================="
    
    # 使用awk提取并显示所有规则
    awk '
    /\[\[endpoints\]\]/ {in_endpoint=1; next}
    in_endpoint && /listen =/ {
        gsub(/.*"/, "");
        gsub(/".*/, "");
        listen=$0;
    }
    in_endpoint && /remote =/ {
        gsub(/.*"/, "");
        gsub(/".*/, "");
        remote=$0;
        rule_count++;
        printf "%d) 本地端口 %s -> %s\n", rule_count, listen, remote;
        in_endpoint=0;
    }' /root/realm/config.toml > "$temp_file"
    
    if [ ! -s "$temp_file" ]; then
        echo "没有找到任何转发规则。"
        rm "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    cat "$temp_file"
    echo "=================="
    
    # 获取规则总数
    rule_count=$(wc -l < "$temp_file")
    
    while true; do
        read -p "请输入要删除的规则编号 (1-$rule_count)，输入 0 取消: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le "$rule_count" ]; then
            break
        else
            echo "无效的选择，请重新输入。"
        fi
    done
    
    if [ "$choice" -eq 0 ]; then
        echo "取消删除操作。"
        rm "$temp_file"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 创建新的配置文件
    local new_config=$(mktemp)
    echo "[network]
no_tcp = false
use_udp = true" > "$new_config"
    
    # 计数器
    local current_rule=0
    
    # 从原配置文件中提取规则
    awk -v target="$choice" '
    /\[\[endpoints\]\]/ {
        in_endpoint=1;
        buffer="[[endpoints]]\n";
        next;
    }
    in_endpoint {
        buffer = buffer $0 "\n";
        if ($0 ~ /remote =/) {
            current_rule++;
            if (current_rule != target) {
                printf "%s", buffer;
            }
            in_endpoint=0;
        }
    }
    !in_endpoint && !/\[network\]/ && !/no_tcp =/ && !/use_udp =/' /root/realm/config.toml >> "$new_config"
    
    # 替换原配置文件
    mv "$new_config" /root/realm/config.toml
    
    echo "规则已删除。"
    rm "$temp_file"
    
    # 重启服务以应用更改
    systemctl restart realm
    
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
    if systemctl is-active --quiet realm; then
        systemctl stop realm
    fi
    systemctl disable realm 2>/dev/null
    rm -f /etc/systemd/system/realm.service
    rm -rf /root/realm
    systemctl daemon-reload
    # 更新realm状态变量
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
    echo "realm 已完全卸载"
    read -n 1 -s -r -p "按任意键继续..."
}

# 更新脚本的函数
update_script() {
    echo "正在检查更新..."
    echo "当前版本：$VERSION"
    
    # 添加随机数以避免缓存
    local timestamp=$(date +%s)
    local temp_file="/tmp/RealmOneKey_${timestamp}.sh"
    
    echo "正在从GitHub获取最新版本..."
    # 添加no-cache参数避免缓存，并输出详细信息
    if curl -s -H "Cache-Control: no-cache" -o "$temp_file" "https://raw.githubusercontent.com/xspoco/RealmPortForwarding/refs/heads/main/RealmOneKey.sh?_=${timestamp}"; then
        if [ -f "$temp_file" ]; then
            if [ -s "$temp_file" ]; then
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
                    return
                fi
                
                echo "最新版本：$REMOTE_VERSION"
                
                # 使用版本比较函数
                compare_versions "$VERSION" "$REMOTE_VERSION"
                case $? in
                    0) 
                        echo "当前已是最新版本！"
                        echo "如果你确定远程有更新，请尝试以下操作："
                        echo "1. 等待几分钟后再试（GitHub可能需要时间更新缓存）"
                        echo "2. 使用浏览器直接访问脚本地址检查版本"
                        rm -f "$temp_file"
                        read -n 1 -s -r -p "按任意键继续..."
                        return
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
                
                if [[ $confirm != "Y" && $confirm != "y" ]]; then
                    echo "取消更新"
                    rm -f "$temp_file"
                    read -n 1 -s -r -p "按任意键继续..."
                    return
                fi
                
                # 备份当前脚本
                cp "$0" "$0.backup"
                
                # 替换当前脚本
                mv "$temp_file" "$0"
                chmod +x "$0"
                
                echo "脚本已更新完成！"
                echo "正在重启脚本..."
                exec "$0"
            else
                echo "更新失败：下载的文件为空"
                rm -f "$temp_file"
            fi
        else
            echo "更新失败：无法下载新版本"
        fi
    else
        echo "更新失败：无法连接到更新服务器"
        echo "curl错误代码：$?"
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    read -n 1 -s -r -p "按任意键继续..."
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

# 显示菜单的函数
show_menu() {
    clear
    echo -e "欢迎使用realm一键转发脚本 v$VERSION"
    echo "================="
    echo "1. 部署环境"
    echo "2. 添加转发"
    echo "3. 查看已添加的转发规则"
    echo "4. 删除转发"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 一键卸载"
    echo "9. 检查更新"
    echo "10. 备份配置"
    echo "11. 恢复配置"
    echo "12. 查看详细状态"
    echo "13. 启用realm开机自启"
    echo "14. 禁用realm开机自启"
    echo "0. 退出脚本"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -n "realm 转发状态："
    check_realm_service_status
}

# 主循环
while true; do
    show_menu
    read -p "请选择一个选项: " choice

    case $choice in
        1)
            deploy_realm
            ;;
        2)
            add_forward
            ;;
        3)
            show_forwards
            ;;
        4)
            delete_forward
            ;;
        5)
            start_service
            ;;
        6)
            stop_service
            ;;
        7)
            restart_service
            ;;
        8)
            uninstall_realm
            ;;
        9)
            update_script
            ;;
        10)
            backup_restore_config "backup"
            ;;
        11)
            backup_restore_config "restore"
            ;;
        12)
            check_service_details
            ;;
        13)
            manage_autostart "enable"
            ;;
        14)
            manage_autostart "disable"
            ;;
        0)
            echo "感谢使用！"
            exit 0
            ;;
        *)
            echo "无效的选项，请重新选择"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
    esac
done

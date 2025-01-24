#!/bin/bash

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

# 显示菜单的函数
show_menu() {
    clear
    echo "欢迎使用realm一键转发脚本"
    echo "================="
    echo "1. 部署环境"
    echo "2. 添加转发"
    echo "3. 查看已添加的转发规则"
    echo "4. 删除转发"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 一键卸载"
    echo "0. 退出脚本"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -n "realm 转发状态："
    check_realm_service_status
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
        0)
            echo "感谢使用，再见！"
            exit 0
            ;;
        *)
            echo "无效选项: $choice"
            ;;
    esac
done

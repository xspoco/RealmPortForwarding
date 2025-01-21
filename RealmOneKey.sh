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
    echo "7. 一键卸载"
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
    }

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
    }

    echo "当前所有转发规则："
    echo "=================="
    
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
        printf "本地端口 %s -> %s\n", listen, remote;
        in_endpoint=0;
    }' /root/realm/config.toml

    if [ $? -ne 0 ] || [ -z "$(grep '\[\[endpoints\]\]' /root/realm/config.toml)" ]; then
        echo "没有发现任何转发规则。"
    fi
    
    echo "=================="
    read -n 1 -s -r -p "按任意键继续..."
}

# 其他函数保持不变...
[其余代码保持不变]

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

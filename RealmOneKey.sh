#!/bin/bash

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
    echo "3. 删除转发"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 一键卸载"
    echo "7. 查看转发细则"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -n "realm 转发状态："
    check_realm_service_status
}

# 部署环境的函数
deploy_realm() {
    mkdir -p /root/realm
    cd /root/realm
    wget -O realm.tar.gz https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf realm.tar.gz
    chmod +x realm
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
    echo "部署完成。"
}

# 卸载realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    echo "realm已被卸载。"
    # 更新realm状态变量
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
}

# 删除转发规则的函数
delete_forward() {
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n 'remote =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo $line | cut -d '"' -f 2)"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice-1))]}
    local line_number=$(echo $chosen_line | cut -d ':' -f 1)
    local start_line=$line_number
    local end_line=$(($line_number + 2))

    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    echo "转发规则已删除。"
}

# 添加转发规则
add_forward() {
    echo "添加转发规则："
    while true; do
        read -p "请输入目标IP (例如 8.8.8.8): " ip
        read -p "请输入远程端口 (目标服务器端口): " remote_port
        read -p "请输入本地端口 (映射到本地端口): " local_port
        read -p "请输入转发协议 (tcp/udp，默认为tcp): " protocol
        protocol=${protocol:-tcp}
        
        echo "[[endpoints]]
listen = \"0.0.0.0:$local_port\"
remote = \"$ip:$remote_port\"
protocol = \"$protocol\"" >> /root/realm/config.toml

        echo "规则已添加：$protocol $local_port -> $ip:$remote_port"

        read -p "是否继续添加(Y/N)? " answer
       

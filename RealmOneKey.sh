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
    read -n 1 -s -r -p "按任意键继续..."
}

# 删除转发规则的函数
delete_forward() {
    echo "当前转发规则："
    local IFS=$'\n' # 设置IFS仅以换行符作为分隔符
    local lines=($(grep -n 'remote =' /root/realm/config.toml)) # 搜索所有包含转发规则的行
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo $line | cut -d '"' -f 2)" # 提取并显示端口信息
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    local chosen_line=${lines[$((choice-1))]} # 根据用户选择获取相应行
    local line_number=$(echo $chosen_line | cut -d ':' -f 1) # 获取行号

    # 删除相关的三行：listen、remote 和 [[endpoints]]（如果存在）
    local start_line=$((line_number - 1)) # listen 行
    local end_line=$((line_number + 1))   # [[endpoints]] 行（如果存在）
    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    echo "转发规则已删除。"
    read -n 1 -s -r -p "按任意键继续..."
}

# 添加转发规则
add_forward() {
    # 首先检查 realm 是否已安装
    if [ ! -d "/root/realm" ]; then
        echo "请先安装 realm（选项1）再添加转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    # 检查配置文件是否存在，如果不存在则创建基础配置
    if [ ! -f "/root/realm/config.toml" ]; then
        # 确保目录存在
        mkdir -p /root/realm
        
        echo "[network]
no_tcp = false
use_udp = true

[[endpoints]]" > /root/realm/config.toml
        echo "已创建基础配置文件。"
    elif ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
        # 如果文件存在但没有 [[endpoints]] 节点，添加它
        echo -e "\n[[endpoints]]" >> /root/realm/config.toml
    fi

    while true; do
        read -p "请输入目的地IP: " ip
        read -p "请输入目的地端口: " port
        # 追加到config.toml文件
        echo "listen = \"0.0.0.0:$port\"
remote = \"$ip:$port\"

[[endpoints]]" >> /root/realm/config.toml
        
        read -p "是否继续添加(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            # 删除最后一个多余的 [[endpoints]]
            sed -i '$ d' /root/realm/config.toml
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
    
    local IFS=$'\n'
    local lines=($(grep 'remote =' /root/realm/config.toml))
    
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local remote=$(echo $line | cut -d '"' -f 2)
        echo "$index. $remote"
        let index+=1
    done
    echo "=================="
    read -n 1 -s -r -p "按任意键继续..."
}

# 检查并处理权限的函数
check_permission() {
    local cmd=$1
    if [ "$EUID" -eq 0 ]; then
        # root用户直接执行
        $cmd
    else
        # 非root用户，检查是否有sudo
        if command -v sudo >/dev/null 2>&1; then
            sudo $cmd
        else
            echo "错误：当前用户不是root用户，且未安装sudo。"
            echo "请选择以下方式之一："
            echo "1. 使用root用户运行此脚本"
            echo "2. 安装sudo：apt-get install sudo 或 yum install sudo"
            read -n 1 -s -r -p "按任意键继续..."
            return 1
        fi
    fi
    return 0
}

# 启动服务
start_service() {
    if systemctl is-active --quiet realm; then
        echo "realm服务已经在运行中。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    # 使用check_permission函数执行命令
    if ! check_permission "systemctl unmask realm.service"; then
        return
    fi
    if ! check_permission "systemctl daemon-reload"; then
        return
    fi
    if ! check_permission "systemctl restart realm.service"; then
        return
    fi
    if ! check_permission "systemctl enable realm.service"; then
        return
    fi

    echo "realm服务已启动并设置为开机自启。"
    read -n 1 -s -r -p "按任意键继续..."
}

# 停止服务
stop_service() {
    if ! systemctl is-active --quiet realm; then
        echo "realm服务当前未运行。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    systemctl stop realm
    echo "realm服务已停止。"
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

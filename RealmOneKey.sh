#!/bin/bash

# 当前脚本版本号
VERSION="1.5.4"

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
# 安装realm
install_realm() {
    # 创建安装目录
    mkdir -p /root/realm
    cd /root/realm || exit
    
    # 检测系统架构
    arch=$(uname -m)
    
    # 定义下载链接
    case $arch in
        x86_64)
            download_url="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        aarch64)
            download_url="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        *)
            echo "不支持的系统架构: $arch"
            return 1
            ;;
    esac
    
    # 下载并解压
    echo "正在下载realm..."
    if ! wget -q --show-progress "$download_url" -O realm.tar.gz; then
        echo "下载失败，请检查网络连接"
        return 1
    fi
    
    tar xzf realm.tar.gz
    rm realm.tar.gz
    
    # 创建配置文件目录
    mkdir -p /etc/realm
    
    # 检查是否存在原配置文件
    if [ ! -f "/etc/realm/config.toml" ]; then
        # 创建新的配置文件
        cat > /etc/realm/config.toml << 'EOL'
# realm default configuration
[[endpoints]]
# First endpoint
listen = "0.0.0.0:0"
remote = "0.0.0.0:0"
mode = "tcp"
remark = "默认规则"
EOL
    fi
    
    # 创建systemd服务
    cat > /etc/systemd/system/realm.service << 'EOL'
[Unit]
Description=realm Service
After=network.target

[Service]
Type=simple
ExecStart=/root/realm/realm -c /etc/realm/config.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 设置开机自启
    systemctl enable realm
    
    # 启动服务
    systemctl start realm
    
    echo "realm安装完成！"
    realm_status="已安装"
    realm_status_color="$GREEN"
}

# 卸载realm
uninstall_realm() {
    echo -e "${YELLOW}警告：这将完全删除realm及其所有配置文件。${NC}"
    read -p "确定要卸载吗？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # 停止服务
        systemctl stop realm
        
        # 禁用服务
        systemctl disable realm
        
        # 删除服务文件
        rm -f /etc/systemd/system/realm.service
        
        # 重新加载systemd
        systemctl daemon-reload
        
        # 删除程序文件
        rm -rf /root/realm
        
        # 删除配置文件
        rm -rf /etc/realm
        
        echo "realm已完全卸载！"
        realm_status="未安装"
        realm_status_color="$RED"
    else
        echo "取消卸载"
    fi
}

# 备份配置
backup_config() {
    local backup_dir="/root/realm_backup"
    local date_suffix=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/realm_config_${date_suffix}.tar.gz"
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    
    # 复制配置文件到临时目录
    cp -r /etc/realm/* "$temp_dir/"
    
    # 创建备份
    tar -czf "$backup_file" -C "$temp_dir" .
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    echo "配置已备份到: $backup_file"
}

# 恢复配置
restore_config() {
    local backup_dir="/root/realm_backup"
    
    # 检查备份目录是否存在
    if [ ! -d "$backup_dir" ]; then
        echo "未找到备份目录"
        return 1
    fi
    
    # 列出所有备份文件
    local backup_files=("$backup_dir"/realm_config_*.tar.gz)
    if [ ! -f "${backup_files[0]}" ]; then
        echo "未找到备份文件"
        return 1
    fi
    
    echo "可用的备份文件："
    local i=1
    for file in "${backup_files[@]}"; do
        echo "$i) $(basename "$file")"
        ((i++))
    done
    
    read -p "请选择要恢复的备份文件编号: " choice
    
    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#backup_files[@]} ]; then
        local selected_file="${backup_files[$((choice-1))]}"
        
        # 创建临时目录
        local temp_dir=$(mktemp -d)
        
        # 解压备份文件到临时目录
        tar -xzf "$selected_file" -C "$temp_dir"
        
        # 停止realm服务
        systemctl stop realm
        
        # 恢复配置文件
        rm -rf /etc/realm/*
        cp -r "$temp_dir"/* /etc/realm/
        
        # 清理临时目录
        rm -rf "$temp_dir"
        
        # 重启realm服务
        systemctl start realm
        
        echo "配置已恢复"
    else
        echo "无效的选择"
    fi
}
# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "              ${BOLD}Realm 管理脚本${NC}"
    echo -e "          ${UNDERLINE}当前版本：v${VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " 当前状态：${realm_status_color}$realm_status${NC}"
    echo -e " 运行状态：$(check_realm_service_status)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${GREEN}1.${NC} 安装 Realm"
    echo -e " ${GREEN}2.${NC} 卸载 Realm"
    echo -e " ${GREEN}3.${NC} 启动 Realm"
    echo -e " ${GREEN}4.${NC} 停止 Realm"
    echo -e " ${GREEN}5.${NC} 重启 Realm"
    echo -e " ${GREEN}6.${NC} 查看服务状态"
    echo -e " ${GREEN}7.${NC} 查看配置文件"
    echo -e " ${GREEN}8.${NC} 编辑配置文件"
    echo -e " ${GREEN}9.${NC} 备份配置"
    echo -e " ${GREEN}10.${NC} 恢复配置"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${GREEN}0.${NC} 退出脚本"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "请输入选项 [0-10]: " choice
}

# 主程序循环
while true; do
    show_menu
    case $choice in
        1)
            if [ "$realm_status" = "已安装" ]; then
                echo "realm已经安装，如需重新安装请先卸载"
            else
                install_realm
            fi
            ;;
        2)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，无需卸载"
            else
                uninstall_realm
            fi
            ;;
        3)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，请先安装"
            else
                systemctl start realm
                echo "realm已启动"
            fi
            ;;
        4)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，请先安装"
            else
                systemctl stop realm
                echo "realm已停止"
            fi
            ;;
        5)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，请先安装"
            else
                systemctl restart realm
                echo "realm已重启"
            fi
            ;;
        6)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，请先安装"
            else
                check_service_details
            fi
            ;;
        7)
            if [ -f "/etc/realm/config.toml" ]; then
                cat /etc/realm/config.toml
                read -n 1 -s -r -p "按任意键继续..."
            else
                echo "配置文件不存在"
            fi
            ;;
        8)
            if [ -f "/etc/realm/config.toml" ]; then
                nano /etc/realm/config.toml
            else
                echo "配置文件不存在"
            fi
            ;;
        9)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，无法备份配置"
            else
                backup_config
            fi
            ;;
        10)
            if [ "$realm_status" = "未安装" ]; then
                echo "realm未安装，无法恢复配置"
            else
                restore_config
            fi
            ;;
        0)
            echo "感谢使用！"
            exit 0
            ;;
        *)
            echo "无效的选项，请重新选择"
            ;;
    esac
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
done

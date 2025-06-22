#!/bin/bash

# 当前脚本版本号
VERSION="1.5.5"

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
# 配置realm的函数
configure_realm() {
    # 检查是否安装了realm
    if [ ! -f "/root/realm/realm" ]; then
        echo -e "\033[0;31mrealm未安装，请先安装realm。\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    echo "当前配置内容："
    echo "================"
    if [ -f "/root/realm/config.toml" ]; then
        cat /root/realm/config.toml
    else
        echo "配置文件不存在"
    fi
    echo "================"
    echo ""
    
    # 提示用户输入配置信息
    read -p "请输入监听端口 (默认: 8080): " port
    port=${port:-8080}
    
    read -p "请输入密码 (默认: realm): " password
    password=${password:-realm}
    
    # 创建新的配置文件
    cat > /root/realm/config.toml << EOF
[network]
no_tcp = false
use_udp = true
port = ${port}

[relay]
password = "${password}"
EOF
    
    # 重启服务
    echo "正在重启realm服务..."
    if ! systemctl restart realm; then
        echo -e "\033[0;31m服务重启失败\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    echo -e "\n配置已更新！"
    echo "================"
    echo -e "端口: \033[0;32m$port\033[0m"
    echo -e "密码: \033[0;32m$password\033[0m"
    echo "================"
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 卸载realm的函数
uninstall_realm() {
    echo "警告：此操作将完全卸载realm。"
    read -p "确定要卸载吗？(Y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消卸载。"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 停止并禁用服务
    echo "停止realm服务..."
    systemctl stop realm
    systemctl disable realm
    
    # 删除服务文件
    echo "删除服务文件..."
    rm -f /etc/systemd/system/realm.service
    
    # 删除realm目录
    echo "删除realm文件..."
    rm -rf /root/realm
    
    # 重新加载systemd
    systemctl daemon-reload
    
    echo -e "\n卸载完成！"
    read -n 1 -s -r -p "按任意键继续..."
}

# 管理realm服务的函数
manage_service() {
    while true; do
        clear
        echo -e "${CYAN}================== Realm 服务管理 ==================${NC}"
        echo -e "1. ${GREEN}启动服务${NC}"
        echo -e "2. ${RED}停止服务${NC}"
        echo -e "3. ${YELLOW}重启服务${NC}"
        echo -e "4. ${CYAN}查看服务状态${NC}"
        echo -e "0. ${YELLOW}返回主菜单${NC}"
        echo "=================================================="
        
        read -p "请选择操作 [0-4]: " choice
        
        case $choice in
            1)
                echo "正在启动realm服务..."
                systemctl start realm
                sleep 2
                ;;
            2)
                echo "正在停止realm服务..."
                systemctl stop realm
                sleep 2
                ;;
            3)
                echo "正在重启realm服务..."
                systemctl restart realm
                sleep 2
                ;;
            4)
                check_service_details
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项"
                sleep 2
                ;;
        esac
    done
}

# 检查更新
check_update() {
    echo "正在检查更新..."
    
    # 获取GitHub最新版本
    latest_version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep -oP '"tag_name": "\K(.+)(?=")')
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取最新版本信息${NC}"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    }
    
    # 获取当前安装的版本
    current_version=$(get_realm_version)
    if [ "$current_version" == "未安装" ]; then
        echo -e "${YELLOW}Realm 未安装${NC}"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    echo -e "当前版本: ${CYAN}${current_version}${NC}"
    echo -e "最新版本: ${CYAN}${latest_version}${NC}"
    
    # 比较版本
    compare_versions "$current_version" "$latest_version"
    case $? in
        0)
            echo -e "${GREEN}已经是最新版本${NC}"
            ;;
        1)
            echo -e "${YELLOW}当前版本高于远程版本${NC}"
            ;;
        2)
            echo -e "${YELLOW}发现新版本${NC}"
            read -p "是否要更新？(Y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                deploy_realm
            fi
            ;;
    esac
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 主菜单循环
while true; do
    clear
    local_version=$(get_realm_version)
    service_status=$(check_realm_service_status)
    
    echo -e "${CYAN}===================== Realm 管理脚本 =====================${NC}"
    echo -e "脚本版本: ${GREEN}${VERSION}${NC}"
    echo -e "Realm状态: ${realm_status_color}${realm_status}${NC}"
    echo -e "当前版本: ${CYAN}${local_version}${NC}"
    echo -e "服务状态: ${service_status}"
    echo "========================================================="
    echo -e "1. ${GREEN}安装/更新 Realm${NC}"
    echo -e "2. ${YELLOW}配置 Realm${NC}"
    echo -e "3. ${CYAN}服务管理${NC}"
    echo -e "4. ${YELLOW}检查更新${NC}"
    echo -e "5. ${RED}卸载 Realm${NC}"
    echo -e "0. ${RED}退出脚本${NC}"
    echo "========================================================="
    
    read -p "请选择操作 [0-5]: " option
    
    case $option in
        1)
            deploy_realm
            ;;
        2)
            configure_realm
            ;;
        3)
            manage_service
            ;;
        4)
            check_update
            ;;
        5)
            uninstall_realm
            ;;
        0)
            echo "感谢使用！"
            exit 0
            ;;
        *)
            echo "无效选项"
            sleep 2
            ;;
    esac
done

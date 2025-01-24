#!/bin/bash

# 当前脚本版本号
VERSION="1.3.6"

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
    if ! systemctl list-unit-files | grep -q realm.service; then
        echo -e "\033[0;31m服务未安装\033[0m"
        read -n 1 -s -r -p "按任意键继续..."
        return 1
    fi
    
    echo "Realm 服务状态详情："
    echo "----------------------------------------"
    
    # 检查服务状态
    echo -n "运行状态: "
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m运行中\033[0m"
    else
        echo -e "\033[0;31m未运行\033[0m"
    fi
    
    # 检查开机启动状态
    echo -n "开机启动: "
    if systemctl is-enabled --quiet realm; then
        echo -e "\033[0;32m已启用\033[0m"
    else
        echo -e "\033[0;31m未启用\033[0m"
    fi
    
    # 显示资源使用情况
    echo "资源使用:"
    local pid=$(systemctl show -p MainPID realm | cut -d= -f2)
    if [ "$pid" != "0" ]; then
        echo "CPU使用率: $(ps -p $pid -o %cpu | tail -n 1)%"
        echo "内存使用: $(ps -p $pid -o rss | tail -n 1 | awk '{printf "%.2f MB\n",$1/1024}')"
    else
        echo -e "\033[0;31m进程未运行\033[0m"
    fi
    
    # 显示最后100行日志
    echo "----------------------------------------"
    echo "最近日志:"
    journalctl -u realm -n 100 --no-pager
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 部署realm的函数
deploy_realm() {
    # 检查是否已安装
    if [ -d "/root/realm" ]; then
        echo "realm 已经安装，如需重新安装请先卸载"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 创建目录
    mkdir -p /root/realm
    chmod 700 /root/realm
    cd /root/realm || exit
    
    echo "正在下载realm..."
    if ! curl -L -o realm.tar.gz https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz; then
        echo -e "\033[0;31m下载失败\033[0m"
        rm -rf /root/realm
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 解压
    if ! tar -xzf realm.tar.gz; then
        echo -e "\033[0;31m解压失败\033[0m"
        rm -rf /root/realm
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi
    
    # 设置执行权限
    chmod +x realm
    
    # 创建配置文件
    echo '[common]
port = "80"
token = "realm"' > config.toml
    chmod 600 config.toml
    
    # 创建服务文件
    echo "[Unit]
Description=realm forward service
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/root/realm/realm -c /root/realm/config.toml
WorkingDirectory=/root/realm

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm.service
    
    systemctl daemon-reload
    # 设置开机自启动
    systemctl enable realm
    # 更新realm状态变量
    realm_status="已安装"
    realm_status_color="\033[0;32m" # 绿色
    
    # 清理下载文件
    rm -f realm.tar.gz
    
    echo -e "\033[0;32m部署完成\033[0m"
    echo "配置文件位置：/root/realm/config.toml"
    echo "默认端口：80"
    echo "默认令牌：realm"
    echo "请根据需要修改配置文件后重启服务"
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
    esac
    
    read -n 1 -s -r -p "按任意键继续..."
}

# 添加转发规则的函数
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
    echo "准备卸载realm..."
    read -p "确定要卸载realm吗？这将删除所有相关文件和配置(y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "取消卸载"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    # 停止服务
    echo "停止realm服务..."
    systemctl stop realm 2>/dev/null
    
    # 禁用服务
    echo "禁用realm服务..."
    systemctl disable realm 2>/dev/null
    
    # 删除服务文件
    echo "删除服务文件..."
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    
    # 删除realm程序和配置（包含备份）
    echo "删除realm程序和配置文件..."
    rm -rf /root/realm
    
    # 删除下载的脚本文件
    echo "删除脚本文件..."
    rm -f /tmp/RealmOneKey*.sh
    
    # 删除临时文件
    echo "清理临时文件..."
    rm -f /tmp/realm_*
    rm -f /tmp/RealmOneKey_*.sh
    
    # 删除当前脚本
    echo "删除当前脚本..."
    local current_script="$0"
    
    # 更新状态变量（在脚本退出前）
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
    
    echo -e "\033[0;32m卸载完成！所有realm相关文件已清理干净\033[0m"
    echo "系统将在3秒后退出..."
    sleep 1
    echo "2..."
    sleep 1
    echo "1..."
    sleep 1
    
    # 使用新进程删除当前脚本并退出
    (sleep 1; rm -f "$current_script") &
    exit 0
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
                
                # 备份当前脚本和配置
                echo "备份当前配置..."
                if [ -f "$config_file" ]; then
                    backup_config
                fi
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
    echo
    
    # 退出选项
    echo -e "  ${RED}0${NC}. 退出脚本"
    echo
    
    # 输入提示
    echo -e "${YELLOW}请输入选项编号: ${NC}"
}

# 主循环
while true; do
    show_menu
    read -r choice
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
            check_service_details
            ;;
        9)
            uninstall_realm
            ;;
        10)
            update_script
            ;;
        11)
            backup_config
            ;;
        12)
            backup_restore_config "restore"
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

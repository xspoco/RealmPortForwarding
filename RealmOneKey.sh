#!/bin/bash

VERSION="1.9.0"

SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
[ ! -f "$SCRIPT_PATH" ] && SCRIPT_PATH="$0"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"
CYAN="\033[0;36m"; NC="\033[0m"; BOLD="\033[1m"; UNDERLINE="\033[4m"

compare_versions() {
    local v1=${1#v} v2=${2#v}
    local IFS=.
    local i a=($v1) b=($v2)
    for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        ((x > y)) && return 1
        ((x < y)) && return 2
    done
    return 0
}

[ "$EUID" -ne 0 ] && { echo "需要 root 权限"; exit 1; }

detect_realm_asset() {
    local libc=${1:-musl} m; m=$(uname -m)
    case "$m" in
        x86_64|amd64)    echo "x86_64-unknown-linux-${libc}" ;;
        aarch64|arm64)   echo "aarch64-unknown-linux-${libc}" ;;
        armv7l|armv7)    echo "arm-unknown-linux-${libc}eabihf" ;;
        *) echo "x86_64-unknown-linux-${libc}" >&2; echo "x86_64-unknown-linux-${libc}" ;;
    esac
}

download_realm_asset() {
    local version="$1" libc="${2:-musl}"
    local asset; asset=$(detect_realm_asset "$libc")
    local filename="realm-${asset}.tar.gz" url
    if [ "$version" = "latest" ]; then
        url="https://github.com/zhboner/realm/releases/latest/download/${filename}"
    else
        url="https://github.com/zhboner/realm/releases/download/v${version#v}/${filename}"
    fi
    echo "下载地址: $url" >&2
    rm -f "$filename"
    # 修复点：增加超时限制，防止网络异常时永久卡死
    if curl -fL --connect-timeout 10 --max-time 120 --progress-bar -o "$filename" "$url" 2>/dev/null || wget -q --timeout=20 --tries=2 -O "$filename" "$url"; then
        if [ -s "$filename" ]; then
            echo "$filename"; return 0
        fi
    fi
    rm -f "$filename"; return 1
}

self_test_realm_binary() {
    local bin="$1"
    [ -x "$bin" ] || return 2
    "$bin" -v >/tmp/.realm_selftest.log 2>&1
    local ec=$?
    if [ $ec -gt 128 ]; then
        echo -e "\033[0;31m检测到realm运行崩溃(信号 $((ec-128)))，CPU/系统不兼容\033[0m" >&2
        return 1
    elif [ $ec -ne 0 ]; then
        cat /tmp/.realm_selftest.log >&2; return 2
    fi
    return 0
}

show_service_diagnostics() {
    echo -e "\n${YELLOW}${BOLD}== 服务诊断信息 ==${NC}"
    echo "---- systemctl status realm ----"
    systemctl --no-pager status realm 2>&1 | head -n 15
    echo "---- journalctl -u realm (最近20行) ----"
    journalctl -u realm --no-pager -n 20 2>&1
    echo "----------------------------------------"
    if [ -f /root/realm/config.toml ]; then
        echo "当前配置文件内容："
        head -n 40 /root/realm/config.toml
    fi
}

get_realm_version() {
    [ -f /root/realm/realm ] || { echo "未安装"; return; }
    local raw; raw=$(/root/realm/realm -v 2>/dev/null)
    local v; v=$(echo "$raw" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    echo "${v:-未知}"
}

check_realm_service_status() {
    systemctl list-unit-files 2>/dev/null | grep -q realm.service || { echo -e "\033[0;31m未安装\033[0m"; return 1; }
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m运行中\033[0m"; return 0
    else
        if [ -f /root/realm/config.toml ] && ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
            echo -e "\033[0;33m未运行(无规则)${NC}"
        else
            echo -e "\033[0;31m未运行\033[0m"
        fi
        return 1
    fi
}

init_realm_config() {
    local cfg="/root/realm/config.toml"
    if [ ! -f "$cfg" ]; then
        cat > "$cfg" <<'EOF'
endpoints = []

[network]
no_tcp = false
use_udp = true
EOF
        return 0
    fi
    if ! grep -qE "^[[:space:]]*endpoints[[:space:]]*=" "$cfg" && ! grep -q "\[\[endpoints\]\]" "$cfg"; then
        { echo "endpoints = []"; echo; cat "$cfg"; } > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    fi
}

deploy_realm() {
    if [ -f /root/realm/realm ]; then
        read -p "检测到已安装realm，是否重新安装？(y/n): " c
        if [[ ! "$c" =~ ^[Yy]$ ]]; then
            echo "取消安装。"
            return 0
        fi
    fi

    echo "开始安装realm..."
    local old; old=$(pwd)
    mkdir -p /root/realm
    cd /root/realm || return 1

    echo "正在下载realm..."
    local f; f=$(download_realm_asset "latest" "musl" | tail -n1)
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo -e "${RED}下载失败，请检查网络${NC}"; cd "$old"; return 1
    fi

    echo "正在解压文件..."
    tar -xzf "$f"; local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}解压失败 (tar rc=$rc)${NC}"; rm -f "$f"; cd "$old"; return 1
    fi
    [ -f realm ] || { echo -e "${RED}未找到realm可执行文件${NC}"; rm -f "$f"; cd "$old"; return 1; }
    chmod +x realm

    if ! self_test_realm_binary "./realm"; then
        echo -e "${YELLOW}musl版本运行异常，尝试改用 gnu 版本...${NC}"
        rm -f "$f" realm
        f=$(download_realm_asset "latest" "gnu" | tail -n1)
        if [ -z "$f" ]; then
            echo -e "${RED}gnu版本下载失败，安装中止${NC}"; cd "$old"; return 1
        fi
        tar -xzf "$f" || { echo -e "${RED}gnu解压失败${NC}"; rm -f "$f"; cd "$old"; return 1; }
        chmod +x realm
        self_test_realm_binary "./realm" || { echo -e "${RED}gnu版本仍然运行异常${NC}"; rm -f "$f"; cd "$old"; return 1; }
    fi

    echo "正在创建服务文件..."
    cat > /etc/systemd/system/realm.service <<'EOF'
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

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

    init_realm_config
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
    sleep 2
    
    # 修复点：清理下载的压缩包，避免残留
    rm -f "$f"

    if ! systemctl is-active --quiet realm; then
        if ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
            echo -e "${YELLOW}提示：由于尚未添加任何转发规则，Realm 服务启动后自动退出，属正常现象。${NC}"
            echo -e "${GREEN}安装完成！${NC}"
            echo -e "请通过选项 2 添加转发规则，系统将自动启动服务。"
            cd "$old"
            return 0
        else
            echo -e "${RED}服务未能保持运行状态${NC}"
            show_service_diagnostics
            cd "$old"
            return 1
        fi
    fi
    
    echo -e "\n${GREEN}安装完成！${NC}"
    echo "=================="
    echo -e "Realm 版本: ${GREEN}$(get_realm_version)${NC}"
    echo -e "服务状态: ${GREEN}已启动${NC}"
    echo "=================="
    cd "$old"
    return 0
}

backup_config() {
    local cfg=/root/realm/config.toml dir=/root/realm/backups
    [ -f "$cfg" ] || { echo -e "${RED}错误：未找到配置文件${NC}"; return 1; }
    mkdir -p "$dir"; chmod 700 "$dir"
    
    local ts
    ts=$(date +"%Y%m%d_%H%M%S")
    local bf="$dir/config_${ts}.toml"
    
    cp "$cfg" "$bf" || { echo -e "${RED}备份失败${NC}"; return 1; }
    echo -e "${GREEN}配置文件已备份到：$bf${NC}"
    
    local n; n=$(ls -1 "$dir"/config_*.toml 2>/dev/null | wc -l)
    if [ "$n" -gt 5 ]; then
        echo "清理旧备份文件..."
        ls -t "$dir"/config_*.toml | tail -n +6 | xargs rm -f
    fi
    return 0
}

backup_restore_config() {
    local action=$1 dir=/root/realm/backups cfg=/root/realm/config.toml
    case $action in
        backup) backup_config ;;
        restore)
            [ -d "$dir" ] || { echo -e "${RED}错误：未找到备份目录${NC}"; return 1; }
            local files=()
            while IFS= read -r f; do files+=("$f"); done < <(ls -t "$dir"/config_*.toml 2>/dev/null)
            [ ${#files[@]} -eq 0 ] && { echo -e "${RED}没有找到可用的备份文件${NC}"; return 1; }
            echo "可用的备份文件："
            local i=1
            for f in "${files[@]}"; do
                echo "$i) $(basename "$f") ($(date -r "$f" '+%F %T'))"; ((i++))
            done
            read -p "请选择要恢复的备份文件编号（输入q取消）: " c
            if [ "$c" = "q" ]; then
                echo "取消恢复"
                return 0
            fi
            [[ ! "$c" =~ ^[0-9]+$ ]] && return 0
            [ "$c" -ge 1 ] && [ "$c" -le ${#files[@]} ] || return 0
            local sel="${files[$((c-1))]}"
            verify_config "$sel" || { echo -e "${RED}错误：选择的备份文件格式无效${NC}"; return 1; }
            [ -f "$cfg" ] && cp "$cfg" "$cfg.$(date +%s).bak"
            cp "$sel" "$cfg" && echo -e "${GREEN}配置已恢复${NC}"
            if systemctl is-active --quiet realm; then
                echo "正在重启realm服务..."
                systemctl restart realm
                sleep 1
                systemctl is-active --quiet realm && echo -e "${GREEN}服务已重启${NC}" || { echo -e "${RED}服务重启失败${NC}"; show_service_diagnostics; }
            fi
            ;;
    esac
    return 0
}

validate_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.; local p; for p in $ip; do [ "$p" -le 255 ] || return 1; done
    return 0
}

validate_port() {
    local p=$1
    [[ $p =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

add_forward() {
    echo -e "\n添加转发规则 (在任意步骤输入 q 可退出)"
    echo "=================="
    local la lp ra rp cm
    while true; do
        read -p "请输入本地监听地址 (默认 0.0.0.0，输入 q 退出): " la
        [ "$la" = "q" ] && { echo "取消添加转发规则。"; return 0; }
        [ -z "$la" ] && { la="0.0.0.0"; break; }
        validate_ip "$la" && break
        echo -e "${RED}无效的IP地址格式${NC}"
    done
    while true; do
        read -p "请输入本地端口 (1-65535，输入 q 退出): " lp
        [ "$lp" = "q" ] && { echo "取消添加转发规则。"; return 0; }
        validate_port "$lp" && break
        echo -e "${RED}无效的端口号${NC}"
    done
    while true; do
        read -p "请输入远程地址 (输入 q 退出): " ra
        [ "$ra" = "q" ] && { echo "取消添加转发规则。"; return 0; }
        validate_ip "$ra" && break
        echo -e "${RED}无效的IP地址格式${NC}"
    done
    while true; do
        read -p "请输入远程端口 (1-65535，输入 q 退出): " rp
        [ "$rp" = "q" ] && { echo "取消添加转发规则。"; return 0; }
        validate_port "$rp" && break
        echo -e "${RED}无效的端口号${NC}"
    done
    read -p "请输入备注 (可选，直接回车跳过): " cm

    echo -e "\n即将添加以下转发规则："
    echo "本地 $la:$lp -> 远程 $ra:$rp"
    [ -n "$cm" ] && echo "备注: $cm"
    read -p "确认添加？(y/n): " c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        echo "取消添加转发规则。"
        return 0
    fi

    local cfg=/root/realm/config.toml
    [ -f "$cfg" ] && cp "$cfg" "$cfg.bak" || init_realm_config
    init_realm_config

    {
        echo ""
        echo "[[endpoints]]"
        echo "listen = \"$la:$lp\""
        echo "remote = \"$ra:$rp\""
        [ -n "$cm" ] && echo "comment = \"$cm\""
    } >> "$cfg"

    echo "正在重启服务以应用更改..."
    systemctl restart realm
    sleep 1
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}转发规则添加成功，服务已重启${NC}"; rm -f "$cfg.bak"
    else
        echo -e "${RED}警告：服务重启失败，正在恢复备份...${NC}"
        [ -f "$cfg.bak" ] && mv "$cfg.bak" "$cfg"
        show_service_diagnostics
    fi
    return 0
}

show_forwards() {
    [ -f /root/realm/config.toml ] || { echo "配置文件不存在，尚未添加任何转发规则。"; return 0; }
    echo "当前所有转发规则："
    echo "=================="
    awk '
    /\[\[endpoints\]\]/ {
        if (listen && remote) { n++; printf "%d) 本地端口 %s -> %s%s\n", n, listen, remote, (comment?" [备注: "comment"]":"") }
        listen=remote=comment=""; next
    }
    /listen *=/ { gsub(/.*= *"|" *$/,""); listen=$0 }
    /remote *=/ { gsub(/.*= *"|" *$/,""); remote=$0 }
    /comment *=/ { gsub(/.*= *"|" *$/,""); comment=$0 }
    END {
        if (listen && remote) { n++; printf "%d) 本地端口 %s -> %s%s\n", n, listen, remote, (comment?" [备注: "comment"]":"") }
        if (n==0) print "没有发现任何转发规则。"
    }' /root/realm/config.toml
    echo "=================="
    return 0
}

delete_forward() {
    local cfg=/root/realm/config.toml
    [ -f "$cfg" ] || { echo "配置文件不存在，没有可删除的转发规则。"; return 0; }
    local tmp=$(mktemp) rf=$(mktemp)

    awk '
    /\[\[endpoints\]\]/ { if (listen && remote) print listen "\t" remote "\t" comment; listen=remote=comment=""; next }
    /listen *=/ { gsub(/.*= *"|" *$/,""); listen=$0 }
    /remote *=/ { gsub(/.*= *"|" *$/,""); remote=$0 }
    /comment *=/ { gsub(/.*= *"|" *$/,""); comment=$0 }
    END { if (listen && remote) print listen "\t" remote "\t" comment }
    ' "$cfg" > "$rf"

    local total; total=$(wc -l < "$rf")
    [ "$total" -eq 0 ] && { echo "没有发现任何转发规则。"; rm -f "$tmp" "$rf"; return 0; }

    local i=1
    while IFS=$'\t' read -r l r c; do
        [ -n "$c" ] && echo "$i) 本地端口 $l -> $r [备注: $c]" || echo "$i) 本地端口 $l -> $r"
        ((i++))
    done < "$rf"
    echo "=================="

    local choice
    read -p "请输入要删除的规则编号 (1-$total)，输入 q 取消: " choice
    if [ "$choice" = "q" ]; then
        echo "取消删除操作。"
        rm -f "$tmp" "$rf"
        return 0
    fi
    [[ ! "$choice" =~ ^[0-9]+$ ]] && return 0
    [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ] || return 0

    cp "$cfg" "$cfg.bak"

    {
        echo "endpoints = []"
        echo ""
        echo "[network]"
        echo "no_tcp = false"
        echo "use_udp = true"
    } > "$tmp"

    local cur=0
    while IFS=$'\t' read -r l r c; do
        ((cur++))
        [ "$cur" -eq "$choice" ] && continue
        {
            echo ""
            echo "[[endpoints]]"
            echo "listen = \"$l\""
            echo "remote = \"$r\""
            [ -n "$c" ] && echo "comment = \"$c\""
        } >> "$tmp"
    done < "$rf"

    if ! mv "$tmp" "$cfg"; then
        echo -e "${RED}错误：无法更新配置文件，正在恢复备份...${NC}"
        mv "$cfg.bak" "$cfg"
        rm -f "$tmp" "$rf"
        return 0
    fi
    rm -f "$rf" "$cfg.bak"
    echo -e "${GREEN}规则已删除${NC}"
    
    echo "正在重启服务以应用更改..."
    systemctl restart realm; sleep 1
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}服务已重启${NC}"
    else
        if ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
            echo -e "${YELLOW}提示：所有规则已清空，Realm 服务已自动退出，属正常现象。${NC}"
        else
            echo -e "${RED}警告：服务重启失败${NC}"
            show_service_diagnostics
        fi
    fi
    return 0
}

start_service() {
    if ! systemctl is-active --quiet realm; then
        systemctl start realm
        sleep 1
        if systemctl is-active --quiet realm; then
            echo "realm 服务已启动"
        else
            if ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
                echo -e "${YELLOW}提示：尚未添加任何转发规则，Realm 无法保持运行，请先添加规则。${NC}"
            else
                echo -e "${RED}realm 服务启动失败${NC}"
                show_service_diagnostics
            fi
        fi
    else
        echo "realm 服务已经在运行中"
    fi
    return 0
}

stop_service() {
    if systemctl is-active --quiet realm; then
        echo "realm 服务正在运行中"
        read -p "确定要停止服务吗？(y/n): " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            systemctl stop realm
            echo "realm 服务已停止"
        else
            echo "取消停止操作"
        fi
    else
        echo "realm 服务未在运行"
    fi
    return 0
}

restart_service() {
    if systemctl is-active --quiet realm; then
        echo "realm 服务正在运行中"
        read -p "确定要重启服务吗？(y/n): " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            systemctl restart realm
            sleep 1
            if systemctl is-active --quiet realm; then
                echo "realm 服务已重启"
            else
                echo -e "${RED}realm 服务重启失败${NC}"
                show_service_diagnostics
            fi
        else
            echo "取消重启操作"
        fi
    else
        echo "realm 服务未在运行，将启动服务"
        read -p "确定要启动服务吗？(y/n): " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            systemctl start realm
            sleep 1
            if systemctl is-active --quiet realm; then
                echo "realm 服务已启动"
            else
                if ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
                    echo -e "${YELLOW}提示：尚未添加任何转发规则，Realm 无法保持运行，请先添加规则。${NC}"
                else
                    echo -e "${RED}realm 服务启动失败${NC}"
                    show_service_diagnostics
                fi
            fi
        else
            echo "取消启动操作"
        fi
    fi
    return 0
}

uninstall_realm() {
    echo "准备卸载realm..."
    read -p "确定要卸载realm吗？这将删除所有相关文件和配置 (y/n): " c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        return 0
    fi
    read -p "再次确认：所有数据将被删除，确认卸载？ (y/n): " c2
    if [[ ! "$c2" =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        return 0
    fi

    [ -f /root/realm/config.toml ] && backup_config

    echo "停止realm服务..."
    systemctl stop realm 2>/dev/null
    local count=0
    while systemctl is-active --quiet realm && [ $count -lt 10 ]; do
        sleep 1; ((count++))
    done
    if systemctl is-active --quiet realm; then
        echo -e "${RED}警告：服务无法完全停止${NC}"
        read -p "是否强制继续卸载？ (y/n): " force
        if [[ ! "$force" =~ ^[Yy]$ ]]; then
            echo "取消卸载"
            return 0
        fi
    fi

    echo "禁用realm服务..."
    systemctl disable realm 2>/dev/null
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload

    echo "删除realm程序和配置文件..."
    rm -rf /root/realm_backups_tmp 2>/dev/null
    if [ -d "/root/realm/backups" ]; then
        mv "/root/realm/backups" "/root/realm_backups_tmp"
    fi
    rm -rf /root/realm
    mkdir -p /root/realm
    if [ -d "/root/realm_backups_tmp" ]; then
        mv "/root/realm_backups_tmp" "/root/realm/backups"
    fi

    echo -e "${GREEN}卸载完成！${NC}"
    [ -d /root/realm/backups ] && echo "配置备份保留在：/root/realm/backups"
    return 0
}

check_realm_update() {
    local old; old=$(pwd)
    [ -f /root/realm/realm ] || { echo "Realm未安装，请先安装Realm。"; return 1; }
    
    local cur; cur=$(get_realm_version)
    echo "当前Realm版本：$cur"
    echo "正在获取GitHub最新版本信息..."
    
    local info rc
    # 修复点：增加网络请求超时
    info=$(curl -s --connect-timeout 10 --max-time 20 https://api.github.com/repos/zhboner/realm/releases/latest)
    rc=$?
    [ $rc -ne 0 ] && { echo -e "${RED}获取最新版本信息失败${NC}"; return 1; }
    
    local latest; latest=$(echo "$info" | grep -oP '"tag_name":\s*"\K[^"]+')
    [ -z "$latest" ] && { echo -e "${RED}无法解析最新版本号${NC}"; return 1; }
    latest=${latest#v}
    
    # 修复点：校验版本号格式，防止获取到脏数据
    [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo -e "${RED}解析到的最新版本号格式异常：$latest${NC}"; return 1; }
    echo "GitHub最新Realm版本：$latest"

    compare_versions "$cur" "$latest"
    local cmp=$?
    local confirm="N"
    case $cmp in
        0) 
            echo -e "${GREEN}Realm已是最新版本！${NC}"
            return 0 
            ;;
        1)
            echo -e "${YELLOW}当前Realm版本高于GitHub最新发布版本，可能是测试版本${NC}"
            read -p "是否仍要更新到GitHub发布版本？(y/n): " confirm
            ;;
        2)
            echo -e "${GREEN}发现Realm新版本：$latest${NC}"
            read -p "是否更新Realm？(y/n): " confirm
            ;;
    esac
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消Realm更新"
        return 0
    fi

    echo -e "\n${YELLOW}${BOLD}开始执行Realm更新流程...${NC}"
    backup_config
    local td; td=$(mktemp -d)
    cd "$td" || return 1
    
    echo "正在从GitHub下载Realm版本: $latest"
    local f; f=$(download_realm_asset "$latest" "musl" | tail -n1)
    { [ -z "$f" ] || [ ! -f "$f" ]; } && f=$(download_realm_asset "latest" "musl" | tail -n1)
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo -e "${RED}下载失败${NC}"; cd "$old"; rm -rf "$td"; return 1
    fi
    
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$sz" -lt 1000000 ] && { echo -e "${RED}下载文件大小异常${NC}"; cd "$old"; rm -rf "$td"; return 1; }

    tar -xzf "$f"; rc=$?
    [ $rc -ne 0 ] && { echo -e "${RED}解压失败 (rc=$rc)${NC}"; cd "$old"; rm -rf "$td"; return 1; }
    [ -f realm ] || { echo -e "${RED}未找到realm可执行文件${NC}"; cd "$old"; rm -rf "$td"; return 1; }
    chmod +x realm

    if ! self_test_realm_binary "./realm"; then
        echo -e "${YELLOW}新版本musl运行异常，尝试改用gnu版本...${NC}"
        rm -f "$f" realm
        f=$(download_realm_asset "$latest" "gnu" | tail -n1)
        { [ -z "$f" ] || [ ! -f "$f" ]; } && f=$(download_realm_asset "latest" "gnu" | tail -n1)
        if [ -z "$f" ] || [ ! -f "$f" ]; then
            echo -e "${RED}gnu版本下载失败，更新中止（旧版本未受影响）${NC}"; cd "$old"; rm -rf "$td"; return 1
        fi
        tar -xzf "$f" || { cd "$old"; rm -rf "$td"; return 1; }
        chmod +x realm
        self_test_realm_binary "./realm" || { echo -e "${RED}新版本运行异常，已中止更新${NC}"; cd "$old"; rm -rf "$td"; return 1; }
    fi

    echo "停止Realm服务..."
    systemctl stop realm; sleep 2
    systemctl is-active --quiet realm && pkill -9 realm
    
    [ -f /root/realm/realm ] && cp -f /root/realm/realm /root/realm/realm.bak
    mkdir -p /root/realm; chmod 755 /root/realm
    rm -f /root/realm/realm
    if ! cp -f realm /root/realm/realm; then
        [ -f /root/realm/realm.bak ] && cp -f /root/realm/realm.bak /root/realm/realm
        systemctl start realm; cd "$old"; rm -rf "$td"; return 1
    fi
    chmod 755 /root/realm/realm
    
    echo "启动Realm服务..."
    systemctl start realm; sleep 2
    if ! systemctl is-active --quiet realm; then
        if ! grep -q "\[\[endpoints\]\]" /root/realm/config.toml; then
            echo -e "${YELLOW}更新完成，由于无转发规则，服务处于待机状态。${NC}"
            # 修复点：更新成功后清理备份
            rm -f /root/realm/realm.bak
        else
            echo -e "${RED}服务启动失败${NC}"; show_service_diagnostics
            [ -f /root/realm/realm.bak ] && { cp -f /root/realm/realm.bak /root/realm/realm; chmod +x /root/realm/realm; systemctl start realm; }
        fi
    else
        rm -f /root/realm/realm.bak
    fi
    
    cd "$old"; rm -rf "$td"
    echo -e "\n=================="
    echo -e "Realm更新完成!"
    echo -e "原版本: ${YELLOW}$cur${NC}"
    echo -e "新版本: ${GREEN}$(get_realm_version)${NC}"
    echo "=================="
    return 0
}

update_script() {
    echo "正在检查更新..."
    echo "当前脚本版本：$VERSION"
    
    local ts=$(date +%s) tf="/tmp/RealmOneKey_${ts}.sh"
    echo "正在从GitHub获取最新脚本版本..."
    # 修复点：增加超时限制
    if ! curl -s --connect-timeout 10 --max-time 30 -H "Cache-Control: no-cache" -o "$tf" "https://raw.githubusercontent.com/xspoco/RealmPortForwarding/refs/heads/main/RealmOneKey.sh?_=$ts"; then
        echo -e "${RED}脚本下载失败${NC}"
        [ -f /root/realm/realm ] && check_realm_update
        return 1
    fi
    [ -s "$tf" ] || { echo -e "${RED}下载的文件无效${NC}"; rm -f "$tf"; return 1; }
    
    local rv; rv=$(grep '^VERSION=' "$tf" | cut -d'"' -f2)
    [ -z "$rv" ] && { echo "无法获取远程脚本版本号"; rm -f "$tf"; return 1; }
    
    # 修复点：校验脚本版本号格式，防止污染文件被覆盖
    [[ ! "$rv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "远程脚本版本号格式异常，可能是下载被干扰"; rm -f "$tf"; return 1; }
    echo "远程脚本版本：$rv"

    compare_versions "$VERSION" "$rv"
    local cmp=$? update="false"
    case $cmp in
        0) 
            echo "当前脚本已是最新版本！"
            ;;
        1)
            echo "当前脚本版本比远程版本更新，可能是测试版本"
            read -p "是否仍要更新到远程版本？(y/n): " c
            [[ "$c" =~ ^[Yy]$ ]] && update="true"
            ;;
        2)
            echo "发现脚本新版本"
            read -p "是否更新脚本？(y/n): " c
            [[ "$c" =~ ^[Yy]$ ]] && update="true"
            ;;
    esac

    if [ "$update" = "true" ]; then
        [ -f /root/realm/config.toml ] && backup_config
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
        if ! mv "$tf" "$SCRIPT_PATH"; then
            echo "更新失败：无法替换脚本文件"
            rm -f "$tf"
            [ -f /root/realm/realm ] && check_realm_update
            return 1
        fi
        chmod +x "$SCRIPT_PATH"
        echo "脚本已更新完成！"
        
        if [ -f /root/realm/realm ]; then
            echo ""
            check_realm_update
        fi
        echo "正在重启脚本..."
        exec "$SCRIPT_PATH"
    else
        rm -f "$tf"
        [ -f /root/realm/realm ] && check_realm_update
    fi
    return 0
}

verify_config() {
    local f="$1"
    [ -s "$f" ] || return 1
    grep -q "^\[network\]" "$f" || return 1
    if grep -q "\[\[endpoints\]\]" "$f"; then
        grep -qE "^[[:space:]]*listen[[:space:]]*=" "$f" && grep -qE "^[[:space:]]*remote[[:space:]]*=" "$f" || return 1
    elif ! grep -qE "^[[:space:]]*endpoints[[:space:]]*=[[:space:]]*\[\]" "$f"; then
        return 1
    fi
    return 0
}

show_menu() {
    clear
    local r_status r_color
    if [ -f "/root/realm/realm" ]; then
        r_status="已安装"; r_color="$GREEN"
    else
        r_status="未安装"; r_color="$RED"
    fi
    
    echo -e "\n${YELLOW}${BOLD}Realm 一键转发脚本 ${NC}${YELLOW}v${VERSION}${NC}\n"
    echo -e "${UNDERLINE}系统状态${NC}"
    echo -e "  运行状态: ${r_color}${r_status}${NC}"
    echo -e "  转发状态: $(check_realm_service_status)"
    echo -e "  Realm 版本: $(get_realm_version)"
    echo
    echo -e "${CYAN}${BOLD}基础功能${NC}"
    echo -e "  ${GREEN}1${NC}. 部署环境          ${GREEN}2${NC}. 添加转发"
    echo -e "  ${GREEN}3${NC}. 查看转发规则      ${GREEN}4${NC}. 删除转发"
    echo -e "${CYAN}${BOLD}服务控制${NC}"
    echo -e "  ${GREEN}5${NC}. 启动服务          ${GREEN}6${NC}. 停止服务"
    echo -e "  ${GREEN}7${NC}. 重启服务          ${GREEN}8${NC}. 查看详细状态"
    echo -e "${CYAN}${BOLD}系统管理${NC}"
    echo -e "  ${GREEN}9${NC}. 一键卸载          ${GREEN}10${NC}. 检查更新"
    echo -e "  ${GREEN}11${NC}. 备份配置         ${GREEN}12${NC}. 恢复配置"
    echo -e "  ${GREEN}13${NC}. 其他选项         ${GREEN}14${NC}. 查看服务日志/诊断"
    echo -e "  ${RED}0${NC}. 退出脚本"
    echo -n -e "${YELLOW}请输入选项编号: ${NC}"
}

while true; do
    show_menu
    read -r choice
    echo
    case $choice in
        1) deploy_realm ;;
        2) 
            if [ -f /root/realm/realm ]; then
                add_forward
            else
                echo -e "${RED}请先安装 Realm（选项1）再添加转发规则${NC}"
            fi
            ;;
        3)
            if [ -f /root/realm/realm ]; then
                show_forwards
            else
                echo -e "${RED}请先安装 Realm（选项1）再查看转发规则${NC}"
            fi
            ;;
        4)
            if [ -f /root/realm/realm ]; then
                delete_forward
            else
                echo -e "${RED}请先安装 Realm（选项1）再删除转发规则${NC}"
            fi
            ;;
        5)
            if [ -f /root/realm/realm ]; then
                start_service
            else
                echo -e "${RED}请先安装 Realm（选项1）再启动服务${NC}"
            fi
            ;;
        6)
            if [ -f /root/realm/realm ]; then
                stop_service
            else
                echo -e "${RED}请先安装 Realm（选项1）再停止服务${NC}"
            fi
            ;;
        7)
            if [ -f /root/realm/realm ]; then
                restart_service
            else
                echo -e "${RED}请先安装 Realm（选项1）再重启服务${NC}"
            fi
            ;;
        8)
            if [ -f /root/realm/realm ]; then
                echo -e "\n服务详细状态："
                echo "=================="
                echo -e "Realm 版本: ${GREEN}$(get_realm_version)${NC}"
                echo -n "开机启动: "
                if systemctl is-enabled --quiet realm; then
                    echo -e "${GREEN}已启用${NC}"
                else
                    echo -e "${RED}未启用${NC}"
                fi
                echo "=================="
                systemctl status --no-pager realm
            else
                echo -e "${RED}请先安装 Realm（选项1）再查看服务状态${NC}"
            fi
            ;;
        9)
            if [ -f /root/realm/realm ]; then
                uninstall_realm
            else
                echo -e "${RED}Realm 未安装，无需卸载${NC}"
            fi
            ;;
        10) update_script ;;
        11)
            if [ -f /root/realm/config.toml ]; then
                backup_config
            else
                echo -e "${RED}没有找到配置文件，无法备份${NC}"
            fi
            ;;
        12)
            if [ -d /root/realm/backups ]; then
                backup_restore_config "restore"
            else
                echo -e "${RED}没有找到备份文件夹，无法恢复${NC}"
            fi
            ;;
        13)
            while true; do
                echo -e "\n${CYAN}${BOLD}其他选项${NC}"
                echo -e "  ${GREEN}1${NC}. 启用realm开机启动"
                echo -e "  ${GREEN}2${NC}. 禁用realm开机启动"
                echo -e "  ${RED}q${NC}. 返回主菜单"
                echo -n -e "${YELLOW}请输入选项编号: ${NC}"
                read -r sub_choice
                case $sub_choice in
                    1)
                        echo "正在启用realm开机启动..."
                        if systemctl enable realm; then
                            echo -e "${GREEN}已启用realm开机启动${NC}"
                        else
                            echo -e "${RED}启用失败${NC}"
                        fi
                        ;;
                    2)
                        echo "正在禁用realm开机启动..."
                        if systemctl disable realm; then
                            echo -e "${GREEN}已禁用realm开机启动${NC}"
                        else
                            echo -e "${RED}禁用失败${NC}"
                        fi
                        ;;
                    q)
                        echo -e "\n返回主菜单"
                        break
                        ;;
                    *)
                        echo -e "${RED}无效的选项${NC}"
                        ;;
                esac
            done
            continue
            ;;
        14)
            if [ -f /root/realm/realm ]; then
                show_service_diagnostics
            else
                echo -e "${RED}Realm 未安装${NC}"
            fi
            ;;
        0)
            echo -e "${GREEN}感谢使用！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择${NC}"
            ;;
    esac
    if [ "$choice" != "13" ] && [ "$choice" != "0" ]; then
        read -n 1 -s -r -p "按任意键继续..."
    fi
done

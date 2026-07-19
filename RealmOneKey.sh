#!/bin/bash

VERSION="1.8.5"

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
    if curl -fL --progress-bar -o "$filename" "$url" 2>/dev/null || wget -q --show-progress -O "$filename" "$url"; then
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
        echo -e "\033[0;31m运行崩溃(信号 $((ec-128)))，CPU/系统不兼容\033[0m" >&2
        return 1
    elif [ $ec -ne 0 ]; then
        cat /tmp/.realm_selftest.log >&2; return 2
    fi
    return 0
}

show_service_diagnostics() {
    echo -e "\n${YELLOW}${BOLD}== 服务诊断信息 ==${NC}"
    systemctl --no-pager status realm 2>&1 | head -n 15
    echo "---- journalctl -u realm (最近20行) ----"
    journalctl -u realm --no-pager -n 20 2>&1
    [ -f /root/realm/config.toml ] && { echo "配置文件："; head -n 40 /root/realm/config.toml; }
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
        echo -e "\033[0;31m未运行\033[0m"; return 1
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
        read -p "已安装 realm，重新安装? [y/N]: " c
        [[ ! "$c" =~ ^[Yy]$ ]] && return
    fi
    echo "开始安装 realm..."
    local old; old=$(pwd)
    mkdir -p /root/realm
    cd /root/realm || return 1

    echo "下载 realm..."
    local f; f=$(download_realm_asset "latest" "musl" | tail -n1)
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo -e "${RED}下载失败${NC}"; cd "$old"; return 1
    fi

    tar -xzf "$f"; local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}解压失败 (tar rc=$rc)${NC}"; cd "$old"; return 1
    fi
    [ -f realm ] || { echo -e "${RED}未找到可执行文件${NC}"; cd "$old"; return 1; }
    chmod +x realm

    if ! self_test_realm_binary "./realm"; then
        echo -e "${YELLOW}musl 异常，尝试 gnu...${NC}"
        rm -f "$f" realm
        f=$(download_realm_asset "latest" "gnu" | tail -n1)
        [ -z "$f" ] && { echo -e "${RED}gnu 下载失败${NC}"; cd "$old"; return 1; }
        tar -xzf "$f" || { echo -e "${RED}gnu 解压失败${NC}"; cd "$old"; return 1; }
        chmod +x realm
        self_test_realm_binary "./realm" || { echo -e "${RED}gnu 仍异常${NC}"; cd "$old"; return 1; }
    fi

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
    systemctl start realm || { show_service_diagnostics; cd "$old"; return 1; }
    sleep 1
    systemctl is-active --quiet realm || { show_service_diagnostics; cd "$old"; return 1; }
    rm -f "$f"
    echo -e "\n${GREEN}安装完成！ 版本: $(get_realm_version)${NC}"
    cd "$old"
}

backup_config() {
    local cfg=/root/realm/config.toml dir=/root/realm/backups
    [ -f "$cfg" ] || { echo -e "${RED}无配置文件${NC}"; return 1; }
    mkdir -p "$dir"; chmod 700 "$dir"
    local ts=$(date +%Y%m%d_%H%M%S) bf="$dir/config_${ts}.toml"
    cp "$cfg" "$bf" || { echo -e "${RED}备份失败${NC}"; return 1; }
    echo -e "${GREEN}已备份到：$bf${NC}"
    local n; n=$(ls -1 "$dir"/config_*.toml 2>/dev/null | wc -l)
    [ "$n" -gt 5 ] && ls -t "$dir"/config_*.toml | tail -n +6 | xargs rm -f
    return 0
}

backup_restore_config() {
    local action=$1 dir=/root/realm/backups cfg=/root/realm/config.toml
    case $action in
        backup) backup_config ;;
        restore)
            [ -d "$dir" ] || { echo -e "${RED}无备份目录${NC}"; return 1; }
            local files=()
            while IFS= read -r f; do files+=("$f"); done < <(ls -t "$dir"/config_*.toml 2>/dev/null)
            [ ${#files[@]} -eq 0 ] && { echo -e "${RED}无备份文件${NC}"; return 1; }
            local i=1
            for f in "${files[@]}"; do
                echo "$i) $(basename "$f") ($(date -r "$f" '+%F %T'))"; ((i++))
            done
            read -p "选择编号: " c
            [[ ! "$c" =~ ^[0-9]+$ ]] && return 1
            [ "$c" -ge 1 ] && [ "$c" -le ${#files[@]} ] || return 1
            local sel="${files[$((c-1))]}"
            verify_config "$sel" || { echo -e "${RED}备份格式无效${NC}"; return 1; }
            [ -f "$cfg" ] && cp "$cfg" "$cfg.$(date +%s).bak"
            cp "$sel" "$cfg" && echo -e "${GREEN}已恢复${NC}"
            systemctl is-active --quiet realm && systemctl restart realm
            ;;
    esac
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
    echo -e "\n添加转发规则 (输入 q 退出)"
    local la lp ra rp cm
    while true; do
        read -p "本地监听地址(默认0.0.0.0): " la
        [ "$la" = "q" ] && return
        [ -z "$la" ] && { la="0.0.0.0"; break; }
        validate_ip "$la" && break
        echo -e "${RED}无效IP${NC}"
    done
    while true; do
        read -p "本地端口: " lp
        [ "$lp" = "q" ] && return
        validate_port "$lp" && break
        echo -e "${RED}无效端口${NC}"
    done
    while true; do
        read -p "远程地址: " ra
        [ "$ra" = "q" ] && return
        validate_ip "$ra" && break
        echo -e "${RED}无效IP${NC}"
    done
    while true; do
        read -p "远程端口: " rp
        [ "$rp" = "q" ] && return
        validate_port "$rp" && break
        echo -e "${RED}无效端口${NC}"
    done
    read -p "备注(可选): " cm

    read -p "确认添加 $la:$lp -> $ra:$rp ? [y/N]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return

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

    systemctl restart realm
    sleep 1
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}规则已添加，服务已重启${NC}"; rm -f "$cfg.bak"
    else
        echo -e "${RED}重启失败，回滚${NC}"
        [ -f "$cfg.bak" ] && mv "$cfg.bak" "$cfg"
        show_service_diagnostics
    fi
}

show_forwards() {
    [ -f /root/realm/config.toml ] || { echo "无配置文件"; return; }
    awk '
    /\[\[endpoints\]\]/ {
        if (listen && remote) { n++; printf "%d) %s -> %s%s\n", n, listen, remote, (comment?" ["comment"]":"") }
        listen=remote=comment=""; next
    }
    /listen *=/ { gsub(/.*= *"|" *$/,""); listen=$0 }
    /remote *=/ { gsub(/.*= *"|" *$/,""); remote=$0 }
    /comment *=/ { gsub(/.*= *"|" *$/,""); comment=$0 }
    END {
        if (listen && remote) { n++; printf "%d) %s -> %s%s\n", n, listen, remote, (comment?" ["comment"]":"") }
        if (n==0) print "无转发规则"
    }' /root/realm/config.toml
}

delete_forward() {
    local cfg=/root/realm/config.toml
    [ -f "$cfg" ] || { echo "无配置文件"; return; }
    local tmp=$(mktemp) rf=$(mktemp)

    awk '
    /\[\[endpoints\]\]/ { if (listen && remote) print listen "\t" remote "\t" comment; listen=remote=comment=""; next }
    /listen *=/ { gsub(/.*= *"|" *$/,""); listen=$0 }
    /remote *=/ { gsub(/.*= *"|" *$/,""); remote=$0 }
    /comment *=/ { gsub(/.*= *"|" *$/,""); comment=$0 }
    END { if (listen && remote) print listen "\t" remote "\t" comment }
    ' "$cfg" > "$rf"

    local total; total=$(wc -l < "$rf")
    [ "$total" -eq 0 ] && { echo "无转发规则"; rm -f "$tmp" "$rf"; return; }

    local i=1
    while IFS=$'\t' read -r l r c; do
        echo "$i) $l -> $r ${c:+[$c]}"; ((i++))
    done < "$rf"

    local choice
    read -p "删除编号(1-$total, q取消): " choice
    [ "$choice" = "q" ] && { rm -f "$tmp" "$rf"; return; }
    [[ ! "$choice" =~ ^[0-9]+$ ]] && return
    [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ] || return

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

    mv "$tmp" "$cfg" || { mv "$cfg.bak" "$cfg"; rm -f "$tmp" "$rf"; return 1; }
    rm -f "$rf" "$cfg.bak"
    systemctl restart realm; sleep 1
    systemctl is-active --quiet realm && echo -e "${GREEN}已删除并重启${NC}" || show_service_diagnostics
}

start_service()   { systemctl is-active --quiet realm && echo "已在运行" || { systemctl start realm; sleep 1; systemctl is-active --quiet realm && echo "已启动" || show_service_diagnostics; }; }
stop_service()    { systemctl is-active --quiet realm && { read -p "确认停止? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && systemctl stop realm && echo "已停止"; } || echo "未运行"; }
restart_service() { systemctl restart realm; sleep 1; systemctl is-active --quiet realm && echo "已重启" || show_service_diagnostics; }

uninstall_realm() {
    read -p "确认卸载? [y/N]: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    read -p "再次确认? [y/N]: " c2; [[ ! "$c2" =~ ^[Yy]$ ]] && return
    [ -f /root/realm/config.toml ] && backup_config
    systemctl stop realm 2>/dev/null
    systemctl disable realm 2>/dev/null
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    [ -d /root/realm/backups ] && mv /root/realm/backups /root/realm_bak
    rm -rf /root/realm
    [ -d /root/realm_bak ] && mv /root/realm_bak /root/realm/backups
    echo -e "${GREEN}卸载完成${NC}"
}

check_realm_update() {
    local old; old=$(pwd)
    [ -f /root/realm/realm ] || { echo "未安装"; return 1; }
    local cur; cur=$(get_realm_version)
    echo "当前版本: $cur"
    echo "获取 GitHub 最新版本..."
    local info rc
    info=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest)
    rc=$?
    [ $rc -ne 0 ] && { echo -e "${RED}获取失败 (rc=$rc)${NC}"; return 1; }
    local latest; latest=$(echo "$info" | grep -oP '"tag_name":\s*"\K[^"]+')
    [ -z "$latest" ] && { echo -e "${RED}解析失败${NC}"; return 1; }
    latest=${latest#v}
    echo "GitHub 最新: $latest"

    compare_versions "$cur" "$latest"
    local cmp=$?
    local confirm="N"
    case $cmp in
        0) echo -e "${GREEN}已是最新${NC}"; return 0 ;;
        1) read -p "本地更新，仍更新到远程? [y/N]: " confirm ;;
        2) read -p "发现新版本，更新? [y/N]: " confirm ;;
    esac
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    backup_config
    local td; td=$(mktemp -d)
    cd "$td" || return 1
    local f; f=$(download_realm_asset "$latest" "musl" | tail -n1)
    { [ -z "$f" ] || [ ! -f "$f" ]; } && f=$(download_realm_asset "latest" "musl" | tail -n1)
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo -e "${RED}下载失败${NC}"; cd "$old"; rm -rf "$td"; return 1
    fi
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$sz" -lt 1000000 ] && { echo -e "${RED}文件大小异常${NC}"; cd "$old"; rm -rf "$td"; return 1; }

    tar -xzf "$f"; rc=$?
    [ $rc -ne 0 ] && { echo -e "${RED}解压失败 (rc=$rc)${NC}"; cd "$old"; rm -rf "$td"; return 1; }
    [ -f realm ] || { echo -e "${RED}无可执行文件${NC}"; cd "$old"; rm -rf "$td"; return 1; }
    chmod +x realm
    if ! self_test_realm_binary "./realm"; then
        echo -e "${YELLOW}musl 异常，尝试 gnu...${NC}"
        rm -f "$f" realm
        f=$(download_realm_asset "$latest" "gnu" | tail -n1)
        { [ -z "$f" ] || [ ! -f "$f" ]; } && f=$(download_realm_asset "latest" "gnu" | tail -n1)
        if [ -z "$f" ] || [ ! -f "$f" ]; then
            echo -e "${RED}gnu 下载失败，旧版本不受影响${NC}"; cd "$old"; rm -rf "$td"; return 1
        fi
        tar -xzf "$f" || { cd "$old"; rm -rf "$td"; return 1; }
        chmod +x realm
        self_test_realm_binary "./realm" || { cd "$old"; rm -rf "$td"; return 1; }
    fi

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
    systemctl start realm; sleep 2
    if ! systemctl is-active --quiet realm; then
        show_service_diagnostics
        [ -f /root/realm/realm.bak ] && { cp -f /root/realm/realm.bak /root/realm/realm; chmod +x /root/realm/realm; systemctl start realm; }
    else
        rm -f /root/realm/realm.bak
    fi
    cd "$old"; rm -rf "$td"
    echo -e "\n更新完成: $cur -> $(get_realm_version)"
    return 0
}

update_script() {
    echo "当前脚本版本: $VERSION"
    local ts=$(date +%s) tf="/tmp/RealmOneKey_${ts}.sh"
    if ! curl -s -H "Cache-Control: no-cache" -o "$tf" "https://raw.githubusercontent.com/xspoco/RealmPortForwarding/refs/heads/main/RealmOneKey.sh?_=$ts"; then
        echo -e "${RED}脚本下载失败${NC}"
        [ -f /root/realm/realm ] && check_realm_update
        return 1
    fi
    [ -s "$tf" ] || { echo -e "${RED}下载为空${NC}"; rm -f "$tf"; return 1; }
    local rv; rv=$(grep '^VERSION=' "$tf" | cut -d'"' -f2)
    [ -z "$rv" ] && { echo "无法解析远程版本"; rm -f "$tf"; return 1; }
    echo "远程版本: $rv"
    compare_versions "$VERSION" "$rv"
    local cmp=$? update="false"
    case $cmp in
        0) echo "已是最新" ;;
        1) read -p "本地更新，仍更新? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && update="true" ;;
        2) read -p "发现新版本，更新? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && update="true" ;;
    esac
    if [ "$update" = "true" ]; then
        [ -f /root/realm/config.toml ] && backup_config
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
        mv "$tf" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" || { rm -f "$tf"; return 1; }
        [ -f /root/realm/realm ] && check_realm_update
        exec "$SCRIPT_PATH"
    else
        rm -f "$tf"
        [ -f /root/realm/realm ] && check_realm_update
    fi
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
    # 修复点1：每次刷新菜单实时检测安装状态
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
        2) [ -f /root/realm/realm ] && add_forward || echo -e "${RED}请先安装${NC}" ;;
        3) [ -f /root/realm/realm ] && show_forwards || echo -e "${RED}请先安装${NC}" ;;
        4) [ -f /root/realm/realm ] && delete_forward || echo -e "${RED}请先安装${NC}" ;;
        5) [ -f /root/realm/realm ] && start_service || echo -e "${RED}请先安装${NC}" ;;
        6) [ -f /root/realm/realm ] && stop_service || echo -e "${RED}请先安装${NC}" ;;
        7) [ -f /root/realm/realm ] && restart_service || echo -e "${RED}请先安装${NC}" ;;
        8) [ -f /root/realm/realm ] && { systemctl status --no-pager realm; } || echo -e "${RED}请先安装${NC}" ;;
        9) [ -f /root/realm/realm ] && uninstall_realm || echo -e "${RED}无需卸载${NC}" ;;
        10) update_script ;;
        11) [ -f /root/realm/config.toml ] && backup_config || echo -e "${RED}无配置文件${NC}" ;;
        12) [ -d /root/realm/backups ] && backup_restore_config "restore" || echo -e "${RED}无备份${NC}" ;;
        13) while true; do
                echo -e "\n${CYAN}${BOLD}其他选项${NC}"
                echo -e "  ${GREEN}1${NC}. 启用开机启动"
                echo -e "  ${GREEN}2${NC}. 禁用开机启动"
                echo -e "  ${RED}q${NC}. 返回"
                read -r sc
                case $sc in
                    1) systemctl enable realm && echo -e "${GREEN}已启用${NC}" ;;
                    2) systemctl disable realm && echo -e "${GREEN}已禁用${NC}" ;;
                    q) break ;;
                    *) echo -e "${RED}无效${NC}" ;;
                esac
            done
            continue ;;
        14) [ -f /root/realm/realm ] && show_service_diagnostics || echo -e "${RED}未安装${NC}" ;;
        0) echo -e "${GREEN}感谢使用${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
    # 修复点2：统一在此处等待按键，避免函数内部多次提示
    read -n 1 -s -r -p "按任意键继续..."
done

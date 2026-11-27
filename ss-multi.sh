#!/usr/bin/env bash
# =============================================================================
#  ss-multi.sh — Shadowsocks 多端口 / 多密码 管理面板 (Ubuntu / Debian)
# =============================================================================
#
#  功能:
#    * whiptail TUI 管理界面
#    * 一个配置 = 一个端口 + 一个密码（同一个 ss-server 进程内并行）
#    * 新增 / 删除配置、修改密码
#    * 查看 ss:// 链接，支持 OSC52 复制到本地剪贴板 / 终端显示 / 导出文件
#    * 服务状态查看、重启、加密方式切换、ufw 放行
#    * 默认启用 TCP BBR 拥塞控制（内核级，对所有端口/配置统一生效）
#
#  用法:
#    sudo bash ss-multi.sh            # 打开管理面板
#    sudo bash ss-multi.sh links      # 仅输出全部 ss:// 链接
#    sudo bash ss-multi.sh list       # 仅输出配置列表
#    sudo bash ss-multi.sh restart    # 重启服务
#    sudo bash ss-multi.sh status     # 查看服务状态
#
#  依赖: shadowsocks-libev, jq, curl, whiptail（首次运行自动安装）
# =============================================================================

set -uo pipefail

CONF_DIR="/etc/ss-multi"
CONF_FILE="$CONF_DIR/config.json"
META_FILE="$CONF_DIR/meta.json"
SVC="ss-multi"
UNIT_FILE="/etc/systemd/system/${SVC}.service"
BBR_CONF="/etc/sysctl.d/99-ss-multi-bbr.conf"
DEF_METHOD="aes-256-gcm"
BACKTITLE=" Shadowsocks 管理面板 "
SERVER_IP=""

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# 保证中文界面不乱码
if [ -z "${LANG:-}" ] || [[ "${LANG}" != *UTF-8* && "${LANG}" != *utf8* ]]; then
    export LANG="C.UTF-8"
fi

# ----------------------------------------------------------------------------
# 基础工具
# ----------------------------------------------------------------------------
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行: sudo bash $0"
}

rand_pass() {
    head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16
}

b64url() {
    printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='
}

urlenc() {
    jq -rn --arg s "$1" '$s|@uri'
}

detect_ip() {
    local ip=""
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

# ----------------------------------------------------------------------------
# 依赖安装 / 初始化
# ----------------------------------------------------------------------------
bootstrap() {
    local need=0
    command -v whiptail  >/dev/null 2>&1 || need=1
    command -v jq        >/dev/null 2>&1 || need=1
    command -v curl      >/dev/null 2>&1 || need=1
    command -v ss-server >/dev/null 2>&1 || need=1
    [ "$need" -eq 0 ] && return 0

    info "首次运行，正在安装依赖 (shadowsocks-libev / jq / curl / whiptail)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || die "apt-get update 失败，请检查网络"
    apt-get install -y shadowsocks-libev jq curl whiptail ca-certificates >/dev/null 2>&1

    if ! command -v ss-server >/dev/null 2>&1; then
        info "尝试启用 universe 仓库..."
        apt-get install -y software-properties-common >/dev/null 2>&1
        add-apt-repository -y universe >/dev/null 2>&1
        apt-get update -y >/dev/null 2>&1
        apt-get install -y shadowsocks-libev >/dev/null 2>&1
    fi

    command -v ss-server >/dev/null 2>&1 || die "shadowsocks-libev 安装失败，请手动安装后重试"
    command -v whiptail  >/dev/null 2>&1 || die "whiptail 安装失败"
    command -v jq        >/dev/null 2>&1 || die "jq 安装失败"
    info "依赖安装完成"
}

ensure_unit() {
    cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=Shadowsocks Multi-Config Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c /etc/ss-multi/config.json -u
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # 关掉软件包自带的单实例服务，避免和本面板抢端口
    if systemctl cat shadowsocks-libev.service >/dev/null 2>&1; then
        systemctl disable --now shadowsocks-libev.service >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable "$SVC" >/dev/null 2>&1 || true
}

init_conf() {
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"

    if [ ! -f "$CONF_FILE" ]; then
        local p
        p=$(rand_pass)
        jq -n --arg m "$DEF_METHOD" --arg pw "$p" \
            '{server:"0.0.0.0", port_password:{"8388":$pw}, timeout:300, method:$m, fast_open:false}' \
            > "$CONF_FILE"
        jq -n --arg p "8388" --arg n "默认配置" --arg t "$(date -Is)" \
            '{($p):{name:$n,created:$t}}' > "$META_FILE"
        info "已生成初始配置: 端口 8388 / 密码 $p"
    fi

    chmod 600 "$CONF_FILE"
    [ -f "$META_FILE" ] || echo '{}' > "$META_FILE"
    chmod 600 "$META_FILE"

    ensure_unit
    ensure_bbr || true

    if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
        systemctl start "$SVC" >/dev/null 2>&1 || true
    fi
}

# ----------------------------------------------------------------------------
# 网络优化: TCP BBR
#   BBR 是内核级拥塞控制算法，开启一次即对面板中所有配置/端口同时生效。
# ----------------------------------------------------------------------------
cc_current() { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown; }

bbr_supported() {
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    [[ " $avail " == *" bbr "* ]]
}

bbr_state_text() {
    if [ "$(cc_current)" = "bbr" ]; then
        echo "已启用 (bbr)"
    else
        echo "未启用 ($(cc_current))"
    fi
}

# 幂等: 已启用则直接返回；首次写入 /etc/sysctl.d 并立即生效。
# 提示信息走 stderr，避免污染 `links` 等命令的 stdout 输出。
ensure_bbr() {
    if [ "$(cc_current)" = "bbr" ] && [ -f "$BBR_CONF" ]; then
        return 0
    fi

    if ! bbr_supported; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        bbr_supported || {
            info "当前内核不支持 BBR (需 Linux 4.9+)，已跳过 BBR 优化" >&2
            return 1
        }
    fi

    cat > "$BBR_CONF" <<'EOF'
# ss-multi: TCP BBR 拥塞控制优化（全局生效，覆盖所有配置端口）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    chmod 644 "$BBR_CONF"

    # 某些环境中部分键写入失败不影响 bbr 生效，因此不因 sysctl 返回码中断，以实际算法为准
    sysctl -p "$BBR_CONF" >/dev/null 2>&1 || true

    if [ "$(cc_current)" = "bbr" ]; then
        info "已启用 TCP BBR 拥塞控制（对所有配置生效）" >&2
        return 0
    fi
    info "BBR 参数已写入，但当前拥塞控制仍为 $(cc_current)（容器/受限环境常见）" >&2
    return 1
}

# ----------------------------------------------------------------------------
# 配置读 / 写
# ----------------------------------------------------------------------------
list_ports()  { jq -r '.port_password | keys_unsorted[]' "$CONF_FILE" 2>/dev/null | sort -n; }
cfg_method()  { jq -r '.method // "aes-256-gcm"' "$CONF_FILE" 2>/dev/null; }
get_pass()    { jq -r --arg p "$1" '.port_password[$p] // empty' "$CONF_FILE" 2>/dev/null; }
get_name()    { jq -r --arg p "$1" '.[$p].name // empty' "$META_FILE" 2>/dev/null; }
count_ports() { list_ports | wc -l; }

set_meta_name() {
    local port=$1 name=$2 tmp
    tmp=$(mktemp)
    jq --arg p "$port" --arg n "$name" --arg t "$(date -Is)" \
        '.[$p] = ((.[$p] // {}) + {name:$n, created:(.[$p].created // $t)})' \
        "$META_FILE" > "$tmp" && mv "$tmp" "$META_FILE"
    chmod 600 "$META_FILE"
}

svc_state_text() {
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        echo "运行中 (active)"
    elif systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
        echo "已停止 (inactive)"
    else
        echo "未启用"
    fi
}

svc_restart() {
    systemctl restart "$SVC" >/dev/null 2>&1 || return 1
    sleep 1
    systemctl is-active --quiet "$SVC"
}

listening_ports() {
    ss -lntu 2>/dev/null \
        | awk 'NR>1 {print $5}' \
        | awk -F'[.:]' 'NF {print $NF}' \
        | sort -u | tr '\n' ' '
}

# ----------------------------------------------------------------------------
# ss:// 链接
# ----------------------------------------------------------------------------
gen_link_for() {
    local p=$1 host=${2:-$SERVER_IP}
    local m pw n
    m=$(cfg_method)
    pw=$(get_pass "$p")
    [ -z "$pw" ] && return 1
    n=$(get_name "$p")
    [ -z "$n" ] && n="SS-$p"
    printf 'ss://%s@%s:%s#%s\n' "$(b64url "${m}:${pw}")" "$host" "$p" "$(urlenc "$n")"
}

gen_all_links() {
    local p
    while read -r p; do
        [ -n "$p" ] && gen_link_for "$p"
    done < <(list_ports)
}

copy_clip() {
    local b64
    b64=$(printf '%s' "$1" | base64 -w0)
    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty 2>/dev/null || true
    else
        printf '\033]52;c;%s\a' "$b64" > /dev/tty 2>/dev/null || true
    fi
}

term_show() {
    local f=$1 title=$2
    clear
    printf '\n\033[1m%s\033[0m\n\n' "$title"
    cat "$f"
    printf '\n%s\n' "----------------------------------------------------------------"
    printf '%s\n' "提示: 大部分终端可直接用鼠标选中复制；Windows Terminal / iTerm2 / Kitty"
    printf '%s\n' "      支持本面板的「复制到剪贴板」按钮 (OSC 52)。"
    printf '\n按回车返回...'
    read -r _ || true
}

# ----------------------------------------------------------------------------
# TUI 小工具
# ----------------------------------------------------------------------------
msg()    { whiptail --backtitle "$BACKTITLE" --title "${2:-提示}"     --msgbox "$1" 0 76 3>&1 1>&2 2>&3; }
confirm(){ whiptail --backtitle "$BACKTITLE" --title "${2:-确认}"     --yesno  "$1" 0 70 3>&1 1>&2 2>&3; }
ask_input() { whiptail --backtitle "$BACKTITLE" --title "$1" --inputbox    "$2" 10 66 "$3" 3>&1 1>&2 2>&3; }
ask_pass()  { whiptail --backtitle "$BACKTITLE" --title "$1" --passwordbox "$2" 10 66 "$3" 3>&1 1>&2 2>&3; }

pick_port() {
    local title=$1 ports items=() p n sel
    mapfile -t ports < <(list_ports)
    if [ "${#ports[@]}" -eq 0 ]; then
        msg "当前还没有任何配置，请先新增。" "提示"
        return 1
    fi
    for p in "${ports[@]}"; do
        n=$(get_name "$p"); [ -z "$n" ] && n="配置-$p"
        items+=("$p" "$n")
    done
    sel=$(whiptail --backtitle "$BACKTITLE" --title "选择配置" --menu "$title" \
            22 66 12 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$sel"
}

# ----------------------------------------------------------------------------
# 功能: 查看列表
# ----------------------------------------------------------------------------
view_configs() {
    local f p pw n ls lst
    f=$(mktemp)
    lst=$(listening_ports)
    {
        printf '服务状态 : %s\n' "$(svc_state_text)"
        printf '加密方式 : %s\n' "$(cfg_method)"
        printf '拥塞控制 : %s\n' "$(bbr_state_text)"
        printf '配置数量 : %s\n' "$(count_ports)"
        printf '配置文件 : %s\n' "$CONF_FILE"
        printf '服务器IP : %s\n\n' "${SERVER_IP:-未知}"
        while read -r p; do
            [ -z "$p" ] && continue
            pw=$(get_pass "$p")
            n=$(get_name "$p"); [ -z "$n" ] && n="-"
            if [[ " $lst " == *" $p "* ]]; then ls="监听着"; else ls="未监听"; fi
            printf '────────────────────────────────────────────────────\n'
            printf '  端口 : %s\n' "$p"
            printf '  名称 : %s\n' "$n"
            printf '  密码 : %s\n' "$pw"
            printf '  状态 : %s\n' "$ls"
        done < <(list_ports)
        printf '────────────────────────────────────────────────────\n'
    } > "$f"
    whiptail --backtitle "$BACKTITLE" --title "配置列表" --scrolltext \
        --textbox "$f" 24 78 3>&1 1>&2 2>&3
    rm -f "$f"
}

# ----------------------------------------------------------------------------
# 功能: 新增配置
# ----------------------------------------------------------------------------
add_config() {
    local port pw name used
    while :; do
        port=$(ask_input "新增配置" "请输入端口号 (1-65535)\n建议使用 10000-60000 之间的高位端口" "") || return 0
        port=$(printf '%s' "$port" | tr -d '[:space:]')
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            msg "端口无效，请输入 1-65535 之间的数字。" "错误"
            continue
        fi
        if [ -n "$(get_pass "$port")" ]; then
            msg "端口 $port 已经在配置中，请换一个。" "错误"
            continue
        fi
        used=$(listening_ports)
        if [[ " $used " == *" $port "* ]]; then
            confirm "端口 $port 目前已被其它程序占用，仍然要继续吗？" "端口占用" || continue
        fi
        break
    done

    pw=$(ask_pass "设置密码" "请输入端口 $port 的密码\n留空则自动生成 16 位随机密码" "") || return 0
    pw=$(printf '%s' "$pw" | tr -d '\r\n')
    if [ -z "$pw" ]; then
        pw=$(rand_pass)
        msg "已自动生成密码: $pw" "提示"
    fi

    name=$(ask_input "配置名称" "给这个配置起个名字 (仅用于区分，可留空)" "配置-$port") || return 0
    name=$(printf '%s' "$name" | tr -d '\r')
    [ -z "$name" ] && name="配置-$port"

    local tmp
    tmp=$(mktemp)
    jq --arg p "$port" --arg pw "$pw" '.port_password[$p] = $pw' "$CONF_FILE" > "$tmp" \
        && mv "$tmp" "$CONF_FILE" || { rm -f "$tmp"; msg "写入配置失败。" "错误"; return 1; }
    chmod 600 "$CONF_FILE"
    set_meta_name "$port" "$name"

    # 新配置同样享有 BBR（幂等：已开启则瞬间返回）
    ensure_bbr || true
    fw_open_port "$port"

    if svc_restart; then
        SERVER_IP=$(detect_ip)
        local link; link=$(gen_link_for "$port")
        if confirm "配置已创建并生效:\n\n端口: $port\n名称: $name\n密码: $pw\n\n是否现在复制 ss:// 链接到剪贴板？" "完成"; then
            copy_clip "$link"
            msg "已发送复制指令到终端:\n\n$link\n\n如果剪贴板里没有内容（终端不支持 OSC52），\n请在「SS 链接」菜单使用「在终端显示」。\n\n云服务器请记得在安全组放行 $port 端口。" "已复制"
        fi
    else
        msg "配置已写入，但服务启动失败。\n请检查日志:\n  journalctl -u $SVC -n 50" "警告"
    fi
}

# ----------------------------------------------------------------------------
# 功能: 删除配置
# ----------------------------------------------------------------------------
delete_config() {
    local port n pwtmp
    port=$(pick_port "选择要删除的配置") || return 0
    n=$(get_name "$port"); [ -z "$n" ] && n="配置-$port"
    confirm "确定删除「$n」(端口 $port) 吗？\n\n删除后该端口会立即关闭，链接同时失效。" "删除确认" || return 0

    pwtmp=$(mktemp)
    jq --arg p "$port" 'del(.port_password[$p])' "$CONF_FILE" > "$pwtmp" \
        && mv "$pwtmp" "$CONF_FILE" || { rm -f "$pwtmp"; msg "删除失败。" "错误"; return 1; }
    pwtmp=$(mktemp)
    jq --arg p "$port" 'del(.[$p])' "$META_FILE" > "$pwtmp" && mv "$pwtmp" "$META_FILE"
    chmod 600 "$CONF_FILE" "$META_FILE"

    svc_restart
    msg "已删除端口 $port 的配置。\n\n提示: ufw 放行规则不会被自动删除，如需清理:\n  ufw delete allow $port/tcp\n  ufw delete allow $port/udp" "完成"
}

# ----------------------------------------------------------------------------
# 功能: 修改密码
# ----------------------------------------------------------------------------
change_password() {
    local port n pw link
    port=$(pick_port "选择要修改密码的配置") || return 0
    n=$(get_name "$port"); [ -z "$n" ] && n="配置-$port"

    pw=$(ask_pass "修改密码" "端口 $port ($n) 的新密码\n留空则自动生成随机密码" "") || return 0
    pw=$(printf '%s' "$pw" | tr -d '\r\n')
    if [ -z "$pw" ]; then
        pw=$(rand_pass)
        msg "已自动生成新密码: $pw" "提示"
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg p "$port" --arg pw "$pw" '.port_password[$p] = $pw' "$CONF_FILE" > "$tmp" \
        && mv "$tmp" "$CONF_FILE" || { rm -f "$tmp"; msg "写入失败。" "错误"; return 1; }
    chmod 600 "$CONF_FILE"

    if svc_restart; then
        SERVER_IP=$(detect_ip)
        link=$(gen_link_for "$port")
        if confirm "密码已修改并生效:\n\n端口: $port\n新密码: $pw\n\n旧链接已失效，是否复制新链接到剪贴板？" "完成"; then
            copy_clip "$link"
            msg "已发送复制指令到终端:\n\n$link" "已复制"
        fi
    else
        msg "服务重启失败，请查看日志:\n  journalctl -u $SVC -n 50" "错误"
    fi
}

# ----------------------------------------------------------------------------
# 功能: SS 链接
# ----------------------------------------------------------------------------
copy_one_link() {
    local port link
    port=$(pick_port "选择要复制的配置") || return 0
    link=$(gen_link_for "$port")
    copy_clip "$link"
    msg "已发送复制指令到终端:\n\n$link\n\n如果没有复制成功（终端不支持 OSC52），\n请改用「在终端显示」手动复制。" "已复制"
}

copy_all_links() {
    local f
    f=$(mktemp)
    gen_all_links > "$f"
    copy_clip "$(cat "$f")"
    local cnt; cnt=$(wc -l < "$f")
    rm -f "$f"
    msg "已把 $cnt 条链接发送到终端剪贴板。\n\n如果剪贴板为空，说明终端不支持 OSC52，\n请改用「在终端显示全部链接」。" "已复制"
}

display_all_links() {
    local f
    f=$(mktemp)
    { printf '# 服务器: %s   加密: %s   生成时间: %s\n\n' "$SERVER_IP" "$(cfg_method)" "$(date '+%F %T')"; gen_all_links; } > "$f"
    term_show "$f" "全部 SS 链接"
    rm -f "$f"
}

display_one_link() {
    local port f
    port=$(pick_port "选择要显示的配置") || return 0
    f=$(mktemp)
    gen_link_for "$port" > "$f"
    term_show "$f" "端口 $port 的 SS 链接"
    rm -f "$f"
}

export_links() {
    local out="/root/ss-links.txt"
    {
        printf '# 服务器: %s\n' "$SERVER_IP"
        printf '# 加密方式: %s\n' "$(cfg_method)"
        printf '# 生成时间: %s\n\n' "$(date '+%F %T')"
        gen_all_links
    } > "$out"
    chmod 600 "$out"
    msg "全部链接已导出到:\n\n$out\n\n查看: cat $out" "导出完成"
}

show_links_menu() {
    SERVER_IP=$(detect_ip)
    local c
    while :; do
        clear
        c=$(whiptail --backtitle "$BACKTITLE" --title "SS 链接" --menu \
            "服务器: ${SERVER_IP:-未知}   加密: $(cfg_method)" 20 70 9 \
            "1" "复制单个配置的链接到剪贴板" \
            "2" "复制全部链接到剪贴板" \
            "3" "在终端显示全部链接" \
            "4" "在终端显示单个配置的链接" \
            "5" "导出全部链接到 /root/ss-links.txt" \
            "0" "返回" 3>&1 1>&2 2>&3) || return 0
        case "$c" in
            1) copy_one_link ;;
            2) copy_all_links ;;
            3) display_all_links ;;
            4) display_one_link ;;
            5) export_links ;;
            0|*) return 0 ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 功能: 加密方式
# ----------------------------------------------------------------------------
change_method() {
    local cur sel tmp
    cur=$(cfg_method)
    clear
    sel=$(whiptail --backtitle "$BACKTITLE" --title "加密方式" --menu \
        "当前加密方式: $cur\n\n修改后所有配置的链接都会变化，需要同步更新客户端。" 22 72 8 \
        "aes-256-gcm"             "推荐 · AEAD" \
        "aes-128-gcm"             "AEAD" \
        "chacha20-ietf-poly1305"  "AEAD · 移动设备友好" \
        "xchacha20-ietf-poly1305" "AEAD" \
        "aes-256-cfb"             "旧版 · 兼容性最好" \
        "chacha20-ietf"           "旧版" \
        3>&1 1>&2 2>&3) || return 0
    [ -z "$sel" ] && return 0
    if [ "$sel" = "$cur" ]; then msg "加密方式未改变。" "提示"; return 0; fi

    tmp=$(mktemp)
    jq --arg m "$sel" '.method = $m' "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"
    chmod 600 "$CONF_FILE"

    if svc_restart; then
        msg "已切换加密方式为: $sel\n\n请在所有客户端中同步修改，否则无法连接。" "完成"
    else
        msg "服务重启失败，请查看日志:\n  journalctl -u $SVC -n 50" "错误"
    fi
}

# ----------------------------------------------------------------------------
# 功能: 服务管理 / 防火墙
# ----------------------------------------------------------------------------
show_status() {
    clear
    printf '\n\033[1m=== systemctl status %s ===\033[0m\n\n' "$SVC"
    systemctl status "$SVC" --no-pager -l 2>&1 | head -n 30
    printf '\n\033[1m=== 最近日志 ===\033[0m\n\n'
    journalctl -u "$SVC" -n 15 --no-pager 2>&1
    printf '\n按回车返回...'
    read -r _ || true
}

service_menu() {
    local c
    while :; do
        clear
        c=$(whiptail --backtitle "$BACKTITLE" --title "服务管理" --menu \
            "当前状态: $(svc_state_text)" 18 62 6 \
            "1" "查看状态与日志" \
            "2" "重启服务" \
            "3" "停止服务" \
            "4" "启动服务" \
            "0" "返回" 3>&1 1>&2 2>&3) || return 0
        case "$c" in
            1) show_status ;;
            2) if svc_restart; then msg "服务已重启。" "完成"; else msg "重启失败，请查看日志。" "错误"; fi ;;
            3) systemctl stop "$SVC" >/dev/null 2>&1; msg "服务已停止。" "完成" ;;
            4) systemctl start "$SVC" >/dev/null 2>&1; sleep 1
               if systemctl is-active --quiet "$SVC"; then msg "服务已启动。" "完成"; else msg "启动失败，请查看日志。" "错误"; fi ;;
            0|*) return 0 ;;
        esac
    done
}

fw_open_port() {
    local port=$1 st
    command -v ufw >/dev/null 2>&1 || return 0
    st=$(ufw status 2>/dev/null || true)
    [[ "$st" == *"Status: active"* ]] || return 0
    ufw allow "$port/tcp" >/dev/null 2>&1
    ufw allow "$port/udp" >/dev/null 2>&1
}

fw_sync_all() {
    local st p
    if ! command -v ufw >/dev/null 2>&1; then
        msg "系统未安装 ufw，跳过。\n\n请记得在云厂商安全组中放行对应端口。" "提示"; return 0
    fi
    st=$(ufw status 2>/dev/null || true)
    if [[ "$st" != *"Status: active"* ]]; then
        msg "ufw 当前未启用，无需操作。\n\n请记得在云厂商安全组中放行对应端口。" "提示"; return 0
    fi
    while read -r p; do
        [ -z "$p" ] && continue
        ufw allow "$p/tcp" >/dev/null 2>&1
        ufw allow "$p/udp" >/dev/null 2>&1
    done < <(list_ports)
    msg "已为所有配置端口放行 TCP/UDP。" "完成"
}

bbr_menu() {
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 未知)
    if ! confirm "当前拥塞控制: $(bbr_state_text)\n可用算法: $avail\n\nBBR 是内核级优化，对本面板中的所有配置(端口)同时生效，\n无需逐个端口设置。\n\n是否立即应用 / 重新应用 BBR？" "网络优化 (BBR)"; then
        return 0
    fi
    if ensure_bbr; then
        msg "BBR 已启用。\n\n拥塞控制: $(cc_current)\n队列规则: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)\n\n对所有配置(端口)生效。" "完成"
    else
        msg "BBR 启用失败。\n\n当前拥塞控制: $(cc_current)\n可用算法: $avail\n\n常见原因:\n  - 内核低于 4.9 (uname -r 查看)\n  - 运行在容器 / 受限环境" "失败"
    fi
}

# ----------------------------------------------------------------------------
# 主菜单
# ----------------------------------------------------------------------------
main_menu() {
    local c
    while :; do
        clear
        c=$(whiptail --backtitle "$BACKTITLE" --title " Shadowsocks 管理面板 " --menu \
            "服务: $(svc_state_text)   配置数: $(count_ports)   加密: $(cfg_method)\nBBR: $(bbr_state_text)" \
            22 70 12 \
            "1" "查看所有配置" \
            "2" "新增配置 (端口 + 密码)" \
            "3" "删除配置" \
            "4" "修改密码" \
            "5" "查看 / 复制 SS 链接" \
            "6" "更改加密方式" \
            "7" "服务状态 / 重启 / 停止" \
            "8" "防火墙放行已有端口 (ufw)" \
            "9" "网络优化 / BBR 拥塞控制" \
            "0" "退出" 3>&1 1>&2 2>&3) || break
        case "$c" in
            1) view_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) change_password ;;
            5) show_links_menu ;;
            6) change_method ;;
            7) service_menu ;;
            8) fw_sync_all ;;
            9) bbr_menu ;;
            0) break ;;
        esac
    done
    clear
    echo "再见。"
}

# ----------------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------------
main() {
    require_root

    case "${1:-}" in
        links)
            bootstrap; init_conf
            SERVER_IP=$(detect_ip)
            gen_all_links
            exit 0
            ;;
        list)
            bootstrap; init_conf
            while read -r p; do
                [ -z "$p" ] && continue
                printf '%s\t%s\n' "$p" "$(get_name "$p")"
            done < <(list_ports)
            exit 0
            ;;
        restart)
            bootstrap; init_conf
            if svc_restart; then echo "重启成功"; else echo "重启失败"; exit 1; fi
            exit 0
            ;;
        status)
            bootstrap; init_conf
            systemctl status "$SVC" --no-pager -l
            exit 0
            ;;
        ""|-h|--help|help)
            if [ -n "${1:-}" ]; then
                sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
                exit 0
            fi
            ;;
        *)
            die "未知参数: $1 (可用: links | list | restart | status)"
            ;;
    esac

    [ -t 0 ] || die "请在交互式终端中运行本脚本"
    bootstrap
    init_conf
    SERVER_IP=$(detect_ip)
    main_menu
}

main "$@"

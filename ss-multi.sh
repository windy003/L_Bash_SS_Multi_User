#!/usr/bin/env bash
# =============================================================================
#  ss-multi.sh — Shadowsocks 多端口 / 多密码 管理面板 (Ubuntu / Debian)
# =============================================================================
#
#  功能:
#    * 管理界面：菜单按数字键立即选择（无需方向键/回车），输入框使用 whiptail
#    * 一个配置 = 一个端口 + 一个密码（ss-manager 按端口拉起多个 ss-server 实例）
#    * 新增 / 删除配置、修改密码
#    * 在「查看所有配置」中逐个查看详情、复制 ss:// 链接（OSC52）/ 终端显示
#    * 服务状态查看、重启（新增端口时后台自动放行 ufw）
#    * 后台自动启用 TCP BBR 拥塞控制（无菜单入口，对所有端口/配置统一生效）
#    * 一键卸载（可单独选择卸载软件包）
#
#  用法:
#    sudo bash ss-multi.sh            # 打开管理面板
#    sudo bash ss-multi.sh links      # 仅输出全部 ss:// 链接
#    sudo bash ss-multi.sh list       # 仅输出配置列表
#    sudo bash ss-multi.sh restart    # 重启服务
#    sudo bash ss-multi.sh status     # 查看服务状态
#    sudo bash ss-multi.sh uninstall  # 卸载面板并清理配置
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

# 终端文字颜色：统一黑色（30 = 黑，0 = 复位）。
# 如果终端是深色背景导致文字看不见，把 CLR 改成空字符串 CLR='' 即可用终端默认前景色。
CLR=$'\033[30m'
CLR_OFF=$'\033[0m'

# ----------------------------------------------------------------------------
# 基础工具
# ----------------------------------------------------------------------------
die()  { printf '%s[错误]%s %s\n' "$CLR" "$CLR_OFF" "$*" >&2; exit 1; }
info() { printf '%s%s%s\n' "$CLR" "$*" "$CLR_OFF"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行: sudo bash $0"
}

rand_pass() {
    head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16
}

# 随机挑一个高位端口 (10000-60000)，避开已有配置和当前正在监听的端口
rand_port() {
    local p ports used i
    ports=" $(list_ports 2>/dev/null | tr '\n' ' ') "
    used=" $(listening_ports 2>/dev/null) "
    for i in $(seq 1 200); do
        p=$(( RANDOM % 50001 + 10000 ))
        [[ "$ports" == *" $p "* ]] && continue
        [[ "$used" == *" $p "* ]] && continue
        printf '%s' "$p"
        return 0
    done
    return 1
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
    command -v whiptail   >/dev/null 2>&1 || need=1
    command -v jq         >/dev/null 2>&1 || need=1
    command -v curl       >/dev/null 2>&1 || need=1
    command -v ss-server  >/dev/null 2>&1 || need=1
    command -v ss-manager >/dev/null 2>&1 || need=1
    [ "$need" -eq 0 ] && return 0

    info "首次运行，正在安装依赖 (shadowsocks-libev / jq / curl / whiptail)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || die "apt-get update 失败，请检查网络"
    apt-get install -y shadowsocks-libev jq curl whiptail ca-certificates >/dev/null 2>&1

    if ! command -v ss-server >/dev/null 2>&1 || ! command -v ss-manager >/dev/null 2>&1; then
        info "尝试启用 universe 仓库..."
        apt-get install -y software-properties-common >/dev/null 2>&1
        add-apt-repository -y universe >/dev/null 2>&1
        apt-get update -y >/dev/null 2>&1
        apt-get install -y shadowsocks-libev >/dev/null 2>&1
    fi

    command -v ss-server  >/dev/null 2>&1 || die "shadowsocks-libev 安装失败，请手动安装后重试"
    command -v ss-manager >/dev/null 2>&1 || die "ss-manager 安装失败（shadowsocks-libev 包内应包含），请手动检查"
    command -v whiptail   >/dev/null 2>&1 || die "whiptail 安装失败"
    command -v jq         >/dev/null 2>&1 || die "jq 安装失败"
    info "依赖安装完成"
}

# ss-server 不解析 config.json 里的 port_password（只有 ss-manager 支持），
# 所以由 ss-manager 读取同一份配置，并按端口拉起多个 ss-server 子进程。
ensure_unit() {
    local tmp changed=0
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
[Unit]
Description=Shadowsocks Multi-Config Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/ss-manager -c /etc/ss-multi/config.json -u --workdir /etc/ss-multi
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    if ! cmp -s "$tmp" "$UNIT_FILE" 2>/dev/null; then
        changed=1
        install -m 644 "$tmp" "$UNIT_FILE"
    fi
    rm -f "$tmp"

    # 关掉软件包自带的单实例服务，避免和本面板抢端口
    if systemctl cat shadowsocks-libev.service >/dev/null 2>&1; then
        systemctl disable --now shadowsocks-libev.service >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable "$SVC" >/dev/null 2>&1 || true

    # 单元有变化且服务仍在跑（例如从旧的 ss-server 单元升级）-> 立即重启生效
    if [ "$changed" -eq 1 ] && systemctl is-active --quiet "$SVC" 2>/dev/null; then
        systemctl restart "$SVC" >/dev/null 2>&1 || true
    fi
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
    printf '\n%s%s%s\n\n' "$CLR" "$title" "$CLR_OFF"
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
# 危险操作使用: 默认焦点在「否」，回车不会误删
confirm_no(){ whiptail --backtitle "$BACKTITLE" --title "${2:-确认}" --defaultno --yesno "$1" 0 70 3>&1 1>&2 2>&3; }
ask_input() { whiptail --backtitle "$BACKTITLE" --title "$1" --inputbox    "$2" 10 66 "$3" 3>&1 1>&2 2>&3; }
ask_pass()  { whiptail --backtitle "$BACKTITLE" --title "$1" --passwordbox "$2" 10 66 "$3" 3>&1 1>&2 2>&3; }

# 自绘单键菜单：按数字键立即选中，无需方向键 / 回车。
#   用法: menu_pick <标题> <说明> tag1 desc1 [tag2 desc2 ...]
#   说明里的 \n 会被展开；超过 9 项自动分页（n 下一页 / p 上一页），q 取消。
#   界面绘制走 stderr，选中项从 stdout 返回，便于 sel=$(menu_pick ...) 捕获。
menu_pick() {
    local title=$1 prompt=$2; shift 2
    local tags=() descs=() key i page=0 pages=1 per=9 total start end
    while [ $# -ge 2 ]; do
        tags+=("$1"); descs+=("$2"); shift 2
    done
    total=${#tags[@]}
    [ "$total" -eq 0 ] && return 1
    pages=$(( (total + per - 1) / per ))

    while :; do
        start=$(( page * per ))
        end=$(( start + per - 1 ))
        [ "$end" -ge "$total" ] && end=$(( total - 1 ))
        {
            clear
            printf '\n%s== %s ==%s\n\n' "$CLR" "$title" "$CLR_OFF"
            [ -n "$prompt" ] && printf '%b\n\n' "$prompt"
            for ((i = start; i <= end; i++)); do
                printf '  %s%d%s) %s\n' "$CLR" "$(( i - start + 1 ))" "$CLR_OFF" "${descs[$i]}"
            done
            printf '\n'
            if [ "$pages" -gt 1 ]; then
                printf '  %s第 %d/%d 页  n 下一页  p 上一页%s\n' "$CLR" "$(( page + 1 ))" "$pages" "$CLR_OFF"
            fi
            printf '  %s按数字键立即选择，q 返回%s\n' "$CLR" "$CLR_OFF"
        } >&2

        if ! IFS= read -rsn1 key; then
            return 1
        fi
        case "$key" in
            q|Q) return 1 ;;
            n|N) [ $(( page + 1 )) -lt "$pages" ] && page=$(( page + 1 )); continue ;;
            p|P) [ "$page" -gt 0 ] && page=$(( page - 1 )); continue ;;
            [1-9])
                i=$(( start + key - 1 ))
                if [ "$i" -le "$end" ] && [ "$i" -lt "$total" ]; then
                    printf '%s' "${tags[$i]}"
                    return 0
                fi
                printf '\a' >&2
                ;;
            *)
                # 吞掉方向键等 ESC 序列，避免一次按键触发多次重绘
                [ "$key" = $'\e' ] && { IFS= read -rsn2 -t 0.05 _ 2>/dev/null || true; }
                printf '\a' >&2
                ;;
        esac
    done
}

pick_port() {
    local title=$1 ports items=() p n sel
    mapfile -t ports < <(list_ports)
    if [ "${#ports[@]}" -eq 0 ]; then
        msg "当前还没有任何配置，请先新增。" "提示"
        return 1
    fi
    for p in "${ports[@]}"; do
        [ -z "$p" ] && continue
        n=$(get_name "$p"); [ -z "$n" ] && n="配置-$p"
        items+=("$p" "端口 $p · $n")
    done
    sel=$(menu_pick "$title" "按数字键选择，q 取消" "${items[@]}") || return 1
    printf '%s' "$sel"
}

# ----------------------------------------------------------------------------
# 功能: 查看列表
#   列出所有配置；选中某个配置后查看详情，并可复制它的 ss:// 链接。
# ----------------------------------------------------------------------------
config_detail() {
    local port=$1 n pw st link tf c
    n=$(get_name "$port"); [ -z "$n" ] && n="配置-$port"
    pw=$(get_pass "$port"); [ -z "$pw" ] && pw="(缺失)"
    if [[ " $(listening_ports) " == *" $port "* ]]; then st="监听着"; else st="未监听"; fi

    link=$(gen_link_for "$port" 2>/dev/null) || true
    [ -z "$link" ] && link="(无法生成，密码缺失)"

    while :; do
        c=$(menu_pick "配置详情 · 端口 $port" \
            "名称: $n\n端口: $port\n密码: $pw\n状态: $st" \
            "1" "复制 ss:// 链接到剪贴板" \
            "2" "在终端显示完整链接") || return 0
        case "$c" in
            1)
                copy_clip "$link"
                msg "已发送复制指令到终端:\n\n$link\n\n如果剪贴板没有内容（终端不支持 OSC52），\n请改用「在终端显示完整链接」手动复制。" "已复制"
                ;;
            2)
                tf=$(mktemp)
                printf '%s\n' "$link" > "$tf"
                term_show "$tf" "端口 $port 的 SS 链接"
                rm -f "$tf"
                ;;
            *) return 0 ;;
        esac
    done
}

view_configs() {
    local ports=() items=() p n st sel lst ip
    mapfile -t ports < <(list_ports)
    if [ "${#ports[@]}" -eq 0 ]; then
        msg "当前还没有任何配置，请先新增。" "提示"
        return 0
    fi
    ip=$(detect_ip); [ -n "$ip" ] && SERVER_IP=$ip

    while :; do
        lst=$(listening_ports)
        items=()
        for p in "${ports[@]}"; do
            [ -z "$p" ] && continue
            n=$(get_name "$p"); [ -z "$n" ] && n="配置-$p"
            if [[ " $lst " == *" $p "* ]]; then st="[运行]"; else st="[停止]"; fi
            items+=("$p" "$st 端口 $p · $n")
        done

        sel=$(menu_pick "配置列表" \
            "服务: $(svc_state_text)   加密: $(cfg_method)\n服务器: ${SERVER_IP:-未知}   配置数: ${#ports[@]}\n\n选择配置查看信息 / 复制 ss:// 链接" \
            "${items[@]}") || return 0
        config_detail "$sel"
    done
}

# ----------------------------------------------------------------------------
# 功能: 新增配置
# ----------------------------------------------------------------------------
add_config() {
    local port pw name used def
    def=$(rand_port) || def=""
    while :; do
        port=$(ask_input "新增配置" "请输入端口号 (1-65535)\n建议使用 10000-60000 之间的高位端口\n已随机预填一个可用端口，直接回车即可使用" "$def") || return 0
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

    fw_close_port "$port"
    svc_restart
    msg "已删除端口 $port 的配置。" "完成"
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
# 功能: 服务管理
# ----------------------------------------------------------------------------
show_status() {
    clear
    printf '\n%s=== systemctl status %s ===%s\n\n' "$CLR" "$SVC" "$CLR_OFF"
    systemctl status "$SVC" --no-pager -l 2>&1 | head -n 30
    printf '\n%s=== 最近日志 ===%s\n\n' "$CLR" "$CLR_OFF"
    journalctl -u "$SVC" -n 15 --no-pager 2>&1
    printf '\n按回车返回...'
    read -r _ || true
}

service_menu() {
    local c
    while :; do
        c=$(menu_pick "服务管理" "当前状态: $(svc_state_text)" \
            "1" "查看状态与日志" \
            "2" "重启服务" \
            "3" "停止服务" \
            "4" "启动服务") || return 0
        case "$c" in
            1) show_status ;;
            2) if svc_restart; then msg "服务已重启。" "完成"; else msg "重启失败，请查看日志。" "错误"; fi ;;
            3) systemctl stop "$SVC" >/dev/null 2>&1; msg "服务已停止。" "完成" ;;
            4) systemctl start "$SVC" >/dev/null 2>&1; sleep 1
               if systemctl is-active --quiet "$SVC"; then msg "服务已启动。" "完成"; else msg "启动失败，请查看日志。" "错误"; fi ;;
            *) return 0 ;;
        esac
    done
}

# 防火墙在后台静默处理：新增端口自动放行，删除配置自动回收
fw_open_port() {
    local port=$1 st
    command -v ufw >/dev/null 2>&1 || return 0
    st=$(ufw status 2>/dev/null || true)
    [[ "$st" == *"Status: active"* ]] || return 0
    ufw allow "$port/tcp" >/dev/null 2>&1
    ufw allow "$port/udp" >/dev/null 2>&1
}

fw_close_port() {
    local port=$1
    command -v ufw >/dev/null 2>&1 || return 0
    ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$port/udp" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# 功能: 卸载
#   所有确认默认都是「否」，避免误触。
# ----------------------------------------------------------------------------
do_uninstall() {
    local ports port rmv_pkg=0 ufw_txt="未安装，跳过"
    ports=$(list_ports 2>/dev/null || true)

    confirm_no "即将卸载 Shadowsocks 多用户面板，将执行:\n\n  - 停止并禁用服务: $SVC\n  - 删除 systemd 单元: $UNIT_FILE\n  - 删除配置目录: $CONF_DIR\n    (含全部端口、密码、备注)\n  - 回收本面板放行的 ufw 端口\n\n此操作不可恢复！确定继续？" "卸载确认" || return 1

    confirm_no "是否卸载 shadowsocks-libev 软件包？\n\n注意: 若系统上还有其它程序依赖它，请选「否」。" "软件包" && rmv_pkg=1

    # 1) 停止并移除服务
    systemctl disable --now "$SVC" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true

    # 2) 回收 ufw 规则（使用卸载前缓存的端口列表）
    if command -v ufw >/dev/null 2>&1; then
        ufw_txt="已清理"
        while read -r port; do
            [ -z "$port" ] && continue
            ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
            ufw delete allow "$port/udp" >/dev/null 2>&1 || true
        done <<< "$ports"
    fi

    # 3) 删除配置
    rm -rf "$CONF_DIR"

    # 4) 回退本脚本写入的 BBR 配置
    rm -f "$BBR_CONF"
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true

    # 5) 卸载软件包
    if [ "$rmv_pkg" -eq 1 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y shadowsocks-libev >/dev/null 2>&1 || true
    fi

    local pkg_txt="保留"
    [ "$rmv_pkg" -eq 1 ] && pkg_txt="已卸载"

    msg "卸载完成。\n\n  - 服务 / systemd 单元 : 已移除\n  - 配置目录            : 已删除\n  - ufw 端口规则        : $ufw_txt\n  - BBR 优化            : 已移除\n  - shadowsocks-libev   : $pkg_txt" "完成"
    return 0
}

# ----------------------------------------------------------------------------
# 主菜单
# ----------------------------------------------------------------------------
main_menu() {
    local c
    while :; do
        c=$(menu_pick "Shadowsocks 管理面板" \
            "服务: $(svc_state_text)   配置数: $(count_ports)   加密: $(cfg_method)" \
            "1" "查看所有配置 (含复制链接)" \
            "2" "新增配置 (端口 + 密码)" \
            "3" "删除配置" \
            "4" "修改密码" \
            "5" "服务状态 / 重启 / 停止" \
            "6" "卸载面板 / 清理配置") || break
        case "$c" in
            1) view_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) change_password ;;
            5) service_menu ;;
            6) if do_uninstall; then clear; echo "卸载完成，再见。"; exit 0; fi ;;
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
        uninstall)
            [ -t 0 ] || die "卸载需要交互式终端确认，请在终端中运行"
            command -v whiptail >/dev/null 2>&1 || die "缺少 whiptail，请先安装: apt-get install -y whiptail"
            do_uninstall
            exit $?
            ;;
        ""|-h|--help|help)
            if [ -n "${1:-}" ]; then
                sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
                exit 0
            fi
            ;;
        *)
            die "未知参数: $1 (可用: links | list | restart | status | uninstall)"
            ;;
    esac

    [ -t 0 ] || die "请在交互式终端中运行本脚本"
    bootstrap
    init_conf
    SERVER_IP=$(detect_ip)
    main_menu
}

main "$@"

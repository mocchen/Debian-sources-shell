#!/bin/bash
# =============================================================================
#  Debian 换源一键脚本 (source.sh)
#  作者: 末晨   https://blog.mochen.one
#
#  v2.0.0
#    - 按 VERSION_ID / VERSION_CODENAME 自动识别发行版，Debian 9 ~ 14 及以后版本
#      无需再改脚本；已 EOL 的版本自动切到官方归档源 archive.debian.org
#    - 同时支持 deb822 (/etc/apt/sources.list.d/debian.sources) 与传统
#      /etc/apt/sources.list，按当前系统实际使用的那一种写入，避免重复源
#    - 写入前快照备份整个源配置，一键回滚；冲突的旧源文件自动停用/去重
#    - 支持非交互参数，便于批量部署与自动化
# =============================================================================

set -u -o pipefail

SCRIPT_VERSION="2.0.0"

# ---------------------------------------------------------------------------
# 颜色
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;36m'
    NC=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' NC=''
fi

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------
MODE="menu"          # menu | restore | list-backups | show | help
MIRROR=""            # official/tuna/ustc/aliyun/tencent/huawei/nju
FMT="auto"           # auto | list | deb822
WITH_SRC="auto"      # auto | 1 | 0
WITH_BACKPORTS=1
DO_UPDATE=1
DO_UPGRADE=0
ASSUME_YES=0
FORCE=0
PRINT_ONLY=0
CODENAME_OVERRIDE=""
RESTORE_TARGET=""
ROOT="/"

# ---------------------------------------------------------------------------
# 路径（ROOT 仅用于调试/离线预览，正常为 /）
# ---------------------------------------------------------------------------
normalize_root() {
    ROOT="${ROOT%/}"
}

APT_DIR=""          # $ROOT/etc/apt
LIST_FILE=""        # $ROOT/etc/apt/sources.list
D822_FILE=""        # $ROOT/etc/apt/sources.list.d/debian.sources
SNAP_BASE=""        # $ROOT/var/backups/apt-dsh
SNAP_DIR=""         # 本次写入前的快照目录

init_paths() {
    normalize_root
    APT_DIR="$ROOT/etc/apt"
    LIST_FILE="$APT_DIR/sources.list"
    D822_FILE="$APT_DIR/sources.list.d/debian.sources"
    SNAP_BASE="$ROOT/var/backups/apt-dsh"
}

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "${GREEN}[ OK ]${NC} $*"; }
info() { printf '%b\n' "${BLUE}[INFO]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
err()  { printf '%b\n' "${RED}[FAIL]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# 是否有人可以交互：终端，或 /dev/tty（curl ... | bash 的场景）
interactive() {
    [ -t 0 ] && return 0
    ( exec 3<>/dev/tty 2>/dev/null && [ -t 3 ] ) 2>/dev/null
}

# 读一行到 REPLY（stdin 不是终端时改从 /dev/tty 读）
read_line() {
    REPLY=""
    if [ -t 0 ]; then
        read -r REPLY || true
    elif [ -r /dev/tty ]; then
        read -r REPLY </dev/tty 2>/dev/null || true
    fi
}

# confirm <提示> <默认值 y|n>；非交互时直接取默认值，--yes 时恒为真
confirm() {
    local prompt="$1" def="${2:-n}" ans=""
    [ "$ASSUME_YES" = 1 ] && return 0
    if ! interactive; then
        [ "$def" = "y" ]
        return $?
    fi
    printf '%b' "${YELLOW}${prompt}${NC}"
    read_line
    ans="${REPLY:-$def}"
    case "$ans" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

cop_info() {
    printf '%b\n' "${GREEN}════════════════════════════════════════════${NC}"
    printf '%b\n' "${GREEN}   Debian 换源一键脚本   v${SCRIPT_VERSION}${NC}"
    printf '%b\n' "${GREEN}   作者: 末晨   ${YELLOW}https://blog.mochen.one${NC}"
    printf '%b\n' "${GREEN}════════════════════════════════════════════${NC}"
    printf '\n'
}

usage() {
    cat <<EOF
Debian 换源脚本 v${SCRIPT_VERSION}

用法: bash source.sh [选项]

镜像源:
  -m, --mirror NAME     official|tuna|ustc|aliyun|tencent|huawei|nju
  -y, --yes             非交互执行，所有确认自动通过
  --no-backports        不写入 -backports 源
  -s, --with-src        写入 deb-src 源（默认跟随现有配置）
  --no-src              不写入 deb-src 源

配置格式:
  -f, --format FMT      auto|list|deb822（默认 auto：跟随当前系统）

其它操作:
  -p, --print           只打印将要写入的内容，不修改任何文件
  --no-update           写入后不执行 apt-get update
  --upgrade             写入并更新索引后执行 apt-get upgrade
  --restore [快照]      恢复备份（默认最新一次）
  --list-backups        列出所有备份
  --show                显示当前生效的源配置

调试/进阶:
  --codename NAME       强制指定发行代号（例如 trixie、forky）
  --root DIR            操作指定根目录（离线预览/测试用）
  --force               跳过镜像可用性检测
  -h, --help            显示本帮助

示例:
  bash source.sh -m tuna -y            # 非交互切换到清华源并更新索引
  bash source.sh -m aliyun --no-src    # 阿里云源，不写 deb-src
  bash source.sh --print               # 只预览生成结果
  bash source.sh --restore             # 回滚到最近一次备份
EOF
}

# ===========================================================================
# 1. 系统与发行版识别
# ===========================================================================
OS_ID="unknown"
OS_LIKE=""
OS_VER=""
OS_CODENAME=""
CODENAME=""
DVER=""
REL_KIND=""       # archived | lts | stable | future | sid
REL_LABEL=""
COMPONENTS=""
SEC_SUITE=""
SUITES=()

detect_os() {
    local f="" c
    for c in "$ROOT/etc/os-release" "$ROOT/usr/lib/os-release" /etc/os-release /usr/lib/os-release; do
        if [ -r "$c" ]; then f="$c"; break; fi
    done
    [ -n "$f" ] || die "无法读取 /etc/os-release，本脚本仅支持 Debian 系统。"

    local -a vals=()
    mapfile -t vals < <(
        # shellcheck disable=SC1090
        . "$f" >/dev/null 2>&1
        printf '%s\n%s\n%s\n%s\n' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}"
    )
    OS_ID="${vals[0]:-}"
    OS_LIKE="${vals[1]:-}"
    OS_VER="${vals[2]:-}"
    OS_CODENAME="${vals[3]:-}"
    [ -n "$OS_ID" ] || OS_ID="unknown"

    if [ "$OS_ID" != "debian" ]; then
        if printf '%s' "$OS_LIKE" | grep -qi debian; then
            warn "当前系统是 ${OS_ID}（Debian 衍生版），直接套用 Debian 官方源有损坏系统的风险。"
            confirm "仍然继续吗？[y/N] " n || die "已取消。"
        else
            die "本脚本仅支持 Debian 系统（当前：${OS_ID}）。"
        fi
    fi
}

resolve_release() {
    local cn="${CODENAME_OVERRIDE:-$OS_CODENAME}"
    local ver="${OS_VER%%.*}"
    local dv=""

    # VERSION_ID 必须是纯数字，否则按“未知版本”处理
    case "$ver" in
        ''|*[!0-9]*) ver="" ;;
    esac

    if [ -z "$cn" ] && [ -n "$ver" ]; then
        case "$ver" in
            7)  cn="wheezy" ;;
            8)  cn="jessie" ;;
            9)  cn="stretch" ;;
            10) cn="buster" ;;
            11) cn="bullseye" ;;
            12) cn="bookworm" ;;
            13) cn="trixie" ;;
            14) cn="forky" ;;
        esac
    fi
    # 测试版/不稳定版的 VERSION_ID 往往缺失，退回到 /etc/debian_version
    if [ -z "$cn" ]; then
        dv=$(cat "$ROOT/etc/debian_version" 2>/dev/null || true)
        cn="${dv%%/*}"
        case "$cn" in
            [0-9]*) cn="" ;;
        esac
    fi
    [ -n "$cn" ] || die "无法识别当前 Debian 发行代号，请用 --codename 手动指定。"

    CODENAME="$cn"
    if [ -z "$ver" ]; then
        case "$cn" in
            wheezy)   ver=7 ;;
            jessie)   ver=8 ;;
            stretch)  ver=9 ;;
            buster)   ver=10 ;;
            bullseye) ver=11 ;;
            bookworm) ver=12 ;;
            trixie)   ver=13 ;;
            forky)    ver=14 ;;
            *)        ver="" ;;
        esac
    fi

    if [ "$cn" = "sid" ] || [ "$cn" = "unstable" ]; then
        REL_KIND="sid"
        REL_LABEL="不稳定版 (sid)，无安全更新源"
        DVER=""
    elif [ -n "$ver" ] && [ "$ver" -le 11 ]; then
        # 截至 2026-11：Debian 11 及更早版本均已 EOL，只保留在 archive.debian.org
        REL_KIND="archived"
        REL_LABEL="已停止支持 (EOL)，改用官方归档源"
        DVER="$ver"
    elif [ -n "$ver" ] && [ "$ver" -eq 12 ]; then
        REL_KIND="lts"
        REL_LABEL="旧稳定版 (LTS 维护中)"
        DVER=12
    elif [ -n "$ver" ] && [ "$ver" -eq 13 ]; then
        REL_KIND="stable"
        REL_LABEL="当前稳定版"
        DVER=13
    else
        REL_KIND="future"
        REL_LABEL="测试版/更新的版本，按稳定版规则配置"
        DVER="${ver:-0}"
    fi

    # 组件：由 Debian 12 起固件从 non-free 拆到 non-free-firmware
    if [ -n "$ver" ] && [ "$ver" -lt 12 ]; then
        COMPONENTS="main contrib non-free"
    else
        COMPONENTS="main contrib non-free non-free-firmware"
    fi

    # 安全更新源的套件名：Debian 10 及更早为 <代号>/updates
    if [ "$REL_KIND" = "sid" ]; then
        SEC_SUITE=""
    elif [ -n "$ver" ] && [ "$ver" -le 10 ]; then
        SEC_SUITE="$CODENAME/updates"
    else
        SEC_SUITE="$CODENAME-security"
    fi

    SUITES=()
    if [ "$REL_KIND" = "sid" ]; then
        SUITES=("sid")
    elif [ "$REL_KIND" = "archived" ]; then
        # 归档站保留 <代号> 与 <代号>-updates，不再提供 -backports
        SUITES=("$CODENAME" "$CODENAME-updates")
    else
        SUITES=("$CODENAME" "$CODENAME-updates")
        if [ "$WITH_BACKPORTS" = 1 ]; then
            SUITES+=("$CODENAME-backports")
        fi
    fi
}

# ===========================================================================
# 2. 镜像源表
# ===========================================================================
MIRROR_ORDER=(official tuna ustc aliyun tencent huawei nju)
declare -A M_NAME

M_NAME[official]="官方 Debian 源 (deb.debian.org)"
M_NAME[tuna]="清华 TUNA"
M_NAME[ustc]="中科大 USTC"
M_NAME[aliyun]="阿里云"
M_NAME[tencent]="腾讯云"
M_NAME[huawei]="华为云"
M_NAME[nju]="南京大学 (NJU)"

BASE_URI=""
SEC_URI=""
MIRROR_LABEL=""

normalize_mirror() {
    case "${1:-}" in
        official|debian|default|deb)      printf 'official' ;;
        tuna|tsinghua|qinghua|thu|tuna.tsinghua) printf 'tuna' ;;
        ustc|zhongkeda|ustc.edu)          printf 'ustc' ;;
        aliyun|ali|aliyunecs)             printf 'aliyun' ;;
        tencent|txy|tencentcloud|qcloud)  printf 'tencent' ;;
        huawei|hw|huaweicloud)            printf 'huawei' ;;
        nju|nanjing|nju.edu)              printf 'nju' ;;
        *)                                printf '' ;;
    esac
}

# 云厂商内网域名（http 走内网更省流量）
IN_CLOUD_TENCENT=0
IN_CLOUD_ALIYUN=0

http_ok() {
    local url="$1"
    if have curl; then
        curl -fsSL -m 8 -o /dev/null "$url" >/dev/null 2>&1
    elif have wget; then
        wget -q -T 8 -t 1 -O /dev/null "$url" >/dev/null 2>&1
    else
        return 2
    fi
}

detect_cloud() {
    case "$MIRROR" in
        tencent)
            http_ok "http://169.254.0.23/latest/meta-data/" && IN_CLOUD_TENCENT=1
            ;;
        aliyun)
            http_ok "http://100.100.100.200/latest/meta-data/" && IN_CLOUD_ALIYUN=1
            ;;
    esac
    return 0
}

set_mirror_uris() {
    local m="$MIRROR"

    if [ "$REL_KIND" = "archived" ]; then
        if [ "$m" != "official" ]; then
            warn "Debian ${DVER} 已停止支持，镜像站不再同步，改用官方归档站 archive.debian.org。"
        fi
        BASE_URI="https://archive.debian.org/debian/"
        SEC_URI="https://archive.debian.org/debian-security/"
        MIRROR_LABEL="官方归档站 archive.debian.org"
        return 0
    fi

    case "$m" in
        tencent) [ "$IN_CLOUD_TENCENT" = 1 ] && m="tencent-intra" ;;
        aliyun)  [ "$IN_CLOUD_ALIYUN" = 1 ]  && m="aliyun-intra" ;;
    esac

    case "$m" in
        official)      BASE_URI="https://deb.debian.org/debian/";                SEC_URI="https://deb.debian.org/debian-security/" ;;
        tuna)          BASE_URI="https://mirrors.tuna.tsinghua.edu.cn/debian/";  SEC_URI="https://mirrors.tuna.tsinghua.edu.cn/debian-security/" ;;
        ustc)          BASE_URI="https://mirrors.ustc.edu.cn/debian/";           SEC_URI="https://mirrors.ustc.edu.cn/debian-security/" ;;
        aliyun)        BASE_URI="https://mirrors.aliyun.com/debian/";            SEC_URI="https://mirrors.aliyun.com/debian-security/" ;;
        tencent)       BASE_URI="https://mirrors.cloud.tencent.com/debian/";     SEC_URI="https://mirrors.cloud.tencent.com/debian-security/" ;;
        huawei)        BASE_URI="https://mirrors.huaweicloud.com/debian/";       SEC_URI="https://mirrors.huaweicloud.com/debian-security/" ;;
        nju)           BASE_URI="https://mirror.nju.edu.cn/debian/";             SEC_URI="https://mirror.nju.edu.cn/debian-security/" ;;
        aliyun-intra)  BASE_URI="http://mirrors.aliyun.com/debian/";             SEC_URI="http://mirrors.aliyun.com/debian-security/" ;;
        tencent-intra) BASE_URI="http://mirrors.cloud.tencent.com/debian/";      SEC_URI="http://mirrors.cloud.tencent.com/debian-security/" ;;
        *)             die "未知的镜像源：$m" ;;
    esac

    case "$m" in
        aliyun-intra)  MIRROR_LABEL="阿里云（内网 HTTP）" ;;
        tencent-intra) MIRROR_LABEL="腾讯云（内网 HTTP）" ;;
        *)             MIRROR_LABEL="${M_NAME[$m]:-$m}" ;;
    esac
    return 0
}

# 校验镜像上确实存在对应发行版的 Release 文件
check_mirror() {
    [ "$FORCE" = 1 ] && return 0
    if ! have curl && ! have wget; then
        info "未检测到 curl/wget，跳过镜像可用性检测。"
        return 0
    fi
    info "正在检测 ${MIRROR_LABEL:-$MIRROR} 是否可用 ..."
    if http_ok "${BASE_URI}dists/${CODENAME}/Release"; then
        ok "镜像可用。"
        return 0
    fi
    warn "镜像 $BASE_URI 上找不到 ${CODENAME} 的索引，可能不可用或未同步。"
    if [ "$ASSUME_YES" = 1 ] && [ "$FORCE" = 0 ]; then
        die "已停止写入。请换一个镜像，或加 --force 强制写入。"
    fi
    confirm "仍然继续写入吗？[y/N] " n || die "已取消。"
}

# ===========================================================================
# 3. 配置生成
# ===========================================================================
CONFIG_TEXT=""
KEYRING=""

detect_keyring() {
    KEYRING=""
    local f
    for f in "$D822_FILE" "$APT_DIR"/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        KEYRING=$(sed -n 's/^[[:space:]]*[Ss]igned-[Bb]y:[[:space:]]*//p' "$f" | head -n 1)
        [ -n "$KEYRING" ] && break
    done
    if [ -z "$KEYRING" ] && [ -f "$ROOT/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
    fi
    return 0
}

header_comment() {
    printf '# 由 source.sh %s 生成于 %s\n' "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# 系统: Debian %s (%s)  镜像: %s\n' "${OS_VER:-未知}" "$CODENAME" "${MIRROR_LABEL:-$MIRROR}"
    case "$REL_KIND" in
        archived) printf '# 注意: 该版本已 EOL，使用 archive.debian.org 归档源（不再有安全更新）\n' ;;
        future)   printf '# 注意: 测试版/未发布版本，套件名按 <代号> 规则生成\n' ;;
        sid)      printf '# 注意: sid 为滚动发行版，无 -security/-updates 源\n' ;;
    esac
}

# 收集 sources.list 中与 Debian 无关的条目（第三方源），写入新配置时原样保留
collect_foreign_lines() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk -v re="$DEBIAN_HOST_RE" '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*(deb|deb-src)[[:space:]]/ { if (tolower($0) ~ re) next; print; next }
        /^[[:space:]]*(Types|URIs|Suites|Components|Signed-By|Enabled|Architectures|Check-Valid-Until|Targets|Comment|Description):/ { next }
        { print }
    ' "$file" 2>/dev/null || true
}

build_list_format() {
    local flag="" s out="" foreign=""
    [ "$REL_KIND" = "archived" ] && flag="[check-valid-until=no] "

    out="$(header_comment)"$'\n\n'
    for s in "${SUITES[@]}"; do
        out+="deb ${flag}${BASE_URI} ${s} ${COMPONENTS}"$'\n'
        if [ "$WITH_SRC" = 1 ]; then
            out+="deb-src ${flag}${BASE_URI} ${s} ${COMPONENTS}"$'\n'
        fi
        out+=$'\n'
    done
    if [ -n "$SEC_SUITE" ]; then
        out+="deb ${flag}${SEC_URI} ${SEC_SUITE} ${COMPONENTS}"$'\n'
        if [ "$WITH_SRC" = 1 ]; then
            out+="deb-src ${flag}${SEC_URI} ${SEC_SUITE} ${COMPONENTS}"$'\n'
        fi
    fi

    # 保留原有的第三方源，避免换源时被误删
    foreign=$(collect_foreign_lines "$LIST_FILE")
    if [ -n "$foreign" ]; then
        out+=$'\n'"# ---------- 以下为原有其它源，保持原样 ----------"$'\n'
        out+="$foreign"$'\n'
    fi

    CONFIG_TEXT="$out"
}

build_deb822_format() {
    local types="deb" out="" sb="" cu=""
    [ "$WITH_SRC" = 1 ] && types="deb deb-src"
    [ -n "$KEYRING" ] && sb="Signed-By: $KEYRING"$'\n'
    [ "$REL_KIND" = "archived" ] && cu="Check-Valid-Until: no"$'\n'

    out="$(header_comment)"$'\n\n'
    out+="Types: ${types}"$'\n'
    out+="URIs: ${BASE_URI}"$'\n'
    out+="Suites: ${SUITES[*]}"$'\n'
    out+="Components: ${COMPONENTS}"$'\n'
    out+="${sb}${cu}"

    if [ -n "$SEC_SUITE" ]; then
        out+=$'\n'
        out+="Types: ${types}"$'\n'
        out+="URIs: ${SEC_URI}"$'\n'
        out+="Suites: ${SEC_SUITE}"$'\n'
        out+="Components: ${COMPONENTS}"$'\n'
        out+="${sb}${cu}"
    fi
    CONFIG_TEXT="$out"
}

detect_format() {
    if [ "$FMT" = "auto" ]; then
        if [ -f "$D822_FILE" ]; then
            FMT="deb822"
        elif [ -f "$LIST_FILE" ] && grep -qiE '^[[:space:]]*(deb|deb-src)[[:space:]]' "$LIST_FILE" 2>/dev/null; then
            FMT="list"
        elif [ -n "$DVER" ] && [ "$DVER" -ge 13 ]; then
            FMT="deb822"
        else
            FMT="list"
        fi
    fi
    return 0
}

detect_with_src() {
    [ "$WITH_SRC" != "auto" ] && return 0
    if grep -qiE '^[[:space:]]*deb-src[[:space:]]' "$LIST_FILE" 2>/dev/null \
        || grep -qiE '^[[:space:]]*Types:.*deb-src' "$D822_FILE" 2>/dev/null \
        || { [ ! -f "$LIST_FILE" ] && [ ! -f "$D822_FILE" ]; }; then
        WITH_SRC=1
    else
        WITH_SRC=0
    fi
    return 0
}

# ===========================================================================
# 4. 备份 / 恢复 / 写入
# ===========================================================================
snapshot() {
    local ts n=1
    ts=$(date '+%Y%m%d-%H%M%S')
    while [ -e "$SNAP_BASE/$ts" ]; do
        n=$((n + 1))
        ts="$(date '+%Y%m%d-%H%M%S')-$n"
    done
    SNAP_DIR="$SNAP_BASE/$ts"
    mkdir -p "$SNAP_DIR/sources.list.d" || die "无法创建备份目录：$SNAP_DIR"

    [ -f "$LIST_FILE" ] && cp -a "$LIST_FILE" "$SNAP_DIR/sources.list"
    if [ -d "$APT_DIR/sources.list.d" ]; then
        cp -a "$APT_DIR/sources.list.d/." "$SNAP_DIR/sources.list.d/" 2>/dev/null || true
    fi
    {
        printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'script=%s\n' "$SCRIPT_VERSION"
        printf 'os=%s\n' "${OS_VER:-未知}"
        printf 'codename=%s\n' "$CODENAME"
        printf 'mirror=%s\n' "${MIRROR_LABEL:-$MIRROR}"
        printf 'format=%s\n' "$FMT"
    } > "$SNAP_DIR/manifest"
    printf '%s\n' "$SNAP_DIR" > "$SNAP_BASE/latest"
    ok "已备份当前源配置到：$SNAP_DIR"
}

write_file() {
    local file="$1" content="$2" tmp
    tmp="${file}.dsh.tmp"
    mkdir -p "$(dirname "$file")" || die "无法创建目录：$(dirname "$file")"
    printf '%s\n' "$content" > "$tmp" || die "写入失败：$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" || die "写入失败：$file"
    if [ "$ROOT" = "" ] && [ "$(id -u)" = 0 ]; then
        chown root:root "$file" 2>/dev/null || true
    fi
    ok "已写入：$file"
}

DEBIAN_HOST_RE='deb\.debian\.org|archive\.debian\.org|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn|mirrors\.aliyun\.com|mirrors\.cloud\.tencent\.com|mirrors\.huaweicloud\.com|mirror\.nju\.edu\.cn'

# 传统格式：注释掉与 Debian 相关的 deb 行
neutralize_list_file() {
    local f="$1" tmp="$1.dsh.tmp"
    awk -v re="$DEBIAN_HOST_RE" '
        /^[[:space:]]*(deb|deb-src)[[:space:]]/ && tolower($0) ~ re { print "# [已停用] " $0; next }
        { print }
    ' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    if grep -qiE '^[[:space:]]*(deb|deb-src)[[:space:]]' "$tmp"; then
        mv -f "$tmp" "$f"
        info "已在 $(basename "$f") 中注释掉重复的 Debian 条目（其余第三方源保留）"
    elif [ "$f" = "$LIST_FILE" ]; then
        mv -f "$tmp" "$f"
        info "已清空 $(basename "$f") 中重复的 Debian 条目"
    else
        rm -f "$tmp" "$f"
        info "已停用重复的 Debian 源文件：$f"
    fi
}

# deb822 格式：整段删除 debian 的 stanza，保留第三方 stanza
neutralize_sources_file() {
    local f="$1" tmp="$1.dsh.tmp" out=""
    out=$(awk -v re="$DEBIAN_HOST_RE" '
        function flush_stanza(   i) {
            if (nb > 0 && drop == 0) { printf "%s", buf }
            buf = ""; nb = 0; drop = 0
        }
        /^[[:space:]]*$/ { flush_stanza(); printf "\n"; next }
        /^[[:space:]]*#/ { buf = buf $0 "\n"; nb++; next }
        {
            if ($0 ~ /^URIs:/ && tolower($0) ~ re) drop = 1
            buf = buf $0 "\n"; nb++
        }
        END { flush_stanza() }
    ' "$f" 2>/dev/null) || { return 1; }

    if ! printf '%s' "$out" | grep -qiE '^[[:space:]]*URIs:'; then
        rm -f "$f"
        info "已停用重复的 Debian 源文件：$f"
    else
        printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$f"
        info "已从 $(basename "$f") 中移除重复的 Debian 条目（其余第三方源保留）"
    fi
}

# 停用除 keep 之外、会与本次写入冲突的 Debian 源条目
neutralize_conflicts() {
    local keep="$1" f
    local -a cands=()

    [ -f "$LIST_FILE" ] && cands+=("$LIST_FILE")
    for f in "$APT_DIR"/sources.list.d/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.list|*.sources) cands+=("$f") ;;
        esac
    done

    for f in "${cands[@]:-}"; do
        [ -n "$f" ] || continue
        [ "$f" = "$keep" ] && continue
        grep -qiE "$DEBIAN_HOST_RE" "$f" 2>/dev/null || continue
        case "$f" in
            *.sources) neutralize_sources_file "$f" ;;
            *)         neutralize_list_file "$f" ;;
        esac
    done
}

require_root() {
    [ -n "$ROOT" ] && return 0
    [ "$(id -u)" = "0" ] || die "该脚本必须以 root 身份运行（请使用 sudo 或切换到 root）。"
}

restore_snapshot() {
    local snap="$1"
    [ -d "$snap" ] || die "备份不存在：$snap"

    if [ -f "$snap/sources.list" ]; then
        cp -a "$snap/sources.list" "$LIST_FILE"
    else
        rm -f "$LIST_FILE"
    fi
    rm -f "$APT_DIR"/sources.list.d/*.list "$APT_DIR"/sources.list.d/*.sources 2>/dev/null || true
    if [ -d "$snap/sources.list.d" ]; then
        cp -a "$snap/sources.list.d/." "$APT_DIR/sources.list.d/" 2>/dev/null || true
    fi
    ok "已恢复源配置：$snap"
    [ -f "$snap/manifest" ] && sed 's/^/      /' "$snap/manifest"
}

latest_snapshot() {
    local p=""
    if [ -f "$SNAP_BASE/latest" ]; then
        p=$(head -n 1 "$SNAP_BASE/latest" 2>/dev/null || true)
        if [ -n "$p" ] && [ -d "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    fi
    # 兜底：取最新的一个快照目录
    p=$(ls -1d "$SNAP_BASE"/*/ 2>/dev/null | sort -r | head -n 1 || true)
    p="${p%/}"
    if [ -n "$p" ] && [ -d "$p" ]; then
        printf '%s\n' "$p"
        return 0
    fi
    return 1
}

list_backups() {
    local d ver cn mm ft
    if [ ! -d "$SNAP_BASE" ] || [ -z "$(ls -1A "$SNAP_BASE" 2>/dev/null)" ]; then
        info "暂无任何备份。"
        return 0
    fi
    printf '\n%-18s %-10s %-12s %-10s %s\n' "快照时间" "系统版本" "发行代号" "格式" "镜像"
    for d in $(ls -1d "$SNAP_BASE"/*/ 2>/dev/null | sort -r); do
        d="${d%/}"
        [ -d "$d" ] || continue
        [ -f "$d/manifest" ] || continue
        ver="?"; cn="?"; ft="?"; mm="?"
        if [ -f "$d/manifest" ]; then
            ver=$(sed -n 's/^os=//p' "$d/manifest" | head -n 1)
            cn=$(sed -n 's/^codename=//p' "$d/manifest" | head -n 1)
            mm=$(sed -n 's/^mirror=//p' "$d/manifest" | head -n 1)
            ft=$(sed -n 's/^format=//p' "$d/manifest" | head -n 1)
        fi
        printf '%-18s %-10s %-12s %-10s %s\n' "$(basename "$d")" "${ver:-?}" "${cn:-?}" "${ft:-?}" "${mm:-?}"
    done
    printf '\n用 --restore <快照时间> 恢复指定的备份。\n'
}

do_restore() {
    require_root
    local snap="" pick=""

    if [ -n "$RESTORE_TARGET" ]; then
        snap="$RESTORE_TARGET"
        [ -d "$snap" ] || snap="$SNAP_BASE/$RESTORE_TARGET"
    else
        if ! snap=$(latest_snapshot); then
            die "没有可用的备份（$SNAP_BASE 为空）。"
        fi
        if interactive && [ "$ASSUME_YES" = 0 ]; then
            info "最近的备份：$snap"
            if [ -f "$snap/manifest" ]; then sed 's/^/      /' "$snap/manifest"; fi
            confirm "确认恢复到该备份？[Y/n] " y || die "已取消。"
        fi
    fi

    [ -d "$snap" ] || die "备份不存在：$snap"
    restore_snapshot "$snap"

    if [ "$DO_UPDATE" = 1 ] && [ -z "$ROOT" ] && have apt-get; then
        info "正在更新软件包索引 ..."
        apt-get update -o Acquire::Retries=3 || warn "apt-get update 有错误，请查看上方输出。"
    fi
}

show_current() {
    local f found=0
    info "当前生效的源配置文件："
    if [ -f "$LIST_FILE" ]; then
        printf '\n---- %s ----\n' "$LIST_FILE"
        grep -vE '^[[:space:]]*$' "$LIST_FILE" | sed 's/^/  /'
        found=1
    fi
    for f in "$APT_DIR"/sources.list.d/*.sources "$APT_DIR"/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        printf '\n---- %s ----\n' "$f"
        grep -vE '^[[:space:]]*$' "$f" | sed 's/^/  /'
        found=1
    done
    [ "$found" = 1 ] || warn "未找到任何源配置文件。"
}

# ===========================================================================
# 5. 主流程
# ===========================================================================
show_menu() {
    local i=1 m
    printf '  请选择要使用的镜像源：\n\n'
    printf '    0) 退出\n'
    for m in "${MIRROR_ORDER[@]}"; do
        printf '    %d) %s\n' "$i" "${M_NAME[$m]}"
        i=$((i + 1))
    done
    MENU_RESTORE=$i
    printf '    %d) 恢复备份的源配置\n' "$MENU_RESTORE"
    i=$((i + 1))
    MENU_SHOW=$i
    printf '    %d) 查看当前源配置\n' "$MENU_SHOW"
    printf '\n'
}

MENU_RESTORE=0
MENU_SHOW=0

choose_mirror() {
    local i=0 m choice=""
    if [ -n "$MIRROR" ]; then
        MIRROR=$(normalize_mirror "$MIRROR")
        [ -n "$MIRROR" ] || die "未知的镜像源，可用：${MIRROR_ORDER[*]}"
        return 0
    fi

    show_menu
    if interactive; then
        printf '  请输入序号 [0-%d]: ' "$MENU_SHOW"
        read_line
        choice="$REPLY"
    else
        die "非交互环境请用 -m/--mirror 指定镜像源，例如：bash $0 -m tuna -y"
    fi

    case "$choice" in
        ""|0) say "${RED}已退出，未更改源。${NC}"; exit 0 ;;
    esac
    if [ "$choice" = "$MENU_RESTORE" ]; then
        MODE="restore"
        return 0
    fi
    if [ "$choice" = "$MENU_SHOW" ]; then
        show_current
        exit 0
    fi
    case "$choice" in
        ''|*[!0-9]*) die "无效的选项：$choice" ;;
    esac
    if [ "$choice" -ge 1 ] && [ "$choice" -le "${#MIRROR_ORDER[@]}" ]; then
        MIRROR="${MIRROR_ORDER[$((choice - 1))]}"
    else
        die "无效的选项：$choice"
    fi
}

run_apply() {
    detect_format
    detect_with_src
    detect_keyring
    detect_cloud
    set_mirror_uris

    if [ "$FMT" = "deb822" ]; then
        build_deb822_format
    else
        build_list_format
    fi

    printf '\n'
    info "系统：Debian ${OS_VER:-未知} (${CODENAME})  ${REL_LABEL}"
    info "镜像：${MIRROR_LABEL:-$MIRROR}"
    info "格式：$([ "$FMT" = deb822 ] && printf 'deb822 (.sources)' || printf '传统 sources.list')"
    printf '\n%s\n' "---------- 即将写入的配置 ----------"
    printf '%s\n' "$CONFIG_TEXT"
    printf '%s\n\n' "------------------------------------"

    if [ "$PRINT_ONLY" = 1 ]; then
        info "预览模式（--print），未修改任何文件。"
        return 0
    fi

    require_root
    check_mirror
    detect_keyring
    if [ "$FMT" = "deb822" ]; then build_deb822_format; else build_list_format; fi

    confirm "确认写入以上配置？[Y/n] " y || { say "${RED}已取消，未做任何修改。${NC}"; exit 0; }

    snapshot
    if [ "$FMT" = "deb822" ]; then
        neutralize_conflicts "$D822_FILE"
        write_file "$D822_FILE" "$CONFIG_TEXT"
    else
        neutralize_conflicts "$LIST_FILE"
        write_file "$LIST_FILE" "$CONFIG_TEXT"
    fi

    printf '\n'
    ok "Debian ${OS_VER:-?} (${CODENAME}) 已切换到 ${MIRROR_LABEL:-$MIRROR}。"
    info "回滚命令：bash $0 --restore"

    if [ "$DO_UPDATE" = 1 ]; then
        if [ -n "$ROOT" ]; then
            info "（预览根目录，跳过 apt-get update）"
        elif have apt-get; then
            printf '\n'
            info "正在更新软件包索引 ..."
            if apt-get update -o Acquire::Retries=3; then
                ok "软件包索引更新完成。"
            else
                warn "apt-get update 报告了错误，请查看上方输出；需要时可执行 --restore 回滚。"
            fi
        fi
    fi

    if [ "$DO_UPGRADE" = 1 ]; then
        if [ -z "$ROOT" ] && have apt-get; then
            printf '\n'
            info "正在升级已安装的软件包 ..."
            DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || warn "apt-get upgrade 未完全成功。"
        fi
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--mirror)
                [ $# -ge 2 ] || die "$1 需要一个参数"
                MIRROR="$2"; shift 2 ;;
            --mirror=*) MIRROR="${1#*=}"; shift ;;
            -f|--format)
                [ $# -ge 2 ] || die "$1 需要一个参数"
                FMT="$2"; shift 2 ;;
            --format=*) FMT="${1#*=}"; shift ;;
            -s|--with-src) WITH_SRC=1; shift ;;
            --no-src) WITH_SRC=0; shift ;;
            --no-backports) WITH_BACKPORTS=0; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            -p|--print) PRINT_ONLY=1; shift ;;
            --no-update) DO_UPDATE=0; shift ;;
            --upgrade) DO_UPGRADE=1; shift ;;
            --force) FORCE=1; shift ;;
            --codename)
                [ $# -ge 2 ] || die "$1 需要一个参数"
                CODENAME_OVERRIDE="$2"; shift 2 ;;
            --codename=*) CODENAME_OVERRIDE="${1#*=}"; shift ;;
            --root)
                [ $# -ge 2 ] || die "$1 需要一个参数"
                ROOT="$2"; shift 2 ;;
            --root=*) ROOT="${1#*=}"; shift ;;
            --restore)
                MODE="restore"; shift
                if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                    RESTORE_TARGET="$1"; shift
                fi ;;
            --restore=*) MODE="restore"; RESTORE_TARGET="${1#*=}"; shift ;;
            --list-backups) MODE="list-backups"; shift ;;
            --show) MODE="show"; shift ;;
            -h|--help) MODE="help"; shift ;;
            *) die "未知参数：$1（用 --help 查看帮助）" ;;
        esac
    done

    case "$FMT" in
        auto|list|deb822) ;;
        *) die "--format 只支持 auto|list|deb822" ;;
    esac
    case "$WITH_SRC" in
        auto|0|1) ;;
        *) die "内部参数错误：WITH_SRC=$WITH_SRC" ;;
    esac
}

main() {
    parse_args "$@"
    init_paths

    case "$MODE" in
        help) usage; exit 0 ;;
        list-backups) list_backups; exit 0 ;;
    esac

    if [ "$MODE" != "help" ]; then
        cop_info
    fi

    if [ "$MODE" = "show" ]; then
        detect_os
        resolve_release
        show_current
        exit 0
    fi

    # --print 需要先知道发行版才能生成内容
    detect_os
    resolve_release

    if [ "$MODE" = "restore" ]; then
        do_restore
        exit 0
    fi

    # --print 只预览时不交互，默认官方源
    if [ "$PRINT_ONLY" = 1 ] && [ -z "$MIRROR" ]; then
        MIRROR="official"
    fi

    if [ "$MODE" = "menu" ] && [ -z "$MIRROR" ] && [ ! -t 0 ] && ! interactive; then
        warn "未指定镜像源，默认使用官方源；可用 -m 指定。"
        MIRROR="official"
    fi

    choose_mirror
    if [ "$MODE" = "restore" ]; then
        do_restore
        exit 0
    fi
    run_apply
}

main "$@"

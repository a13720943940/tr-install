#!/usr/bin/env bash
#
# Transmission 一键安装脚本
# 支持: Debian 10+/Ubuntu 18.04+/CentOS 7+/Alpine
# 用法:
#   wget -qO tr-install.sh https://your-url/tr-install.sh && sudo bash tr-install.sh -u user -p pass [选项]
#   (注: 某些系统不支持 bash <(wget...) 语法，请先下载再执行)
#
# 选项:
#   -u, --user          RPC 用户名 (必填)
#   -p, --pass          RPC 密码 (必填)
#   -P, --rpc-port      RPC 端口 (默认: 9091)
#   -t, --peer-port     种子端口 (默认: 51413)
#   -d, --download-dir  下载目录 (默认: /home/<user>/downloads)
#   -m, --incomplete    未完成下载目录 (默认: /home/<user>/downloads/incomplete)
#   -q, --tr-version    Transmission 版本 (默认: 4.0.5)
#   -v, --verbose       详细输出
#   -x, --ssl           启用 SSL
#   -h, --help          显示帮助
#

set -uo pipefail
# 注意: 不使用 set -e, 避免管道错误意外退出

# ─── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ─── 默认值 ───────────────────────────────────────────────────────────────────
TR_USER=""
TR_PASS=""
TR_RPC_PORT=9091
TR_PEER_PORT=51413
TR_DOWNLOAD_DIR=""
TR_INCOMPLETE_DIR=""
TR_INCOMPLETE_ENABLED=1
TR_VERSION="4.0.5"
TR_VERBOSE=0
TR_USE_SSL=0
TR_BIND_ADDR="0.0.0.0"
SYSTEM_USER=""
INSTALL_PREFIX="/usr/local"
TRUNK_BUILD=0   # 从 trunk 源码编译
TR_WEB_CONTROL=0  # 安装 TrguiNG 美化界面

# ─── 帮助 ─────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
${BOLD}Transmission-daemon 一键安装脚本${NC} v1.0.0

${BOLD}用法:${NC}
  bash tr-install.sh -u <用户名> -p <密码> [选项...]

${BOLD}必填参数:${NC}
  -u, --user <用户名>      RPC 登录用户名
  -p, --pass <密码>        RPC 登录密码

${BOLD}可选参数:${NC}
  -P, --rpc-port <端口>    RPC 端口 (默认: 9091)
  -t, --peer-port <端口>   种子监听端口 (默认: 51413)
  -d, --download-dir <路径>  下载目录 (默认: /home/<用户>/downloads)
  -m, --incomplete <路径>  未完成目录 (默认: /home/<用户>/downloads/incomplete)
  -q, --tr-version <版本>  Transmission 版本 (默认: 4.0.5)
  -i, --install-prefix <路径> 安装前缀 (默认: /usr/local)
  -b, --bind <地址>        绑定地址 (默认: 0.0.0.0)
  -x, --ssl                启用 SSL (自签名证书)
  -k, --trunk              从 trunk 源码编译 (最新特性)
  -w, --web-control        安装 TrguiNG 美化界面 (现代 React Web UI)
  -v, --verbose            显示详细输出
  -h, --help               显示此帮助

${BOLD}示例:${NC}
  # 标准安装
  bash tr-install.sh -u admin -p "MyPass123"

  # 一键在线执行 (与参考脚本格式兼容)
  bash <(wget -qO- https://your-url/tr-install.sh) \\
    -u jalonw -p "13720943940@1q" -P 9091 -t 51413 -q 3.00 -v -x

EOF
    exit 0
}

# ─── 解析参数 ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)          TR_USER="$2";       shift 2 ;;
        -p|--pass)          TR_PASS="$2";       shift 2 ;;
        -P|--rpc-port)      TR_RPC_PORT="$2";   shift 2 ;;
        -t|--peer-port)     TR_PEER_PORT="$2";  shift 2 ;;
        -d|--download-dir)  TR_DOWNLOAD_DIR="$2"; shift 2 ;;
        -m|--incomplete)    TR_INCOMPLETE_DIR="$2"; shift 2 ;;
        -q|--tr-version)    TR_VERSION="$2";    shift 2 ;;
        -i|--install-prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        -b|--bind)          TR_BIND_ADDR="$2";  shift 2 ;;
        -x|--ssl)           TR_USE_SSL=1;       shift ;;
        -k|--trunk)         TRUNK_BUILD=1;      shift ;;
        -w|--web-control)   TR_WEB_CONTROL=1;   shift ;;  # 保留向后兼容
        -v|--verbose)       TR_VERBOSE=1;       shift ;;
        -h|--help)          usage ;;
        *)                  error "未知参数: $1"; usage ;;
    esac
done

# 推导系统用户名 (去除特殊字符用作系统用户名)
SYSTEM_USER="${TR_USER//[^a-zA-Z0-9_]/}"
SYSTEM_USER="${SYSTEM_USER:0:32}"

# 默认下载目录 (与 qBittorrent 一致)
if [[ -z "$TR_DOWNLOAD_DIR" ]]; then
    TR_DOWNLOAD_DIR="/home/${SYSTEM_USER}/Downloads"
fi
if [[ -z "$TR_INCOMPLETE_DIR" ]]; then
    TR_INCOMPLETE_DIR="${TR_DOWNLOAD_DIR}/incomplete"
fi

# ─── 校验 ─────────────────────────────────────────────────────────────────────
if [[ -z "$TR_USER" || -z "$TR_PASS" ]]; then
    error "用户名 (-u) 和密码 (-p) 为必填参数！"
    usage
fi

[[ "$TR_RPC_PORT" =~ ^[0-9]+$ && "$TR_RPC_PORT" -gt 1024 && "$TR_RPC_PORT" -lt 65535 ]] || {
    error "RPC 端口必须是 1025-65534 之间的数字，当前: $TR_RPC_PORT"; exit 1; }
[[ "$TR_PEER_PORT" =~ ^[0-9]+$ && "$TR_PEER_PORT" -gt 1024 && "$TR_PEER_PORT" -lt 65535 ]] || {
    error "种子端口必须是 1025-65534 之间的数字，当前: $TR_PEER_PORT"; exit 1; }

# ─── 环境检测 ─────────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
        PACKAGES="build-essential pkg-config libssl-dev git cmake intltool \
                   libcurl4-openssl-dev libglib2.0-dev libevent-dev \
                   libminiupnpc-dev libutfcpp-dev gettext zip"
    elif [[ -f /etc/redhat-release || -f /etc/centos-release ]]; then
        if grep -qiE "rocky|almalinux" /etc/redhat-release 2>/dev/null; then
            OS="rhel"
        else
            OS="centos"
        fi
        PKG_UPDATE="yum check-update || true"
        PKG_INSTALL="yum install -y"
        PACKAGES="gcc gcc-c++ make pkgconfig openssl-devel git cmake intltool \
                   libcurl-devel glib2-devel libevent-devel miniupnpc-devel \
                   libutfcpp-devel gettext zip"
    elif [[ -f /etc/alpine-release ]]; then
        OS="alpine"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --no-cache"
        PACKAGES="build-base pkgconfig openssl-dev git cmake intltool \
                   libcurl-dev glib2-dev libevent-dev miniupnpc-dev utf8cpp gettext"
    else
        error "不支持的操作系统！仅支持 Debian/Ubuntu/CentOS/RHEL/Alpine"
        exit 1
    fi
    info "检测到操作系统: ${BOLD}${OS}${NC}"
}

detect_arch() {
    case $(uname -m) in
        x86_64)  ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l)  ARCH="armhf" ;;
        *)       error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    info "系统架构: ${BOLD}${ARCH}${NC}"
}

# ─── 检查已安装 ───────────────────────────────────────────────────────────────
check_existing() {
    if command -v transmission-daemon &>/dev/null; then
        local cur_ver
        cur_ver=$(transmission-daemon --version 2>/dev/null | awk '{print $2}' || echo "unknown")
        warn "检测到已安装 Transmission: v${cur_ver}"
        read -rp "是否覆盖安装？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "退出安装"; exit 0; }
        systemctl stop transmission 2>/dev/null || true
    fi
    if id "$SYSTEM_USER" &>/dev/null; then
        info "系统用户 $SYSTEM_USER 已存在"
    fi
}

# ─── 创建用户 ─────────────────────────────────────────────────────────────────
create_user() {
    step "创建系统用户"
    if ! id "$SYSTEM_USER" &>/dev/null; then
        useradd -r -m -s /usr/sbin/nologin "$SYSTEM_USER"
        info "用户 $SYSTEM_USER 创建成功"
    else
        info "用户 $SYSTEM_USER 已存在，跳过"
    fi
    # 必须在函数里赋值并设为全局，否则调用者读不到
    TR_UID=$(id -u "$SYSTEM_USER")
    TR_GID=$(id -g "$SYSTEM_USER")
}

# ─── 安装依赖 ─────────────────────────────────────────────────────────────────
install_dependencies() {
    step "安装编译依赖"
    $PKG_UPDATE
    $PKG_INSTALL $PACKAGES
    info "依赖安装完成"
}

# ─── 编译安装 Transmission ────────────────────────────────────────────────────
install_transmission() {
    step "编译安装 Transmission ${TR_VERSION}"

    local tr_src="/tmp/transmission-${TR_VERSION}"
    local tr_build="${tr_src}/build"
    local prefix="${INSTALL_PREFIX}"

    rm -rf "$tr_src"
    mkdir -p "$tr_build"

    # 下载源码
    rm -rf "$tr_src" /tmp/transmission-api.json /tmp/transmission-*.tar.* 2>/dev/null || true
    if [[ "$TRUNK_BUILD" == "1" ]]; then
        info "从 trunk 克隆源码 (最新版本)..."
        GIT_HTTP_VERSION=HTTP/1.1 git clone --depth=1 "https://github.com/transmission/transmission.git" "$tr_src" || true
        cd "$tr_src" 2>/dev/null || true
        TR_VERSION=$(git describe --tags 2>/dev/null | sed 's/^v//' | head -1 || echo "trunk")
    else
        info "下载 Transmission-${TR_VERSION}..."
        # 3.00 release tarball 缺少 third-party 子模块, 必须用 git clone --depth=1 --recurse-submodules
        # 3.00 的 tag 不带 v 前缀, 4.0+ 带 v 前缀
        local tag_candidates=()
        if [[ "${TR_VERSION}" == 3.* ]]; then
            tag_candidates=("${TR_VERSION}" "v${TR_VERSION}")
        else
            tag_candidates=("v${TR_VERSION}" "${TR_VERSION}")
        fi

        local tag_name=""
        for t in "${tag_candidates[@]}"; do
            echo "[DEBUG] 尝试 tag: $t" >&2
            if git ls-remote --exit-code --heads origin "refs/tags/$t" "https://github.com/transmission/transmission.git" 2>/dev/null; then
                tag_name="$t"
                break
            fi
        done

        if [[ -z "$tag_name" ]]; then
            tag_name="${TR_VERSION}"
        fi

        info "Git clone (含子模块, 可能较慢)..."
        GIT_HTTP_VERSION=HTTP/1.1 git clone --depth=1 --recurse-submodules --branch "${tag_name}" \
            "https://github.com/transmission/transmission.git" "$tr_src" 2>&1 | tail -5

        if [[ ! -d "$tr_src" ]]; then
            error "源码下载失败"
            exit 1
        fi
    fi

    if [[ ! -d "$tr_src" ]]; then
        error "无法下载 Transmission 源码，请检查网络或尝试手动下载"
        exit 1
    fi

    echo "[DEBUG] tr_src=$tr_src" >&2
    echo "[DEBUG] 内容:" >&2
    ls -la "$tr_src" 2>/dev/null | head -20 >&2

    cd "$tr_build"
    echo "[DEBUG] tr_build=$tr_build" >&2

    # 根据版本选择构建系统
    # Transmission 3.00: 使用 cmake (有 CMakeLists.txt)
    # Transmission 4.0+: 使用 autotools (configure.ac + autogen.sh)
    if [[ -f "${tr_src}/CMakeLists.txt" ]] && [[ ! -f "${tr_src}/configure" ]]; then
        info "使用 CMake 构建..."
        echo "[DEBUG] CMake 构建, tr_src=${tr_src}" >&2
        cmake "${tr_src}" -DCMAKE_INSTALL_PREFIX="${prefix}" \
                 -DCMAKE_BUILD_TYPE=Release \
                 -DENABLE_DAEMON=ON \
                 -DENABLE_CLI=OFF \
                 -DENABLE_GTK=OFF \
                 -DENABLE_MAC=OFF \
                 -DENABLE_QT=OFF 2>&1 | tail -20
        echo "[DEBUG] cmake 退出码: $?" >&2
        make -j$(nproc) 2>&1 | tail -20
        echo "[DEBUG] make 退出码: $?" >&2
        make install 2>&1 | tail -10
        echo "[DEBUG] make install 退出码: $?" >&2
        echo "[DEBUG] /usr/local/bin/transmission-daemon:" >&2
        ls -la /usr/local/bin/transmission* 2>&1 >&2
    elif [[ -f "${tr_src}/autogen.sh" ]] || [[ -f "${tr_src}/configure.ac" ]]; then
        info "使用 Autotools 构建..."
        cd "${tr_src}"
        if [[ ! -f "./configure" ]]; then
            info "运行 autogen.sh..."
            bash autogen.sh || autoreconf -fi
        fi
        CFLAGS="-O2 -march=native" \
        CXXFLAGS="-O2 -march=native" \
        ./configure --prefix="${prefix}" \
            --disable-daemon 2>&1 | tail -10
        make -j$(nproc) 2>&1 | tail -10
        make install 2>&1 | tail -5
        cd "$tr_build"
    else
        error "未知的构建系统 (无 CMakeLists.txt 或 configure.ac)"
        ls -la "${tr_src}" >&2
        exit 1
    fi

    # 清理
    rm -rf "$tr_src" "/tmp/transmission-${TR_VERSION}.tar.gz" "/tmp/transmission-${TR_VERSION}.tar.xz"

    info "Transmission ${TR_VERSION} 安装完成"
}

# ─── SSL 证书 ─────────────────────────────────────────────────────────────────
generate_ssl() {
    step "生成 SSL 自签名证书"
    local cert_dir="/home/${SYSTEM_USER}/.config/transmission/ssl"
    mkdir -p "$cert_dir"

    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=CN/ST=SH/L=Shanghai/O=Seedbox/CN=$(hostname -f 2>/dev/null || hostname)" \
        -keyout "${cert_dir}/tr.key" \
        -out "${cert_dir}/tr.crt" &>/dev/null

    chmod 600 "${cert_dir}/tr.key"
    chmod 644 "${cert_dir}/tr.crt"
    info "SSL 证书生成完成"
}

# ─── 配置目录与权限 ───────────────────────────────────────────────────────────
setup_directories() {
    step "配置目录与权限"

    local conf_dir="/home/${SYSTEM_USER}/.config/transmission"
    mkdir -p "$conf_dir" "$TR_DOWNLOAD_DIR" "${TR_INCOMPLETE_DIR}"

    # 创建 session 文件 (避免权限问题)
    local session_file="${conf_dir}/settings.json"
    if [[ ! -f "$session_file" ]]; then
        touch "$session_file"
        chown "${TR_GID}:${TR_GID}" "$session_file"
    fi

    chown -R "${TR_GID}:${TR_GID}" "$conf_dir"
    chown -R "${TR_GID}:${TR_GID}" "$TR_DOWNLOAD_DIR"
    chown -R "${TR_GID}:${TR_GID}" "$TR_INCOMPLETE_DIR"
    info "目录权限配置完成"
}

# ─── 生成 settings.json ───────────────────────────────────────────────────────
generate_settings() {
    step "生成 Transmission 配置文件"

    local conf_file="/home/${SYSTEM_USER}/.config/transmission/settings.json"

    local incomplete_flag="false"
    [[ "$TR_INCOMPLETE_ENABLED" == "1" ]] && incomplete_flag="true"

    local ssl_opts=""
    if [[ "$TR_USE_SSL" == "1" ]]; then
        ssl_opts=$(cat << SSLOPTS
    "rpc-ssl": true,
    "rpc-ssl-cert": "/home/${SYSTEM_USER}/.config/transmission/ssl/tr.crt",
    "rpc-ssl-private-key": "/home/${SYSTEM_USER}/.config/transmission/ssl/tr.key",
SSLOPTS
)
    fi

    cat > "$conf_file" << EOF
{
    "alt-speed-down": 10240,
    "alt-speed-enabled": false,
    "alt-speed-up": 1024,
    "bind-address-ipv4": "0.0.0.0",
    "bind-address-ipv6": "::",
    "blocklist-enabled": false,
    "cache-size-mb": 64,
    "dht-enabled": true,
    "download-queue-enabled": true,
    "download-queue-size": 5,
    "encryption": 1,
    "idle-seeding-limit": 30,
    "idle-seeding-limit-enabled": false,
    "incomplete-dir": "${TR_INCOMPLETE_DIR}",
    "incomplete-dir-enabled": ${incomplete_flag},
    "lpd-enabled": true,
    "max-peers-global": 200,
    "message-level": 2,
    "peer-congestion-algorithm": "",
    "peer-id-ttl-hours": 6,
    "peer-limit-global": 200,
    "peer-limit-per-torrent": 50,
    "peer-port": ${TR_PEER_PORT},
    "peer-port-random-high": 65535,
    "peer-port-random-low": 1025,
    "peer-port-random-on-start": false,
    "peer-socket-tos": "default",
    "pex-enabled": true,
    "port-forwarding-enabled": true,
    "preallocation": 1,
    "prefetch-enabled": true,
    "queue-stalled-enabled": true,
    "queue-stalled-minutes": 30,
    "ratio-limit": 2.0000,
    "ratio-limit-enabled": false,
    "rename-partial-files": true,
    "rpc-authentication-required": true,
    "rpc-bind-address": "${TR_BIND_ADDR}",
    "rpc-enabled": true,
    "rpc-host-whitelist": "",
    "rpc-host-whitelist-enabled": false,
    "rpc-password": "${TR_PASS}",
    "rpc-port": ${TR_RPC_PORT},
    "rpc-url": "/transmission/",
    "rpc-username": "${TR_USER}",
    "rpc-whitelist": "0.0.0.0/0",
    "rpc-whitelist-enabled": false,
    "scrape-paused-torrents-enabled": true,
    "script-torrent-done-enabled": false,
    "script-torrent-done-filename": "",
    "seed-queue-enabled": false,
    "seed-queue-size": 10,
    "speed-limit-down": 0,
    "speed-limit-down-enabled": false,
    "speed-limit-up": 0,
    "speed-limit-up-enabled": false,
    "start-added-torrents": true,
    "trash-original-torrent-files": false,
    "umask": 18,
    "upload-slots-per-torrent": 14,
${ssl_opts}
    "download-dir": "${TR_DOWNLOAD_DIR}"
}
EOF

    chmod 600 "$conf_file"
    chown "${TR_GID}:${TR_GID}" "$conf_file"
    info "配置文件写入完成: $conf_file"
}

# ─── Systemd 服务 ─────────────────────────────────────────────────────────────
create_systemd_service() {
    step "配置 Systemd 服务"

    local service_file="/etc/systemd/system/transmission.service"

    cat > "$service_file" << EOF
[Unit]
Description=Transmission BitTorrent Daemon
Documentation=man:transmission-daemon(1)
After=network.target

[Service]
Type=simple
User=${TR_UID}
Group=${SYSTEM_USER}
Environment=TRANSMISSION_WEB_HOME=${INSTALL_PREFIX}/share/transmission/public_html
ExecStart=${INSTALL_PREFIX}/bin/transmission-daemon --foreground --config-dir /home/${SYSTEM_USER}/.config/transmission
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
LimitNPROC=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=transmission-daemon

[Install]
WantedBy=multi-user.target
EOF

    # 创建日志目录 (使用 journal, 无需日志文件)

    systemctl daemon-reload
    info "Systemd 服务配置完成"
}

# ─── 安装 TrguiNG 美化界面 ────────────────────────────────────────────────────
# TrguiNG: 现代 React Web UI for Transmission
# https://github.com/openscopeproject/TrguiNG
# 4.0.5 默认查找 public_html 目录, 3.x 用 web 目录
install_web_control() {
    step "安装 TrguiNG Web UI"

    # 确定 web 目录 (4.0.5 用 public_html, 3.x 用 web)
    local tr_web_dir="${INSTALL_PREFIX}/share/transmission/public_html"
    mkdir -p "$tr_web_dir"

    info "Web UI 安装目录: $tr_web_dir"

    # 备份原版界面
    if [[ -f "${tr_web_dir}/index.html" ]] && [[ ! -f "${tr_web_dir}/index.original.html" ]]; then
        cp "${tr_web_dir}/index.html" "${tr_web_dir}/index.original.html"
        info "已备份原版 Web UI → index.original.html"
    fi

    # 从 GitHub Releases 下载 TrguiNG web 包
    local trguing_zip="/tmp/trguing-web.zip"
    local trguing_tmp="/tmp/trguing-web"
    local trguing_url="https://github.com/ManuZhu0728/TrguiNG/releases/download/v1.5.1-ee/trguing-web-v1.5.1-ee.zip"

    # 尝试获取最新版本下载链接
    local latest_url
    latest_url=$(curl -sL "https://api.github.com/repos/ManuZhu0728/TrguiNG/releases/latest" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); [print(a[\'browser_download_url\']) for a in d.get(\'assets\',[]) if \'web\' in a[\'name\'].lower()]" 2>/dev/null | head -1)
    [[ -n "$latest_url" ]] && trguing_url="$latest_url"

    info "下载 TrguiNG Web UI..."
    [[ "$TR_VERBOSE" == "1" ]] && echo "  URL: $trguing_url"

    rm -rf "$trguing_tmp" "$trguing_zip"
    if wget -q --no-check-certificate -O "$trguing_zip" "$trguing_url"; then
        mkdir -p "$trguing_tmp"
        if command -v unzip &>/dev/null; then
            unzip -qo "$trguing_zip" -d "$trguing_tmp"
        elif command -v python3 &>/dev/null; then
            python3 -c "import zipfile; zipfile.ZipFile(\'$trguing_zip\').extractall(\'$trguing_tmp\')"
        else
            if command -v jar &>/dev/null; then
                (cd "$trguing_tmp" && jar xf "$trguing_zip")
            else
                warn "找不到 unzip/python3/jar，跳过 TrguiNG 安装"
                warn "请手动下载 $trguing_url 并解压到 $tr_web_dir"
                rm -rf "$trguing_tmp" "$trguing_zip"
                return 0
            fi
        fi

        # 清空旧 web 文件并复制 TrguiNG
        rm -rf "${tr_web_dir:?}/"*
        # TrguiNG zip 解压后可能在子目录或根目录
        if [[ -f "${trguing_tmp}/index.html" ]]; then
            cp -rf "${trguing_tmp}/"* "${tr_web_dir}/"
        else
            # 查找含 index.html 的子目录
            local sub_dir
            sub_dir=$(find "$trguing_tmp" -name "index.html" -type f -print -quit 2>/dev/null | xargs dirname 2>/dev/null)
            if [[ -n "$sub_dir" && -f "${sub_dir}/index.html" ]]; then
                cp -rf "${sub_dir}/"* "${tr_web_dir}/"
            else
                warn "TrguiNG 包中未找到 index.html，跳过安装"
                rm -rf "$trguing_tmp" "$trguing_zip"
                return 0
            fi
        fi
        rm -rf "$trguing_tmp" "$trguing_zip"
    else
        warn "TrguiNG 下载失败，请手动下载并解压到 $tr_web_dir"
        warn "下载地址: https://github.com/ManuZhu0728/TrguiNG/releases"
        rm -rf "$trguing_tmp" "$trguing_zip"
        return 0
    fi

    # 强制中文语言 (TrguiNG 由浏览器 localStorage 决定)
    python3 -c "
import os
path = os.path.join('${tr_web_dir}', 'index.html')
if os.path.exists(path):
    with open(path) as f: content = f.read()
    inj = '<script>localStorage.setItem("i18nextLng","zh-Hans");</script>'
    if 'i18nextLng' not in content:
        content = content.replace('<head>', '<head>' + inj, 1)
        with open(path, 'w') as f: f.write(content)
"
    # 设置权限
    chown -R "${TR_GID}:${TR_GID}" "${tr_web_dir}" 2>/dev/null || true
    chmod -R 755 "${tr_web_dir}" 2>/dev/null || true

    info "✅ TrguiNG Web UI 安装完成"
    info "   访问地址: http://<服务器IP>:${TR_RPC_PORT}/transmission/web/"
}

# ─── 防火墙 ───────────────────────────────────────────────────────────────────
configure_firewall() {
    step "配置防火墙"

    if command -v ufw &>/dev/null; then
        ufw allow "${TR_RPC_PORT}/tcp" comment "Transmission RPC" 2>/dev/null || true
        ufw allow "${TR_PEER_PORT}/tcp" comment "Transmission P2P" 2>/dev/null || true
        ufw allow "${TR_PEER_PORT}/udp" comment "Transmission P2P UDP" 2>/dev/null || true
        info "UFW 规则已添加"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${TR_RPC_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="${TR_PEER_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="${TR_PEER_PORT}/udp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld 规则已添加"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "${TR_RPC_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport "${TR_PEER_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "${TR_PEER_PORT}" -j ACCEPT 2>/dev/null || true
        info "iptables 规则已添加 (重启后失效)"
    fi
}

# ─── 启动 ─────────────────────────────────────────────────────────────────────
start_service() {
    step "启动 Transmission 服务"

    systemctl enable transmission.service
    systemctl restart transmission.service

    sleep 3

    if systemctl is-active --quiet transmission.service; then
        info "✅ Transmission 服务已启动并设置开机自启"
    else
        error "服务启动失败，请检查日志:"
        journalctl -u transmission -n 20 --no-pager
        exit 1
    fi
}

# ─── 完成摘要 ─────────────────────────────────────────────────────────────────
show_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<服务器IP>")

    local protocol="http"
    local port_display="${TR_RPC_PORT}"
    if [[ "$TR_USE_SSL" == "1" ]]; then
        protocol="https"
    fi

    step "安装完成 ✅"
    echo
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}Web UI 地址:${NC}  ${protocol}://${ip}:${port_display}/transmission/"
    echo -e "  ${GREEN}用户名:${NC}       ${TR_USER}"
    echo -e "  ${GREEN}密码:${NC}         ${TR_PASS}"
    echo -e "  ${GREEN}RPC 端口:${NC}     ${TR_RPC_PORT}"
    echo -e "  ${GREEN}种子端口:${NC}     ${TR_PEER_PORT}"
    echo -e "  ${GREEN}下载目录:${NC}     ${TR_DOWNLOAD_DIR}"
    echo -e "  ${GREEN}未完成目录:${NC}   ${TR_INCOMPLETE_DIR}"
    echo -e "  ${GREEN}Transmission:${NC} ${TR_VERSION}"
    if [[ "$TR_USE_SSL" == "1" ]]; then
    echo -e "  ${GREEN}SSL:${NC}          已启用 (自签名证书)"
    fi
    if [[ "$TR_WEB_CONTROL" == "1" ]]; then
    echo -e "  ${GREEN}Web UI:${NC}       TrguiNG (现代 React Web UI)"
    fi
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  ${CYAN}常用命令:${NC}"
    echo -e "    查看状态:   systemctl status transmission"
    echo -e "    查看日志:   journalctl -u transmission -f"
    echo -e "    重启:       systemctl restart transmission"
    echo -e "    停止:       systemctl stop transmission"
    echo -e "    RPC CLI:    transmission-remote --auth ${TR_USER}:${TR_PASS} -l"
    echo -e "    卸载:       systemctl stop transmission && systemctl disable transmission && rm -rf ${INSTALL_PREFIX}/bin/transmission* && rm -f /etc/systemd/system/transmission.service"
    echo
    [[ "$TR_USE_SSL" == "1" ]] && warn "使用了自签名 SSL 证书，浏览器会报不安全提示，接受即可"
    info "首次登录后建议在 Web UI 中开启 DHT、PeX、LSD 以提高做种效果"
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${CYAN}${BOLD}"
    echo "   ██████╗ ███████╗████████╗██████╗  ██████╗ ██████╗  █████╗ ██████╗"
    echo "   ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗"
    echo "   ██████╔╝█████╗     ██║   ██████╔╝██║   ██║██████╔╝███████║██████╔╝"
    echo "   ██╔══██╗██╔══╝     ██║   ██╔══██╗██║   ██║██╔══██╗██╔══██║██╔══██╗"
    echo "   ██║  ██║███████╗   ██║   ██║  ██║╚██████╔╝██████╔╝██║  ██║██║  ██║"
    echo "   ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "   ${BOLD}Transmission-daemon 一键安装脚本 v1.1.0${NC}"
    echo -e "   版本: ${TR_VERSION} | RPC端口: ${TR_RPC_PORT} | 种子端口: ${TR_PEER_PORT}"
    echo -e "   下载目录: ${TR_DOWNLOAD_DIR}  (与 qBittorrent 同目录)"
    echo

    detect_os
    detect_arch
    check_existing
    create_user
    install_dependencies
    [[ "$TR_USE_SSL" == "1" ]] && generate_ssl
    install_transmission
    setup_directories
    generate_settings
    create_systemd_service
    [[ "$TR_WEB_CONTROL" == "1" ]] && install_web_control
    configure_firewall
    start_service
    show_summary
}

main "$@"

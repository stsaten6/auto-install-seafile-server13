#!/bin/bash
##############################################################################
# Seafile CE 13.0 一键部署脚本（修正版 v1.1）
# 相对原版的修复清单：
#  1. seadoc 补齐环境变量 + 创建 seadoc_db 数据库（原版必然导致 seadoc 崩溃循环）
#  2. 离线包完整性校验：5 个镜像全部检查（原版只检查 1 个）
#  3. docker compose 统一入口：docker compose / docker-compose 自动回退
#  4. Kylin V10 / openEuler / 统信 UOS 正确归类；RELEASE_VER 增加纯数字校验，
#     非数字时映射到可用仓库主版本（Kylin/openEuler/UOS -> centos/8）
#  5. 启动检测改为先捕获日志再 grep，规避 pipefail + grep -q 的 SIGPIPE 误判
#  6. mysqladmin 就绪等待加 120 秒超时；.env 生成后 chmod 600
#  7. caddy 仅在提供域名时启用（IP 部署无法签证书，跳过 HTTPS 反代）
#  8. 旧数据清理分支修复：非交互输入不再触发 set -u 崩溃，且不再重复生成配置
# 使用方式与官方一致：先将 5 个镜像打包为 seafile_offline.tar 放到 /root/
##############################################################################
set -uo pipefail
INSTALL_DIR="${INSTALL_DIR:-/opt/seafile}"
DOMAIN_OR_IP="${DOMAIN_OR_IP:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
SEAFILE_MYSQL_PASSWORD="${SEAFILE_MYSQL_PASSWORD:-}"
JWT_PRIVATE_KEY="${JWT_PRIVATE_KEY:-}"
OFFLINE_IMAGE="${OFFLINE_IMAGE:-/root/seafile_offline.tar}"
IMAGES=(seafileltd/seafile:13.0-latest seafileltd/seadoc:latest mariadb:10.11 memcached:1.6 redis:7 caddy:2)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
gen_pass() { openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16; }
gen_jwt()  { openssl rand -base64 32 | tr -d '\n'; }
# ---------- 解析 compose 命令（v2 插件或独立二进制） ----------
resolve_compose() {
    COMPOSE=""
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null; then
        COMPOSE="docker-compose"
    fi
}
# ---------- 系统检测 ----------
detect_os() {
    info "===== 1/8 检测操作系统 ====="
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        VERSION_ID="${VERSION_ID:-}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="centos"
        VERSION_ID=$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides redhat-release)" | cut -d. -f1)
    else
        error "无法识别操作系统"
    fi
    case "$OS_ID" in
        centos|rhel|kylin|openEuler|fedora|rocky|almalinux|anolis)
            if command -v dnf &>/dev/null; then PKG="dnf"
            elif command -v yum &>/dev/null; then PKG="yum"
            else error "未找到 dnf/yum"; fi
            OS_FAMILY="redhat"
            case "$OS_ID" in
                centos|rhel) RELEASE_VER="${VERSION_ID%%.*}" ;;
                rocky|almalinux|anolis)
                    RELEASE_VER=$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides redhat-release 2>/dev/null)" 2>/dev/null | cut -d. -f1) ;;
                *) RELEASE_VER="" ;;  # kylin/openEuler/fedora 走下方映射
            esac
            ;;
        ubuntu|debian|deepin|uos)   # 统信 UOS 基于 Debian，归入 apt 系
            PKG="apt"; OS_FAMILY="debian";;
        *)
            if command -v dnf &>/dev/null; then PKG="dnf"; OS_FAMILY="redhat"; RELEASE_VER="8"
            elif command -v yum &>/dev/null; then PKG="yum"; OS_FAMILY="redhat"; RELEASE_VER="7"
            elif command -v apt &>/dev/null; then PKG="apt"; OS_FAMILY="debian"
            else error "无法确定包管理器"; fi
            ;;
    esac
    # REPO_VER 必须为纯数字，否则按发行版映射到兼容的阿里云仓库主版本
    if [[ -n "${RELEASE_VER:-}" && "$RELEASE_VER" =~ ^[0-9]+$ ]]; then
        REPO_VER="$RELEASE_VER"
    else
        case "$OS_ID" in
            kylin|openEuler|uos) REPO_VER="8" ;;  # 均为 RHEL8 系
            fedora) REPO_VER="9" ;;
            *) REPO_VER="7" ;;
        esac
        RELEASE_VER="${RELEASE_VER:-?}"
    fi
    info "系统: ${OS_ID} ${VERSION_ID:-} | 包管理器: $PKG | 仓库主版本: ${REPO_VER:-?}"
}
# ---------- Docker 安装（阿里云源） ----------
install_docker() {
    info "===== 2/8 安装 Docker ====="
    resolve_compose
    if command -v docker &>/dev/null && [ -n "$COMPOSE" ]; then
        info "Docker 已就绪，跳过安装"
        return 0
    fi
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -y && apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        $PKG remove -y docker docker-client docker-client-latest docker-common docker-latest \
            docker-latest-logrotate docker-logrotate docker-engine docker-ce docker-ce-cli podman runc 2>/dev/null || true
        $PKG install -y yum-utils device-mapper-persistent-data lvm2 curl openssl || true
        local baseurl="http://mirrors.aliyun.com/docker-ce/linux/centos/${REPO_VER:-7}/\$basearch/stable"
        cat > /etc/yum.repos.d/docker-ce.repo <<REPO
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=${baseurl}
enabled=1
gpgcheck=0
REPO
        if [ "${REPO_VER:-7}" -eq 7 ]; then
            info "CentOS 7 环境，安装额外依赖..."
            $PKG install -y epel-release || true
            $PKG install -y container-selinux fuse-overlayfs slirp4netns || true
        fi
        $PKG makecache || true
        $PKG install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
            error "Docker 安装失败，请检查网络和依赖"
    fi
    systemctl enable --now docker
    if ! docker compose version &>/dev/null; then
        curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    resolve_compose
    [ -n "$COMPOSE" ] || error "docker compose 不可用"
    info "Docker 安装完成"
}
# ---------- 导入离线镜像（校验全部 5 个镜像） ----------
import_images() {
    info "===== 3/8 导入离线镜像 ====="
    if [ ! -f "$OFFLINE_IMAGE" ]; then
        error "离线镜像包 $OFFLINE_IMAGE 不存在！请先在可联网机器上拉取以下镜像并打包：${IMAGES[*]}"
    fi
    local missing=0 img=""
    for img in "${IMAGES[@]}"; do
        if ! docker image inspect "$img" &>/dev/null; then
            warn "本地缺少镜像: $img"
            missing=1
        fi
    done
    if [ $missing -eq 0 ]; then
        info "所需镜像均已存在，跳过导入"
        return 0
    fi
    info "正在导入镜像（可能需要几分钟）..."
    docker load -i "$OFFLINE_IMAGE" || error "镜像导入失败"
    for img in "${IMAGES[@]}"; do
        docker image inspect "$img" &>/dev/null || error "离线包中缺少镜像: $img，请重新打包"
    done
    info "镜像导入完成"
}
# ---------- 生成配置文件 ----------
generate_configs() {
    info "===== 4/8 生成配置文件 ====="
    mkdir -p "$INSTALL_DIR"/{db,caddy-data,seafile-data}
    cd "$INSTALL_DIR"
    [ -z "$DOMAIN_OR_IP" ] && DOMAIN_OR_IP=$(hostname -I | awk '{print $1}')
    # IP 无法申请证书，caddy 仅在有域名时启用
    if [[ "$DOMAIN_OR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        USE_CADDY=0
        warn "检测到 IP 访问地址（${DOMAIN_OR_IP}），跳过 caddy HTTPS 反代（通过 80 端口直接访问）"
    else
        USE_CADDY=1
    fi
    cat > .env <<EOF
SEAFILE_SERVER_HOSTNAME=${DOMAIN_OR_IP}
SEAFILE_ADMIN_EMAIL=${ADMIN_EMAIL}
SEAFILE_ADMIN_PASSWORD=${ADMIN_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
SEAFILE_MYSQL_DB_PASSWD=${SEAFILE_MYSQL_PASSWORD}
JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
LETSENCRYPT_EMAIL=${ADMIN_EMAIL}
TIME_ZONE=Asia/Shanghai
EOF
    chmod 600 .env
    cat > seafile-server.yml <<'YAML'
services:
  db:
    image: mariadb:10.11
    container_name: seafile-mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    restart: unless-stopped
  memcached:
    image: memcached:1.6
    container_name: seafile-memcached
    entrypoint: memcached -m 256
    restart: unless-stopped
  redis:
    image: redis:7
    container_name: seafile-redis
    restart: unless-stopped
  seafile:
    image: seafileltd/seafile:13.0-latest
    container_name: seafile
    ports:
      - "80:80"
    environment:
      - SEAFILE_SERVER_HOSTNAME=${SEAFILE_SERVER_HOSTNAME}
      - SEAFILE_ADMIN_EMAIL=${SEAFILE_ADMIN_EMAIL}
      - SEAFILE_ADMIN_PASSWORD=${SEAFILE_ADMIN_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - SEAFILE_MYSQL_DB_HOST=db
      - SEAFILE_MYSQL_DB_PORT=3306
      - SEAFILE_MYSQL_DB_USER=seafile
      - SEAFILE_MYSQL_DB_PASSWD=${SEAFILE_MYSQL_DB_PASSWD}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
      - SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=seahub_db
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAFILE_SERVER_PROTOCOL=http
      - TIME_ZONE=Asia/Shanghai
    volumes:
      - ./seafile-data:/shared
    depends_on:
      - db
      - memcached
      - redis
    restart: unless-stopped
  seadoc:
    image: seafileltd/seadoc:latest
    container_name: seafile-seadoc
    volumes:
      - ./seafile-data:/shared
    environment:
      - SEAFILE_MYSQL_DB_HOST=db
      - SEAFILE_MYSQL_DB_PORT=3306
      - SEAFILE_MYSQL_DB_USER=seafile
      - SEAFILE_MYSQL_DB_PASSWD=${SEAFILE_MYSQL_DB_PASSWD}
      - SEAFILE_MYSQL_DB_SEADOC_DB_NAME=seadoc_db
      - SEAFILE_SERVER_HOSTNAME=${SEAFILE_SERVER_HOSTNAME}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
    depends_on:
      - seafile
    restart: unless-stopped
YAML
    if [ "$USE_CADDY" -eq 1 ]; then
        cat >> seafile-server.yml <<'YAML'
  caddy:
    image: caddy:2
    container_name: seafile-caddy
    ports:
      - "443:443"
    volumes:
      - ./caddy-data:/data
    command: caddy reverse-proxy --from ${SEAFILE_SERVER_HOSTNAME} --to seafile:80
    depends_on:
      - seafile
    restart: unless-stopped
YAML
    fi
    info "配置文件已生成（services: db/memcached/redis/seafile/seadoc$( [ "$USE_CADDY" -eq 1 ] && echo "/caddy")）"
}
# ---------- 数据库预初始化 ----------
init_mysql() {
    info "===== 5/8 初始化数据库 ====="
    cd "$INSTALL_DIR"
    $COMPOSE -f seafile-server.yml up -d db
    info "等待数据库就绪（最多 120 秒）..."
    local tries=0 ready=0
    while [ $tries -lt 60 ]; do
        if docker exec seafile-mysql mysqladmin -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent &>/dev/null; then
            ready=1
            break
        fi
        tries=$((tries+1))
        sleep 2
    done
    [ $ready -eq 1 ] || error "数据库 120 秒内未就绪，请检查: docker logs seafile-mysql"
    docker exec seafile-mysql mysql -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS ccnet_db CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS seafile_db CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS seahub_db CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS seadoc_db CHARACTER SET utf8mb4;
DROP USER IF EXISTS 'seafile'@'%';
CREATE USER 'seafile'@'%' IDENTIFIED BY '${SEAFILE_MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON ccnet_db.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON seafile_db.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON seahub_db.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON seadoc_db.* TO 'seafile'@'%';
FLUSH PRIVILEGES;
SQL
    info "数据库准备完毕"
}
# ---------- 启动所有容器并等待服务启动 ----------
start_services() {
    info "===== 6/8 启动容器 ====="
    cd "$INSTALL_DIR"
    $COMPOSE -f seafile-server.yml up -d
    info "===== 7/8 等待 Seafile 启动（最多 3 分钟） ====="
    local success=0 logs="" i=""
    for i in $(seq 1 36); do
        logs=$(docker logs seafile 2>&1 || true)
        if grep -qE "Seafile started|Successfully started|seahub is started" <<<"$logs"; then
            success=1
            break
        fi
        sleep 5
    done
    if [ $success -eq 1 ]; then
        info "Seafile 启动成功"
    else
        warn "未在日志中检测到标准启动标记，但服务可能已静默运行。"
        if curl -sfI http://localhost &>/dev/null; then
            info "Web 界面可访问"
        else
            warn "无法访问 Web 界面，请检查日志：docker logs seafile"
        fi
    fi
}
# ---------- 输出信息 ----------
show_summary() {
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}Seafile CE 13.0 部署完成！${NC}"
    echo "  访问地址: http://${DOMAIN_OR_IP}"
    echo "  管理员邮箱: ${ADMIN_EMAIL}"
    echo "  管理员密码: ${ADMIN_PASSWORD}"
    echo "  MySQL root 密码: ${MYSQL_ROOT_PASSWORD}"
    echo "  Seafile 数据库密码: ${SEAFILE_MYSQL_PASSWORD}"
    echo "============================================================"
    echo "  实时日志: docker logs -f seafile"
}
# ---------- 主流程 ----------
main() {
    [ "$EUID" -eq 0 ] || error "请使用 root 权限运行"
    detect_os
    [ -z "$MYSQL_ROOT_PASSWORD" ] && MYSQL_ROOT_PASSWORD=$(gen_pass)
    [ -z "$SEAFILE_MYSQL_PASSWORD" ] && SEAFILE_MYSQL_PASSWORD=$(gen_pass)
    [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD=$(gen_pass)
    [ -z "$JWT_PRIVATE_KEY" ] && JWT_PRIVATE_KEY=$(gen_jwt)
    install_docker
    import_images
    # 清理旧数据（询问；非交互且无输入时明确中止而非崩溃）
    if [ -d "$INSTALL_DIR/db" ] || [ -d "$INSTALL_DIR/seafile-data" ]; then
        warn "检测到旧数据，是否删除并全新部署？(y/n)"
        read -r -n 1 REPLY || REPLY=""
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ( cd "$INSTALL_DIR" && $COMPOSE -f seafile-server.yml down -v ) 2>/dev/null || true
            rm -rf "$INSTALL_DIR"
        elif [ -z "$REPLY" ] && [ ! -t 0 ]; then
            error "非交互环境下检测到旧数据，请先手动清理 $INSTALL_DIR 后重试"
        else
            error "请手动处理旧数据后重试"
        fi
    fi
    generate_configs
    init_mysql
    start_services
    show_summary
}
main "$@"

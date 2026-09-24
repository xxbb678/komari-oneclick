#!/bin/bash
# Komari 监控面板 一键安装脚本 (Docker Compose + Cloudflare Tunnel + GitHub 备份)
# 仓库: https://github.com/xxbb678/komari-oneclick

if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
    exit 0
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()   { echo -e "${BLUE}[提示]${NC} $1"; }
success(){ echo -e "${GREEN}[成功]${NC} $1"; }
warning(){ echo -e "${YELLOW}[警告]${NC} $1"; }
error()  { echo -e "${RED}[错误]${NC} $1"; }

GH_PROXY_URL="https://ghfast.top"
GH_CLONE_URL="https://github.com/xxbb678/komari-oneclick.git"
WORK_DIR="$HOME/komari-oneclick"
COMPOSE_FILE="$WORK_DIR/compose.yml"
BACKUP_SCRIPT="$WORK_DIR/backup.sh"
EVN_='.env'

curl_max() { curl -s --connect-timeout 10 --max-time 20 "$@"; }

trap 'error "脚本被用户中断"; exit 1' INT

# ---------- Docker 检查 ----------
check_docker() {
    if ! command -v docker &>/dev/null; then
        warning "Docker 未安装，正在自动安装..."
        curl -fsSL --connect-timeout 10 --max-time 60 https://get.docker.com | sh || {
            error "Docker 安装失败! 请手动安装后重试"; exit 1; }
        success "Docker 安装成功"
    fi
    if ! docker compose version &>/dev/null; then
        error "Docker Compose 插件不可用! 请安装 Docker v20.10+"; exit 1
    fi
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        systemctl start docker 2>/dev/null || { error "Docker 服务启动失败!"; exit 1; }
    fi
}

# ---------- 网络/GitHub 出口检查 ----------
check_network() {
    if ! retry 3 curl_max -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null | grep -q '2\|3'; then
        error "无法访问 github.com，请确认出口网络(IPv4/纯IPv6+WARP)正常"
        exit 1
    fi
}

retry() {
    local max=$1; shift; local attempt=1
    while [ $attempt -le $max ]; do "$@" && return 0; ((attempt++)); sleep $((attempt*2)); done
    return 1
}

# ---------- 获取部署文件 ----------
prepare_files() {
    if [ -f "$COMPOSE_FILE" ] && [ -f "$BACKUP_SCRIPT" ]; then
        info "已就绪: $WORK_DIR"; return 0
    fi
    mkdir -p "$WORK_DIR"
    info "正在获取部署文件 (compose.yml / backup.sh)..."
    cd "$WORK_DIR" || { error "无法进入 $WORK_DIR"; exit 1; }
    if ! retry 3 git clone --branch main --depth 1 "$GH_PROXY_URL/$GH_CLONE_URL" "$WORK_DIR/.src" 2>/dev/null; then
        # 代理失败回退直连
        rm -rf "$WORK_DIR/.src"
        if ! retry 3 git clone --branch main --depth 1 "$GH_CLONE_URL" "$WORK_DIR/.src" 2>/dev/null; then
            error "拉取部署文件失败。请检查网络或手动 git clone"; exit 1
        fi
    fi
    cp -f "$WORK_DIR/.src/compose.yml" "$WORK_DIR/" 2>/dev/null
    cp -f "$WORK_DIR/.src/backup.sh"  "$WORK_DIR/" 2>/dev/null
    cp -f "$WORK_DIR/.src/komari.sh"  "$WORK_DIR/" 2>/dev/null || true
    rm -rf "$WORK_DIR/.src"
    chmod +x "$WORK_DIR/backup.sh" 2>/dev/null
    success "部署文件就绪"
}

# ---------- 生成 .env ----------
write_env() {
    cat > "$WORK_DIR/$EVN_" <<EOF
GITHUB_TOKEN=${GITHUB_TOKEN}
GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME}
BACKUP_BRANCH=${BACKUP_BRANCH:-komari-backup}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ARGO_AUTH=${ARGO_AUTH}
ARGO_DOMAIN=${ARGO_DOMAIN}
EOF
}

# ---------- GitHub token 验证(带超时) ----------
validate_github_token() {
    info "验证 GitHub Token 权限..."
    local resp code body
    resp=$(curl_max -w '%{http_code}' -H "Authorization: token $GITHUB_TOKEN" \
           -H "Accept: application/vnd.github+json" https://api.github.com/user)
    code="${resp: -3}"; body="${resp%???}"
    if [ -z "$code" ]; then error "无法连接 GitHub API(网络超时)"; exit 1; fi
    if [ "$code" != "200" ]; then
        error "Token 验证失败! HTTP $code\n$body"; exit 1
    fi
}

# ---------- 输入参数 ----------
input_variables() {
    echo -e "\n${YELLOW}==== 配置输入 (按Ctrl+C退出) ====${NC}"
    while true; do
        read -r -p $'\nGitHub Token (明文显示, 粘贴后回车): ' GITHUB_TOKEN || { echo; error "输入中断"; exit 1; }
        [ -n "$GITHUB_TOKEN" ] && break
        warning "Token 不能为空!"
    done
    validate_github_token

    while true; do
        read -r -p $'\nGitHub 用户名: ' GITHUB_REPO_OWNER || { echo; error "输入中断"; exit 1; }
        [ -n "$GITHUB_REPO_OWNER" ] && break
        warning "用户名不能为空!"
    done
    read -r -p $'\n备份仓库名 (默认 komari-backup): ' GITHUB_REPO_NAME
    GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-komari-backup}

    # 检查备份仓库/分支，不存在则创建私有仓库
    repo_status=$(curl_max -o /dev/null -w "%{http_code}" \
                  -H "Authorization: token $GITHUB_TOKEN" \
                  -H "Accept: application/vnd.github+json" \
                  https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME)
    case $repo_status in
        200) success "备份仓库已存在，跳过创建" ;;
        404) info "正在创建私有仓库 $GITHUB_REPO_NAME..."
             curl_max -X POST --connect-timeout 10 --max-time 20 -H "Authorization: token $GITHUB_TOKEN" \
                  -H "Accept: application/vnd.github+json" \
                  -d "{\"name\":\"$GITHUB_REPO_NAME\",\"private\":true}" \
                  https://api.github.com/user/repos >/dev/null || { error "仓库创建失败! 请检查 Token 是否有 repo 权限"; exit 1; }
             success "私有仓库 $GITHUB_REPO_NAME 创建成功" ;;
        403) error "GitHub API 速率限制，稍后重试"; exit 1 ;;
        *)   error "检查仓库失败 (HTTP $repo_status)"; exit 1 ;;
    esac

    read -r -p $'\n面板登录账户 (留空默认 admin): ' ADMIN_USERNAME
    ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
    read -r -s -p $'\n面板登录密码: ' ADMIN_PASSWORD || { echo; error "输入中断"; exit 1; }
    echo
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)}

    echo -e "\n${YELLOW}==== Argo/Cloudflare Tunnel 配置 ====${NC}"
    echo -e "在 Cloudflare Zero Trust → Access → Tunnels 创建一个隧道，取得 Tunnel Token (ey开头)"
    while true; do
        read -r -p $'\nArgo Tunnel Token (明文显示, 粘贴后回车): ' ARGO_AUTH || { echo; error "输入中断"; exit 1; }
        [ -n "$ARGO_AUTH" ] && break
        warning "Token 不能为空!"
    done
    while true; do
        read -r -p $'\n面板访问域名 (如 komari.example.com): ' ARGO_DOMAIN || { echo; error "输入中断"; exit 1; }
        if [[ "$ARGO_DOMAIN" =~ ^([a-zA-Z0-9]+(-[a-zA-Z0-9]+)*\.)+[a-zA-Z]{2,}$ ]]; then
            break
        else
            warning "域名格式无效! 请用类似 komari.example.com 的格式"
        fi
    done
    read -r -p $'\n备份分支名 (默认 komari-backup): ' BACKUP_BRANCH
    BACKUP_BRANCH=${BACKUP_BRANCH:-komari-backup}

    write_env
    echo -e "\n${YELLOW}==== 配置摘要 ====${NC}"
    awk -F'=' '{ if($1=="GITHUB_TOKEN"||$1=="ARGO_AUTH") print $1"=******"; else print $0 }' "$WORK_DIR/$EVN_" | grep -vE '^ADMIN_PASSWORD' || true
    echo "ADMIN_USERNAME=$ADMIN_USERNAME  ADMIN_PASSWORD=******"
}

# ---------- 启动 ----------
start_service() {
    info "正在启动 Komari + Cloudflared..."
    cd "$WORK_DIR" || exit 1
    docker compose pull && docker compose up -d || {
        error "启动失败! 请检查:\n1. Docker 服务状态\n2. 能否拉取 ghcr.io 镜像(国内可先配镜像加速)\n3. 磁盘空间"; exit 1; }
    success "✅ 部署启动成功"
    echo -e "\n${BLUE}▍重要: 去 Cloudflare 面板配置隧道 Ingress${NC}"
    echo -e "将域名 $ARGO_DOMAIN (或 *.$ARGO_DOMAIN) 的"
    echo -e "HTTP Service 指向: ${GREEN}http://komari:25774${NC}"
    echo -e "保存后等待 30 秒，即可访问 ${GREEN}https://$ARGO_DOMAIN${NC}"
}

# ---------- 修复 PurCarte 登录过期后进入 404 ----------
fix_purcarte_login_redirect() {
    local theme_file="$WORK_DIR/data/theme/PurCarte/dist/index.html"
    local marker="KOMARI_LOGIN_REDIRECT"
    local patch='<script>/* KOMARI_LOGIN_REDIRECT */if(location.pathname==="/login"||location.pathname.startsWith("/login/")){location.replace("/admin");}</script>'

    [ -f "$theme_file" ] || {
        info "未安装 PurCarte 主题，跳过登录过期 404 修复"
        return 0
    }

    if grep -qF "$marker" "$theme_file"; then
        info "PurCarte 登录过期 404 修复已存在"
        return 0
    fi

    cp -a "$theme_file" "$theme_file.bak-login-redirect" 2>/dev/null || true
    python3 - "$theme_file" "$patch" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
patch = sys.argv[2]
s = p.read_text()
if "KOMARI_LOGIN_REDIRECT" not in s:
    s = s.replace("<head>", "<head>" + patch, 1)
    p.write_text(s)
PY

    if grep -qF "$marker" "$theme_file"; then
        success "PurCarte 登录过期 404 修复已应用"
    else
        warning "PurCarte 登录过期 404 修复应用失败"
    fi
}

# ---------- cron 备份 ----------
config_cron() {
    info "当前工作目录: $WORK_DIR"
    read -r -p $'\n是否开启数据自动备份到 GitHub? (每天 02:10 执行) [y/N] ' enable_backup || enable_backup=n
    if [[ "$enable_backup" =~ [Yy] ]]; then
        mkdir -p "$WORK_DIR/logs"
        local tag="# KOMARI-V1-BACKUP"
        local cronline="10 2 * * * export TZ=Asia/Shanghai; log_file=\"$WORK_DIR/logs/backup-\$(date +\%Y\%m\%d-\%H\%M\%S).log\"; /bin/bash \"$BACKUP_SCRIPT\" backup > \"\$log_file\" 2>&1 $tag"
        ( crontab -l 2>/dev/null | grep -vF "$tag"; printf '%s\n' "$cronline" ) | crontab -
        if crontab -l | grep -qF "$tag"; then
            success "自动备份已配置 (每天 02:10)"
        else
            warning "cron 写入失败，可手动执行: $BACKUP_SCRIPT backup"
        fi
    else
        info "未启用自动备份"
    fi
}

# ---------- 离线通知自动开启 ----------
enable_offline_auto() {
    local tag="# KOMARI-V1-OFFLINE"
    local f="$WORK_DIR/check_offline_auto.sh"
    [ -f "$f" ] || { warning "未找到 $f，跳过离线通知自动开启配置"; return 0; }
    chmod +x "$f"
    command -v sqlite3 >/dev/null 2>&1 || {
        info "安装 sqlite3..."
        (command -v apt-get >/dev/null && apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq sqlite3 >/dev/null 2>&1) || \
        (command -v yum >/dev/null && yum install -y -q sqlite >/dev/null 2>&1) || \
        (command -v apk >/dev/null && apk add --no-interactive sqlite >/dev/null 2>&1) || \
        warning "sqlite3 安装失败，离线通知自动开启不可用"
    }
    # 首次启动容器可能尚未建库, 稍候再启用现有机器
    sleep 4
    if bash "$f" 2>/dev/null; then
        info "已为当前机器启用离线通知"
    else
        warning "数据库未就绪或 sqlite3 不可用，将由每分钟 cron 自动补齐"
    fi
    ( crontab -l 2>/dev/null | grep -vF "$tag"; printf '%s\n' "* * * * * /bin/bash $f >/dev/null 2>&1 $tag" ) | crontab -
    if crontab -l | grep -qF "$tag"; then
        success "离线通知自动开启已配置 (每分钟检查新机器)"
    else
        warning "cron 写入失败, 可手动执行: bash $f"
    fi
}

# ---------- 延迟监测全局化 ----------
enable_ping_allclients() {
    local tag="# KOMARI-V1-PINGAC"
    local f="$WORK_DIR/check_ping_allclients.sh"
    [ -f "$f" ] || { warning "未找到 $f，跳过延迟监测全局化配置"; return 0; }
    chmod +x "$f"
    command -v sqlite3 >/dev/null 2>&1 || {
        info "安装 sqlite3..."
        (command -v apt-get >/dev/null && apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq sqlite3 >/dev/null 2>&1) || \
        (command -v yum >/dev/null && yum install -y -q sqlite >/dev/null 2>&1) || \
        (command -v apk >/dev/null && apk add --no-interactive sqlite >/dev/null 2>&1) || \
        warning "sqlite3 安装失败，延迟监测全局化不可用"
    }
    sleep 4
    if bash "$f" 2>/dev/null; then
        info "延迟监测已设为对所有机器生效"
    else
        warning "数据库未就绪或 sqlite3 不可用，将由每分钟 cron 自动补齐"
    fi
    ( crontab -l 2>/dev/null | grep -vF "$tag"; printf '%s\n' "* * * * * /bin/bash $f >/dev/null 2>&1 $tag" ) | crontab -
    if crontab -l | grep -qF "$tag"; then
        success "延迟监测自动全局化已配置 (每分钟, 新任务也自动对所有机器生效)"
    else
        warning "cron 写入失败, 可手动执行: bash $f"
    fi
}

# ---------- 卸载 ----------
uninstall() {
    echo -e "\n${RED}==== 卸载 Komari ====${NC}"
    echo "将停止并删除容器，但会保留数据和备份配置:"
    echo "  停止容器    : komari, komari-cloudflared"
    echo   "  移除 cron    : komari 自动备份任务"
    echo   "  保留数据目录 : $WORK_DIR/data"
    echo   "  (如需彻底删除数据，之后手动: rm -rf $WORK_DIR)"
    read -r -p $'\n确定卸载? [y/N] ' ans || ans=n
    [[ "$ans" =~ [Yy] ]] || { info "已取消卸载"; return; }

    cd "$WORK_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    crontab -l 2>/dev/null | grep -vF '# KOMARI-V1-BACKUP' | crontab - || true
    success "卸载完成，容器已删除，数据保留于 $WORK_DIR/data"
}

# ---------- 菜单 ----------
menu_install() {
    check_docker
    check_network
    prepare_files
    input_variables
    start_service
    fix_purcarte_login_redirect
    enable_offline_auto
    enable_ping_allclients
    config_cron
}

menu_info() {
    echo -e "\n${BLUE}==== Komari 状态 ====${NC}"
    docker ps -a --filter "name=komari" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
    echo -e "\n${BLUE}▍面板地址${NC}"
    grep -q 'ARGO_DOMAIN=' "$WORK_DIR/$EVN_" 2>/dev/null && echo "  https://$(grep '^ARGO_DOMAIN=' "$WORK_DIR/$EVN_" | cut -d= -f2- 2>/dev/null)"
    echo -e "\n${BLUE}▍常用命令${NC}"
    echo -e "  查看日志   ${GREEN}docker logs -f komari${NC}"
    echo -e "  重启服务   ${GREEN}docker compose -f $COMPOSE_FILE restart${NC}"
    echo -e "  立即备份   ${GREEN}$BACKUP_SCRIPT backup${NC}"
    echo -e "\n${BLUE}▍安装 Agent(客户端)接入此面板${NC}"
    echo -e "  docker run -d --name komari-agent --restart unless-stopped \\"
    echo -e "    ghcr.io/komari-monitor/komari-agent:latest \\"
    echo -e "    -e http://<你的域名>/ -t <面板里生成的节点Token>"
}

main() {
    clear
    while true; do
        echo -e "
${BLUE}════════ Komari 一键脚本 ════════${NC}
  ${GREEN}1)${NC} 安装
  ${GREEN}2)${NC} 查看信息
  ${GREEN}3)${NC} 立即备份到 GitHub
  ${GREEN}4)${NC} 重新配置备份参数
  ${RED}5)${NC} 卸载
  ${GREEN}0)${NC} 退出
${BLUE}════════════════════════════════${NC}"
        read -r -p $'请选择: ' opt || break
        case $opt in
            1) menu_install ;;
            2) menu_info ;;
            3) "$BACKUP_SCRIPT" backup ;;
            4) cd "$WORK_DIR" 2>/dev/null; input_variables ; echo "备份配置已更新" ;;
            5) uninstall ;;
            0) break ;;
            *) warning "无效选项"; sleep 1 ;;
        esac
        echo; read -r -p "按回车返回菜单..." _ 2>/dev/null || true
    done
}
main
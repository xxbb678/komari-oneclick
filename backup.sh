#!/bin/bash

# 确保在 Bash 中执行
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
    exit 0
fi

# 加载同目录下的 .env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
if [ -f "$SCRIPT_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^# ]] || [[ -z "$key" ]] && continue
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        export "$key"="$value"
    done < "$SCRIPT_DIR/.env"
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-""}
GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER:-""}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-""}
BACKUP_BRANCH=${BACKUP_BRANCH:-"komari-backup"}

DATA_DIR="$SCRIPT_DIR/data"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_DAYS=7
CLONE_DEPTH=20

[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
[ ! -d "$DATA_DIR" ] && mkdir -p "$DATA_DIR"

export GIT_AUTHOR_NAME="[Auto] Komari Backup"
export GIT_AUTHOR_EMAIL="backup@komari.oneclick"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export LANG=en_US.UTF-8
export TZ=Asia/Shanghai

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

die() { echo "错误: $*" >&2; exit 1; }

[ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_REPO_OWNER" ] || [ -z "$GITHUB_REPO_NAME" ] && {
    die "未设置 GitHub 备份参数，跳过备份。请先在 komari.sh 中配置备份。"
}

urlencode() {
    echo -n "$1" | od -An -tx1 | tr -d '\n ' | sed 's/../%&/g'
}
ENCODED_TOKEN=$(urlencode "$GITHUB_TOKEN")
CLONE_URL="https://${ENCODED_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

clean_old_logs() {
    echo "正在清理过期日志(>$LOG_DAYS 天)..."
    find "$LOG_DIR" -maxdepth 1 -type f -name "backup-*.log" -mtime +"$LOG_DAYS" -delete
    echo "日志清理完成"
}

# 清理 GitHub 仓库中超过 7 天的备份
cleanup_old_backups() {
    echo "开始清理 GitHub 仓库中超过 7 天的备份..."
    local repo_dir="$TEMP_DIR/cleanup_repo"
    if ! git clone --depth "$CLONE_DEPTH" --branch "$BACKUP_BRANCH" --single-branch "$CLONE_URL" "$repo_dir" 2>/dev/null; then
        echo "备份分支不存在，跳过清理"
        return 0
    fi
    cd "$repo_dir" || return 1
    local cutoff_date
    cutoff_date=$(date -u -v-7d +%Y%m%d 2>/dev/null || date -u -d "-7 days" +%Y%m%d)
    local deleted=0
    while IFS= read -r -d '' file; do
        local filename base fdate
        filename=$(basename "$file")
        base="${filename#komari_data_}"
        fdate="${base%%-*}"
        if [[ "$fdate" =~ ^[0-9]{8}$ ]] && [[ "$fdate" -le "$cutoff_date" ]]; then
            git rm -q --cached "$file" 2>/dev/null
            rm -f "$file"
            ((deleted++))
        fi
    done < <(find . -type f -name "komari_data_*.tar.gz" -not -path "./.git/*" -print0 2>/dev/null)
    if [ "$deleted" -gt 0 ]; then
        git add -A
        git commit -m "自动清理: 删除 7 天前的备份" -q && git push origin "$BACKUP_BRANCH" -q
        echo "已清理 $deleted 个过期备份"
    else
        echo "没有需要清理的旧备份"
    fi
}

create_backup() {
    TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
    COMMIT_TIME=$(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S %Z')
    ARCHIVE_NAME="komari_data_${TIMESTAMP}.tar.gz"

    echo "正在打包 Komari 数据目录..."
    tar -czf "$TEMP_DIR/$ARCHIVE_NAME" -C "$DATA_DIR" . 2>/dev/null || die "数据打包失败"

    # 初始化备份仓库
    local deft="$TEMP_DIR/backup_repo"
    if git clone --depth "$CLONE_DEPTH" --branch "$BACKUP_BRANCH" --single-branch "$CLONE_URL" "$deft" 2>/dev/null; then
        cp "$TEMP_DIR/$ARCHIVE_NAME" "$deft/"
    else
        mkdir -p "$deft"
        cd "$deft" || die "无法进入备份目录"
        git init -q -b "$BACKUP_BRANCH"
        cp "$TEMP_DIR/$ARCHIVE_NAME" "$deft/"
    fi

    cd "$deft" || die "无法进入备份目录"
    git remote add origin "$CLONE_URL" 2>/dev/null
    git add "$ARCHIVE_NAME"
    git -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" commit -m "新增备份 $COMMIT_TIME" --allow-empty -q
    git push origin "$BACKUP_BRANCH" -q || die "推送备份到 GitHub 失败"

    echo "✅ 备份完成: $ARCHIVE_NAME"
}

case "$1" in
    backup)
        cleanup_old_backups
        create_backup
        clean_old_logs
        ;;
    *)
        echo "Usage: $0 backup" >&2
        exit 1
        ;;
esac
# komari-oneclick

[Komari](https://github.com/komari-monitor/komari) 轻量自托管服务器监控面板 一键部署脚本。

- **Docker Compose** 部署 Komari 面板 + Cloudflare Tunnel（cloudflared）
- 用自己的域名通过 **Cloudflare Tunnel** 访问面板，无需公网入站端口
- **自动备份**到你自己 GitHub 私有仓库（每天 02:10，本地 cron）
- 纯 IPv6 / 低配机器可正常部署（全部走云出站，无需公网 IPv4）

## 一键安装

```bash
bash -c "$(curl -fsSL --max-time 60 https://ghfast.top/https://raw.githubusercontent.com/xxbb678/komari-oneclick/main/komari.sh)"
```

或 clone 本仓库后执行 `./komari.sh`。

安装时依次输入：
1. **GitHub Token**（明文显示，需 `repo` 权限，用于自动备份到私有仓）
2. **GitHub 用户名**、**备份仓库名**（默认自动创建私有仓库 `komari-backup`）
3. **面板登录账户/密码**
4. **Argo Tunnel Token**（Cloudflare Zero Trust → Access → Tunnels 创建的隧道 Token，`ey` 开头）
5. **访问域名**（如 `komari.example.com`）

## 关键一步：配置隧道 Ingress

启动完成后，到 Cloudflare 隧道面板把域名（或 `*.域名`）的 **HTTP Service** 指向：

```
http://komari:25774
```

保存后约 30 秒即可访问 `https://你的域名`。

## 安装 Agent（监控客户端）

```bash
docker run -d --name komari-agent --restart unless-stopped \
  ghcr.io/komari-monitor/komari-agent:latest \
  -e http://你的域名/ -t <面板里生成的节点Token>
```

## 备份说明

- 备份内容：`data/` 目录快照（`komari_data_<时间戳>.tar.gz`），打包后推送到你的私有仓库 `komari-backup` 的分支 `komari-backup`
- 自动清理 7 天前的旧备份
- 手动立即备份：`bash backup.sh backup`
- 修改备份参数：菜单选「4 重新配置备份参数」

## 管理命令

| 操作 | 命令 |
|---|---|
| 查看日志 | `docker logs -f komari` |
| 重启 | `docker compose -f ~/komari-oneclick/compose.yml restart` |
| 停止 | `docker compose -f ~/komari-oneclick/compose.yml stop` |
| 卸载 | 脚本菜单选「5 卸载」（保留数据，可选再删 `~/komari-oneclick`） |

## 注意事项

- 国内网络拉取 `ghcr.io` 镜像若慢/失败，请先配置 Docker 镜像加速后重试
- 面板与 Agent 之间走你域名 25774，需域名能连通 Cloudflare Tunnel 回源
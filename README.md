# wsm - Web Server Manager

纯命令行的 Web 服务器管理脚本 (类似宝塔面板的功能, 但没有面板进程, 不占资源, 全程 SSH 交互菜单)。

Nginx + 多版本 PHP + MariaDB + Let's Encrypt, 站点 / 证书 / 备份 / 防篡改 / 软件商店 一个脚本搞定。

## 一键安装

用 root 登录服务器后执行:

```bash
curl -fsSL https://raw.githubusercontent.com/chentiti888/web/main/wsm.sh -o wsm.sh && bash wsm.sh install
```

装完会自动变成 `wsm` 命令, 以后直接输入:

```bash
wsm
```

## 更新脚本

仓库里更新后, 在服务器上:

```bash
wsm update
```

或者进入菜单: `wsm` → `10) 更新脚本` → `检查并更新`。更新前会自动备份旧版, 不满意可以在同一个菜单里回滚。

> GitHub 的 raw 文件有最长约 5 分钟缓存, 刚推送完请稍等几分钟再更新。

## 常用命令

```bash
wsm                          # 交互菜单 (推荐)
wsm install                  # 安装 Nginx / PHP / MariaDB / certbot 环境
wsm add-php [域名]            # 新建 PHP 站点
wsm add-static [域名]         # 新建静态站点
wsm add-wp [域名]             # 一键部署 WordPress
wsm add-proxy [域名] [后端]    # 新建反向代理
wsm add-redirect [域名] [目标] # 新建域名重定向
wsm ssl [域名]                # 申请 / 更换证书
wsm list                     # 站点列表
wsm certs                    # 证书总览
wsm renew                    # 立即续期全部证书
wsm backup-site [域名]        # 备份网站
wsm backup-db [库名|--all]    # 备份数据库
wsm tamper-lock [域名]        # 防篡改: 锁定网站文件
wsm tamper-unlock [域名]      # 防篡改: 解锁
wsm stats [域名]              # 访问统计
wsm sftp                     # SFTP 账号管理
wsm store                    # 软件商店
wsm update                   # 在线更新脚本
wsm help                     # 全部命令
```

## 功能

- **网站**: PHP / 静态 / 反向代理 / 域名重定向, 多域名绑定, 伪静态, 子路径反代, 访问密码, 防盗链, IP 黑白名单, Gzip, 静态缓存, 停用 / 启用
- **证书**: Let's Encrypt (HTTP) / 通配符 (Cloudflare DNS) / 自有证书 / 自签名, 自动续期
- **PHP**: 7.4 - 8.4 多版本共存, 扩展, 参数, 禁用函数, FPM 进程数调优
- **数据库**: MariaDB, phpMyAdmin, 创建 / 改密码 / 备份 / 还原
- **防篡改**: 文件锁定 (chattr +i), 可写目录禁止执行 PHP, 完整性基线检测和自动还原
- **WordPress**: 一键部署 (自动建库, 生成配置和密钥, 配好伪静态)
- **SFTP**: 给单个网站开隔离账号, 只能看到自己的网站目录
- **访问统计**: PV / 独立 IP / 流量 / 状态码 / 爬虫 / TOP 页面 / 每小时分布
- **文件工具**: 大文件排查, 解压, 打包, 批量替换, 在线编辑, 可疑代码扫描
- **备份**: 网站和数据库备份 / 还原, 计划任务
- **软件商店**: Node.js, PM2, Python, Java, Docker, PostgreSQL, Redis, Memcached, Fail2ban 等

## 系统要求

- Debian 10+ / Ubuntu 20.04+ (推荐)
- RHEL 系 (Rocky / Alma / CentOS) 尽力支持
- 需要 root 权限

## 注意事项

- 防火墙需要自行放行 80 / 443 端口 (脚本检测到 ufw / firewalld 会自动放行)
- 防篡改依赖 `chattr`, 需要 ext4 / xfs / btrfs 文件系统
- 更新网站文件前, 先在 `网站防篡改` 里临时解锁, 改完再锁定

# wsm - Server Manager

纯命令行的服务器管理脚本：**服务器工具箱 + 命令行版"宝塔"**。没有面板进程，不占资源，全程 SSH 交互菜单。

- **启动不装任何软件**：第一次运行只装 `wsm` 命令本身，什么环境都不装。纯工具机、代理机、中转机也能放心用
- **用到才装**：网站环境、测试工具、端口转发组件等，都是在菜单里选了才安装
- **装过的都能卸载**：wsm 装过的软件都有记录，可以在 [已安装组件] 里统一卸载；网站环境和 wsm 本身也能完整卸载

## 安装

用 root 登录服务器后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/chentiti888/web/main/wsm.sh -o wsm.sh && bash wsm.sh
```

装完会变成 `wsm` 命令（`ssb` 也可以），以后直接输入：

```bash
wsm
```

需要建网站时，在菜单里选 `7) 安装网站环境`，或执行：

```bash
wsm install      # 一键安装 Nginx + PHP + MariaDB + certbot (会先确认)
```

## 菜单

```
  服务器 ─────────────────────────────
    1  系统信息       配置 / 负载 / IP / 虚拟化
    2  SSH 安全       端口 / 密钥 / 密码登录
    3  网络设置       BBR / 禁 Ping / 端口转发
    4  网络检测       网速 / 回程线路 / 解锁检测
    5  性能测试       CPU / 内存 / 硬盘 IO
    6  系统维护       服务 / Swap / 时区 / 告警 / 组件

  网站与应用 ─────────────────────────
    7  安装网站环境   (装好后变成 网站面板)
    8  程序下载       3x-ui / 哪吒 / WordPress …
    9  TG机器人       添加 / 管理 Telegram 机器人
  ────────────────────────────────────
   10  更新 / 卸载        0  退出
```

所有输入框都可以输入 `0` 返回上一级。

## 功能

### 服务器工具（不需要网站环境）

- **系统信息**：系统 / 内核 / 虚拟化 / CPU / 内存 / 硬盘 / 运行时间 / 公网 IPv4 和 IPv6
- **SSH 安全**：生成密钥、导入公钥（从 GitHub 仓库拉取或粘贴）、下载私钥（屏幕显示 / 临时链接 / scp）、关闭或恢复密码登录、修改 SSH 端口；每次修改都先检测配置，不通过自动恢复
- **网络设置**：BBR 加速、禁 Ping、TCP / UDP 端口转发（重启后自动恢复）
- **网络检测**：网速测试（最近机房的延迟 / 下载 / 上传，东京 / 新加坡 / 美西 / 法兰克福 / 伦敦 多节点下载，只用 curl，不跑第三方测速脚本）、回程线路（北京 / 上海 / 广州 / 成都 的电信 / 联通 / 移动）、流媒体和 AI 解锁（Netflix / Disney+ / YouTube / Prime Video / ChatGPT / Claude / Gemini）
- **性能测试**：CPU 占用（各核 / 最耗 CPU 的程序）、CPU 单核 / 多核、内存读写、硬盘 IO
- **系统维护**：服务管理、Swap、服务器时区、Telegram 告警、已安装组件（查看 / 卸载 wsm 装过的软件）

### 网站面板（安装网站环境后）

- **网站**：PHP / 静态 / 反向代理 / 域名重定向，多域名绑定，伪静态，子路径反代，访问密码，防盗链，IP 黑白名单，Gzip，静态缓存，停用 / 启用
- **证书**：Let's Encrypt (HTTP) / 通配符 (Cloudflare DNS) / 自有证书 / 自签名，自动续期
- **PHP**：7.4 - 8.4 多版本共存，扩展，参数，禁用函数，FPM 进程数调优
- **数据库**：MariaDB，phpMyAdmin，创建 / 改密码 / 备份 / 还原
- **备份与搬家**：网站 / 数据库备份还原，计划任务，全量备份，一键搬家，异地备份（Cloudflare R2 / Backblaze B2 / 谷歌网盘 / 其他服务器）
- **安全防护**：源站保护（80/443 只允许 CDN），CDN 真实 IP，防 CC / 恶意 bot，禁止 IP 直接访问，网站防篡改（文件锁定 + 可写目录禁 PHP + 完整性检测 / 自动还原）
- **访问统计**：PV / 独立 IP / 流量 / 真人 / 爬虫 / 可疑 IP / TOP 页面
- **Nginx 维护**：检测重载配置，错误日志，清理日志
- **卸载网站环境**：完整卸载 Nginx / certbot / PHP，MariaDB、数据库文件、网站文件分别确认

### 程序下载

- **扩展程序**（模块，可随时添加删除）：Xboard / WordPress / Typecho / Nextcloud / 哪吒监控 / Uptime Kuma / OpenList / 3x-ui，部署时自动检测最新版本
- **网站环境 / 开发运行 / 系统工具**：MariaDB, Redis, Composer, phpMyAdmin, PostgreSQL, Memcached, Node.js, PM2, Python3, Java, Git, Supervisor, Docker, Rclone, FFmpeg, ImageMagick, 监控工具包

### TG机器人

打开独立的 Telegram 机器人管理工具 [tggl](https://github.com/chentiti888/tggl)：从仓库拉取机器人 → 装依赖 → 写入 Token / ID → 启动并开机自启。两边互不依赖，也可以直接输入 `tgbot` 打开。

## 常用命令

```bash
wsm                          # 交互菜单 (推荐)
wsm help                     # 全部命令

# 服务器工具
wsm sysinfo                  # 系统信息
wsm ssh                      # SSH 安全
wsm keys                     # 导入公钥
wsm bbr                      # BBR 开关
wsm noping                   # 禁 Ping 开关
wsm fwd                      # 端口转发
wsm speedtest                # 网速测试
wsm route                    # 回程线路检测
wsm unlock                   # 流媒体 / AI 解锁检测
wsm bench                    # 性能测试
wsm components               # 已安装组件
wsm tgbot                    # TG机器人管理

# 网站
wsm install                  # 一键安装网站环境
wsm web                      # 网站面板
wsm add-php [域名]            # 新建 PHP 站点
wsm add-static [域名]         # 新建静态站点
wsm add-proxy [域名] [后端]    # 新建反向代理
wsm add-redirect [域名] [目标] # 新建域名重定向
wsm app wordpress install    # 部署 WordPress (其他模块同理)
wsm ssl [域名]                # 申请 / 更换证书
wsm list                     # 站点列表
wsm certs                    # 证书总览
wsm stats [域名]              # 访问统计
wsm backup-all               # 全量备份
wsm restore-all [文件]        # 从全量备份还原 / 搬家到本机

# 更新 / 卸载
wsm update                   # 在线更新脚本
wsm rollback                 # 回滚到上一个版本
wsm web-uninstall            # 卸载网站环境
wsm uninstall                # 卸载 wsm
```

## 更新

```bash
wsm update
```

或者进入菜单：`wsm` → `10) 更新 / 卸载` → `检查并更新`。更新前会自动备份旧版，不满意可以在同一个菜单里回滚。

> GitHub 的 raw 文件有最长约 5 分钟缓存，刚推送完请稍等几分钟再更新。

## 卸载

- **只卸载网站环境**：`网站面板 → 卸载网站环境`（或 `wsm web-uninstall`）。服务器工具的设置不受影响
- **卸载 wsm**：`10) 更新 / 卸载 → 卸载 wsm`（或 `wsm uninstall`）。SSH 端口、密钥登录等设置默认保留（自动改回去可能导致连不上服务器），会单独询问是否还原
- **wsm 装过的单个软件**：`6) 系统维护 → 已安装组件`

## 从旧版本升级

- 原来的 SSH 小工具（`ssb` / `sshm` / `chen`）已经合并进 wsm，升级后会自动清理旧命令，`ssb` 保留为 wsm 的别名
- 原 SSH 小工具保存的公钥地址、生成的私钥会自动迁移，可以在 SSH 安全里继续使用

## 系统要求

- Debian 10+ / Ubuntu 20.04+（推荐）
- RHEL 系（Rocky / Alma / CentOS）尽力支持
- 需要 root 权限

## 注意事项

- 云服务器需要在安全组放行 80 / 443 端口（脚本检测到 ufw / firewalld 会自动放行）
- 修改 SSH 端口、关闭密码登录后，**不要关闭当前窗口**，先新开窗口测试能登录
- 防篡改依赖 `chattr`，需要 ext4 / xfs / btrfs 文件系统；更新网站文件前先在 `网站防篡改` 里临时解锁，改完再锁定
- 回程线路、解锁检测的结果是按特征推测的，仅供参考

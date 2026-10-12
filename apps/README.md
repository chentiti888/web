# wsm 扩展程序模块

wsm 本体只管服务器环境：Nginx / PHP / 数据库 / 证书 / 防护 / 备份这些通用功能。
第三方程序（Xboard、WordPress、3x-ui ……）都是这个目录里的一个独立模块，
在 wsm 的 **程序下载 → 扩展程序 → a) 添加模块** 里随时添加，**d) 删除模块** 随时删除。

模块分两类：

| 类型 | APP_TYPE | 说明 | 例子 |
|---|---|---|---|
| 网站程序 | `site`（默认） | 部署成「网站管理」里的站点：PHP 程序直接跑在 Nginx+PHP 上，独立程序跑在本机端口、wsm 建反代站点 | xboard、wordpress、typecho、nextcloud、nezha、uptimekuma、openlist |
| 独立软件 | `soft` | 自带服务和端口，不建站点，装一份 | xui (3x-ui) |

## 现有模块

| ID | 程序 | 运行方式 | 版本来源 |
|---|---|---|---|
| xboard | Xboard 面板 | PHP + 队列 | 自己仓库的最新提交 |
| wordpress | WordPress | PHP | api.wordpress.org |
| typecho | Typecho | PHP | GitHub Releases |
| nextcloud | Nextcloud | PHP + 定时任务 | GitHub Releases |
| nezha | 哪吒监控 | Go 二进制 :8008 + 反代(含 gRPC) | GitHub Releases |
| uptimekuma | Uptime Kuma | Node.js :3001 + 反代 | GitHub Releases |
| openlist | OpenList | Go 二进制 :5244 + 反代 | GitHub Releases |
| xui | 3x-ui | 官方脚本 | GitHub Releases |

## 新增一个模块

1. 在本目录新建 `<id>.sh`（id 只能用小写字母、数字、下划线，字母开头）
2. 在 `index.txt` 加一行：`<id>|名称 - 一句话简介`
3. 推到仓库后，服务器上 `wsm app add <id>` 或在菜单里添加

## 网站程序模块 (site)

```bash
# shellcheck shell=bash disable=SC2034
APP_ID=myapp                 # 必须和文件名一致
APP_NAME="我的程序"
APP_DESC="一句话简介"
APP_VER=1.0

# 必须: 部署一个新站点。可直接用 wsm 的函数: add_site / load_meta / apply_site /
#       install_db / install_redis / install_composer / php_bin / ask / choose / confirm ...
# 部署成功后一定要调用 app_mark_site 域名 myapp, 站点才会归到这个模块下
app_myapp_install() { ...; app_mark_site "$domain" myapp; }

# 以下都是可选
app_myapp_menu()         { :; }  # $1=站点, 模块自己的管理菜单 (更新/后台/重置密码...)
app_myapp_detect()       { :; }  # 已 load_meta, 返回 0 表示这个老站点是本程序 (自动认领)
app_myapp_guard_skip()   { :; }  # 输出防 CC 不限速的 nginx map 行, 如:  "~^/api/node/"  1;
app_myapp_guard_on()     { :; }  # $1=站点, 站点开启防 CC 时调用
app_myapp_units()        { :; }  # $1=站点, 输出该站点的后台 systemd 服务 (监控/服务管理/搬家会用)
app_myapp_backup_paths() { :; }  # 输出全量备份要额外带上的文件 (/etc/wsm 和网站目录本来就会备份)
app_myapp_purge()        { :; }  # $1=站点 $2=根目录, 删除站点时停掉并移除服务/计划任务 (不要交互)
app_myapp_files()        { :; }  # $1=站点 $2=根目录, 输出程序文件路径 (默认就是网站根目录), 卸载时直接删除
app_myapp_data()         { :; }  # $1=站点 $2=根目录, 输出用户数据路径, 删除前单独确认
app_myapp_dbinfo()       { :; }  # $1=站点 $2=根目录, 输出 "库名 账号", 删除前单独确认
app_myapp_cleanup()      { :; }  # $1=站点, 全部删完后收尾 (如删空目录、系统用户)
app_myapp_cli()          { :; }  # wsm app myapp 参数...
```

## wsm 提供给模块的常用函数

| 函数 | 作用 |
|---|---|
| `ver_pick 名称 owner/repo` | 部署时查最新版本并让用户确认 → `PICK_VER` |
| `app_check_update 名称 owner/repo 当前版本` | 菜单里检查更新, 有新版返回 0 → `PICK_VER` |
| `gh_asset_url owner/repo 版本 文件名` | GitHub Release 下载地址 (版本空 = latest) |
| `app_new_domain 变量 提示` | 输入新站点域名并检查可用 |
| `app_need_db 名称` / `app_db_new 前缀 域名` | 确保有数据库 / 建库建用户 → `ADB_NAME ADB_USER ADB_PASS` |
| `php_pick_min 最低版本 名称` / `php_exts_ensure 版本 扩展...` | 选 PHP 版本 / 装扩展 |
| `app_site_conf 域名 < 规则` | 写站点专用 Nginx 规则 (`__PHP_SOCK__` 自动替换), 配合 `REWRITE=app` |
| `app_proxy_site 域名 端口` | 建反代站点 |
| `app_systemd 服务名 说明 目录 命令 [用户] [环境变量...]` | 写 systemd 服务并启动 |
| `app_port_free 端口` / `app_wait_port 端口 秒` | 端口检查 / 等程序启动 |

卸载：模块菜单里加一项调用 `app_site_uninstall 站点` 即可，wsm 会按上面几个钩子列出要删的东西、确认后统一清理。

模块需要保存的数据放在 `$APPS_DATA/<id>/`（即 /etc/wsm/appdata/<id>/，会随全量备份一起备份）。

## 独立软件模块 (soft)

```bash
# shellcheck shell=bash disable=SC2034
APP_ID=mysoft
APP_TYPE=soft
APP_NAME="我的软件"
APP_DESC="一句话简介"
APP_VER=1.0

app_mysoft_install()   { :; }   # 必须: 安装
app_mysoft_installed() { :; }   # 建议: 返回 0 表示已安装 (菜单显示 已装/未装)
app_mysoft_detect()    { app_mysoft_installed; }  # 可选: 老服务器升级时据此自动添加模块
app_mysoft_version()   { :; }   # 可选: 输出版本
app_mysoft_uninstall() { :; }   # 可选: 卸载
app_mysoft_menu()      { :; }   # 可选: 已安装后的管理菜单
app_mysoft_units()     { :; }   # 可选: 输出 systemd 服务名 (监控/服务管理会带上)
```


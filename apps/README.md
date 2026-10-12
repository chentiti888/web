# wsm 网站应用模块

wsm 本体只管 Nginx / PHP / 数据库 / 证书 / 防护 / 备份这些通用功能，
具体的网站程序（Xboard、WordPress ……）都是这个目录里的一个独立模块，
在 wsm 的 **程序下载 → 网站应用 → a) 添加模块** 里随时添加，**d) 删除模块** 随时删除。

## 新增一个模块

1. 在本目录新建 `<id>.sh`（id 只能用小写字母、数字、下划线，字母开头）
2. 在 `index.txt` 加一行：`<id>|名称 - 一句话简介`
3. 推到仓库后，服务器上 `wsm app add <id>` 或在菜单里添加

## 模块文件格式

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
app_myapp_purge()        { :; }  # $1=站点 $2=根目录, 删除站点时清理服务/计划任务
app_myapp_cli()          { :; }  # wsm app myapp 参数...
```

模块需要保存的数据放在 `$APPS_DATA/<id>/`（即 /etc/wsm/appdata/<id>/，会随全量备份一起备份）。

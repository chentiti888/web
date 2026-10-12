# shellcheck shell=bash disable=SC2034
# wsm 程序模块: Typecho 轻量博客 (github.com/typecho/typecho)
# 本文件由 wsm 载入使用 (程序下载 → 扩展程序 → 添加模块), 不能单独运行。
APP_ID=typecho
APP_NAME="Typecho"
APP_DESC="轻量博客, 国内常用, 自动下载最新版+建库"
APP_VER=1.2

TC_REPO=typecho/typecho

tc_version() {  # tc_version 网站目录 : 读取已装版本
  sed -n "s/.*const VERSION *= *'\([^']*\)'.*/\1/p" "$1/var/Typecho/Common.php" 2>/dev/null | head -1
}

tc_fetch() {  # tc_fetch 版本(可空) 临时目录 -> 解压后的程序目录放在 TC_SRC
  local url d
  url=$(gh_asset_url "$TC_REPO" "$1" typecho.zip)
  TC_SRC=""
  command -v unzip >/dev/null 2>&1 || pkg_install unzip >/dev/null 2>&1 || { err "unzip 安装失败"; return 1; }
  info "下载 Typecho ${1:-最新版} ..."
  curl -fL --max-time 300 -o "$2/tc.zip" "$url" || { err "下载失败: $url"; return 1; }
  mkdir -p "$2/x"
  unzip -q "$2/tc.zip" -d "$2/x" || { err "解压失败"; return 1; }
  for d in "$2/x" "$2"/x/*/; do
    [[ -f $d/index.php && -d $d/var ]] && { TC_SRC=${d%/}; return 0; }
  done
  err "安装包结构不认识"; return 1
}

tc_site_conf() {  # Typecho 需要 PATH_INFO (后台 /index.php/action/... 这类地址)
  app_site_conf "$1" <<'EOF'
    location / { try_files $uri $uri/ /index.php$is_args$args; }
    location ~* ^/usr/uploads/.*\.(php|phtml|phar)$ { deny all; }
    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_pass __PHP_SOCK__;
        fastcgi_read_timeout 300;
    }
EOF
}

app_typecho_install() {
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} root tmp scheme
  title "一键部署 Typecho"
  app_need_db Typecho || return 1
  app_new_domain domain "① 网站域名 (如 blog.example.com)" || return 1
  root=$WWW_ROOT/$domain
  safe_root "$root" || die "网站目录不合法: $root"
  [[ -d $root && -n $(ls -A "$root" 2>/dev/null) ]] && die "目录 $root 里已有文件, 请换一个域名或先清空该目录"
  php_pick_min 7.4 Typecho || return 1
  ver_pick Typecho "$TC_REPO" || return 1

  tmp=$(mktemp -d)
  tc_fetch "$PICK_VER" "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$root"
  cp -a "$TC_SRC/." "$root/"
  rm -rf "$tmp"
  app_db_new tc "$domain" || { rm -rf "$root"; die "创建数据库失败"; }
  php_exts_ensure "$PICK_PHP" mysql curl mbstring xml gd zip

  PRESET_ROOT=$root PRESET_PHP=$PICK_PHP add_site php "$domain" \
    || { err "站点创建失败, 文件在 $root, 数据库 $ADB_NAME 已创建"; return 1; }
  load_meta "$domain"
  REWRITE=app
  tc_site_conf "$domain"
  apply_site >/dev/null
  app_mark_site "$domain" typecho
  fix_perms_dir "$root"
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  echo
  info "Typecho $(tc_version "$root") 已部署, 最后一步: 打开 $scheme://$domain/install.php 完成安装向导"
  echo "  向导里填写数据库 (请记下):"
  echo "    数据库地址: localhost     端口: 3306"
  echo "    数据库名:   $ADB_NAME"
  echo "    用户名:     $ADB_USER"
  echo "    密码:       $ADB_PASS"
  echo "  然后设置网站地址、管理员账号和密码即可"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS: 建议先在 [SSL 证书] 里开启, 再打开向导"
  return 0
}

app_typecho_dbinfo() {  # 库名 账号 (安装向导生成的 config.inc.php)
  local f=$2/config.inc.php
  [[ -f $f ]] || return 0
  echo "$(sed -n "s/.*'database' *=> *'\([^']*\)'.*/\1/p" "$f" | head -1) $(sed -n "s/.*'user' *=> *'\([^']*\)'.*/\1/p" "$f" | head -1)"
}

app_typecho_detect() { [[ -f $ROOT/var/Typecho/Common.php && -d $ROOT/admin ]]; }

app_typecho_menu() {  # app_typecho_menu 站点
  local d=$1 c root cur tmp scheme
  while true; do
    root=$( load_meta "$d"; echo "$ROOT" ); cur=$(tc_version "$root")
    scheme=$( load_meta "$d"; [[ $SSL == 1 ]] && echo https || echo http )
    title "Typecho · $d"
    echo "  后台地址: $scheme://$d/admin/"
    echo "  网站目录: $root"
    echo "  程序版本: ${cur:-未知}"
    choose c "操作:" "检查更新" "卸载 (删除站点和程序)" "返回" || return 0
    case $c in
      检查更新)
        if app_check_update Typecho "$TC_REPO" "$cur" && confirm "升级到 $PICK_VER ? (文章、主题、插件、上传文件不受影响)" y; then
          tmp=$(mktemp -d)
          if tc_fetch "$PICK_VER" "$tmp"; then
            rm -rf "${root:?}/admin" "${root:?}/var" "${root:?}/install"
            cp -a "$TC_SRC/admin" "$TC_SRC/var" "$root/"
            [[ -d $TC_SRC/install ]] && cp -a "$TC_SRC/install" "$root/"
            cp -f "$TC_SRC"/*.php "$root/"
            fix_perms_dir "$root"
            info "已升级到 $(tc_version "$root"), 登录后台如果提示升级数据库, 点一下确认即可"
          fi
          rm -rf "$tmp"
        fi
        pause ;;
      卸载*) (app_site_uninstall "$d"); pause; [[ -f $(meta_file "$d") ]] || return 0 ;;
      *) return 0 ;;
    esac
  done
}

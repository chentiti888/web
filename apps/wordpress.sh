# shellcheck shell=bash disable=SC2034
# wsm 程序模块: WordPress
# 本文件由 wsm 载入使用 (程序下载 → 扩展程序 → 添加模块), 不能单独运行。
APP_ID=wordpress
APP_NAME="WordPress"
APP_DESC="博客 / 企业站, 自动下载+建库+写好配置"
APP_VER=1.2

wp_latest() {  # 官方接口查最新版本号
  curl -fsSL --max-time 15 https://api.wordpress.org/core/version-check/1.7/ 2>/dev/null \
    | grep -o '"current":"[^"]*"' | head -1 | cut -d'"' -f4
}
wp_version() { sed -n "s/^\$wp_version = '\(.*\)';/\1/p" "$1/wp-includes/version.php" 2>/dev/null | head -1; }

wp_php_exts() {  # wp_php_exts PHP版本  (尽力补齐 WordPress 常用扩展)
  local v=$1 pv e
  pv=$(php_pkgver "$v")
  for e in mysql curl gd mbstring xml zip intl; do
    if [[ $PM == apt ]]; then pkg_install "php$v-$e" >/dev/null 2>&1 || true
    else
      case $e in mysql) e=mysqlnd ;; esac
      pkg_install "php${pv}-php-$e" >/dev/null 2>&1 || pkg_install "php${pv}-php-pecl-$e" >/dev/null 2>&1 || true
    fi
  done
  systemctl restart "$(php_svc "$v")" >/dev/null 2>&1 || true
}

wp_install() {  # wp_install [域名]
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} root lang url tmp dbn dbu dbp pre k v scheme
  title "一键部署 WordPress"
  if ! command -v mysql >/dev/null 2>&1; then
    confirm "WordPress 需要数据库, 现在安装 MariaDB 吗?" y || return 1
    install_db || return 1
  fi
  ask domain "① 网站域名 (如 blog.example.com)" || return 1
  valid_domain "$domain" || die "域名格式不正确: $domain"
  [[ -f $(meta_file "$domain") ]] && die "站点已存在: $domain"
  v=$(domain_used "$domain") && die "域名 $domain 已被站点 $v 使用"
  root=$WWW_ROOT/$domain
  safe_root "$root" || die "网站目录不合法: $root"
  if [[ -d $root && -n $(ls -A "$root" 2>/dev/null) ]]; then
    die "目录 $root 里已有文件, 请换一个域名或先清空该目录"
  fi
  info "检查 WordPress 最新版本 ..."
  v=$(wp_latest)
  if [[ -n $v ]]; then echo "  最新版本: ${G}$v${N} (下面会下载最新版)"; else warn "没能检测到版本号, 照常下载最新版"; fi
  choose lang "WordPress 语言:" "简体中文" "English" || return 1
  if [[ $lang == 简体* ]]; then url=https://cn.wordpress.org/latest-zh_CN.tar.gz
  else url=https://wordpress.org/latest.tar.gz; fi

  tmp=$(mktemp -d)
  info "下载 WordPress ..."
  curl -fL --max-time 300 -o "$tmp/wp.tgz" "$url" || { rm -rf "$tmp"; die "下载失败, 请检查服务器网络"; }
  mkdir -p "$root"
  tar -xzf "$tmp/wp.tgz" -C "$root" --strip-components=1 || { rm -rf "$tmp" "$root"; die "解压失败"; }
  rm -rf "$tmp"
  [[ -f $root/wp-config-sample.php ]] || { rm -rf "$root"; die "安装包不完整"; }

  k=$(printf '%s' "$domain" | tr -c 'A-Za-z0-9' '_' | cut -c1-12)
  dbn="wp_${k}_$(openssl rand -hex 2)"; dbu=$dbn
  dbp=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  mysql -e "CREATE DATABASE \`$dbn\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
CREATE USER '$dbu'@'localhost' IDENTIFIED BY '$dbp'; \
GRANT ALL PRIVILEGES ON \`$dbn\`.* TO '$dbu'@'localhost'; FLUSH PRIVILEGES;" \
    || { rm -rf "$root"; die "创建数据库失败"; }

  cp "$root/wp-config-sample.php" "$root/wp-config.php"
  sed -i -e "s/database_name_here/$dbn/" -e "s/username_here/$dbu/" -e "s/password_here/$dbp/" "$root/wp-config.php"
  for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    v=$(openssl rand -base64 72 | tr -dc 'A-Za-z0-9' | head -c 64)
    sed -i "s/^define( *'$k'.*/define( '$k', '$v' );/" "$root/wp-config.php"
  done
  pre="wp$(openssl rand -hex 2)_"
  sed -i "s/^\$table_prefix = .*/\$table_prefix = '$pre';/" "$root/wp-config.php"
  sed -i -e "/stop editing/i define( 'FS_METHOD', 'direct' );" \
         -e "/stop editing/i define( 'DISALLOW_FILE_EDIT', true );" "$root/wp-config.php"
  rm -f "$root/readme.html" "$root/license.txt" "$root/wp-config-sample.php"

  echo
  info "WordPress 文件与数据库已准备好 (请记下数据库信息)"
  echo "  数据库: $dbn"
  echo "  用户:   $dbu"
  echo "  密码:   $dbp"
  echo "  (已自动写入 wp-config.php, 安装向导里不需要再填)"
  echo
  PRESET_ROOT=$root add_site php "$domain" || { err "站点创建失败, 文件在 $root, 数据库 $dbn 已创建"; return 1; }
  load_meta "$domain"
  REWRITE=wordpress
  apply_site >/dev/null
  app_mark_site "$domain" wordpress
  wp_php_exts "$PHPVER"
  chmod 640 "$root/wp-config.php" 2>/dev/null   # 里面有数据库密码, 不让其他用户读取
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  echo
  info "全部完成, 最后一步: 用浏览器打开 $scheme://$domain/ 完成安装向导"
  echo "  向导里设置: 站点标题、管理员账号和密码、邮箱"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS: 建议先在 [SSL 证书] 里开启 HTTPS, 再打开向导, 这样 WordPress 会记成 https 地址"
  echo "  提示: 域名需要先解析到本机 IP; 想防篡改请在 [网站防篡改] 里选 WordPress 预设"
  return 0
}

# ---------------------------------------------------------------- 模块接口
app_wordpress_install() { wp_install "${1:-}"; }

app_wordpress_dbinfo() {  # 库名 账号 (从 wp-config.php 读)
  local f=$2/wp-config.php
  [[ -f $f ]] || return 0
  echo "$(sed -n "s/.*define( *['\"]DB_NAME['\"], *['\"]\([^'\"]*\)['\"].*/\1/p" "$f" | head -1) $(sed -n "s/.*define( *['\"]DB_USER['\"], *['\"]\([^'\"]*\)['\"].*/\1/p" "$f" | head -1)"
}

app_wordpress_detect() { [[ -f $ROOT/wp-config.php && -d $ROOT/wp-includes ]]; }

wp_upgrade() {  # wp_upgrade 站点 : 用官方最新包覆盖程序文件 (wp-content 和 wp-config.php 不动)
  local d=$1 root url tmp lang
  root=$( load_meta "$d"; echo "$ROOT" )
  lang=$(sed -n "s/^\$wp_local_package = '\(.*\)';/\1/p" "$root/wp-includes/version.php" 2>/dev/null)
  if [[ $lang == zh_CN ]]; then url=https://cn.wordpress.org/latest-zh_CN.tar.gz
  else url=https://wordpress.org/latest.tar.gz; fi
  tmp=$(mktemp -d)
  info "下载最新版 ..."
  if curl -fL --max-time 300 -o "$tmp/wp.tgz" "$url" && tar -xzf "$tmp/wp.tgz" -C "$tmp" && [[ -f $tmp/wordpress/wp-settings.php ]]; then
    rm -rf "$tmp/wordpress/wp-content" "$tmp/wordpress/wp-config-sample.php" "$tmp/wordpress/readme.html" "$tmp/wordpress/license.txt"
    cp -a "$tmp/wordpress/." "$root/"
    chown -R "$WEB_USER:$WEB_USER" "$root/wp-admin" "$root/wp-includes" "$root"/*.php
    info "程序文件已更新到 $(wp_version "$root"), 打开后台时如果提示升级数据库, 点一下确认即可"
  else
    err "下载或解压失败, 网站没有改动"
  fi
  rm -rf "$tmp"
}

app_wordpress_menu() {  # app_wordpress_menu 站点
  local d=$1 c root cur new scheme
  while true; do
    root=$( load_meta "$d"; echo "$ROOT" )
    scheme=$( load_meta "$d"; [[ $SSL == 1 ]] && echo https || echo http )
    cur=$(wp_version "$root")
    title "WordPress · $d"
    echo "  后台地址: $scheme://$d/wp-admin/"
    echo "  网站目录: $root"
    echo "  程序版本: ${cur:-未知}"
    choose c "操作:" "检查更新" "补齐 PHP 扩展 (插件报缺扩展时用)" "卸载 (删除站点和程序)" "返回" || return 0
    case $c in
      检查更新)
        new=$(wp_latest)
        echo "  当前版本: ${cur:-未知}"
        echo "  最新版本: ${new:-检测失败}"
        if [[ -n $new ]] && ver_newer "$cur" "$new"; then
          echo "  也可以在后台 [仪表盘 → 更新] 里一键升级"
          confirm "现在用命令行升级到 $new ? (文章、主题、插件、上传文件不受影响, 建议先做一次备份)" y && wp_upgrade "$d"
        elif [[ -n $new ]]; then info "已经是最新版"; fi
        pause ;;
      补齐*) ( load_meta "$d"; wp_php_exts "$PHPVER" ); info "已处理"; pause ;;
      卸载*) (app_site_uninstall "$d"); pause; [[ -f $(meta_file "$d") ]] || return 0 ;;
      *) return 0 ;;
    esac
  done
}

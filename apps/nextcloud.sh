# shellcheck shell=bash disable=SC2034
# wsm 程序模块: Nextcloud 私有网盘 (nextcloud.com)
# 本文件由 wsm 载入使用 (程序下载 → 扩展程序 → 添加模块), 不能单独运行。
APP_ID=nextcloud
APP_NAME="Nextcloud"
APP_DESC="私有网盘/同步/在线文档, 自动安装+建库+缓存+定时任务"
APP_VER=1.2

NC_REPO=nextcloud/server
NC_DL=https://download.nextcloud.com/server/releases
NC_DATA_BASE=${WWW_ROOT%/*}/ncdata   # 用户文件放在网站目录外面, 更安全

nc_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_' | cut -c1-30; }
nc_data_dir() { echo "$NC_DATA_BASE/$1"; }

nc_occ() {  # nc_occ 网站目录 PHP版本 参数... (以网站用户运行 occ)
  local root=$1 v=$2; shift 2
  (cd "$root" && runuser -u "$WEB_USER" -- "$(php_bin "$v")" occ --no-interaction "$@")
}

nc_version() {  # nc_version 网站目录 -> 如 32.0.1
  sed -n "s/^\$OC_VersionString *= *'\([^']*\)'.*/\1/p" "$1/version.php" 2>/dev/null | head -1
}

nc_site_conf() {  # 按官方文档精简的 Nginx 规则
  app_site_conf "$1" <<'EOF'
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation { try_files $uri $uri/ =404; }
        return 301 /index.php$request_uri;
    }
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }
    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass __PHP_SOCK__;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_max_temp_file_size 0;
        fastcgi_read_timeout 3600;
    }
    location ~ \.mjs$ { default_type text/javascript; try_files $uri /index.php$request_uri; expires 6M; access_log off; }
    location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)$ { try_files $uri /index.php$request_uri; expires 6M; access_log off; }
    location ~ \.woff2?$ { try_files $uri /index.php$request_uri; expires 7d; access_log off; }
    location /remote { return 301 /remote.php$request_uri; }
    location / { try_files $uri $uri/ /index.php$request_uri; }
EOF
}

nc_fetch() {  # nc_fetch 版本(可空=最新) 临时目录 -> 解压到 临时目录/nextcloud
  local f url
  if [[ -n $1 ]]; then f="nextcloud-${1#v}.tar.bz2"; else f=latest.tar.bz2; fi
  url=$NC_DL/$f
  command -v bzip2 >/dev/null 2>&1 || pkg_install bzip2 >/dev/null 2>&1 || { err "bzip2 安装失败"; return 1; }
  info "下载 Nextcloud ${1:-最新版} (约 250MB, 请耐心等待) ..."
  curl -fL --max-time 1800 -o "$2/nc.tar.bz2" "$url" || { err "下载失败: $url"; return 1; }
  tar -xjf "$2/nc.tar.bz2" -C "$2" || { err "解压失败"; return 1; }
  [[ -f $2/nextcloud/occ ]] || { err "安装包不完整"; return 1; }
}

nc_php_tune() {  # Nextcloud 推荐的 PHP 参数 (内存只调大, 不调小)
  local f m; f=$(php_ini_file "$1")
  m=$(sed -n 's/^memory_limit *= *\([0-9]*\)\([MmGg]\).*/\1\2/p' "$f" 2>/dev/null | tail -1)
  case $m in *[Gg]) m=$(( ${m%?} * 1024 )) ;; *[Mm]) m=${m%?} ;; *) m=0 ;; esac
  ((m >= 512)) || ini_set_kv "$f" memory_limit 512M
  ini_set_kv "$f" opcache.interned_strings_buffer 16
  ini_set_kv "$f" output_buffering 0
  systemctl restart "$(php_svc "$1")" >/dev/null 2>&1 || true
}

app_nextcloud_install() {
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} root data tmp admin pw mem dbv scheme out k x
  title "一键部署 Nextcloud"
  mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  if [[ -n $mem ]] && ((mem < 1800)); then
    warn "本机内存 ${mem}MB, Nextcloud 建议 2GB 以上, 小内存会比较卡"
    confirm "仍然继续?" n || return 1
  fi
  app_need_db Nextcloud || return 1
  dbv=$(mysql -N -e "SELECT VERSION()" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
  if [[ -n $dbv ]] && awk -v v="$dbv" 'BEGIN { exit !(v + 0 < 10.6) }'; then
    warn "当前 MariaDB 是 $dbv, 新版 Nextcloud 要求 10.6 以上 (Debian 11 自带 10.5), 安装可能失败"
    confirm "仍然继续?" n || return 1
  fi
  if ! unit_exists redis-server && ! unit_exists redis; then
    confirm "Nextcloud 用 Redis 做缓存和文件锁会快很多, 现在安装 Redis 吗?" y && install_redis
  fi
  app_new_domain domain "① 网站域名 (如 pan.example.com)" || return 1
  root=$WWW_ROOT/$domain; data=$(nc_data_dir "$domain")
  safe_root "$root" || die "网站目录不合法: $root"
  [[ -d $root && -n $(ls -A "$root" 2>/dev/null) ]] && die "目录 $root 里已有文件, 请换一个域名或先清空该目录"
  [[ -d $data && -n $(ls -A "$data" 2>/dev/null) ]] && die "数据目录 $data 里已有文件, 请先处理"
  read -r -p "② 管理员用户名 [admin]: " admin || return 1
  admin=${admin:-admin}
  [[ $admin =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die "用户名格式不正确"
  php_pick_min 8.2 Nextcloud || return 1
  ver_pick Nextcloud "$NC_REPO" || return 1

  info "安装 PHP 扩展 ..."
  php_exts_ensure "$PICK_PHP" mysql curl gd mbstring xml zip intl bcmath gmp redis imagick apcu
  nc_php_tune "$PICK_PHP"
  tmp=$(mktemp -d)
  nc_fetch "$PICK_VER" "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$root" "$data"
  cp -a "$tmp/nextcloud/." "$root/"
  rm -rf "$tmp"
  chown -R "$WEB_USER:$WEB_USER" "$root" "$data"
  chmod 750 "$data"
  app_db_new nc "$domain" || { rm -rf "$root"; die "创建数据库失败"; }
  pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)

  info "初始化 Nextcloud (需要一两分钟) ..."
  out=$(nc_occ "$root" "$PICK_PHP" maintenance:install --database mysql --database-host 127.0.0.1 \
        --database-name "$ADB_NAME" --database-user "$ADB_USER" --database-pass "$ADB_PASS" \
        --admin-user "$admin" --admin-pass "$pw" --data-dir "$data" 2>&1) || {
    printf '%s\n' "$out" | tail -8
    app_db_drop "$ADB_NAME"; rm -rf "$root" "$data"
    die "初始化失败 (已清理)"
  }

  PRESET_ROOT=$root PRESET_PHP=$PICK_PHP add_site php "$domain" \
    || { err "站点创建失败, 程序在 $root, 管理员 $admin 密码 $pw"; return 1; }
  load_meta "$domain"
  REWRITE=app
  nc_site_conf "$domain"
  apply_site >/dev/null
  app_mark_site "$domain" nextcloud
  scheme=http; [[ $SSL == 1 ]] && scheme=https

  k=0
  for x in $domain $ALIASES; do nc_occ "$root" "$PICK_PHP" config:system:set trusted_domains $k --value="$x" >/dev/null; k=$((k + 1)); done
  nc_occ "$root" "$PICK_PHP" config:system:set overwrite.cli.url --value="$scheme://$domain" >/dev/null
  [[ $SSL == 1 ]] && nc_occ "$root" "$PICK_PHP" config:system:set overwriteprotocol --value=https >/dev/null
  nc_occ "$root" "$PICK_PHP" config:system:set default_phone_region --value=CN >/dev/null
  nc_occ "$root" "$PICK_PHP" config:system:set maintenance_window_start --type=integer --value=1 >/dev/null
  if unit_exists redis-server || unit_exists redis; then
    nc_occ "$root" "$PICK_PHP" config:system:set redis host --value=127.0.0.1 >/dev/null
    nc_occ "$root" "$PICK_PHP" config:system:set redis port --type=integer --value=6379 >/dev/null
    nc_occ "$root" "$PICK_PHP" config:system:set memcache.local --value='\OC\Memcache\Redis' >/dev/null
    nc_occ "$root" "$PICK_PHP" config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null
  fi
  printf '*/5 * * * * %s %s -f %s/cron.php >/dev/null 2>&1\n' "$WEB_USER" "$(command -v "$(php_bin "$PICK_PHP")")" "$root" \
    > "/etc/cron.d/nextcloud-$(nc_slug "$domain")"
  chmod 644 "/etc/cron.d/nextcloud-$(nc_slug "$domain")"
  nc_occ "$root" "$PICK_PHP" background:cron >/dev/null
  nc_occ "$root" "$PICK_PHP" db:add-missing-indices >/dev/null 2>&1

  echo
  info "Nextcloud $(nc_version "$root") 部署完成 (请截图或记下下面的信息)"
  echo "  访问地址: $scheme://$domain/"
  echo "  管理员:   $admin"
  echo "  密码:     $pw"
  echo "  数据目录: $data  (用户上传的文件都在这里)"
  echo "  数据库:   $ADB_NAME  密码 $ADB_PASS (已写入配置)"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS, 网盘强烈建议开启: [SSL 证书] 开启后, 到本模块菜单里点 [修复配置]"
  echo "  提示: 网页上传单个文件超过 100MB 会自动分块, 不受影响"
  return 0
}

app_nextcloud_detect() { [[ -f $ROOT/occ && -f $ROOT/version.php && -d $ROOT/apps/files ]]; }

app_nextcloud_backup_paths() {
  local d
  while read -r d; do
    [[ -n $d ]] || continue
    [[ -d $(nc_data_dir "$d") ]] && nc_data_dir "$d"
    [[ -f /etc/cron.d/nextcloud-$(nc_slug "$d") ]] && echo "/etc/cron.d/nextcloud-$(nc_slug "$d")"
  done < <(app_sites nextcloud)
  return 0
}

app_nextcloud_purge() {  # app_nextcloud_purge 域名 根目录 : 停掉定时任务
  rm -f "/etc/cron.d/nextcloud-$(nc_slug "$1")"
  echo "   已移除 Nextcloud 定时任务"
}
app_nextcloud_data() { nc_data_dir "$1"; }
app_nextcloud_dbinfo() {  # 库名 账号
  local f=$2/config/config.php
  [[ -f $f ]] || return 0
  echo "$(sed -n "s/.*'dbname' *=> *'\([^']*\)'.*/\1/p" "$f" | head -1) $(sed -n "s/.*'dbuser' *=> *'\([^']*\)'.*/\1/p" "$f" | head -1)"
}

app_nextcloud_menu() {  # app_nextcloud_menu 站点
  local d=$1 c root v cur scheme pw u
  while true; do
    root=$( load_meta "$d"; echo "$ROOT" ); v=$( load_meta "$d"; echo "$PHPVER" )
    scheme=$( load_meta "$d"; [[ $SSL == 1 ]] && echo https || echo http )
    cur=$(nc_version "$root")
    title "Nextcloud · $d"
    echo "  访问地址: $scheme://$d/"
    echo "  程序版本: ${cur:-未知}   PHP: $v"
    echo "  数据目录: $(nc_data_dir "$d")"
    choose c "操作:" "检查更新" "重置用户密码" "修复配置 (改了域名/开了HTTPS后用)" \
      "重新扫描文件" "查看状态" "卸载 (删除站点和程序)" "返回" || return 0
    case $c in
      检查更新)
        if app_check_update Nextcloud "$NC_REPO" "$cur" && confirm "升级到 $PICK_VER ? (升级期间网盘暂停访问)" y; then
          warn "Nextcloud 只能逐个大版本升级, 跨多个大版本时需要多升几次"
          info "运行官方升级程序 ..."
          (cd "$root" && runuser -u "$WEB_USER" -- "$(php_bin "$v")" updater/updater.phar --no-interaction) \
            || warn "升级没有完成, 请看上面的信息"
          nc_occ "$root" "$v" db:add-missing-indices >/dev/null 2>&1
          info "当前版本: $(nc_version "$root")"
        fi
        pause ;;
      重置*)
        read -r -p "用户名 [admin]: " u || continue
        u=${u:-admin}
        pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
        if (cd "$root" && runuser -u "$WEB_USER" -- env OC_PASS="$pw" "$(php_bin "$v")" occ user:resetpassword --password-from-env "$u"); then
          info "已重置, 新密码: $pw"
        fi
        pause ;;
      修复*)
        ( load_meta "$d"; k=0
          for x in $DOMAIN $ALIASES; do nc_occ "$ROOT" "$PHPVER" config:system:set trusted_domains $k --value="$x" >/dev/null; k=$((k + 1)); done
          if [[ $SSL == 1 ]]; then
            nc_occ "$ROOT" "$PHPVER" config:system:set overwriteprotocol --value=https >/dev/null
            nc_occ "$ROOT" "$PHPVER" config:system:set overwrite.cli.url --value="https://$DOMAIN" >/dev/null
          fi
          nc_occ "$ROOT" "$PHPVER" maintenance:repair >/dev/null 2>&1
          nc_occ "$ROOT" "$PHPVER" db:add-missing-indices >/dev/null 2>&1 )
        info "已按当前域名和 HTTPS 状态修复"; pause ;;
      重新扫描*) nc_occ "$root" "$v" files:scan --all; pause ;;
      查看状态) nc_occ "$root" "$v" status; pause ;;
      卸载*) (app_site_uninstall "$d"); pause; [[ -f $(meta_file "$d") ]] || return 0 ;;
      *) return 0 ;;
    esac
  done
}

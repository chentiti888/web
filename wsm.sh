#!/usr/bin/env bash
# =====================================================================
#  wsm.sh v2  -  Web Server Manager (命令行版"宝塔")
#
#  网站: PHP / 静态 / 反向代理 / 域名重定向, 多域名绑定, 伪静态, 子路径反代,
#        访问密码, 防盗链, IP 黑白名单, Gzip, 静态缓存, 停用/启用, 日志分析,
#        防篡改(文件锁定 + 可写目录禁PHP + 完整性基线检测/自动还原)
#        WordPress 一键部署, SFTP 账号(隔离到网站目录), 访问统计(PV/IP/流量/TOP/蜘蛛)
#        文件工具(大文件/解压/打包/批量替换/编辑/木马扫描), 在线更新(Git 仓库)
#  证书: Let's Encrypt(HTTP) / 通配符(Cloudflare DNS) / 自有证书 / 自签名, 自动续期
#  PHP : 7.4-8.4 多版本共存, 扩展, 参数, 禁用函数, FPM 进程数
#  其他: MariaDB + phpMyAdmin, Redis, Composer, 备份/还原, 计划任务, 服务管理,
#        软件商店 (Node.js/PM2/Python/Java/Docker/PostgreSQL/Memcached/Fail2ban 等)
#  系统: Debian 10+ / Ubuntu 20.04+ (推荐)   RHEL 系 (Rocky/Alma/CentOS) 尽力支持
#
#  用法: bash wsm.sh install      首次安装环境 (之后直接用 wsm 命令)
#        wsm                      进入交互菜单
# =====================================================================
set -uo pipefail

WSM_VER="2.1"
WSM_DIR=/etc/wsm
META_DIR=$WSM_DIR/sites
CERT_DIR=$WSM_DIR/certs
AUTH_DIR=$WSM_DIR/auth
WWW_ROOT=/www/wwwroot
BACKUP_DIR=/www/backup
ACME_ROOT=/var/www/_acme
NGX_CONF=/etc/nginx/conf.d
CRON_TASKS=/etc/cron.d/wsm-tasks
WSM_BIN=/usr/local/bin/wsm
PHP_VERSIONS="7.4 8.0 8.1 8.2 8.3 8.4"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[x]${N} $*" >&2; }
die()  { err "$*"; exit 1; }
title() { echo; echo "${B}━━━━━━━━ $* ━━━━━━━━${N}"; }
# pad_w 文本 宽度 : 按显示宽度补空格 (中文占 2 格), 文本里不要带颜色码
pad_w() {
  local s=$1 w=$2 t n LC_ALL=C
  t=${s//[! -~]/}
  n=$(( ${#t} + (${#s} - ${#t}) / 3 * 2 ))
  printf '%s%*s' "$s" $((w > n ? w - n : 0)) ''
}
# mi 序号 名称 说明 : 主菜单一行 (名称列固定 12 格, 手机窄屏也不换行)
mi() { printf ' %2s) ' "$1"; pad_w "$2" 12; printf '%s\n' "${3:-}"; }

pause() { echo; read -r -p "${D}按回车键继续...${N}" _ || true; }

confirm() {  # confirm "问题" [y|n]
  local d=${2:-y} a hint
  [[ $d == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "$1 [$hint] " a || a=""
  a=${a:-$d}
  [[ $a =~ ^[Yy] ]]
}

ask() {  # ask 变量名 "提示" "默认值"  (变量已有值则跳过)
  local __v=$1 __p=$2 __d=${3:-} __in
  if [[ -n ${!__v:-} ]]; then return 0; fi
  if [[ -n $__d ]]; then
    read -r -p "$__p [$__d]: " __in || __in=""
    __in=${__in:-$__d}
  else
    read -r -p "$__p: " __in || __in=""
  fi
  printf -v "$__v" '%s' "$__in"
}

choose() {  # choose 结果变量 "标题" 选项1 选项2 ...   (数字选择, 默认第1项)
  local __var=$1 __title=$2; shift 2
  local -a __items=("$@")
  local __i __c
  echo "$__title"
  for __i in "${!__items[@]}"; do printf "   %d) %s\n" $((__i + 1)) "${__items[__i]}"; done
  while true; do
    read -r -p "请选择 [1]: " __c || return 1
    __c=${__c:-1}
    if [[ $__c =~ ^[0-9]+$ ]] && ((__c >= 1 && __c <= ${#__items[@]})); then
      printf -v "$__var" '%s' "${__items[__c - 1]}"
      return 0
    fi
    warn "无效选择, 请输入 1-${#__items[@]}"
  done
}

read_secret() {  # read_secret 变量 "提示"
  local __v=$1 __in
  read -rs -p "$2: " __in || __in=""
  echo
  printf -v "$__v" '%s' "$__in"
}

need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行"; }

# ================================================================ 系统识别
detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}
  OS_VER=${VERSION_ID%%.*}
  OS_CODENAME=${VERSION_CODENAME:-}
  case $OS_ID in
    debian|ubuntu) PM=apt; WEB_USER=www-data ;;
    centos|rocky|almalinux|rhel|ol) PM=dnf; WEB_USER=nginx ;;
    *) die "暂只支持 Debian / Ubuntu / RHEL 系, 当前: $OS_ID" ;;
  esac
  [[ -e /proc/net/if_inet6 ]] && HAS_V6=1 || HAS_V6=0
}

pkg_install() {
  if [[ $PM == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else dnf install -y "$@"; fi
}

public_ip() {
  curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null \
    || curl -4 -s --max-time 4 https://ifconfig.me 2>/dev/null || true
}

unit_exists() { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"; }

svc_state() {  # 彩色状态
  if systemctl is-active --quiet "$1" 2>/dev/null; then echo "${G}运行中${N}"; else echo "${R}未运行${N}"; fi
}

nginx_reload() {
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx; else nginx -t; return 1; fi
}

# ================================================================ PHP 辅助
php_pkgver() { echo "${1//./}"; }
php_svc() { if [[ $PM == apt ]]; then echo "php$1-fpm"; else echo "php$(php_pkgver "$1")-php-fpm"; fi; }
php_bin() { if [[ $PM == apt ]]; then echo "php$1"; else echo "php$(php_pkgver "$1")"; fi; }
php_sock() {
  if [[ $PM == apt ]]; then echo "/run/php/php$1-fpm.sock"
  else echo "/var/opt/remi/php$(php_pkgver "$1")/run/php-fpm/www.sock"; fi
}
php_ini_file() {
  if [[ $PM == apt ]]; then echo "/etc/php/$1/fpm/conf.d/99-wsm.ini"
  else echo "/etc/opt/remi/php$(php_pkgver "$1")/php.d/99-wsm.ini"; fi
}
php_pool_file() {
  if [[ $PM == apt ]]; then echo "/etc/php/$1/fpm/pool.d/www.conf"
  else echo "/etc/opt/remi/php$(php_pkgver "$1")/php-fpm.d/www.conf"; fi
}
php_installed() {
  local d v
  if [[ $PM == apt ]]; then
    for d in /etc/php/*/fpm; do
      [[ -d $d ]] || continue
      v=$(basename "$(dirname "$d")")
      # 卸载后配置目录可能残留, 以 php-fpm 程序是否存在为准
      [[ -x /usr/sbin/php-fpm$v ]] && echo "$v"
    done
  else
    for d in /etc/opt/remi/php*; do
      [[ -d $d ]] || continue
      v=$(basename "$d"); v=${v#php}
      [[ -x /opt/remi/php$v/root/usr/sbin/php-fpm ]] || continue
      echo "${v:0:1}.${v:1}"
    done
  fi
  return 0
}

ini_set_kv() {  # ini_set_kv 文件 键 值
  local f=$1 k=$2 v=$3
  touch "$f"
  if grep -qE "^$k[[:space:]]*=" "$f"; then
    sed -i -E "s|^$k[[:space:]]*=.*|$k = $v|" "$f"
  else
    echo "$k = $v" >> "$f"
  fi
}

add_php_repo() {
  [[ $PM == apt ]] || return 0
  if [[ $OS_ID == ubuntu ]]; then
    if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi ondrej; then
      pkg_install software-properties-common
      add-apt-repository -y ppa:ondrej/php || die "添加 ondrej/php 源失败"
      apt-get update -y
    fi
  else
    if [[ ! -f /etc/apt/sources.list.d/php-sury.list ]]; then
      pkg_install apt-transport-https lsb-release ca-certificates curl
      curl -fsSLo /tmp/sury-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
        || die "下载 sury 密钥失败"
      dpkg -i /tmp/sury-keyring.deb
      echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
        > /etc/apt/sources.list.d/php-sury.list
      apt-get update -y
    fi
  fi
}

install_php() {
  local v=${1:-}
  if [[ -z $v ]]; then
    local -a avail=()
    local x
    for x in $PHP_VERSIONS; do avail+=("$x"); done
    choose v "选择要安装的 PHP 版本:" "${avail[@]}" || return 1
  fi
  [[ " $PHP_VERSIONS " == *" $v "* ]] || die "不支持的 PHP 版本: $v"
  local pv ini_dir pool_conf ext
  pv=$(php_pkgver "$v")
  info "安装 PHP $v ..."
  if [[ $PM == apt ]]; then
    add_php_repo
    pkg_install "php$v-fpm" "php$v-cli" "php$v-common" "php$v-mysql" "php$v-curl" \
                "php$v-gd" "php$v-mbstring" "php$v-xml" "php$v-zip" || die "PHP $v 安装失败"
    for ext in bcmath intl opcache soap; do
      pkg_install "php$v-$ext" >/dev/null 2>&1 || warn "可选扩展 $ext 未安装(可忽略)"
    done
  else
    rpm -q remi-release >/dev/null 2>&1 || {
      pkg_install epel-release dnf-plugins-core
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${OS_VER}.rpm" || die "安装 remi 源失败"
    }
    pkg_install "php${pv}-php-fpm" "php${pv}-php-cli" "php${pv}-php-mysqlnd" "php${pv}-php-gd" \
                "php${pv}-php-mbstring" "php${pv}-php-xml" || die "PHP $v 安装失败"
    for ext in pecl-zip bcmath intl opcache soap; do
      pkg_install "php${pv}-php-$ext" >/dev/null 2>&1 || warn "可选扩展 $ext 未安装(可忽略)"
    done
    pool_conf=$(php_pool_file "$v")
    sed -i "s/^user = .*/user = ${WEB_USER}/;s/^group = .*/group = ${WEB_USER}/" "$pool_conf"
  fi
  ini_dir=$(dirname "$(php_ini_file "$v")")
  mkdir -p "$ini_dir"
  cat > "$(php_ini_file "$v")" <<EOF
expose_php = Off
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = 256M
max_execution_time = 300
date.timezone = Asia/Shanghai
EOF
  systemctl enable --now "$(php_svc "$v")"
  systemctl restart "$(php_svc "$v")"
  info "PHP $v 就绪 (socket: $(php_sock "$v"))"
}

# ================================================================ 基础环境
firewall_open() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
    info "ufw 已放行 80/443"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
    firewall-cmd --reload >/dev/null
    info "firewalld 已放行 80/443"
  fi
}

selinux_tune() {
  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) != Disabled ]]; then
    setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
  fi
}

install_base() {
  info "安装 Nginx / certbot / 常用工具 ..."
  if [[ $PM == apt ]]; then
    apt-get update -y
    pkg_install nginx curl ca-certificates openssl cron certbot unzip tar gzip || die "基础软件安装失败"
    rm -f /etc/nginx/sites-enabled/default
    systemctl enable --now cron >/dev/null 2>&1 || true
  else
    pkg_install epel-release
    pkg_install nginx curl openssl cronie certbot unzip tar gzip || die "基础软件安装失败"
    systemctl enable --now crond >/dev/null 2>&1 || true
  fi
  mkdir -p "$WWW_ROOT" "$ACME_ROOT" "$META_DIR" "$CERT_DIR" "$AUTH_DIR" "$BACKUP_DIR" "$NGX_CONF"
  chmod 700 "$CERT_DIR" "$AUTH_DIR"
  cat > "$NGX_CONF/00-wsm.conf" <<'EOF'
# managed by wsm
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  selinux_tune
  firewall_open
  systemctl enable --now nginx
  nginx -t && systemctl reload nginx
  ensure_renew_cron
}

# ================================================================ 站点元数据
META_KEYS=(TYPE DOMAIN ALIASES ROOT PHPVER UPSTREAM SSL FORCE_HTTPS CERT_MODE REWRITE
           AUTH HOTLINK HOTLINK_DOMAINS IP_MODE IP_LIST GZIP CACHE REDIRECT_TO REDIRECT_CODE DISABLED
           TAMPER TAMPER_EXCLUDE NOEXEC)

meta_defaults() {
  TYPE=; DOMAIN=; ALIASES=; ROOT=; PHPVER=; UPSTREAM=; SSL=0; FORCE_HTTPS=0; CERT_MODE=le
  REWRITE=none; AUTH=0; HOTLINK=0; HOTLINK_DOMAINS=; IP_MODE=none; IP_LIST=; GZIP=1; CACHE=0
  REDIRECT_TO=; REDIRECT_CODE=301; DISABLED=0; TAMPER=0; TAMPER_EXCLUDE=; NOEXEC=0
}

meta_file() { echo "$META_DIR/$1.conf"; }

save_meta() {
  mkdir -p "$META_DIR"
  local k
  for k in "${META_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done > "$(meta_file "$DOMAIN")"
}

load_meta() {
  local f; f=$(meta_file "$1")
  [[ -f $f ]] || die "站点不存在: $1"
  meta_defaults
  # shellcheck disable=SC1090
  . "$f"
}

list_site_names() {
  local f
  for f in "$META_DIR"/*.conf; do
    [[ -e $f ]] && basename "$f" .conf
  done
  return 0
}

type_name() {
  case $1 in
    php) echo "PHP 站点" ;; static) echo "静态站点" ;; proxy) echo "反向代理" ;;
    redirect) echo "域名重定向" ;; *) echo "$1" ;;
  esac
}

pick_site() {  # pick_site [指定域名]  ->  SITE
  SITE=""
  local arg=${1:-} d i=0 c
  local -a names=()
  while read -r d; do [[ -n $d ]] && names+=("$d"); done < <(list_site_names)
  if [[ -n $arg ]]; then
    [[ -f $(meta_file "$arg") ]] || { err "站点不存在: $arg"; return 1; }
    SITE=$arg; return 0
  fi
  ((${#names[@]})) || { warn "还没有任何站点, 先去新建一个"; return 1; }
  echo "选择站点:"
  for d in "${names[@]}"; do
    i=$((i + 1))
    printf "   %2d) %s\n" "$i" "$d"
  done
  read -r -p "输入序号或域名 (回车取消): " c || return 1
  [[ -z $c ]] && return 1
  if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#names[@]})); then SITE=${names[c - 1]}; return 0; fi
  if [[ -f $(meta_file "$c") ]]; then SITE=$c; return 0; fi
  err "无效选择"; return 1
}

use_site() { pick_site "${1:-}" || return 1; load_meta "$SITE"; }

valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,}$ ]]; }
valid_url()    { local re='^https?://[]A-Za-z0-9._:/[-]+$'; [[ $1 =~ $re ]]; }
valid_path()   { [[ $1 =~ ^/[A-Za-z0-9._/~-]*$ ]]; }
valid_ip()     { [[ $1 =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]; }
# 网站目录必须至少两级, 且不能落在系统目录下 (防止 chown/rm 误伤)
safe_root() {
  [[ $1 =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+/?$ ]] || return 1
  case $1 in
    /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/dev/*|/proc/*|/sys/*|/root/*|/run/*|/var/lib/*|/var/log/*) return 1 ;;
  esac
  return 0
}

domain_used() {  # domain_used 域名 [排除的站点]  -> 输出占用它的站点
  local x=$1 f d
  for f in "$META_DIR"/*.conf; do
    [[ -e $f ]] || continue
    d=$(basename "$f" .conf)
    [[ $d == "${2:-}" ]] && continue
    if ( load_meta "$d"; for n in $DOMAIN $ALIASES; do [[ $n == "$x" ]] && exit 0; done; exit 1 ); then
      echo "$d"; return 0
    fi
  done
  return 1
}

# ================================================================ 证书路径
cert_paths() {  # 依据 CERT_MODE 设置 CRT / KEY
  if [[ $CERT_MODE == le ]]; then
    CRT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
    KEY=/etc/letsencrypt/live/$DOMAIN/privkey.pem
  else
    CRT=$CERT_DIR/$DOMAIN/fullchain.pem
    KEY=$CERT_DIR/$DOMAIN/privkey.pem
  fi
}

cert_days_left() {  # 依赖已 load_meta; 输出剩余天数, 无证书输出空
  cert_paths
  [[ -f $CRT ]] || return 0
  local end ts
  end=$(openssl x509 -enddate -noout -in "$CRT" 2>/dev/null | cut -d= -f2)
  ts=$(date -d "$end" +%s 2>/dev/null) || return 0
  echo $(((ts - $(date +%s)) / 86400))
}

# ================================================================ Nginx 配置生成
ngx_ge() {  # nginx 版本 >= $1 ?
  local cur
  cur=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
  [[ -n $cur && $(printf '%s\n%s\n' "$1" "$cur" | sort -V | head -1) == "$1" ]]
}

listen_lines() {  # listen_lines 端口 [ssl]
  local port=$1 ssl=${2:-}
  if [[ -n $ssl ]]; then
    if ngx_ge 1.25.1; then
      echo "    listen $port ssl;"
      [[ $HAS_V6 == 1 ]] && echo "    listen [::]:$port ssl;"
      echo "    http2 on;"
    else
      echo "    listen $port ssl http2;"
      [[ $HAS_V6 == 1 ]] && echo "    listen [::]:$port ssl http2;"
    fi
  else
    echo "    listen $port;"
    [[ $HAS_V6 == 1 ]] && echo "    listen [::]:$port;"
  fi
  return 0
}

server_common() {
  cat <<EOF
    server_tokens off;
    charset utf-8;
    client_max_body_size 100m;
    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log  /var/log/nginx/$DOMAIN.error.log;
EOF
}

proxy_block() {  # proxy_block location 后端
  cat <<EOF
    location $1 {
        proxy_pass $2;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_ssl_server_name on;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
}

rewrite_location() {
  case $REWRITE in
    wordpress|laravel) echo '    location / { try_files $uri $uri/ /index.php?$query_string; }' ;;
    thinkphp) echo '    location / { if (!-e $request_filename) { rewrite ^(.*)$ /index.php?s=$1 last; break; } }' ;;
    spa) echo '    location / { try_files $uri $uri/ /index.html; }' ;;
    custom) echo "    include $META_DIR/$DOMAIN.rewrite;" ;;
    *) echo '    location / { try_files $uri $uri/ =404; }' ;;
  esac
}

server_body() {
  local ip p u ex re
  if [[ $GZIP == 1 ]]; then
    cat <<'EOF'
    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1k;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml;
EOF
  fi
  if [[ $IP_MODE == allow ]]; then
    for ip in $IP_LIST; do echo "    allow $ip;"; done
    echo "    deny all;"
  elif [[ $IP_MODE == deny ]]; then
    for ip in $IP_LIST; do echo "    deny $ip;"; done
  fi
  if [[ $AUTH == 1 ]]; then
    echo '    auth_basic "Restricted";'
    echo "    auth_basic_user_file $AUTH_DIR/$DOMAIN.htpasswd;"
  fi

  if [[ $TYPE == redirect ]]; then
    echo "    return $REDIRECT_CODE $REDIRECT_TO\$request_uri;"
    return 0
  fi

  if [[ -f $META_DIR/$DOMAIN.paths ]]; then
    while read -r p u; do
      [[ -n $p && -n $u ]] && proxy_block "^~ $p" "$u"
    done < "$META_DIR/$DOMAIN.paths"
  fi

  case $TYPE in
    php|static)
      echo "    root $ROOT;"
      if [[ $TYPE == php ]]; then echo "    index index.php index.html index.htm;"
      else echo "    index index.html index.htm;"; fi
      rewrite_location
      if [[ $TYPE == php && $NOEXEC == 1 ]]; then
        for ex in $TAMPER_EXCLUDE; do
          re=${ex//./\\.}
          echo "    location ~* ^/${re}/.*\.(php|phtml|phar|php[0-9])\$ { deny all; }"
        done
      fi
      if [[ $HOTLINK == 1 || $CACHE == 1 ]]; then
        echo '    location ~* \.(gif|jpg|jpeg|png|bmp|webp|ico|svg|css|js|woff|woff2|ttf|mp4|zip)$ {'
        if [[ $HOTLINK == 1 ]]; then
          echo "        valid_referers none blocked server_names $DOMAIN $ALIASES $HOTLINK_DOMAINS;"
          echo '        if ($invalid_referer) { return 403; }'
        fi
        [[ $CACHE == 1 ]] && echo "        expires 30d;"
        echo '        try_files $uri =404;'
        echo '    }'
      fi
      if [[ $TYPE == php ]]; then
        cat <<EOF
    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$(php_sock "$PHPVER");
        fastcgi_read_timeout 300;
    }
EOF
      fi
      echo '    location ~ /\.(?!well-known) { deny all; }'
      ;;
    proxy)
      proxy_block "/" "$UPSTREAM"
      ;;
  esac
}

render_site() {
  load_meta "$1"
  local names="$DOMAIN${ALIASES:+ $ALIASES}"
  local conf="$NGX_CONF/$DOMAIN.conf"
  if [[ $DISABLED == 1 ]]; then
    rm -f "$conf"
    nginx_reload >/dev/null 2>&1
    return 0
  fi
  if [[ $SSL == 1 ]]; then
    cert_paths
    [[ -f $CRT && -f $KEY ]] || { err "找不到证书文件: $CRT"; return 1; }
  fi

  {
    echo "# managed by wsm - 请勿手动修改, 用 wsm 命令管理"
    echo "server {"
    listen_lines 80
    echo "    server_name $names;"
    echo "    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; auth_basic off; allow all; }"
    if [[ $SSL == 1 && $FORCE_HTTPS == 1 ]]; then
      echo "    location / { return 301 https://\$host\$request_uri; }"
    else
      server_common
      server_body
    fi
    echo "}"
    if [[ $SSL == 1 ]]; then
      echo "server {"
      listen_lines 443 ssl
      echo "    server_name $names;"
      cat <<EOF
    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
EOF
      [[ $FORCE_HTTPS == 1 ]] && echo '    add_header Strict-Transport-Security "max-age=31536000" always;'
      server_common
      server_body
      echo "}"
    fi
  } > "$conf.tmp"

  [[ -f $conf ]] && cp -f "$conf" "$conf.bak"
  mv -f "$conf.tmp" "$conf"
  if ! nginx -t 2>/tmp/wsm_nginx_err; then
    err "Nginx 配置检测失败, 已回滚:"
    cat /tmp/wsm_nginx_err >&2
    if [[ -f $conf.bak ]]; then mv -f "$conf.bak" "$conf"; else rm -f "$conf"; fi
    return 1
  fi
  rm -f "$conf.bak"
  systemctl reload nginx
}

# 保存并应用; 失败时恢复旧元数据
apply_site() {  # 依赖当前全局元数据变量
  local f bak=""
  f=$(meta_file "$DOMAIN")
  [[ -f $f ]] && { bak=$(mktemp); cp -f "$f" "$bak"; }
  save_meta
  if render_site "$DOMAIN"; then
    [[ -n $bak ]] && rm -f "$bak"
    return 0
  fi
  if [[ -n $bak ]]; then mv -f "$bak" "$f"; else rm -f "$f"; fi
  return 1
}

# ================================================================ 证书申请 / 安装
public_ip_cached() { SERVER_IP=${SERVER_IP:-$(public_ip)}; echo "$SERVER_IP"; }

check_dns() {  # 依赖已 load_meta; 返回 0=OK 或用户确认继续
  local ip n r bad=0
  ip=$(public_ip_cached)
  for n in $DOMAIN $ALIASES; do
    r=$(getent ahostsv4 "$n" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z $r ]]; then
      warn "$n 还没有解析到任何 IPv4 地址"; bad=1
    elif [[ -n $ip && $r != "$ip" ]]; then
      warn "$n 解析到 $r, 但本机公网 IP 是 $ip (若用了 CDN 代理可忽略)"; bad=1
    fi
  done
  if [[ $bad == 1 ]]; then
    confirm "域名解析与本机不一致, 仍然继续?" n
  fi
}

finish_ssl() {  # finish_ssl 模式(le|custom|self)
  CERT_MODE=$1
  SSL=1
  if confirm "是否强制 HTTP 自动跳转到 HTTPS?" y; then FORCE_HTTPS=1; else FORCE_HTTPS=0; fi
  apply_site || return 1
  ensure_renew_cron
  info "HTTPS 已启用: https://$DOMAIN"
}

ssl_le_http() {
  load_meta "$1"
  command -v certbot >/dev/null 2>&1 || die "未安装 certbot, 请先安装环境"
  echo "Let's Encrypt (HTTP 验证) 需要: 域名已解析到本机, 且 80 端口可从外网访问。"
  check_dns || { warn "已取消"; return 1; }
  local email="" n
  local -a n_args=() mail_args=()
  [[ -f $WSM_DIR/email ]] && email=$(cat "$WSM_DIR/email")
  if [[ -z $email ]]; then
    read -r -p "证书到期通知邮箱 (可留空): " email || email=""
    [[ -n $email ]] && echo "$email" > "$WSM_DIR/email"
  fi
  if [[ -n $email ]]; then mail_args=(-m "$email"); else mail_args=(--register-unsafely-without-email); fi
  for n in $DOMAIN $ALIASES; do n_args+=(-d "$n"); done
  info "正在申请证书: $DOMAIN $ALIASES"
  certbot certonly --webroot -w "$ACME_ROOT" "${n_args[@]}" --cert-name "$DOMAIN" \
    --agree-tos --non-interactive --expand "${mail_args[@]}" \
    || { err "申请失败: 请确认域名已解析到本机、80 端口已放行(云厂商安全组也要放行)"; return 1; }
  finish_ssl le
}

ssl_le_dns() {
  load_meta "$1"
  command -v certbot >/dev/null 2>&1 || die "未安装 certbot, 请先安装环境"
  echo "通配符证书需要 DNS 验证。目前支持 Cloudflare (域名需托管在 Cloudflare)。"
  if ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
    info "安装 certbot Cloudflare 插件 ..."
    pkg_install python3-certbot-dns-cloudflare || { err "插件安装失败"; return 1; }
  fi
  local cf=$WSM_DIR/cloudflare.ini token base n
  if [[ ! -f $cf ]] || confirm "已保存过 Cloudflare Token, 是否重新输入?" n; then
    echo "到 Cloudflare → 我的个人资料 → API 令牌 创建令牌, 权限: 区域→DNS→编辑"
    read_secret token "粘贴 API Token (输入不显示)"
    [[ -n $token ]] || { err "Token 为空"; return 1; }
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$cf"
    chmod 600 "$cf"
  fi
  base=${DOMAIN#www.}
  ask base "通配符所属主域名 (将申请 *.主域名)" "$base"
  valid_domain "$base" || { err "域名格式不正确"; return 1; }
  local -a n_args=(-d "$DOMAIN")
  local -A seen=([$DOMAIN]=1)
  for n in $ALIASES "$base" "*.$base"; do
    [[ -n ${seen[$n]:-} ]] && continue
    seen[$n]=1; n_args+=(-d "$n")
  done
  local -a mail_args=()
  [[ -f $WSM_DIR/email ]] && mail_args=(-m "$(cat "$WSM_DIR/email")") || mail_args=(--register-unsafely-without-email)
  info "正在通过 DNS 申请通配符证书 (约需 1 分钟) ..."
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cf" \
    --dns-cloudflare-propagation-seconds 30 "${n_args[@]}" --cert-name "$DOMAIN" \
    --agree-tos --non-interactive --expand "${mail_args[@]}" \
    || { err "申请失败: 请检查 Token 权限和域名是否托管在 Cloudflare"; return 1; }
  finish_ssl le
}

read_block() {  # 读取到单独一行 END
  local line
  while IFS= read -r line; do
    [[ $line == END ]] && break
    printf '%s\n' "$line"
  done
}

ssl_custom() {
  load_meta "$1"
  local how dir=$CERT_DIR/$DOMAIN crt_src key_src a b
  choose how "证书提供方式:" "粘贴证书和私钥内容" "指定服务器上的证书文件路径" || return 1
  mkdir -p "$dir"; chmod 700 "$dir"
  if [[ $how == 粘贴* ]]; then
    echo "请粘贴证书内容 (含 -----BEGIN CERTIFICATE-----, 中间证书一并粘贴), 完成后单独输入一行 END:"
    read_block > "$dir/fullchain.pem.new"
    echo "请粘贴私钥内容 (-----BEGIN ... PRIVATE KEY-----), 完成后单独输入一行 END:"
    read_block > "$dir/privkey.pem.new"
  else
    read -r -p "证书文件路径 (.crt/.pem, 需含完整证书链): " crt_src || return 1
    read -r -p "私钥文件路径 (.key): " key_src || return 1
    [[ -f $crt_src && -f $key_src ]] || { err "文件不存在"; return 1; }
    cp -f "$crt_src" "$dir/fullchain.pem.new"; cp -f "$key_src" "$dir/privkey.pem.new"
  fi
  if ! openssl x509 -in "$dir/fullchain.pem.new" -noout 2>/dev/null; then
    err "证书格式无效"; rm -f "$dir"/*.new; return 1
  fi
  if ! openssl pkey -in "$dir/privkey.pem.new" -noout 2>/dev/null; then
    err "私钥格式无效(带密码的私钥不支持)"; rm -f "$dir"/*.new; return 1
  fi
  a=$(openssl x509 -in "$dir/fullchain.pem.new" -noout -pubkey | openssl sha256)
  b=$(openssl pkey -in "$dir/privkey.pem.new" -pubout | openssl sha256)
  if [[ $a != "$b" ]]; then err "证书与私钥不匹配"; rm -f "$dir"/*.new; return 1; fi
  mv -f "$dir/fullchain.pem.new" "$dir/fullchain.pem"
  mv -f "$dir/privkey.pem.new" "$dir/privkey.pem"
  chmod 600 "$dir/privkey.pem"
  info "证书校验通过: $(openssl x509 -in "$dir/fullchain.pem" -noout -enddate)"
  finish_ssl custom
}

ssl_self() {
  load_meta "$1"
  local dir=$CERT_DIR/$DOMAIN n san=""
  mkdir -p "$dir"; chmod 700 "$dir"
  for n in $DOMAIN $ALIASES; do san+="${san:+,}DNS:$n"; done
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=$san" 2>/dev/null \
    || { err "生成自签名证书失败"; return 1; }
  chmod 600 "$dir/privkey.pem"
  warn "自签名证书浏览器会提示不安全, 仅建议测试或 CDN 回源使用"
  finish_ssl self
}

ssl_pick_method() {  # ssl_pick_method 域名
  local m
  choose m "选择证书类型:" \
    "Let's Encrypt 免费证书 (HTTP 验证, 最常用)" \
    "Let's Encrypt 通配符证书 (Cloudflare DNS 验证)" \
    "使用我自己的证书 (粘贴内容 / 指定文件)" \
    "生成自签名证书 (测试用)" || return 1
  case $m in
    "Let's Encrypt 免费"*) ssl_le_http "$1" ;;
    *通配符*) ssl_le_dns "$1" ;;
    使用我自己*) ssl_custom "$1" ;;
    *) ssl_self "$1" ;;
  esac
}

ssl_off() {
  load_meta "$1"
  confirm "确认关闭 $DOMAIN 的 HTTPS? (证书文件保留)" n || return 0
  SSL=0; FORCE_HTTPS=0
  apply_site && info "已关闭 HTTPS"
}

ssl_toggle_force() {
  load_meta "$1"
  [[ $SSL == 1 ]] || { warn "该站点还没启用 HTTPS"; return 1; }
  if [[ $FORCE_HTTPS == 1 ]]; then FORCE_HTTPS=0; else FORCE_HTTPS=1; fi
  apply_site && info "强制 HTTPS: $([[ $FORCE_HTTPS == 1 ]] && echo 已开启 || echo 已关闭)"
}

ssl_info() {
  load_meta "$1"
  cert_paths
  [[ -f $CRT ]] || { warn "没有找到证书文件"; return 1; }
  openssl x509 -in "$CRT" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
    || openssl x509 -in "$CRT" -noout -subject -issuer -dates
  echo "证书文件: $CRT"
}

ssl_renew_one() {
  load_meta "$1"
  [[ $CERT_MODE == le ]] || { warn "只有 Let's Encrypt 证书可以自动续期"; return 1; }
  certbot renew --cert-name "$DOMAIN" --force-renewal --deploy-hook "systemctl reload nginx"
}

ensure_renew_cron() {
  [[ -d /etc/cron.d ]] || return 0
  cat > /etc/cron.d/wsm-certbot <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3,15 * * * root certbot renew -q --deploy-hook "systemctl reload nginx"
EOF
  chmod 644 /etc/cron.d/wsm-certbot
}

list_certs() {
  local d days src
  printf "%-30s %-12s %-10s %s\n" "域名" "证书来源" "剩余天数" "状态"
  while read -r d; do
    [[ -n $d ]] || continue
    load_meta "$d"
    if [[ $SSL != 1 ]]; then
      printf "%-30s %-12s %-10s %s\n" "$d" "-" "-" "未启用 HTTPS"; continue
    fi
    days=$(cert_days_left)
    case $CERT_MODE in le) src="Let's Encrypt";; custom) src="自有证书";; *) src="自签名";; esac
    if [[ -z $days ]]; then
      printf "%-30s %-12s %-10s %s\n" "$d" "$src" "?" "${R}证书文件缺失${N}"
    elif ((days < 15)); then
      printf "%-30s %-12s %-10s %s\n" "$d" "$src" "$days" "${R}即将到期${N}"
    else
      printf "%-30s %-12s %-10s %s\n" "$d" "$src" "$days" "${G}正常${N}"
    fi
  done < <(list_site_names)
  if [[ -f /etc/cron.d/wsm-certbot ]]; then echo; echo "自动续期: ${G}已开启${N} (每天 03:17 / 15:17 检查)"
  else echo; echo "自动续期: ${R}未开启${N}"; fi
}

toggle_auto_renew() {
  if [[ -f /etc/cron.d/wsm-certbot ]]; then
    confirm "关闭证书自动续期?" n && rm -f /etc/cron.d/wsm-certbot && info "已关闭"
  else
    ensure_renew_cron && info "已开启"
  fi
}

# ================================================================ 新建站点
add_site() {  # add_site 类型 [域名] [后端/跳转目标]
  local type=$1 domain=${2:-} extra=${3:-} aliases="" root=${PRESET_ROOT:-} a u
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  title "新建$(type_name "$type")"
  ask domain "① 主域名 (如 example.com)"
  valid_domain "$domain" || die "域名格式不正确: $domain"
  [[ -f $(meta_file "$domain") ]] && die "站点已存在: $domain"
  read -r -p "② 绑定其他域名 (空格分隔, 可留空, 如 www.$domain): " aliases || aliases=""
  for a in $aliases; do
    valid_domain "$a" || die "域名格式不正确: $a"
    u=$(domain_used "$a") && die "域名 $a 已被站点 $u 使用"
  done
  u=$(domain_used "$domain") && die "域名 $domain 已被站点 $u 使用"

  meta_defaults
  TYPE=$type; DOMAIN=$domain; ALIASES=$aliases
  case $type in
    php|static)
      ask root "③ 网站根目录" "$WWW_ROOT/$domain"
      safe_root "$root" || die "目录不合法: 需为至少两级的普通路径(如 /www/wwwroot/xxx), 且不能在 /etc /usr /root 等系统目录下"
      ROOT=${root%/}
      mkdir -p "$ROOT"
      if [[ ! -e $ROOT/index.html && ! -e $ROOT/index.php ]]; then
        printf '<!doctype html>\n<html lang="zh-CN"><head><meta charset="utf-8"><title>%s</title></head>\n<body><h1>%s 站点创建成功</h1></body></html>\n' "$domain" "$domain" > "$ROOT/index.html"
      fi
      fix_perms_dir "$ROOT"
      if [[ $type == php ]]; then
        choose_php || die "没有可用的 PHP"
        PHPVER=$CHOSEN_PHP
      fi
      ;;
    proxy)
      ask extra "③ 后端地址 (如 http://127.0.0.1:3000)"
      valid_url "$extra" || die "后端地址格式不正确(不能含空格/引号/分号等)"
      UPSTREAM=$extra
      selinux_tune
      ;;
    redirect)
      ask extra "③ 跳转到 (如 https://www.example.com, 不带结尾斜杠)"
      extra=${extra%/}
      valid_url "$extra" || die "跳转地址格式不正确"
      REDIRECT_TO=$extra
      local rc; choose rc "跳转类型:" "301 永久跳转 (SEO 友好)" "302 临时跳转" || return 1
      REDIRECT_CODE=${rc%% *}
      ;;
  esac

  apply_site || die "站点创建失败"
  info "站点已创建: http://$domain"
  if confirm "现在为它启用 HTTPS 吗?" y; then
    ssl_pick_method "$domain" || warn "HTTPS 未启用, 之后可在 [SSL 证书] 菜单里重试"
  fi
}

choose_php() {  # 结果放在 CHOSEN_PHP
  local list x
  local -a arr=()
  list=$(php_installed | sort -V)
  if [[ -z $list ]]; then
    warn "还没有安装任何 PHP, 先装一个"
    install_php "" || return 1
    list=$(php_installed | sort -V)
  fi
  for x in $list; do arr+=("$x"); done
  choose CHOSEN_PHP "选择 PHP 版本:" "${arr[@]}"
}

fix_perms_dir() {
  chown -R "$WEB_USER:$WEB_USER" "$1" 2>/dev/null || true
  find "$1" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$1" -type f -exec chmod 644 {} + 2>/dev/null || true
  command -v chcon >/dev/null 2>&1 && chcon -R -t httpd_sys_rw_content_t "$1" >/dev/null 2>&1 || true
}

del_site() {
  use_site "${1:-}" || return 1
  local d=$DOMAIN
  confirm "确认删除站点 $d ? 此操作不可恢复" n || return 0
  sftp_purge_domain "$d"
  rm -f "$NGX_CONF/$d.conf"
  [[ $TAMPER == 1 && -d $ROOT ]] && chattr -R -i "$ROOT" 2>/dev/null
  rm -f "$WSM_DIR/baseline/$d.sha256" "$WSM_DIR/baseline/$d.tar.gz"
  [[ -f $CRON_TASKS ]] && sed -i "\|tamper-check $d |d" "$CRON_TASKS"
  if [[ $SSL == 1 && $CERT_MODE == le ]]; then
    certbot delete --cert-name "$d" --non-interactive >/dev/null 2>&1 || true
  fi
  rm -rf "$CERT_DIR/$d"
  rm -f "$AUTH_DIR/$d.htpasswd" "$META_DIR/$d.paths" "$META_DIR/$d.rewrite" "$(meta_file "$d")"
  nginx_reload >/dev/null 2>&1
  if [[ -n $ROOT && -d $ROOT ]] && confirm "同时删除网站目录 $ROOT ?" n; then rm -rf -- "$ROOT"; fi
  info "已删除 $d"
}

list_sites() {
  local d target days st ssl
  printf "%-28s %-10s %-34s %-8s %s\n" "域名" "类型" "目标" "HTTPS" "状态"
  while read -r d; do
    [[ -n $d ]] || continue
    load_meta "$d"
    target=""
    case $TYPE in
      php) target="$ROOT (php$PHPVER)" ;;
      static) target=$ROOT ;;
      proxy) target=$UPSTREAM ;;
      redirect) target="→ $REDIRECT_TO" ;;
    esac
    ssl="-"
    if [[ $SSL == 1 ]]; then days=$(cert_days_left); ssl="${days:-?}天"; fi
    if [[ $DISABLED == 1 ]]; then st="${Y}已停用${N}"; else st="${G}运行中${N}"; fi
    printf "%-28s %-10s %-34s %-8s %s\n" "$DOMAIN" "$(type_name "$TYPE")" "$target" "$ssl" "$st"
  done < <(list_site_names)
  [[ -n $(list_site_names) ]] || echo "(还没有站点)"
}

# ================================================================ 站点设置
yn() { [[ $1 == 1 ]] && echo "开" || echo "关"; }

site_summary() {
  echo "  域名:     $DOMAIN${ALIASES:+ $ALIASES}"
  echo "  类型:     $(type_name "$TYPE")   状态: $([[ $DISABLED == 1 ]] && echo "${Y}已停用${N}" || echo "${G}运行中${N}")"
  case $TYPE in
    php) echo "  目录:     $ROOT   PHP: $PHPVER   伪静态: $REWRITE" ;;
    static) echo "  目录:     $ROOT   伪静态: $REWRITE" ;;
    proxy) echo "  后端:     $UPSTREAM" ;;
    redirect) echo "  跳转到:   $REDIRECT_TO ($REDIRECT_CODE)" ;;
  esac
  if [[ $SSL == 1 ]]; then echo "  HTTPS:    已启用 ($CERT_MODE), 强制跳转: $(yn "$FORCE_HTTPS")"
  else echo "  HTTPS:    未启用"; fi
  echo "  访问密码: $(yn "$AUTH")   防盗链: $(yn "$HOTLINK")   静态缓存: $(yn "$CACHE")   Gzip: $(yn "$GZIP")   IP规则: $IP_MODE"
  echo "  防篡改:   $([[ $TAMPER == 1 ]] && echo "${G}已锁定${N}" || echo 未锁定)   可写目录: ${TAMPER_EXCLUDE:-无}   可写目录禁PHP: $(yn "$NOEXEC")"
}

need_type() {  # need_type 类型...  (当前 TYPE 不在其中则提示)
  local t
  for t in "$@"; do [[ $TYPE == "$t" ]] && return 0; done
  warn "该选项不适用于「$(type_name "$TYPE")」"
  return 1
}

site_domains() {
  local d=$1 c new n u x
  while true; do
    load_meta "$d"
    echo; echo "主域名: $DOMAIN"; echo "其他绑定: ${ALIASES:-(无)}"
    choose c "域名绑定:" "添加域名" "删除域名" "返回" || return 0
    case $c in
      添加域名)
        read -r -p "新域名 (空格分隔可多个): " new || continue
        for n in $new; do
          valid_domain "$n" || { warn "格式不正确: $n"; continue; }
          [[ " $DOMAIN $ALIASES " == *" $n "* ]] && { warn "已绑定: $n"; continue; }
          if u=$(domain_used "$n" "$d"); then warn "$n 已被站点 $u 使用"; continue; fi
          ALIASES="${ALIASES:+$ALIASES }$n"
        done
        apply_site && info "已更新绑定"
        if [[ $SSL == 1 && $CERT_MODE == le ]] && confirm "新域名需要重新申请证书才能用 HTTPS, 现在申请?" y; then
          ssl_le_http "$d"
        elif [[ $SSL == 1 ]]; then warn "请确认当前证书包含新域名"; fi
        ;;
      删除域名)
        [[ -n $ALIASES ]] || { warn "没有可删除的绑定域名"; continue; }
        local -a arr=($ALIASES)
        choose x "删除哪个域名?" "${arr[@]}" || continue
        new=""
        for n in $ALIASES; do [[ $n == "$x" ]] || new+="${new:+ }$n"; done
        ALIASES=$new
        apply_site && info "已删除 $x"
        ;;
      *) return 0 ;;
    esac
  done
}

site_root_change() {
  load_meta "$1"
  need_type php static || return 1
  [[ $TAMPER == 1 ]] && { err "网站处于防篡改锁定状态, 请先在 [网站防篡改] 里解锁"; return 1; }
  local r=""
  ask r "新的网站根目录" "$ROOT"
  safe_root "$r" || { err "目录不合法: 需为至少两级的普通路径, 且不能在系统目录下"; return 1; }
  mkdir -p "$r"
  ROOT=${r%/}
  apply_site || return 1
  confirm "修复该目录的属主和权限?" y && fix_perms_dir "$ROOT"
  info "网站根目录已改为 $ROOT"
}

site_php_switch() {
  load_meta "$1"
  need_type php || return 1
  choose_php || return 1
  PHPVER=$CHOSEN_PHP
  apply_site && info "$DOMAIN 已切换到 PHP $PHPVER"
}

site_target_change() {
  load_meta "$1"
  need_type proxy redirect || return 1
  local v=""
  if [[ $TYPE == proxy ]]; then
    ask v "新的后端地址" "$UPSTREAM"
    valid_url "$v" || { err "地址格式不正确"; return 1; }
    UPSTREAM=$v
  else
    ask v "新的跳转目标" "$REDIRECT_TO"
    v=${v%/}
    valid_url "$v" || { err "地址格式不正确"; return 1; }
    REDIRECT_TO=$v
    local rc; choose rc "跳转类型:" "301 永久跳转" "302 临时跳转" || return 1
    REDIRECT_CODE=${rc%% *}
  fi
  apply_site && info "已更新"
}

site_rewrite() {
  load_meta "$1"
  need_type php static || return 1
  echo "当前伪静态: $REWRITE"
  local r
  choose r "选择伪静态规则:" \
    "none (不使用)" "wordpress (WordPress)" "laravel (Laravel / 通用 index.php 入口)" \
    "thinkphp (ThinkPHP)" "spa (Vue / React 单页应用)" "custom (自己写 location 规则)" || return 1
  REWRITE=${r%% *}
  if [[ $REWRITE == custom ]]; then
    echo "请粘贴 Nginx 规则 (需包含完整的 location / { ... } 块), 完成后单独输入一行 END:"
    read_block > "$META_DIR/$DOMAIN.rewrite"
  fi
  apply_site && info "伪静态已设置为 $REWRITE"
}

site_paths() {
  local d=$1 c f p u x
  f=$META_DIR/$d.paths
  while true; do
    load_meta "$d"
    echo; echo "当前反代子路径:"
    if [[ -s $f ]]; then nl -w2 -s') ' "$f"; else echo "  (无)"; fi
    choose c "子路径反代 (如把 /api/ 转发到后端):" "添加规则" "删除规则" "返回" || return 0
    case $c in
      添加规则)
        read -r -p "路径 (如 /api/): " p || continue
        valid_path "$p" || { warn "路径格式不正确"; continue; }
        read -r -p "转发到 (如 http://127.0.0.1:3000/ ; 结尾带 / 会去掉路径前缀): " u || continue
        valid_url "$u" || { warn "地址格式不正确"; continue; }
        echo "$p $u" >> "$f"
        apply_site && info "已添加"
        ;;
      删除规则)
        [[ -s $f ]] || { warn "没有规则"; continue; }
        read -r -p "要删除的序号: " x || continue
        [[ $x =~ ^[0-9]+$ ]] && sed -i "${x}d" "$f" && apply_site && info "已删除"
        ;;
      *) return 0 ;;
    esac
  done
}

site_auth() {
  local d=$1 c u pw
  while true; do
    load_meta "$d"
    echo; echo "访问密码: $(yn "$AUTH")"
    choose c "访问密码 (HTTP Basic 认证):" "设置/添加用户" "关闭访问密码" "返回" || return 0
    case $c in
      设置*)
        read -r -p "用户名: " u || continue
        [[ $u =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || { warn "用户名只能含字母数字 _ . -"; continue; }
        read_secret pw "密码 (输入不显示)"
        [[ ${#pw} -ge 4 ]] || { warn "密码至少 4 位"; continue; }
        mkdir -p "$AUTH_DIR"
        touch "$AUTH_DIR/$d.htpasswd"; chmod 640 "$AUTH_DIR/$d.htpasswd"
        sed -i "/^$u:/d" "$AUTH_DIR/$d.htpasswd"
        printf '%s:%s\n' "$u" "$(openssl passwd -apr1 "$pw")" >> "$AUTH_DIR/$d.htpasswd"
        chgrp "$WEB_USER" "$AUTH_DIR/$d.htpasswd" 2>/dev/null || true
        AUTH=1
        apply_site && info "已启用访问密码, 用户: $u"
        ;;
      关闭*) AUTH=0; apply_site && info "已关闭" ;;
      *) return 0 ;;
    esac
  done
}

site_hotlink() {
  load_meta "$1"
  need_type php static || return 1
  local c w
  choose c "防盗链 / 静态缓存:" \
    "开启防盗链 (只允许本站及白名单域名引用图片等资源)" "关闭防盗链" \
    "开启静态资源缓存 (30 天)" "关闭静态资源缓存" || return 1
  case $c in
    开启防盗链*)
      read -r -p "额外允许的域名 (空格分隔, 可留空): " w || w=""
      for x in $w; do valid_domain "$x" || { err "格式不正确: $x"; return 1; }; done
      HOTLINK=1; HOTLINK_DOMAINS=$w ;;
    关闭防盗链*) HOTLINK=0 ;;
    开启静态*) CACHE=1 ;;
    *) CACHE=0 ;;
  esac
  apply_site && info "已更新"
}

site_ip_rules() {
  load_meta "$1"
  local c x l i m
  local -a arr=() keep=()
  while true; do
    read -r -a arr <<<"$IP_LIST"
    title "IP 访问控制 · $DOMAIN"
    case $IP_MODE in
      allow) echo "  模式: ${G}白名单${N} (只允许下列 IP)" ;;
      deny)  echo "  模式: ${Y}黑名单${N} (禁止下列 IP)" ;;
      *)     echo "  模式: 未开启" ;;
    esac
    if ((${#arr[@]})); then
      i=0; for x in "${arr[@]}"; do i=$((i + 1)); printf "   %2d. %s\n" "$i" "$x"; done
    else echo "  (名单为空)"; fi
    choose c "操作:" "添加 IP" "删除单个 IP" "切换白名单 / 黑名单" "清空并关闭" "返回" || return 0
    case $c in
      添加*)
        if [[ $IP_MODE == none ]]; then
          choose m "选择模式:" "白名单 (只允许这些 IP)" "黑名单 (禁止这些 IP)" || continue
          [[ $m == 白名单* ]] && IP_MODE=allow || IP_MODE=deny
        fi
        read -r -p "IP 或网段 (空格分隔, 如 1.2.3.4 10.0.0.0/8): " l || continue
        [[ -n $l ]] || { err "不能为空"; continue; }
        for x in $l; do valid_ip "$x" || { err "格式不正确: $x"; continue 2; }; done
        for x in $l; do [[ " $IP_LIST " == *" $x "* ]] || IP_LIST="${IP_LIST:+$IP_LIST }$x"; done
        [[ $IP_MODE == allow ]] && warn "白名单模式: 不在名单里的访问(包括你自己)会被拒绝, 请确认包含你的 IP"
        apply_site && info "已更新" ;;
      删除*)
        ((${#arr[@]})) || { warn "名单是空的"; continue; }
        read -r -p "输入要删除的序号或 IP (空格分隔多个): " l || continue
        keep=()
        for x in "${arr[@]}"; do
          i=$(printf '%s\n' "${arr[@]}" | grep -nxF -- "$x" | head -1 | cut -d: -f1)
          for m in $l; do [[ $m == "$i" || $m == "$x" ]] && continue 2; done
          keep+=("$x")
        done
        if ((${#keep[@]} == ${#arr[@]})); then warn "没有匹配的项"; continue; fi
        IP_LIST="${keep[*]:-}"
        if [[ -z $IP_LIST ]]; then IP_MODE=none; info "名单已空, 自动关闭 IP 访问控制"; fi
        apply_site && info "已更新" ;;
      切换*)
        [[ $IP_MODE == none ]] && { warn "尚未开启, 请先添加 IP"; continue; }
        if [[ $IP_MODE == allow ]]; then IP_MODE=deny; else IP_MODE=allow; fi
        [[ $IP_MODE == allow ]] && warn "已切换为白名单, 请确认名单里包含你的 IP"
        apply_site && info "已切换" ;;
      清空*) IP_MODE=none; IP_LIST=""; apply_site && info "已关闭并清空" ;;
      *) return 0 ;;
    esac
  done
}

site_toggle() {  # 停用/启用
  load_meta "$1"
  if [[ $DISABLED == 1 ]]; then DISABLED=0; apply_site && info "站点已启用"
  else confirm "停用 $DOMAIN? (访问将失效, 数据保留)" y && { DISABLED=1; apply_site && info "站点已停用"; }; fi
}

site_gzip() {
  load_meta "$1"
  if [[ $GZIP == 1 ]]; then GZIP=0; else GZIP=1; fi
  apply_site && info "Gzip: $(yn "$GZIP")"
}

site_logs() {
  local d=$1 c
  load_meta "$d"
  while true; do
    choose c "日志:" "最近 50 行访问日志" "最近 50 行错误日志" "访问统计 (PV/IP/流量/TOP)" "清空日志" "返回" || return 0
    case $c in
      最近*访问*) tail -n 50 "/var/log/nginx/$d.access.log" 2>/dev/null || warn "暂无日志" ;;
      最近*错误*) tail -n 50 "/var/log/nginx/$d.error.log" 2>/dev/null || warn "暂无日志" ;;
      访问统计*) stat_range_pick && stat_show "$d" "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
      清空日志*)
        : > "/var/log/nginx/$d.access.log" 2>/dev/null; : > "/var/log/nginx/$d.error.log" 2>/dev/null
        info "已清空" ;;
      *) return 0 ;;
    esac
  done
}

ssl_menu() {
  use_site "${1:-}" || return 1
  local d=$SITE c
  while true; do
    load_meta "$d"
    title "SSL 设置 · $d"
    if [[ $SSL == 1 ]]; then echo "  当前: 已启用 ($CERT_MODE), 剩余 $(cert_days_left) 天, 强制跳转: $(yn "$FORCE_HTTPS")"
    else echo "  当前: 未启用 HTTPS"; fi
    choose c "操作:" "申请 / 更换证书" "强制 HTTPS 开关" "关闭 HTTPS" "查看证书信息" \
      "立即续期 (Let's Encrypt)" "返回" || return 0
    case $c in
      申请*) ssl_pick_method "$d" ;;
      强制*) ssl_toggle_force "$d" ;;
      关闭*) ssl_off "$d" ;;
      查看*) ssl_info "$d" ;;
      立即*) ssl_renew_one "$d" ;;
      *) return 0 ;;
    esac
  done
}

site_settings() {
  use_site "${1:-}" || return 1
  local d=$SITE c
  while true; do
    load_meta "$d"
    title "站点设置 · $d"
    site_summary
    echo
    local -a __it=("域名绑定" "SSL/HTTPS" "切换PHP版本" "网站根目录" "后端/跳转目标" "伪静态规则" \
      "反代子路径" "访问密码" "防盗链/缓存" "IP黑白名单" "Gzip压缩" "停用/启用" \
      "查看Nginx配置" "日志统计" "备份此站点" "修复权限" "网站防篡改" "文件工具")
    local __k
    for __k in "${!__it[@]}"; do
      printf '%3d) ' $((__k + 1)); pad_w "${__it[__k]}" 14
      ((__k % 2)) && echo || printf ' '
    done
    ((${#__it[@]} % 2)) && echo
    echo "  0) 返回"
    read -r -p "请选择: " c || return 0
    case $c in
      1) site_domains "$d" ;;
      2) ssl_menu "$d" ;;
      3) site_php_switch "$d" ;;
      4) site_root_change "$d" ;;
      5) site_target_change "$d" ;;
      6) site_rewrite "$d" ;;
      7) need_type php static proxy && site_paths "$d" ;;
      8) site_auth "$d" ;;
      9) site_hotlink "$d" ;;
      10) site_ip_rules "$d" ;;
      11) site_gzip "$d" ;;
      12) site_toggle "$d" ;;
      13) cat "$NGX_CONF/$d.conf" 2>/dev/null || warn "站点已停用, 没有生效的配置"; pause ;;
      14) site_logs "$d" ;;
      15) backup_site "$d" 7 ;;
      16) need_type php static && [[ -d $ROOT ]] && fix_perms_dir "$ROOT" && info "权限已修复" ;;
      17) need_type php static && tamper_menu "$d" ;;
      18) need_type php static && files_menu "$d" ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ================================================================ 网站防篡改
# 原理: 1) chattr +i 把网站文件设为"不可修改"(连 root/PHP 木马都改不了, 要先解锁)
#       2) 上传/缓存等必须可写的目录单独放开, 并禁止在里面执行 PHP (防 webshell)
#       3) 文件完整性基线: 记录每个文件的 sha256 + 备份, 可检测并还原被改动/新增的文件
baseline_dir() { echo "$WSM_DIR/baseline"; }

chattr_ok() {  # 测试目录所在文件系统是否支持 chattr +i
  local t="$1/.wsm_chattr_test_$$"
  if touch "$t" 2>/dev/null && chattr +i "$t" 2>/dev/null; then
    chattr -i "$t" 2>/dev/null; rm -f "$t"; return 0
  fi
  chattr -i "$t" 2>/dev/null; rm -f "$t"; return 1
}

tamper_prune_args() {  # tamper_prune_args 基准目录 -> TP_ARGS (find 的排除参数)
  TP_ARGS=()
  local ex first=1
  for ex in $TAMPER_EXCLUDE; do
    if ((first)); then TP_ARGS+=(-path "$1/$ex"); first=0; else TP_ARGS+=(-o -path "$1/$ex"); fi
  done
}

tamper_find() {  # 在当前目录(网站根)下列出受保护文件 ./xxx
  tamper_prune_args "."
  if ((${#TP_ARGS[@]})); then find . \( "${TP_ARGS[@]}" \) -prune -o -type f -print
  else find . -type f -print; fi
}

tamper_lock_files() {
  tamper_prune_args "$ROOT"
  if ((${#TP_ARGS[@]})); then
    find "$ROOT" \( "${TP_ARGS[@]}" \) -prune -o -type f -exec chattr +i {} +
    find "$ROOT" \( "${TP_ARGS[@]}" \) -prune -o -type d -exec chattr +i {} +
  else
    find "$ROOT" -type f -exec chattr +i {} +
    find "$ROOT" -type d -exec chattr +i {} +
  fi
}

tamper_baseline() {  # 依赖已 load_meta
  local bd; bd=$(baseline_dir)
  mkdir -p "$bd"; chmod 700 "$bd"
  ( cd "$ROOT" && tamper_find | LC_ALL=C sort | tr '\n' '\0' | xargs -0 -r sha256sum ) > "$bd/$DOMAIN.sha256" \
    || { err "生成哈希基线失败"; return 1; }
  ( cd "$ROOT" && tamper_find | tar -czf "$bd/$DOMAIN.tar.gz" -T - ) \
    || { err "生成基线备份失败"; return 1; }
  info "基线已创建: $(wc -l < "$bd/$DOMAIN.sha256") 个文件 (备份 $(du -h "$bd/$DOMAIN.tar.gz" | cut -f1))"
}

tamper_pick_excludes() {  # -> TAMPER_EXCLUDE
  local p x list
  choose p "你的程序属于哪一类? (决定哪些目录保持可写):" \
    "WordPress (wp-content/uploads wp-content/cache wp-content/upgrade)" \
    "Laravel (storage bootstrap/cache)" \
    "ThinkPHP (runtime public/uploads)" \
    "通用 (uploads upload cache runtime storage data logs temp)" \
    "纯静态或不需要写入 (全部锁定)" \
    "自定义" || return 1
  case $p in
    WordPress*) TAMPER_EXCLUDE="wp-content/uploads wp-content/cache wp-content/upgrade" ;;
    Laravel*) TAMPER_EXCLUDE="storage bootstrap/cache" ;;
    ThinkPHP*) TAMPER_EXCLUDE="runtime public/uploads" ;;
    通用*) TAMPER_EXCLUDE="uploads upload cache runtime storage data logs temp" ;;
    纯静态*) TAMPER_EXCLUDE="" ;;
    *)
      read -r -p "可写目录 (相对网站根目录, 空格分隔, 如 uploads data/cache): " list || return 1
      for x in $list; do
        [[ $x =~ ^[A-Za-z0-9._/-]+$ && $x != /* && $x != *..* ]] || { err "目录不合法: $x"; return 1; }
      done
      TAMPER_EXCLUDE=$list ;;
  esac
}

tamper_lock() {
  load_meta "$1"
  need_type php static || return 1
  [[ -d $ROOT ]] || { err "网站目录不存在: $ROOT"; return 1; }
  [[ $TAMPER == 1 ]] && { warn "已经是锁定状态"; return 0; }
  command -v chattr >/dev/null 2>&1 || pkg_install e2fsprogs >/dev/null 2>&1
  chattr_ok "$ROOT" || { err "当前文件系统不支持文件锁定 (需要 ext4 / xfs / btrfs; 部分容器或虚拟化环境不支持)"; return 1; }
  if [[ -z $TAMPER_EXCLUDE ]] || ! confirm "沿用上次的可写目录 ($TAMPER_EXCLUDE) ?" y; then
    tamper_pick_excludes || return 1
  fi
  echo
  echo "即将锁定 $ROOT :"
  echo "  · 除可写目录外, 所有文件和目录都无法被修改/删除/新建 (包括 root 和 PHP)"
  echo "  · 可写目录: ${TAMPER_EXCLUDE:-无 (全部锁定)}"
  echo "  · CMS 后台安装/更新插件、在线编辑主题等会失败; 要更新网站请先 [临时解锁]"
  confirm "确认锁定?" y || return 0
  local ex
  for ex in $TAMPER_EXCLUDE; do
    mkdir -p "$ROOT/$ex"
    chown -R "$WEB_USER:$WEB_USER" "$ROOT/$ex" 2>/dev/null || true
  done
  info "创建完整性基线 ..."
  tamper_baseline || return 1
  info "锁定文件 (大站点可能需要几十秒) ..."
  tamper_lock_files || { err "锁定过程出错"; return 1; }
  TAMPER=1
  if [[ $TYPE == php && -n $TAMPER_EXCLUDE ]] && confirm "同时禁止在可写目录里执行 PHP? (强烈建议, 防 webshell)" y; then NOEXEC=1; fi
  apply_site || return 1
  info "防篡改已开启。更新网站前请用 [临时解锁], 改完再 [锁定]"
}

tamper_unlock() {
  load_meta "$1"
  [[ $TAMPER == 1 ]] || { warn "当前没有锁定"; return 0; }
  chattr -R -i "$ROOT" || { err "解锁失败"; return 1; }
  TAMPER=0
  save_meta
  info "已解锁, 现在可以更新网站文件。改完后请回到这里重新锁定 (会自动刷新基线)"
}

tamper_check() {  # tamper_check [域名] [ask|report|restore]
  use_site "${1:-}" || return 1
  local mode=${2:-ask} bd bl changed new nc nn f
  bd=$(baseline_dir); bl=$bd/$DOMAIN.sha256
  [[ -f $bl && -f $bd/$DOMAIN.tar.gz && -d $ROOT ]] || { err "还没有基线, 请先 [锁定] 或 [重新创建基线]"; return 1; }
  cd "$ROOT" || return 1
  changed=$(sha256sum -c --quiet "$bl" 2>&1 | sed -n 's/: FAILED.*$//p')
  new=$(comm -13 <(cut -c67- "$bl" | LC_ALL=C sort) <(tamper_find | LC_ALL=C sort))
  if [[ -z $changed && -z $new ]]; then
    info "$DOMAIN 文件完整, 没有发现被修改 / 删除 / 新增的文件"
    return 0
  fi
  nc=$(printf '%s\n' "$changed" | grep -c .); nn=$(printf '%s\n' "$new" | grep -c .)
  echo "$(date '+%F %T') $DOMAIN 被修改或删除=$nc 新增=$nn" >> /var/log/wsm-tamper.log
  warn "$DOMAIN 发现异常: 被修改或删除 $nc 个, 新增 $nn 个"
  [[ -n $changed ]] && { echo "--- 被修改 / 删除:"; printf '%s\n' "$changed" | head -30; }
  [[ -n $new ]] && { echo "--- 新增的文件 (可能是木马):"; printf '%s\n' "$new" | head -30; }
  if [[ $mode == ask ]]; then
    confirm "按基线还原被改动的文件, 并删除新增的文件?" n && mode=restore || mode=report
  fi
  if [[ $mode == restore ]]; then
    if [[ $TAMPER == 1 ]]; then chattr -R -i "$ROOT" 2>/dev/null; fi
    [[ -n $changed ]] && printf '%s\n' "$changed" | tar -xzf "$bd/$DOMAIN.tar.gz" -C "$ROOT" -T -
    if [[ -n $new ]]; then while read -r f; do rm -f -- "$ROOT/$f"; done <<< "$new"; fi
    if [[ $TAMPER == 1 ]]; then tamper_lock_files; fi
    echo "$(date '+%F %T') $DOMAIN 已按基线还原" >> /var/log/wsm-tamper.log
    info "已还原 $nc 个文件, 删除 $nn 个新增文件"
  fi
  return 2
}

tamper_cron_toggle() {
  local d=$1 m mode
  tasks_init
  [[ -x $WSM_BIN ]] || self_install
  if grep -q "tamper-check $d " "$CRON_TASKS"; then
    sed -i "\|tamper-check $d |d" "$CRON_TASKS"
    info "已关闭定时检测"; return 0
  fi
  read -r -p "每隔几分钟检测一次 (1-59) [10]: " m || return 1
  m=${m:-10}
  [[ $m =~ ^[0-9]+$ && $m -ge 1 && $m -le 59 ]] || { err "请输入 1-59"; return 1; }
  choose mode "发现改动时:" "只记录日志 (/var/log/wsm-tamper.log)" "自动还原被改动的文件并删除新增文件" || return 1
  [[ $mode == 自动* ]] && mode=restore || mode=report
  printf '*/%s * * * * root %s tamper-check %s %s >> /var/log/wsm-task.log 2>&1 # wsm-task\n' "$m" "$WSM_BIN" "$d" "$mode" >> "$CRON_TASKS"
  info "已开启: 每 $m 分钟检测一次 (发现改动: $([[ $mode == restore ]] && echo 自动还原 || echo 仅记录))"
}

tamper_menu() {
  local d=$1 c
  while true; do
    load_meta "$d"
    title "网站防篡改 · $d"
    echo "  锁定状态:   $([[ $TAMPER == 1 ]] && echo "${G}已锁定${N}" || echo "${Y}未锁定${N}")"
    echo "  可写目录:   ${TAMPER_EXCLUDE:-无}"
    echo "  可写目录禁止执行 PHP: $(yn "$NOEXEC")"
    echo "  定时检测:   $(grep -q "tamper-check $d " "$CRON_TASKS" 2>/dev/null && echo 已开启 || echo 未开启)"
    choose c "操作:" "锁定网站文件 (开启防篡改)" "临时解锁 (更新网站前使用)" "修改可写目录" \
      "可写目录禁止执行 PHP (开关)" "文件完整性检测" "还原被改动的文件 (按基线)" \
      "重新创建基线 (网站更新后)" "定时检测任务 (开关)" "返回" || return 0
    case $c in
      锁定*) tamper_lock "$d" ;;
      临时*) tamper_unlock "$d" ;;
      修改可写*)
        [[ $TAMPER == 1 ]] && { warn "请先临时解锁"; continue; }
        tamper_pick_excludes && apply_site && info "已更新: ${TAMPER_EXCLUDE:-无}" ;;
      可写目录禁止*)
        if [[ -z $TAMPER_EXCLUDE ]]; then warn "还没有设置可写目录"; continue; fi
        if [[ $NOEXEC == 1 ]]; then NOEXEC=0; else NOEXEC=1; fi
        apply_site && info "可写目录禁止执行 PHP: $(yn "$NOEXEC")" ;;
      文件完整性*) ( tamper_check "$d" ask ) ;;
      还原*) ( tamper_check "$d" restore ) ;;
      重新创建*)
        [[ -d $ROOT ]] || continue
        if [[ $TAMPER == 1 ]]; then warn "网站已锁定, 文件没有变化, 基线无需更新 (需要的话先临时解锁)"; continue; fi
        tamper_baseline ;;
      定时*) tamper_cron_toggle "$d" ;;
      *) return 0 ;;
    esac
  done
}

# ================================================================ PHP 管理
php_status_table() {
  local v n
  pad_w "版本" 8; pad_w "状态" 10; echo "站点数"
  for v in $(php_installed | sort -V); do
    n=0
    while read -r d; do
      [[ -n $d ]] || continue
      ( load_meta "$d"; [[ $TYPE == php && $PHPVER == "$v" ]] ) && n=$((n + 1))
    done < <(list_site_names)
    pad_w "$v" 8; printf '%s' "$(svc_state "$(php_svc "$v")")"; printf '    %s\n' "$n"
  done
  [[ -n $(php_installed) ]] || echo "(尚未安装 PHP)"
}

pick_php_installed() {  # -> CHOSEN_PHP
  local x
  local -a arr=()
  for x in $(php_installed | sort -V); do arr+=("$x"); done
  ((${#arr[@]})) || { warn "还没有安装 PHP"; return 1; }
  choose CHOSEN_PHP "选择 PHP 版本:" "${arr[@]}"
}

php_uninstall() {
  pick_php_installed || return 1
  local v=$CHOSEN_PHP d
  while read -r d; do
    [[ -n $d ]] || continue
    if ( load_meta "$d"; [[ $TYPE == php && $PHPVER == "$v" ]] ); then
      err "站点 $d 正在使用 PHP $v, 请先切换版本"; return 1
    fi
  done < <(list_site_names)
  confirm "确认卸载 PHP $v ?" n || return 0
  systemctl disable --now "$(php_svc "$v")" >/dev/null 2>&1 || true
  if [[ $PM == apt ]]; then apt-get purge -y "php$v-*" && apt-get autoremove -y
  else dnf remove -y "php$(php_pkgver "$v")-php-*"; fi
  # 清理残留的配置目录, 避免列表里还显示
  if [[ $PM == apt ]]; then rm -rf "/etc/php/$v"
  else rm -rf "/etc/opt/remi/php$(php_pkgver "$v")"; fi
  info "PHP $v 已卸载"
}

php_settings() {
  pick_php_installed || return 1
  local v=$CHOSEN_PHP f c val
  f=$(php_ini_file "$v")
  touch "$f"
  while true; do
    echo; echo "PHP $v 当前参数 ($f):"
    grep -vE '^\s*(;|$)' "$f" | sed 's/^/   /'
    choose c "修改:" "上传大小限制 (upload_max_filesize + post_max_size)" "内存限制 (memory_limit)" \
      "最大执行时间 (max_execution_time)" "时区 (date.timezone)" "显示错误 (display_errors)" "返回" || return 0
    case $c in
      上传*) read -r -p "新值 (如 200M): " val || continue
             [[ $val =~ ^[0-9]+[KMG]$ ]] || { warn "格式如 100M"; continue; }
             ini_set_kv "$f" upload_max_filesize "$val"; ini_set_kv "$f" post_max_size "$val" ;;
      内存*) read -r -p "新值 (如 512M): " val || continue
             [[ $val =~ ^[0-9]+[KMG]$ ]] || { warn "格式如 256M"; continue; }
             ini_set_kv "$f" memory_limit "$val" ;;
      最大*) read -r -p "秒数 (如 300): " val || continue
             [[ $val =~ ^[0-9]+$ ]] || { warn "请输入数字"; continue; }
             ini_set_kv "$f" max_execution_time "$val" ;;
      时区*) read -r -p "时区 (如 Asia/Shanghai): " val || continue
             [[ $val =~ ^[A-Za-z_/+-]+$ ]] || { warn "格式不正确"; continue; }
             ini_set_kv "$f" date.timezone "$val" ;;
      显示*) choose val "display_errors:" "Off (生产环境)" "On (调试)" || continue
             ini_set_kv "$f" display_errors "${val%% *}" ;;
      *) return 0 ;;
    esac
    systemctl restart "$(php_svc "$v")" && info "已生效"
  done
}

php_disable_functions() {
  pick_php_installed || return 1
  local v=$CHOSEN_PHP f c
  f=$(php_ini_file "$v")
  local list="passthru,exec,system,popen,proc_open,shell_exec"
  echo "当前: $(grep -E '^disable_functions' "$f" 2>/dev/null || echo '未设置 (未禁用)')"
  choose c "禁用危险函数 ($list):" "启用禁用 (更安全, 但部分程序/面板会受影响)" "取消禁用" || return 1
  touch "$f"
  if [[ $c == 启用* ]]; then ini_set_kv "$f" disable_functions "$list"
  else sed -i -E '/^disable_functions/d' "$f"; fi
  systemctl restart "$(php_svc "$v")" && info "已生效"
}

php_extensions() {
  pick_php_installed || return 1
  local v=$CHOSEN_PHP c ext pv
  pv=$(php_pkgver "$v")
  while true; do
    choose c "PHP $v 扩展:" "查看已加载扩展" "安装扩展" "返回" || return 0
    case $c in
      查看*) "$(php_bin "$v")" -m | tr '\n' ' ' | fold -s -w 70; echo ;;
      安装*)
        read -r -p "扩展名 (如 redis imagick gmp soap ldap): " ext || continue
        [[ $ext =~ ^[a-z0-9_]+$ ]] || { warn "扩展名格式不正确"; continue; }
        if [[ $PM == apt ]]; then pkg_install "php$v-$ext"
        else pkg_install "php${pv}-php-$ext" || pkg_install "php${pv}-php-pecl-$ext"; fi \
          && { systemctl restart "$(php_svc "$v")"; info "扩展 $ext 已安装"; } \
          || err "安装失败 (扩展名可能不存在于该版本源中)"
        ;;
      *) return 0 ;;
    esac
  done
}

php_fpm_tune() {
  pick_php_installed || return 1
  local v=$CHOSEN_PHP f n
  f=$(php_pool_file "$v")
  [[ -f $f ]] || { err "找不到 $f"; return 1; }
  echo "当前 pm 配置:"; grep -E '^(pm|pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers)\s*=' "$f" | sed 's/^/   /'
  read -r -p "设置 pm.max_children (建议 内存GB×8~12, 如 20): " n || return 1
  [[ $n =~ ^[0-9]+$ && $n -ge 2 && $n -le 1000 ]] || { err "请输入 2-1000 的数字"; return 1; }
  sed -i -E "s/^pm\.max_children\s*=.*/pm.max_children = $n/" "$f"
  sed -i -E "s/^pm\.start_servers\s*=.*/pm.start_servers = $((n / 4 > 2 ? n / 4 : 2))/" "$f"
  sed -i -E "s/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = $((n / 8 > 1 ? n / 8 : 1))/" "$f"
  sed -i -E "s/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = $((n / 2 > 3 ? n / 2 : 3))/" "$f"
  systemctl restart "$(php_svc "$v")" && info "PHP-FPM 进程数已调整并重启"
}

# ================================================================ 数据库
need_mysql() { command -v mysql >/dev/null 2>&1 || { err "还没安装 MariaDB, 请先在 [软件与环境] 里安装"; return 1; }; }

install_db() {
  info "安装 MariaDB ..."
  pkg_install mariadb-server || die "MariaDB 安装失败"
  systemctl enable --now mariadb
  info "MariaDB 已启动 (本机 root 直接执行 mysql 即可登录)"
}

db_names() { mysql -N -e "SHOW DATABASES" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'; }

db_list() {
  need_mysql || return 1
  echo "数据库列表:"
  db_names | sed 's/^/   /'
  [[ -n $(db_names) ]] || echo "   (空)"
}

pick_db() {  # -> DBNAME
  DBNAME=""
  need_mysql || return 1
  local n x i=0 c
  local -a arr=()
  while read -r n; do [[ -n $n ]] && arr+=("$n"); done < <(db_names)
  ((${#arr[@]})) || { warn "没有可用的数据库"; return 1; }
  echo "选择数据库:"
  for x in "${arr[@]}"; do i=$((i + 1)); printf "   %2d) %s\n" "$i" "$x"; done
  read -r -p "输入序号或名称: " c || return 1
  if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#arr[@]})); then DBNAME=${arr[c - 1]}; return 0; fi
  [[ " ${arr[*]} " == *" $c "* ]] && { DBNAME=$c; return 0; }
  err "无效选择"; return 1
}

db_create() {
  need_mysql || return 1
  local name=${1:-} user pw mode
  title "创建数据库"
  ask name "数据库名"
  [[ $name =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "名称只能含字母数字下划线, 最长 32"
  user=$name
  read -r -p "数据库用户名 [$name]: " user || user=""
  user=${user:-$name}
  [[ $user =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "用户名格式不正确"
  choose mode "密码:" "自动生成强密码" "我自己输入" || return 1
  if [[ $mode == 自动* ]]; then
    pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  else
    read_secret pw "密码 (8-64 位, 字母数字和 ._@#%+=-)"
    [[ $pw =~ ^[A-Za-z0-9._@#%+=-]{8,64}$ ]] || die "密码不符合要求"
  fi
  mysql -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
CREATE USER '$user'@'localhost' IDENTIFIED BY '$pw'; \
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$user'@'localhost'; FLUSH PRIVILEGES;" \
    || die "创建失败(库或用户可能已存在)"
  echo; info "数据库已创建"
  echo "  库名:   $name"
  echo "  用户:   $user"
  echo "  密码:   $pw"
  echo "  主机:   localhost"
}

db_drop() {
  pick_db || return 1
  local n=$DBNAME u
  read -r -p "同时删除的用户名 (默认同库名, 填 - 表示不删用户) [$n]: " u || u=""
  u=${u:-$n}
  confirm "确认删除数据库 $n ? 不可恢复" n || return 0
  mysql -e "DROP DATABASE \`$n\`;" || return 1
  if [[ $u != "-" && $u =~ ^[A-Za-z0-9_]{1,32}$ ]]; then mysql -e "DROP USER IF EXISTS '$u'@'localhost'; FLUSH PRIVILEGES;"; fi
  info "已删除"
}

db_passwd() {
  need_mysql || return 1
  local u pw mode
  read -r -p "要改密码的数据库用户名: " u || return 1
  [[ $u =~ ^[A-Za-z0-9_]{1,32}$ ]] || { err "用户名格式不正确"; return 1; }
  choose mode "新密码:" "自动生成强密码" "我自己输入" || return 1
  if [[ $mode == 自动* ]]; then pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  else read_secret pw "新密码 (8-64 位)"; [[ $pw =~ ^[A-Za-z0-9._@#%+=-]{8,64}$ ]] || { err "密码不符合要求"; return 1; }; fi
  mysql -e "ALTER USER '$u'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || return 1
  info "已修改, 新密码: $pw"
}

install_pma() {
  local domain="" root tmp secret
  need_mysql || return 1
  command -v nginx >/dev/null 2>&1 || { err "请先安装环境"; return 1; }
  echo "phpMyAdmin 建议绑定一个不容易被猜到的域名, 并开启 HTTPS 和访问密码。"
  ask domain "phpMyAdmin 使用的域名 (如 db.example.com)"
  valid_domain "$domain" || { err "域名格式不正确"; return 1; }
  [[ -f $(meta_file "$domain") ]] && { err "站点已存在"; return 1; }
  root=$WWW_ROOT/$domain
  tmp=$(mktemp -d)
  info "下载 phpMyAdmin ..."
  curl -fL --max-time 180 -o "$tmp/pma.tgz" https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz \
    || { rm -rf "$tmp"; err "下载失败, 请检查网络"; return 1; }
  mkdir -p "$root"
  tar -xzf "$tmp/pma.tgz" -C "$root" --strip-components=1 || { rm -rf "$tmp"; err "解压失败"; return 1; }
  rm -rf "$tmp"
  secret=$(openssl rand -hex 16)
  cp "$root/config.sample.inc.php" "$root/config.inc.php"
  sed -i "s/\(blowfish_secret'\] = \)'';/\1'$secret';/" "$root/config.inc.php"
  PRESET_ROOT=$root add_site php "$domain"
  info "安装完成。登录请使用 [数据库] 菜单里创建的用户 (MariaDB 的 root 无法直接登录 phpMyAdmin)"
  warn "建议到 [站点设置] 里给它加上 访问密码 或 IP 白名单"
}

# ================================================================ 备份 / 还原
backup_site() {  # backup_site [域名] [保留份数]
  use_site "${1:-}" || return 1
  local keep=${2:-7} f
  [[ -n $ROOT && -d $ROOT ]] || { warn "该站点没有网站目录可备份"; return 1; }
  mkdir -p "$BACKUP_DIR/site"
  f=$BACKUP_DIR/site/${DOMAIN}_$(date +%Y%m%d_%H%M%S).tar.gz
  tar -czf "$f" -C "$(dirname "$ROOT")" "$(basename "$ROOT")" || { err "备份失败"; return 1; }
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR/site/${DOMAIN}_"*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
  info "已备份: $f ($(du -h "$f" | cut -f1)), 保留最近 $keep 份"
}

backup_db() {  # backup_db 库名|--all [保留份数]
  need_mysql || return 1
  local target=${1:-} keep=${2:-7} n f
  if [[ -z $target ]]; then pick_db || return 1; target=$DBNAME; fi
  mkdir -p "$BACKUP_DIR/db"
  if [[ $target == --all ]]; then
    while read -r n; do [[ -n $n ]] && backup_db "$n" "$keep"; done < <(db_names)
    return 0
  fi
  [[ $target =~ ^[A-Za-z0-9_]{1,64}$ ]] || { err "库名格式不正确"; return 1; }
  f=$BACKUP_DIR/db/${target}_$(date +%Y%m%d_%H%M%S).sql.gz
  if mysqldump --single-transaction --routines "$target" | gzip > "$f"; then
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR/db/${target}_"*.sql.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
    info "已备份: $f ($(du -h "$f" | cut -f1)), 保留最近 $keep 份"
  else
    rm -f "$f"; err "备份失败: $target"; return 1
  fi
}

list_backups() {
  echo "网站备份 ($BACKUP_DIR/site):"; ls -lh "$BACKUP_DIR/site" 2>/dev/null | awk 'NR>1{print "   " $9 "  " $5}'
  echo "数据库备份 ($BACKUP_DIR/db):"; ls -lh "$BACKUP_DIR/db" 2>/dev/null | awk 'NR>1{print "   " $9 "  " $5}'
}

pick_file() {  # pick_file 目录 通配 -> PICKED_FILE
  PICKED_FILE=""
  local i=0 f c
  local -a arr=()
  while read -r f; do [[ -n $f ]] && arr+=("$f"); done < <(ls -1t "$1"/$2 2>/dev/null)
  ((${#arr[@]})) || { warn "没有找到备份文件"; return 1; }
  echo "选择备份文件 (新→旧):"
  for f in "${arr[@]}"; do i=$((i + 1)); printf "   %2d) %s\n" "$i" "$(basename "$f")"; done
  read -r -p "序号: " c || return 1
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#arr[@]})) || { err "无效选择"; return 1; }
  PICKED_FILE=${arr[c - 1]}
}

restore_site() {
  use_site "" || return 1
  [[ -n $ROOT ]] || { warn "该站点没有网站目录"; return 1; }
  pick_file "$BACKUP_DIR/site" "${DOMAIN}_*.tar.gz" || return 1
  confirm "将用 $(basename "$PICKED_FILE") 覆盖 $ROOT 中的同名文件, 继续?" n || return 0
  if [[ $TAMPER == 1 ]]; then
    chattr -R -i "$ROOT" 2>/dev/null; TAMPER=0; save_meta
    warn "网站原先处于防篡改锁定状态, 已临时解锁, 还原后请到 [网站防篡改] 重新锁定"
  fi
  tar -xzf "$PICKED_FILE" -C "$(dirname "$ROOT")" && fix_perms_dir "$ROOT" && info "还原完成"
}

restore_db() {
  pick_db || return 1
  pick_file "$BACKUP_DIR/db" "${DBNAME}_*.sql.gz" || return 1
  confirm "将用 $(basename "$PICKED_FILE") 覆盖数据库 $DBNAME 的数据, 继续?" n || return 0
  gunzip -c "$PICKED_FILE" | mysql "$DBNAME" && info "还原完成"
}

# ================================================================ 计划任务
tasks_init() {
  [[ -f $CRON_TASKS ]] || printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' > "$CRON_TASKS"
  chmod 644 "$CRON_TASKS"
}

tasks_list() {
  tasks_init
  echo "已有计划任务:"
  if grep -q '# wsm-task' "$CRON_TASKS"; then
    grep -n '# wsm-task' "$CRON_TASKS" | sed -E 's/ root / → /; s/ >> [^#]*//; s/# wsm-task//' | sed 's/^/   /'
  else echo "   (无)"; fi
}

tasks_add() {
  tasks_init
  local kind="" cmd="" freq="" h="" m="" expr="" keep="" target="" dow="" dom=""
  [[ -x $WSM_BIN ]] || self_install
  choose kind "任务类型:" "备份网站" "备份数据库" "备份全部数据库" "自定义 Shell 命令" || return 1
  case $kind in
    备份网站)
      pick_site "" || return 1
      read -r -p "保留最近几份 [7]: " keep || keep=""; keep=${keep:-7}
      cmd="$WSM_BIN backup-site $SITE $keep" ;;
    备份数据库)
      pick_db || return 1
      read -r -p "保留最近几份 [7]: " keep || keep=""; keep=${keep:-7}
      cmd="$WSM_BIN backup-db $DBNAME $keep" ;;
    备份全部*)
      read -r -p "保留最近几份 [7]: " keep || keep=""; keep=${keep:-7}
      cmd="$WSM_BIN backup-db --all $keep" ;;
    *)
      read -r -p "要执行的命令: " cmd || return 1
      [[ -n $cmd && $cmd != *'#'* ]] || { err "命令不能为空且不能含 #"; return 1; } ;;
  esac
  [[ $keep =~ ^[0-9]+$ || -z ${keep:-} ]] || { err "份数请输入数字"; return 1; }
  choose freq "执行频率:" "每天" "每周" "每月" "每隔 N 小时" || return 1
  case $freq in
    每隔*)
      read -r -p "每隔几小时 [6]: " h || h=""; h=${h:-6}
      [[ $h =~ ^[0-9]+$ && $h -ge 1 && $h -le 23 ]] || { err "请输入 1-23"; return 1; }
      expr="0 */$h * * *" ;;
    *)
      read -r -p "几点执行 (0-23) [3]: " h || h=""; h=${h:-3}
      read -r -p "第几分钟 (0-59) [30]: " m || m=""; m=${m:-30}
      [[ $h =~ ^[0-9]+$ && $h -le 23 && $m =~ ^[0-9]+$ && $m -le 59 ]] || { err "时间不合法"; return 1; }
      case $freq in
        每天) expr="$m $h * * *" ;;
        每周) read -r -p "星期几 (1=周一 ... 7=周日) [1]: " dow || dow=""; dow=${dow:-1}
              [[ $dow =~ ^[1-7]$ ]] || { err "请输入 1-7"; return 1; }
              expr="$m $h * * $((dow % 7))" ;;
        每月) read -r -p "每月几号 (1-28) [1]: " dom || dom=""; dom=${dom:-1}
              [[ $dom =~ ^[0-9]+$ && $dom -ge 1 && $dom -le 28 ]] || { err "请输入 1-28"; return 1; }
              expr="$m $h $dom * *" ;;
      esac ;;
  esac
  target=$expr
  printf '%s root %s >> /var/log/wsm-task.log 2>&1 # wsm-task\n' "$target" "$cmd" >> "$CRON_TASKS"
  info "已添加计划任务: [$expr] $cmd"
}

tasks_del() {
  tasks_list
  local n
  read -r -p "要删除的行号 (列表最前面的数字): " n || return 1
  [[ $n =~ ^[0-9]+$ ]] || { err "请输入数字"; return 1; }
  if sed -n "${n}p" "$CRON_TASKS" | grep -q '# wsm-task'; then sed -i "${n}d" "$CRON_TASKS"; info "已删除"
  else err "该行不是 wsm 任务"; fi
}

# ================================================================ 服务 / 软件
install_redis() {
  info "安装 Redis ..."
  if [[ $PM == apt ]]; then pkg_install redis-server || return 1; systemctl enable --now redis-server
  else pkg_install redis || return 1; systemctl enable --now redis; fi
  local v pv
  for v in $(php_installed | sort -V); do
    pv=$(php_pkgver "$v")
    if [[ $PM == apt ]]; then pkg_install "php$v-redis" >/dev/null 2>&1 || warn "PHP $v 的 redis 扩展安装失败"
    else pkg_install "php${pv}-php-pecl-redis*" >/dev/null 2>&1 || warn "PHP $v 的 redis 扩展安装失败"; fi
    systemctl restart "$(php_svc "$v")" 2>/dev/null || true
  done
  info "Redis 已安装并监听 127.0.0.1:6379, 已为已装的 PHP 版本加载 redis 扩展"
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then info "Composer 已安装: $(composer --version 2>/dev/null | head -1)"; return 0; fi
  pkg_install composer >/dev/null 2>&1 && { info "Composer 已安装"; return 0; }
  local php; php=$(command -v php || true)
  [[ -n $php ]] || { err "需要先安装 PHP"; return 1; }
  curl -fsSL https://getcomposer.org/installer | "$php" -- --install-dir=/usr/local/bin --filename=composer \
    && info "Composer 已安装" || err "安装失败, 请检查网络"
}

toggle_block_ip() {
  local f=$NGX_CONF/00-default.conf
  if [[ -f $f ]]; then
    confirm "当前已禁止 IP/未绑定域名访问, 是否恢复允许?" n || return 0
    rm -f "$f"; nginx_reload && info "已恢复"; return 0
  fi
  echo "开启后: 用 IP 或未绑定的域名访问服务器会被直接断开(返回 444), 可防止扫描和域名恶意解析。"
  confirm "开启禁止 IP / 未绑定域名访问?" y || return 0
  {
    echo "# managed by wsm"
    echo "server { listen 80 default_server;"
    [[ $HAS_V6 == 1 ]] && echo "  listen [::]:80 default_server;"
    echo "  server_name _; return 444; }"
    if ngx_ge 1.19.4; then
      echo "server { listen 443 ssl default_server;"
      [[ $HAS_V6 == 1 ]] && echo "  listen [::]:443 ssl default_server;"
      echo "  server_name _; ssl_reject_handshake on; }"
    else
      mkdir -p "$CERT_DIR/_default"
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=localhost" \
        -keyout "$CERT_DIR/_default/key.pem" -out "$CERT_DIR/_default/crt.pem" 2>/dev/null
      echo "server { listen 443 ssl default_server; server_name _;"
      echo "  ssl_certificate $CERT_DIR/_default/crt.pem; ssl_certificate_key $CERT_DIR/_default/key.pem; return 444; }"
    fi
  } > "$f"
  if nginx -t 2>/tmp/wsm_nginx_err; then systemctl reload nginx; info "已开启"
  else err "配置冲突, 已回滚:"; cat /tmp/wsm_nginx_err >&2; rm -f "$f"; fi
}

manage_service() {
  local x name act
  local -a svcs=("nginx")
  unit_exists mariadb && svcs+=("mariadb")
  unit_exists redis-server && svcs+=("redis-server")
  unit_exists redis && svcs+=("redis")
  for x in $(php_installed | sort -V); do svcs+=("$(php_svc "$x")"); done
  echo "服务状态:"
  for x in "${svcs[@]}"; do printf "   %-22s %s\n" "$x" "$(svc_state "$x")"; done
  choose name "选择服务:" "${svcs[@]}" || return 1
  choose act "操作:" "重启" "重载配置" "启动" "停止" "设为开机自启" "取消开机自启" "查看状态详情" || return 1
  case $act in
    重启) systemctl restart "$name" ;;
    重载*) systemctl reload "$name" ;;
    启动) systemctl start "$name" ;;
    停止) confirm "确认停止 $name ?" n && systemctl stop "$name" ;;
    设为*) systemctl enable "$name" ;;
    取消*) systemctl disable "$name" ;;
    *) systemctl status "$name" --no-pager -l | head -20 ;;
  esac
  echo "$name: $(svc_state "$name")"
}

self_install() {
  local me
  me=$(readlink -f "$0" 2>/dev/null || true)
  if [[ -f $me && $me != "$WSM_BIN" ]]; then
    install -m755 "$me" "$WSM_BIN" && info "已安装命令: wsm (之后直接输入 wsm 即可)"
  fi
}

cmd_install() {
  install_base
  local v=""
  read -r -p "安装哪些 PHP 版本? (${PHP_VERSIONS}; 多个用空格分隔, 输入 none 跳过) [8.3]: " v || v=""
  v=${v:-8.3}
  if [[ $v != none ]]; then
    for x in $v; do install_php "$x"; done
  fi
  confirm "安装 MariaDB 数据库?" y && install_db
  self_install
  echo
  info "环境安装完成!  输入 ${G}wsm${N} 进入管理菜单"
  warn "云服务器请在安全组放行 80 / 443 端口"
}

# ================================================================ 软件商店
APP_IDS=(nodejs pm2 python java git composer supervisor
         mariadb postgresql redis memcached phpmyadmin
         docker fail2ban rclone ffmpeg imagemagick monitor)

app_cat() {
  case $1 in
    nodejs|pm2|python|java|git|composer|supervisor) echo "开发与运行环境" ;;
    mariadb|postgresql|redis|memcached|phpmyadmin) echo "数据库与缓存" ;;
    *) echo "系统与工具" ;;
  esac
}
app_name() {
  case $1 in
    nodejs) echo "Node.js" ;; pm2) echo "PM2" ;; python) echo "Python3" ;; java) echo "Java (JRE)" ;;
    git) echo "Git" ;; composer) echo "Composer" ;; supervisor) echo "Supervisor" ;;
    mariadb) echo "MariaDB" ;; postgresql) echo "PostgreSQL" ;; redis) echo "Redis" ;;
    memcached) echo "Memcached" ;; phpmyadmin) echo "phpMyAdmin" ;;
    docker) echo "Docker" ;; fail2ban) echo "Fail2ban" ;; rclone) echo "Rclone" ;;
    ffmpeg) echo "FFmpeg" ;; imagemagick) echo "ImageMagick" ;; monitor) echo "监控工具包" ;;
  esac
}
app_desc() {
  case $1 in
    nodejs) echo "JS 运行环境 + npm" ;; pm2) echo "Node 项目进程守护" ;;
    python) echo "Python3 + pip + venv" ;; java) echo "OpenJDK 运行环境" ;;
    git) echo "代码版本管理" ;; composer) echo "PHP 依赖管理" ;;
    supervisor) echo "通用进程守护(队列等)" ;;
    mariadb) echo "MySQL 兼容数据库" ;; postgresql) echo "PostgreSQL 数据库" ;;
    redis) echo "内存缓存 / 队列" ;; memcached) echo "内存缓存" ;;
    phpmyadmin) echo "网页管理数据库" ;;
    docker) echo "容器运行环境" ;; fail2ban) echo "防暴力破解(SSH/站点密码)" ;;
    rclone) echo "云存储同步 / 异地备份" ;; ffmpeg) echo "音视频处理" ;;
    imagemagick) echo "图片处理命令行" ;; monitor) echo "htop iotop iftop nload" ;;
  esac
}
app_installed() {
  case $1 in
    nodejs) command -v node >/dev/null 2>&1 ;;
    pm2) command -v pm2 >/dev/null 2>&1 ;;
    python) command -v python3 >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1 ;;
    java) command -v java >/dev/null 2>&1 ;;
    git) command -v git >/dev/null 2>&1 ;;
    composer) command -v composer >/dev/null 2>&1 ;;
    supervisor) command -v supervisord >/dev/null 2>&1 ;;
    mariadb) command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1 ;;
    postgresql) command -v psql >/dev/null 2>&1 ;;
    redis) command -v redis-server >/dev/null 2>&1 ;;
    memcached) command -v memcached >/dev/null 2>&1 ;;
    phpmyadmin) compgen -G "$WWW_ROOT/*/config.sample.inc.php" >/dev/null 2>&1 ;;
    docker) command -v docker >/dev/null 2>&1 ;;
    fail2ban) command -v fail2ban-client >/dev/null 2>&1 ;;
    rclone) command -v rclone >/dev/null 2>&1 ;;
    ffmpeg) command -v ffmpeg >/dev/null 2>&1 ;;
    imagemagick) command -v convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 ;;
    monitor) command -v htop >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
app_version() {
  case $1 in
    nodejs) echo "$(node -v 2>/dev/null) / npm $(npm -v 2>/dev/null)" ;;
    pm2) pm2 -v 2>/dev/null | tail -1 ;;
    python) python3 --version 2>&1 ;;
    java) java -version 2>&1 | head -1 ;;
    git) git --version ;;
    composer) composer --version 2>/dev/null | head -1 ;;
    supervisor) supervisord -v 2>/dev/null ;;
    mariadb) (mariadbd --version 2>/dev/null || mysqld --version 2>/dev/null) | head -1 ;;
    postgresql) psql --version ;;
    redis) redis-server --version | awk '{print $3}' ;;
    memcached) memcached -V ;;
    phpmyadmin) echo "(以站点形式安装)" ;;
    docker) docker --version ;;
    fail2ban) fail2ban-client --version 2>/dev/null | head -1 ;;
    rclone) rclone version 2>/dev/null | head -1 ;;
    ffmpeg) ffmpeg -version 2>/dev/null | head -1 ;;
    imagemagick) (convert -version 2>/dev/null || magick -version 2>/dev/null) | head -1 ;;
    monitor) htop --version 2>/dev/null | head -1 ;;
  esac
}
app_service() {  # 输出该软件对应的 systemd 服务名(没有则为空)
  case $1 in
    mariadb) echo mariadb ;; postgresql) echo postgresql ;; memcached) echo memcached ;;
    docker) echo docker ;; fail2ban) echo fail2ban ;;
    redis) if unit_exists redis-server; then echo redis-server; else echo redis; fi ;;
    supervisor) if unit_exists supervisor; then echo supervisor; else echo supervisord; fi ;;
  esac
  return 0
}
app_valid() { local x; for x in "${APP_IDS[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

pkg_refresh() {
  if [[ $PM == apt && -z ${PKG_REFRESHED:-} ]]; then apt-get update -y >/dev/null 2>&1; PKG_REFRESHED=1; fi
  return 0
}
pkg_remove() {
  if [[ $PM == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
  else dnf remove -y "$@"; fi
}
confirm_typed() { local a; read -r -p "$1 (输入 yes-delete 确认): " a || return 1; [[ $a == yes-delete ]]; }

install_nodejs() {
  local v
  pkg_refresh
  if [[ $PM == apt ]]; then
    choose v "选择 Node.js 版本 (以 NodeSource 实际提供为准):" \
      "24 (LTS, 推荐)" "22 (LTS 维护期)" "系统自带版本 (最稳, 但版本较旧)" || return 1
    if [[ $v == 系统* ]]; then
      pkg_install nodejs npm || return 1
    else
      v=${v%% *}
      pkg_install ca-certificates curl gnupg || return 1
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg \
        || { err "下载 NodeSource 密钥失败, 请检查网络"; return 1; }
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${v}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
      apt-get update -y >/dev/null 2>&1; PKG_REFRESHED=1
      pkg_install nodejs || return 1
    fi
  else
    pkg_install nodejs npm || return 1
  fi
  info "Node.js 已安装: $(node -v) / npm $(npm -v 2>/dev/null)"
}

install_pm2() {
  command -v npm >/dev/null 2>&1 || { info "PM2 依赖 Node.js, 先安装 Node.js"; install_nodejs || return 1; }
  npm install -g pm2 || { err "PM2 安装失败"; return 1; }
  pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
  info "PM2 已安装 (已设为开机自启)"
  echo "  用法: pm2 start app.js --name myapp  →  pm2 save  →  pm2 list"
  echo "  配合 [反向代理站点] 把域名指向项目端口即可对外访问"
}

install_python() {
  pkg_refresh
  if [[ $PM == apt ]]; then pkg_install python3 python3-pip python3-venv || return 1
  else pkg_install python3 python3-pip || return 1; fi
  info "已安装: $(python3 --version)  (项目建议用 python3 -m venv 建虚拟环境)"
}

install_java() {
  pkg_refresh
  if [[ $PM == apt ]]; then pkg_install default-jre-headless || return 1
  else pkg_install java-17-openjdk-headless || return 1; fi
  info "已安装: $(java -version 2>&1 | head -1)"
}

install_supervisor() {
  pkg_refresh
  pkg_install supervisor || return 1
  systemctl enable --now "$(app_service supervisor)"
  info "Supervisor 已启动, 配置目录: /etc/supervisor/conf.d/ (RHEL: /etc/supervisord.d/)"
}

install_postgresql() {
  pkg_refresh
  if [[ $PM == apt ]]; then pkg_install postgresql postgresql-contrib || return 1
  else
    pkg_install postgresql-server postgresql-contrib || return 1
    postgresql-setup --initdb >/dev/null 2>&1 || true
  fi
  systemctl enable --now postgresql
  local v pv
  for v in $(php_installed | sort -V); do
    pv=$(php_pkgver "$v")
    if [[ $PM == apt ]]; then pkg_install "php$v-pgsql" >/dev/null 2>&1 || warn "PHP $v 的 pgsql 扩展安装失败"
    else pkg_install "php${pv}-php-pgsql" >/dev/null 2>&1 || warn "PHP $v 的 pgsql 扩展安装失败"; fi
    systemctl restart "$(php_svc "$v")" 2>/dev/null || true
  done
  info "PostgreSQL 已安装 ($(psql --version))"
  echo "  建库建用户: sudo -u postgres createuser -P 用户名 ; sudo -u postgres createdb -O 用户名 库名"
}

install_memcached() {
  pkg_refresh
  pkg_install memcached || return 1
  systemctl enable --now memcached
  local v pv
  for v in $(php_installed | sort -V); do
    pv=$(php_pkgver "$v")
    if [[ $PM == apt ]]; then pkg_install "php$v-memcached" >/dev/null 2>&1 || warn "PHP $v 的 memcached 扩展安装失败"
    else pkg_install "php${pv}-php-pecl-memcached" >/dev/null 2>&1 || warn "PHP $v 的 memcached 扩展安装失败"; fi
    systemctl restart "$(php_svc "$v")" 2>/dev/null || true
  done
  info "Memcached 已启动, 监听 127.0.0.1:11211"
}

install_docker() {
  [[ $PM == apt ]] || { err "Docker 目前只支持 Debian / Ubuntu"; return 1; }
  pkg_refresh
  pkg_install docker.io || return 1
  pkg_install docker-compose-v2 >/dev/null 2>&1 || pkg_install docker-compose >/dev/null 2>&1 \
    || warn "docker compose 未能安装 (可忽略, 需要时再装)"
  systemctl enable --now docker
  info "Docker 已安装: $(docker --version)"
  warn "容器映射的端口会绕过 ufw 直接对外开放, 数据库等服务请绑定 127.0.0.1"
}

fail2ban_conf() {  # fail2ban_conf 输出文件
  local f=$1 ip=${SSH_CLIENT:-}
  ip=${ip%% *}
  valid_ip "$ip" || ip=""
  mkdir -p "$(dirname "$f")"
  {
    echo "# managed by wsm"
    echo "[DEFAULT]"
    echo "bantime  = 1h"
    echo "findtime = 10m"
    echo "maxretry = 5"
    echo "ignoreip = 127.0.0.1/8 ::1${ip:+ $ip}"
    echo
    echo "[sshd]"
    echo "enabled = true"
    echo
    echo "[nginx-http-auth]"
    echo "enabled = true"
    echo "port    = http,https"
    echo "logpath = /var/log/nginx/*error.log"
  } > "$f"
}

install_fail2ban() {
  pkg_refresh
  pkg_install fail2ban || return 1
  fail2ban_conf /etc/fail2ban/jail.d/wsm.local
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  sleep 1
  info "Fail2ban 已启动: SSH 连续输错 5 次封 1 小时, 站点访问密码同理"
  echo "  已自动把你当前的登录 IP 加入白名单, 避免误封自己"
  echo "  查看: fail2ban-client status sshd   解封: fail2ban-client set sshd unbanip <IP>"
}

install_ffmpeg() {
  pkg_refresh
  if [[ $PM == apt ]]; then pkg_install ffmpeg || return 1
  else err "RHEL 系需要先启用 RPM Fusion 源, 请手动安装 ffmpeg"; return 1; fi
  info "已安装: $(ffmpeg -version 2>/dev/null | head -1)"
}

app_install() {
  app_valid "${1:-}" || { err "未知软件: ${1:-}"; return 1; }
  pkg_refresh
  case $1 in
    nodejs) install_nodejs ;;
    pm2) install_pm2 ;;
    python) install_python ;;
    java) install_java ;;
    git) pkg_install git && info "Git 已安装: $(git --version)" ;;
    composer) install_composer ;;
    supervisor) install_supervisor ;;
    mariadb) install_db ;;
    postgresql) install_postgresql ;;
    redis) install_redis ;;
    memcached) install_memcached ;;
    phpmyadmin) install_pma ;;
    docker) install_docker ;;
    fail2ban) install_fail2ban ;;
    rclone) pkg_install rclone && info "Rclone 已安装, 运行 rclone config 配置云存储" ;;
    ffmpeg) install_ffmpeg ;;
    imagemagick)
      if [[ $PM == apt ]]; then pkg_install imagemagick; else pkg_install ImageMagick; fi \
        && info "ImageMagick 已安装" ;;
    monitor) pkg_install htop iotop iftop nload && info "已安装 htop / iotop / iftop / nload" ;;
  esac
}

app_uninstall() {
  app_valid "${1:-}" || { err "未知软件: ${1:-}"; return 1; }
  local svc; svc=$(app_service "$1")
  case $1 in
    nodejs) pkg_remove nodejs; pkg_remove npm 2>/dev/null; rm -f /etc/apt/sources.list.d/nodesource.list ;;
    pm2) npm rm -g pm2; systemctl disable pm2-root >/dev/null 2>&1; rm -f /etc/systemd/system/pm2-root.service ;;
    python) warn "Python3 是系统组件, 只卸载 pip 和 venv"; if [[ $PM == apt ]]; then pkg_remove python3-pip python3-venv; else pkg_remove python3-pip; fi ;;
    java) if [[ $PM == apt ]]; then pkg_remove default-jre-headless; else pkg_remove java-17-openjdk-headless; fi ;;
    git) pkg_remove git ;;
    composer) rm -f /usr/local/bin/composer; pkg_remove composer 2>/dev/null ;;
    supervisor) pkg_remove supervisor ;;
    mariadb)
      warn "卸载 MariaDB 后, 依赖它的网站会无法连接数据库 (数据文件仍保留在 /var/lib/mysql)"
      confirm_typed "确认卸载 MariaDB" || return 0
      systemctl stop mariadb; pkg_remove mariadb-server mariadb-client ;;
    postgresql)
      warn "卸载 PostgreSQL 后依赖它的程序会失效 (数据文件会保留)"
      confirm_typed "确认卸载 PostgreSQL" || return 0
      systemctl stop postgresql; pkg_remove postgresql postgresql-contrib ;;
    redis) systemctl stop "$svc"; if [[ $PM == apt ]]; then pkg_remove redis-server; else pkg_remove redis; fi ;;
    memcached) systemctl stop memcached; pkg_remove memcached ;;
    phpmyadmin) warn "phpMyAdmin 就是一个普通 PHP 站点, 请到 [网站管理] → [删除站点] 里删除它"; return 0 ;;
    docker)
      warn "卸载 Docker 不会删除镜像和容器数据 (/var/lib/docker)"
      confirm_typed "确认卸载 Docker" || return 0
      systemctl stop docker; pkg_remove docker.io docker-compose docker-compose-v2 2>/dev/null || pkg_remove docker.io ;;
    fail2ban) systemctl stop fail2ban; rm -f /etc/fail2ban/jail.d/wsm.local; pkg_remove fail2ban ;;
    rclone) pkg_remove rclone ;;
    ffmpeg) pkg_remove ffmpeg ;;
    imagemagick) if [[ $PM == apt ]]; then pkg_remove imagemagick; else pkg_remove ImageMagick; fi ;;
    monitor) pkg_remove htop iotop iftop nload ;;
  esac
  info "$(app_name "$1") 已卸载 (配置文件按系统习惯保留)"
}

app_manage() {
  local id=$1 c svc
  local -a opts
  while true; do
    title "$(app_name "$id")"
    echo "  简介: $(app_desc "$id")"
    svc=$(app_service "$id")
    if app_installed "$id"; then
      echo "  状态: ${G}已安装${N}   版本: $(app_version "$id")"
      opts=("重新安装 / 更新" "卸载")
      if [[ -n $svc ]] && unit_exists "$svc"; then
        echo "  服务: $svc $(svc_state "$svc")"
        opts+=("启动" "停止" "重启")
      fi
    else
      echo "  状态: ${Y}未安装${N}"
      opts=("安装")
    fi
    opts+=("返回")
    choose c "操作:" "${opts[@]}" || return 0
    case $c in
      安装|重新*) ( app_install "$id" ); pause ;;
      卸载) ( app_uninstall "$id" ); pause ;;
      启动) systemctl start "$svc" && info "已启动" ;;
      停止) confirm "确认停止 $svc ?" n && systemctl stop "$svc" && info "已停止" ;;
      重启) systemctl restart "$svc" && info "已重启" ;;
      *) return 0 ;;
    esac
  done
}

app_list() {
  local id st
  printf "%-12s %-14s %-8s %s\n" "ID" "名称" "状态" "简介"
  for id in "${APP_IDS[@]}"; do
    if app_installed "$id"; then st="已安装"; else st="未安装"; fi
    printf "%-12s %-14s %-8s %s\n" "$id" "$(app_name "$id")" "$st" "$(app_desc "$id")"
  done
}

menu_store() {
  local c i id cat last st
  while true; do
    title "软件商店"
    i=0; last=""
    for id in "${APP_IDS[@]}"; do
      i=$((i + 1))
      cat=$(app_cat "$id")
      if [[ $cat != "$last" ]]; then echo; echo "  ${B}${cat}${N}"; last=$cat; fi
      if app_installed "$id"; then st="${G}已装${N}"; else st="${D}未装${N}"; fi
      printf "  %2d) " "$i"; pad_w "$(app_name "$id")" 16; echo "$st"
    done
    echo
    read -r -p "输入序号 (回车返回): " c || return 0
    [[ -z $c || $c == 0 || $c == q ]] && return 0
    if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#APP_IDS[@]})); then app_manage "${APP_IDS[c - 1]}"
    else warn "无效选择"; fi
  done
}

# ================================================================ SFTP 账号
# 原理: 复用系统自带的 OpenSSH (internal-sftp + chroot), 不新增任何常驻进程。
#       每个账号被关进 /www/sftp/<用户>/ , 里面只挂载(bind)对应网站目录, 看不到系统其他文件。
#       账号用户 ID 与 Web 运行用户相同, 上传的文件天然属于网站用户, 不会有权限问题。
SFTP_DIR=$WSM_DIR/sftp
SFTP_HOME=/www/sftp
SFTP_GROUP=wsm-sftp
SFTP_MAIN=/etc/ssh/sshd_config
SFTP_DROPIN=/etc/ssh/sshd_config.d/99-wsm-sftp.conf
SFTP_MARK="# wsm-sftp"

sshd_service() { if unit_exists ssh; then echo ssh; else echo sshd; fi; }

sftp_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
  echo "${p:-22}"
}

sftp_block() {
  cat <<'EOS'
Match Group wsm-sftp
    ChrootDirectory %h
    ForceCommand internal-sftp -u 022
    PasswordAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
EOS
}

sftp_ensure_conf() {
  command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || { err "没有检测到 OpenSSH 服务端 (sshd), 请先安装 openssh-server"; return 1; }
  getent group "$SFTP_GROUP" >/dev/null 2>&1 || groupadd "$SFTP_GROUP" || return 1
  mkdir -p "$SFTP_HOME" "$SFTP_DIR"
  chown root:root "$SFTP_HOME"; chmod 755 "$SFTP_HOME"
  local main=$SFTP_MAIN bak
  [[ -f $main ]] || { err "找不到 $main, 无法配置 SFTP"; return 1; }
  [[ -f $SFTP_DROPIN ]] && return 0
  grep -qs "^$SFTP_MARK begin" "$main" && return 0
  bak=$(mktemp); cp -a "$main" "$bak"
  if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$main"; then
    mkdir -p "$(dirname "$SFTP_DROPIN")"
    sftp_block > "$SFTP_DROPIN"
  else
    { echo; echo "$SFTP_MARK begin"; sftp_block; echo "$SFTP_MARK end"; } >> "$main"
  fi
  if ! sshd -t 2>/dev/null; then
    rm -f "$SFTP_DROPIN"; cp -a "$bak" "$main"; rm -f "$bak"
    err "sshd 配置检测未通过, 已自动回滚 (没有改动 SSH)"; return 1
  fi
  rm -f "$bak"
  systemctl reload "$(sshd_service)" 2>/dev/null || systemctl restart "$(sshd_service)" 2>/dev/null || true
  info "已启用 SFTP 隔离配置 (已重载 SSH, 当前登录不受影响)"
}

sftp_default_user() {
  local u
  u=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_')
  u="s_${u}"
  echo "${u:0:32}"
}

sftp_gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16; }

sftp_ask_pw() {  # -> SFTP_PW
  local mode
  choose mode "密码:" "自动生成强密码" "我自己输入" || return 1
  if [[ $mode == 自动* ]]; then SFTP_PW=$(sftp_gen_pw)
  else
    read_secret SFTP_PW "密码 (8-64 位, 字母数字和 ._@#%+=-)"
    [[ $SFTP_PW =~ ^[A-Za-z0-9._@#%+=-]{8,64}$ ]] || { err "密码不符合要求"; return 1; }
  fi
}

sftp_add() {
  use_site "" || return 1
  need_type php static || return 1
  [[ -d $ROOT ]] || { err "网站目录不存在: $ROOT"; return 1; }
  local d=$DOMAIN root=$ROOT u def perm home opt uid gid shell
  sftp_ensure_conf || return 1
  def=$(sftp_default_user "$d")
  read -r -p "SFTP 用户名 [$def]: " u || return 1
  u=${u:-$def}
  [[ $u =~ ^[a-z][a-z0-9_]{2,31}$ ]] || { err "用户名: 小写字母开头, 3-32 位小写字母/数字/下划线"; return 1; }
  id "$u" >/dev/null 2>&1 && { err "系统里已存在用户 $u"; return 1; }
  choose perm "权限:" "读写 (可上传 / 修改 / 删除)" "只读 (只能查看 / 下载)" || return 1
  sftp_ask_pw || return 1
  home=$SFTP_HOME/$u
  uid=$(id -u "$WEB_USER"); gid=$(id -g "$WEB_USER")
  shell=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
  mkdir -p "$home/www"
  chown root:root "$home"; chmod 755 "$home"
  if ! useradd -o -u "$uid" -g "$gid" -G "$SFTP_GROUP" -d "$home" -M -s "$shell" "$u"; then
    rmdir "$home/www" "$home" 2>/dev/null; err "创建用户失败"; return 1
  fi
  echo "$u:$SFTP_PW" | chpasswd || { userdel -f "$u" 2>/dev/null; rmdir "$home/www" "$home" 2>/dev/null; err "设置密码失败"; return 1; }
  opt=bind; [[ $perm == 只读* ]] && opt=bind,ro
  if ! mount --bind "$root" "$home/www"; then
    userdel -f "$u" 2>/dev/null; rmdir "$home/www" "$home" 2>/dev/null; err "挂载网站目录失败"; return 1
  fi
  [[ $opt == bind,ro ]] && mount -o remount,bind,ro "$home/www" 2>/dev/null
  printf '%s %s none %s 0 0\n' "$root" "$home/www" "$opt" >> /etc/fstab
  systemctl daemon-reload >/dev/null 2>&1 || true
  {
    printf 'DOMAIN=%q\n' "$d"
    printf 'ROOT=%q\n' "$root"
    printf 'PERM=%q\n' "$([[ $opt == bind,ro ]] && echo ro || echo rw)"
  } > "$SFTP_DIR/$u.conf"
  echo; info "SFTP 账号已创建"
  echo "  协议:   SFTP (不是 FTP)"
  echo "  地址:   $(public_ip_cached)"
  echo "  端口:   $(sftp_port)  (就是 SSH 端口)"
  echo "  用户:   $u"
  echo "  密码:   $SFTP_PW"
  echo "  权限:   $([[ $opt == bind,ro ]] && echo 只读 || echo 读写)"
  echo "  登录后: 看到的 /www 目录就是网站根目录 ($d)"
  echo
  echo "  客户端: FileZilla / Xftp / WinSCP / 手机 Termius 均可, 选择 SFTP 协议"
  [[ $TAMPER == 1 ]] && warn "该网站处于防篡改锁定状态, 账号暂时无法写入; 需要时先到 [网站防篡改] 临时解锁"
  return 0
}

sftp_users() {
  local f
  for f in "$SFTP_DIR"/*.conf; do [[ -e $f ]] && basename "$f" .conf; done
  return 0
}

sftp_list() {
  local u n=0
  printf "%-18s %-20s %s\n" "用户" "网站" "权限"
  while read -r u; do
    [[ -n $u ]] || continue
    n=$((n + 1))
    ( # shellcheck disable=SC1090
      DOMAIN=""; PERM=rw; source "$SFTP_DIR/$u.conf"
      printf "%-18s %-20s %s%s\n" "${u:0:17}" "${DOMAIN:0:19}" "$([[ $PERM == ro ]] && echo 只读 || echo 读写)" \
        "$(mountpoint -q "$SFTP_HOME/$u/www" 2>/dev/null || echo '  (未挂载!)')"
    )
  done < <(sftp_users)
  ((n)) || echo "(还没有 SFTP 账号)"
  return 0
}

sftp_pick_user() {  # -> SFTP_USER
  SFTP_USER=""
  local u i=0 c
  local -a arr=()
  while read -r u; do [[ -n $u ]] && arr+=("$u"); done < <(sftp_users)
  ((${#arr[@]})) || { warn "还没有 SFTP 账号"; return 1; }
  echo "选择账号:"
  for u in "${arr[@]}"; do i=$((i + 1)); printf "   %2d) %s\n" "$i" "$u"; done
  read -r -p "输入序号或用户名 (回车取消): " c || return 1
  [[ -z $c ]] && return 1
  if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#arr[@]})); then SFTP_USER=${arr[c - 1]}; return 0; fi
  [[ " ${arr[*]} " == *" $c "* ]] && { SFTP_USER=$c; return 0; }
  err "无效选择"; return 1
}

sftp_passwd() {
  sftp_pick_user || return 1
  sftp_ask_pw || return 1
  echo "$SFTP_USER:$SFTP_PW" | chpasswd || { err "修改失败"; return 1; }
  info "已修改 $SFTP_USER 的密码: $SFTP_PW"
}

sftp_remove_user() {  # 只卸载挂载点并删除账号, 绝不删除网站文件
  local u=$1 home=$SFTP_HOME/$1
  [[ $u =~ ^[a-z][a-z0-9_]{2,31}$ ]] || return 1
  if mountpoint -q "$home/www" 2>/dev/null; then
    umount "$home/www" 2>/dev/null || umount -l "$home/www" 2>/dev/null \
      || { err "卸载 $home/www 失败, 已中止 (未删除任何文件)"; return 1; }
  fi
  sed -i "\\|^[^ ]* $home/www |d" /etc/fstab
  systemctl daemon-reload >/dev/null 2>&1 || true
  if id "$u" >/dev/null 2>&1; then userdel -f "$u" >/dev/null 2>&1 || true; fi
  id "$u" >/dev/null 2>&1 && { err "账号 $u 删除失败"; return 1; }
  rmdir "$home/www" "$home" 2>/dev/null
  rm -f "$SFTP_DIR/$u.conf"
  return 0
}

sftp_del() {
  sftp_pick_user || return 1
  confirm "删除 SFTP 账号 $SFTP_USER ? (网站文件不会被删除)" n || return 0
  sftp_remove_user "$SFTP_USER" && info "已删除 $SFTP_USER"
}

sftp_purge_domain() {  # 删除站点时调用: 清理该站点的全部 SFTP 账号
  local u
  while read -r u; do
    [[ -n $u ]] || continue
    if ( DOMAIN=""; source "$SFTP_DIR/$u.conf"; [[ $DOMAIN == "$1" ]] ); then sftp_remove_user "$u" >/dev/null; fi
  done < <(sftp_users)
  return 0
}

sftp_menu() {
  local c
  while true; do
    title "SFTP 账号"
    echo "  复用系统 SSH, 不增加常驻进程; 每个账号只能看到自己的网站目录"
    choose c "操作:" "添加账号" "账号列表" "修改密码" "删除账号" "返回" || return 0
    case $c in
      添加*) (sftp_add); pause ;;
      账号*) sftp_list; pause ;;
      修改*) (sftp_passwd); pause ;;
      删除*) (sftp_del); pause ;;
      *) return 0 ;;
    esac
  done
}

# ================================================================ WordPress 一键部署
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
  ask domain "① 网站域名 (如 blog.example.com)"
  valid_domain "$domain" || die "域名格式不正确: $domain"
  [[ -f $(meta_file "$domain") ]] && die "站点已存在: $domain"
  v=$(domain_used "$domain") && die "域名 $domain 已被站点 $v 使用"
  root=$WWW_ROOT/$domain
  safe_root "$root" || die "网站目录不合法: $root"
  if [[ -d $root && -n $(ls -A "$root" 2>/dev/null) ]]; then
    die "目录 $root 里已有文件, 请换一个域名或先清空该目录"
  fi
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

# ================================================================ 访问统计
# 只在你打开时临时分析 nginx 日志, 不常驻、不占资源
declare -A ST=()
STAT_TMP=""
STAT_AWK=$(cat <<'AWK'
BEGIN {
  FS = "\""
  n = split(dates, dl, "|")
  for (i = 1; i <= n; i++) ok[dl[i]] = 1
  filt = (dates != "")
}
{
  split($1, a, " ")
  ts = a[4]
  if (filt && !(substr(ts, 2, 11) in ok)) next
  ip = a[1]
  split($2, r, " ")
  url = r[2]
  q = index(url, "?"); if (q) url = substr(url, 1, q - 1)
  split($3, s, " ")
  st = s[1] + 0; by = s[2] + 0
  tot++; bytes += by; ips[ip]++
  cls[int(st / 100)]++
  hr[substr(ts, 14, 2)]++
  if (url ~ /\.(css|js|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map|mp4|mp3)$/) {
    nstatic++
  } else {
    pv++
    if (st < 400) page[url]++
  }
  if (st == 404) nf[url]++
  ual = tolower($6)
  if (ual ~ /googlebot/) sp["Google"]++
  else if (ual ~ /baiduspider/) sp["Baidu"]++
  else if (ual ~ /bingbot/) sp["Bing"]++
  else if (ual ~ /yandex/) sp["Yandex"]++
  else if (ual ~ /sogou/) sp["Sogou"]++
  else if (ual ~ /360spider|haosouspider/) sp["360"]++
  else if (ual ~ /bytespider/) sp["Byte"]++
  else if (ual ~ /bot|spider|crawl|slurp|python-requests|go-http|wget|curl/) sp["Other"]++
  rf = $4
  if (rf != "-" && rf != "") {
    sub(/^https?:\/\//, "", rf); sub(/[\/?].*/, "", rf)
    if (rf != "" && rf != dom) ref[rf]++
  }
}
END {
  uv = 0; for (k in ips) uv++
  printf "S\ttot\t%d\nS\tpv\t%d\nS\tuv\t%d\nS\tbytes\t%.0f\n", tot, pv, uv, bytes
  for (c = 2; c <= 5; c++) printf "S\tc%d\t%d\n", c, cls[c] + 0
  for (k in ips) printf "ip\t%d\t%s\n", ips[k], k
  for (k in page) printf "url\t%d\t%s\n", page[k], k
  for (k in nf) printf "nf\t%d\t%s\n", nf[k], k
  for (k in ref) printf "ref\t%d\t%s\n", ref[k], k
  for (k in sp) printf "sp\t%d\t%s\n", sp[k], k
  for (k in hr) printf "hr\t%d\t%s\n", hr[k], k
}
AWK
)

hb() {  # 字节数 -> 易读
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}; if(i==1)printf "%d%s",b,u[i]; else printf "%.1f%s",b,u[i]}'
}

stat_dates() {  # 1=今天 y=昨天 N=最近N天 all=不限
  local n=$1 i out=""
  case $n in
    all) echo ""; return ;;
    y) LC_ALL=C date -d "-1 day" +%d/%b/%Y; return ;;
  esac
  for ((i = 0; i < n; i++)); do out+="$(LC_ALL=C date -d "-$i day" +%d/%b/%Y)|"; done
  echo "${out%|}"
}

stat_stream() {  # stat_stream 域名 范围
  local f=/var/log/nginx/$1.access.log x
  if [[ $2 != 1 ]]; then
    for x in "$f".[0-9]*; do
      [[ -e $x ]] || continue
      case $x in *.gz) zcat "$x" 2>/dev/null ;; *) cat "$x" ;; esac
    done
  fi
  [[ -e $f ]] && cat "$f"
  return 0
}

stat_collect() {  # stat_collect 域名 范围 -> 填充 ST[] 和 $STAT_TMP
  local d=$1 range=$2 dates t k v
  dates=$(stat_dates "$range")
  STAT_TMP=$(mktemp)
  stat_stream "$d" "$range" | awk -v dates="$dates" -v dom="$d" "$STAT_AWK" > "$STAT_TMP"
  ST=()
  while IFS=$'\t' read -r t k v; do [[ $t == S ]] && ST[$k]=$v; done < "$STAT_TMP"
}

stat_top() {  # stat_top 标签 条数
  local c k
  awk -F'\t' -v t="$1" '$1==t{print $2"\t"$3}' "$STAT_TMP" | sort -t$'\t' -k1,1nr | head -n "$2" |
  while IFS=$'\t' read -r c k; do
    if ((${#k} > 28)); then k="${k:0:27}.."; fi
    printf '  %7s  %s\n' "$c" "$k"
  done
}

stat_range_pick() {  # -> STAT_RANGE STAT_RANGE_NAME
  local r
  choose r "统计范围:" "今天" "昨天" "最近 7 天" "最近 30 天" "全部日志" || return 1
  case $r in
    今天) STAT_RANGE=1 ;; 昨天) STAT_RANGE=y ;; 最近\ 7*) STAT_RANGE=7 ;;
    最近\ 30*) STAT_RANGE=30 ;; *) STAT_RANGE=all ;;
  esac
  STAT_RANGE_NAME=$r
}

stat_show() {  # stat_show 域名 范围 范围名
  local d=$1 range=$2 rname=${3:-} max=0 c h t bar n
  [[ -e /var/log/nginx/$d.access.log ]] || { warn "暂无访问日志"; return 1; }
  stat_collect "$d" "$range"
  title "访问统计 · $d"
  echo "  范围: $rname"
  if ((${ST[tot]:-0} == 0)); then echo "  (这个时间段没有访问记录)"; rm -f "$STAT_TMP"; return 0; fi
  printf '  '; pad_w "总请求" 12; printf '%s\n' "${ST[tot]}"
  printf '  '; pad_w "页面访问 PV" 12; printf '%s\n' "${ST[pv]}"
  printf '  '; pad_w "独立 IP" 12; printf '%s\n' "${ST[uv]}"
  printf '  '; pad_w "流量" 12; printf '%s\n' "$(hb "${ST[bytes]}")"
  echo "  状态码  2xx:${ST[c2]}  3xx:${ST[c3]}"
  echo "          4xx:${ST[c4]}  5xx:${ST[c5]}"
  if [[ -n $(awk -F'\t' '$1=="sp"' "$STAT_TMP") ]]; then
    echo; echo "${B}爬虫 / 脚本${N}"; stat_top sp 8
  fi
  echo; echo "${B}访问 IP TOP10${N}"; stat_top ip 10
  echo; echo "${B}热门页面 TOP10${N}"; stat_top url 10
  if [[ -n $(awk -F'\t' '$1=="nf"' "$STAT_TMP") ]]; then
    echo; echo "${B}404 页面 TOP5${N}"; stat_top nf 5
  fi
  if [[ -n $(awk -F'\t' '$1=="ref"' "$STAT_TMP") ]]; then
    echo; echo "${B}来源网站 TOP5${N}"; stat_top ref 5
  fi
  echo; echo "${B}每小时请求量${N}"
  while IFS=$'\t' read -r t c h; do
    [[ $t == hr ]] && ((c > max)) && max=$c
  done < "$STAT_TMP"
  for h in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    c=$(awk -F'\t' -v k="$h" '$1=="hr"&&$3==k{print $2}' "$STAT_TMP")
    c=${c:-0}
    n=0; ((max > 0 && c > 0)) && { n=$((c * 20 / max)); ((n < 1)) && n=1; }
    bar=$(printf '%*s' "$n" '' | tr ' ' '#')
    printf '  %s %-20s %s\n' "$h" "$bar" "$c"
  done
  rm -f "$STAT_TMP"
}

stat_overview() {  # stat_overview 范围 范围名
  local d name
  title "全部站点 · 访问概览"
  echo "  范围: $2"
  printf '  '; pad_w "站点" 16; pad_w "PV" 8; pad_w "IP" 6; echo "流量"
  while read -r d; do
    [[ -n $d ]] || continue
    if [[ ! -e /var/log/nginx/$d.access.log ]]; then continue; fi
    stat_collect "$d" "$1"
    name=$d; ((${#name} > 15)) && name="${name:0:14}~"
    printf '  '; pad_w "$name" 16; pad_w "${ST[pv]:-0}" 8; pad_w "${ST[uv]:-0}" 6; hb "${ST[bytes]:-0}"; echo
    rm -f "$STAT_TMP"
  done < <(list_site_names)
}

stats_menu() {
  local c
  choose c "统计对象:" "单个站点" "全部站点概览" "返回" || return 0
  case $c in
    单个*) pick_site "" || return 0
           stat_range_pick || return 0
           stat_show "$SITE" "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
    全部*) stat_range_pick || return 0
           stat_overview "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
  esac
}

stats_cli() {  # wsm stats [域名] [1|y|7|30|all]
  local d=${1:-} r=${2:-1}
  case $r in 1|y|7|30|all) ;; *) die "范围只能是 1(今天) y(昨天) 7 30 all" ;; esac
  if [[ -z $d ]]; then stat_overview "$r" "$r"; else pick_site "$d" || return 1; stat_show "$d" "$r" "$r"; fi
}

# ================================================================ 文件工具
files_ok() {
  [[ -n ${ROOT:-} && -d $ROOT ]] && safe_root "$ROOT" && return 0
  err "网站目录不可用: ${ROOT:-空}"; return 1
}
files_unlocked() {
  [[ $TAMPER == 1 ]] || return 0
  warn "网站处于防篡改锁定状态, 请先到 [网站防篡改] 临时解锁"; return 1
}
files_trunc() {  # files_trunc 文本 [最大宽度]  (太长时保留结尾)
  local s=$1 n=${2:-30}
  if ((${#s} > n)); then s="~${s: -$((n - 1))}"; fi
  printf '%s' "$s"
}

files_dirsize() {
  title "目录大小排行"
  du -h --max-depth=1 "$ROOT" 2>/dev/null | sort -rh | head -15 | while IFS=$'\t' read -r sz p; do
    if [[ $p == "$ROOT" ]]; then p="(整个网站)"; else p=${p#"$ROOT"/}; fi
    printf '  %7s  %s\n' "$sz" "$(files_trunc "$p" 28)"
  done
}

files_bigfiles() {
  local n s p
  read -r -p "查找大于多少 MB 的文件 [20]: " n || return 1
  n=${n:-20}
  [[ $n =~ ^[0-9]+$ && $n -ge 1 ]] || { err "请输入数字"; return 1; }
  echo "大于 ${n}MB 的文件 (前 20 个):"
  find "$ROOT" -type f -size +"${n}"M -printf '%s\t%P\n' 2>/dev/null | sort -t$'\t' -k1,1nr | head -20 |
  while IFS=$'\t' read -r s p; do printf '  %8s  %s\n' "$(hb "$s")" "$(files_trunc "$p" 28)"; done
  return 0
}

files_recent() {
  local r m t p
  choose r "查看多久内改动过的文件:" "最近 1 小时" "最近 24 小时" "最近 7 天" || return 1
  case $r in *1\ 小时) m=60 ;; *24*) m=1440 ;; *) m=10080 ;; esac
  echo "改动过的文件 (最新 40 个):"
  find "$ROOT" -type f -mmin -"$m" -printf '%T@\t%Tm-%Td %TH:%TM\t%P\n' 2>/dev/null | sort -t$'\t' -k1,1nr | head -40 |
  while IFS=$'\t' read -r _ t p; do printf '  %s  %s\n' "$t" "$(files_trunc "$p" 24)"; done
  return 0
}

files_find_name() {
  local kw
  read -r -p "文件名包含: " kw || return 1
  [[ -n $kw ]] || return 1
  find "$ROOT" -iname "*$kw*" -printf '%P\n' 2>/dev/null | head -40 | while read -r p; do echo "  $(files_trunc "$p" 36)"; done
  return 0
}

files_find_text() {
  local kw line
  read -r -p "文件内容包含 (区分大小写): " kw || return 1
  [[ -n $kw ]] || return 1
  grep -rInF --exclude-dir=.git --exclude-dir=node_modules -- "$kw" "$ROOT" 2>/dev/null | head -30 |
  while IFS= read -r line; do line=${line#"$ROOT"/}; echo "  ${line:0:70}"; done
  return 0
}

files_scan() {
  local n=0 f
  title "可疑代码扫描"
  echo "  按常见木马特征做简单检查, 只能作参考, 可能有误报"
  echo
  echo "${B}含可疑特征的 PHP 文件${N}"
  while IFS= read -r -d '' f; do
    n=$((n + 1)); echo "  $(files_trunc "${f#"$ROOT"/}" 36)"
  done < <(grep -rIlZE --include='*.php' --include='*.phtml' --include='*.php5' --exclude-dir=.git \
    -e 'eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|str_rot13)' \
    -e 'assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e '(system|shell_exec|passthru|exec|popen|proc_open)[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e 'base64_decode[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)' \
    -e 'FilesMan|c99shell|r57shell|b374k' "$ROOT" 2>/dev/null)
  ((n)) || echo "  (未发现)"
  echo
  echo "${B}上传目录里的 PHP 文件 (正常情况下不该有)${N}"
  n=0
  while IFS= read -r f; do
    n=$((n + 1)); echo "  $(files_trunc "${f#"$ROOT"/}" 36)"
  done < <(find "$ROOT" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' \) \( -path '*/uploads/*' -o -path '*/upload/*' \) 2>/dev/null | head -30)
  ((n)) || echo "  (未发现)"
  return 0
}

files_extract() {
  files_unlocked || return 1
  local f dest target tmp src cnt top
  read -r -p "压缩包路径 (zip / tar.gz / tgz / tar.bz2 / tar.xz / tar): " f || return 1
  [[ -f $f ]] || { err "文件不存在: $f"; return 1; }
  read -r -p "解压到 (相对网站目录, 回车=网站根目录): " dest || return 1
  dest=${dest#/}
  target=$(realpath -m "$ROOT/$dest")
  case $target in "$ROOT"|"$ROOT"/*) ;; *) err "目标必须在网站目录内"; return 1 ;; esac
  tmp=$(mktemp -d "$(dirname "$ROOT")/.wsm-x.XXXXXX") || { err "无法创建临时目录"; return 1; }
  case $f in
    *.zip)
      command -v unzip >/dev/null 2>&1 || pkg_install unzip >/dev/null 2>&1 || { err "需要 unzip, 安装失败"; rm -rf "$tmp"; return 1; }
      unzip -q -o "$f" -d "$tmp" ;;
    *.tar.gz|*.tgz) tar -xzf "$f" -C "$tmp" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$f" -C "$tmp" ;;
    *.tar.xz|*.txz) tar -xJf "$f" -C "$tmp" ;;
    *.tar) tar -xf "$f" -C "$tmp" ;;
    *) err "不支持的格式"; rm -rf "$tmp"; return 1 ;;
  esac || { err "解压失败"; rm -rf "$tmp"; return 1; }
  find "$tmp" -type l -delete 2>/dev/null   # 删除压缩包里的符号链接, 防止指向系统文件
  src=$tmp
  cnt=$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l)
  if ((cnt == 1)); then
    top=$(find "$tmp" -mindepth 1 -maxdepth 1)
    if [[ -d $top ]] && confirm "压缩包最外层只有一个目录 ($(basename "$top")), 去掉这一层?" y; then src=$top; fi
  fi
  cnt=$(find "$src" -type f | wc -l)
  if ! confirm "将 $cnt 个文件解压到 ${target}, 同名文件会被覆盖, 继续?" y; then rm -rf "$tmp"; return 0; fi
  mkdir -p "$target"
  cp -a "$src"/. "$target"/ || { err "复制失败"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  fix_perms_dir "$target"
  info "已解压 $cnt 个文件到 $target (已修正所有者和权限)"
}

files_pack() {
  local out def
  def=/root/${DOMAIN}_$(date +%Y%m%d_%H%M).tar.gz
  read -r -p "保存到 [$def]: " out || return 1
  out=${out:-$def}
  [[ $out == /* ]] || { err "请填绝对路径"; return 1; }
  case $out in "$WWW_ROOT"/*|"$ROOT"/*) err "不能保存在网站目录里 (会被公开下载)"; return 1 ;; esac
  mkdir -p "$(dirname "$out")"
  tar -czf "$out" -C "$(dirname "$ROOT")" "$(basename "$ROOT")" || { err "打包失败"; return 1; }
  chmod 600 "$out"
  info "已打包: $out ($(du -h "$out" | cut -f1))"
}

files_replace() {
  files_unlocked || return 1
  local find repl kind n f fe re bk dl i=0
  local -a inc=() list=()
  read -r -p "查找的文本: " find || return 1
  [[ -n $find ]] || { err "不能为空"; return 1; }
  read -r -p "替换为 (留空=删除这段文本): " repl || return 1
  choose kind "文件范围:" "PHP 文件" "HTML / JS / CSS" "配置类 (.env .conf .ini .json .xml .yml)" "所有文本文件" || return 1
  case $kind in
    PHP*) inc=(--include='*.php' --include='*.phtml') ;;
    HTML*) inc=(--include='*.html' --include='*.htm' --include='*.js' --include='*.css') ;;
    配置*) inc=(--include='.env*' --include='*.conf' --include='*.ini' --include='*.json' --include='*.xml' --include='*.yml' --include='*.yaml') ;;
  esac
  mapfile -d '' -t list < <(grep -rIlZF ${inc[@]+"${inc[@]}"} --exclude-dir=.git --exclude-dir=node_modules -- "$find" "$ROOT" 2>/dev/null)
  n=${#list[@]}
  ((n)) || { warn "没有找到包含该文本的文件"; return 0; }
  echo "找到 $n 个文件:"
  for f in "${list[@]}"; do
    i=$((i + 1)); ((i > 15)) && { echo "  ... 还有 $((n - 15)) 个"; break; }
    echo "  $(files_trunc "${f#"$ROOT"/}" 36)"
  done
  confirm "替换以上文件里的所有匹配?" n || return 0
  bk=$BACKUP_DIR/replace/${DOMAIN}_$(date +%Y%m%d_%H%M%S).tar.gz
  mkdir -p "$(dirname "$bk")"
  for f in "${list[@]}"; do printf '%s\0' "${f#"$ROOT"/}"; done | tar -czf "$bk" -C "$ROOT" --null -T - \
    || { err "备份失败, 已取消 (没有改动任何文件)"; return 1; }
  dl=$'\001'
  fe=$(printf '%s' "$find" | sed 's/[][\.*^$]/\\&/g')
  re=$(printf '%s' "$repl" | sed 's/[\&]/\\&/g')
  for f in "${list[@]}"; do sed -i "s${dl}${fe}${dl}${re}${dl}g" "$f"; done
  info "已替换 $n 个文件。替换前的原文件备份在: $bk"
}

files_edit() {
  files_unlocked || return 1
  local rel p ed bakd bakf sum1 sum2 out c
  local -a cand=()
  for c in wp-config.php .env config.php .htaccess index.php; do [[ -f $ROOT/$c ]] && cand+=("$c"); done
  cand+=("手动输入路径")
  choose rel "编辑哪个文件:" "${cand[@]}" || return 1
  if [[ $rel == 手动* ]]; then read -r -p "相对网站目录的路径: " rel || return 1; fi
  rel=${rel#/}
  [[ -n $rel ]] || return 1
  p=$(realpath -m "$ROOT/$rel")
  case $p in "$ROOT"/*) ;; *) err "文件必须在网站目录内"; return 1 ;; esac
  ed=$(command -v nano || command -v vim || command -v vi || true)
  if [[ -z $ed ]]; then pkg_install nano >/dev/null 2>&1; ed=$(command -v nano || true); fi
  [[ -n $ed ]] || { err "没有可用的编辑器 (nano/vim)"; return 1; }
  if [[ ! -f $p ]]; then confirm "文件不存在, 新建它?" n || return 0; fi
  bakd=$BACKUP_DIR/edit/$DOMAIN; mkdir -p "$bakd"
  bakf=""
  if [[ -f $p ]]; then bakf=$bakd/$(basename "$p").$(date +%Y%m%d_%H%M%S); cp -a "$p" "$bakf"; fi
  sum1=$(sha256sum "$p" 2>/dev/null | cut -d' ' -f1)
  "$ed" "$p"
  sum2=$(sha256sum "$p" 2>/dev/null | cut -d' ' -f1)
  if [[ $sum1 == "$sum2" ]]; then info "没有改动"; return 0; fi
  if [[ $p == *.php && -n ${PHPVER:-} ]] && command -v "$(php_bin "$PHPVER")" >/dev/null 2>&1; then
    if ! out=$("$(php_bin "$PHPVER")" -l "$p" 2>&1); then
      err "PHP 语法检查没通过:"; echo "$out" | head -5
      if [[ -n $bakf ]] && confirm "还原成修改前的版本?" y; then cp -a "$bakf" "$p"; info "已还原"; return 0; fi
    else info "PHP 语法检查通过"; fi
  fi
  chown "$WEB_USER:$WEB_USER" "$p" 2>/dev/null
  info "已保存${bakf:+, 修改前的版本备份在 $bakf}"
}

files_clean() {
  files_unlocked || return 1
  local n d f
  local -a junk=() dirs=()
  mapfile -d '' -t junk < <(find "$ROOT" -type f \( -name '.DS_Store' -o -name 'Thumbs.db' -o -name '*.swp' -o -name '*~' \) -print0 2>/dev/null)
  for d in wp-content/cache wp-content/upgrade; do [[ -d $ROOT/$d ]] && dirs+=("$ROOT/$d"); done
  echo "垃圾文件 (.DS_Store / Thumbs.db / *.swp / *~): ${#junk[@]} 个"
  for d in "${dirs[@]}"; do echo "缓存目录 ${d#"$ROOT"/}: $(du -sh "$d" 2>/dev/null | cut -f1)"; done
  n=$(( ${#junk[@]} + ${#dirs[@]} ))
  ((n)) || { info "没有需要清理的内容"; return 0; }
  confirm "全部清理?" n || return 0
  for f in "${junk[@]}"; do rm -f -- "$f"; done
  for d in "${dirs[@]}"; do find "$d" -mindepth 1 -delete 2>/dev/null; done
  info "清理完成"
}

files_menu() {
  local d=$1 c
  load_meta "$d"
  files_ok || return 1
  while true; do
    load_meta "$d"
    title "文件工具 · $d"
    echo "  目录: $ROOT"
    choose c "操作:" "目录大小排行" "查找大文件" "最近改动的文件" "搜索文件名" "搜索文件内容" \
      "可疑代码扫描" "解压到网站目录" "打包网站目录" "批量替换文本" "编辑文件" "清理垃圾文件" "修复权限" "返回" || return 0
    case $c in
      目录*) files_dirsize ;;
      查找*) files_bigfiles ;;
      最近*) files_recent ;;
      搜索文件名) files_find_name ;;
      搜索文件内容) files_find_text ;;
      可疑*) files_scan ;;
      解压*) files_extract ;;
      打包*) files_pack ;;
      批量*) files_replace ;;
      编辑*) files_edit ;;
      清理*) files_clean ;;
      修复*) files_unlocked && confirm "把所有者改为 $WEB_USER, 目录 755 / 文件 644 ?" y && { fix_perms_dir "$ROOT"; info "权限已修复"; } ;;
      *) return 0 ;;
    esac
    pause
  done
}

menu_files() {
  use_site "" || { pause; return 0; }
  need_type php static || { pause; return 0; }
  files_menu "$SITE"
}

# ================================================================ 在线更新
UPDATE_CONF=$WSM_DIR/update.conf
SELF_BAK=$WSM_DIR/backup
UPDATE_URL=""
UPDATED=0
UPD_TMP=""

update_load() { UPDATE_URL=""; [[ -f $UPDATE_CONF ]] && source "$UPDATE_CONF"; return 0; }

update_set_url() {
  local in url re_url re_repo
  re_url='^https://[A-Za-z0-9._~:/?&=%@+-]+$'
  re_repo='^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(@([A-Za-z0-9._/-]+))?$'
  echo "填 GitHub 仓库, 如 chentiti888/wsm  (指定分支: chentiti888/wsm@dev)"
  echo "脚本文件名需要是 wsm.sh; 文件名不同时请直接填完整的 raw 地址 (https://...)"
  read -r -p "仓库 / 地址: " in || return 1
  in=${in// /}
  [[ -n $in ]] || return 1
  if [[ $in =~ $re_url ]]; then url=$in
  elif [[ $in =~ $re_repo ]]; then
    url="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[4]:-main}/wsm.sh"
  else err "格式不对"; return 1; fi
  mkdir -p "$WSM_DIR"
  printf 'UPDATE_URL=%q\n' "$url" > "$UPDATE_CONF"
  UPDATE_URL=$url
  info "已保存: $url"
  echo "  新服务器一键安装:"
  echo "  curl -fsSL $url -o wsm.sh && bash wsm.sh install"
}

update_fetch() {  # -> UPD_TMP
  local u=$UPDATE_URL first sep='?'
  [[ $u == *\?* ]] && sep='&'
  UPD_TMP=$(mktemp)
  curl -fsSL --max-time 60 -H 'Cache-Control: no-cache' "${u}${sep}_=$(date +%s)" -o "$UPD_TMP" \
    || { rm -f "$UPD_TMP"; err "下载失败: 请检查仓库地址是否正确 (私有仓库不支持) 和服务器网络"; return 1; }
  first=$(head -n1 "$UPD_TMP")
  if [[ $first != '#!'*bash* ]] || ! grep -q '^WSM_VER=' "$UPD_TMP" || (($(wc -c < "$UPD_TMP") < 20000)); then
    rm -f "$UPD_TMP"; err "下载到的内容不是有效的 wsm 脚本 (地址写错 / 仓库里没有 wsm.sh?)"; return 1
  fi
  if ! bash -n "$UPD_TMP" 2>/dev/null; then
    rm -f "$UPD_TMP"; err "新脚本语法检查没通过, 已取消更新 (当前版本没有改动)"; return 1
  fi
}

update_install_file() {  # update_install_file 新文件 : 备份当前版本并替换
  mkdir -p "$SELF_BAK"
  [[ -f $WSM_BIN ]] && cp -a "$WSM_BIN" "$SELF_BAK/wsm.v${WSM_VER}.$(date +%Y%m%d_%H%M%S).sh"
  # shellcheck disable=SC2012
  ls -1t "$SELF_BAK"/wsm.v*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f
  install -m 755 "$1" "$WSM_BIN.new" && mv -f "$WSM_BIN.new" "$WSM_BIN"
}

update_run() {  # update_run [-y]
  local yes=${1:-} vnew
  UPDATED=0
  update_load
  if [[ -z $UPDATE_URL ]]; then update_set_url || return 1; fi
  info "正在检查更新 ..."
  update_fetch || return 1
  if [[ -f $WSM_BIN ]] && cmp -s "$UPD_TMP" "$WSM_BIN"; then
    info "已经是最新版 (v$WSM_VER)"; rm -f "$UPD_TMP"; return 0
  fi
  vnew=$(sed -n 's/^WSM_VER="\(.*\)".*/\1/p' "$UPD_TMP" | head -1)
  echo "  当前: v$WSM_VER   仓库: v${vnew:-?}"
  if [[ $yes != -y ]]; then confirm "现在更新?" y || { rm -f "$UPD_TMP"; return 0; }; fi
  update_install_file "$UPD_TMP" || { rm -f "$UPD_TMP"; err "写入失败"; return 1; }
  rm -f "$UPD_TMP"
  UPDATED=1
  info "已更新到 v${vnew:-?} (旧版本已备份, 可在 [更新脚本] 里回滚)"
}

update_rollback() {
  local f c
  local -a names=()
  while read -r f; do [[ -n $f ]] && names+=("$(basename "$f")"); done < <(ls -1t "$SELF_BAK"/wsm.v*.sh 2>/dev/null)
  ((${#names[@]})) || { warn "没有可回滚的旧版本"; return 1; }
  choose c "回滚到:" "${names[@]}" || return 1
  bash -n "$SELF_BAK/$c" 2>/dev/null || { err "该备份文件已损坏"; return 1; }
  confirm "回滚到 $c ?" n || return 0
  update_install_file "$SELF_BAK/$c" || { err "写入失败"; return 1; }
  UPDATED=1
  info "已回滚"
}

update_menu() {
  local c u
  while true; do
    update_load
    UPDATED=0
    title "更新脚本"
    u=${UPDATE_URL#https://raw.githubusercontent.com/}
    echo "  当前版本: v$WSM_VER"
    echo "  仓库: $(files_trunc "${u:-(未设置)}" 32)"
    choose c "操作:" "检查并更新" "设置仓库地址" "回滚到旧版本" "返回" || return 0
    case $c in
      检查*) update_run ;;
      设置*) update_set_url ;;
      回滚*) update_rollback ;;
      *) return 0 ;;
    esac
    if [[ $UPDATED == 1 ]]; then info "重新载入新版本 ..."; sleep 1; exec "$WSM_BIN"; fi
    pause
  done
}

# ================================================================ 菜单
dashboard() {
  local n=0 f phps
  for f in "$META_DIR"/*.conf; do [[ -e $f ]] && n=$((n + 1)); done
  phps=$(php_installed | sort -V | tr '\n' ' ')
  echo
  echo "${B}╔══════════════════════════════════════════════════════╗${N}"
  echo "${B}║${N}  Web Server Manager v$WSM_VER   服务器 IP: ${SERVER_IP:-未知}"
  echo "${B}╚══════════════════════════════════════════════════════╝${N}"
  printf "  Nginx: %s   站点: %s 个   PHP: %s\n" "$(svc_state nginx)" "$n" "${phps:-未安装}"
  if unit_exists mariadb; then printf "  MariaDB: %s   " "$(svc_state mariadb)"; fi
  printf "磁盘: %s   负载: %s\n" "$(df -h / | awk 'NR==2{print $5}')" "$(cut -d' ' -f1-3 /proc/loadavg)"
}

menu_tamper() {
  use_site "" || { pause; return 0; }
  if [[ $TYPE != php && $TYPE != static ]]; then
    warn "防篡改只适用于 PHP / 静态站点"; pause; return 0
  fi
  tamper_menu "$SITE"
}

menu_sites() {
  local c
  while true; do
    title "网站管理"
    cat <<'EOF'
   1) 站点列表
   2) 新建 PHP 站点
   3) 新建 WordPress
   4) 新建静态站点
   5) 新建反向代理
   6) 新建域名重定向
   7) 站点设置 (域名/SSL/伪静态...)
   8) 删除站点
   9) 访问统计
  10) 网站防篡改
  11) SFTP 账号
  12) 文件工具
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) list_sites; pause ;;
      2) (add_site php); pause ;;
      3) (wp_install); pause ;;
      4) (add_site static); pause ;;
      5) (add_site proxy); pause ;;
      6) (add_site redirect); pause ;;
      7) (site_settings "") ;;
      8) (del_site ""); pause ;;
      9) (stats_menu); pause ;;
      10) (menu_tamper) ;;
      11) sftp_menu ;;
      12) (menu_files) ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_ssl() {
  local c
  while true; do
    title "SSL 证书管理"
    cat <<'EOF'
   1) 证书总览 (来源/剩余天数)
   2) 申请 / 更换证书
   3) 站点 SSL 设置 (强制HTTPS)
   4) 立即续期全部证书
   5) 自动续期 开/关
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) list_certs; pause ;;
      2) (use_site "" && ssl_pick_method "$DOMAIN"); pause ;;
      3) (ssl_menu "") ;;
      4) certbot renew --deploy-hook "systemctl reload nginx"; pause ;;
      5) toggle_auto_renew; pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_php() {
  local c
  while true; do
    title "PHP 管理"
    php_status_table
    cat <<'EOF'

   1) 安装新的 PHP 版本
   2) 卸载 PHP 版本
   3) 常用参数 (上传/内存/超时)
   4) 扩展管理 (查看/安装)
   5) 禁用危险函数
   6) PHP-FPM 进程数调优
   7) 重启 PHP-FPM
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) (install_php ""); pause ;;
      2) (php_uninstall); pause ;;
      3) (php_settings) ;;
      4) (php_extensions) ;;
      5) (php_disable_functions); pause ;;
      6) (php_fpm_tune); pause ;;
      7) (pick_php_installed && systemctl restart "$(php_svc "$CHOSEN_PHP")" && info "已重启"); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_db() {
  local c
  while true; do
    title "数据库管理"
    cat <<'EOF'
   1) 数据库列表
   2) 创建数据库和用户
   3) 删除数据库
   4) 修改用户密码
   5) 备份数据库
   6) 还原数据库
   7) 安装 phpMyAdmin (网页管理数据库)
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) (db_list); pause ;;
      2) (db_create ""); pause ;;
      3) (db_drop); pause ;;
      4) (db_passwd); pause ;;
      5) (backup_db ""); pause ;;
      6) (restore_db); pause ;;
      7) (install_pma); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_backup() {
  local c
  while true; do
    title "备份与计划任务"
    cat <<'EOF'
   1) 立即备份网站
   2) 立即备份数据库
   3) 查看备份文件
   4) 还原网站
   5) 还原数据库
   6) 查看计划任务
   7) 添加计划任务 (定时备份)
   8) 删除计划任务
   0) 返回
EOF
    echo "  备份目录: $BACKUP_DIR"
    read -r -p "请选择: " c || return 0
    case $c in
      1) (backup_site "" 7); pause ;;
      2) (backup_db ""); pause ;;
      3) list_backups; pause ;;
      4) (restore_site); pause ;;
      5) (restore_db); pause ;;
      6) tasks_list; pause ;;
      7) (tasks_add); pause ;;
      8) (tasks_del); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_system() {
  local c
  while true; do
    title "服务与日志"
    cat <<'EOF'
   1) 服务管理 (启停/重启/自启)
   2) 检测并重载 Nginx 配置
   3) 查看 Nginx 全局错误日志
   4) 磁盘与内存使用情况
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) (manage_service); pause ;;
      2) nginx -t && systemctl reload nginx && info "配置正确, 已重载"; pause ;;
      3) tail -n 50 /var/log/nginx/error.log 2>/dev/null || warn "暂无日志"; pause ;;
      4) df -h /; echo; free -h; du -sh "$WWW_ROOT" "$BACKUP_DIR" 2>/dev/null; pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_software() {
  local c
  while true; do
    title "软件与环境"
    cat <<'EOF'
   1) 安装/修复基础环境
   2) 安装 MariaDB
   3) 安装 Redis (含 PHP 扩展)
   4) 安装 Composer
   5) 禁止IP直接访问 (开关)
   0) 返回
EOF
    read -r -p "请选择: " c || return 0
    case $c in
      1) (install_base); pause ;;
      2) (install_db); pause ;;
      3) (install_redis); pause ;;
      4) (install_composer); pause ;;
      5) (toggle_block_ip); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

main_menu() {
  local c
  SERVER_IP=$(public_ip)
  while true; do
    dashboard
    echo
    mi 1 "网站管理" "新建/设置/删除"
    mi 2 "SSL 证书" "申请/自有证书/续期"
    mi 3 "PHP 管理" "版本/扩展/参数"
    mi 4 "数据库" "创建/备份/phpMyAdmin"
    mi 5 "备份与任务" "网站/数据库/定时"
    mi 6 "服务与日志" "启停/重载/日志"
    mi 7 "软件与环境" "Redis/Composer"
    mi 8 "软件商店" "Node/Docker/PG..."
    mi 9 "网站防篡改" "锁定/检测/还原"
    mi 10 "更新脚本" "从 Git 仓库一键更新"
    echo "  0) 退出"
    read -r -p "请选择: " c || exit 0
    case $c in
      1) menu_sites ;;
      2) menu_ssl ;;
      3) menu_php ;;
      4) menu_db ;;
      5) menu_backup ;;
      6) menu_system ;;
      7) menu_software ;;
      8) menu_store ;;
      9) (menu_tamper) ;;
      10) update_menu ;;
      0|q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage() {
  cat <<EOF
wsm v$WSM_VER - Web Server Manager

  wsm                               交互菜单 (推荐)
  wsm install                       安装 Nginx/PHP/MariaDB/certbot 环境
  wsm add-php|add-static [域名]     新建站点
  wsm add-wp [域名]                 一键部署 WordPress
  wsm add-proxy [域名] [后端URL]    新建反向代理
  wsm sftp                          SFTP 账号管理
  wsm update [-y]                   从 Git 仓库更新脚本 (-y 不确认)
  wsm rollback                      回滚到上一个版本
  wsm stats [域名] [1|y|7|30|all]   访问统计 (不写域名=全站概览)
  wsm add-redirect [域名] [目标]    新建域名重定向
  wsm ssl [域名]                    申请/更换证书
  wsm list                          站点列表
  wsm certs                         证书总览
  wsm renew                         立即续期全部证书
  wsm backup-site [域名] [份数]     备份网站
  wsm backup-db [库名|--all] [份数] 备份数据库
  wsm tamper-lock|tamper-unlock [域名]      防篡改: 锁定/解锁网站文件
  wsm tamper-check [域名] [ask|report|restore]  防篡改: 完整性检测/还原
  wsm db-create [库名]              创建数据库
  wsm php-install [版本]            安装 PHP
  wsm del [域名]                    删除站点
  wsm status                        服务状态
  wsm store                         软件商店 (交互)
  wsm app-list                      软件列表和安装状态
  wsm app-install|app-uninstall <ID>  安装/卸载软件 (ID 见 app-list)
EOF
}

# ================================================================ 入口
[[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != "$0" ]] && return 0

need_root
detect_os
mkdir -p "$META_DIR" "$CERT_DIR" "$AUTH_DIR"

case ${1:-menu} in
  menu)         main_menu ;;
  install)      cmd_install ;;
  php-install)  install_php "${2:-}" ;;
  db-install)   install_db ;;
  db-create)    db_create "${2:-}" ;;
  add-php)      add_site php "${2:-}" ;;
  add-static)   add_site static "${2:-}" ;;
  add-wp)       wp_install "${2:-}" ;;
  sftp)         sftp_menu ;;
  update)       update_run "${2:-}" ;;
  rollback)     update_rollback ;;
  stats)        stats_cli "${2:-}" "${3:-1}" ;;
  add-proxy)    add_site proxy "${2:-}" "${3:-}" ;;
  add-redirect) add_site redirect "${2:-}" "${3:-}" ;;
  ssl)          use_site "${2:-}" && ssl_pick_method "$SITE" ;;
  del)          del_site "${2:-}" ;;
  list)         list_sites ;;
  certs)        list_certs ;;
  renew)        certbot renew --deploy-hook "systemctl reload nginx" ;;
  backup-site)  backup_site "${2:-}" "${3:-7}" ;;
  backup-db)    backup_db "${2:-}" "${3:-7}" ;;
  tamper-lock)  use_site "${2:-}" && tamper_lock "$SITE" ;;
  tamper-unlock) use_site "${2:-}" && tamper_unlock "$SITE" ;;
  tamper-check) tamper_check "${2:-}" "${3:-ask}" ;;
  status)       dashboard ;;
  store)        menu_store ;;
  app-list)     app_list ;;
  app-install)  app_install "${2:-}" ;;
  app-uninstall) app_uninstall "${2:-}" ;;
  help|-h|--help) usage ;;
  *)            usage ;;
esac

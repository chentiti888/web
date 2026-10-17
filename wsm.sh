#!/usr/bin/env bash
# =====================================================================
#  wsm.sh v3  -  Server Manager (服务器工具箱 + 命令行版"宝塔")
#
#  启动不安装任何软件: 只装 wsm 快捷命令, 其他都是在菜单里选了才装, 装过的都能卸载
#
#  服务器: 系统信息, SSH 安全(端口/密钥/导入公钥/下载私钥/密码登录), BBR, 禁 Ping, 端口转发(TCP/UDP),
#          回程线路检测, 流媒体/AI 解锁检测, CPU/内存/硬盘测试, CPU 占用, Swap, 时区, 服务管理, Telegram 告警,
#          已安装组件(统一卸载)
#  网站:   (选 [安装网站环境] 后才有) PHP / 静态 / 反向代理 / 域名重定向, 多域名绑定, 伪静态, 子路径反代,
#          访问密码, 防盗链, IP 黑白名单, Gzip, 静态缓存, 停用/启用, 日志分析,
#          防篡改(文件锁定 + 可写目录禁PHP + 完整性基线检测/自动还原), 访问统计(PV/IP/流量/TOP/蜘蛛),
#          全量备份(网站/数据库/机器人分开)/一键搬家/异地备份, 源站保护(多 CDN), 防 CC
#  证书:   Let's Encrypt(HTTP) / 通配符(Cloudflare DNS) / 自有证书 / 自签名, 自动续期
#  PHP :   7.4-8.4 多版本共存, 扩展, 参数, 禁用函数, FPM 进程数
#  程序下载: 扩展程序模块 (Xboard / WordPress / Typecho / Nextcloud / 哪吒 / Uptime Kuma / OpenList / 3x-ui,
#            可随时添加/删除), 数据库, 开发运行环境, 系统工具
#  系统:   Debian 10+ / Ubuntu 20.04+ (推荐)   RHEL 系 (Rocky/Alma/CentOS) 尽力支持
#
#  用法: bash wsm.sh                 安装 wsm 命令并进入菜单 (不装任何软件)
#        wsm                         进入交互菜单
#        wsm install                 一键安装网站环境 (Nginx + PHP + MariaDB + certbot)
# =====================================================================
set -uo pipefail

WSM_VER="3.1.8"
# CHANGELOG-BEGIN  (更新时显示比当前版本新的条目, 新的写在最上面; 只留最近几条, 完整记录见仓库 CHANGELOG.md)
# v3.1.8 网速测试改回 curl 自己测 (不再用 speedtest-cli): 从官方 Speedtest 服务器列表按距离由近到远试, 每个先试测 2 秒, 下载和上传都正常才用; Speedtest 都不行再用 Cloudflare / Linode
# v3.1.7 修复 Gemini 检测: 网页里的可用标记改版失效, 支持的地区 (如日本) 也显示不支持; 改为按 Google 识别的地区对照支持列表判断
# v3.1.6 流媒体/AI 解锁检测对照 RegionRestrictionCheck 重新核对: Disney+ 改用官方接口判断 (以前只看首页, 不支持的地区也显示可访问); Netflix/YouTube/ChatGPT 补上浏览器请求头和 cookie, 避免拿到不同页面误判
# v3.1.5 网速测试改用 speedtest-cli (官方 Speedtest 服务器, 自动选最近最快的节点; speedtest.py 放在 wsm 仓库里, 核对 sha256 后临时运行, 测完就删); 不能用时自动改用 Cloudflare / Linode 备用测试
# CHANGELOG-END
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

# ---------------- 配色 (256 色; 终端只支持 8 色时自动退回基本色)
# 主色(天蓝): 序号/标题/提示   正文: 亮白   说明: 灰   状态: 绿=正常 黄=注意 红=异常/退出
if [[ ${TERM:-} == *256color* || ${COLORTERM:-} == *color* || ${TERM:-} == xterm* || ${TERM:-} == screen* || ${TERM:-} == tmux* ]]; then
  R=$'\e[38;5;203m'; G=$'\e[38;5;114m'; Y=$'\e[38;5;221m'; B=$'\e[38;5;75m'; D=$'\e[38;5;244m'
  T=$'\e[38;5;252m'; L=$'\e[38;5;238m'; S=$'\e[38;5;110m'
else
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; T=$'\e[0m'; L=$'\e[2m'; S=$'\e[34m'
fi
N=$'\e[0m'; BD=$'\e[1m'
RED=$R; GREEN=$G; YELLOW=$Y; CYAN=$B; NC=$N
info() { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
err()  { echo "  ${R}✘${N} $*" >&2; }
die()  { err "$*"; exit 1; }
disp_w() { local s=$1 t LC_ALL=C; t=${s//[! -~]/}; echo $(( ${#t} + (${#s} - ${#t}) / 3 * 2 )); }
rep() { local i o=""; for ((i = 0; i < $2; i++)); do o+=$1; done; printf '%s' "$o"; }
title() { local n=$((46 - $(disp_w "$*"))); ((n < 4)) && n=4; printf '\n  %s%s%s%s %s%s%s\n' "$BD" "$B" "$*" "$N" "$L" "$(rep ─ "$n")" "$N"; }
# mitem 序号 名称 [说明]     mback : 0 返回      mlist : 把 "   1) 名称 (说明)" 这种行转成统一样式
mitem() { printf '  %s%3s%s  %s%s%s\e[24G%s%s%s\n' "$BD$B" "$1" "$N" "$T" "$2" "$N" "$D" "${3:-}" "$N"; }
mback() { printf '  %s%3s%s  %s%s%s\n' "$BD$G" 0 "$N" "$G" "${1:-返回}" "$N"; }
mlist() {
  local line n t d
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*([0-9a-z]+)\)[[:space:]]+(.*)$ ]]; then
      n=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}; d=""
      if [[ $t =~ ^(.*[^[:space:]])[[:space:]]+\((.*)\)$ ]]; then t=${BASH_REMATCH[1]}; d=${BASH_REMATCH[2]}; fi
      mitem "$n" "$t" "$d"
    else
      printf '%s\n' "$line"
    fi
  done
}
pad_w() {
  local s=$1 w=$2 t n LC_ALL=C
  t=${s//[! -~]/}
  n=$(( ${#t} + (${#s} - ${#t}) / 3 * 2 ))
  printf '%s%*s' "$s" $((w > n ? w - n : 0)) ''
}
# ---------------- 服务器时区 (定时任务/日志都按这个时间)
tz_get() {
  local z=""
  command -v timedatectl >/dev/null 2>&1 && z=$(timedatectl show -p Timezone --value 2>/dev/null)
  [[ -n $z ]] || z=$(cat /etc/timezone 2>/dev/null)
  [[ -n $z ]] || z=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  echo "${z:-UTC}"
}

tz_now() { date '+%F %T %Z'; }

tz_set() {
  local z=$1
  [[ $z =~ ^[A-Za-z0-9_+/-]+$ && -f /usr/share/zoneinfo/$z ]] || { err "没有这个时区: $z"; return 1; }
  if ! timedatectl set-timezone "$z" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/$z" /etc/localtime && echo "$z" > /etc/timezone || { err "设置失败"; return 1; }
  fi
  systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true
  info "时区已改为 $z, 现在时间: $(tz_now)"
}

tz_menu() {
  local c z
  echo "  当前时区: $(tz_get)"
  echo "  服务器时间: $(tz_now)"
  echo "  (定时备份/计划任务/日志都按这个时间)"
  choose c "设置为:" "北京时间 (Asia/Shanghai)" "UTC" "手动输入 (如 Asia/Tokyo)" || return 0
  case $c in
    北京*) z=Asia/Shanghai ;;
    UTC) z=UTC ;;
    *) read -r -p "时区名: " z || return 0 ;;
  esac
  tz_set "$z"
}

tz_suggest() {
  case $(tz_get) in
    UTC|Etc/UTC|Etc/Universal|Universal|GMT|Etc/GMT)
      echo "  服务器现在是 UTC 时间 ($(tz_now)), 比北京时间慢 8 小时。"
      confirm "改成北京时间? (定时备份等会按北京时间执行)" y && tz_set Asia/Shanghai ;;
  esac
  return 0
}

# ---------------- 菜单图标: 默认普通符号 (所有终端都能显示); 终端装了 Nerd 字体可以用 wsm icons nerd 换成图标
UI_CONF=$WSM_DIR/ui.conf
ICON_STYLE=plain
declare -A ICO_PLAIN=([web]="⌂" [ssl]="◈" [php]="◇" [db]="▤" [bak]="⇅" [sys]="◎" [app]="⇩" [sec]="◆" [upd]="↻" [exit]="×" [c_panel]="▣" [c_web]="◫" [c_dev]="❯" [c_tool]="▥")
declare -A ICO_NERD=([web]="" [ssl]="" [php]="" [db]="" [bak]="" [sys]="" [app]="" [sec]="" [upd]="" [exit]="" [c_panel]="" [c_web]="" [c_dev]="" [c_tool]="")
ui_load() { ICON_STYLE=plain; [[ -f $UI_CONF ]] && source "$UI_CONF"; [[ $ICON_STYLE == nerd ]] || ICON_STYLE=plain; return 0; }
ico() { if [[ $ICON_STYLE == nerd ]]; then printf '%s' "${ICO_NERD[$1]:-}"; else printf '%s' "${ICO_PLAIN[$1]:-}"; fi; }
ui_icon_set() {
  [[ $1 == nerd || $1 == plain ]] || { err "只能是 nerd 或 plain"; return 1; }
  mkdir -p "$WSM_DIR"; printf 'ICON_STYLE=%s\n' "$1" > "$UI_CONF"; ICON_STYLE=$1
  info "菜单图标: $([[ $1 == nerd ]] && echo "Nerd 字体图标" || echo "普通符号")"
}

# 所有带提示的输入 (read -p): 自动提示 "(0返回)", 输入 0 就取消并返回上一级 (返回值 1)
# 例外: "按回车继续" 和 "(0-23)" 这类 0 本身有效的数字输入; 不带 -p 的数据读取不受影响
read() {
  local -a _rd_a=("$@")
  local _rd_i _rd_pi=-1 _rd_p="" _rd_var _rd_cancel=1
  for ((_rd_i = 0; _rd_i < ${#_rd_a[@]}; _rd_i++)); do
    if [[ ${_rd_a[_rd_i]} == -p ]]; then _rd_pi=$((_rd_i + 1)); _rd_p=${_rd_a[_rd_pi]:-}; break; fi
  done
  if ((_rd_pi < 0)); then builtin read "$@"; return; fi
  [[ $_rd_p == 请选择* || $_rd_p == 输入序号* ]] && { _rd_p="  ${B}›${N} $_rd_p"; _rd_a[_rd_pi]=$_rd_p; }
  _rd_var=${_rd_a[${#_rd_a[@]}-1]}
  [[ $_rd_p == *按回车* || $_rd_p == *"(0-"* ]] && _rd_cancel=0
  if ((_rd_cancel)) && [[ $_rd_p == *": " && $_rd_p != 请选择* && $_rd_p != *"0 返回"* \
        && $_rd_p != *回车取消* && $_rd_p != *回车返回* && $_rd_p != *"[Y/n]"* && $_rd_p != *"[y/N]"* ]]; then
    _rd_a[_rd_pi]="${_rd_p%: } ${D}(0返回)${N}: "
  fi
  builtin read "${_rd_a[@]}" || return
  if ((_rd_cancel)) && [[ ${!_rd_var:-} == 0 ]]; then return 1; fi
  return 0
}

pause() { echo; read -r -p "${D}按回车键继续...${N}" _ || true; }

confirm() {
  local d=${2:-y} a hint
  [[ $d == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "$1 [$hint] " a || return 1
  a=${a:-$d}
  [[ $a =~ ^[Yy] ]]
}

ask() {  # 变量名 "提示" "默认值"  (变量已有值则跳过)
  local __v=$1 __p=$2 __d=${3:-} __in
  if [[ -n ${!__v:-} ]]; then return 0; fi
  if [[ -n $__d ]]; then
    read -r -p "$__p [$__d]: " __in || return 1
    __in=${__in:-$__d}
  else
    read -r -p "$__p: " __in || return 1
  fi
  printf -v "$__v" '%s' "$__in"
}

choose() {  # 结果变量 "标题" 选项1 选项2 ...   (数字选择, 默认第1项; 0 = 返回, 返回值 1)
  local __var=$1 __title=$2; shift 2
  local -a __items=("$@")
  local __i __c __last
  __last=${__items[${#__items[@]}-1]}
  echo "  ${D}$__title${N}"
  for __i in "${!__items[@]}"; do
    if [[ ${__items[__i]} == 返回* ]] && ((__i == ${#__items[@]} - 1)); then continue; fi
    printf '  %s%3d%s  %s%s%s\n' "$BD$B" $((__i + 1)) "$N" "$T" "${__items[__i]}" "$N"
  done
  mback
  while true; do
    read -r -p "请选择 [1]: " __c || return 1
    __c=${__c:-1}
    [[ $__c == 0 || $__c == q ]] && return 1
    if [[ $__c =~ ^[0-9]+$ ]] && ((__c >= 1 && __c <= ${#__items[@]})); then
      printf -v "$__var" '%s' "${__items[__c - 1]}"
      return 0
    fi
    warn "无效选择, 请输入 1-${#__items[@]}"
  done
}

read_secret() {
  local __v=$1 __in
  read -rs -p "$2: " __in || { echo; return 1; }
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

# ---------------- 安装记录: wsm 装过的软件包都记在这里, [系统维护 → 已安装组件] 可以统一卸载
# 装之前系统里就有的包不记录, 所以卸载时不会动系统原有的东西
# 记录格式: 包名<TAB>用途<TAB>日期     用途取自变量 PKG_FOR (调用方设置, 不设就留空)
LEDGER=$WSM_DIR/installed.list
PKG_FOR=""

pkg_has() {  # 包名 : 这个包是否已安装
  if [[ $PM == apt ]]; then [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == *'install ok installed'* ]]
  else rpm -q "$1" >/dev/null 2>&1; fi
}

ledger_add() {
  mkdir -p "$WSM_DIR"
  ledger_has "$1" && return 0
  printf '%s\t%s\t%s\n' "$1" "${2:-}" "$(date +%F)" >> "$LEDGER"
}

ledger_has() { [[ -f $LEDGER ]] && awk -F'\t' -v p="$1" '$1==p{f=1} END{exit !f}' "$LEDGER"; }
ledger_del() {
  [[ -f $LEDGER ]] || return 0
  awk -F'\t' -v p="$1" '$1!=p' "$LEDGER" > "$LEDGER.tmp" && mv -f "$LEDGER.tmp" "$LEDGER"
}

pkg_install() {
  local p rc
  local -a new=()
  for p in "$@"; do
    [[ $p == -* || $p == *'*'* ]] && continue
    pkg_has "$p" || new+=("$p")
  done
  if [[ $PM == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else dnf install -y "$@"; fi
  rc=$?
  for p in ${new[@]+"${new[@]}"}; do pkg_has "$p" && ledger_add "$p" "$PKG_FOR"; done
  return $rc
}

ensure_pkg() {  # 命令 包名 "用途说明" : 没有这个命令就询问并安装 (安装会记录, 可在 已安装组件 里卸载)
  local cmd=$1 pkg=$2 why=${3:-}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  confirm "需要安装 $pkg${why:+ ($why)}, 现在安装?" y || return 1
  info "正在安装 $pkg ..."
  pkg_refresh
  PKG_FOR=${why:-$pkg} pkg_install "$pkg" >/dev/null 2>&1 \
    || { [[ $PM == dnf ]] && pkg_install epel-release >/dev/null 2>&1 && PKG_FOR=${why:-$pkg} pkg_install "$pkg" >/dev/null 2>&1; }
  command -v "$cmd" >/dev/null 2>&1 && { info "$pkg 已安装"; return 0; }
  err "$pkg 安装失败"; return 1
}

web_installed() { command -v nginx >/dev/null 2>&1 && [[ -f $NGX_CONF/00-wsm.conf ]]; }

need_web() {
  web_installed && return 0
  echo
  warn "这个功能需要网站环境 (Nginx + PHP + MariaDB + certbot)"
  confirm "现在一键安装网站环境?" y || return 1
  cmd_install && web_installed
}

public_ip() {
  curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null \
    || curl -4 -s --max-time 4 https://ifconfig.me 2>/dev/null || true
}

unit_exists() { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"; }

svc_state() {
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

ini_set_kv() {
  local f=$1 k=$2 v=$3
  touch "$f"
  if grep -qE "^${k}[[:space:]]*=" "$f"; then
    sed -i -E "s|^${k}[[:space:]]*=.*|$k = $v|" "$f"
  else
    echo "$k = $v" >> "$f"
  fi
}

add_php_repo() {
  [[ $PM == apt ]] || return 0
  apt_fix_sources
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
  local v=${1:-} PKG_FOR=${PKG_FOR:-网站环境}
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

# ---------------- 旧版 Debian 软件源修复 (Debian 9/10/11)
# 1. backports 源已下线, 注释掉   2. Debian 11 安全源正确写法是 bullseye-security
# 3. 版本已被移到归档站 (deb.debian.org 上没有了) 时, 改用 archive.debian.org
APT_DIR=/etc/apt
APT_FIXED=0

apt_fix_sources() {
  [[ $PM == apt && ${OS_ID:-} == debian && $APT_FIXED == 0 ]] || return 0
  APT_FIXED=1
  local code=${OS_CODENAME:-} f sec changed=0
  [[ $code =~ ^(stretch|buster|bullseye)$ ]] || return 0
  for f in "$APT_DIR/sources.list" "$APT_DIR"/sources.list.d/*.list; do
    [[ -f $f ]] || continue
    if grep -qE "^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]${code}-backports([[:space:]]|$)" "$f"; then
      sed -i -E "/^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]${code}-backports([[:space:]]|$)/s/^/# wsm-disabled: /" "$f"; changed=1
    fi
    if [[ $code == bullseye ]] && grep -qE '[[:space:]]bullseye/updates([[:space:]]|$)' "$f"; then
      sed -i -E 's#^([[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?)[a-z]+://[^[:space:]]+[[:space:]]+bullseye/updates#\1http://security.debian.org/debian-security bullseye-security#' "$f"
      changed=1
    fi
  done
  # 是否已归档: 官方源上没有这个版本了
  if ! curl -fsI --max-time 10 "http://deb.debian.org/debian/dists/$code/Release" >/dev/null 2>&1 \
     && curl -fsI --max-time 10 "http://archive.debian.org/debian/dists/$code/Release" >/dev/null 2>&1; then
    [[ -f $APT_DIR/sources.list.wsm-bak ]] || cp -a "$APT_DIR/sources.list" "$APT_DIR/sources.list.wsm-bak" 2>/dev/null
    [[ $code == bullseye ]] && sec="$code-security" || sec="$code/updates"
    {
      echo "# managed by wsm: Debian $code 已归档, 改用 archive.debian.org (原文件: sources.list.wsm-bak)"
      echo "deb http://archive.debian.org/debian $code main contrib non-free"
      echo "deb http://archive.debian.org/debian-security $sec main contrib non-free"
    } > "$APT_DIR/sources.list"
    for f in "$APT_DIR"/sources.list.d/*.list; do
      [[ -f $f ]] || continue
      sed -i -E "/^[[:space:]]*deb(-src)?[[:space:]].*(\/debian\/?|\/debian-security\/?)[[:space:]]+${code}/s/^/# wsm-disabled: /" "$f"
    done
    echo 'Acquire::Check-Valid-Until "false";' > "$APT_DIR/apt.conf.d/99wsm-archive"
    changed=1
    warn "Debian $code 已停止维护并归档, 软件源已切换到 archive.debian.org (建议有空重装 Debian 12)"
  fi
  ((changed)) && info "已修复 Debian $code 的软件源"
  return 0
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
  local PKG_FOR="网站环境"
  info "安装 Nginx / certbot / 常用工具 ..."
  if [[ $PM == apt ]]; then
    apt_fix_sources
    apt-get update -y
    pkg_install nginx curl ca-certificates openssl cron certbot unzip tar gzip
    # 卸载后重装时 dpkg 认为配置文件是用户删掉的, 不会再生成 nginx.conf -> 强制补回缺失的配置文件
    if command -v nginx >/dev/null 2>&1 && [[ ! -f /etc/nginx/nginx.conf ]]; then
      info "补回缺失的 Nginx 配置文件 ..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall -o Dpkg::Options::=--force-confmiss nginx-common nginx >/dev/null 2>&1
    fi
    command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1 || die "基础软件安装失败"
    [[ -f /etc/nginx/nginx.conf ]] || die "Nginx 主配置 /etc/nginx/nginx.conf 缺失, 请执行: apt-get purge -y nginx nginx-common 后重新安装"
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
  wsm_logrotate
  self_install >/dev/null 2>&1
  realip_ensure
}

# ================================================================ 站点元数据
META_KEYS=(TYPE DOMAIN ALIASES ROOT PHPVER UPSTREAM SSL FORCE_HTTPS CERT_MODE REWRITE
           AUTH HOTLINK HOTLINK_DOMAINS IP_MODE IP_LIST GZIP CACHE REDIRECT_TO REDIRECT_CODE DISABLED
           TAMPER TAMPER_EXCLUDE NOEXEC GUARD GUARD_LEVEL GUARD_SKIP APP)

meta_defaults() {
  TYPE=; DOMAIN=; ALIASES=; ROOT=; PHPVER=; UPSTREAM=; SSL=0; FORCE_HTTPS=0; CERT_MODE=le
  REWRITE=none; AUTH=0; HOTLINK=0; HOTLINK_DOMAINS=; IP_MODE=none; IP_LIST=; GZIP=1; CACHE=0
  REDIRECT_TO=; REDIRECT_CODE=301; DISABLED=0; TAMPER=0; TAMPER_EXCLUDE=; NOEXEC=0; GUARD=0; GUARD_LEVEL=2; GUARD_SKIP=; APP=
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

pick_site() {  # [指定域名]  ->  SITE
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
safe_root() {
  [[ $1 =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+/?$ ]] || return 1
  case $1 in
    /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/dev/*|/proc/*|/sys/*|/root/*|/run/*|/var/lib/*|/var/log/*) return 1 ;;
  esac
  return 0
}

domain_used() {  # 域名 [排除的站点]  -> 输出占用它的站点
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

listen_lines() {
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

proxy_block() {
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
    app) ;;   # 程序模块自己的规则 (站点的 .app.nginx), 在 server_body 里输出
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
  guard_server_lines
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

  if [[ -f $META_DIR/$DOMAIN.app.nginx ]]; then  # 程序模块提供的专用规则
    local sock=""
    [[ $TYPE == php && -n $PHPVER ]] && sock="unix:$(php_sock "$PHPVER")"
    sed "s#__PHP_SOCK__#$sock#g" "$META_DIR/$DOMAIN.app.nginx"
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
  if [[ ${GUARD:-0} == 1 ]]; then guard_ensure_global || return 1; fi
  if [[ -n ${GUARD_SKIP:-} && -f $GUARD_CONF ]] && ! grep -qF "${DOMAIN//./\\.}" "$GUARD_CONF"; then
    guard_refresh_global >/dev/null 2>&1
  fi
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

finish_ssl() {  # 模式(le|custom|self)
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
    read -r -p "证书到期通知邮箱 (可留空): " email || return 1
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
    PKG_FOR="网站环境 (通配符证书插件)" pkg_install python3-certbot-dns-cloudflare || { err "插件安装失败"; return 1; }
  fi
  local cf=$WSM_DIR/cloudflare.ini token base n
  if [[ ! -f $cf ]] || confirm "已保存过 Cloudflare Token, 是否重新输入?" n; then
    echo "到 Cloudflare → 我的个人资料 → API 令牌 创建令牌, 权限: 区域→DNS→编辑"
    read_secret token "粘贴 API Token (输入不显示)" || return 1
    [[ -n $token ]] || { err "Token 为空"; return 1; }
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$cf"
    chmod 600 "$cf"
  fi
  base=${DOMAIN#www.}
  ask base "通配符所属主域名 (将申请 *.主域名)" "$base" || return 1
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

ssl_pick_method() {
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
# ---------------------------------------------------------------- 默认首页
default_page_php() {
  cat <<'WSMPAGE'
<?php
// 站点默认首页 (由 wsm 生成) - 兼容 PHP 7.4 ~ 8.4
// 测试完成后请删除本文件, 页面底部有"删除此页"按钮。
header('Content-Type: text/html; charset=utf-8');
header('X-Robots-Tag: noindex');

function h($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }
function ext_ok($e) {
    if ($e === 'opcache') { return extension_loaded('Zend OPcache') || function_exists('opcache_get_status'); }
    return extension_loaded($e);
}

$self    = __FILE__;
$age     = time() - (int)@filemtime($self);
$expired = $age > 86400;            // 创建 24 小时后, 数据库测试自动关闭
$host    = preg_replace('/[^A-Za-z0-9.\-:]/', '', (string)($_SERVER['HTTP_HOST'] ?? 'localhost'));
$ip      = (string)($_SERVER['REMOTE_ADDR'] ?? '');
$https   = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');

// ---------- 删除本页 ----------
if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'del') {
    $ok = @unlink($self);
    echo '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       . '<body style="font:16px/1.7 system-ui,sans-serif;padding:48px 24px;text-align:center">'
       . ($ok ? '已删除测试页。现在可以上传你的网站程序了。' : '删除失败: 没有权限, 请用 SFTP 或在服务器上手动删除 ' . h(basename($self)))
       . '</body>';
    exit;
}

// ---------- 数据库连接测试 (只允许连本机, 且限制尝试次数) ----------
$dbMsg = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'db') {
    $lim = sys_get_temp_dir() . '/wsm_dbtest_' . md5($ip);
    $now = time();
    $hits = array_filter(array_map('intval', (array)@explode(',', (string)@file_get_contents($lim))), function ($t) use ($now) { return $t > $now - 3600; });
    if ($expired) {
        $dbMsg = [false, '测试页已超过 24 小时, 数据库测试已关闭。请删除本页。'];
    } elseif (count($hits) >= 10) {
        $dbMsg = [false, '尝试次数过多, 请 1 小时后再试。'];
    } elseif (!function_exists('mysqli_connect')) {
        $dbMsg = [false, '没有安装 mysqli 扩展'];
    } else {
        $hits[] = $now;
        @file_put_contents($lim, implode(',', $hits));
        mysqli_report(MYSQLI_REPORT_OFF);
        $m = mysqli_init();
        $m->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
        $ok = @$m->real_connect('localhost', trim((string)($_POST['user'] ?? '')), (string)($_POST['pass'] ?? ''), trim((string)($_POST['name'] ?? '')) ?: null);
        if (!$ok) {
            $dbMsg = [false, '连接失败: ' . $m->connect_error];
        } else {
            $dbMsg = [true, '连接成功 · 数据库版本 ' . $m->server_info];
            $m->close();
        }
    }
}

$exts = ['mysqli', 'pdo_mysql', 'curl', 'gd', 'mbstring', 'xml', 'zip', 'openssl', 'json', 'intl', 'bcmath', 'opcache', 'redis'];
$testfile = __DIR__ . '/.wsm_w_' . bin2hex(random_bytes(3));
$canWrite = @file_put_contents($testfile, '1') !== false;
if ($canWrite) { @unlink($testfile); }
$user = function_exists('posix_getpwuid') ? (posix_getpwuid(posix_geteuid())['name'] ?? '-') : get_current_user();
?>
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title><?= h($host) ?></title>
<style>
  :root {
    --bg:#f6f7fb; --card:#ffffff; --tx:#1b1f2a; --mut:#6b7385; --line:#e6e9f0;
    --pri:#3563f5; --pri-soft:rgba(53,99,245,.10); --ok:#10a25a; --ok-soft:rgba(16,162,90,.12);
    --bad:#d6342b; --bad-soft:rgba(214,52,43,.10); --warn:#a8680a; --warn-soft:rgba(240,170,40,.16);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:#0e1015; --card:#161a22; --tx:#e9ecf3; --mut:#97a0b3; --line:#252b36;
      --pri:#7b98ff; --pri-soft:rgba(123,152,255,.14); --ok:#3ccf86; --ok-soft:rgba(60,207,134,.14);
      --bad:#ff7b72; --bad-soft:rgba(255,123,114,.14); --warn:#f0be5a; --warn-soft:rgba(240,190,90,.14);
    }
  }
  * { box-sizing:border-box; }
  html { -webkit-text-size-adjust:100%; }
  body {
    margin:0; color:var(--tx); background:var(--bg);
    background-image:radial-gradient(900px 380px at 50% -120px, var(--pri-soft), transparent 70%);
    background-repeat:no-repeat;
    font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
  }
  .wrap { max-width:680px; margin:0 auto; padding:56px 16px 40px; }
  .hero { text-align:center; margin-bottom:32px; }
  .logo {
    width:56px; height:56px; margin:0 auto 18px; border-radius:16px; display:grid; place-items:center;
    background:var(--pri); color:#fff; box-shadow:0 10px 28px var(--pri-soft);
  }
  .logo svg { width:28px; height:28px; }
  h1 { margin:0 0 6px; font-size:26px; line-height:1.25; letter-spacing:-.01em; word-break:break-all; }
  .sub { margin:0; color:var(--mut); }
  .chips { display:flex; flex-wrap:wrap; gap:8px; justify-content:center; margin-top:18px; }
  .chip { padding:3px 12px; border-radius:999px; font-size:13px; background:var(--pri-soft); color:var(--pri); }
  .chip.ok { background:var(--ok-soft); color:var(--ok); }
  .chip.off { background:var(--warn-soft); color:var(--warn); }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:20px 22px; margin-bottom:16px; }
  .card h2 { margin:0 0 12px; font-size:15px; font-weight:600; }
  .card h2 small { font-weight:400; color:var(--mut); margin-left:8px; }
  .row { display:flex; justify-content:space-between; gap:16px; padding:9px 0; border-bottom:1px solid var(--line); }
  .row:last-child { border-bottom:0; padding-bottom:0; }
  .row span:first-child { color:var(--mut); flex:none; }
  .row span:last-child { text-align:right; word-break:break-all; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(98px,1fr)); gap:8px; }
  .ext { display:flex; align-items:center; gap:7px; padding:7px 10px; border:1px solid var(--line); border-radius:10px; font-size:13px; }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--ok); flex:none; }
  .ext.no { color:var(--mut); } .ext.no .dot { background:var(--bad); }
  form { display:grid; gap:10px; }
  .two { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  input {
    width:100%; padding:11px 12px; font:inherit; color:var(--tx); background:var(--bg);
    border:1px solid var(--line); border-radius:10px; outline:none;
  }
  input:focus { border-color:var(--pri); box-shadow:0 0 0 3px var(--pri-soft); }
  button {
    padding:11px 16px; font:inherit; font-weight:600; border:0; border-radius:10px; cursor:pointer;
    background:var(--pri); color:#fff;
  }
  button.ghost { background:transparent; color:var(--bad); border:1px solid var(--line); font-weight:500; }
  button:disabled, input:disabled { opacity:.5; cursor:not-allowed; }
  .msg { padding:10px 14px; border-radius:10px; margin-bottom:12px; font-size:14px; }
  .msg.ok { background:var(--ok-soft); color:var(--ok); } .msg.bad { background:var(--bad-soft); color:var(--bad); }
  .note { color:var(--mut); font-size:13px; margin:12px 0 0; }
  .foot { text-align:center; color:var(--mut); font-size:13px; margin-top:28px; }
  .foot form { display:inline; }
  @media (max-width:480px) { .wrap { padding-top:40px; } h1 { font-size:22px; } .two { grid-template-columns:1fr; } }
</style>
</head>
<body>
<div class="wrap">

  <div class="hero">
    <div class="logo">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>
    </div>
    <h1><?= h($host) ?></h1>
    <p class="sub">站点创建成功, 服务运行正常</p>
    <div class="chips">
      <span class="chip">PHP <?= h(PHP_VERSION) ?></span>
      <span class="chip <?= $https ? 'ok' : 'off' ?>"><?= $https ? 'HTTPS 已启用' : 'HTTP · 未启用 HTTPS' ?></span>
      <span class="chip ok"><?= h(PHP_SAPI) ?></span>
    </div>
  </div>

  <div class="card">
    <h2>运行环境</h2>
    <div class="row"><span>服务器</span><span><?= h($_SERVER['SERVER_SOFTWARE'] ?? '-') ?></span></div>
    <div class="row"><span>网站目录</span><span><?= h(__DIR__) ?></span></div>
    <div class="row"><span>运行用户</span><span><?= h($user) ?></span></div>
    <div class="row"><span>目录可写</span><span><?= $canWrite ? '是' : '否 (上传 / 缓存类程序会出错)' ?></span></div>
    <div class="row"><span>服务器时间</span><span><?= h(date('Y-m-d H:i:s')) ?> · <?= h(date_default_timezone_get()) ?></span></div>
    <div class="row"><span>上传 / 内存 / 超时</span><span><?= h(ini_get('upload_max_filesize')) ?> / <?= h(ini_get('memory_limit')) ?> / <?= h(ini_get('max_execution_time')) ?>s</span></div>
  </div>

  <div class="card">
    <h2>PHP 扩展</h2>
    <div class="grid">
      <?php foreach ($exts as $e): $ok = ext_ok($e); ?>
        <div class="ext <?= $ok ? '' : 'no' ?>"><i class="dot"></i><?= h($e) ?></div>
      <?php endforeach; ?>
    </div>
  </div>

  <div class="card">
    <h2>数据库连接测试<small>仅限本机 localhost</small></h2>
    <?php if ($dbMsg): ?>
      <div class="msg <?= $dbMsg[0] ? 'ok' : 'bad' ?>"><?= h($dbMsg[1]) ?></div>
    <?php endif; ?>
    <form method="post" autocomplete="off">
      <input type="hidden" name="action" value="db">
      <div class="two">
        <input name="user" placeholder="数据库用户名" value="<?= h($_POST['user'] ?? '') ?>" <?= $expired ? 'disabled' : '' ?>>
        <input name="pass" type="password" placeholder="数据库密码" <?= $expired ? 'disabled' : '' ?>>
      </div>
      <input name="name" placeholder="数据库名 (可留空)" value="<?= h($_POST['name'] ?? '') ?>" <?= $expired ? 'disabled' : '' ?>>
      <button type="submit" <?= $expired ? 'disabled' : '' ?>>测试连接</button>
    </form>
    <p class="note"><?= $expired ? '创建已超过 24 小时, 测试功能已自动关闭。' : '密码只用于本次连接, 不会保存。数据库可在服务器上执行 wsm → 数据库 里创建。' ?></p>
  </div>

  <div class="foot">
    <p>这是自动生成的测试页, 会显示服务器信息, 用完请删除。</p>
    <form method="post" onsubmit="return confirm('确定删除这个测试页吗?')">
      <input type="hidden" name="action" value="del">
      <button class="ghost" type="submit">删除此页</button>
    </form>
  </div>

</div>
</body>
</html>
WSMPAGE
}

default_page_static() {
  cat <<'WSMPAGE'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>__DOMAIN__</title>
<style>
  :root { --bg:#f6f7fb; --card:#fff; --tx:#1b1f2a; --mut:#6b7385; --line:#e6e9f0; --pri:#3563f5; --pri-soft:rgba(53,99,245,.10); }
  @media (prefers-color-scheme: dark) { :root { --bg:#0e1015; --card:#161a22; --tx:#e9ecf3; --mut:#97a0b3; --line:#252b36; --pri:#7b98ff; --pri-soft:rgba(123,152,255,.14); } }
  * { box-sizing:border-box; }
  body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px 16px; color:var(--tx); background:var(--bg);
    background-image:radial-gradient(900px 380px at 50% -120px, var(--pri-soft), transparent 70%); background-repeat:no-repeat;
    font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif; }
  .box { width:100%; max-width:420px; text-align:center; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:40px 28px; }
  .logo { width:56px; height:56px; margin:0 auto 18px; border-radius:16px; display:grid; place-items:center; background:var(--pri); color:#fff; box-shadow:0 10px 28px var(--pri-soft); }
  .logo svg { width:28px; height:28px; }
  h1 { margin:0 0 6px; font-size:24px; line-height:1.25; word-break:break-all; }
  p { margin:0; color:var(--mut); }
  .tip { margin-top:22px; padding-top:18px; border-top:1px solid var(--line); font-size:13px; }
</style>
</head>
<body>
  <div class="box">
    <div class="logo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div>
    <h1>__DOMAIN__</h1>
    <p>站点创建成功, 服务运行正常</p>
    <p class="tip">把你的网站文件上传到网站目录, 替换本页 (index.html) 即可。</p>
  </div>
</body>
</html>
WSMPAGE
}

write_default_page() {  # 网站目录 类型(php|static) 域名
  local root=$1 type=$2 domain=$3
  if [[ $type == php ]]; then default_page_php > "$root/index.php"
  else default_page_static | sed "s/__DOMAIN__/$domain/g" > "$root/index.html"; fi
}

add_site() {
  local type=$1 domain=${2:-} extra=${3:-} aliases="" root=${PRESET_ROOT:-} a u
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  title "新建$(type_name "$type")"
  ask domain "① 主域名 (如 example.com)" || return 1
  valid_domain "$domain" || die "域名格式不正确: $domain"
  [[ -f $(meta_file "$domain") ]] && die "站点已存在: $domain"
  read -r -p "② 绑定其他域名 (空格分隔, 可留空, 如 www.$domain): " aliases || return 1
  for a in $aliases; do
    valid_domain "$a" || die "域名格式不正确: $a"
    u=$(domain_used "$a") && die "域名 $a 已被站点 $u 使用"
  done
  u=$(domain_used "$domain") && die "域名 $domain 已被站点 $u 使用"

  meta_defaults
  TYPE=$type; DOMAIN=$domain; ALIASES=$aliases
  case $type in
    php|static)
      ask root "③ 网站根目录" "$WWW_ROOT/$domain" || return 1
      safe_root "$root" || die "目录不合法: 需为至少两级的普通路径(如 /www/wwwroot/xxx), 且不能在 /etc /usr /root 等系统目录下"
      ROOT=${root%/}
      mkdir -p "$ROOT"
      if [[ ! -e $ROOT/index.html && ! -e $ROOT/index.php ]]; then
        write_default_page "$ROOT" "$type" "$domain"
      fi
      fix_perms_dir "$ROOT"
      if [[ $type == php ]]; then
        choose_php || die "没有可用的 PHP"
        PHPVER=$CHOSEN_PHP
      fi
      ;;
    proxy)
      ask extra "③ 后端地址 (如 http://127.0.0.1:3000)" || return 1
      valid_url "$extra" || die "后端地址格式不正确(不能含空格/引号/分号等)"
      UPSTREAM=$extra
      selinux_tune
      ;;
    redirect)
      ask extra "③ 跳转到 (如 https://www.example.com, 不带结尾斜杠)" || return 1
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
  [[ -n ${PRESET_PHP:-} ]] && { CHOSEN_PHP=$PRESET_PHP; return 0; }
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

rm_path_safe() {  # 路径 : 只删至少两级的普通目录/文件, 系统目录和顶层目录一律不删
  local p=${1%/}
  [[ -n $p && -e $p ]] || return 0
  safe_root "$p" || { warn "跳过不安全的路径: $p"; return 1; }
  case $p in /opt|/www|"$WWW_ROOT"|/home|/srv|/var|/var/www|/tmp) warn "跳过: $p"; return 1 ;; esac
  rm -rf -- "$p"
}

del_site() {  # [域名]   (DEL_MODE=uninstall 时: 程序文件直接删, 只问数据库和用户数据)
  use_site "${1:-}" || return 1
  local d=$DOMAIN app=${APP:-} mode=${DEL_MODE:-} x db="" dbu="" del_files=0 del_data=0 del_db=0
  local -a files=() data=()
  if [[ -n $app ]] && app_has "$app" files; then mapfile -t files < <(app_call "$app" files "$d" "$ROOT")
  elif [[ -n $ROOT && -d $ROOT ]]; then files=("$ROOT"); fi
  [[ -n $app ]] && mapfile -t data < <(app_call "$app" data "$d" "$ROOT")
  if [[ -n $app ]] && app_has "$app" dbinfo; then read -r db dbu < <(app_call "$app" dbinfo "$d" "$ROOT"); fi
  [[ $db =~ ^[A-Za-z0-9_]+$ ]] || db=""
  [[ $dbu =~ ^[A-Za-z0-9_]+$ ]] || dbu=""

  echo "  将删除站点: $d${app:+  (${APP_NAMES[$app]:-$app})}"
  echo "   - Nginx 配置、证书、访问密码等站点设置"
  [[ -n $app ]] && app_has "$app" purge && echo "   - 程序的后台服务 / 定时任务"
  if ((${#files[@]} > 3)); then
    echo "   - 程序文件: ${#files[@]} 项, 在 ${files[0]%/*}/$([[ $mode == uninstall ]] || echo "  (会再问一次)")"
  else
    for x in "${files[@]}"; do [[ -n $x && -e $x ]] && echo "   - 程序文件: $x$([[ $mode == uninstall ]] || echo "  (会再问一次)")"; done
  fi
  for x in "${data[@]}"; do [[ -n $x && -e $x ]] && echo "   - 用户数据: $x  (会再问一次)"; done
  [[ -n $db ]] && echo "   - 数据库: $db  (会再问一次)"
  [[ -n $app ]] && warn "删除后无法恢复, 重要数据请先备份 ([备份与搬家] → 立即全量备份)"
  confirm "确认$([[ $mode == uninstall ]] && echo 卸载 || echo 删除)站点 $d ?" n || return 0

  if [[ $mode == uninstall ]]; then del_files=1
  elif ((${#files[@]})) && [[ -e ${files[0]} ]]; then
    if ((${#files[@]} > 3)); then x="${files[0]%/*}/ 下的程序文件"; else x=${files[*]}; fi
    confirm "同时删除程序文件 ($x) ?" n && del_files=1
  fi
  for x in "${data[@]}"; do
    [[ -n $x && -e $x ]] && { confirm "同时删除用户数据 $x (删了就找不回来)?" n && del_data=1; break; }
  done
  if [[ -n $db ]] && mysql -N -e "SHOW DATABASES LIKE '$db'" 2>/dev/null | grep -qx "$db"; then
    confirm "同时删除数据库 $db 和它的账号 (网站内容都在里面)?" n && del_db=1
  else db=""; fi

  [[ -n $app ]] && app_call "$app" purge "$d" "$ROOT"
  rm -f "$NGX_CONF/$d.conf"
  [[ $TAMPER == 1 && -d $ROOT ]] && chattr -R -i "$ROOT" 2>/dev/null
  rm -f "$WSM_DIR/baseline/$d.sha256" "$WSM_DIR/baseline/$d.tar.gz"
  [[ -f $CRON_TASKS ]] && sed -i "\|tamper-check $d |d" "$CRON_TASKS"
  if [[ $SSL == 1 && $CERT_MODE == le ]]; then
    certbot delete --cert-name "$d" --non-interactive >/dev/null 2>&1 || true
  fi
  rm -rf "$CERT_DIR/$d"
  rm -f "$AUTH_DIR/$d.htpasswd" "$META_DIR/$d.paths" "$META_DIR/$d.rewrite" "$META_DIR/$d.app.nginx" "$(meta_file "$d")"
  if [[ -n ${GUARD_SKIP:-} ]] || { [[ -n $app ]] && app_has "$app" guard_skip; }; then guard_refresh_global; fi
  nginx_reload >/dev/null 2>&1

  if ((del_files)); then
    [[ $TAMPER == 1 ]] && for x in "${files[@]}"; do [[ -d $x ]] && chattr -R -i "$x" 2>/dev/null; done
    for x in "${files[@]}"; do rm_path_safe "$x"; done
    echo "   已删除程序文件"
  fi
  if ((del_data)); then for x in "${data[@]}"; do rm_path_safe "$x"; done; echo "   已删除用户数据"
  else for x in "${data[@]}"; do [[ -n $x && -e $x ]] && echo "   保留了用户数据: $x"; done; fi
  if ((del_db)); then
    app_db_drop "$db" "$dbu"; echo "   已删除数据库 $db"
  elif [[ -n $db ]]; then echo "   保留了数据库: $db"; fi
  [[ -n $app ]] && app_call "$app" cleanup "$d"
  info "已$([[ $mode == uninstall ]] && echo 卸载 || echo 删除) $d"
}

app_site_uninstall() {  # 域名 : 程序菜单里的 [卸载]
  local d=$1
  title "卸载 ${APP_NAMES[$(app_of_site "$d")]:-程序} · $d"
  DEL_MODE=uninstall del_site "$d"
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
  echo "  防CC/bot: $([[ ${GUARD:-0} == 1 ]] && echo "${G}已开启${N} ($(guard_level_name "${GUARD_LEVEL:-2}"))" || echo 未开启)"
}

need_type() {  # 类型...  (当前 TYPE 不在其中则提示)
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
  ask r "新的网站根目录" "$ROOT" || return 1
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
    ask v "新的后端地址" "$UPSTREAM" || return 1
    valid_url "$v" || { err "地址格式不正确"; return 1; }
    UPSTREAM=$v
  else
    ask v "新的跳转目标" "$REDIRECT_TO" || return 1
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
  if [[ $REWRITE == app ]]; then
    warn "这个站点的规则由程序模块 (${APP:-?}) 管理, 改了程序可能打不开, 这里不提供修改"
    return 1
  fi
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
        read_secret pw "密码 (输入不显示)" || continue
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
      read -r -p "额外允许的域名 (空格分隔, 可留空): " w || return 1
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

site_toggle() {
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
      访问统计*) stat_range_pick && STAT_ASK=1 stat_show "$d" "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
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

# ================================================================ 防 CC / 防恶意 bot
# 原理: 1) 全局文件 01-wsm-guard.conf 定义规则 (只定义, 不生效)
#       2) 站点开启后, 在站点配置里引用这些规则才生效 (每个站点单独开关)
#       3) 静态文件和网站应用模块声明的接口 (如面板节点接口、订阅链接) 不限速也不拦截, 避免误伤
GUARD_CONF=$NGX_CONF/01-wsm-guard.conf

guard_level_name() { case $1 in 1) echo "宽松" ;; 3) echo "严格" ;; *) echo "标准" ;; esac; }
guard_level_desc() {
  case $1 in
    1) echo "每个 IP 每秒 30 次, 突发 100 次" ;;
    3) echo "每个 IP 每秒 5 次, 突发 20 次" ;;
    *) echo "每个 IP 每秒 10 次, 突发 50 次" ;;
  esac
}
guard_burst() { case $1 in 1) echo 100 ;; 3) echo 20 ;; *) echo 50 ;; esac; }

guard_cf_ranges() {  # 输出 Cloudflare 回源 IP 段 (先在线获取, 失败用内置列表)
  local v4 v6
  v4=$(curl -fsS --max-time 6 https://www.cloudflare.com/ips-v4/ 2>/dev/null | grep -E '^[0-9.]+/[0-9]+$')
  v6=$(curl -fsS --max-time 6 https://www.cloudflare.com/ips-v6/ 2>/dev/null | grep -E '^[0-9a-fA-F:]+/[0-9]+$')
  [[ -n $v4 ]] || v4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15
104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
  [[ -n $v6 ]] || v6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32"
  printf '%s\n%s\n' "$v4" "$v6" | tr ' ' '\n' | grep -v '^$'
}

guard_write_global() {  # 写全局规则文件到 $GUARD_CONF.tmp (真实 IP 在 00-wsm-realip.conf 里)
  {
    echo "# managed by wsm - 防 CC / 防恶意 bot 的公共规则 (站点开启防护后才生效)"
    cat <<'EOF'

# 不限速、不拦截的请求: 静态文件 + 各网站应用模块声明的接口
map $request_uri $wsm_skip {
    default 0;
    ~*\.(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|eot|map)(\?|$)   1;
EOF
    apps_hook guard_skip
    echo "}"
    echo
    echo "# 各站点自己设置的放行路径 (站点 → 防 CC → 放行路径)"
    echo 'map "$host:$uri" $wsm_pass {'
    echo "    default 0;"
    guard_pass_lines
    echo "}"
    cat <<'EOF'
map "$wsm_skip$wsm_pass" $wsm_free {
    "00"    0;
    default 1;
}
map $wsm_free $wsm_key {
    1       "";
    default $binary_remote_addr;
}

# 空 User-Agent: 只有 [严格] 强度才拦截 (很多探针/回调/脚本不带 User-Agent, 拦了容易误伤)
map "$wsm_free:$http_user_agent" $wsm_empty_ua {
    default 0;
    "0:"    1;
    "0:-"   1;
}

# 恶意扫描器 / 攻击工具 / 高频采集爬虫 (正常搜索引擎不受影响)
map "$wsm_free:$http_user_agent" $wsm_bad_ua {
    default 0;
    ~^1:    0;
    ~*^0:.*(sqlmap|nikto|nmap|masscan|zgrab|zmap|nuclei|acunetix|netsparker|wpscan|dirbuster|gobuster|feroxbuster|ffuf|wfuzz|hydra|jaeles|whatweb|zmeu|morfeus|libwww-perl|python-urllib|scrapy|httrack|ahrefsbot|semrushbot|mj12bot|dotbot|blexbot|dataforseobot|megaindex|serpstatbot|bytespider)  1;
}

# 扫描敏感文件的请求
map $uri $wsm_bad_path {
    default 0;
    ~*/\.(env|git|svn|hg|bzr|ds_store|idea|vscode|aws|ssh|htpasswd)(/|$)   1;
    ~*\.(sql|sqlite|bak|backup|old|orig|swp|swo)$                         1;
    ~*/(vendor/phpunit|phpunit/|eval-stdin\.php|cgi-bin/|boaform|hnap1|actuator/|solr/admin)  1;
}
# WordPress 专用路径 (非 WordPress 站点被访问这些就是在扫漏洞)
map $uri $wsm_wp_path {
    default 0;
    ~*/(wp-login\.php|xmlrpc\.php|wp-config\.php|wp-admin/|wp-includes/|wp-content/plugins/)  1;
}

limit_req_zone  $wsm_key zone=wsm_l1:20m rate=30r/s;
limit_req_zone  $wsm_key zone=wsm_l2:20m rate=10r/s;
limit_req_zone  $wsm_key zone=wsm_l3:20m rate=5r/s;
limit_conn_zone $wsm_key zone=wsm_conn:20m;
limit_req_status  429;
limit_conn_status 429;
limit_req_log_level warn;
EOF
  } > "$GUARD_CONF.tmp"
}

guard_pass_lines() {  # 各站点的放行路径 -> map 行: "~*^(域名|别名):/路径" 1;
  local d
  while read -r d; do
    [[ -n $d ]] || continue
    ( load_meta "$d" 2>/dev/null || exit 0
      [[ -n ${GUARD_SKIP:-} ]] || exit 0
      hosts=""
      for h in $DOMAIN $ALIASES; do valid_domain "$h" && hosts+="${hosts:+|}${h//./\\.}"; done
      [[ -n $hosts ]] || exit 0
      for p in $GUARD_SKIP; do
        [[ $p =~ ^/[A-Za-z0-9._~/-]{0,100}$ ]] || continue
        printf '    "~*^(%s):%s"   1;\n' "$hosts" "$(printf '%s' "$p" | sed 's/\./\\./g')"
      done )
  done < <(list_site_names)
  return 0
}

guard_ensure_global() {  # 全局文件不存在就生成并检测, 失败回滚; 旧版本生成的规则自动升级
  if [[ -f $GUARD_CONF ]]; then
    grep -q 'wsm_empty_ua' "$GUARD_CONF" || guard_refresh_global
    return 0
  fi
  guard_write_global
  mv -f "$GUARD_CONF.tmp" "$GUARD_CONF"
  nginx -t >/dev/null 2>&1 && return 0
  nginx -t 2>&1 | tail -3 >&2
  rm -f "$GUARD_CONF"
  err "Nginx 不支持防护规则 (缺少 limit_req / map 模块?)"
  return 1
}

guard_refresh_global() {  # 重新生成全局规则 (模块增删、后台路径变化后), 失败恢复旧文件
  [[ -f $GUARD_CONF ]] || return 0
  local bak; bak=$(mktemp); cp -f "$GUARD_CONF" "$bak"
  guard_write_global
  mv -f "$GUARD_CONF.tmp" "$GUARD_CONF"
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1; rm -f "$bak"; return 0; fi
  mv -f "$bak" "$GUARD_CONF"
  err "防护规则更新失败, 已恢复原规则"; return 1
}

guard_server_lines() {  # 输出站点配置里的防护指令 (依赖 load_meta)
  [[ ${GUARD:-0} == 1 ]] || return 0
  local lv=${GUARD_LEVEL:-2}
  [[ $lv == 1 || $lv == 3 ]] || lv=2
  echo "    # wsm 防护: 恶意 bot / 敏感文件扫描 / 限速 (模块声明的接口已排除)"
  echo '    if ($wsm_bad_ua) { return 444; }'
  [[ $lv == 3 ]] && echo '    if ($wsm_empty_ua) { return 444; }'
  echo '    if ($wsm_bad_path) { return 444; }'
  [[ $REWRITE == wordpress ]] || echo '    if ($wsm_wp_path) { return 444; }'
  echo "    limit_req zone=wsm_l$lv burst=$(guard_burst "$lv") nodelay;"
  echo "    limit_conn wsm_conn 60;"
}

guard_log() {  # 域名: 最近被拦截的情况 (原因 / 路径 / IP / 程序名), 可以一键放行路径
  local f="/var/log/nginx/$1.access.log" n n444 n429 p
  local -a top=()
  [[ -f $f ]] || { warn "还没有访问日志"; return 0; }
  n444=$(tail -n 20000 "$f" | awk '$9==444' | wc -l)
  n429=$(tail -n 20000 "$f" | awk '$9==429' | wc -l)
  n=$((n444 + n429))
  echo "最近 2 万条访问里, 被拦截 $n 次:"
  echo "   ${n444} 次 444 = 恶意程序 / 敏感文件 / 空程序名(严格模式)"
  echo "   ${n429} 次 429 = 请求太快, 被限速"
  ((n > 0)) || return 0
  echo; echo "被拦最多的路径:"
  mapfile -t top < <(tail -n 20000 "$f" | awk '$9==444 || $9==429 {split($7, a, "?"); print $9, a[1]}' \
    | sort | uniq -c | sort -rn | head -8)
  printf '%s\n' "${top[@]}" | awk '{printf "  %-8s %s  %s\n", $1"次", ($2==444 ? "拒绝" : "限速"), $3}'
  echo; echo "被拒绝最多的程序名 (User-Agent):"
  tail -n 20000 "$f" | awk -F'"' '{split($3, s, " ")} s[1]==444 {print ($6=="" || $6=="-") ? "(空)" : substr($6, 1, 60)}' \
    | sort | uniq -c | sort -rn | head -5 | sed 's/^/  /'
  echo; echo "拦截最多的 IP:"
  tail -n 20000 "$f" | awk '$9==444 || $9==429 {print $1}' | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %-8s %s\n", $1"次", $2}'
  local -a paths=()
  mapfile -t paths < <(printf '%s\n' "${top[@]}" | awk '{print $3}' | awk '!seen[$0]++' \
    | grep -viE '/\.|\.(sql|sqlite|bak|backup|old|orig|swp|env)$|wp-|phpunit|cgi-bin|xmlrpc')
  ((${#paths[@]})) || return 0
  echo
  confirm "有正常程序 (探针/回调) 被误伤? 把它的路径加入放行" n || return 0
  choose p "放行哪个路径:" "${paths[@]}" || return 0
  guard_skip_add "$1" "$p"
}

guard_warn() {  # 开启防护前的提示 (只说一次)
  echo
  warn "开启防 CC 前请注意, 它可能误伤这些访问:"
  echo "   - 机器人探针、Webhook 回调、监控等程序: 请求太频繁会被限速 (返回 429)"
  echo "   - 程序名在拦截名单里的脚本 (如 python-urllib、scrapy、httrack 等采集工具): 会被直接拒绝 (444)"
  echo "   - 公司/学校/机房等很多人共用一个出口 IP 时: 可能一起被限速"
  realip_on || echo "   - ${R}CDN 真实IP 已关闭${N}: 走 CDN 的网站会按 CDN 节点限速, 大面积误封, 建议先开启"
  echo "   遇到误伤: 在本站点 [放行路径] 里加上被拦的接口路径 (查看拦截记录能看到是哪个), 或者关闭防护"
  echo
}

guard_set() {  # 域名 on|off   (GUARD_NOWARN=1 时不提示)
  load_meta "$1"
  if [[ $2 == on ]]; then
    if [[ -z ${GUARD_NOWARN:-} && ${GUARD:-0} != 1 ]]; then
      guard_warn
      confirm "确认为 $DOMAIN 开启防 CC?" n || return 0
    fi
    guard_ensure_global || return 1
    [[ -n ${APP:-} ]] && app_call "$APP" guard_on "$1"
    GUARD=1
  else
    GUARD=0
  fi
  apply_site || return 1
  if [[ $2 == on ]]; then
    info "已开启防护: $DOMAIN (强度: $(guard_level_name "${GUARD_LEVEL:-2}"))"
  else
    info "已关闭防护: $DOMAIN"
  fi
}

guard_menu() {
  local d=$1 c lv
  while true; do
    load_meta "$d"
    title "防 CC / 防恶意 bot · $d"
    echo "  状态:     $([[ ${GUARD:-0} == 1 ]] && echo "${G}已开启${N}" || echo 未开启)"
    echo "  强度:     $(guard_level_name "${GUARD_LEVEL:-2}") ($(guard_level_desc "${GUARD_LEVEL:-2}"))"
    echo
    echo "  开启后会:"
    echo "   - 拦截扫描器/攻击工具和高频采集爬虫, 正常搜索引擎不受影响"
    echo "   - 拦截扫描 .env / .git / 备份文件 等敏感文件的请求"
    echo "   - 限制同一个 IP 的请求速度, 防 CC 和刷接口 (超出返回 429)"
    echo "   - 静态文件, 以及网站应用模块声明的接口 (如面板节点接口/订阅链接) 不受影响"
    echo "  放行路径: ${GUARD_SKIP:-无}"
    choose c "操作:" "$([[ ${GUARD:-0} == 1 ]] && echo 关闭防护 || echo 开启防护)" "调整强度" \
      "查看拦截记录" "放行路径 (探针/回调等接口不受防护)" "返回" || return 0
    case $c in
      开启防护) guard_set "$d" on ;;
      关闭防护) guard_set "$d" off ;;
      调整强度)
        choose lv "选择强度:" "宽松 ($(guard_level_desc 1))" "标准 ($(guard_level_desc 2), 推荐)" \
          "严格 ($(guard_level_desc 3))" || continue
        case $lv in 宽松*) GUARD_LEVEL=1 ;; 严格*) GUARD_LEVEL=3 ;; *) GUARD_LEVEL=2 ;; esac
        apply_site && info "强度已改为: $(guard_level_name "$GUARD_LEVEL")"
        ;;
      查看拦截记录) guard_log "$d"; pause ;;
      放行路径*) guard_skip_menu "$d" ;;
      *) return 0 ;;
    esac
  done
}

guard_skip_set() {  # 域名 "路径 路径..." : 保存放行路径并更新规则
  ( load_meta "$1"; GUARD_SKIP=$2; save_meta )
  guard_refresh_global
}

guard_skip_add() {
  local p=$2 cur
  [[ $p == /* ]] || p="/$p"
  [[ $p =~ ^/[A-Za-z0-9._~/-]{0,100}$ ]] || { err "路径格式不正确 (如 /probe.php 或 /api/)"; return 1; }
  cur=$( load_meta "$1"; echo "${GUARD_SKIP:-}" )
  [[ " $cur " == *" $p "* ]] && { info "已经在放行列表里"; return 0; }
  guard_skip_set "$1" "${cur:+$cur }$p" && info "已放行: $p (以 $p 开头的地址都不限速、不检查程序名)"
}

guard_skip_menu() {
  local d=$1 c p cur
  local -a arr=()
  while true; do
    cur=$( load_meta "$d"; echo "${GUARD_SKIP:-}" )
    title "放行路径 · $d"
    echo "  这些路径不限速、不检查程序名 (敏感文件拦截照样生效)。"
    echo "  适合: 机器人探针上报、Webhook 回调、支付通知等程序调用的接口。"
    echo "  请确认这些接口自己有密钥校验。"
    echo
    if [[ -n $cur ]]; then for p in $cur; do echo "   - $p"; done; else echo "   (无)"; fi
    choose c "操作:" "添加" "删除" "返回" || return 0
    case $c in
      添加) read -r -p "路径 (如 /probe.php、/api/): " p || continue; [[ -n $p ]] && guard_skip_add "$d" "$p"; pause ;;
      删除)
        read -r -a arr <<<"$cur"
        ((${#arr[@]})) || { warn "没有可删的"; continue; }
        choose p "删除哪个:" "${arr[@]}" || continue
        cur=" $cur "; cur=${cur// $p / }; cur=$(echo $cur)
        guard_skip_set "$d" "$cur" && info "已删除: $p"; pause ;;
      *) return 0 ;;
    esac
  done
}

guard_sites() {  # 能开防护的站点 (重定向站点不需要)
  local d
  while read -r d; do
    [[ -n $d ]] || continue
    [[ $( load_meta "$d" 2>/dev/null; echo "$TYPE" ) == redirect ]] || echo "$d"
  done < <(list_site_names)
}

guard_summary() {
  local n=0 t=0 d
  while read -r d; do
    [[ -n $d ]] || continue
    t=$((t + 1))
    [[ $( load_meta "$d" 2>/dev/null; echo "${GUARD:-0}" ) == 1 ]] && n=$((n + 1))
  done < <(guard_sites)
  ((t)) || { echo "没有站点"; return 0; }
  if ((n)); then echo "${G}$n${N}/$t 个站点已开启"; else echo "0/$t 个站点已开启"; fi
}

guard_overview() {
  local c d st
  local -a sites=() opts=()
  while true; do
    mapfile -t sites < <(guard_sites)
    title "防 CC / 恶意 bot"
    echo "  拦截扫描器/攻击工具/高频采集爬虫、敏感文件探测, 并限制单个 IP 的请求速度"
    echo "  按站点开关; 正常搜索引擎、静态文件和模块声明的接口不受影响"
    echo
    ((${#sites[@]})) || { warn "还没有站点"; pause; return 0; }
    opts=()
    for d in "${sites[@]}"; do
      st=$( load_meta "$d" 2>/dev/null; if [[ ${GUARD:-0} == 1 ]]; then echo "${G}已开启${N} ($(guard_level_name "${GUARD_LEVEL:-2}"))"; else echo "未开启"; fi )
      printf '   %-30s %s\n' "$d" "$st"
      opts+=("$d")
    done
    opts+=("全部开启" "全部关闭" "返回")
    choose c "选择站点进入设置, 或批量操作:" "${opts[@]}" || return 0
    case $c in
      全部开启)
        guard_warn
        if confirm "确认为全部 ${#sites[@]} 个站点开启防 CC?" n; then
          for d in "${sites[@]}"; do (GUARD_NOWARN=1 guard_set "$d" on); done
        fi
        pause ;;
      全部关闭) confirm "关闭所有站点的防护?" n && for d in "${sites[@]}"; do (guard_set "$d" off); done; pause ;;
      返回) return 0 ;;
      *) (guard_menu "$c") ;;
    esac
  done
}

guard_cli() {
  use_site "${1:-}" || return 1
  case ${2:-} in
    on|off) guard_set "$SITE" "$2" ;;
    *) guard_menu "$SITE" ;;
  esac
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
      "查看Nginx配置" "日志统计" "备份此站点" "修复权限" "网站防篡改" "防CC/防恶意bot")
    local __k
    for __k in "${!__it[@]}"; do
      printf '  %s%3d%s  %s' "$BD$B" $((__k + 1)) "$N" "$T"; pad_w "${__it[__k]}" 16; printf '%s' "$N"
      ((__k % 2)) && echo || printf ' '
    done
    ((${#__it[@]} % 2)) && echo
    mback
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
      18) guard_menu "$d" ;;
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

tamper_prune_args() {  # 基准目录 -> TP_ARGS (find 的排除参数)
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

tamper_check() {
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
need_mysql() { command -v mysql >/dev/null 2>&1 || { err "还没安装 MariaDB, 请先在 [程序下载] 里安装"; return 1; }; }

install_db() {
  local PKG_FOR=${PKG_FOR:-数据库 MariaDB}
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
  ask name "数据库名" || return 1
  [[ $name =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "名称只能含字母数字下划线, 最长 32"
  user=$name
  read -r -p "数据库用户名 [$name]: " user || return 1
  user=${user:-$name}
  [[ $user =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "用户名格式不正确"
  choose mode "密码:" "自动生成强密码" "我自己输入" || return 1
  if [[ $mode == 自动* ]]; then
    pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  else
    read_secret pw "密码 (8-64 位, 字母数字和 ._@#%+=-)" || return 1
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
  read -r -p "同时删除的用户名 (默认同库名, 填 - 表示不删用户) [$n]: " u || return 1
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
  else read_secret pw "新密码 (8-64 位)" || return 1; [[ $pw =~ ^[A-Za-z0-9._@#%+=-]{8,64}$ ]] || { err "密码不符合要求"; return 1; }; fi
  mysql -e "ALTER USER '$u'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || return 1
  info "已修改, 新密码: $pw"
}

install_pma() {
  local domain="" root tmp secret
  need_mysql || return 1
  command -v nginx >/dev/null 2>&1 || { err "请先安装环境"; return 1; }
  echo "phpMyAdmin 建议绑定一个不容易被猜到的域名, 并开启 HTTPS 和访问密码。"
  ask domain "phpMyAdmin 使用的域名 (如 db.example.com)" || return 1
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
backup_site() {
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

backup_db() {
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

pick_file() {  # 目录 通配 -> PICKED_FILE
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
      read -r -p "保留最近几份 [7]: " keep || return 1; keep=${keep:-7}
      cmd="$WSM_BIN backup-site $SITE $keep" ;;
    备份数据库)
      pick_db || return 1
      read -r -p "保留最近几份 [7]: " keep || return 1; keep=${keep:-7}
      cmd="$WSM_BIN backup-db $DBNAME $keep" ;;
    备份全部*)
      read -r -p "保留最近几份 [7]: " keep || return 1; keep=${keep:-7}
      cmd="$WSM_BIN backup-db --all $keep" ;;
    *)
      read -r -p "要执行的命令: " cmd || return 1
      [[ -n $cmd && $cmd != *'#'* ]] || { err "命令不能为空且不能含 #"; return 1; } ;;
  esac
  [[ $keep =~ ^[0-9]+$ || -z ${keep:-} ]] || { err "份数请输入数字"; return 1; }
  choose freq "执行频率:" "每天" "每周" "每月" "每隔 N 小时" || return 1
  case $freq in
    每隔*)
      read -r -p "每隔几小时 [6]: " h || return 1; h=${h:-6}
      [[ $h =~ ^[0-9]+$ && $h -ge 1 && $h -le 23 ]] || { err "请输入 1-23"; return 1; }
      expr="0 */$h * * *" ;;
    *)
      echo "  服务器时间: $(tz_now)"
      read -r -p "几点执行 (0-23) [3]: " h || return 1; h=${h:-3}
      read -r -p "第几分钟 (0-59) [30]: " m || return 1; m=${m:-30}
      [[ $h =~ ^[0-9]+$ && $h -le 23 && $m =~ ^[0-9]+$ && $m -le 59 ]] || { err "时间不合法"; return 1; }
      case $freq in
        每天) expr="$m $h * * *" ;;
        每周) read -r -p "星期几 (1=周一 ... 7=周日) [1]: " dow || return 1; dow=${dow:-1}
              [[ $dow =~ ^[1-7]$ ]] || { err "请输入 1-7"; return 1; }
              expr="$m $h * * $((dow % 7))" ;;
        每月) read -r -p "每月几号 (1-28) [1]: " dom || return 1; dom=${dom:-1}
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

composer_ver_ok() {  # Composer 版本 >= 2.2 才算可用 (Debian 11 的 apt 版只有 2.0.9, 装不了新项目)
  local v
  v=$(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null \
      | sed -n 's/.*Composer[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -1)
  [[ -n $v && $(printf '%s\n2.2\n' "$v" | sort -V | head -1) == 2.2 ]]
}

install_composer() {
  if command -v composer >/dev/null 2>&1 && composer_ver_ok; then
    info "Composer 已安装: $(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null | head -1)"
    return 0
  fi
  local php; php=$(command -v php || true)
  [[ -n $php ]] || { err "需要先安装 PHP"; return 1; }
  if command -v composer >/dev/null 2>&1; then
    warn "现有 Composer 版本过旧, 替换为官方最新版 ..."
    [[ $PM == apt ]] && apt-mark unhold composer >/dev/null 2>&1
    pkg_remove composer >/dev/null 2>&1 || true
    rm -f /usr/local/bin/composer
    hash -r
  fi
  # 官方安装器优先, 失败再用阿里云镜像; 不再用系统源 (版本太旧)
  if ! curl -fsSL --max-time 60 https://getcomposer.org/installer \
       | "$php" -- --install-dir=/usr/local/bin --filename=composer >/dev/null; then
    curl -fsSL --max-time 120 https://mirrors.aliyun.com/composer/composer.phar -o /usr/local/bin/composer \
      && chmod +x /usr/local/bin/composer \
      || { err "Composer 下载失败, 请检查网络"; return 1; }
  fi
  hash -r
  composer_ver_ok || { err "Composer 安装后版本仍然过旧"; return 1; }
  info "Composer 已安装: $(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null | head -1)"
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

svc_list() {
  local x u id
  local -A seen=()
  {
    sshd_service
    for x in nginx mariadb redis-server redis netfilter-persistent; do unit_exists "$x" && echo "$x"; done
    for x in $(php_installed | sort -V); do php_svc "$x"; echo; done
    apps_units
    tg_load 2>/dev/null; for x in ${TG_UNITS:-}; do echo "$x"; done
  } | while read -r u; do
    [[ -n $u ]] || continue
    unit_exists "$u" || continue
    id=$(systemctl show -p Id --value "$u" 2>/dev/null); id=${id%.service}
    [[ -n ${seen[${id:-$u}]:-} ]] && continue
    seen[${id:-$u}]=1; echo "$u"
  done
}

svc_boot() { systemctl is-enabled --quiet "$1" 2>/dev/null && echo "${G}开${N}" || echo "${Y}关${N}"; }

svc_table() {
  local x
  printf '   '; pad_w "服务" 26; pad_w "状态" 10; echo "开机自启"
  for x in "$@"; do
    printf '   '; pad_w "$x" 26; printf '%s    %s\n' "$(svc_state "$x")" "$(svc_boot "$x")"
  done
}

manage_service() {
  local name act ok
  local -a svcs=()
  mapfile -t svcs < <(svc_list)
  while true; do
    title "服务管理"
    svc_table "${svcs[@]}"
    tg_ready 2>/dev/null && [[ -f $TG_CRON ]] && echo "   ${D}(Telegram 告警开着: 开机自启的服务停了会被自动拉起)${N}"
    choose name "选择服务:" "${svcs[@]}" || return 0
    while true; do
      echo
      echo "  $name   状态: $(svc_state "$name")   开机自启: $(svc_boot "$name")"
      choose act "操作:" "重启" "重载配置" "启动" "停止" "设为开机自启" "取消开机自启" "查看状态详情" || break
      ok=1
      case $act in
        重启) systemctl restart "$name" >/dev/null 2>&1 || ok=0 ;;
        重载*) systemctl reload "$name" >/dev/null 2>&1 || ok=0 ;;
        启动) systemctl start "$name" >/dev/null 2>&1 || ok=0 ;;
        停止)
          if [[ $name == nginx ]]; then warn "停止 nginx 后所有网站都打不开"; fi
          confirm "确认停止 $name ?" n || continue
          systemctl stop "$name" >/dev/null 2>&1 || ok=0 ;;
        设为*) systemctl enable "$name" >/dev/null 2>&1 || ok=0 ;;
        取消*) systemctl disable "$name" >/dev/null 2>&1 || ok=0 ;;
        *) systemctl status "$name" --no-pager -l 2>&1 | head -20; continue ;;
      esac
      sleep 1
      if ((ok)); then
        case $act in
          重启) systemctl is-active --quiet "$name" && info "已重启 $name" || err "$name 重启后没有运行起来" ;;
          重载*) info "已重载 $name 的配置" ;;
          启动) systemctl is-active --quiet "$name" && info "已启动 $name" || err "$name 没有启动起来" ;;
          停止) info "已停止 $name" ;;
          设为*) info "已设为开机自启: $name" ;;
          取消*) info "已取消开机自启: $name"
                tg_ready 2>/dev/null && [[ -f $TG_CRON ]] && echo "  告警不会再自动拉起它" ;;
        esac
      else
        err "操作失败, 最近日志:"
        journalctl -u "$name" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
      fi
    done
  done
}

# 安装 wsm 快捷命令 (每次启动都会检查, 已装好就什么都不做). 这是启动时唯一会写入系统的东西
# 另外: ssb 作为别名指向 wsm; 清理原 SSH 小工具的旧命令 (sshm/chen/cc) 并迁移它的配置
WSM_ALIAS=/usr/local/bin/ssb
OLD_TOOL_CMDS=(sshm chen cc ssb)
self_install() {
  local me tmp c p
  me=$(readlink -f "$0" 2>/dev/null || true)
  if [[ -f $me && $me != "$WSM_BIN" && $me != /proc/* && $me != /dev/* ]]; then
    install -m755 "$me" "$WSM_BIN" && info "已安装命令: ${G}wsm${N} (之后直接输入 wsm 即可, ssb 也可以)"
  elif [[ ! -f $WSM_BIN ]]; then
    update_load 2>/dev/null
    tmp=$(mktemp)
    if curl -fsSL --retry 2 --max-time 60 "${UPDATE_URL:-$UPDATE_DEFAULT_URL}" -o "$tmp" 2>/dev/null \
        && head -n1 "$tmp" | grep -q '^#!' && grep -q '^WSM_VER=' "$tmp" && bash -n "$tmp" 2>/dev/null; then
      install -m755 "$tmp" "$WSM_BIN" && info "已安装命令: ${G}wsm${N} (之后直接输入 wsm 即可, ssb 也可以)"
    else
      warn "快捷命令安装失败 (下载不到脚本), 可手动: curl -fsSL $UPDATE_DEFAULT_URL -o $WSM_BIN && chmod +x $WSM_BIN"
    fi
    rm -f "$tmp"
  fi
  [[ -f $WSM_BIN ]] || return 0
  for c in "${OLD_TOOL_CMDS[@]}"; do   # 只删确认是原 SSH 小工具的文件, 别的程序不动
    p=/usr/local/bin/$c
    [[ -f $p && ! -L $p ]] && grep -q "SSH 小工具" "$p" 2>/dev/null && rm -f "$p"
  done
  [[ -e $WSM_ALIAS ]] || ln -s "$WSM_BIN" "$WSM_ALIAS" 2>/dev/null
  if [[ -f /etc/ssh-tool.conf ]]; then   # 原 SSH 小工具保存的公钥地址
    mkdir -p "$WSM_DIR"
    grep '^KEYS_URL=https://' /etc/ssh-tool.conf | tail -1 >> "$SSH_TOOL_CONF" && chmod 600 "$SSH_TOOL_CONF"
    rm -f /etc/ssh-tool.conf
  fi
  return 0
}

cmd_install() {
  local PKG_FOR="网站环境"
  pkg_refresh
  tz_suggest
  install_base
  local v="" x
  read -r -p "安装哪些 PHP 版本? (${PHP_VERSIONS}; 多个用空格分隔, 输入 none 跳过) [8.3]: " v || return 1
  v=${v:-8.3}
  if [[ $v != none ]]; then
    for x in $v; do install_php "$x"; done
  fi
  confirm "安装 MariaDB 数据库?" y && install_db
  self_install
  echo
  info "网站环境安装完成!  菜单里的 [网站面板] 管理网站 (命令: ${G}wsm${N})"
  warn "云服务器请在安全组放行 80 / 443 端口"
}

# ---------------- Swap (虚拟内存)
# 小内存 VPS 内存吃紧时, 没有 Swap 的话 MariaDB 最容易被系统杀掉
SWAP_FILE=/swapfile
SWAP_SYSCTL=/etc/sysctl.d/99-wsm-swap.conf

swap_total() { free -m | awk '/^Swap:/{print $2+0}'; }
swap_state() { local t; t=$(swap_total); ((t > 0)) && echo "${t}MB" || echo "无"; }

swap_create() {
  local mem def size avail ok=0
  mem=$(free -m | awk '/^Mem:/{print $2+0}')
  if ((mem <= 1024)); then def=1024; elif ((mem <= 4096)); then def=2048; else def=4096; fi
  echo "  内存 ${mem}MB, 建议 Swap ${def}MB"
  read -r -p "Swap 大小 (MB) [$def]: " size || return 1
  size=${size:-$def}
  [[ $size =~ ^[0-9]+$ ]] && ((size >= 256 && size <= 32768)) || { err "请输入 256-32768"; return 1; }
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE"; then
    info "关闭旧的 $SWAP_FILE ..."
    swapoff "$SWAP_FILE" || { err "关闭旧 Swap 失败 (内存可能不够腾出来)"; return 1; }
  fi
  rm -f "$SWAP_FILE"
  avail=$(df -Pm / | awk 'NR==2{print $4}')
  ((avail > size + 1024)) || { err "磁盘剩余 ${avail}MB, 不够创建 ${size}MB 的 Swap"; return 1; }
  info "创建 ${size}MB Swap ..."
  if fallocate -l "${size}M" "$SWAP_FILE" 2>/dev/null; then
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null 2>&1 && swapon "$SWAP_FILE" 2>/dev/null && ok=1
  fi
  if ((ok == 0)); then  # 部分文件系统不支持 fallocate 的 swap, 改用 dd
    swapoff "$SWAP_FILE" 2>/dev/null; rm -f "$SWAP_FILE"
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size" status=none 2>/dev/null && chmod 600 "$SWAP_FILE" \
      && mkswap "$SWAP_FILE" >/dev/null 2>&1 && swapon "$SWAP_FILE" 2>/dev/null && ok=1
  fi
  if ((ok == 0)); then
    rm -f "$SWAP_FILE"
    err "创建失败: 这台 VPS 可能不允许 Swap (OpenVZ / LXC 容器常见)"; return 1
  fi
  grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  echo "vm.swappiness = 10" > "$SWAP_SYSCTL"
  sysctl -q -w vm.swappiness=10 >/dev/null 2>&1
  info "Swap 已开启: ${size}MB (开机自动挂载, 只在内存不够时使用)"
}

swap_remove() {
  grep -q "^$SWAP_FILE " /etc/fstab 2>/dev/null || [[ -f $SWAP_FILE ]] || { warn "没有找到 wsm 创建的 Swap ($SWAP_FILE)"; return 0; }
  confirm "删除 $SWAP_FILE ?" n || return 0
  swapoff "$SWAP_FILE" 2>/dev/null
  rm -f "$SWAP_FILE" "$SWAP_SYSCTL"
  sed -i "\\|^$SWAP_FILE |d" /etc/fstab
  info "已删除 Swap"
}

swap_menu() {
  local c
  while true; do
    title "Swap 虚拟内存"
    free -m | awk 'NR==1{print "              " $1 "   " $2 "    " $3} /^(Mem|Swap):/{printf "  %-6s %8sMB %7sMB %7sMB\n", $1, $2, $3, $4}'
    echo "  swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null) (越小越少用 Swap, 建议 10)"
    choose c "操作:" "创建 / 调整大小" "删除" "返回" || return 0
    case $c in
      创建*) (swap_create); pause ;;
      删除) (swap_remove); pause ;;
      *) return 0 ;;
    esac
  done
}

# ================================================================ 程序下载 (原软件商店)
APP_IDS=(webbase mariadb redis composer phpmyadmin postgresql memcached
         nodejs pm2 python java git supervisor docker
         rclone ffmpeg imagemagick monitor)

app_cat_icon() { case $1 in 网站环境) ico c_web ;; 开发运行) ico c_dev ;; *) ico c_tool ;; esac; }

app_cat() {
  case $1 in
    webbase|mariadb|redis|composer|phpmyadmin|postgresql|memcached) echo "网站环境" ;;
    nodejs|pm2|python|java|git|supervisor|docker) echo "开发运行" ;;
    *) echo "系统工具" ;;
  esac
}
app_name() {
  case $1 in
    webbase) echo "Nginx 网站环境" ;;
    nodejs) echo "Node.js" ;; pm2) echo "PM2" ;; python) echo "Python3" ;; java) echo "Java (JRE)" ;;
    git) echo "Git" ;; composer) echo "Composer" ;; supervisor) echo "Supervisor" ;;
    mariadb) echo "MariaDB" ;; postgresql) echo "PostgreSQL" ;; redis) echo "Redis" ;;
    memcached) echo "Memcached" ;; phpmyadmin) echo "phpMyAdmin" ;;
    docker) echo "Docker" ;; rclone) echo "Rclone" ;;
    ffmpeg) echo "FFmpeg" ;; imagemagick) echo "ImageMagick" ;; monitor) echo "监控工具包" ;;
  esac
}
app_desc() {
  case $1 in
    webbase) echo "Nginx + 证书工具 + PHP, 建站必装" ;;
    nodejs) echo "JS 运行环境 + npm" ;; pm2) echo "Node 项目进程守护" ;;
    python) echo "Python3 + pip + venv" ;; java) echo "OpenJDK 运行环境" ;;
    git) echo "代码版本管理" ;; composer) echo "PHP 依赖管理" ;;
    supervisor) echo "通用进程守护(队列等)" ;;
    mariadb) echo "MySQL 兼容数据库" ;; postgresql) echo "PostgreSQL 数据库" ;;
    redis) echo "内存缓存 / 队列" ;; memcached) echo "内存缓存" ;;
    phpmyadmin) echo "网页管理数据库" ;;
    docker) echo "容器运行环境" ;;
    rclone) echo "云存储同步 / 异地备份" ;; ffmpeg) echo "音视频处理" ;;
    imagemagick) echo "图片处理命令行" ;; monitor) echo "htop iotop iftop nload" ;;
  esac
}
app_installed() {
  case $1 in
    webbase) command -v nginx >/dev/null 2>&1 ;;
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
    rclone) command -v rclone >/dev/null 2>&1 ;;
    ffmpeg) command -v ffmpeg >/dev/null 2>&1 ;;
    imagemagick) command -v convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 ;;
    monitor) command -v htop >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
app_version() {
  case $1 in
    webbase) nginx -v 2>&1 | sed 's#.*/##' ;;
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
    rclone) rclone version 2>/dev/null | head -1 ;;
    ffmpeg) ffmpeg -version 2>/dev/null | head -1 ;;
    imagemagick) (convert -version 2>/dev/null || magick -version 2>/dev/null) | head -1 ;;
    monitor) htop --version 2>/dev/null | head -1 ;;
  esac
}
app_service() {
  case $1 in
    webbase) echo nginx ;;
    mariadb) echo mariadb ;; postgresql) echo postgresql ;; memcached) echo memcached ;;
    docker) echo docker ;;
    redis) if unit_exists redis-server; then echo redis-server; else echo redis; fi ;;
    supervisor) if unit_exists supervisor; then echo supervisor; else echo supervisord; fi ;;
  esac
  return 0
}
app_valid() { local x; for x in "${APP_IDS[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

pkg_refresh() {
  if [[ $PM == apt && -z ${PKG_REFRESHED:-} ]]; then apt_fix_sources; apt-get update -y >/dev/null 2>&1; PKG_REFRESHED=1; fi
  return 0
}
pkg_remove() {
  local p rc
  if [[ $PM == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
  else dnf remove -y "$@"; fi
  rc=$?
  for p in "$@"; do [[ $p == -* ]] && continue; pkg_has "$p" || ledger_del "$p"; done
  return $rc
}
confirm_typed() { local a; read -r -p "$1 (输入 yes-delete 确认): " a || return 1; [[ $a == yes-delete ]]; }

install_nodejs() {
  local v
  pkg_refresh
  if [[ $PM == apt ]]; then
    if [[ ${WSM_NODE_VER:-} =~ ^[0-9]+$ ]]; then v="$WSM_NODE_VER (还原)"      # 全量还原: 和旧服务器同一个大版本
    elif [[ ${WSM_NODE_VER:-} == sys ]]; then v="系统自带"
    else
      choose v "选择 Node.js 版本 (以 NodeSource 实际提供为准):" \
        "24 (LTS, 推荐)" "22 (LTS 维护期)" "系统自带版本 (最稳, 但版本较旧)" || return 1
    fi
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
    webbase) if command -v nginx >/dev/null 2>&1; then install_base; else cmd_install; fi ;;
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
    webbase) warn "卸载 Nginx 会让所有网站停止访问, 这里不提供卸载"; return 0 ;;
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
    rclone) pkg_has rclone && pkg_remove rclone
            if [[ -f /usr/bin/rclone ]] && ! pkg_has rclone; then rm -f /usr/bin/rclone /usr/local/share/man/man1/rclone.1; ledger_del @rclone; fi ;;
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
      安装|重新*) { [[ $id != phpmyadmin && $id != composer ]] || need_web; } && ( app_install "$id" ); pause ;;
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
  local c i id cat last st n m
  local -a mods=()
  ui_load
  while true; do
    apps_load
    mods=("${APPS_LOADED[@]}"); m=${#mods[@]}
    title "程序下载"
    echo; echo "  ${S}${BD}$(ico c_panel) 扩展程序${N} ${D}(模块, 可随时添加删除, 不依赖网站环境的可以直接装)${N}"
    i=0
    for id in "${mods[@]}"; do
      i=$((i + 1))
      printf '  %s%3d%s  %s' "$BD$B" "$i" "$N" "$T"; pad_w "${APP_NAMES[$id]}" 16; printf '%s' "$N"; app_status "$id"
    done
    ((m)) || echo "       ${D}(还没有模块, 输入 a 从仓库添加)${N}"
    printf '  %s%3s%s  %s添加模块%s     %s%s%s  %s删除模块%s\n' "$BD$B" a "$N" "$T" "$N" "$BD$B" d "$N" "$T" "$N"
    last=""
    for id in "${APP_IDS[@]}"; do
      i=$((i + 1))
      cat=$(app_cat "$id")
      if [[ $cat != "$last" ]]; then echo; echo "  ${S}${BD}$(app_cat_icon "$cat") ${cat}${N}"; last=$cat; fi
      if app_installed "$id"; then st="${G}● 已装${N}"; else st="${D}○ 未装${N}"; fi
      printf '  %s%3d%s  %s' "$BD$B" "$i" "$N" "$T"; pad_w "$(app_name "$id")" 16; printf '%s%s\n' "$N" "$st"
    done
    echo
    mback
    read -r -p "输入序号 (回车返回): " c || return 0
    [[ -z $c || $c == 0 || $c == q ]] && return 0
    case $c in
      a|A) (app_add); pause; continue ;;
      d|D)
        ((m)) || { warn "还没有模块"; continue; }
        local -a opts=()
        for id in "${mods[@]}"; do opts+=("${APP_NAMES[$id]} ($id)"); done
        choose n "删除哪个模块:" "${opts[@]}" || continue
        n=${n##*(}; n=${n%)}
        app_remove "$n"; pause; continue ;;
    esac
    if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= m)); then app_module_menu "${mods[c - 1]}"
    elif [[ $c =~ ^[0-9]+$ ]] && ((c > m && c <= m + ${#APP_IDS[@]})); then app_manage "${APP_IDS[c - m - 1]}"
    else warn "无效选择"; fi
  done
}

# ================================================================ 扩展程序模块
# 底座只管服务器环境 (Nginx/PHP/数据库/证书/防护/备份); 具体程序 (Xboard / WordPress / 3x-ui ...)
# 都是 /etc/wsm/apps/<id>.sh 一个独立模块, 随时添加、删除。格式见仓库 apps/README.md, 简述:
#   APP_ID=<id>  APP_NAME="名称"  APP_DESC="一句话简介"  APP_VER=1.0
#   APP_TYPE=site (默认, 网站程序: 部署成站点, 可部署多个) | soft (独立软件: 自带服务, 装一份)
#   app_<id>_install [域名]          必须: 安装 / 部署; site 类成功后调用 app_mark_site 域名 <id>
#   app_<id>_menu  [站点]            可选: 模块自己的管理菜单
#   app_<id>_detect                  可选: 识别已有的 (site 类已 load_meta 判断站点; soft 类判断是否已装)
#   app_<id>_installed               soft 类: 是否已安装      app_<id>_version  soft 类: 版本
#   app_<id>_uninstall               soft 类: 卸载
#   app_<id>_units [站点]            可选: 后台服务 (监控 / 服务管理 / 搬家)
#   app_<id>_guard_skip              可选: 输出防 CC 不限速的 nginx map 行 (如节点接口 / 订阅链接)
#   app_<id>_guard_on 域名           可选: 站点开启防 CC 时调用
#   app_<id>_backup_paths            可选: 输出全量备份要额外带上的文件
#   app_<id>_purge 域名 根目录       可选: 删除站点时清理 (服务 / 计划任务 ...)
#   app_<id>_cli 参数...             可选: 命令行 wsm app <id> 参数...
APPS_DIR=$WSM_DIR/apps
APPS_DATA=$WSM_DIR/appdata
APPS_MIGRATED=$APPS_DIR/.migrated-2
declare -A APP_NAMES=() APP_DESCS=() APP_VERS=() APP_TYPES=()
APPS_LOADED=()

app_id_ok() { [[ $1 =~ ^[a-z][a-z0-9_]{1,30}$ ]]; }

app_file_check() {  # 文件 [期望的id] -> APP_CHECK_ID ; 检查模块文件是否合格
  local f=$1 want=${2:-} id
  APP_CHECK_ID=""
  [[ -s $f ]] || { err "模块文件是空的"; return 1; }
  bash -n "$f" 2>/dev/null || { err "模块文件语法错误"; return 1; }
  id=$(sed -n 's/^APP_ID=["'\'']\{0,1\}\([a-z][a-z0-9_]*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$f" | head -1)
  app_id_ok "$id" || { err "模块里没有正确的 APP_ID"; return 1; }
  [[ -z $want || $want == "$id" ]] || { err "模块 ID 是 $id, 不是 $want"; return 1; }
  grep -q "^app_${id}_install()" "$f" || { err "模块缺少 app_${id}_install"; return 1; }
  APP_CHECK_ID=$id
}

apps_load() {
  local f id APP_ID APP_NAME APP_DESC APP_VER APP_TYPE
  APPS_LOADED=()
  [[ -d $APPS_DIR ]] || return 0
  for f in "$APPS_DIR"/*.sh; do
    [[ -f $f ]] || continue
    id=${f##*/}; id=${id%.sh}
    app_id_ok "$id" && bash -n "$f" 2>/dev/null || continue
    APP_ID=""; APP_NAME=""; APP_DESC=""; APP_VER=""; APP_TYPE=""
    # shellcheck disable=SC1090
    source "$f" || continue
    [[ $APP_ID == "$id" ]] && declare -F "app_${id}_install" >/dev/null || continue
    APP_NAMES[$id]=${APP_NAME:-$id}; APP_DESCS[$id]=${APP_DESC:-}; APP_VERS[$id]=${APP_VER:-}
    [[ $APP_TYPE == soft ]] && APP_TYPES[$id]=soft || APP_TYPES[$id]=site
    APPS_LOADED+=("$id")
  done
  return 0
}

app_loaded() { local x; for x in "${APPS_LOADED[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }
app_has() { app_loaded "$1" && declare -F "app_${1}_$2" >/dev/null; }
app_call() { local id=$1 fn=$2; shift 2; app_has "$id" "$fn" || return 0; "app_${id}_${fn}" "$@"; }
apps_hook() { local id fn=$1; shift; for id in "${APPS_LOADED[@]}"; do app_call "$id" "$fn" "$@"; done; return 0; }
app_soft() { [[ ${APP_TYPES[$1]:-site} == soft ]]; }
app_soft_installed() { app_has "$1" installed && "app_${1}_installed"; }

app_of_site() { ( load_meta "$1" 2>/dev/null; echo "${APP:-}" ); }
app_site_call() {  # 域名 钩子 参数... : 调用该站点所属模块的钩子
  local d=$1 fn=$2 id; shift 2
  id=$(app_of_site "$d")
  [[ -n $id ]] && app_call "$id" "$fn" "$@"
  return 0
}

app_mark_site() {  # 域名 模块id : 记录站点属于哪个程序
  ( load_meta "$1" || exit 1; APP=$2; save_meta )
}

app_sites() {  # 模块id : 列出属于该模块的站点
  local d
  while read -r d; do
    [[ -n $d ]] || continue
    [[ $(app_of_site "$d") == "$1" ]] && echo "$d"
  done < <(list_site_names)
  return 0
}

app_status() {
  local n
  if app_soft "$1"; then
    if app_soft_installed "$1"; then echo "${G}已装${N}"; else echo "${D}未装${N}"; fi
  else
    n=$(app_sites "$1" | wc -l)
    if ((n)); then echo "${G}${n} 个站点${N}"; else echo "${D}未部署${N}"; fi
  fi
}

apps_units() {
  local d id
  {
    for id in "${APPS_LOADED[@]}"; do app_soft "$id" && app_call "$id" units; done
    while read -r d; do
      [[ -n $d ]] || continue
      id=$(app_of_site "$d")
      [[ -n $id ]] && ! app_soft "$id" && app_call "$id" units "$d"
    done < <(list_site_names)
  } | awk 'NF && !seen[$0]++'
}

apps_claim() {  # 让已载入的网站模块认领还没归属的老站点
  local d id n=0
  while read -r d; do
    [[ -n $d && -z $(app_of_site "$d") ]] || continue
    for id in "${APPS_LOADED[@]}"; do
      app_soft "$id" && continue
      app_has "$id" detect || continue
      if ( load_meta "$d"; "app_${id}_detect" ) >/dev/null 2>&1; then
        app_mark_site "$d" "$id"; n=$((n + 1)); break
      fi
    done
  done < <(list_site_names)
  echo "$n"
}

app_repo_base() {  # 模块仓库地址 (和脚本更新地址同一个仓库的 apps/ 目录)
  update_load
  echo "${WSM_APPS_URL:-${UPDATE_URL%/*}/apps}"
}

app_fetch() {  # 来源(id/网址/本地文件) -> APP_FETCHED (临时文件)
  local src=$1 tmp
  APP_FETCHED=""
  tmp=$(mktemp)
  if [[ -f $src ]]; then cp -f "$src" "$tmp"
  elif [[ $src =~ ^https?:// ]]; then
    curl -fsSL --max-time 60 "$src" -o "$tmp" || { rm -f "$tmp"; err "下载失败: $src"; return 1; }
  elif app_id_ok "$src"; then
    curl -fsSL --max-time 60 "$(app_repo_base)/$src.sh?_=$(date +%s)" -o "$tmp" \
      || { rm -f "$tmp"; err "仓库里没有找到模块 $src"; return 1; }
  else rm -f "$tmp"; err "无法识别: $src"; return 1; fi
  APP_FETCHED=$tmp
}

app_install_file() {  # 临时文件 : 检查并放进模块目录
  app_file_check "$1" || { rm -f "$1"; return 1; }
  mkdir -p "$APPS_DIR" "$APPS_DATA"
  install -m 644 "$1" "$APPS_DIR/$APP_CHECK_ID.sh"; rm -f "$1"
  apps_load
  app_loaded "$APP_CHECK_ID" || { err "模块载入失败"; return 1; }
  apps_claim >/dev/null
  guard_refresh_global >/dev/null 2>&1
  info "已添加模块: ${APP_NAMES[$APP_CHECK_ID]} ($APP_CHECK_ID${APP_VERS[$APP_CHECK_ID]:+ v${APP_VERS[$APP_CHECK_ID]}})"
}

app_add() {
  local src=${1:-} idx line id c
  local -a ids=() names=()
  if [[ -z $src ]]; then
    idx=$(curl -fsSL --max-time 30 "$(app_repo_base)/index.txt?_=$(date +%s)" 2>/dev/null)
    while IFS='|' read -r id line; do
      app_id_ok "$id" || continue
      app_loaded "$id" && continue
      ids+=("$id"); names+=("$line")
    done <<< "$idx"
    if ((${#ids[@]})); then
      local -a opts=()
      for c in "${!ids[@]}"; do opts+=("${names[c]}"); done
      opts+=("从网址或本地文件添加")
      choose c "仓库里可添加的模块:" "${opts[@]}" || return 0
      if [[ $c == 从网址* ]]; then src=""
      else for line in "${!ids[@]}"; do [[ ${names[line]} == "$c" ]] && src=${ids[line]}; done; fi
    else
      [[ -n $idx ]] && info "仓库里的模块都已经添加了"
      [[ -n $idx ]] || warn "读取模块仓库失败: $(app_repo_base)"
    fi
    if [[ -z $src ]]; then
      read -r -p "模块文件网址或本地路径: " src || return 0
      [[ -n $src ]] || return 0
    fi
  fi
  app_fetch "$src" || return 1
  app_install_file "$APP_FETCHED"
}

app_update_module() {  # id : 从仓库重新下载模块
  local id=$1
  app_fetch "$id" || return 1
  if cmp -s "$APP_FETCHED" "$APPS_DIR/$id.sh"; then rm -f "$APP_FETCHED"; info "模块已是最新"; return 0; fi
  app_file_check "$APP_FETCHED" "$id" || { rm -f "$APP_FETCHED"; return 1; }
  app_install_file "$APP_FETCHED"
}

app_remove() {
  local id=$1 d c=""
  local -a sites=()
  [[ -f $APPS_DIR/$id.sh ]] || { err "没有这个模块: $id"; return 1; }
  echo "  模块: ${APP_NAMES[$id]:-$id}"
  if app_soft "$id"; then
    if app_soft_installed "$id"; then
      echo "  这个软件目前已安装在本机"
      choose c "删除模块时, 软件:" "保留软件 (照常运行, 只是不再由 wsm 管理)" "先卸载软件" || return 0
      if [[ $c == 先卸载* ]]; then
        if app_has "$id" uninstall; then ("app_${id}_uninstall") || { warn "没有卸载, 模块也保留"; return 0; }
        else warn "这个模块没有提供卸载功能, 请手动卸载"; fi
      fi
    fi
  else
    mapfile -t sites < <(app_sites "$id")
    if ((${#sites[@]})); then
      echo "  有 ${#sites[@]} 个站点是用它部署的: ${sites[*]}"
      choose c "删除模块时, 这些站点:" "保留站点 (网站照常运行, 只是不再由模块管理)" \
        "一起删除站点" || return 0
      if [[ $c == 一起* ]]; then
        for d in "${sites[@]}"; do (del_site "$d"); done
      fi
    fi
  fi
  confirm "确认删除模块 ${APP_NAMES[$id]:-$id} ?" n || return 0
  rm -f "$APPS_DIR/$id.sh"
  apps_load
  guard_refresh_global >/dev/null 2>&1
  info "已删除模块 ${APP_NAMES[$id]:-$id}"
  [[ $c == 保留* ]] && echo "  以后重新添加这个模块, 会自动重新接管"
  return 0
}

apps_migrate_once() {  # 老版本升级上来时: 自动找回已在用的程序对应的模块 (只做一次)
  [[ -f $APPS_MIGRATED ]] && return 0
  local idx id tmp found fail=0
  apps_claim >/dev/null
  idx=$(curl -fsSL --max-time 10 "$(app_repo_base)/index.txt?_=$(date +%s)" 2>/dev/null) || return 0
  while IFS='|' read -r id _; do
    app_id_ok "$id" && ! app_loaded "$id" || continue
    app_fetch "$id" 2>/dev/null || { fail=1; continue; }
    tmp=$APP_FETCHED
    app_file_check "$tmp" "$id" 2>/dev/null || { rm -f "$tmp"; continue; }
    found=$(
      APP_TYPE=""
      # shellcheck disable=SC1090
      source "$tmp" 2>/dev/null
      declare -F "app_${id}_detect" >/dev/null || exit 0
      if [[ $APP_TYPE == soft ]]; then "app_${id}_detect" >/dev/null 2>&1 && echo 1; exit 0; fi
      while read -r d; do
        [[ -n $d ]] || continue
        ( load_meta "$d"; [[ -z ${APP:-} ]] && "app_${id}_detect" ) >/dev/null 2>&1 && { echo 1; break; }
      done < <(list_site_names)
    )
    if [[ $found == 1 ]]; then app_install_file "$tmp" >/dev/null 2>&1; else rm -f "$tmp"; fi
  done <<< "$idx"
  ((fail)) && return 0   # 有模块没下载到, 下次再试
  mkdir -p "$APPS_DIR"; date '+%F %T' > "$APPS_MIGRATED"
  guard_refresh_global >/dev/null 2>&1
  return 0
}

app_deploy_menu() {
  local c id
  local -a opts=() ids=()
  for id in "${APPS_LOADED[@]}"; do
    app_soft "$id" && continue
    ids+=("$id"); opts+=("${APP_NAMES[$id]}  ${D}${APP_DESCS[$id]}${N}")
  done
  ((${#ids[@]})) || { warn "还没有添加网站类模块 (如 WordPress / Xboard), 到 [程序下载] 里添加"; return 0; }
  choose c "部署哪个程序:" "${opts[@]}" || return 0
  for id in "${ids[@]}"; do
    [[ $c == "${APP_NAMES[$id]}  "* ]] && { "app_${id}_install"; return; }
  done
}

app_module_menu() {
  local id=$1 c d
  local -a sites=() opts=()
  while true; do
    title "${APP_NAMES[$id]}"
    echo "  简介: ${APP_DESCS[$id]:-无}"
    echo "  模块: $id${APP_VERS[$id]:+ v${APP_VERS[$id]}}"
    if app_soft "$id"; then
      if app_soft_installed "$id"; then
        echo "  状态: ${G}已安装${N}$(app_has "$id" version && echo "   版本: $("app_${id}_version")")"
        opts=()
        app_has "$id" menu && opts+=("管理")
        opts+=("重新安装")
        app_has "$id" uninstall && opts+=("卸载软件")
      else
        echo "  状态: ${Y}未安装${N}"
        opts=("安装")
      fi
    else
      mapfile -t sites < <(app_sites "$id")
      echo "  站点: ${sites[*]:-无}"
      opts=("部署新站点")
      app_has "$id" menu && ((${#sites[@]})) && opts+=("管理已部署的站点")
    fi
    opts+=("更新模块" "删除模块" "返回")
    choose c "操作:" "${opts[@]}" || return 0
    case $c in
      部署*) need_web && ("app_${id}_install"); pause ;;
      安装|重新安装) ("app_${id}_install"); pause ;;
      管理) ("app_${id}_menu") ;;
      卸载软件) ("app_${id}_uninstall") && info "已卸载 (模块还在, 想彻底不要可以再删除模块)"; pause ;;
      管理已部署*)
        if ((${#sites[@]} == 1)); then d=${sites[0]}
        else choose d "哪个站点:" "${sites[@]}" || continue; fi
        ("app_${id}_menu" "$d") ;;
      更新模块) (app_update_module "$id"); apps_load; pause ;;
      删除模块) app_remove "$id"; pause; app_loaded "$id" || return 0 ;;
      *) return 0 ;;
    esac
  done
}

app_cli() {
  local a=${1:-list} id
  case $a in
    list)
      ((${#APPS_LOADED[@]})) || { echo "还没有添加模块"; return 0; }
      for id in "${APPS_LOADED[@]}"; do
        printf '%-12s ' "$id"; pad_w "${APP_NAMES[$id]}" 16
        if app_soft "$id"; then
          if app_soft_installed "$id"; then echo "已安装"; else echo "未安装"; fi
        else
          app_sites "$id" | paste -sd' ' -
        fi
      done ;;
    add) app_add "${2:-}" ;;
    remove) [[ -n ${2:-} ]] || { err "用法: wsm app remove <模块>"; return 1; }; app_remove "$2" ;;
    update) [[ -n ${2:-} ]] || { err "用法: wsm app update <模块>"; return 1; }; app_update_module "$2" ;;
    *)
      id=$a; shift
      app_loaded "$id" || { err "没有这个模块: $id (wsm app list 查看)"; return 1; }
      case ${1:-} in
        install) { app_soft "$id" || need_web; } && "app_${id}_install" "${2:-}" ;;
        uninstall) app_has "$id" uninstall || { err "这个模块不支持卸载"; return 1; }; "app_${id}_uninstall" ;;
        *) if app_has "$id" cli; then "app_${id}_cli" "$@"; else app_module_menu "$id"; fi ;;
      esac ;;
  esac
}

# ---------------------------------------------------------------- 给模块用的公共函数
# 版本检测: 先查 GitHub Releases 接口 (带发布日期), 查不到 (限流/网络) 再用 git 读标签
ver_gh_latest() {
  local r=$1 j tag="" date=""
  j=$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$r/releases/latest" 2>/dev/null)
  tag=$(printf '%s\n' "$j" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  date=$(printf '%s\n' "$j" | sed -n 's/^ *"published_at": *"\([0-9-]*\)T.*/\1/p' | head -1)
  if [[ -z $tag ]] && command -v git >/dev/null 2>&1; then
    tag=$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --tags --refs "https://github.com/$r.git" 2>/dev/null \
          | awk -F/ '{print $3}' | grep -viE 'rc|alpha|beta|pre|dev|nightly|test' | sort -V | tail -1)
  fi
  [[ -n $tag ]] || return 1
  echo "$tag|$date"
}

ver_newer() {  # 当前 最新 : 最新 比 当前 新则返回 0
  local a=${1#v} b=${2#v}
  [[ -n $b && $a != "$b" && $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1) == "$b" ]]
}

ver_pick() {  # 程序名 owner/repo -> PICK_VER (空 = 用 latest 链接)
  local x tag="" date="" v
  PICK_VER=""
  info "检查 $1 最新版本 ..."
  if x=$(ver_gh_latest "$2"); then
    tag=${x%%|*}; date=${x#*|}
    echo "  最新版本: ${G}$tag${N}${date:+  (发布于 $date)}"
  else
    warn "没能检测到最新版本 (网络或 GitHub 限流), 将直接下载最新版"
  fi
  read -r -p "回车安装${tag:+ $tag}最新版, 或输入要安装的版本号: " v || return 1
  PICK_VER=${v:-$tag}
  [[ -z $v || $v =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || { err "版本号格式不正确"; return 1; }
  return 0
}

gh_asset_url() {  # owner/repo 版本(可空) 文件名
  if [[ -n $2 ]]; then echo "https://github.com/$1/releases/download/$2/$3"
  else echo "https://github.com/$1/releases/latest/download/$3"; fi
}

arch_go() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7*) echo arm-7 ;; s390x) echo s390x ;;
    *) uname -m ;;
  esac
}

app_new_domain() {  # 变量名 提示 : 输入新站点的域名并检查可用
  local _nd=${!1:-} _nu
  ask _nd "$2" || return 1
  valid_domain "$_nd" || { err "域名格式不正确: $_nd"; return 1; }
  [[ -f $(meta_file "$_nd") ]] && { err "站点已存在: $_nd"; return 1; }
  _nu=$(domain_used "$_nd") && { err "域名 $_nd 已被站点 $_nu 使用"; return 1; }
  printf -v "$1" "%s" "$_nd"
}

app_need_db() {  # 程序名 : 没有数据库就先装
  command -v mysql >/dev/null 2>&1 && return 0
  confirm "$1 需要数据库, 现在安装 MariaDB 吗?" y || return 1
  install_db
}

app_db_new() {  # 前缀 域名 -> ADB_NAME ADB_USER ADB_PASS
  local k; k=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_' | cut -c1-12)
  ADB_NAME="${1}_${k}_$(openssl rand -hex 2)"; ADB_USER=$ADB_NAME
  ADB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  mysql -e "CREATE DATABASE \`$ADB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
CREATE USER '$ADB_USER'@'localhost' IDENTIFIED BY '$ADB_PASS'; \
GRANT ALL PRIVILEGES ON \`$ADB_NAME\`.* TO '$ADB_USER'@'localhost'; FLUSH PRIVILEGES;"
}

app_db_drop() {  # 库名 [账号] : 删除数据库和它的账号 (账号默认和库同名)
  [[ $1 =~ ^[A-Za-z0-9_]+$ ]] || return 0
  local u=${2:-$1}
  [[ $u =~ ^[A-Za-z0-9_]+$ && $u != root ]] || u=$1
  mysql -e "DROP DATABASE IF EXISTS \`$1\`; DROP USER IF EXISTS '$u'@'localhost';" 2>/dev/null
}

php_exts_ensure() {  # PHP版本 扩展...  (尽力安装, 装不上的跳过)
  local v=$1 pv e; shift
  pv=$(php_pkgver "$v")
  for e in "$@"; do
    if [[ $PM == apt ]]; then pkg_install "php$v-$e" >/dev/null 2>&1 || true
    else
      case $e in mysql) e=mysqlnd ;; esac
      pkg_install "php${pv}-php-$e" >/dev/null 2>&1 || pkg_install "php${pv}-php-pecl-$e" >/dev/null 2>&1 || true
    fi
  done
  systemctl restart "$(php_svc "$v")" >/dev/null 2>&1 || true
}

# shellcheck disable=SC2034  # PICK_PHP 给模块用
php_pick_min() {  # 最低版本 程序名 -> PICK_PHP (没有合适的就装 8.3)
  local x; local -a list=()
  PICK_PHP=""
  for x in $(php_installed | sort -V); do
    awk -v v="$x" -v m="$1" 'BEGIN { exit !(v + 0 >= m + 0) }' && list+=("$x")
  done
  if ((${#list[@]} == 0)); then
    warn "$2 需要 PHP $1 以上, 先安装 PHP 8.3"
    install_php 8.3 || return 1
    PICK_PHP=8.3
  elif ((${#list[@]} == 1)); then PICK_PHP=${list[0]}
  else choose PICK_PHP "选择 PHP 版本 ($2 需要 $1+):" "${list[@]}" || return 1
  fi
}

app_site_conf() {  # 域名 : 从标准输入写入站点的程序专用 Nginx 规则
  # 规则会放进站点 server 块里; __PHP_SOCK__ 会替换成站点当前 PHP 版本的 sock (切换 PHP 后自动跟着变)
  cat > "$META_DIR/$1.app.nginx"
}

app_systemd() {
  local name=$1 desc=$2 wd=$3 exec=$4 user=${5:-root} e; shift 5 2>/dev/null || shift $#
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo "After=network.target"
    echo
    echo "[Service]"
    echo "Type=simple"
    echo "User=$user"
    echo "WorkingDirectory=$wd"
    for e in "$@"; do echo "Environment=$e"; done
    echo "ExecStart=$exec"
    echo "Restart=on-failure"
    echo "RestartSec=5"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "/etc/systemd/system/$name.service"
  systemctl daemon-reload
  systemctl enable --now "$name" >/dev/null 2>&1
}

app_proxy_site() {  # 域名 本机端口 : 建反向代理站点 (会问绑定域名和 HTTPS)
  add_site proxy "$1" "http://127.0.0.1:$2"
}

app_ver_set() { mkdir -p "$APPS_DATA/$1"; echo "$2" > "$APPS_DATA/$1/version"; }  # 记录已装版本
app_ver_get() { head -1 "$APPS_DATA/$1/version" 2>/dev/null; }

app_port_free() {  # 端口 : 端口没被占用返回 0
  ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

app_check_update() {  # 程序名 owner/repo 当前版本 : 有新版返回 0, 新版本放在 PICK_VER
  local x tag date
  PICK_VER=""
  info "检查 $1 最新版本 ..."
  x=$(ver_gh_latest "$2") || { warn "没能检测到最新版本 (网络或 GitHub 限流), 稍后再试"; return 1; }
  tag=${x%%|*}; date=${x#*|}
  echo "  当前版本: ${3:-未知}"
  echo "  最新版本: $tag${date:+  (发布于 $date)}"
  if [[ -n $3 ]] && ! ver_newer "$3" "$tag"; then info "已经是最新版"; return 1; fi
  # shellcheck disable=SC2034  # 给模块用
  PICK_VER=$tag
  return 0
}

app_wait_port() {  # 端口 [秒] : 等程序启动监听
  local i
  for ((i = 0; i < ${2:-30}; i++)); do
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$" && return 0
    sleep 1
  done
  return 1
}

# ================================================================ 访问统计
# 只在你打开时临时分析 nginx 日志, 不常驻、不占资源
# 真人 / 爬虫 / 可疑 是按日志推测的: 看 User-Agent 和访问行为, 仅供参考
declare -A ST=()
STAT_TMP=""
STAT_AWK=$(cat <<'AWK'
BEGIN {
  FS = "\""
  n = split(dates, dl, "|")
  for (i = 1; i <= n; i++) ok[dl[i]] = 1
  filt = (dates != "")
  # 常见漏洞扫描路径 (只在返回 4xx/5xx 时才算, 正常网站自己的页面不会误判)
  SCAN = "(/\\.(env|git|svn|hg|ds_store|htpasswd|aws)|wp-login\\.php|xmlrpc\\.php|/wp-(admin|content|includes)|phpmyadmin|/pma/|myadmin|/vendor/phpunit|eval-stdin|/cgi-bin/|/boaform|/hnap1|/actuator|/solr/|/owa/|/autodiscover|/shell|\\.(sql|bak|old|swp|tar|tgz|rar|7z)$|/config\\.(php|json|ya?ml)$)"
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
  ua = $6; ual = tolower(ua)
  eng = ""
  if (ual ~ /googlebot|google-inspectiontool|googleother/) eng = "Google"
  else if (ual ~ /baiduspider/) eng = "Baidu"
  else if (ual ~ /bingbot/) eng = "Bing"
  else if (ual ~ /yandex/) eng = "Yandex"
  else if (ual ~ /sogou/) eng = "Sogou"
  else if (ual ~ /360spider|haosouspider/) eng = "360"
  else if (ual ~ /bytespider/) eng = "Byte"
  noua = (ua == "" || ua == "-")
  isbot = (eng != "" || noua || ual ~ /bot|spider|crawl|slurp|python|go-http|wget|curl|scrapy|httpclient|okhttp|java\/|libwww|axios|node-fetch|headless|phantomjs|masscan|zgrab|nmap|nikto|sqlmap/)
  if (eng != "") { sp[eng]++; claim[ip] = eng }
  else if (noua) sp["无UA"]++
  else if (isbot) sp["Other"]++
  if (isbot) hasb[ip] = 1; else hash[ip] = 1
  if (url ~ /\.(css|js|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map|mp4|mp3)$/) {
    nstatic++; ist[ip]++
  } else {
    pv++
    if (isbot) pvb[ip]++; else pvh[ip]++
    if (st < 400) page[url]++
    m = substr(ts, 2, 17)                      # 精确到分钟, 算每分钟页面请求数
    if (lm[ip] == m) mc[ip]++; else { lm[ip] = m; mc[ip] = 1 }
    if (mc[ip] > mx[ip]) mx[ip] = mc[ip]
  }
  if (st == 404) { nf[url]++; n4[ip]++ }
  if (st >= 400 && tolower(url) ~ SCAN) { sc[ip]++; scu[url]++ }
  rf = $4
  if (rf != "-" && rf != "") {
    sub(/^https?:\/\//, "", rf); sub(/[\/?].*/, "", rf)
    if (rf != "" && rf != dom) ref[rf]++
  }
}
END {
  uv = 0; for (k in ips) uv++
  # 网站自己有静态资源请求 (没被 CDN 全部缓存) 时, 才用 "只看页面不加载资源" 这条判断
  sitest = (tot > 0 && nstatic * 100 >= tot * 15)
  for (k in ips) {
    why = ""
    if (sc[k]) why = why "扫描漏洞" sc[k] "次 "
    if (!(k in claim)) {
      if (n4[k] >= 20 && n4[k] * 2 >= ips[k]) why = why "404过多(" n4[k] ") "
      if (mx[k] >= 60) why = why "频率高(" mx[k] "页/分) "
      if (sitest && pvh[k] >= 30 && !ist[k]) why = why "不加载资源 "
    }
    if (why != "") {
      sub(/ $/, "", why)
      sip++; spv += pvh[k] + pvb[k]; t = " [可疑]"
      printf "bad\t%d\t%s\t%s\n", ips[k], k, why
    } else if (hash[k]) {
      hip++; hpv += pvh[k]; rpv += pvb[k]; t = ""
    } else {
      rip++; rpv += pvb[k]; t = " [爬虫]"
    }
    printf "ip\t%d\t%s%s\n", ips[k], k, t
  }
  printf "S\ttot\t%d\nS\tpv\t%d\nS\tuv\t%d\nS\tbytes\t%.0f\n", tot, pv, uv, bytes
  printf "S\thpv\t%d\nS\trpv\t%d\nS\tspv\t%d\nS\thip\t%d\nS\trip\t%d\nS\tsip\t%d\n", hpv, rpv, spv, hip, rip, sip
  for (c = 2; c <= 5; c++) printf "S\tc%d\t%d\n", c, cls[c] + 0
  for (k in page) printf "url\t%d\t%s\n", page[k], k
  for (k in nf) printf "nf\t%d\t%s\n", nf[k], k
  for (k in scu) printf "scu\t%d\t%s\n", scu[k], k
  for (k in ref) printf "ref\t%d\t%s\n", ref[k], k
  for (k in sp) printf "sp\t%d\t%s\n", sp[k], k
  for (k in claim) printf "cl\t%d\t%s\t%s\n", ips[k], k, claim[k]
  for (k in hr) printf "hr\t%d\t%s\n", hr[k], k
}
AWK
)

hb() {
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

stat_stream() {
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

stat_collect() {  # 域名 范围 -> 填充 ST[] 和 $STAT_TMP
  local d=$1 range=$2 dates t k v
  dates=$(stat_dates "$range")
  STAT_TMP=$(mktemp)
  stat_stream "$d" "$range" | awk -v dates="$dates" -v dom="$d" "$STAT_AWK" > "$STAT_TMP"
  ST=()
  while IFS=$'\t' read -r t k v; do [[ $t == S ]] && ST[$k]=$v; done < "$STAT_TMP"
}

stat_top() {
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

stat_bad() {  # 疑似恶意 IP: 一行 IP, 一行原因 (手机上不换行)
  local c ip why
  awk -F'\t' '$1=="bad"{print $2"\t"$3"\t"$4}' "$STAT_TMP" | sort -t$'\t' -k1,1nr | head -n "$1" |
  while IFS=$'\t' read -r c ip why; do
    printf '  %7s  %s\n           %s\n' "$c" "$ip" "${D}${why}${N}"
  done
}

stat_verify() {  # 核实自称搜索引擎的 IP: 反向 DNS 查域名, 再正向查回 IP, 两边对得上才是真的
  local c ip eng host re res
  command -v getent >/dev/null 2>&1 || { warn "缺少 getent, 无法核实"; return 0; }
  # 先用公共 DNS 的地址试一下反向解析, 不通就别核实了, 免得把真爬虫误判成假冒
  if [[ -z $(timeout 4 getent hosts 8.8.8.8 2>/dev/null; timeout 4 getent hosts 1.1.1.1 2>/dev/null) ]]; then
    warn "这台服务器暂时查不了反向 DNS, 无法核实"; return 0
  fi
  echo; echo "${B}搜索引擎核实 (访问最多的 8 个)${N}"
  while IFS=$'\t' read -r c ip eng; do
    case $eng in
      Google) re='\.(googlebot|google)\.com$' ;;
      Baidu)  re='\.baidu\.(com|jp)$' ;;
      Bing)   re='\.search\.msn\.com$' ;;
      Yandex) re='\.yandex\.(ru|net|com)$' ;;
      Sogou)  re='\.sogou\.com$' ;;
      *)      re='' ;;
    esac
    if [[ -z $re ]]; then
      res="${D}不支持核实${N}"
    else
      host=$(timeout 4 getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
      if [[ -z $host ]]; then
        res="${R}查不到域名, 多半假冒${N}"
      elif [[ $host =~ $re ]] &&
         timeout 4 getent ahosts "$host" 2>/dev/null | awk '{print $1}' | grep -qxF "$ip"; then
        res="${G}真${N}"
      else
        res="${R}假冒${N} ${D}($host)${N}"
      fi
    fi
    printf '  %-6s %-15s %s\n' "$eng" "$ip" "$res"
  done < <(awk -F'\t' '$1=="cl"{print $2"\t"$3"\t"$4}' "$STAT_TMP" | sort -t$'\t' -k1,1nr | head -n 8)
}

stat_show() {  # 域名 范围 范围名   (STAT_ASK=1 时最后询问是否核实搜索引擎)
  local d=$1 range=$2 rname=${3:-} max=0 c h t bar n
  [[ -e /var/log/nginx/$d.access.log ]] || { warn "暂无访问日志"; return 1; }
  stat_collect "$d" "$range"
  title "访问统计 · $d"
  echo "  范围: $rname"
  if ((${ST[tot]:-0} == 0)); then echo "  (这个时间段没有访问记录)"; rm -f "$STAT_TMP"; return 0; fi
  printf '  '; pad_w "总请求" 12; printf '%s\n' "${ST[tot]}"
  printf '  '; pad_w "页面访问 PV" 12; printf '%s\n' "${ST[pv]}"
  echo "    ${G}真人 ${ST[hpv]:-0}${N} / 爬虫 ${ST[rpv]:-0} / ${Y}可疑 ${ST[spv]:-0}${N}"
  printf '  '; pad_w "独立 IP" 12; printf '%s\n' "${ST[uv]}"
  echo "    ${G}真人 ${ST[hip]:-0}${N} / 爬虫 ${ST[rip]:-0} / ${Y}可疑 ${ST[sip]:-0}${N}"
  printf '  '; pad_w "流量" 12; printf '%s\n' "$(hb "${ST[bytes]}")"
  echo "  状态码  2xx:${ST[c2]}  3xx:${ST[c3]}"
  echo "          4xx:${ST[c4]}  5xx:${ST[c5]}"
  if [[ -n $(awk -F'\t' '$1=="sp"' "$STAT_TMP") ]]; then
    echo; echo "${B}爬虫 / 脚本 (请求数)${N}"; stat_top sp 8
  fi
  if [[ -n $(awk -F'\t' '$1=="bad"' "$STAT_TMP") ]]; then
    echo; echo "${B}疑似恶意 IP TOP10${N}"; stat_bad 10
  fi
  if [[ -n $(awk -F'\t' '$1=="scu"' "$STAT_TMP") ]]; then
    echo; echo "${B}被扫描的路径 TOP5${N}"; stat_top scu 5
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
  echo
  echo "  ${D}真人/爬虫/可疑 按日志推测, 仅供参考${N}"
  if [[ ${STAT_ASK:-0} == 1 ]] && grep -q '^cl' "$STAT_TMP"; then
    confirm "核实搜索引擎真假? (需联网, 几秒)" n && stat_verify
  fi
  rm -f "$STAT_TMP"
}

stat_overview() {
  local d name
  title "全部站点 · 访问概览"
  echo "  范围: $2"
  printf '  '; pad_w "站点" 15; pad_w "PV" 7; pad_w "真人" 7; pad_w "IP" 5; echo "流量"
  while read -r d; do
    [[ -n $d ]] || continue
    if [[ ! -e /var/log/nginx/$d.access.log ]]; then continue; fi
    stat_collect "$d" "$1"
    name=$d; ((${#name} > 14)) && name="${name:0:13}~"
    printf '  '; pad_w "$name" 15; pad_w "${ST[pv]:-0}" 7; pad_w "${ST[hpv]:-0}" 7; pad_w "${ST[uv]:-0}" 5; hb "${ST[bytes]:-0}"; echo
    rm -f "$STAT_TMP"
  done < <(list_site_names)
  echo "  ${D}真人为推测值, 明细看单个站点统计${N}"
}

stats_menu() {
  local c
  choose c "统计对象:" "单个站点" "全部站点概览" "返回" || return 0
  case $c in
    单个*) pick_site "" || return 0
           stat_range_pick || return 0
           STAT_ASK=1 stat_show "$SITE" "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
    全部*) stat_range_pick || return 0
           stat_overview "$STAT_RANGE" "$STAT_RANGE_NAME" ;;
  esac
}

stats_cli() {
  local d=${1:-} r=${2:-1}
  case $r in 1|y|7|30|all) ;; *) die "范围只能是 1(今天) y(昨天) 7 30 all" ;; esac
  if [[ -z $d ]]; then stat_overview "$r" "$r"; else pick_site "$d" || return 1; stat_show "$d" "$r" "$r"; fi
}

# ================================================================ 通用小工具
sshd_service() { if unit_exists ssh; then echo ssh; else echo sshd; fi; }

ssh_port_now() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
  echo "${p:-22}"
}

files_trunc() {  # 文本 [最大宽度]  (太长时保留结尾)
  local s=$1 n=${2:-30}
  if ((${#s} > n)); then s="~${s: -$((n - 1))}"; fi
  printf '%s' "$s"
}

# ================================================================ 在线更新
UPDATE_CONF=$WSM_DIR/update.conf
SELF_BAK=$WSM_DIR/backup
UPDATE_DEFAULT_URL="https://raw.githubusercontent.com/chentiti888/web/main/wsm.sh"
UPDATE_URL=""
UPDATED=0
UPD_TMP=""
SELF_LAST_BAK=""

update_changes() {  # 新脚本 : 显示比当前版本新的更新内容
  local v rest n=0
  while read -r v rest; do
    # 只显示比当前版本新的; 当前版本没写更新说明时 (如 2.11.5), 遇到更旧的条目也停下
    [[ $(printf '%s\n%s\n' "$v" "$WSM_VER" | sort -V | tail -1) == "$WSM_VER" ]] && break
    echo "  ${G}v$v${N}"
    printf '%s\n' "$rest" | tr ';' '\n' | sed 's/^ *//; /^$/d; s/^/    - /'
    n=$((n + 1)); ((n >= 8)) && break
  done < <(sed -n '/^# CHANGELOG-BEGIN/,/^# CHANGELOG-END/p' "$1" | sed -n 's/^# v//p')
  ((n == 0)) && echo "    (这次没有写更新说明)"
  return 0
}

update_selftest() {  # 新脚本装好后能不能正常运行
  local out
  out=$(timeout 30 bash "$WSM_BIN" version 2>/dev/null) || return 1
  [[ $out == "$1" ]]
}

update_load() { UPDATE_URL=""; [[ -f $UPDATE_CONF ]] && source "$UPDATE_CONF"; UPDATE_URL=${UPDATE_URL:-$UPDATE_DEFAULT_URL}; return 0; }

update_set_url() {
  local in url re_url re_repo
  re_url='^https://[A-Za-z0-9._~:/?&=%@+-]+$'
  re_repo='^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(@([A-Za-z0-9._/-]+))?$'
  echo "填 GitHub 仓库, 如 chentiti888/web  (指定分支: chentiti888/web@dev)"
  echo "也可以直接粘贴仓库网址 (https://github.com/用户/仓库)"
  echo "脚本文件名需要是 wsm.sh; 文件名不同时请直接填完整的 raw 地址 (https://...)"
  read -r -p "仓库 / 地址: " in || return 1
  in=${in// /}
  [[ -n $in ]] || return 1
  in=${in%.git}
  # 直接粘贴 GitHub 网页地址也行: https://github.com/用户/仓库[/tree|blob/分支/...]
  if [[ $in =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(/(tree|blob)/([A-Za-z0-9._-]+).*)?$ ]]; then
    in="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}${BASH_REMATCH[5]:+@${BASH_REMATCH[5]}}"
  fi
  if [[ $in =~ $re_url ]]; then url=$in
  elif [[ $in =~ $re_repo ]]; then
    url="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[4]:-main}/wsm.sh"
  else err "格式不对"; return 1; fi
  mkdir -p "$WSM_DIR"
  printf 'UPDATE_URL=%q\n' "$url" > "$UPDATE_CONF"
  UPDATE_URL=$url
  info "已保存: $url"
  echo "  新服务器安装 wsm (不装任何软件): curl -fsSL $url -o wsm.sh && bash wsm.sh"
  echo "  需要网站环境时再执行: wsm install (或菜单里选 [安装网站环境])"
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

update_install_file() {  # 新文件 : 备份当前版本并替换 (-> SELF_LAST_BAK)
  mkdir -p "$SELF_BAK"
  SELF_LAST_BAK=""
  if [[ -f $WSM_BIN ]]; then
    SELF_LAST_BAK="$SELF_BAK/wsm.v${WSM_VER}.$(date +%Y%m%d_%H%M%S).sh"
    cp -a "$WSM_BIN" "$SELF_LAST_BAK"
  fi
  # shellcheck disable=SC2012
  ls -1t "$SELF_BAK"/wsm.v*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f
  install -m 755 "$1" "$WSM_BIN.new" && mv -f "$WSM_BIN.new" "$WSM_BIN"
}

update_run() {
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
  if grep -q '^# CHANGELOG-BEGIN' "$UPD_TMP"; then echo "  更新内容:"; update_changes "$UPD_TMP"; fi
  if [[ $yes != -y ]]; then confirm "现在更新?" y || { rm -f "$UPD_TMP"; return 0; }; fi
  update_install_file "$UPD_TMP" || { rm -f "$UPD_TMP"; err "写入失败"; return 1; }
  rm -f "$UPD_TMP"
  if [[ -n $vnew ]] && ! update_selftest "$vnew"; then
    if [[ -n $SELF_LAST_BAK && -f $SELF_LAST_BAK ]]; then
      install -m 755 "$SELF_LAST_BAK" "$WSM_BIN"
      err "新版本运行自检没通过, 已自动回滚到 v$WSM_VER"
    else
      err "新版本运行自检没通过, 请检查"
    fi
    return 1
  fi
  UPDATED=1
  bash "$WSM_BIN" app list >/dev/null 2>&1 || true   # 让新版本做一次升级迁移 (如自动找回网站应用模块)
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
    title "更新 / 卸载"
    u=${UPDATE_URL#https://raw.githubusercontent.com/}
    echo "  当前版本: v$WSM_VER"
    echo "  来源: $(files_trunc "$u" 32)"
    choose c "操作:" "检查并更新" "回滚到旧版本" "卸载 wsm" "返回" || return 0
    case $c in
      检查*) update_run ;;
      回滚*) update_rollback ;;
      卸载*) wsm_uninstall ;;
      *) return 0 ;;
    esac
    if [[ $UPDATED == 1 ]]; then info "重新载入新版本 ..."; sleep 1; exec "$WSM_BIN"; fi
    pause
  done
}

# ================================================================ Telegram 告警
# 每 5 分钟检查一次 (cron, 跑完就退出, 不常驻):
#   服务挂了先自动重启, 重启好了/没好/恢复 都发消息; 磁盘快满; 证书快到期 (每天最多一次); 全量备份结果
# 同一个问题只提醒一次, 恢复后再发一条, 不刷屏
TG_CONF=$WSM_DIR/telegram.conf
TG_STATE=$WSM_DIR/monitor.state
TG_CRON=/etc/cron.d/wsm-monitor
TG_TOKEN=""; TG_CHAT=""; TG_ON_BACKUP=1; TG_DISK=90; TG_CERT_DAYS=10; TG_UNITS=""
declare -A MON=()

tg_load() {
  TG_TOKEN=""; TG_CHAT=""; TG_ON_BACKUP=1; TG_DISK=90; TG_CERT_DAYS=10; TG_UNITS=""
  # shellcheck disable=SC1090
  [[ -f $TG_CONF ]] && source "$TG_CONF"
  return 0
}

tg_save() {
  mkdir -p "$WSM_DIR"
  {
    printf 'TG_TOKEN=%q\n' "$TG_TOKEN"; printf 'TG_CHAT=%q\n' "$TG_CHAT"
    printf 'TG_ON_BACKUP=%q\n' "$TG_ON_BACKUP"; printf 'TG_DISK=%q\n' "$TG_DISK"
    printf 'TG_CERT_DAYS=%q\n' "$TG_CERT_DAYS"; printf 'TG_UNITS=%q\n' "$TG_UNITS"
  } > "$TG_CONF"
  chmod 600 "$TG_CONF"
}

tg_ready() { tg_load; [[ -n $TG_TOKEN && -n $TG_CHAT ]]; }

tg_send() {
  tg_ready || return 1
  local ip=${SERVER_IP:-}
  [[ -n $ip ]] || ip=$(public_ip)
  curl -fsS --max-time 15 -o /dev/null "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=[$(fb_host)${ip:+ $ip}]
$1"
}

tg_event() {  # 类型 文本 (backup 类型受开关控制)
  tg_ready || return 0
  [[ $1 == backup && $TG_ON_BACKUP != 1 ]] && return 0
  tg_send "$2" || true
}

mon_state_load() {
  MON=()
  local k v
  [[ -f $TG_STATE ]] || return 0
  while read -r k v; do [[ -n $k ]] && MON[$k]=$v; done < "$TG_STATE"
}

mon_state_save() {
  local k
  for k in "${!MON[@]}"; do printf '%s %s\n' "$k" "${MON[$k]}"; done > "$TG_STATE"
}

mon_units() {  # 需要监控的服务 (只看开机自启的)
  local u v f
  for u in nginx mariadb redis-server redis; do
    unit_exists "$u" && systemctl is-enabled --quiet "$u" 2>/dev/null && echo "$u"
  done
  for v in $(php_installed); do
    u=$(php_svc "$v"); systemctl is-enabled --quiet "$u" 2>/dev/null && echo "$u"
  done
  for u in $(apps_units); do
    systemctl is-enabled --quiet "$u" 2>/dev/null && echo "$u"
  done
  for u in $TG_UNITS; do unit_exists "$u" && echo "$u"; done
  return 0
}

mon_check() {
  tg_ready || return 0
  exec 8>/run/wsm-monitor.lock
  flock -n 8 || return 0
  mon_state_load
  local u pct d days today msgs=() certs=""
  for u in $(mon_units | sort -u); do
    if systemctl is-active --quiet "$u"; then
      if [[ ${MON[svc_$u]:-ok} == down ]]; then msgs+=("✅ $u 已恢复运行"); fi
      MON[svc_$u]=ok
      continue
    fi
    systemctl restart "$u" >/dev/null 2>&1; sleep 5
    if systemctl is-active --quiet "$u"; then
      msgs+=("⚠️ $u 停止运行, 已自动重启恢复")
      MON[svc_$u]=ok
    elif [[ ${MON[svc_$u]:-ok} != down ]]; then
      msgs+=("🔴 $u 停止运行, 自动重启失败! 请尽快登录处理
$(journalctl -u "$u" -n 3 --no-pager -o cat 2>/dev/null | cut -c1-150)")
      MON[svc_$u]=down
    fi
  done
  pct=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5+0}')
  if ((pct >= TG_DISK)) && [[ ${MON[disk]:-ok} != full ]]; then
    msgs+=("💾 磁盘已用 ${pct}%, 快满了 (超过 ${TG_DISK}%)"); MON[disk]=full
  elif ((pct < TG_DISK - 5)) && [[ ${MON[disk]:-ok} == full ]]; then
    msgs+=("✅ 磁盘空间恢复正常 (已用 ${pct}%)"); MON[disk]=ok
  fi
  today=$(date +%F)
  if [[ ${MON[cert_day]:-} != "$today" ]]; then
    MON[cert_day]=$today
    while read -r d; do
      [[ -n $d ]] || continue
      days=$( (load_meta "$d"; [[ $SSL == 1 && $DISABLED != 1 ]] && cert_days_left) 2>/dev/null)
      [[ -n $days ]] && ((days < TG_CERT_DAYS)) && certs+="
  $d 剩 $days 天"
    done < <(list_site_names)
    [[ -n $certs ]] && msgs+=("🔐 证书快到期 (自动续期可能失败了):$certs")
  fi
  mon_state_save
  if ((${#msgs[@]})); then tg_send "$(printf '%s\n' "${msgs[@]}")" || true; fi
  return 0
}

tg_setup() {
  local tok chat c out
  echo "1. 在 Telegram 找 @BotFather, 发 /newbot 新建一个机器人, 复制它给的 token"
  echo "   (建议新建一个专门告警用的, 不要用正在跑程序的机器人)"
  read -r -p "2. 粘贴 token (输入 0 返回): " tok || return 1
  [[ $tok == 0 ]] && return 1
  tok=${tok//[[:space:]]/}
  [[ $tok =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { err "token 格式不对"; return 1; }
  out=$(curl -fsS --max-time 15 "https://api.telegram.org/bot$tok/getMe" 2>/dev/null)
  [[ $out == *'"ok":true'* ]] || { err "token 无效, 或服务器连不上 Telegram"; return 1; }
  choose c "接收告警的账号:" "自动获取 (先给机器人发一条消息)" "手动填写 chat id" || return 1
  if [[ $c == 自动* ]]; then
    echo "3. 打开你的新机器人, 点 Start 或随便发一条消息"
    read -r -p "   发完后按回车..." _ || return 1
    out=$(curl -fsS --max-time 15 "https://api.telegram.org/bot$tok/getUpdates" 2>/dev/null)
    chat=$(printf '%s' "$out" | grep -o '"chat":{"id":-\{0,1\}[0-9]*' | tail -1 | grep -o -- '-\{0,1\}[0-9]*$')
    [[ -n $chat ]] || { err "没收到消息, 确认已经给机器人发过消息再试"; return 1; }
  else
    read -r -p "chat id (个人账号可以问 @userinfobot): " chat || return 1
  fi
  [[ $chat =~ ^-?[0-9]+$ ]] || { err "chat id 格式不对"; return 1; }
  tg_load; TG_TOKEN=$tok; TG_CHAT=$chat; tg_save
  if tg_send "✅ wsm 告警已连接, 有问题会在这里通知你"; then
    info "已发送测试消息, 请在 Telegram 查看"
  else
    err "测试消息发送失败"; return 1
  fi
  [[ -x $WSM_BIN ]] || self_install
  printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n*/5 * * * * root %s monitor >/dev/null 2>&1\n' "$WSM_BIN" > "$TG_CRON"
  chmod 644 "$TG_CRON"
  info "告警已开启: 每 5 分钟检查一次"
}

tg_units_menu() {
  local c u cand au
  tg_load
  echo "  默认监控: Nginx / MariaDB / Redis / PHP-FPM / 网站应用的后台服务"
  echo "  额外监控: ${TG_UNITS:-无}"
  choose c "操作:" "自动发现 (机器人等自定义服务)" "手动添加服务名" "清空额外监控" "返回" || return 0
  case $c in
    自动*)
      cand=""; au=" $(apps_units | tr '\n' ' ') "
      for u in /etc/systemd/system/*.service; do
        [[ -f $u && ! -L $u ]] || continue
        u=${u##*/}; u=${u%.service}
        case $u in wsm-*) continue ;; esac
        [[ $au == *" $u "* ]] && continue
        command -v dpkg >/dev/null 2>&1 && dpkg -S "/etc/systemd/system/$u.service" >/dev/null 2>&1 && continue
        [[ " $TG_UNITS " == *" $u "* ]] || cand+="$u "
      done
      [[ -n $cand ]] || { info "没有发现新的"; return 0; }
      echo "发现: $cand"
      confirm "全部加入监控?" y && { TG_UNITS="${TG_UNITS:+$TG_UNITS }${cand% }"; tg_save; info "已加入"; } ;;
    手动*)
      read -r -p "服务名 (如 okbot, 输入 0 返回): " u || return 0
      [[ $u == 0 || -z $u ]] && return 0
      u=${u%.service}
      unit_exists "$u" || { err "没有这个服务: $u"; return 1; }
      [[ " $TG_UNITS " == *" $u "* ]] || { TG_UNITS="${TG_UNITS:+$TG_UNITS }$u"; tg_save; }
      info "已加入" ;;
    清空*) TG_UNITS=""; tg_save; info "已清空" ;;
  esac
}

tg_menu() {
  local c v
  while true; do
    tg_load
    title "Telegram 告警"
    if [[ -n $TG_TOKEN && -n $TG_CHAT ]]; then
      echo "  状态: $([[ -f $TG_CRON ]] && echo "${G}已开启${N} (每 5 分钟检查)" || echo "${Y}已配置, 定时检查未开启${N}")"
      echo "  磁盘告警: ${TG_DISK}%   证书提前: ${TG_CERT_DAYS} 天   备份通知: $([[ $TG_ON_BACKUP == 1 ]] && echo 开 || echo 关)"
    else
      echo "  状态: 未设置"
    fi
    choose c "操作:" "设置机器人 (首次)" "发送测试消息" "立即检查一次" "额外监控的服务" \
      "告警阈值" "备份结果通知 开/关" "暂停 / 恢复告警" "返回" || return 0
    case $c in
      设置*) (tg_setup); pause ;;
      发送*) tg_send "🔔 测试消息, 告警正常" && info "已发送" || err "发送失败 (先设置机器人)"; pause ;;
      立即*) (mon_check) && info "检查完成 (有问题才会发消息)"; pause ;;
      额外*) (tg_units_menu); pause ;;
      告警*)
        read -r -p "磁盘使用超过多少 % 告警 [$TG_DISK]: " v || continue
        [[ -z $v || ( $v =~ ^[0-9]+$ && $v -ge 50 && $v -le 99 ) ]] && TG_DISK=${v:-$TG_DISK}
        read -r -p "证书剩几天时提醒 [$TG_CERT_DAYS]: " v || continue
        [[ -z $v || ( $v =~ ^[0-9]+$ && $v -ge 1 && $v -le 60 ) ]] && TG_CERT_DAYS=${v:-$TG_CERT_DAYS}
        tg_save; info "已保存" ;;
      备份*) if [[ $TG_ON_BACKUP == 1 ]]; then TG_ON_BACKUP=0; else TG_ON_BACKUP=1; fi; tg_save; info "备份结果通知: $([[ $TG_ON_BACKUP == 1 ]] && echo 开 || echo 关)" ;;
      暂停*)
        if [[ -f $TG_CRON ]]; then rm -f "$TG_CRON"; info "已暂停定时检查"
        elif tg_ready; then
          [[ -x $WSM_BIN ]] || self_install
          printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n*/5 * * * * root %s monitor >/dev/null 2>&1\n' "$WSM_BIN" > "$TG_CRON"
          chmod 644 "$TG_CRON"; info "已恢复定时检查"
        else warn "先设置机器人"; fi ;;
      *) return 0 ;;
    esac
  done
}

# ================================================================ 全量备份 / 搬家 / 异地备份
# 一个备份文件, 里面分开放: 系统配置 (wsm/Nginx/证书/定时任务) | 网站 (含模块程序) | 数据库 | 额外目录 | 机器人 (每个单独一份)
# 还原时可以选: 全部 / 只还原网站+数据库+系统 / 只还原机器人
# 可加密; 可定时; 可自动上传到谷歌网盘 / 其他服务器 (rclone); 新服务器上一条命令还原 (搬家)
FB_DIR=$BACKUP_DIR/full
FB_CONF=$WSM_DIR/fullbak.conf
FB_EXTRA=$WSM_DIR/fullbak-extra.list
FB_CRON=/etc/cron.d/wsm-fullbak
FB_KEY=$WSM_DIR/backup_ed25519
FB_LOG=/var/log/wsm-fullbak.log
FB_KEEP_LOCAL=3; FB_KEEP_REMOTE=7; FB_TARGETS=""; FB_PASS=""; FB_LAST=""

fb_load() {
  FB_KEEP_LOCAL=3; FB_KEEP_REMOTE=7; FB_TARGETS=""; FB_PASS=""
  # shellcheck disable=SC1090
  [[ -f $FB_CONF ]] && source "$FB_CONF"
  return 0
}

fb_save() {
  mkdir -p "$WSM_DIR"
  {
    printf 'FB_KEEP_LOCAL=%q\n' "$FB_KEEP_LOCAL"
    printf 'FB_KEEP_REMOTE=%q\n' "$FB_KEEP_REMOTE"
    printf 'FB_TARGETS=%q\n' "$FB_TARGETS"
    printf 'FB_PASS=%q\n' "$FB_PASS"
  } > "$FB_CONF"
  chmod 600 "$FB_CONF"
}

fb_host() { local h; h=$(hostname -s 2>/dev/null); h=${h//[^A-Za-z0-9-]/_}; echo "${h:-server}"; }

fb_extra_list() {  # 额外备份路径 (存在的才输出; 已经按机器人自动备份的不重复)
  [[ -f $FB_EXTRA ]] || return 0
  local p b skip
  local -a bp=()
  mapfile -t bp < <(fb_bot_paths)
  while IFS= read -r p; do
    [[ $p == /* && -e $p ]] || continue
    skip=0
    for b in "${bp[@]}"; do [[ -n $b && ( $p == "$b" || $p == "$b"/* ) ]] && { skip=1; break; }; done
    ((skip)) || echo "$p"
  done < "$FB_EXTRA"
  return 0
}

fb_extra_detect() {  # 自动发现 (非 Python 机器人的) 自定义 systemd 服务 + 它们的程序目录/配置, /root 下的 json/env
  local f wd ef au bots
  au=" $(apps_units | tr '\n' ' ') "
  bots=" $(fb_bots | cut -d'|' -f1 | tr '\n' ' ') "
  {
    for f in /etc/systemd/system/*.service; do
      [[ -f $f && ! -L $f ]] || continue
      case ${f##*/} in wsm-*) continue ;; esac
      wd=${f##*/}; wd=${wd%.service}
      [[ $au == *" $wd "* || $bots == *" $wd "* ]] && continue
      command -v dpkg >/dev/null 2>&1 && dpkg -S "$f" >/dev/null 2>&1 && continue
      echo "$f"
      wd=$(sed -n 's/^WorkingDirectory=-\{0,1\}//p' "$f" | head -1)
      [[ -n $wd && -d $wd && $wd != / && $wd != /root && $wd != "$WWW_ROOT"* ]] && echo "$wd"
      ef=$(sed -n 's/^EnvironmentFile=-\{0,1\}//p' "$f" | head -1)
      [[ -n $ef && -f $ef && ( -z $wd || $ef != "$wd"/* ) ]] && echo "$ef"
    done
    for f in /root/*.json /root/*.env; do [[ -f $f ]] && echo "$f"; done
  } | sort -u | grep -vxF -f <(fb_bot_paths; echo /nonexistent)
}

# ---------------- 机器人 (Python 写的自定义 systemd 服务, 如 Telegram 机器人)
# 每个机器人单独打包: 程序目录 + .service + 环境变量文件 + 依赖清单; 还原时可以只还原机器人, 和网站互不干扰
fb_bots() {  # 输出: 服务名|程序目录|环境变量文件  (程序目录为空 = 只有单个脚本)
  local f u wd ex sc ef au
  au=" $(apps_units | tr '\n' ' ') "
  for f in /etc/systemd/system/*.service; do
    [[ -f $f && ! -L $f ]] || continue
    u=${f##*/}; u=${u%.service}
    case $u in wsm-*) continue ;; esac
    [[ $au == *" $u "* ]] && continue
    command -v dpkg >/dev/null 2>&1 && dpkg -S "$f" >/dev/null 2>&1 && continue
    ex=$(sed -n 's/^ExecStart=[-@+!]*//p' "$f" | head -1)
    [[ $ex == *python* ]] || continue
    wd=$(sed -n 's/^WorkingDirectory=-\{0,1\}//p' "$f" | head -1)
    if [[ -z $wd ]]; then  # 没写工作目录: 用脚本所在目录
      sc=$(printf '%s\n' "$ex" | tr ' ' '\n' | grep -m1 '\.py$')
      [[ $sc == /* ]] && wd=${sc%/*}
    fi
    case $wd in /|/root|/home|/usr*|/etc*|/var|/opt|"") wd="" ;; esac
    [[ -n $wd && ! -d $wd ]] && wd=""
    ef=$(sed -n 's/^EnvironmentFile=-\{0,1\}//p' "$f" | head -1)
    [[ -n $ef && -f $ef ]] || ef=""
    echo "$u|$wd|$ef"
  done
  return 0
}

fb_bots_desc() {  # okbot (/root/mybot), ...
  local u wd ef out=""
  while IFS='|' read -r u wd ef; do [[ -n $u ]] && out+="${out:+, }$u${wd:+ ($wd)}"; done < <(fb_bots)
  echo "${out:-无}"
}

fb_bot_paths() {  # 机器人占用的全部路径 (给额外备份去重用)
  local u wd ef
  while IFS='|' read -r u wd ef; do
    [[ -n $u ]] || continue
    echo "/etc/systemd/system/$u.service"
    [[ -n $wd ]] && echo "$wd"
    [[ -n $ef ]] && echo "$ef"
  done < <(fb_bots)
}

fb_pip_freeze() {  # 本机用 pip 装到系统 Python 的顶层包 (不含系统自带的、不含被依赖的)
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - <<'PY' 2>/dev/null
import re
try:
    import importlib.metadata as m
except ImportError:
    raise SystemExit
dists = []
for d in m.distributions():
    try:
        loc = str(d.locate_file(""))
    except Exception:
        continue
    if loc.startswith("/usr/local") and d.metadata.get("Name"):
        dists.append(d)
norm = lambda s: re.sub(r"[-_.]+", "-", s).lower()
req = set()
for d in dists:
    for r in (d.requires or []):
        if "extra ==" in r:
            continue
        req.add(norm(re.split(r"[ ;<>=!~\[(]", r, 1)[0]))
for d in sorted(dists, key=lambda x: norm(x.metadata["Name"])):
    if norm(d.metadata["Name"]) not in req:
        print(f'{d.metadata["Name"]}=={d.version}')
PY
}

fb_bots_backup() {  # 暂存目录 : 每个机器人一个子目录
  local st=$1 u wd ef n=0
  local -a paths=()
  while IFS='|' read -r u wd ef; do
    [[ -n $u ]] || continue
    mkdir -p "$st/bots/$u"
    cp -f "/etc/systemd/system/$u.service" "$st/bots/$u/$u.service"
    paths=()
    [[ -n $wd ]] && paths+=("${wd#/}")
    [[ -n $ef && ( -z $wd || $ef != "$wd"/* ) ]] && paths+=("${ef#/}")
    if ((${#paths[@]})); then
      tar -czpf "$st/bots/$u/files.tar.gz" -C / --ignore-failed-read --warning=no-file-changed \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='*.log' "${paths[@]}" 2>/dev/null
      (( $? > 1 )) && { err "打包机器人 $u 失败"; return 1; }
    fi
    [[ -n $wd && -f $wd/requirements.txt ]] && cp -f "$wd/requirements.txt" "$st/bots/$u/requirements.txt"
    fb_bot_syspkgs "$wd" > "$st/bots/$u/sys-packages.txt"
    [[ -s $st/bots/$u/sys-packages.txt ]] || rm -f "$st/bots/$u/sys-packages.txt"
    {
      printf 'BOT_UNIT=%q\n' "$u"
      printf 'BOT_DIR=%q\n' "$wd"
      printf 'BOT_ENV=%q\n' "$ef"
      printf 'BOT_PY=%q\n' "$(python3 -V 2>&1 | awk '{print $2}')"
      printf 'BOT_ACTIVE=%q\n' "$(systemctl is-active "$u" 2>/dev/null)"
    } > "$st/bots/$u/info.env"
    n=$((n + 1))
  done < <(fb_bots)
  ((n)) && fb_pip_freeze > "$st/bots/pip-packages.txt"
  return 0
}

fb_pip_install() {  # 依赖清单文件 : 装到系统 Python (只装不删)
  local f=$1 flag="" out
  [[ -s $f ]] || return 0
  command -v pip3 >/dev/null 2>&1 || pkg_install python3-pip >/dev/null 2>&1 || { warn "pip 安装失败, 依赖没装"; return 1; }
  pip3 install --help 2>/dev/null | grep -q -- --break-system-packages && flag=--break-system-packages
  out=$(pip3 install $flag --disable-pip-version-check -q -r "$f" 2>&1) && return 0
  # 整体失败 (常见: 某个版本没有适合新 Python 的安装包) -> 逐个装, 装不上的换最新版
  local line pkg fails=""
  while read -r line; do
    [[ -n $line && $line != \#* ]] || continue
    pip3 install $flag --disable-pip-version-check -q "$line" >/dev/null 2>&1 && continue
    pkg=${line%%[=<>!~ ;]*}
    if pip3 install $flag --disable-pip-version-check -q "$pkg" >/dev/null 2>&1; then
      warn "  $line 装不上, 已改装最新版 $pkg"
    else fails+=" $pkg"; fi
  done < "$f"
  [[ -z $fails ]] || { warn "  这些依赖没装上:$fails"; return 1; }
}

fb_bot_restore() {
  # shellcheck disable=SC2034  # BOT_ENV / BOT_ACTIVE 来自 info.env, 留着给以后用
  local d=$1 BOT_UNIT="" BOT_DIR="" BOT_ENV="" BOT_PY="" BOT_ACTIVE="" req
  # shellcheck disable=SC1091
  source "$d/info.env"
  [[ $BOT_UNIT =~ ^[A-Za-z0-9_.@-]+$ ]] || { err "机器人信息异常"; return 1; }
  echo
  info "还原机器人 $BOT_UNIT (${BOT_DIR:-单个脚本}) ..."
  if systemctl is-active --quiet "$BOT_UNIT" 2>/dev/null; then
    warn "本机已有正在运行的 $BOT_UNIT"
    confirm "停止它并用备份覆盖?" n || return 0
    systemctl stop "$BOT_UNIT"
  fi
  [[ -f $d/files.tar.gz ]] && { tar -xzpf "$d/files.tar.gz" -C / || { err "解压失败"; return 1; }; }
  install -m 644 "$d/$BOT_UNIT.service" "/etc/systemd/system/$BOT_UNIT.service"
  systemctl daemon-reload
  systemctl enable "$BOT_UNIT" >/dev/null 2>&1
  command -v python3 >/dev/null 2>&1 || pkg_install python3 >/dev/null 2>&1
  if [[ -s $d/sys-packages.txt ]]; then
    local p miss=() fails=""
    while read -r p; do
      [[ $p =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]] || continue
      if command -v dpkg >/dev/null 2>&1; then dpkg -s "$p" >/dev/null 2>&1 && continue
      else rpm -q "$p" >/dev/null 2>&1 && continue; fi
      miss+=("$p")
    done < "$d/sys-packages.txt"
    if ((${#miss[@]})); then
      info "  安装机器人用到的系统工具: ${miss[*]}"
      pkg_refresh >/dev/null 2>&1
      pkg_install "${miss[@]}" >/dev/null 2>&1 || for p in "${miss[@]}"; do pkg_install "$p" >/dev/null 2>&1 || fails+=" $p"; done
      [[ -z $fails ]] || warn "  这些系统工具没装上 (新系统可能换了包名):$fails"
    fi
  fi
  req=$d/requirements.txt; [[ -s $req ]] || req=${d%/*}/pip-packages.txt
  if [[ -s $req ]]; then
    info "  安装 Python 依赖 (装到系统 Python, 不影响网站) ..."
    [[ -n $BOT_PY && $BOT_PY != "$(python3 -V 2>&1 | awk '{print $2}')" ]] && \
      echo "  旧服务器 Python $BOT_PY, 本机 $(python3 -V 2>&1 | awk '{print $2}'), 版本不同时个别依赖可能要换版本"
    fb_pip_install "$req"
  fi
  echo "  ${Y}同一个机器人 (同一个 Token) 不能两台服务器同时运行, 否则两边都收不到消息${N}"
  if confirm "旧服务器上的 $BOT_UNIT 已经停了? 现在启动本机的" n; then
    systemctl restart "$BOT_UNIT"; sleep 5
    if systemctl is-active --quiet "$BOT_UNIT"; then info "  $BOT_UNIT 已启动, 运行正常 (开机自启)"
    else
      err "  $BOT_UNIT 没有跑起来, 最近日志:"
      journalctl -u "$BOT_UNIT" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
      echo "  常见原因: 缺依赖 (pip3 install 包名 --break-system-packages 后 systemctl restart $BOT_UNIT)"
    fi
  else
    echo "  已设好开机自启但没有启动。停掉旧服务器的之后执行: systemctl start $BOT_UNIT"
  fi
}

# ---------------- 运行环境清单 (还原到新服务器时自动装好, 不用手动配环境)
fb_soft_list() {  # wsm 软件商店里已安装的软件 (Nginx/phpMyAdmin 另外处理)
  local a out=""
  for a in "${APP_IDS[@]}"; do
    case $a in webbase|phpmyadmin) continue ;; esac
    app_installed "$a" && out+="$a "
  done
  echo "${out% }"
}

fb_node_ver() {  # Node.js 大版本; 用系统自带包装的输出 sys
  command -v node >/dev/null 2>&1 || return 0
  if [[ -f /etc/apt/sources.list.d/nodesource.list ]] || grep -qs nodesource /etc/yum.repos.d/*.repo; then
    node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/'
  else echo sys; fi
}

fb_php_exts() {  # 每个 PHP 版本已加载的扩展: "版本 扩展" 一行一个
  local v b
  for v in $(php_installed); do
    b=$(php_bin "$v"); command -v "$b" >/dev/null 2>&1 || continue
    "$b" -m 2>/dev/null | awk -v v="$v" 'NF && $0 !~ /^\[/ {n=tolower($0); if (n=="zend opcache") n="opcache"; print v, n}'
  done
}

php_ext_pkg() {  # php -m 里的扩展名 -> 软件包里的扩展名 (空 = 跟着基础包/核心自带)
  case $1 in
    mysqli|mysqlnd|pdo_mysql) echo mysql ;;
    pgsql|pdo_pgsql) echo pgsql ;;
    sqlite3|pdo_sqlite) echo sqlite3 ;;
    dom|simplexml|xmlreader|xmlwriter|xml|libxml|xsl) [[ $1 == xsl ]] && echo xsl || echo xml ;;
    core|date|filter|hash|json|pcre|random|reflection|session|spl|standard|zlib|openssl|ctype|fileinfo|tokenizer| \
    iconv|phar|posix|sockets|calendar|exif|ftp|gettext|shmop|sysvmsg|sysvsem|sysvshm|pdo|readline|sodium|ffi|cgi-fcgi) ;;
    *) echo "$1" ;;
  esac
}

fb_php_exts_restore() {  # 清单文件 : 补装新服务器上缺少的 PHP 扩展
  local f=$1 v e pkg b miss fails=""
  [[ -s $f ]] || return 0
  for v in $(awk '{print $1}' "$f" | sort -u); do
    php_installed | grep -qx "$v" || continue
    b=$(php_bin "$v")
    miss=()
    while read -r e; do
      "$b" -m 2>/dev/null | awk '{print tolower($0)}' | grep -qx "$e" && continue
      [[ $e == opcache ]] && "$b" -m 2>/dev/null | grep -qi 'zend opcache' && continue
      pkg=$(php_ext_pkg "$e"); [[ -n $pkg ]] || continue
      "$b" -m 2>/dev/null | grep -qix "$pkg" && continue                 # 同一个包里的别的扩展已经有了
      [[ $pkg == mysql ]] && "$b" -m 2>/dev/null | grep -qix mysqli && continue
      [[ " ${miss[*]} " == *" $pkg "* ]] || miss+=("$pkg")
    done < <(awk -v v="$v" '$1==v {print $2}' "$f")
    ((${#miss[@]})) || continue
    info "  PHP $v 补装扩展: ${miss[*]}"
    php_exts_ensure "$v" "${miss[@]}"
    for e in "${miss[@]}"; do
      "$b" -m 2>/dev/null | awk '{print tolower($0)}' | grep -qx "$e" || \
        { [[ $e == mysql ]] && "$b" -m 2>/dev/null | grep -qix mysqli; } || fails+=" $v/$e"
    done
  done
  [[ -z $fails ]] || warn "  这些 PHP 扩展没装上 (可到 软件管理 → PHP 扩展 手动安装):$fails"
  return 0
}

fb_soft_restore() {  # "软件..." Node大版本 : 补装旧服务器上有、本机没有的软件
  local a fails=""
  for a in $1; do
    app_valid "$a" 2>/dev/null || continue
    app_installed "$a" && continue
    info "  安装 $(app_name "$a" 2>/dev/null || echo "$a") ..."
    if [[ $a == nodejs ]]; then
      ( WSM_NODE_VER=${2:-24} app_install nodejs ) >/dev/null 2>&1 || ( WSM_NODE_VER=sys app_install nodejs ) >/dev/null 2>&1
    else
      ( app_install "$a" ) >/dev/null 2>&1
    fi
    app_installed "$a" || fails+=" $a"
  done
  [[ -z $fails ]] || warn "  这些软件没装上, 请到 软件管理 里手动安装:$fails"
  return 0
}

fb_cmd_list() {  # /usr/local/bin 下自己装的命令 (如 tgbot): shell 脚本、不属于系统软件包、不是 wsm 本身
  local f
  for f in /usr/local/bin/*; do
    [[ -f $f && ! -L $f && $f != "$WSM_BIN" ]] || continue
    (( $(stat -c %s "$f" 2>/dev/null || echo 9999999) < 1048576 )) || continue
    head -1 "$f" 2>/dev/null | grep -qE '^#!.*(/|env +)(ba)?sh\b' || continue   # 只要 shell 脚本 (pip 装的 python 命令跟着依赖重装)
    if command -v dpkg >/dev/null 2>&1; then dpkg -S "$f" >/dev/null 2>&1 && continue
    elif command -v rpm >/dev/null 2>&1; then rpm -qf "$f" >/dev/null 2>&1 && continue; fi
    echo "${f#/}"
  done
}

fb_cmd_restore() {  # 备份目录 : 还原自定义命令 (本机已有同名的不覆盖)
  local b=$1 tmp f n=0
  [[ -f $b/cmds.tar.gz ]] || return 0
  tmp=$(mktemp -d)
  tar -xzpf "$b/cmds.tar.gz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 0; }
  for f in "$tmp"/usr/local/bin/*; do
    [[ -f $f ]] || continue
    [[ -e /usr/local/bin/${f##*/} ]] && continue
    install -m 755 "$f" "/usr/local/bin/${f##*/}" && n=$((n + 1)) && info "  已还原命令: ${f##*/}"
  done
  rm -rf "$tmp"
  return 0
}

fb_ssh_restore() {  # 端口 关密码(0|1) : 把旧服务器的 SSH 设置套用到本机
  local port=${1:-22} nopass=${2:-0} cur
  [[ $port =~ ^[0-9]+$ ]] || port=22
  cur=$(ssh_port_now)
  [[ $port == "$cur" && $nopass == "$(ssh_nopass_now && echo 1 || echo 0)" ]] && return 0
  [[ $port == 22 && $nopass == 0 ]] && return 0
  echo
  info "旧服务器的 SSH 设置: 端口 $port, 密码登录 $([[ $nopass == 1 ]] && echo 关闭 || echo 开启)"
  echo "  本机现在: 端口 $cur, 密码登录 $(ssh_nopass_now && echo 关闭 || echo 开启)"
  if [[ $nopass == 1 ]] && (( $(ssh_key_count) == 0 )); then
    warn "本机没有登录密钥, 先不关闭密码登录"; nopass=0
  fi
  [[ $port != 22 ]] && echo "  云服务器有安全组的, 要先在服务商后台放行 TCP $port"
  confirm "套用到本机?" y || { echo "  已跳过, 之后可在 安全防护 → SSH 安全 里设置"; return 0; }
  if [[ $port != "$cur" ]] && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    warn "端口 $port 已被本机其他程序占用, 保持端口 $cur"; port=$cur
  fi
  [[ $port != 22 ]] && ssh_fw_open "$port"
  ssh_apply "$nopass" "$port" || return 0
  sleep 1
  if [[ $port != "$cur" ]] && ! ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    err "sshd 没有在 $port 上监听, 恢复为 $cur"; ssh_apply "$nopass" "$cur"; return 0
  fi
  info "SSH 已套用: 端口 $port$([[ $nopass == 1 ]] && echo ', 只能用密钥登录')"
  warn "别关当前窗口! 新开一个窗口用端口 $port $([[ $nopass == 1 ]] && echo 和密钥)登录测试"
  if ! confirm "新窗口登录成功了吗? (选 n 恢复成原来的设置)" n; then
    ssh_apply 0 "$cur" && info "已恢复: 端口 $cur, 密码登录开启"
  fi
  return 0
}

fb_bot_syspkgs() {  # 程序目录 : 机器人代码里调用的系统命令 -> 所属软件包名 (一行一个)
  local wd=$1 c p real pkg
  [[ -n $wd && -d $wd ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  while read -r c; do
    [[ $c =~ ^[A-Za-z0-9_.+-]+$ ]] || continue
    case $c in python|python3|sh|bash|env|sudo|systemctl|journalctl|kill|echo|true|false) continue ;; esac
    p=$(command -v "$c" 2>/dev/null) || continue
    [[ $p == /* ]] || continue
    real=$(readlink -f "$p")
    if command -v dpkg >/dev/null 2>&1; then
      pkg=$(dpkg -S "$real" 2>/dev/null || dpkg -S "$p" 2>/dev/null)
      pkg=${pkg%%:*}; pkg=${pkg%%,*}
    else
      pkg=$(rpm -qf --qf '%{NAME}\n' "$real" 2>/dev/null | head -1)
    fi
    [[ -n $pkg && $pkg != *" "* ]] && echo "$pkg"
  done < <(python3 - "$wd" <<'PY' 2>/dev/null
import os, re, sys
root = sys.argv[1]
pat = [
    r"""(?:subprocess\.(?:run|Popen|check_output|check_call|call|getoutput|getstatusoutput)|create_subprocess_exec|create_subprocess_shell|shutil\.which|os\.system|os\.popen|os\.exec\w*)\(\s*\[?\s*[fFrR]?["']\s*([A-Za-z0-9_.+-]+)""",
    r"""\[\s*[fF]?["']([A-Za-z0-9_.+-]+)["']\s*,\s*[fF]?["']-""",
    r"""\b(?:cmd|command|args|argv)\s*=\s*\[\s*[fF]?["']([A-Za-z0-9_.+-]+)["']""",
]
found = set()
base = root.rstrip(os.sep).count(os.sep)
for dp, dn, fn in os.walk(root):
    dn[:] = [d for d in dn if d not in {".git", "__pycache__", "venv", ".venv", "node_modules"}]
    if dp.count(os.sep) - base >= 5:
        dn[:] = []
    for f in fn:
        if not f.endswith(".py"):
            continue
        try:
            t = open(os.path.join(dp, f), encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for p in pat:
            found.update(re.findall(p, t))
print("\n".join(sorted(found)))
PY
) | sort -u
}

fb_tar_part() {  # 输出文件 路径... (相对 /; 没有路径就不生成)
  local out=$1; shift
  (($#)) || return 0
  tar -czpf "$out" -C / --ignore-failed-read --warning=no-file-changed \
    --exclude='storage/logs/*.log' --exclude="${FB_DIR#/}" "$@" 2>/dev/null
  (( $? <= 1 ))
}

fb_dump_users() {  # 导出数据库账号和权限 (MariaDB 10.2+)
  local u h
  mysql -N -e "SELECT user,host FROM mysql.user WHERE user NOT IN ('root','mysql','mariadb.sys','debian-sys-maint','')" 2>/dev/null \
  | while read -r u h; do
      mysql -N -e "SHOW CREATE USER '$u'@'$h'" 2>/dev/null | sed 's/^CREATE USER /CREATE USER IF NOT EXISTS /; s/$/;/'
      mysql -N -e "SHOW GRANTS FOR '$u'@'$h'" 2>/dev/null | sed 's/$/;/'
    done
}

fb_create() {  # [auto] : 生成全量备份 -> FB_LAST
  # 包里分开放: system / sites / extra / db / bots/<每个机器人>, 还原时可以分开选
  fb_load
  local mode=${1:-} ts host name stage p d need avail rc bots="" u wd ef
  local -a sys=() sites=() extra=() all=()
  ts=$(date +%Y%m%d_%H%M%S); host=$(fb_host)
  mkdir -p "$FB_DIR"; chmod 700 "$FB_DIR"
  for p in "$WSM_DIR" /etc/letsencrypt "$NGX_CONF" /root/.config/rclone /etc/cron.d/wsm-* \
           /etc/php/*/fpm/conf.d/99-wsm.ini /etc/opt/remi/php*/php.d/99-wsm.ini; do
    [[ -e $p ]] && sys+=("${p#/}")
  done
  for p in "$WWW_ROOT" $(apps_hook backup_paths); do [[ -e $p ]] && sites+=("${p#/}"); done
  while IFS= read -r p; do extra+=("${p#/}"); done < <(fb_extra_list)
  while IFS='|' read -r u wd ef; do
    [[ -n $u ]] || continue
    bots+="$u "; [[ -n $wd ]] && all+=("${wd#/}")
  done < <(fb_bots)
  all+=("${sys[@]}" "${sites[@]}" "${extra[@]}")
  need=$( (cd / && du -sk "${all[@]}" 2>/dev/null) | awk '{s+=$1} END{print s+0}')
  avail=$(df -Pk "$FB_DIR" | awk 'NR==2{print $4}')
  if (( avail < need / 2 + 102400 )); then
    err "磁盘空间可能不够: 需要约 $((need / 1024))MB, 剩余 $((avail / 1024))MB"
    [[ $mode == auto ]] && return 1
    confirm "仍然继续?" n || return 1
  fi
  stage=$(mktemp -d "$FB_DIR/.tmp-XXXXXX")
  info "打包 (大约 $((need / 1024))MB, 请稍等) ..."
  fb_tar_part "$stage/system.tar.gz" "${sys[@]}" && fb_tar_part "$stage/sites.tar.gz" "${sites[@]}" \
    && fb_tar_part "$stage/extra.tar.gz" "${extra[@]}" || { rm -rf "$stage"; err "打包文件失败"; return 1; }
  crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*$' > "$stage/root.crontab"
  [[ -s $stage/root.crontab ]] || rm -f "$stage/root.crontab"
  [[ -s $SSH_AK ]] && cp -f "$SSH_AK" "$stage/authorized_keys"
  fb_bots_backup "$stage" || { rm -rf "$stage"; return 1; }
  if command -v mysql >/dev/null 2>&1 && mysql -e "SELECT 1" >/dev/null 2>&1; then
    info "导出数据库 ..."
    mkdir -p "$stage/db"
    while read -r d; do
      [[ -n $d ]] || continue
      if ! mysqldump --single-transaction --routines --events --triggers --databases "$d" | gzip > "$stage/db/$d.sql.gz"; then
        rm -rf "$stage"; err "导出数据库失败: $d"; return 1
      fi
    done < <(db_names)
    fb_dump_users > "$stage/db/users.sql"
  fi
  fb_php_exts > "$stage/php-ext.txt"; [[ -s $stage/php-ext.txt ]] || rm -f "$stage/php-ext.txt"
  local -a cmds=(); mapfile -t cmds < <(fb_cmd_list)
  fb_tar_part "$stage/cmds.tar.gz" "${cmds[@]}" || true
  {
    printf 'FB_FORMAT=2\n'
    printf 'FB_WSM=%q\n' "$WSM_VER"
    printf 'FB_DATE=%q\n' "$(date '+%F %T')"
    printf 'FB_HOST=%q\n' "$host"
    printf 'FB_PHP=%q\n' "$(php_installed | sort -V | tr '\n' ' ')"
    printf 'FB_REDIS=%q\n' "$( { unit_exists redis-server || unit_exists redis; } && echo 1 || echo 0)"
    printf 'FB_SITES=%q\n' "$(list_site_names | tr '\n' ' ')"
    printf 'FB_DBS=%q\n' "$(find "$stage/db" -name '*.sql.gz' 2>/dev/null | sed 's|.*/||; s|\.sql\.gz$||' | sort | tr '\n' ' ')"
    printf 'FB_EXTRAS=%q\n' "$(printf '/%s ' "${extra[@]}" | sed 's|^/ $||')"
    printf 'FB_BOTS=%q\n' "${bots% }"
    printf 'FB_SOFT=%q\n' "$(fb_soft_list)"
    printf 'FB_NODE=%q\n' "$(fb_node_ver)"
    printf 'FB_CFW=%q\n' "$( { cfw_active || [[ -f $CFW_UNIT ]]; } && echo 1 || echo 0)"
    printf 'FB_SSH_PORT=%q\n' "$(ssh_port_now 2>/dev/null)"
    printf 'FB_SSH_NOPASS=%q\n' "$(ssh_nopass_now 2>/dev/null && echo 1 || echo 0)"
    printf 'FB_CMDS=%q\n' "$(printf '%s ' "${cmds[@]##*/}" | sed 's/ $//')"
  } > "$stage/manifest.env"
  name="wsm-full-${host}-${ts}.tar"
  if ! tar -cf "$FB_DIR/$name" -C "$stage" .; then rm -rf "$stage" "${FB_DIR:?}/$name"; err "生成备份文件失败"; return 1; fi
  rm -rf "$stage"
  if [[ -n $FB_PASS ]]; then
    if ! WSM_FBPASS=$FB_PASS openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:WSM_FBPASS \
         -in "$FB_DIR/$name" -out "$FB_DIR/$name.enc"; then
      rm -f "${FB_DIR:?}/$name" "${FB_DIR:?}/$name.enc"; err "加密失败"; return 1
    fi
    rm -f "${FB_DIR:?}/$name"; name="$name.enc"
  fi
  chmod 600 "$FB_DIR/$name"
  FB_LAST=$FB_DIR/$name
  # shellcheck disable=SC2012
  ls -1t "$FB_DIR"/wsm-full-*.tar* 2>/dev/null | tail -n +$((FB_KEEP_LOCAL + 1)) | xargs -r rm -f
  info "全量备份完成: $FB_LAST ($(du -h "$FB_LAST" | cut -f1))"
  echo "  网站 $(list_site_names | grep -c .) 个 · 数据库 $(db_names 2>/dev/null | grep -c .) 个 · 机器人: ${bots:-无}"
}

fb_upload() {  # 文件 : 上传到全部异地目标, 并清理多余的旧备份; 返回失败个数
  fb_load
  local f=$1 t old host fails=0
  [[ -n $FB_TARGETS ]] || return 0
  command -v rclone >/dev/null 2>&1 || { err "没有安装 rclone, 无法上传"; return 1; }
  host=$(fb_host)
  for t in $FB_TARGETS; do
    info "上传到 $t ..."
    if rclone copy "$f" "$t" --retries 3 --low-level-retries 10 -q; then
      rclone lsf "$t" --files-only 2>/dev/null | grep "^wsm-full-${host}-" | sort -r \
        | tail -n +$((FB_KEEP_REMOTE + 1)) | while read -r old; do rclone deletefile "$t/$old" -q; done
      info "  上传成功"
    else
      err "  上传失败: $t"; fails=$((fails + 1))
    fi
  done
  return "$fails"
}

fb_run() {  # [auto] : 备份 + 上传 + 通知 (定时任务调用 wsm backup-all auto)
  local mode=${1:-} rc=0 size=""
  exec 9>/run/wsm-fullbak.lock
  flock -n 9 || { err "已经有一个全量备份正在运行"; return 1; }
  [[ $mode == auto ]] && echo "===== $(date '+%F %T') 开始全量备份"
  if fb_create "$mode"; then
    size=$(du -h "$FB_LAST" | cut -f1)
    fb_upload "$FB_LAST" || rc=2
  else
    rc=1
  fi
  if declare -F tg_event >/dev/null; then
    case $rc in
      0) tg_event backup "✅ 全量备份完成 ($size)${FB_TARGETS:+, 已上传异地}" ;;
      2) tg_event backup "⚠️ 全量备份已完成 ($size), 但异地上传失败, 请检查" ;;
      *) tg_event backup "❌ 全量备份失败, 请登录服务器查看 $FB_LOG" ;;
    esac
  fi
  return "$rc"
}

# ---------------- 异地目标 (rclone)
fb_rclone_ensure() {
  command -v rclone >/dev/null 2>&1 && return 0
  info "安装 rclone ..."
  command -v unzip >/dev/null 2>&1 || pkg_install unzip >/dev/null 2>&1
  if curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 && command -v rclone >/dev/null 2>&1; then
    pkg_has rclone || ledger_add @rclone "异地备份 (rclone)"
  else
    PKG_FOR="异地备份" pkg_install rclone >/dev/null 2>&1
  fi
  command -v rclone >/dev/null 2>&1 || { err "rclone 安装失败, 请检查网络"; return 1; }
}

fb_rclone_conf() { rclone config file 2>/dev/null | tail -1; }

fb_rclone_add() {  # 名称 < 配置内容 (key = value 行)
  local f; f=$(fb_rclone_conf)
  [[ -n $f ]] || { err "找不到 rclone 配置文件位置"; return 1; }
  mkdir -p "$(dirname "$f")"
  { echo; echo "[$1]"; cat; } >> "$f"
  chmod 600 "$f"
}

fb_name_ok() {  # 远程名称: 字母数字横线; 同名的旧配置没在用就可以覆盖
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]{0,29}$ ]] || { err "名称要以字母开头, 只能用字母数字 _ -"; return 1; }
  rclone listremotes 2>/dev/null | grep -qx "$1:" || return 0
  fb_load
  if [[ " $FB_TARGETS " == *" $1:"* ]]; then err "名称 $1 正在作为备份目标使用, 请换个名字"; return 1; fi
  confirm "已有一个叫 $1 的旧配置 (之前添加失败留下的?), 覆盖它?" y || return 1
  rclone config delete "$1" >/dev/null 2>&1
}

fb_target_set() {  # 远程名 目录 : 测试并加入异地目标
  local t="$1:$2"
  info "测试连接 ..."
  # 对象存储的令牌通常只能读写指定的桶, 不能建桶, 所以 mkdir 失败不算失败, 能列出目录才算连通
  rclone mkdir "$t" 2>/tmp/wsm_rclone_err
  if ! rclone lsf "$t" --max-depth 1 >/dev/null 2>>/tmp/wsm_rclone_err; then
    err "连接失败:"; tail -3 /tmp/wsm_rclone_err >&2
    rclone config delete "$1" >/dev/null 2>&1
    return 1
  fi
  fb_load
  [[ " $FB_TARGETS " == *" $t "* ]] || FB_TARGETS="${FB_TARGETS:+$FB_TARGETS }$t"
  fb_save
  info "已添加异地目标: $t"
}

fb_gdrive_ask_client() {  # -> GD_CID GD_SEC (自己的 client_id, 可留空用 rclone 共用的)
  GD_CID=""; GD_SEC=""
  echo "  谷歌会停用 rclone 共用的授权 (2026 年内), 建议用自己的 client_id。"
  echo "  创建方法: 谷歌云控制台建一个「桌面应用」OAuth 客户端 (详见 rclone.org/drive)"
  choose GD_CID "用哪个授权:" "自己的 client_id (推荐)" "rclone 共用 (以后会失效)" || return 1
  if [[ $GD_CID == 自己* ]]; then
    read -r -p "客户端 ID (以 .apps.googleusercontent.com 结尾): " GD_CID || return 1
    GD_CID=${GD_CID//[[:space:]]/}
    [[ $GD_CID =~ ^[0-9A-Za-z_-]+\.apps\.googleusercontent\.com$ ]] || { err "客户端 ID 格式不对"; return 1; }
    read -r -p "客户端密钥 (GOCSPX- 开头): " GD_SEC || return 1
    GD_SEC=${GD_SEC//[[:space:]]/}
    [[ $GD_SEC =~ ^[A-Za-z0-9_-]{10,}$ ]] || { err "客户端密钥格式不对"; return 1; }
  else
    GD_CID=""
  fi
}

fb_gdrive_auth() {  # [client_id] [secret] -> GD_TOKEN (手机浏览器授权)
  local cid=${1:-} sec=${2:-} log pid i url gurl cb m
  local -a args=(authorize drive)
  [[ -n $cid ]] && args+=("$cid" "$sec")
  GD_TOKEN=""
  choose m "授权方式:" "手机浏览器授权 (推荐)" "粘贴 token (电脑上运行 rclone authorize 得到)" || return 1
  if [[ $m == 粘贴* ]]; then
    echo "在装了 rclone 的电脑上运行: rclone authorize \"drive\"${cid:+ \"$cid\" \"$sec\"}"
    echo "浏览器授权后, 把输出的 {\"access_token\": ... } 整段粘贴到这里:"
    read -r -p "token: " GD_TOKEN || return 1
    GD_TOKEN=$(printf '%s' "$GD_TOKEN" | tr -d '\r')
    [[ $GD_TOKEN == \{*refresh_token*\} ]] || { err "token 格式不对"; GD_TOKEN=""; return 1; }
    return 0
  fi
  log=$(mktemp)
  rclone "${args[@]}" --auth-no-open-browser > "$log" 2>&1 &
  pid=$!
  url=""
  for i in $(seq 1 30); do
    url=$(grep -o 'http://127\.0\.0\.1:53682/auth?state=[A-Za-z0-9_-]*' "$log" | head -1)
    [[ -n $url ]] && break; sleep 0.5
  done
  gurl=""
  [[ -n $url ]] && gurl=$(curl -s -o /dev/null -w '%{redirect_url}' "$url")
  if [[ $gurl != https://* ]]; then
    kill "$pid" 2>/dev/null; err "启动授权失败:"; tail -5 "$log" >&2; rm -f "$log"; return 1
  fi
  echo
  echo "① 复制下面整段链接, 用手机浏览器打开, 登录谷歌账号并点「允许」:"
  [[ -n $cid ]] && echo "   (提示「Google 尚未验证此应用」时, 点 高级 → 继续前往)"
  echo
  echo "$gurl"
  echo
  echo "② 允许后浏览器会跳到一个打不开的页面 (地址以 http://127.0.0.1:53682 开头),"
  echo "   这是正常的。把浏览器地址栏里的完整地址复制下来。"
  read -r -p "③ 粘贴到这里: " cb || { kill "$pid" 2>/dev/null; rm -f "$log"; return 1; }
  cb=${cb//[[:space:]]/}; cb=${cb/localhost:53682/127.0.0.1:53682}
  if [[ ! $cb =~ ^http://127\.0\.0\.1:53682/.*code= ]]; then
    kill "$pid" 2>/dev/null; rm -f "$log"; err "地址不对, 应该以 http://127.0.0.1:53682/ 开头并含有 code="; return 1
  fi
  curl -s -o /dev/null "$cb"
  for i in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill "$pid" 2>/dev/null
  GD_TOKEN=$(grep -o '{"access_token".*}' "$log" | head -1)
  [[ -n $GD_TOKEN ]] || { err "没有拿到授权:"; tail -5 "$log" >&2; rm -f "$log"; return 1; }
  rm -f "$log"
}

fb_gdrive_conf() {  # client_id secret token : 输出 rclone 配置内容
  printf 'type = drive\nscope = drive\n'
  [[ -n $1 ]] && printf 'client_id = %s\nclient_secret = %s\n' "$1" "$2"
  printf 'token = %s\n' "$3"
}

fb_gdrive_add() {
  local name folder
  fb_rclone_ensure || return 1
  read -r -p "给这个网盘起个名字 [gdrive] (输入 0 返回): " name || return 1
  [[ $name == 0 ]] && return 1
  name=${name:-gdrive}; fb_name_ok "$name" || return 1
  read -r -p "网盘里的备份文件夹 [wsm-backup]: " folder || return 1
  folder=${folder:-wsm-backup}; folder=${folder#/}
  [[ $folder =~ ^[A-Za-z0-9._/-]+$ ]] || { err "文件夹名只能用字母数字 . _ - /"; return 1; }
  fb_gdrive_ask_client || return 1
  fb_gdrive_auth "$GD_CID" "$GD_SEC" || return 1
  fb_gdrive_conf "$GD_CID" "$GD_SEC" "$GD_TOKEN" | fb_rclone_add "$name" || return 1
  fb_target_set "$name" "$folder"
}

fb_gdrive_reauth() {  # 已有的谷歌网盘换成自己的 client_id 并重新授权 (目标和文件夹不变)
  fb_load
  local t n bak f
  local -a gds=()
  fb_rclone_ensure || return 1
  for t in $FB_TARGETS; do
    n=${t%%:*}
    rclone config show "$n:" 2>/dev/null | grep -q '^type = drive' && gds+=("$n")
  done
  ((${#gds[@]})) || { warn "还没有添加谷歌网盘"; return 0; }
  if ((${#gds[@]} == 1)); then n=${gds[0]}; else choose n "哪个网盘?" "${gds[@]}" || return 0; fi
  if rclone config show "$n:" 2>/dev/null | grep -q '^client_id = '; then
    echo "  $n 已经在用自己的 client_id, 继续会重新授权"
  else
    echo "  $n 现在用的是 rclone 共用授权"
  fi
  fb_gdrive_ask_client || return 1
  fb_gdrive_auth "$GD_CID" "$GD_SEC" || return 1
  f=$(fb_rclone_conf); bak=$(mktemp); cp -a "$f" "$bak"
  rclone config delete "$n" >/dev/null 2>&1
  fb_gdrive_conf "$GD_CID" "$GD_SEC" "$GD_TOKEN" | fb_rclone_add "$n" || { cp -a "$bak" "$f"; rm -f "$bak"; return 1; }
  info "测试连接 ..."
  if rclone lsf "$n:" --max-depth 1 >/dev/null 2>&1; then
    rm -f "$bak"; info "$n 已更换授权, 备份照常进行"
  else
    cp -a "$bak" "$f"; rm -f "$bak"; err "新授权连接失败, 已恢复原来的配置"; return 1
  fi
}

FB_REMOTE_PUBKEY_FIX='f=/etc/ssh/sshd_config; if grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/" $f; then mkdir -p /etc/ssh/sshd_config.d; echo "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/00-wsm-pubkey.conf; else cp -a $f $f.wsm-bak; sed -i "1i PubkeyAuthentication yes" $f; fi; if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload; echo WSM_FIX_OK; fi'

fb_ssh_keytest() {  # 主机 端口 用户 : 能否用备份密钥免密登录
  ssh -p "$2" -i "$FB_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
      -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$3@$1" true 2>/dev/null
}

fb_srv_add() {
  local name host port user dir m out
  fb_rclone_ensure || return 1
  read -r -p "给这台服务器起个名字 [srv1] (输入 0 返回): " name || return 1
  [[ $name == 0 ]] && return 1
  name=${name:-srv1}; fb_name_ok "$name" || return 1
  read -r -p "服务器 IP 或域名: " host || return 1
  [[ $host =~ ^[A-Za-z0-9.:-]+$ ]] || { err "地址格式不对"; return 1; }
  read -r -p "SSH 端口 [22]: " port || return 1; port=${port:-22}
  [[ $port =~ ^[0-9]+$ ]] || { err "端口不对"; return 1; }
  read -r -p "登录用户 [root]: " user || return 1; user=${user:-root}
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || { err "用户名不对"; return 1; }
  read -r -p "备份放在对方哪个目录 [/root/wsm-backup]: " dir || return 1
  dir=${dir:-/root/wsm-backup}
  [[ $dir =~ ^/[A-Za-z0-9._/-]+$ ]] || { err "目录格式不对"; return 1; }
  if [[ ! -f $FB_KEY ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "wsm-backup@$(fb_host)" -f "$FB_KEY" || { err "生成密钥失败"; return 1; }
  fi
  chmod 600 "$FB_KEY"
  echo "需要把本机的备份专用公钥装到对方服务器上:"
  choose m "安装方式:" "自动安装 (输入一次对方的登录密码)" "手动安装 (对方已关闭密码登录时用)" || return 1
  if [[ $m == 自动* ]]; then
    if command -v ssh-copy-id >/dev/null 2>&1; then
      ssh-copy-id -i "$FB_KEY.pub" -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" || { err "安装公钥失败"; return 1; }
    else
      ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" \
        'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "$FB_KEY.pub" || { err "安装公钥失败"; return 1; }
    fi
  else
    echo "在对方服务器上运行 wsm → 安全防护 → SSH 安全 → 粘贴已有公钥, 粘贴下面这一行:"
    echo
    cat "$FB_KEY.pub"
    echo
    read -r -p "装好后按回车继续..." _ || return 1
  fi
  info "检查密钥登录 ..."
  if ! fb_ssh_keytest "$host" "$port" "$user"; then
    warn "对方服务器不接受密钥登录 (多半是 SSH 设置里关闭了 PubkeyAuthentication)"
    if confirm "帮你在对方服务器开启密钥登录? (需要再输入一次对方密码)" y; then
      out=$(ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" "$FB_REMOTE_PUBKEY_FIX" 2>&1)
      [[ $out == *WSM_FIX_OK* ]] || { err "开启失败:"; printf '%s\n' "$out" | tail -3 >&2; return 1; }
      sleep 1
      fb_ssh_keytest "$host" "$port" "$user" || { err "已开启但还是登录不了, 请检查对方 SSH 设置 (AuthorizedKeysFile / PermitRootLogin)"; return 1; }
      info "对方服务器已开启密钥登录"
    else
      echo "  可以在对方服务器上手动执行:"
      echo '  echo "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/00-wsm-pubkey.conf && systemctl reload ssh'
      return 1
    fi
  fi
  printf 'type = sftp\nhost = %s\nuser = %s\nport = %s\nkey_file = %s\nshell_type = unix\nmd5sum_command = md5sum\nsha1sum_command = sha1sum\n' \
    "$host" "$user" "$port" "$FB_KEY" | fb_rclone_add "$name" || return 1
  fb_target_set "$name" "$dir"
}

fb_r2_add() {  # Cloudflare R2 (S3 兼容, 用密钥, 不会过期)
  local name ep ak sk bucket acc
  fb_rclone_ensure || return 1
  echo "  需要: R2 的 访问密钥 ID / 机密访问密钥 / 终结点地址 / 存储桶名"
  echo "  (Cloudflare → R2 → 管理 API 令牌 → 创建, 权限选「对象读和写」)"
  read -r -p "给它起个名字 [r2]: " name || return 1
  name=${name:-r2}; fb_name_ok "$name" || return 1
  read -r -p "终结点地址 (https://xxxx.r2.cloudflarestorage.com, 也可只填账号 ID): " ep || return 1
  ep=${ep//[[:space:]]/}; ep=${ep%/}
  if [[ $ep =~ ^[0-9a-f]{32}$ ]]; then ep="https://$ep.r2.cloudflarestorage.com"; fi
  [[ $ep =~ ^https://[0-9a-f]{32}(\.(eu|fedramp))?\.r2\.cloudflarestorage\.com(/.*)?$ ]] || { err "终结点地址格式不对"; return 1; }
  if [[ $ep =~ \.com/([A-Za-z0-9._-]+)$ ]]; then bucket=${BASH_REMATCH[1]}; ep=${ep%/*}; fi
  read -r -p "访问密钥 ID: " ak || return 1; ak=${ak//[[:space:]]/}
  [[ $ak =~ ^[A-Za-z0-9]{20,64}$ ]] || { err "访问密钥 ID 格式不对"; return 1; }
  read_secret sk "机密访问密钥 (输入不显示)" || return 1; sk=${sk//[[:space:]]/}
  [[ $sk =~ ^[A-Za-z0-9]{30,128}$ ]] || { err "机密访问密钥格式不对"; return 1; }
  read -r -p "存储桶名 [${bucket:-wsm-backup}]: " acc || return 1
  bucket=${acc:-${bucket:-wsm-backup}}
  [[ $bucket =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || { err "存储桶名格式不对 (小写字母数字和 -)"; return 1; }
  printf 'type = s3\nprovider = Cloudflare\naccess_key_id = %s\nsecret_access_key = %s\nendpoint = %s\nacl = private\nno_check_bucket = true\n' \
    "$ak" "$sk" "$ep" | fb_rclone_add "$name" || return 1
  fb_target_set "$name" "$bucket/$(fb_host)"
}

fb_b2_add() {  # Backblaze B2 (用应用密钥, 不会过期)
  local name kid key bucket
  fb_rclone_ensure || return 1
  echo "  需要: B2 的 keyID / applicationKey / 存储桶名 (Backblaze → Application Keys 创建)"
  read -r -p "给它起个名字 [b2]: " name || return 1
  name=${name:-b2}; fb_name_ok "$name" || return 1
  read -r -p "keyID: " kid || return 1; kid=${kid//[[:space:]]/}
  [[ $kid =~ ^[A-Za-z0-9]{12,40}$ ]] || { err "keyID 格式不对"; return 1; }
  read_secret key "applicationKey (输入不显示)" || return 1; key=${key//[[:space:]]/}
  [[ $key =~ ^[A-Za-z0-9/+]{20,64}$ ]] || { err "applicationKey 格式不对"; return 1; }
  read -r -p "存储桶名: " bucket || return 1
  [[ $bucket =~ ^[A-Za-z0-9-]{6,50}$ ]] || { err "存储桶名格式不对"; return 1; }
  printf 'type = b2\naccount = %s\nkey = %s\n' "$kid" "$key" | fb_rclone_add "$name" || return 1
  fb_target_set "$name" "$bucket/$(fb_host)"
}

fb_target_del() {
  fb_load
  local -a arr=()
  local c t
  read -r -a arr <<<"$FB_TARGETS"
  ((${#arr[@]})) || { warn "还没有异地目标"; return 0; }
  choose c "移除哪个?" "${arr[@]}" || return 0
  confirm "确认移除 $c ?" n || return 0
  local keep=""
  rclone config delete "${c%%:*}" >/dev/null 2>&1
  for t in "${arr[@]}"; do [[ $t == "$c" ]] || keep="${keep:+$keep }$t"; done
  FB_TARGETS=$keep; fb_save
  info "已移除 $c (网盘/服务器上已有的备份不会删除)"
}

fb_target_test() {
  fb_load
  [[ -n $FB_TARGETS ]] || { warn "还没有异地目标"; return 0; }
  fb_rclone_ensure || return 1
  local t f
  f=$(mktemp); echo "wsm test $(date)" > "$f"
  for t in $FB_TARGETS; do
    if rclone copyto "$f" "$t/.wsm-test" -q 2>/dev/null && rclone deletefile "$t/.wsm-test" -q 2>/dev/null; then
      echo "  ${G}✔${N} $t"
    else
      echo "  ${R}✘${N} $t  (连接或写入失败)"
    fi
  done
  rm -f "$f"
}

fb_targets_menu() {
  local c
  while true; do
    fb_load
    title "异地备份目标"
    if [[ -n $FB_TARGETS ]]; then for c in $FB_TARGETS; do echo "  - $c"; done
    else echo "  (还没有, 备份只保存在本机)"; fi
    choose c "操作:" "添加 Cloudflare R2 (推荐)" "添加 Backblaze B2" "添加其他服务器 (SFTP)" \
      "添加谷歌网盘" "测试全部目标" "谷歌网盘换成自己的授权" "移除目标" "返回" || return 0
    case $c in
      添加\ Cloudflare*) (fb_r2_add); pause ;;
      添加\ Backblaze*) (fb_b2_add); pause ;;
      添加谷歌*) (fb_gdrive_add); pause ;;
      添加其他*) (fb_srv_add); pause ;;
      测试*) fb_target_test; pause ;;
      谷歌网盘换*) (fb_gdrive_reauth); pause ;;
      移除*) fb_target_del; pause ;;
      *) return 0 ;;
    esac
  done
}

# ---------------- 设置
fb_schedule() {
  local c h m dow expr line
  line=$(grep -v '^#' "$FB_CRON" 2>/dev/null | grep backup-all | head -1)
  echo "  当前: ${line:+$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')}${line:-未设置}"
  echo "  服务器时间: $(tz_now) (按这个时间执行; 不对的话到 系统与服务 → 8 改时区)"
  choose c "定时全量备份:" "每天" "每周" "关闭定时备份" || return 0
  if [[ $c == 关闭* ]]; then rm -f "$FB_CRON"; info "已关闭定时备份"; return 0; fi
  [[ -x $WSM_BIN ]] || self_install
  read -r -p "几点执行 (0-23) [4]: " h || return 1; h=${h:-4}
  read -r -p "第几分钟 (0-59) [10]: " m || return 1; m=${m:-10}
  [[ $h =~ ^[0-9]+$ && $h -le 23 && $m =~ ^[0-9]+$ && $m -le 59 ]] || { err "时间不对"; return 1; }
  expr="$m $h * * *"
  if [[ $c == 每周 ]]; then
    read -r -p "星期几 (1=周一 ... 7=周日) [1]: " dow || return 1; dow=${dow:-1}
    [[ $dow =~ ^[1-7]$ ]] || { err "请输入 1-7"; return 1; }
    expr="$m $h * * $((dow % 7))"
  fi
  printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s root %s backup-all auto >> %s 2>&1\n' \
    "$expr" "$WSM_BIN" "$FB_LOG" > "$FB_CRON"
  chmod 644 "$FB_CRON"
  info "已设置: $c $(printf '%02d:%02d' "$h" "$m") 自动全量备份${FB_TARGETS:+, 并上传异地}"
}

fb_extra_menu() {
  local c p
  local -a cand=() cur=()
  while true; do
    mapfile -t cur < <(grep -v '^[[:space:]]*$' "$FB_EXTRA" 2>/dev/null)
    title "额外备份的目录/文件"
    echo "  (网站、数据库、证书、wsm 配置、扩展程序和 Python 机器人都会自动备份,"
    echo "   这里只需要加其他的, 比如 Node 写的程序目录、它的 .service 文件)"
    if ((${#cur[@]})); then for p in "${cur[@]}"; do echo "  - $p$([[ -e $p ]] || echo "  ${R}(不存在)${N}")"; done
    else echo "  (无)"; fi
    choose c "操作:" "自动发现" "手动添加" "删除" "返回" || return 0
    case $c in
      自动*)
        mapfile -t cand < <(fb_extra_detect | grep -vxF -f <(printf '%s\n' "${cur[@]:-}"))
        ((${#cand[@]})) || { info "没有发现新的"; continue; }
        echo "发现这些可能需要备份的:"; printf '   %s\n' "${cand[@]}"
        if confirm "全部加入?" y; then
          mkdir -p "$WSM_DIR"; printf '%s\n' "${cand[@]}" >> "$FB_EXTRA"; info "已加入"
        fi ;;
      手动*)
        read -r -p "完整路径 (如 /root/mybot, 输入 0 返回): " p || continue
        [[ $p == 0 || -z $p ]] && continue
        [[ $p == /* && $p != / && -e $p ]] || { warn "路径不存在或不是完整路径"; continue; }
        [[ " ${cur[*]:-} " == *" $p "* ]] && { warn "已经有了"; continue; }
        mkdir -p "$WSM_DIR"; echo "$p" >> "$FB_EXTRA"; info "已加入" ;;
      删除)
        ((${#cur[@]})) || continue
        choose p "删除哪个?" "${cur[@]}" || continue
        grep -vxF -- "$p" "$FB_EXTRA" > "$FB_EXTRA.tmp"; mv -f "$FB_EXTRA.tmp" "$FB_EXTRA"; info "已删除" ;;
      *) return 0 ;;
    esac
  done
}

fb_settings() {
  local c v p1 p2
  while true; do
    fb_load
    title "全量备份设置"
    echo "  本机保留: $FB_KEEP_LOCAL 份   异地保留: $FB_KEEP_REMOTE 份"
    echo "  加密:     $([[ -n $FB_PASS ]] && echo "${G}已开启${N}" || echo 未开启)"
    choose c "操作:" "本机保留份数" "异地保留份数" "设置/修改加密密码" "关闭加密" "返回" || return 0
    case $c in
      本机*) read -r -p "本机保留几份 [3]: " v || continue; v=${v:-3}
             [[ $v =~ ^[0-9]+$ && $v -ge 1 ]] && { FB_KEEP_LOCAL=$v; fb_save; info "已保存"; } || warn "请输入数字" ;;
      异地*) read -r -p "异地保留几份 [7]: " v || continue; v=${v:-7}
             [[ $v =~ ^[0-9]+$ && $v -ge 1 ]] && { FB_KEEP_REMOTE=$v; fb_save; info "已保存"; } || warn "请输入数字" ;;
      设置*)
        echo "备份里有数据库密码、证书私钥等, 放到网盘建议加密。"
        warn "密码一定要记住! 忘了密码, 备份就无法还原"
        read_secret p1 "加密密码 (至少 8 位)" || continue; [[ ${#p1} -ge 8 ]] || { warn "至少 8 位"; continue; }
        read_secret p2 "再输入一次" || continue; [[ $p1 == "$p2" ]] || { warn "两次不一样"; continue; }
        FB_PASS=$p1; fb_save; info "已开启加密 (之后的备份生效)" ;;
      关闭*) FB_PASS=""; fb_save; info "已关闭加密" ;;
      *) return 0 ;;
    esac
  done
}

# ---------------- 还原 / 搬家
fb_pick_remote_file() {  # -> PICKED_FILE (从异地目标下载)
  PICKED_FILE=""
  fb_load
  local t c f
  local -a arr=() files=()
  fb_rclone_ensure || return 1
  if [[ -z $FB_TARGETS ]]; then
    warn "本机还没有异地目标, 先添加 (用和旧服务器相同的网盘/服务器)"
    fb_targets_menu; fb_load
    [[ -n $FB_TARGETS ]] || return 1
  fi
  read -r -a arr <<<"$FB_TARGETS"
  if ((${#arr[@]} == 1)); then t=${arr[0]}; else choose t "从哪里下载?" "${arr[@]}" || return 1; fi
  # 网盘里按服务器名分文件夹 (存储桶/服务器名); 新服务器名字不一样时, 让你选旧服务器的文件夹
  local parent d n
  local -a dirs=()
  if [[ ${t#*:} == */* ]]; then
    parent=${t%/*}
    info "查找 $parent 下的备份 ..."
    while IFS= read -r d; do
      d=${d%/}; [[ -n $d ]] || continue
      n=$(rclone lsf "$parent/$d" --files-only 2>/dev/null | grep -c '^wsm-full-')
      ((n > 0)) && dirs+=("$d ($n 份)")
    done < <(rclone lsf "$parent" --dirs-only 2>/dev/null)
    if ((${#dirs[@]} > 1)) || { ((${#dirs[@]} == 1)) && [[ ${dirs[0]%% *} != "${t##*/}" ]]; }; then
      choose d "选择要还原的服务器 (文件夹名 = 备份时的服务器名):" "${dirs[@]}" || return 1
      t="$parent/${d%% *}"
    fi
  fi
  mapfile -t files < <(rclone lsf "$t" --files-only 2>/dev/null | grep '^wsm-full-' | sort -r | head -15)
  ((${#files[@]})) || { err "$t 里没有找到备份"; return 1; }
  choose f "选择备份 (新→旧):" "${files[@]}" || return 1
  mkdir -p "$FB_DIR"
  info "下载 $f ..."
  rclone copy "$t/$f" "$FB_DIR" -P || { err "下载失败"; return 1; }
  PICKED_FILE=$FB_DIR/$f
}

fb_pick_scp_file() {  # -> PICKED_FILE (从旧服务器直接拉取)
  PICKED_FILE=""
  local host port user f
  local -a files=()
  read -r -p "旧服务器 IP: " host || return 1
  [[ $host =~ ^[A-Za-z0-9.:-]+$ ]] || { err "地址格式不对"; return 1; }
  read -r -p "SSH 端口 [22]: " port || return 1; port=${port:-22}
  read -r -p "用户 [root]: " user || return 1; user=${user:-root}
  echo "(接下来可能要输入两次旧服务器的密码)"
  mapfile -t files < <(ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" \
    "ls -1t $FB_DIR/wsm-full-*.tar* 2>/dev/null | head -10")
  ((${#files[@]})) || { err "旧服务器 $FB_DIR 里没有全量备份, 先在旧服务器上做一次全量备份"; return 1; }
  choose f "选择备份 (新→旧):" "${files[@]}" || return 1
  [[ $f =~ ^[A-Za-z0-9._/-]+$ ]] || { err "文件名异常"; return 1; }
  mkdir -p "$FB_DIR"
  scp -P "$port" -o StrictHostKeyChecking=accept-new "$user@$host:$f" "$FB_DIR/" || { err "下载失败"; return 1; }
  PICKED_FILE=$FB_DIR/${f##*/}
}

fb_restore() {
  local file=${1:-} src tarf stage pass u v d okdb=0 bad=0 what b
  local do_site=1 do_bots=1
  local -a bots=() pick=()
  title "从全量备份还原 / 搬家"
  if [[ -z $file ]]; then
    choose src "备份文件从哪里来:" "本机已有的全量备份" "从旧服务器直接拉取" "从异地备份下载 (网盘/R2/服务器)" "手动输入文件路径" || return 1
    case $src in
      本机*) pick_file "$FB_DIR" "wsm-full-*.tar*" || return 1; file=$PICKED_FILE ;;
      从旧*) fb_pick_scp_file || return 1; file=$PICKED_FILE ;;
      从异地*) fb_pick_remote_file || return 1; file=$PICKED_FILE ;;
      *) read -r -p "备份文件完整路径: " file || return 1 ;;
    esac
  fi
  [[ -f $file ]] || { err "文件不存在: $file"; return 1; }
  mkdir -p "$FB_DIR"
  stage=$(mktemp -d "$FB_DIR/.restore-XXXXXX")
  tarf=$file
  if [[ $file == *.enc ]]; then
    fb_load; pass=$FB_PASS
    [[ -n $pass ]] || read_secret pass "备份加密密码" || { rm -rf "$stage"; return 1; }
    tarf=$stage/bundle.tar
    if ! WSM_FBPASS=$pass openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:WSM_FBPASS -in "$file" -out "$tarf" 2>/dev/null; then
      if [[ -n $FB_PASS ]]; then
        read_secret pass "本机保存的密码不对, 请输入备份时的加密密码" || { rm -rf "$stage"; return 1; }
        WSM_FBPASS=$pass openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:WSM_FBPASS -in "$file" -out "$tarf" 2>/dev/null \
          || { rm -rf "$stage"; err "密码不对, 无法解密"; return 1; }
      else
        rm -rf "$stage"; err "密码不对, 无法解密"; return 1
      fi
    fi
  fi
  mkdir -p "$stage/b"
  tar -xf "$tarf" -C "$stage/b" 2>/dev/null || { rm -rf "$stage"; err "备份文件损坏或格式不对"; return 1; }
  [[ -f $stage/b/manifest.env ]] || { rm -rf "$stage"; err "这不是 wsm 全量备份"; return 1; }
  # shellcheck disable=SC2034  # 这些变量由 manifest.env 赋值
  local FB_FORMAT="" FB_WSM="" FB_DATE="" FB_HOST="" FB_PHP="" FB_REDIS=0 FB_SITES="" FB_DBS="" FB_EXTRAS="" FB_BOTS="" FB_SOFT="" FB_NODE="" FB_CFW=0 FB_SSH_PORT="" FB_SSH_NOPASS=0 FB_CMDS=""
  # shellcheck disable=SC1091
  source "$stage/b/manifest.env"
  if [[ ${FB_FORMAT:-1} == 1 ]]; then
    [[ -f $stage/b/files.tar.gz ]] || { rm -rf "$stage"; err "这不是 wsm 全量备份"; return 1; }
  fi
  for b in "$stage"/b/bots/*/info.env; do [[ -f $b ]] && { b=${b%/info.env}; bots+=("${b##*/}"); }; done
  echo
  echo "  备份时间: $FB_DATE   来自: $FB_HOST (wsm v$FB_WSM)"
  echo "  网站:     ${FB_SITES:-无}"
  echo "  数据库:   ${FB_DBS:-无}"
  echo "  PHP:      ${FB_PHP:-无}$([[ -f $stage/b/php-ext.txt ]] && echo "  (扩展 $(awk '{print $2}' "$stage/b/php-ext.txt" | sort -u | grep -c .) 个, 缺的自动补装)")"
  [[ -n $FB_SOFT ]] && echo "  软件:     $FB_SOFT  (本机没有的自动安装)"
  [[ -n $FB_CMDS ]] && echo "  命令:     $FB_CMDS"
  echo "  机器人:   ${bots[*]:-无}"
  [[ -n ${FB_EXTRAS// /} ]] && echo "  额外内容: $FB_EXTRAS"
  echo
  if ((${#bots[@]})); then
    choose what "还原哪些:" "全部" "只还原 网站 + 数据库 + 系统配置" "只还原 机器人" || { rm -rf "$stage"; return 0; }
    case $what in 只还原\ 网站*) do_bots=0 ;; 只还原\ 机器人) do_site=0 ;; esac
  else
    do_bots=0
  fi
  if ((do_bots)); then
    if ((${#bots[@]} == 1)); then pick=("${bots[@]}")
    else
      choose b "还原哪个机器人:" "全部机器人 (${bots[*]})" "${bots[@]}" || { rm -rf "$stage"; return 0; }
      if [[ $b == 全部机器人* ]]; then pick=("${bots[@]}"); else pick=("$b"); fi
    fi
  fi
  ((do_site)) && warn "会覆盖本机同名的网站、数据库和配置"
  ((do_bots)) && warn "会覆盖本机同名机器人的程序文件: ${pick[*]}"
  confirm "确认还原?" n || { rm -rf "$stage"; return 0; }

  if ((do_site)); then
    info "检查并安装运行环境 ..."
    command -v nginx >/dev/null 2>&1 || install_base
    for v in $FB_PHP; do php_installed | grep -qx "$v" || install_php "$v"; done
    fb_php_exts_restore "$stage/b/php-ext.txt"
    if [[ -n $FB_DBS ]] && ! command -v mysql >/dev/null 2>&1; then install_db; fi
    if [[ $FB_REDIS == 1 ]] && ! unit_exists redis-server && ! unit_exists redis; then install_redis; fi
    fb_soft_restore "$FB_SOFT" "$FB_NODE"

    for u in $(apps_units); do systemctl stop "$u" >/dev/null 2>&1; done
    info "还原网站和配置文件 ..."
    if [[ ${FB_FORMAT:-1} == 1 ]]; then
      tar -xzpf "$stage/b/files.tar.gz" -C / || { rm -rf "$stage"; err "解压文件失败"; return 1; }
    else
      for b in system sites extra; do
        [[ -f $stage/b/$b.tar.gz ]] || continue
        tar -xzpf "$stage/b/$b.tar.gz" -C / || { rm -rf "$stage"; err "解压 $b 失败"; return 1; }
      done
    fi
    rm -rf "$WSM_DIR/sftp" 2>/dev/null

    if [[ -n $FB_DBS ]]; then
      info "还原数据库 ..."
      for d in $FB_DBS; do
        if gunzip -c "$stage/b/db/$d.sql.gz" | mysql; then okdb=$((okdb + 1)); else warn "数据库 $d 还原失败"; bad=$((bad + 1)); fi
      done
      [[ -s $stage/b/db/users.sql ]] && { mysql < "$stage/b/db/users.sql" || warn "部分数据库账号还原失败"; }
      mysql -e "FLUSH PRIVILEGES" 2>/dev/null
    fi

    if [[ -s $stage/b/authorized_keys ]]; then
      ssh_ak_prepare
      while IFS= read -r u; do
        [[ $u =~ ^[[:space:]]*(#|$) ]] && continue
        grep -qxF -- "$u" "$SSH_AK" || printf '%s\n' "$u" >> "$SSH_AK"
      done < "$stage/b/authorized_keys"
    fi
    if [[ -s $stage/b/root.crontab ]]; then  # root 的定时任务: 只追加本机没有的
      local cur add
      cur=$(crontab -l -u root 2>/dev/null)
      add=$(grep -vxF -f <(printf '%s\n' "$cur"; echo '#__none__') "$stage/b/root.crontab")
      if [[ -n $add ]]; then
        { [[ -n $cur ]] && printf '%s\n' "$cur"; printf '%s\n' "$add"; } | crontab -u root - \
          && info "已追加 $(printf '%s\n' "$add" | grep -c .) 条 root 定时任务"
      fi
    fi

    systemctl daemon-reload
    apps_load; apps_migrate_once   # 模块随 /etc/wsm 一起还原; 老版本的备份没有模块, 自动从仓库找回
    apps_hook restore              # 模块自己还需要补的环境 (可选钩子)
    for u in $(apps_units); do unit_exists "$u" && systemctl enable --now "$u" >/dev/null 2>&1; done
    for u in $FB_EXTRAS; do
      [[ $u == /etc/systemd/system/*.service && -f $u ]] && systemctl enable --now "${u##*/}" >/dev/null 2>&1
    done

    info "重新生成站点配置 ..."
    for d in $(list_site_names); do ( render_site "$d" ) >/dev/null 2>&1 || { warn "站点 $d 配置生成失败, 请到站点设置里检查"; bad=$((bad + 1)); }; done
    for v in $(php_installed); do systemctl restart "$(php_svc "$v")" >/dev/null 2>&1; done
    nginx_reload >/dev/null 2>&1
    ensure_renew_cron
    self_install >/dev/null 2>&1
    realip_ensure
  fi

  if ((do_bots)); then
    for b in "${pick[@]}"; do fb_bot_restore "$stage/b/bots/$b" || bad=$((bad + 1)); done
  fi
  fb_cmd_restore "$stage/b"
  if ((do_site)) && [[ $FB_CFW == 1 ]] && ! cfw_active; then
    echo
    info "旧服务器开着源站保护 (只让 CDN 访问 80/443), 现在为本机开启:"
    cfw_enable
  fi
  ((do_site)) && [[ -n $FB_SSH_PORT ]] && fb_ssh_restore "$FB_SSH_PORT" "$FB_SSH_NOPASS"
  rm -rf "$stage"

  echo
  if ((bad)); then warn "还原完成, 但有 $bad 处出错, 请看上面的提示"; else info "还原完成!"; fi
  if ((do_site)); then
    echo "  网站 $(list_site_names | grep -c .) 个, 数据库 $okdb 个"
    echo "  接下来:"
    echo "   - 把域名解析改到本机 IP: $(public_ip_cached)"
    echo "   - 定时备份、Telegram 告警、异地目标已跟着还原, 本机会照常执行"
    [[ $FB_CFW == 1 ]] && ! cfw_active && echo "   - 源站保护没有开启, 需要时到 安全防护 → 1 开启"
    echo "   - 旧服务器不用了的话, 记得关掉它的定时备份, 免得两台一起往网盘传"
  fi
  if ((do_bots)); then
    echo "   - 机器人: 确认旧服务器上的 ${pick[*]} 已停止 (systemctl disable --now 服务名)"
  elif ((${#bots[@]})); then
    echo "   - 备份里还有机器人 (${bots[*]}) 没有还原, 需要时再选 [只还原 机器人]"
  elif [[ ${FB_FORMAT:-1} == 1 && -n $FB_EXTRAS ]]; then
    echo "   - 检查机器人等额外程序是否正常运行 (Python 版本不同时可能要重装依赖)"
  fi
  return 0
}

fb_menu() {
  local c last
  while true; do
    fb_load
    last=$(ls -1t "$FB_DIR"/wsm-full-*.tar* 2>/dev/null | head -1)
    title "全量备份 / 搬家"
    if [[ -n $last ]]; then echo "  最近备份: $(basename "$last") ($(du -h "$last" | cut -f1))"; else echo "  最近备份: 无"; fi
    echo "  定时备份: $(grep -q backup-all "$FB_CRON" 2>/dev/null && echo "${G}已开启${N}" || echo 未开启)"
    echo "  异地目标: ${FB_TARGETS:-无 (只存本机)}"
    echo "  加密:     $([[ -n $FB_PASS ]] && echo 已开启 || echo 未开启)"
    echo "  机器人:   $(fb_bots_desc)  ${D}(自动识别, 单独备份)${N}"
    choose c "操作:" "立即全量备份" "定时自动备份" "异地备份" \
      "额外备份的目录" "保留份数 / 加密" "还原 / 搬家到本机" "返回" || return 0
    case $c in
      立即*) (fb_run); pause ;;
      定时*) (fb_schedule); pause ;;
      异地*) fb_targets_menu ;;
      额外*) fb_extra_menu ;;
      保留*) fb_settings ;;
      还原*) (fb_restore); pause ;;
      *) return 0 ;;
    esac
  done
}

# ================================================================ 安全防护
# 源站保护: 用 iptables 让 80/443 只接受 CDN (Cloudflare + 自定义 CDN) 的连接 (SSH 等其他端口不受影响)
#   默认关闭, 手动开启; 开启后规则放在独立链 WSM_CF 里, 开机由 systemd 服务自动加载, 每周自动更新 IP 段
CFW_IPS=$WSM_DIR/cf-ips.txt
CFW_UNIT=/etc/systemd/system/wsm-cf-firewall.service
CFW_CRON=/etc/cron.d/wsm-cf-ips
CFW_CHAIN=WSM_CF

cfw_active() { command -v iptables >/dev/null 2>&1 && iptables -w -S "$CFW_CHAIN" >/dev/null 2>&1; }

cfw_state() {
  if cfw_active; then echo "${G}已开启${N} (开机自动生效 · $(grep -c . "$CDN_ALLOW" 2>/dev/null || echo 0) 个IP段)"
  elif [[ -f $CFW_UNIT ]]; then echo "${R}已设置但规则未生效${N}"
  else echo "已关闭"; fi
}

cfw_ensure_iptables() {
  command -v iptables >/dev/null 2>&1 && return 0
  info "安装 iptables ..."
  pkg_install iptables >/dev/null 2>&1
  command -v iptables >/dev/null 2>&1 || { err "iptables 安装失败"; return 1; }
}

cfw_fetch() {  # 在线获取 Cloudflare IP 段; 失败时保留旧列表, 没有旧列表才用内置列表
  local tmp v4 v6
  tmp=$(mktemp)
  v4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4/ 2>/dev/null | grep -E '^[0-9.]+/[0-9]+$')
  v6=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6/ 2>/dev/null | grep -E '^[0-9a-fA-F:]+/[0-9]+$')
  if (( $(printf '%s\n' "$v4" | grep -c .) >= 5 )); then
    printf '%s\n%s\n' "$v4" "$v6" | grep -v '^$' | sort -u > "$tmp"
  elif [[ -s $CFW_IPS ]]; then
    rm -f "$tmp"; warn "在线获取失败, 继续使用已保存的 IP 列表"; return 0
  else
    warn "在线获取失败, 使用内置的 Cloudflare IP 列表"
    guard_cf_ranges | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sort -u > "$tmp"
  fi
  mkdir -p "$WSM_DIR"; mv -f "$tmp" "$CFW_IPS"; chmod 644 "$CFW_IPS"
}

cfw_remove_rules() {
  local t
  for t in iptables ip6tables; do
    command -v "$t" >/dev/null 2>&1 || continue
    while "$t" -w -D INPUT -p tcp -m multiport --dports 80,443 -j "$CFW_CHAIN" 2>/dev/null; do :; done
    "$t" -w -F "$CFW_CHAIN" 2>/dev/null
    "$t" -w -X "$CFW_CHAIN" 2>/dev/null
  done
  return 0
}

cfw_apply_rules() {
  mkdir -p "$WSM_DIR"; cdn_all_ips > "$CDN_ALLOW"
  [[ -s $CDN_ALLOW ]] || { err "没有 CDN IP 列表"; return 1; }
  cfw_ensure_iptables || return 1
  cfw_remove_rules
  local t r v6 ok=0
  for t in iptables ip6tables; do
    command -v "$t" >/dev/null 2>&1 || continue
    [[ $t == ip6tables ]] && v6=1 || v6=0
    if ! "$t" -w -N "$CFW_CHAIN" 2>/dev/null; then
      ((v6)) && continue
      err "创建防火墙规则失败"; return 1
    fi
    if ((v6)); then "$t" -w -A "$CFW_CHAIN" -s ::1/128 -j ACCEPT
    else "$t" -w -A "$CFW_CHAIN" -s 127.0.0.0/8 -j ACCEPT; fi
    while read -r r; do
      [[ -n $r ]] || continue
      if [[ $r == *:* ]]; then ((v6)) || continue; else ((v6)) && continue; fi
      "$t" -w -A "$CFW_CHAIN" -s "$r" -j ACCEPT
    done < "$CDN_ALLOW"
    "$t" -w -A "$CFW_CHAIN" -j DROP
    "$t" -w -I INPUT 1 -p tcp -m multiport --dports 80,443 -j "$CFW_CHAIN" \
      || { ((v6)) && { "$t" -w -F "$CFW_CHAIN"; "$t" -w -X "$CFW_CHAIN"; continue; }; cfw_remove_rules; err "加载规则失败"; return 1; }
    ((v6)) || ok=1
  done
  ((ok)) || { cfw_remove_rules; err "IPv4 规则没有生效"; return 1; }
}

cfw_check_sites() {  # 检查每个站点是否经过 CDN -> CFW_BAD = 没经过的数量
  local d names n ip me
  CFW_BAD=0
  me=$(public_ip_cached)
  echo "检查站点是否经过 CDN:"
  while read -r d; do
    [[ -n $d ]] || continue
    names=$(load_meta "$d" 2>/dev/null; [[ $DISABLED == 1 ]] || echo "$DOMAIN $ALIASES")
    for n in $names; do
      if curl -sI --max-time 8 "http://$n/" 2>/dev/null | tr -d '\r' | grep -qi '^server: *cloudflare'; then
        echo "  ${G}✔${N} $n  (Cloudflare)"
        continue
      fi
      ip=$(getent ahostsv4 "$n" 2>/dev/null | awk '{print $1; exit}')
      if [[ -n $(cdn_ids) && -n $ip && $ip != "$me" ]]; then
        echo "  ${G}✔${N} $n  (解析到 $ip, 不是本机, 应该经过了其他 CDN)"
      else
        echo "  ${R}✘${N} $n  (没经过 CDN, 开启后打不开)"
        CFW_BAD=$((CFW_BAD + 1))
      fi
    done
  done < <(list_site_names)
}

cfw_check_ports() {  # 列出 80/443 上除 Nginx 以外的程序
  local o
  o=$(ss -ltnpH 2>/dev/null | awk '$4 ~ /:(80|443)$/' | grep -v '"nginx"' || true)
  [[ -n $o ]] || return 0
  warn "80/443 上还有其他程序, 开启后它们也只有 CDN 能连:"
  printf '%s\n' "$o" | awk '{print "  " $4 "  " $6}'
}

cfw_install_unit() {
  [[ -x $WSM_BIN ]] || self_install
  [[ -x $WSM_BIN ]] || { err "找不到 $WSM_BIN, 无法设置开机自动加载"; return 1; }
  cat > "$CFW_UNIT" <<EOF
[Unit]
Description=wsm: 80/443 only accept CDN
After=network-online.target ufw.service firewalld.service netfilter-persistent.service nftables.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$WSM_BIN cf-firewall apply
ExecStop=$WSM_BIN cf-firewall remove

[Install]
WantedBy=multi-user.target
EOF
  realip_ensure
  systemctl daemon-reload
  systemctl enable wsm-cf-firewall >/dev/null 2>&1
  systemctl start wsm-cf-firewall >/dev/null 2>&1 || true
}

cfw_enable() {
  local x
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    warn "检测到 firewalld 正在运行, 它重载时可能清掉本规则"
    confirm "仍然继续?" n || return 0
  fi
  echo "开启后: 只有 CDN ($(cdn_names)) 能连本机 80/443 端口,"
  echo "  直接用 IP 访问、或没走 CDN (Cloudflare 灰云) 的域名, 都会打不开。"
  echo "  SSH 和其他端口不受影响; 开启后重启服务器也一直有效, 直到你手动关闭。"
  echo "  面板类程序的节点/订阅域名也要走 CDN, 或者改用其他端口对接。"
  echo "  用的不是 Cloudflare? 先到 [安全防护 → CDN 设置] 添加你的 CDN。"
  echo
  cfw_check_sites
  cfw_check_ports
  echo
  if ((CFW_BAD)); then
    warn "有 $CFW_BAD 个域名没经过 CDN, 开启后它们会打不开"
    confirm "仍然开启?" n || return 0
  else
    confirm "确认开启源站保护?" y || return 0
  fi
  cfw_ensure_iptables || return 1
  info "获取 CDN IP 段 ..."
  cfw_fetch || return 1
  for x in $(cdn_ids); do cdn_fetch_one "$x"; done
  cfw_apply_rules || return 1
  cfw_install_unit || { cfw_remove_rules; return 1; }
  realip_write || true
  info "源站保护已开启 ($(grep -c . "$CDN_ALLOW") 个 IP 段, 开机自动生效, 每周一自动更新)"
  echo "  网站打不开时, SSH 执行: wsm cf-firewall off"
}

cfw_disable() {
  systemctl disable --now wsm-cf-firewall >/dev/null 2>&1 || true
  cfw_remove_rules
  rm -f "$CFW_UNIT"
  systemctl daemon-reload
  info "源站保护已关闭, 80/443 对所有 IP 开放 (重启后也保持关闭)"
}

cfw_toggle() { if cfw_active || [[ -f $CFW_UNIT ]]; then confirm "关闭源站保护?" n && cfw_disable; else cfw_enable; fi; }

cfw_refresh() { cf_refresh_all; }

cfw_cli() {
  case ${1:-status} in
    on) cfw_enable ;;
    off) cfw_disable ;;
    apply) cfw_apply_rules ;;
    remove) cfw_remove_rules ;;
    refresh) cf_refresh_all ;;
    *) echo "源站保护: $(cfw_state)" ;;
  esac
}

# ---------------- CDN 真实 IP (所有站点生效, 默认开启, 可关闭)
# 只信任来自 CDN 回源 IP 段的请求头, 别人伪造不了; 不走 CDN 的访问不受影响
#   只有 Cloudflare 时用 CF-Connecting-IP; 加了其他 CDN 后自动改用 X-Forwarded-For (Cloudflare 也会发), 两边都能识别
REALIP_CONF=$NGX_CONF/00-wsm-realip.conf
REALIP_OFF=$WSM_DIR/realip.off          # 有这个文件 = 用户关闭了真实 IP
CDN_DIR=$WSM_DIR/cdn                    # 自定义 CDN: <id>.conf (NAME URL) + <id>.ips
CDN_HEADER_CONF=$CDN_DIR/header         # 手动指定的真实 IP 请求头 (没有 = 自动)
CDN_ALLOW=$WSM_DIR/cdn-allow.txt        # 源站保护放行的全部 IP 段 (Cloudflare + 自定义)

cdn_ids() { local f; for f in "$CDN_DIR"/*.conf; do [[ -f $f ]] && { f=${f##*/}; echo "${f%.conf}"; }; done; return 0; }
# shellcheck disable=SC1090
cdn_name() { ( NAME=""; source "$CDN_DIR/$1.conf" 2>/dev/null; echo "${NAME:-$1}" ); }
# shellcheck disable=SC1090
cdn_url() { ( URL=""; source "$CDN_DIR/$1.conf" 2>/dev/null; echo "${URL:-}" ); }
cdn_count() { grep -c . "$CDN_DIR/$1.ips" 2>/dev/null || echo 0; }
cdn_names() { local i n="Cloudflare"; for i in $(cdn_ids); do n+=" + $(cdn_name "$i")"; done; echo "$n"; }

cdn_cf_ips() { if [[ -s $CFW_IPS ]]; then cat "$CFW_IPS"; else guard_cf_ranges; fi; }
cdn_all_ips() {  # Cloudflare + 自定义 CDN 的全部 IP 段 (去重)
  { cdn_cf_ips; local i; for i in $(cdn_ids); do cat "$CDN_DIR/$i.ips" 2>/dev/null; done; } \
    | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sort -u
}

cdn_header() {
  local h=""
  [[ -s $CDN_HEADER_CONF ]] && h=$(head -1 "$CDN_HEADER_CONF")
  if [[ $h =~ ^[A-Za-z0-9-]{2,40}$ ]]; then echo "$h"
  elif [[ -n $(cdn_ids) ]]; then echo "X-Forwarded-For"
  else echo "CF-Connecting-IP"; fi
}

cdn_parse_ips() {  # 从任意文本 (纯列表 / JSON) 里提取 IP 段, 逐个校验; 单个 IP 补成 /32 或 /128
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, re, ipaddress
out = set()
for m in re.findall(r"[0-9A-Fa-f:.]+(?:/[0-9]{1,3})?", sys.stdin.read()):
    if m.count(":") < 2 and m.count(".") != 3:
        continue
    try:
        out.add(str(ipaddress.ip_network(m, strict=False)))
    except ValueError:
        pass
print("\n".join(sorted(out)))
' | grep .
  else  # 没有 python3 时只认 IPv4
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' \
      | awk -F'[./]' '$1<256 && $2<256 && $3<256 && $4<256 && (NF<5 || $5<=32) { print ($0 ~ /\//) ? $0 : $0 "/32" }' | sort -u
  fi
}

realip_on() { [[ ! -f $REALIP_OFF ]]; }

realip_state() {
  if ! realip_on; then echo "${Y}已关闭${N}"
  elif [[ -f $REALIP_CONF ]]; then echo "${G}已开启${N} ($(cdn_names))"
  else echo "未生效 (还没装 Nginx, 或已有其他 real_ip 设置)"; fi
}

realip_write() {  # 生成/更新真实 IP 配置, nginx 检测不通过就恢复; 关闭状态下删除配置
  command -v nginx >/dev/null 2>&1 || return 0
  local r old="" gold="" h
  if ! realip_on; then
    [[ -f $REALIP_CONF ]] || return 0
    old=$(mktemp); mv -f "$REALIP_CONF" "$old"
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1; rm -f "$old"; return 0; fi
    mv -f "$old" "$REALIP_CONF"; warn "关闭真实 IP 后 Nginx 检测不通过, 已恢复"; return 1
  fi
  [[ -f $REALIP_CONF ]] && { old=$(mktemp); cp -f "$REALIP_CONF" "$old"; }
  # 旧版防 CC 规则里也写过真实 IP, 先去掉, 否则重复报错
  if [[ -f $GUARD_CONF ]] && grep -q real_ip_header "$GUARD_CONF"; then
    gold=$(mktemp); cp -f "$GUARD_CONF" "$gold"
    guard_write_global; mv -f "$GUARD_CONF.tmp" "$GUARD_CONF"
  fi
  h=$(cdn_header)
  {
    echo "# managed by wsm - 网站走 CDN ($(cdn_names)) 时, 日志/统计/限速/IP规则 都用访客真实 IP"
    while read -r r; do echo "set_real_ip_from $r;"; done < <(cdn_all_ips)
    echo "real_ip_header $h;"
    [[ $h == X-Forwarded-For ]] && echo "real_ip_recursive on;"
  } > "$REALIP_CONF"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1
    rm -f "$old" "$gold"; return 0
  fi
  if [[ -n $old ]]; then mv -f "$old" "$REALIP_CONF"; else rm -f "$REALIP_CONF"; fi
  [[ -n $gold ]] && mv -f "$gold" "$GUARD_CONF"
  warn "CDN 真实 IP 配置没生效 (可能已有其他 real_ip 设置)"
  return 1
}

realip_set() {
  if [[ $1 == off ]]; then
    local n=0 d
    while read -r d; do [[ -n $d ]] && [[ $( load_meta "$d" 2>/dev/null; echo "${GUARD:-0}" ) == 1 ]] && n=$((n + 1)); done < <(list_site_names)
    warn "关闭后, 走 CDN 的网站在日志里只能看到 CDN 节点的 IP"
    ((n)) && warn "有 $n 个站点开着防 CC: 会按 CDN 节点 IP 限速, 可能误封大量正常访客"
    confirm "确认关闭 CDN 真实 IP?" n || return 0
    mkdir -p "$WSM_DIR"; touch "$REALIP_OFF"
    realip_write && info "已关闭 CDN 真实 IP (重启后也保持关闭)"
  else
    rm -f "$REALIP_OFF"
    realip_write && info "已开启 CDN 真实 IP ($(cdn_names))"
  fi
}

cdn_apply() {  # CDN 列表变了: 更新真实 IP 配置和源站保护规则
  realip_write >/dev/null 2>&1 || true
  if cfw_active || [[ -f $CFW_UNIT ]]; then cfw_apply_rules || return 1; fi
  return 0
}

cdn_fetch_one() {  # id : 从网址更新某个自定义 CDN 的 IP 段 (失败保留旧的)
  local u tmp
  u=$(cdn_url "$1"); [[ -n $u ]] || return 0
  tmp=$(mktemp)
  if curl -fsSL --max-time 20 "$u" 2>/dev/null | cdn_parse_ips > "$tmp" && [[ -s $tmp ]]; then
    mv -f "$tmp" "$CDN_DIR/$1.ips"; chmod 644 "$CDN_DIR/$1.ips"; return 0
  fi
  rm -f "$tmp"; warn "$(cdn_name "$1"): 在线获取失败, 继续用已保存的 IP 段"; return 1
}

cdn_add() {
  local name url="" h id i=1 src tmp n
  read -r -p "CDN 名称 (如 阿里云 / 腾讯云): " name || return 0
  name=$(printf '%s' "$name" | tr -d '"$`\\' | cut -c1-30)
  [[ -n $name ]] || return 0
  while [[ -f $CDN_DIR/cdn$i.conf ]]; do i=$((i + 1)); done
  id=cdn$i
  choose src "IP 段从哪里来:" "粘贴 (从 CDN 控制台复制 [回源IP段])" "网址 (CDN 公开的 IP 列表地址, 会每周自动更新)" || return 0
  tmp=$(mktemp)
  if [[ $src == 网址* ]]; then
    read -r -p "IP 列表网址 (https://...): " url || { rm -f "$tmp"; return 0; }
    valid_url "$url" || { rm -f "$tmp"; err "网址格式不正确"; return 1; }
    curl -fsSL --max-time 20 "$url" 2>/dev/null | cdn_parse_ips > "$tmp"
  else
    echo "粘贴 IP 段, 一行一个 (如 1.2.3.0/24, 单个 IP 也行), 完成后单独输入一行 END:"
    read_block | cdn_parse_ips > "$tmp"
  fi
  n=$(grep -c . "$tmp")
  ((n > 0)) || { rm -f "$tmp"; err "没有读到有效的 IP 段"; return 1; }
  echo "  读到 $n 个 IP 段"
  choose h "这个 CDN 用哪个请求头传访客真实 IP:" "X-Forwarded-For (绝大多数 CDN, 推荐)" "其他 (自己填)" || { rm -f "$tmp"; return 0; }
  mkdir -p "$CDN_DIR"
  if [[ $h == 其他* ]]; then
    read -r -p "请求头名称 (如 Ali-Cdn-Real-Ip): " h || { rm -f "$tmp"; return 0; }
    [[ $h =~ ^[A-Za-z0-9-]{2,40}$ ]] || { rm -f "$tmp"; err "请求头名称不正确"; return 1; }
    warn "Nginx 全部网站只能用一个真实 IP 请求头: 改成 $h 后, Cloudflare 也会按这个头识别"
    warn "(Cloudflare 不发这个头的话, 走 Cloudflare 的访问就认不出真实 IP)"
    confirm "确定?" n || { rm -f "$tmp"; return 0; }
    echo "$h" > "$CDN_HEADER_CONF"
  fi
  printf 'NAME=%q\nURL=%q\n' "$name" "$url" > "$CDN_DIR/$id.conf"
  mv -f "$tmp" "$CDN_DIR/$id.ips"; chmod 644 "$CDN_DIR/$id.ips"
  cdn_apply
  info "已添加 CDN: $name ($n 个 IP 段), 真实 IP 请求头: $(cdn_header)"
  cfw_active && echo "  源站保护已同步放行这些 IP 段"
  [[ -z $url ]] && echo "  提示: CDN 的回源 IP 段会变, 隔一段时间到控制台核对一下, 变了就到这里 [修改 IP 段]"
  return 0
}

cdn_pick() {  # -> CDN_PICK
  local i; local -a opts=()
  CDN_PICK=""
  for i in $(cdn_ids); do opts+=("$(cdn_name "$i") ($i)"); done
  ((${#opts[@]})) || { warn "还没有添加自定义 CDN"; return 1; }
  choose CDN_PICK "选择 CDN:" "${opts[@]}" || return 1
  CDN_PICK=${CDN_PICK##*(}; CDN_PICK=${CDN_PICK%)}
}

cdn_del() {
  cdn_pick || return 0
  confirm "删除 CDN $(cdn_name "$CDN_PICK") ?" n || return 0
  rm -f "$CDN_DIR/$CDN_PICK.conf" "$CDN_DIR/$CDN_PICK.ips"
  [[ -z $(cdn_ids) ]] && rm -f "$CDN_HEADER_CONF"
  cdn_apply
  info "已删除, 真实 IP 请求头: $(cdn_header)"
}

cdn_edit() {
  local tmp n
  cdn_pick || return 0
  [[ -n $(cdn_url "$CDN_PICK") ]] && { cdn_fetch_one "$CDN_PICK" && cdn_apply && info "已从网址更新: $(cdn_count "$CDN_PICK") 个 IP 段"; return 0; }
  echo "当前 $(cdn_count "$CDN_PICK") 个 IP 段。粘贴新的完整列表 (会替换旧的), 完成后单独输入一行 END:"
  tmp=$(mktemp); read_block | cdn_parse_ips > "$tmp"
  n=$(grep -c . "$tmp")
  ((n > 0)) || { rm -f "$tmp"; err "没有读到有效的 IP 段, 没有改动"; return 1; }
  mv -f "$tmp" "$CDN_DIR/$CDN_PICK.ips"
  cdn_apply && info "已更新: $n 个 IP 段"
}

cdn_header_menu() {
  local c h
  echo "  当前: $(cdn_header) $([[ -s $CDN_HEADER_CONF ]] && echo "(手动指定)" || echo "(自动)")"
  echo "  自动: 只有 Cloudflare 时用 CF-Connecting-IP, 加了其他 CDN 后用 X-Forwarded-For"
  choose c "真实 IP 请求头:" "自动 (推荐)" "手动指定" || return 0
  if [[ $c == 自动* ]]; then rm -f "$CDN_HEADER_CONF"
  else
    read -r -p "请求头名称: " h || return 0
    [[ $h =~ ^[A-Za-z0-9-]{2,40}$ ]] || { err "请求头名称不正确"; return 1; }
    mkdir -p "$CDN_DIR"; echo "$h" > "$CDN_HEADER_CONF"
  fi
  realip_write && info "真实 IP 请求头: $(cdn_header)"
}

cdn_menu() {
  local c i u
  while true; do
    title "CDN 设置"
    echo "  CDN 真实IP: $(realip_state)"
    echo "  请求头:     $(cdn_header) $([[ -s $CDN_HEADER_CONF ]] && echo "(手动指定)" || echo "(自动)")"
    echo "  Cloudflare: $(cdn_cf_ips | grep -c .) 个IP段 (每周自动更新)"
    for i in $(cdn_ids); do
      u=$(cdn_url "$i")
      echo "  $(cdn_name "$i"): $(cdn_count "$i") 个IP段 ($([[ -n $u ]] && echo 网址自动更新 || echo 手动))"
    done
    choose c "操作:" "$(realip_on && echo "关闭 CDN 真实IP" || echo "开启 CDN 真实IP")" "添加其他 CDN" \
      "修改 CDN 的 IP 段" "删除 CDN" "立即更新全部 IP 列表" "真实IP请求头" "返回" || return 0
    case $c in
      关闭*) (realip_set off); pause ;;
      开启*) (realip_set on); pause ;;
      添加*) (cdn_add); pause ;;
      修改*) (cdn_edit); pause ;;
      删除*) (cdn_del); pause ;;
      立即*) (cf_refresh_all); pause ;;
      真实IP*) (cdn_header_menu); pause ;;
      *) return 0 ;;
    esac
  done
}

wsm_logrotate() {
  [[ -d /etc/logrotate.d ]] || return 0
  [[ -f /etc/logrotate.d/wsm ]] && return 0
  cat > /etc/logrotate.d/wsm <<'EOF'
/var/log/wsm-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

realip_ensure() {  # 装了 Nginx 就确保真实 IP 配置 (没被关闭时) 和每周更新任务存在
  command -v nginx >/dev/null 2>&1 || return 0
  realip_on && [[ ! -f $REALIP_CONF ]] && realip_write >/dev/null 2>&1
  if [[ ! -f $CFW_CRON && -x $WSM_BIN ]]; then
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n23 4 * * 1 root %s cf-refresh >> /var/log/wsm-task.log 2>&1\n' "$WSM_BIN" > "$CFW_CRON"
    chmod 644 "$CFW_CRON"
  fi
  return 0
}

cf_refresh_all() {  # 每周更新: Cloudflare + 有网址的自定义 CDN -> 真实 IP 配置 + 源站保护规则
  local i
  cfw_fetch || return 1
  for i in $(cdn_ids); do cdn_fetch_one "$i"; done
  realip_write || true
  if cfw_active || [[ -f $CFW_UNIT ]]; then cfw_apply_rules || return 1; fi
  info "CDN IP 列表已更新: Cloudflare $(grep -c . "$CFW_IPS") 个IP段$(for i in $(cdn_ids); do printf ', %s %s 个' "$(cdn_name "$i")" "$(cdn_count "$i")"; done)"
}

# ---------------- SSH 安全 (密钥登录 / 关闭密码登录 / 改端口)
# 设置写在 /etc/ssh/sshd_config.d/00-wsm-ssh.conf (系统不支持 Include 时写在 sshd_config 开头)
# 每次修改都先用 sshd -t 检测, 不通过自动恢复; 重启 sshd 不会断开当前连接
SSH_MAIN=/etc/ssh/sshd_config
SSH_DROPIN=/etc/ssh/sshd_config.d/00-wsm-ssh.conf
SSH_AK=/root/.ssh/authorized_keys

ssh_use_dropin() { grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_MAIN" 2>/dev/null; }
ssh_eff() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }

ssh_wsm_get() {
  local src=""
  if [[ -f $SSH_DROPIN ]]; then src=$(cat "$SSH_DROPIN")
  else src=$(sed -n '/^# wsm-ssh begin/,/^# wsm-ssh end/p' "$SSH_MAIN" 2>/dev/null); fi
  printf '%s\n' "$src" | awk -v k="$1" '$1==k{print $2; exit}'
}

ssh_key_count() {
  [[ -f $SSH_AK ]] || { echo 0; return 0; }
  grep -cvE '^[[:space:]]*(#|$)' "$SSH_AK" || true
}

ssh_nopass_now() { [[ $(ssh_eff passwordauthentication) == no ]]; }

ssh_state() {
  printf '密码登录%s · 密钥%s个 · 端口%s' \
    "$(ssh_nopass_now && echo "${G}关${N}" || echo "${Y}开${N}")" "$(ssh_key_count)" "$(ssh_port_now)"
}

ssh_reload() {
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload; systemctl restart ssh.socket 2>/dev/null
  fi
  systemctl restart "$(sshd_service)" 2>/dev/null || systemctl reload "$(sshd_service)" 2>/dev/null
}

ssh_pass_mode() {  # wsm 当前写入的密码登录设置 -> ssh_apply 的第一个参数
  case $(ssh_wsm_get PasswordAuthentication) in no) echo 1 ;; yes) echo 2 ;; *) echo 0 ;; esac
}

ssh_apply() {  # 密码登录(0=不管 1=关闭 2=强制开启) 端口(空或22=默认)
  local nopass=$1 port=${2:-} bak dbak f tmp
  local -a body=()
  [[ -f $SSH_MAIN ]] || { err "找不到 $SSH_MAIN"; return 1; }
  command -v sshd >/dev/null 2>&1 || { err "没有找到 sshd"; return 1; }
  [[ $port == 22 ]] && port=""
  body+=("PubkeyAuthentication yes")
  if [[ $nopass == 1 ]]; then
    body+=("PasswordAuthentication no" "ChallengeResponseAuthentication no" "PermitRootLogin prohibit-password")
  elif [[ $nopass == 2 ]]; then
    # 云厂商的 50-cloud-init.conf 等可能写了 no; 这里写在最前面 (先读到的生效)
    body+=("PasswordAuthentication yes" "PermitRootLogin yes")
  fi
  [[ -n $port ]] && body+=("Port $port")
  bak=$(mktemp); cp -a "$SSH_MAIN" "$bak"
  dbak=$(mktemp -d); [[ -d /etc/ssh/sshd_config.d ]] && cp -a /etc/ssh/sshd_config.d "$dbak/"
  rm -f "$SSH_DROPIN"
  sed -i '/^# wsm-ssh begin/,/^# wsm-ssh end/d' "$SSH_MAIN"
  # 端口: 其他地方写的 Port 先注释掉 (Port 会叠加), 恢复默认端口时还原
  for f in "$SSH_MAIN" /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f ]] || continue
    sed -i -E 's/^#wsm# //' "$f"
    [[ -n $port ]] && sed -i -E 's/^([[:space:]]*Port[[:space:]])/#wsm# \1/' "$f"
  done
  if ((${#body[@]})); then
    if ssh_use_dropin; then
      mkdir -p /etc/ssh/sshd_config.d
      { echo "# managed by wsm (SSH 安全)"; printf '%s\n' "${body[@]}"; } > "$SSH_DROPIN"
    else
      tmp=$(mktemp)
      { echo "# wsm-ssh begin"; printf '%s\n' "${body[@]}"; echo "# wsm-ssh end"; cat "$SSH_MAIN"; } > "$tmp"
      cat "$tmp" > "$SSH_MAIN"; rm -f "$tmp"
    fi
  fi
  if ! sshd -t 2>/tmp/wsm_sshd_err; then
    cat "$bak" > "$SSH_MAIN"
    if [[ -d $dbak/sshd_config.d ]]; then rm -rf /etc/ssh/sshd_config.d; cp -a "$dbak/sshd_config.d" /etc/ssh/; fi
    rm -rf "$bak" "$dbak"
    err "SSH 配置检测没通过, 已恢复原配置:"; cat /tmp/wsm_sshd_err >&2
    return 1
  fi
  rm -rf "$bak" "$dbak"
  ssh_reload
}

ssh_pubkey_ensure() {  # 系统关闭了密钥登录时自动打开 (不然加了公钥也用不了)
  [[ $(ssh_eff pubkeyauthentication) == no ]] || return 0
  ssh_apply "$(ssh_pass_mode)" "$(ssh_wsm_get Port)" \
    && info "检测到 SSH 关闭了密钥登录, 已自动打开"
}

ssh_ak_prepare() {
  ssh_pubkey_ensure
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  touch "$SSH_AK"; chmod 600 "$SSH_AK"
  [[ -s $SSH_AK && -n $(tail -c1 "$SSH_AK") ]] && echo >> "$SSH_AK"
  return 0
}

SSH_KEYDIR=/root/ssh-key

ssh_key_gen() {
  local name f
  command -v ssh-keygen >/dev/null 2>&1 || { err "没有找到 ssh-keygen"; return 1; }
  name="wsm-$(hostname -s 2>/dev/null || echo vps)-$(date +%Y%m%d)"
  mkdir -p "$SSH_KEYDIR"; chmod 700 "$SSH_KEYDIR"
  f=$SSH_KEYDIR/$name.key
  [[ -e $f ]] && f=$SSH_KEYDIR/$name-$(date +%H%M%S).key
  ssh_ak_prepare
  ssh-keygen -q -t ed25519 -N "" -C "$name" -f "$f" || { err "生成失败"; return 1; }
  cat "$f.pub" >> "$SSH_AK"; rm -f "$f.pub"; chmod 600 "$f"
  info "已生成密钥, 公钥已加入本服务器"
  echo
  echo "  ┌ 私钥文件 ────────────────────────────"
  echo "  │ ${G}$f${N}"
  echo "  └──────────────────────────────────────"
  echo "  1. 用 SFTP 下载这个文件 (Termius: 连上服务器 → SFTP"
  echo "     → 进入 /root/ssh-key/ → 长按文件下载)"
  echo "  2. Termius: Keychain → + → Import Key → 选择该文件"
  echo "  3. 主机设置里 Key 选它, 新开窗口测试密钥登录"
  echo "  4. 测试成功后, 回本菜单 [删除服务器上的私钥文件]"
  echo "  (不方便用 SFTP 的话, 也可以用临时链接下载 / 屏幕显示 / scp 命令)"
  confirm "现在下载这个私钥?" n && key_download "$f"
  return 0
}

ssh_key_files_del() {
  local -a fs=()
  local f
  for f in "$SSH_KEYDIR"/*.key /root/.ssh/wsm-* "$OLD_KEYDIR"/*; do [[ -f $f && $f != *.pub ]] && fs+=("$f"); done
  ((${#fs[@]})) || { info "服务器上没有留存的私钥文件"; return 0; }
  echo "将删除这些私钥文件 (已加入服务器的公钥不受影响):"
  printf '   %s\n' "${fs[@]}"
  warn "确认你已经下载并导入客户端, 删除后无法恢复"
  confirm "确认删除?" n || return 0
  rm -f -- "${fs[@]}"; rmdir "$SSH_KEYDIR" 2>/dev/null; rm -f "$OLD_KEYDIR"/*.pub 2>/dev/null; rmdir "$OLD_KEYDIR" 2>/dev/null
  info "已删除"
}

ssh_key_add() {
  local k
  echo "粘贴公钥 (一整行, ssh-ed25519 / ssh-rsa / ecdsa- 开头; 输入 0 返回):"
  read -r -p "公钥: " k || return 0
  k=$(printf '%s' "$k" | tr -d '\r')
  [[ -n $k ]] || return 1
  [[ $k == *PRIVATE* ]] && { err "这是私钥! 只能粘贴公钥 (.pub 里的内容)"; return 1; }
  ssh-keygen -lf /dev/stdin <<<"$k" >/dev/null 2>&1 || { err "不是有效的公钥"; return 1; }
  ssh_ak_prepare
  grep -qxF -- "$k" "$SSH_AK" && { warn "这个公钥已经添加过了"; return 0; }
  printf '%s\n' "$k" >> "$SSH_AK"
  info "公钥已添加"
}

ssh_key_list() {
  [[ -f $SSH_AK ]] || return 0
  local i=0 line fp
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    i=$((i + 1))
    fp=$(ssh-keygen -lf /dev/stdin <<<"$line" 2>/dev/null \
      | awk '{c=""; for(j=3;j<NF;j++) c=c (c?" ":"") $j; printf "%s %s", $NF, (c?c:"(无备注)")}')
    printf '   %2d) %s\n' "$i" "${fp:-(无法识别)}"
  done < "$SSH_AK"
}

ssh_key_del() {
  local c total
  total=$(ssh_key_count)
  ((total)) || { warn "还没有添加任何公钥"; return 0; }
  echo "已添加的公钥:"; ssh_key_list
  read -r -p "删除哪个 (序号, 回车返回): " c || return 0
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= total)) || return 0
  if ((total == 1)) && ssh_nopass_now; then
    err "这是最后一个公钥, 且已关闭密码登录, 删掉就登录不上了"; return 1
  fi
  confirm "确认删除第 $c 个公钥?" n || return 0
  awk -v n="$c" '/^[[:space:]]*(#|$)/{print; next} {i++; if (i != n) print}' "$SSH_AK" > "$SSH_AK.tmp" \
    && cat "$SSH_AK.tmp" > "$SSH_AK"; rm -f "$SSH_AK.tmp"
  info "已删除"
}

ssh_nopass_on() {
  ((  $(ssh_key_count) > 0 )) || { err "还没有密钥, 请先 [生成新密钥] 或 [粘贴已有公钥]"; return 1; }
  echo "关闭后只能用密钥登录, 密码登录全部拒绝。"
  warn "请先新开一个窗口, 用密钥登录测试成功, 再继续!"
  confirm "已经用密钥登录成功了吗?" n || { info "已取消, 没有改动"; return 0; }
  ssh_apply 1 "$(ssh_wsm_get Port)" || return 1
  if ssh_nopass_now; then info "已关闭密码登录, 现在只能用密钥登录"
  else warn "已写入配置, 但密码登录仍是开启状态 (可能被其他配置覆盖)"; fi
}

ssh_nopass_off() {
  local st
  confirm "恢复密码登录 (root 也允许用密码登录)?" y || return 0
  ssh_apply 2 "$(ssh_wsm_get Port)" || return 1
  if ssh_nopass_now; then warn "已写入配置, 但密码登录仍是关闭状态 (可能被其他配置覆盖)"; return 1; fi
  info "已恢复密码登录"
  # 很多云服务器 root 默认没有密码 (已锁定), 开了密码登录也登不上
  st=$(passwd -S root 2>/dev/null | awk '{print $2}')
  if [[ $st == L || $st == LK || $st == NP ]]; then
    warn "root 账号目前没有可用的密码, 需要先设置一个"
    confirm "现在设置 root 密码?" y && passwd root
  fi
  return 0
}

ssh_fw_open() {
  local p=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/tcp" >/dev/null && info "ufw 已放行 $p"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null && firewall-cmd --reload >/dev/null && info "firewalld 已放行 $p"
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == Enforcing ]]; then
    semanage port -a -t ssh_port_t -p tcp "$p" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$p" 2>/dev/null \
      || warn "SELinux 放行端口失败, 请手动执行: semanage port -a -t ssh_port_t -p tcp $p"
  fi
  return 0
}

ssh_port_change() {
  local old new nopass=0
  old=$(ssh_port_now)
  nopass=$(ssh_pass_mode)
  echo "当前 SSH 端口: $old"
  read -r -p "新端口 (1024-65535, 22 恢复默认, 0 返回): " new || return 1
  [[ $new == 0 || -z $new ]] && return 0
  if ! [[ $new =~ ^[0-9]+$ ]] || { [[ $new != 22 ]] && ((new < 1024 || new > 65535)); }; then
    err "端口不合法"; return 1
  fi
  [[ $new == "$old" ]] && { warn "和当前端口一样"; return 0; }
  if ss -ltnH "sport = :$new" 2>/dev/null | grep -q .; then err "端口 $new 已被占用"; return 1; fi
  echo "云服务器有安全组的, 先在服务商后台放行 TCP $new"
  confirm "确认把 SSH 端口改成 $new ?" y || return 0
  ssh_fw_open "$new"
  ssh_apply "$nopass" "$new" || return 1
  sleep 1
  if ! ss -ltnH "sport = :$new" 2>/dev/null | grep -q .; then
    err "sshd 没有在 $new 上监听, 恢复为 $old"
    ssh_apply "$nopass" "$old"; return 1
  fi
  info "SSH 端口已改为 $new"
  warn "别关当前窗口! 新开一个窗口用端口 $new 登录测试"
  if confirm "新端口登录成功了吗? (选 n 恢复为 $old)" n; then
    info "完成, 以后用端口 $new 登录"
  else
    ssh_apply "$nopass" "$old" && info "已恢复为端口 $old"
  fi
}

ssh_menu() {
  local c
  while true; do
    title "SSH 安全"
    printf '  %s   %s   %s\n' "$(kv 端口 "$T$(ssh_port_now)$N")" \
      "$(kv 密码登录 "$(ssh_nopass_now && echo "${G}已关闭 (只能用密钥)" || echo "${Y}开启")$N")" "$(kv 密钥 "$T$(ssh_key_count) 个$N")"
    echo "  ${D}推荐顺序: 生成密钥 → 新窗口测试 → 关闭密码登录${N}"
    echo
    choose c "操作:" "生成新密钥" "导入公钥 (从仓库拉取 / 粘贴)" "查看/删除公钥" "下载服务器上的私钥" \
      "删除服务器上的私钥文件" "关闭密码登录" "恢复密码登录" "修改 SSH 端口" "返回" || return 0
    case $c in
      生成*) (ssh_key_gen); pause ;;
      导入*) (import_keys); pause ;;
      下载*) (key_download ""); pause ;;
      查看*) (ssh_key_del); pause ;;
      删除服务器*) (ssh_key_files_del); pause ;;
      关闭*) (ssh_nopass_on); pause ;;
      恢复*) (ssh_nopass_off); pause ;;
      修改*) (ssh_port_change); pause ;;
      *) return 0 ;;
    esac
  done
}

menu_security() {
  local c
  while true; do
    title "安全防护"
    echo "  源站保护:   $(cfw_state)"
    echo "  CDN真实IP:  $(realip_state)"
    echo "  防CC/bot:   $(guard_summary)"
    echo "  ${D}(SSH 安全在主菜单 → 2)${N}"
    mlist <<'EOF'

   1) 源站保护 开/关
   2) CDN 设置 (真实IP / 其他CDN / 更新IP)
   3) 防 CC / 恶意 bot
   4) 禁止IP直接访问 (开关)
   5) 网站防篡改
EOF
    mback
    read -r -p "请选择: " c || return 0
    case $c in
      1) (cfw_toggle); pause ;;
      2) cdn_menu ;;
      3) guard_overview ;;
      4) (toggle_block_ip); pause ;;
      5) (menu_tamper) ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

logs_clean() {
  local before after c
  before=$(du -sm /var/log/nginx 2>/dev/null | awk '{print $1+0}')
  echo "  网站日志目录 /var/log/nginx 占用 ${before}MB"
  choose c "清理方式:" "删除旧的日志 (保留当前日志, 推荐)" "删除旧日志 + 清空当前日志" "返回" || return 0
  [[ $c == 返回 ]] && return 0
  find /var/log/nginx -type f \( -name '*.gz' -o -name '*.log.[0-9]*' \) -delete 2>/dev/null
  if [[ $c == *清空* ]]; then
    confirm "清空后访问统计会从零开始, 继续?" n && find /var/log/nginx -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null
  fi
  command -v journalctl >/dev/null 2>&1 && journalctl --vacuum-size=200M >/dev/null 2>&1
  after=$(du -sm /var/log/nginx 2>/dev/null | awk '{print $1+0}')
  info "清理完成: ${before}MB → ${after}MB (系统日志也压缩到 200MB 以内)"
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
    mlist <<'EOF'
   1) 站点列表
   2) 新建 PHP 站点
   3) 部署网站应用 (WordPress / Xboard 等)
   4) 新建静态站点
   5) 新建反向代理
   6) 新建域名重定向
   7) 站点设置 (域名/SSL/伪静态/防CC...)
   8) 删除站点
   9) 访问统计
EOF
    mback
    read -r -p "请选择: " c || return 0
    case $c in
      1) list_sites; pause ;;
      2) (add_site php); pause ;;
      3) (app_deploy_menu); pause ;;
      4) (add_site static); pause ;;
      5) (add_site proxy); pause ;;
      6) (add_site redirect); pause ;;
      7) (site_settings "") ;;
      8) (del_site ""); pause ;;
      9) (stats_menu); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_ssl() {
  local c
  while true; do
    title "SSL 证书管理"
    mlist <<'EOF'
   1) 证书总览 (来源/剩余天数)
   2) 申请 / 更换证书
   3) 站点 SSL 设置 (强制HTTPS)
   4) 立即续期全部证书
   5) 自动续期 开/关
EOF
    mback
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
    mlist <<'EOF'

   1) 安装新的 PHP 版本
   2) 卸载 PHP 版本
   3) 常用参数 (上传/内存/超时)
   4) 扩展管理 (查看/安装)
   5) 禁用危险函数
   6) PHP-FPM 进程数调优
   7) 重启 PHP-FPM
EOF
    mback
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
    mlist <<'EOF'
   1) 数据库列表
   2) 创建数据库和用户
   3) 删除数据库
   4) 修改用户密码
   5) 备份数据库
   6) 还原数据库
   7) 安装 phpMyAdmin (网页管理数据库)
EOF
    mback
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
    title "备份与搬家"
    mlist <<'EOF'
   1) 立即备份网站
   2) 立即备份数据库
   3) 查看备份文件
   4) 还原网站
   5) 还原数据库
   6) 查看计划任务
   7) 添加计划任务 (定时备份)
   8) 删除计划任务
   9) 全量备份 / 搬家 / 异地备份
EOF
    mback
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
      9) fb_menu ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ================================================================ 服务器工具 (原 SSH 小工具 ssb 合并进来)
# 这一部分不依赖网站环境; 需要的小工具 (sysbench / traceroute / iptables) 用到时才询问安装, 都记在 已安装组件 里
SSH_TOOL_CONF=$WSM_DIR/ssh-tool.conf      # 导入公钥的地址 (原 /etc/ssh-tool.conf 会自动迁移过来)
OLD_KEYDIR=/root/.ssh/keys                # 原 SSH 小工具生成的私钥目录
KEYS_URL_DEFAULT="https://raw.githubusercontent.com/chentiti888/gy/main/authorized_keys"
KEYS_URL=$KEYS_URL_DEFAULT
if [[ -f $SSH_TOOL_CONF ]]; then
  _u=$(sed -n 's/^KEYS_URL=//p' "$SSH_TOOL_CONF" | tail -1)
  [[ $_u =~ ^https:// ]] && KEYS_URL=$_u
  unset _u
fi

current_port() { ssh_port_now; }
get_ip() { local ip; ip=$(public_ip); echo "${ip:-服务器IP}"; }
pass_state() { ssh_nopass_now && echo "已禁用" || echo "允许"; }

tmp_port_open() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    fi
}
tmp_port_close() {
    local port=$1
    command -v ufw >/dev/null 2>&1 && ufw delete allow "${port}/tcp" >/dev/null 2>&1
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1
    command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    return 0
}

# ---------------- 下载私钥 (wsm 生成的在 /root/ssh-key/, 原 SSH 小工具生成的在 /root/.ssh/keys/)
list_keys() {
    local f
    for f in "$SSH_KEYDIR"/*.key "$OLD_KEYDIR"/*; do [[ -f $f && $f != *.pub ]] && echo "$f"; done
    return 0
}

key_download() {
    local keyfile=$1
    local n m k
    if [[ -z "$keyfile" ]]; then
        local -a keys=()
        mapfile -t keys < <(list_keys)
        if ((${#keys[@]} == 0)); then err "服务器上没有留存的私钥 (可以先 [生成新密钥])"; return; fi
        if ((${#keys[@]} == 1)); then keyfile=${keys[0]}
        else choose keyfile "下载哪个私钥:" "${keys[@]}" || return; fi
    fi
    [[ -f $keyfile ]] || { err "找不到 $keyfile"; return; }
    local ip port
    ip=$(get_ip)
    port=$(current_port)

    echo
    echo "  ${D}下载方式:${N}"
    mitem 1 "屏幕显示私钥内容" "复制保存为文件, 最安全"
    mitem 2 "临时链接下载" "一次性, 120 秒自动关闭, 明文传输"
    mitem 3 "显示 scp 命令" "在你本地电脑执行"
    read -r -p "请选择 [1]: " m || return
    case "$m" in
    2)
        command -v python3 >/dev/null || { err "需要 python3"; return; }
        local dport="" token tmp="" dip rc fw=0
        # 这一步里任何时候按 Ctrl+C: 清理临时文件和防火墙规则, 回到菜单 (不退出整个脚本)
        dl_cleanup() {
            [[ -n "$tmp" ]] && rm -rf "$tmp"
            ((fw)) && tmp_port_close "$dport"
            tmp=""; fw=0
        }
        trap 'echo; warn "已取消"; dl_cleanup; trap - INT; return' INT
        # 链接里的 IP 用这次 SSH 连进来的地址 (NAT/中转机器上, 出口 IP 和入口 IP 可能不一样)
        dip=$(awk '{print $3}' <<< "${SSH_CONNECTION:-}")
        if [[ -z "$dip" || "$dip" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) || "$dip" == *:* ]]; then
            dip=$ip
        fi
        echo
        echo " NAT 机器（SSH 端口是服务商分配的那种）要填服务商给你转发好的端口，否则外面连不上"
        read -r -p "下载端口（回车随机）: " dport || { trap - INT; return; }
        if [[ -z "$dport" ]]; then
            dport=$((RANDOM % 10000 + 40000))
        elif ! [[ "$dport" =~ ^[0-9]+$ ]] || ((dport < 1 || dport > 65535)); then
            trap - INT; err "端口无效"; return
        fi
        if timeout 5 ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${dport}$"; then
            trap - INT; err "端口 ${dport} 已被占用，换一个"; return
        fi
        echo " 使用端口：${dport}"
        token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        tmp=$(mktemp -d)
        cp "$keyfile" "${tmp}/${token}"
        fw=1; tmp_port_open "$dport"
        warn "私钥将通过明文 HTTP 传输，下载完成后建议删除并重新生成"
        echo -e "下载链接：${CYAN}http://${dip}:${dport}/${token}${NC}"
        echo " 用手机/电脑浏览器打开链接，会下载一个名为 ${keyfile##*/} 的文件（在浏览器的「下载」里）"
        echo " 或在电脑上执行：curl -o ${keyfile##*/} http://${dip}:${dport}/${token}"
        echo " （云服务器需在安全组放行 ${dport}/tcp；120 秒内没人下载自动关闭；按 Ctrl+C 取消）"
        # 等待下载时按 Ctrl+C: 只结束下载服务, 然后照常往下清理
        trap ':' INT
        python3 - "$tmp" "$dport" "$token" "${keyfile##*/}" <<'PY'
import http.server, sys, os, threading
d, port, token, name = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(os.path.join(d, token), "rb").read()
result = {"ok": False}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.strip('/') != token:
            self.send_error(404); return
        # 告诉浏览器这是要下载的文件, 并用密钥名作为文件名 (不然会保存成一串随机字符)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
        result["ok"] = True
        threading.Thread(target=self.server.shutdown, daemon=True).start()
    def log_message(self, *a): pass
try:
    s = http.server.HTTPServer(('0.0.0.0', port), H)
except OSError as e:
    print(" 无法监听端口 %d：%s" % (port, e)); sys.exit(2)
t = threading.Timer(120, s.shutdown); t.daemon = True; t.start()
try:
    s.serve_forever()
except KeyboardInterrupt:
    print("\n 已取消下载"); sys.exit(1)
sys.exit(0 if result["ok"] else 3)
PY
        rc=$?
        trap - INT
        dl_cleanup
        case $rc in
            0) info "已下载，临时下载服务已关闭" ;;
            3) warn "120 秒内没有人下载，已自动关闭。连不上的话：检查安全组是否放行 ${dport}/tcp，NAT 机器要用转发好的端口" ;;
            *) info "临时下载服务已关闭" ;;
        esac
        ;;
    3)
        echo -e "在本地电脑执行：\n${CYAN}scp -P ${port} root@${ip}:${keyfile} ./${keyfile##*/}${NC}"
        ;;
    *)
        echo -e "${YELLOW}↓↓↓ 复制下面全部内容保存为文件（含 BEGIN/END 行）↓↓↓${NC}"
        cat "$keyfile"
        echo -e "${YELLOW}↑↑↑ 结束 ↑↑↑${NC}"
        echo "本地保存后执行：chmod 600 文件名 ；登录：ssh -i 文件名 -p ${port} root@${ip}"
        ;;
    esac
}

# ---------------- 端口转发 (TCP/UDP DNAT)
# TCP/UDP DNAT 端口转发（来自 udp-f.sh，规则和独立脚本完全通用，两边都能看到、删除）
#   - 支持 TCP+UDP / 仅 UDP / 仅 TCP，中转端口和落地端口可以不同
#   - 重复添加相同转发不会重复写入；只处理 IPv4，不修改 SSH 等其他规则
#   - 同时识别并可删除旧版 UDP 脚本创建的 UDP_FORWARD_* 规则
DNAT_CHAIN="PORT_FWD_DNAT"
ACCEPT_CHAIN="PORT_FWD_ACCEPT"
LEGACY_DNAT_CHAIN="UDP_FORWARD_DNAT"
LEGACY_ACCEPT_CHAIN="UDP_FORWARD_ACCEPT"

FWD_RULES=()


fwd_install_iptables() {
    ensure_pkg iptables iptables "端口转发"
}

fwd_need_iptables() {
    command -v iptables >/dev/null 2>&1 || { err "未安装 iptables，没有可操作的规则。"; return 1; }
}

fwd_ensure() {
    local tbl=()
    if [[ "$1" == "-t" ]]; then
        tbl=(-t "$2")
        shift 2
    fi
    local chain="$1"
    shift
    iptables ${tbl[@]+"${tbl[@]}"} -C "$chain" "$@" 2>/dev/null ||
        iptables ${tbl[@]+"${tbl[@]}"} -A "$chain" "$@"
}

# 用法: fwd_purge 表 链 正则...  (正则以 ! 开头表示不匹配)
fwd_purge() {
    local table="$1" chain="$2"
    shift 2
    local out line re
    local a=()
    out="$(iptables -t "$table" -S "$chain" 2>/dev/null | grep '^-A' || true)"
    for re in "$@"; do
        if [[ "$re" == '!'* ]]; then
            out="$(grep -Ev -- "${re:1}" <<< "$out" || true)"
        else
            out="$(grep -E -- "$re" <<< "$out" || true)"
        fi
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -ra a <<< "$line"
        a[0]="-D"
        iptables -t "$table" "${a[@]}" 2>/dev/null || true
    done <<< "$out"
}

# 开机恢复规则用 iptables-persistent (netfilter-persistent 服务)
# 保存时排除 wsm 源站保护的 WSM_CF 链: 那部分由它自己的开机服务管理, 存进来会重复加载, 关掉后还会被恢复
fwd_save() {
    info "正在保存 iptables 规则..."
    if [[ $PM == apt ]] && ! pkg_has iptables-persistent && pkg_has ufw; then
        warn "系统装了 ufw (和 iptables-persistent 冲突), 不自动安装; 服务器重启后转发规则需要重新添加"
    elif [[ $PM == apt ]] && ! pkg_has iptables-persistent; then
        info "正在安装 iptables-persistent（开机自动恢复转发规则，可在 已安装组件 里卸载）..."
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections 2>/dev/null
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections 2>/dev/null
        pkg_refresh
        PKG_FOR="端口转发 (开机恢复规则)" pkg_install iptables-persistent >/dev/null 2>&1 \
            || warn "iptables-persistent 安装失败，服务器重启后转发规则可能丢失"
    fi
    mkdir -p /etc/iptables
    iptables-save 2>/dev/null | grep -v -- 'WSM_CF' > /etc/iptables/rules.v4.tmp \
        && mv -f /etc/iptables/rules.v4.tmp /etc/iptables/rules.v4
    if [[ -f /etc/iptables/rules.v6 ]] && command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save 2>/dev/null | grep -v -- 'WSM_CF' > /etc/iptables/rules.v6.tmp \
            && mv -f /etc/iptables/rules.v6.tmp /etc/iptables/rules.v6
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent.service'; then
        systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    elif [[ $PM != apt ]]; then
        warn "已保存到 /etc/iptables/rules.v4；这个系统重启后需要自行设置恢复规则"
    fi
}

# FWD_RULES 每项: chain|proto|前端端口|落地IP|落地端口
fwd_collect() {
    FWD_RULES=()
    local chain line proto front dest i
    local f=()
    for chain in "$DNAT_CHAIN" "$LEGACY_DNAT_CHAIN"; do
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            read -ra f <<< "$line"
            proto=""; front=""; dest=""
            for ((i = 0; i < ${#f[@]}; i++)); do
                case "${f[i]}" in
                    -p)               proto="${f[i+1]:-}" ;;
                    --dport)          front="${f[i+1]:-}" ;;
                    --to-destination) dest="${f[i+1]:-}" ;;
                esac
            done
            if [[ -n "$proto" && -n "$front" && -n "$dest" ]]; then
                FWD_RULES+=("${chain}|${proto}|${front}|${dest%:*}|${dest##*:}")
            fi
        done < <(iptables -t nat -S "$chain" 2>/dev/null | grep '^-A' || true)
    done
}

fwd_count() {
    local n=0 r chain proto front ip port
    for r in ${FWD_RULES[@]+"${FWD_RULES[@]}"}; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        # shellcheck disable=SC2053
        if [[ "$proto" == $1 && "$front" == $2 && "$ip" == $3 && "$port" == $4 ]]; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

fwd_print() {
    fwd_collect
    FWD_COUNT=${#FWD_RULES[@]}
    if (( FWD_COUNT == 0 )); then
        echo "  （当前没有转发规则）"
        return
    fi
    printf "  %-4s %-6s %-10s %-24s %s\n" "编号" "协议" "中转端口" "落地地址" "来源"
    local i=1 r chain proto front ip port src
    for r in "${FWD_RULES[@]}"; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        src="当前版本"
        [[ "$chain" == "$LEGACY_DNAT_CHAIN" ]] && src="旧版UDP脚本"
        printf "  %-6s %-6s %-12s %-24s %s\n" "$i" "${proto^^}" "$front" "${ip}:${port}" "$src"
        i=$((i + 1))
    done
}


fwd_add() {
    local BACKEND_IP BACKEND_PORT FRONT_PORT PROTO_CHOICE CONFIRM
    local PROTOS=() PROTO_DESC="" PROTO OUT_IF o o1 o2 o3 o4

    echo
    read -r -p "请输入落地服务器 IP: " BACKEND_IP || return 9   # 输入 0: 直接回到菜单
    [[ "$BACKEND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "IP 格式不正确：$BACKEND_IP"; return 1; }

    IFS='.' read -r o1 o2 o3 o4 <<< "$BACKEND_IP"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$o <= 255 )) || { err "IP 地址不正确：$BACKEND_IP"; return 1; }
    done

    read -r -p "请输入落地服务器端口: " BACKEND_PORT || return 9   # 输入 0: 直接回到菜单
    [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || { err "端口必须是数字"; return 1; }
    (( BACKEND_PORT >= 1 && BACKEND_PORT <= 65535 )) || { err "端口范围必须是 1-65535"; return 1; }

    read -r -p "请输入中转服务器监听端口: " FRONT_PORT || return 9   # 输入 0: 直接回到菜单
    [[ "$FRONT_PORT" =~ ^[0-9]+$ ]] || { err "端口必须是数字"; return 1; }
    (( FRONT_PORT >= 1 && FRONT_PORT <= 65535 )) || { err "端口范围必须是 1-65535"; return 1; }

    echo
    echo "转发协议："
    echo "  1) TCP + UDP（默认）"
    echo "  2) 仅 UDP"
    echo "  3) 仅 TCP"
    read -r -p "请选择 [1-3]: " PROTO_CHOICE || return 9   # 输入 0: 直接回到菜单
    case "${PROTO_CHOICE:-1}" in
        1) PROTOS=(tcp udp); PROTO_DESC="TCP+UDP" ;;
        2) PROTOS=(udp);     PROTO_DESC="UDP" ;;
        3) PROTOS=(tcp);     PROTO_DESC="TCP" ;;
        *) { err "无效选择：$PROTO_CHOICE"; return 1; } ;;
    esac

    echo
    echo "----------------------------------------------"
    echo "转发协议 : ${PROTO_DESC}"
    echo "中转端口 : ${FRONT_PORT}"
    echo "落地地址 : ${BACKEND_IP}:${BACKEND_PORT}"
    echo "----------------------------------------------"
    read -r -p "确认配置？[Y/n]: " CONFIRM
    [[ -z "$CONFIRM" || "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }

    fwd_install_iptables || return

    info "正在开启 IPv4 转发..."
    cat >/etc/sysctl.d/99-port-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl --system >/dev/null
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! ip route get "$BACKEND_IP" >/dev/null 2>&1; then
        warn "当前服务器没有到 $BACKEND_IP 的有效路由，继续配置可能无法工作。"
    fi

    OUT_IF="$(ip route get "$BACKEND_IP" 2>/dev/null | awk '
        {
            for (i=1; i<=NF; i++)
                if ($i=="dev") { print $(i+1); exit }
        }')"
    [[ -n "$OUT_IF" ]] || OUT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
    [[ -n "$OUT_IF" ]] || { err "无法确定出口网卡。"; return 1; }
    info "检测到出口网卡：$OUT_IF"

    iptables -t nat -N "$DNAT_CHAIN" 2>/dev/null || true
    iptables -N "$ACCEPT_CHAIN" 2>/dev/null || true

    for PROTO in "${PROTOS[@]}"; do
        info "正在配置 ${PROTO^^} 转发..."

        fwd_ensure -t nat PREROUTING -p "$PROTO" --dport "$FRONT_PORT" -j "$DNAT_CHAIN"
        fwd_ensure FORWARD -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" -j "$ACCEPT_CHAIN"

        fwd_ensure -t nat "$DNAT_CHAIN" -p "$PROTO" --dport "$FRONT_PORT" \
            -j DNAT --to-destination "${BACKEND_IP}:${BACKEND_PORT}"

        fwd_ensure "$ACCEPT_CHAIN" -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" \
            -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

        fwd_ensure "$ACCEPT_CHAIN" -p "$PROTO" -s "$BACKEND_IP" --sport "$BACKEND_PORT" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        fwd_ensure -t nat POSTROUTING -o "$OUT_IF" -p "$PROTO" -d "$BACKEND_IP" --dport "$BACKEND_PORT" \
            -j MASQUERADE
    done

    fwd_save

    echo
    echo "=============================================="
    echo -e "             ${GREEN}配置完成${NC}"
    echo "=============================================="
    echo
    echo "中转服务器：$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "转发协议  ：${PROTO_DESC}"
    echo "中转端口  ：${FRONT_PORT}"
    echo "落地服务器：${BACKEND_IP}:${BACKEND_PORT}"
    echo "出口网卡  ：${OUT_IF}"
    echo "IPv4 转发 ：$(sysctl -n net.ipv4.ip_forward)"
    echo
    echo "当前转发规则："
    fwd_print
    echo
    info "重复添加相同配置不会重复写入相同规则。"
}


fwd_delete_one() {
    local entry="$1"
    local chain proto front ip port acc_chain ip_re
    IFS='|' read -r chain proto front ip port <<< "$entry"
    ip_re="${ip//./\\.}"

    acc_chain="$ACCEPT_CHAIN"
    [[ "$chain" == "$LEGACY_DNAT_CHAIN" ]] && acc_chain="$LEGACY_ACCEPT_CHAIN"

    iptables -t nat -D "$chain" -p "$proto" --dport "$front" \
        -j DNAT --to-destination "${ip}:${port}" 2>/dev/null || true

    fwd_collect

    # 2. 没有其他规则使用该前端端口，则删除 PREROUTING 跳转
    if [[ "$(fwd_count "$proto" "$front" '*' '*')" == "0" ]]; then
        fwd_purge nat PREROUTING "-p ${proto} " "--dport ${front} " \
            "-j (${DNAT_CHAIN}|${LEGACY_DNAT_CHAIN})\$"
    fi

    # 3. 没有其他规则使用该落地目标，则删除放行与 MASQUERADE
    if [[ "$(fwd_count "$proto" '*' "$ip" "$port")" == "0" ]]; then
        fwd_purge filter FORWARD "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " \
            "-j (${ACCEPT_CHAIN}|${LEGACY_ACCEPT_CHAIN})\$"
        fwd_purge filter "$acc_chain" "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} "
        fwd_purge filter "$acc_chain" "-p ${proto} " "-s ${ip_re}/32 " "--sport ${port} "
        fwd_purge nat POSTROUTING "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " "-j MASQUERADE\$"
    fi

    # 4. 旧版回程规则（不带 --sport），该 IP+协议下已无转发才删除
    if [[ "$(fwd_count "$proto" '*' "$ip" '*')" == "0" ]]; then
        fwd_purge filter "$acc_chain" "-p ${proto} " "-s ${ip_re}/32 " "!--sport"
    fi

    info "已删除：${proto^^} ${front} -> ${ip}:${port}"
}

fwd_delete() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    (( FWD_COUNT > 0 )) || return

    echo
    local sel idx
    local picks=() entries=()
    read -r -p "请输入要删除的编号（可多个，空格分隔；直接回车取消）: " sel
    [[ -n "$sel" ]] || { echo "已取消。"; return; }

    for idx in $sel; do
        [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= FWD_COUNT )) || { err "无效编号：$idx"; return 1; }
        entries+=("${FWD_RULES[idx-1]}")
    done

    local CONFIRM
    read -r -p "确认删除选中的 ${#entries[@]} 条规则？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }

    local e
    for e in "${entries[@]}"; do
        fwd_delete_one "$e"
    done

    fwd_save
    echo
    echo "剩余转发规则："
    fwd_print
}

fwd_clear_all() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    (( FWD_COUNT > 0 )) || { warn "没有规则，仍会清理残留的自定义链。"; }

    echo
    local CONFIRM
    read -r -p "确认清空全部转发规则（含旧版 UDP 脚本规则）？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; return 1; }

    local r chain proto front ip port ip_re c
    fwd_collect
    for r in ${FWD_RULES[@]+"${FWD_RULES[@]}"}; do
        IFS='|' read -r chain proto front ip port <<< "$r"
        ip_re="${ip//./\\.}"
        fwd_purge nat POSTROUTING "-p ${proto} " "-d ${ip_re}/32 " "--dport ${port} " "-j MASQUERADE\$"
    done

    fwd_purge nat PREROUTING "-j (${DNAT_CHAIN}|${LEGACY_DNAT_CHAIN})\$"
    fwd_purge filter FORWARD "-j (${ACCEPT_CHAIN}|${LEGACY_ACCEPT_CHAIN})\$"

    for c in "$DNAT_CHAIN" "$LEGACY_DNAT_CHAIN"; do
        iptables -t nat -F "$c" 2>/dev/null || true
        iptables -t nat -X "$c" 2>/dev/null || true
    done
    for c in "$ACCEPT_CHAIN" "$LEGACY_ACCEPT_CHAIN"; do
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
    done

    fwd_save
    info "已清空全部转发规则。"
}

fwd_list() {
    fwd_need_iptables || return
    echo
    echo "当前转发规则："
    fwd_print
    echo
    echo "详细规则查看："
    echo "  iptables -t nat -vnL"
    echo "  iptables -vnL FORWARD"
}

fwd_persist_remove() {  # 清空转发后: 询问是否卸载 iptables-persistent (只卸载 wsm 装的)
    ledger_has iptables-persistent || return 0
    pkg_has iptables-persistent || { ledger_del iptables-persistent; return 0; }
    echo
    echo "  iptables-persistent 是添加转发时装的 (开机恢复规则的服务), 现在没有转发规则了"
    confirm "一起卸载它?" y || return 0
    systemctl disable --now netfilter-persistent >/dev/null 2>&1
    pkg_remove iptables-persistent netfilter-persistent >/dev/null 2>&1 && info "已卸载 iptables-persistent"
    rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6; rmdir /etc/iptables 2>/dev/null
    return 0
}

forward_menu() {
    local c n
    while true; do
        title "端口转发 (TCP/UDP)"
        fwd_collect 2>/dev/null; n=${#FWD_RULES[@]}
        echo "  当前规则: ${T}${n}${N} 条    IPv4 转发: $([[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]] && echo "${G}开${N}" || echo "${D}关${N}")"
        echo
        mitem 1 "添加转发"
        mitem 2 "删除指定转发"
        mitem 3 "清空全部转发规则"
        mitem 4 "查看当前转发规则"
        mback
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) (fwd_add); (($? == 9)) || pause ;;
            2) (fwd_delete); pause ;;
            3) (fwd_clear_all && fwd_persist_remove); pause ;;
            4) (fwd_list); pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------------- 导入公钥
# 从 GitHub 拉文件时先查最新提交, 按提交编号下载, 避开 raw 链接几分钟的缓存
gh_fresh_url() {  # raw地址 -> 能拿到最新内容的地址
    local u=$1 repo branch path sha
    if [[ "$u" =~ ^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([^/]+)/(.+)$ ]]; then
        repo=${BASH_REMATCH[1]}; branch=${BASH_REMATCH[2]}; path=${BASH_REMATCH[3]}
        sha=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null |
            awk -F'"' '/"sha":/{print $4; exit}')
        [[ -n "$sha" ]] && { echo "https://raw.githubusercontent.com/${repo}/${sha}/${path}"; return; }
    fi
    echo "$u"
}

KEY_RE='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*( .*)?$'

keys_url_normalize() {  # 把各种写法统一成能直接下载的地址
    local u=$1
    u=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$u")
    if [[ "$u" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        # 用户名/仓库名 -> 仓库 main 分支根目录的 authorized_keys
        u="https://raw.githubusercontent.com/${u}/main/authorized_keys"
    elif [[ "$u" =~ ^https://github\.com/([^/]+/[^/]+)/blob/(.+)$ ]]; then
        # 网页上的文件地址 -> raw 地址
        u="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$u" =~ ^https://github\.com/([^/]+/[^/.]+)/?$ ]]; then
        # 只给了仓库首页
        u="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/main/authorized_keys"
    elif [[ "$u" =~ ^[A-Za-z0-9-]+$ ]]; then
        # 只给了 GitHub 用户名 -> 这个账号在 GitHub 上登记的所有公钥
        u="https://github.com/${u}.keys"
    fi
    echo "$u"
}

keys_url_set() {
    local u n yn
    echo
    echo " 当前地址：${KEYS_URL}"
    [[ "$KEYS_URL" == "$KEYS_URL_DEFAULT" ]] && echo " （默认地址）"
    echo " 可以填："
    echo "   用户名/仓库名           如 chentiti888/gy（取 main 分支的 authorized_keys）"
    echo "   GitHub 文件网页地址     如 https://github.com/用户/仓库/blob/main/文件"
    echo "   GitHub 用户名           如 chentiti888（取账号设置里登记的公钥）"
    echo "   任意 https 直链"
    echo "   输入 default 恢复默认地址"
    read -rp "新地址（回车取消）: " u
    [[ -z "$u" ]] && return
    if [[ "$u" == default ]]; then
        u=$KEYS_URL_DEFAULT
    else
        u=$(keys_url_normalize "$u")
    fi
    [[ "$u" =~ ^https:// ]] || { err "地址要以 https:// 开头：$u"; return; }
    echo " 解析为：${u}"
    info "正在试拉一次 ..."
    n=$(curl -fsSL --max-time 20 "$(gh_fresh_url "$u")" 2>/dev/null | tr -d '\r' | grep -cE "$KEY_RE")
    if ((n > 0)); then
        info "能拉到 ${n} 把公钥"
    else
        warn "这个地址没拉到公钥（地址不对、仓库是私有的，或文件里没有公钥）"
        read -rp "仍然保存这个地址？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
    fi
    KEYS_URL=$u
    mkdir -p "$WSM_DIR"
    { grep -v '^KEYS_URL=' "$SSH_TOOL_CONF" 2>/dev/null; echo "KEYS_URL=$u"; } > "$SSH_TOOL_CONF.tmp" && mv -f "$SSH_TOOL_CONF.tmp" "$SSH_TOOL_CONF"
    chmod 600 "$SSH_TOOL_CONF"
    info "已保存，以后从这个地址拉取（保存在 ${SSH_TOOL_CONF}，更新脚本也不会丢）"
}

import_keys() {
    local c src="" tmp line yn n=0 add=0 i blob comment fp state
    local -a keys=()
    title "导入公钥"
    mitem 1 "从仓库拉取" "$(files_trunc "${KEYS_URL#https://}" 40)"
    mitem 2 "手动粘贴公钥"
    mitem 3 "修改拉取地址"
    mback
    read -r -p "请选择 [1]: " c
    tmp=$(mktemp)
    case "${c:-1}" in
        1)
            info "正在拉取 ..."
            if ! curl -fsSL --retry 2 --max-time 20 "$(gh_fresh_url "$KEYS_URL")" -o "$tmp" 2>/dev/null; then
                rm -f "$tmp"; err "拉取失败：${KEYS_URL}"; return
            fi
            src="仓库" ;;
        2)
            echo "粘贴公钥（可以多行，以 ssh-ed25519 / ssh-rsa 等开头），粘贴完按一次回车（空行）结束："
            while IFS= read -r line; do [[ -z "$line" ]] && break; echo "$line" >> "$tmp"; done
            src="粘贴" ;;
        3) rm -f "$tmp"; keys_url_set; return ;;
        *) rm -f "$tmp"; return ;;
    esac
    tr -d '\r' < "$tmp" > "$tmp.x" && mv -f "$tmp.x" "$tmp"
    if grep -q 'PRIVATE KEY' "$tmp"; then
        rm -f "$tmp"
        err "内容里有【私钥】！私钥绝对不能放进仓库或发给别人，已停止导入"
        err "请马上删掉仓库里的私钥，并重新生成一对新密钥"
        return
    fi
    while IFS= read -r line; do
        line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ $KEY_RE ]]; then keys+=("$line"); else warn "跳过一行不像公钥的内容：${line:0:40}..."; fi
    done < "$tmp"
    rm -f "$tmp"
    ((${#keys[@]} == 0)) && { err "没有找到可用的公钥"; return; }
    ssh_ak_prepare
    echo
    echo "从${src}读到 ${#keys[@]} 把公钥："
    for i in "${!keys[@]}"; do
        read -r _ blob comment <<< "${keys[i]}"
        fp=""
        command -v ssh-keygen >/dev/null 2>&1 && fp=$(ssh-keygen -lf <(echo "${keys[i]}") 2>/dev/null | awk '{print $2}')
        if grep -qF "$blob" /root/.ssh/authorized_keys; then state="已存在"; else state="${GREEN}新增${NC}"; add=$((add + 1)); fi
        echo -e "  $((i + 1))) ${keys[i]%% *}  ${comment:-（无备注）}  [${state}]"
        [[ -n "$fp" ]] && echo "     指纹：${fp}"
    done
    ((add == 0)) && { info "这些公钥都已经在服务器上了，不用导入"; return; }
    echo
    read -rp "把 ${add} 把新公钥加入 /root/.ssh/authorized_keys？（原有的不会删除）[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    cp -a /root/.ssh/authorized_keys "/root/.ssh/authorized_keys.bak.$(date +%Y%m%d%H%M%S)"
    # 原文件最后一行没换行时先补一个, 免得两把钥匙粘在一行
    [[ -s /root/.ssh/authorized_keys && -n "$(tail -c1 /root/.ssh/authorized_keys)" ]] && echo >> /root/.ssh/authorized_keys
    for i in "${!keys[@]}"; do
        read -r _ blob _ <<< "${keys[i]}"
        grep -qF "$blob" /root/.ssh/authorized_keys || { echo "${keys[i]}" >> /root/.ssh/authorized_keys; n=$((n + 1)); }
    done
    chmod 600 /root/.ssh/authorized_keys
    info "已导入 ${n} 把公钥（原文件已备份）"
    warn "请【新开一个终端】用私钥测试登录：ssh -i 私钥文件 -p $(current_port) root@服务器IP"
    warn "确认能登录后，再到 SSH 安全 → 关闭密码登录"
}

# ---------------- 系统信息
sys_info() {
    local os kern virt model cores load mem swap disk upt ip4 ip6 cc
    os=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s )
    kern=$(uname -r)
    virt=$(systemd-detect-virt 2>/dev/null || echo "未知")
    [[ "$virt" == none ]] && virt="独立服务器 / 未检测到虚拟化"
    model=$(awk -F: '/^(model name|Model Name|Hardware|cpu model)/{print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -s ' ' | sed 's/^ //')
    cores=$(nproc 2>/dev/null || echo 1)
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d / %d MB (已用 %.0f%%)", $3, $2, $3*100/$2}')
    swap=$(free -m 2>/dev/null | awk '/^Swap:/{if ($2 > 0) printf "%d / %d MB", $3, $2; else print "未开启"}')
    disk=$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s / %s (已用 %s)", $3, $2, $5}')
    upt=$(awk '{d=int($1/86400); h=int($1%86400/3600); m=int($1%3600/60); printf "%d 天 %d 小时 %d 分", d, h, m}' /proc/uptime)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    title "系统信息"
    echo " 主机名：$(hostname)"
    echo " 系统：  ${os}（$(uname -m)）"
    echo " 内核：  ${kern}"
    echo " 虚拟化：${virt}"
    echo " CPU：   ${model:-未知}（${cores} 核）"
    echo " 负载：  ${load}"
    echo " 内存：  ${mem}"
    echo " Swap：  ${swap}"
    echo " 硬盘：  ${disk}"
    echo " 运行：  ${upt}"
    echo " TCP 拥塞控制：${cc:-未知}$([[ "$cc" == bbr ]] && echo "（BBR 已开启）")"
    echo " SSH 端口：$(current_port)    密码登录：$(pass_state)    Ping：$(ping_state)"
    printf ' 查询公网 IP ...'
    ip4=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    ip6=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)
    printf '\r\033[K'
    echo " IPv4：  ${ip4:-无}"
    echo " IPv6：  ${ip6:-无}"
}

# ---------------- 内存性能测试
bench_sysbench_mem() {  # read|write 线程数 秒数 -> MB/s
    sysbench memory --memory-block-size=1M --memory-total-size=100T --memory-oper="$1" \
        --threads="$2" --time="$3" run 2>/dev/null |
        sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -1 | awk '{printf "%.0f", $1}'
}

bench_dd_mem() {  # 没有 sysbench 时: 内核在内存里搬数据的速度 -> MB/s
    LC_ALL=C dd if=/dev/zero of=/dev/null bs=1M count=20000 2>&1 |
        awk '/copied/{v=$(NF-1); u=$NF; if (u ~ /^GB/) v*=1000; else if (u ~ /^kB/) v/=1000; printf "%.0f", v}'
}

mem_bench() {
    local yn total avail swapu cores tool r1="" w1="" rm="" wm="" d=""
    cores=$(nproc 2>/dev/null || echo 1)
    total=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    swapu=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t-f)/1024}' /proc/meminfo)
    title "内存性能测试"
    echo " 内存：${total} MB    可用：${avail} MB    Swap 已用：${swapu} MB"
    ((swapu > 100)) && warn "Swap 用了 ${swapu} MB，说明内存曾经不够用，测试结果可能偏低"
    echo " 测试内容：单线程读 / 写，多线程读 / 写（各 5 秒，约 20 秒）"
    echo " 只在内存里反复读写一小块数据，不会占满内存，也不写硬盘"
    if bench_ensure_sysbench; then
        tool=sysbench
    else
        tool=dd
        warn "改用 dd 粗测（只测一项搬运速度），结果和 sysbench 不能直接比"
    fi
    read -rp "开始测试？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    echo
    if [[ "$tool" == sysbench ]]; then
        printf ' 单线程读 ...'; r1=$(bench_sysbench_mem read 1 5); printf '\r\033[K'
        printf ' 单线程写 ...'; w1=$(bench_sysbench_mem write 1 5); printf '\r\033[K'
        if ((cores > 1)); then
            printf ' 多线程读（%s 线程）...' "$cores"; rm=$(bench_sysbench_mem read "$cores" 5); printf '\r\033[K'
            printf ' 多线程写（%s 线程）...' "$cores"; wm=$(bench_sysbench_mem write "$cores" 5); printf '\r\033[K'
        fi
        [[ -z "$r1$w1" ]] && { err "测试没有输出结果"; return; }
        echo -e "${CYAN}测试结果${NC}（sysbench，单位 MB/s，越高越好）"
        echo -e " 单线程读：${GREEN}${r1:-失败}${NC}"
        echo -e " 单线程写：${GREEN}${w1:-失败}${NC}"
        if ((cores > 1)); then
            echo -e " 多线程读：${GREEN}${rm:-失败}${NC}（${cores} 线程）"
            echo -e " 多线程写：${GREEN}${wm:-失败}${NC}（${cores} 线程）"
        fi
        echo
        echo " 说明："
        echo "  单线程 = 一个程序能用到的内存速度，影响网站/机器人的响应快慢"
        echo "  多线程 = 多个程序同时读写时的总速度，看整机内存带宽"
        if [[ -n "$r1" && -n "$rm" ]] && ((cores > 1)) && awk -v a="$rm" -v b="$r1" 'BEGIN{exit !(a < b * 1.2)}'; then
            echo -e "  ${YELLOW}多线程几乎没有比单线程快：内存带宽可能被限制，或多个核在争抢${NC}"
        fi
        echo "  同配置的机器之间对比才有意义；多测几次差距很大，可能是宿主机繁忙或超售"
    else
        printf ' 测试中 ...'; d=$(bench_dd_mem); printf '\r\033[K'
        [[ -z "$d" ]] && { err "测试没有输出结果"; return; }
        echo -e "${CYAN}测试结果${NC}（dd 粗测）"
        echo -e " 内存搬运速度：${GREEN}${d}${NC} MB/s"
        echo "  这是内核在内存里搬数据的速度，只适合同一种方法互相比较；装上 sysbench 结果更全面"
    fi
}

# ---------------- CPU 占用状态
# 读 /proc 两次 (间隔几秒) 算出这段时间的真实占用; 不装任何工具, 看完就结束
cpu_snap() {  # 文件 : 记录 各核 和 各进程 的累计 CPU 时间
    local f line rest pid
    local -a a
    grep '^cpu' /proc/stat > "$1.stat"
    : > "$1.proc"
    for f in /proc/[0-9]*/stat; do
        read -r line < "$f" 2>/dev/null || continue
        pid=${line%% *}
        rest=${line##*) }              # 程序名里可能有空格, 从最后一个 ")" 后面开始数
        read -ra a <<< "$rest"
        echo "$pid $((a[11] + a[12]))" >> "$1.proc"   # utime + stime
    done
}

cpu_bar() {  # 百分比 -> 10 格进度条
    local n=$(( ($1 + 5) / 10 )) b="" i
    ((n > 10)) && n=10
    for ((i = 0; i < 10; i++)); do if ((i < n)); then b+="█"; else b+="░"; fi; done
    printf '%s' "$b"
}

cpu_usage_show() {
    local sec=$1 t hz cores load1 load5 load15 x us=0 ni=0 sy=0 id=100 wa=0 hi=0 si=0 st=0 tot=0 pid p
    t=$(mktemp)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    cores=$(nproc 2>/dev/null || echo 1)
    cpu_snap "$t.a"; sleep "$sec"; cpu_snap "$t.b"
    read -r load1 load5 load15 _ < /proc/loadavg
    # 总体: user nice system idle iowait irq softirq steal
    read -r us ni sy id wa hi si st tot < <(awk '
        FNR==NR && $1=="cpu" {for (i=2;i<=9;i++) a[i]=$i; next}
        $1=="cpu" {t=0; for (i=2;i<=9;i++) {d[i]=$i-a[i]; t+=d[i]}; if (t<=0) t=1;
                   for (i=2;i<=9;i++) printf "%.1f ", d[i]*100/t; print t}' "$t.a.stat" "$t.b.stat")
    local used
    used=$(awk -v i="$id" 'BEGIN{printf "%.0f", 100-i}')
    title "CPU 占用状态"
    echo -e " 总占用：${GREEN}${used}%${NC}（最近 ${sec} 秒，${cores} 核平均）"
    echo " 负载：  ${load1} / ${load5} / ${load15}（1 / 5 / 15 分钟）"
    echo
    echo -e "${CYAN}各核占用${NC}"
    awk 'FNR==NR && $1~/^cpu[0-9]/ {for (i=2;i<=9;i++) a[$1,i]=$i; next}
         $1~/^cpu[0-9]/ {t=0; idl=0; for (i=2;i<=9;i++) {d=$i-a[$1,i]; t+=d; if (i==5) idl=d}
                          if (t<=0) t=1; printf "%s %.0f\n", substr($1,4), (t-idl)*100/t}' "$t.a.stat" "$t.b.stat" |
    while read -r n p; do printf ' 核%-3s %s %3s%%\n' "$n" "$(cpu_bar "$p")" "$p"; done
    echo
    echo -e "${CYAN}占用细节${NC}"
    printf ' 用户程序   %5s%%  网站、机器人、代理等程序自己在计算\n' "$us"
    printf ' 系统内核   %5s%%  内核在帮程序收发数据、读写文件\n' "$sy"
    printf ' 低优先级   %5s%%  被调低优先级的后台任务（如探针）\n' "$ni"
    printf ' 等待硬盘   %5s%%  CPU 空等硬盘读写，高说明硬盘慢或太忙\n' "$wa"
    printf ' 网络中断   %5s%%  处理网卡收到的数据包，流量大时会升高\n' "$(awk -v a="$hi" -v b="$si" 'BEGIN{printf "%.1f", a+b}')"
    printf ' 被宿主占用 %5s%%  宿主机拿走的时间，高说明 VPS 超售\n' "$st"
    printf ' 空闲       %5s%%\n' "$id"
    echo
    echo -e "${CYAN}最耗 CPU 的程序（100% = 占满 1 个核）${NC}"
    printf ' %-7s %6s  %s\n' "PID" "CPU" "程序"
    awk -v hz="$hz" -v sec="$sec" 'FNR==NR {a[$1]=$2; next} ($1 in a) {d=$2-a[$1]; if (d>0) printf "%s %.1f\n", $1, d*100/(hz*sec)}' \
        "$t.a.proc" "$t.b.proc" | sort -k2,2nr | head -n 10 > "$t.top"
    if [[ -s "$t.top" ]]; then
        while read -r pid p; do
            local name cmd
            name=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
            printf ' %-7s %5s%%  %s\n' "$pid" "$p" "$name"
            [[ -n "$cmd" && "$cmd" != "$name" ]] && echo "                 ${cmd:0:44}"
        done < "$t.top"
    else
        echo " （这段时间没有程序明显占用 CPU）"
    fi
    echo
    x=""
    awk -v v="$used" 'BEGIN{exit !(v >= 90)}' && x+=" CPU 基本跑满，网站/程序可能变慢；"
    awk -v v="$wa" 'BEGIN{exit !(v >= 20)}' && x+=" 等待硬盘偏高，瓶颈在硬盘不在 CPU；"
    awk -v v="$st" 'BEGIN{exit !(v >= 10)}' && x+=" 被宿主占用偏高，这台 VPS 可能超售；"
    awk -v a="$hi" -v b="$si" 'BEGIN{exit !(a + b >= 20)}' && x+=" 网络中断偏高，流量很大（代理/转发）；"
    awk -v l="$load5" -v c="$cores" 'BEGIN{exit !(l > c * 1.5)}' && x+=" 5 分钟负载超过核心数 1.5 倍，任务在排队；"
    if [[ -s "$t.top" ]]; then
        read -r pid p < "$t.top"
        awk -v v="$p" 'BEGIN{exit !(v >= 90)}' &&
            x+=" 程序 $(cat "/proc/$pid/comm" 2>/dev/null || echo "PID $pid") 占满了约 $(awk -v v="$p" 'BEGIN{printf "%.0f", v/100}') 个核；"
    fi
    if [[ -n "$x" ]]; then echo -e " ${YELLOW}提示：${x%；}${NC}"; else echo -e " ${GREEN}状态正常${NC}"; fi
    rm -f "$t" "$t".*
}

cpu_usage() {
    local c k
    title "CPU 占用状态"
    mitem 1 "查看一次" "采样 3 秒"
    mitem 2 "实时刷新" "每 3 秒，按回车停止"
    mback
    read -r -p "请选择 [1]: " c
    case "${c:-1}" in
        1) echo " 正在采样 3 秒 ..."; cpu_usage_show 3 ;;
        2)
            # 不整屏清空 (那样会闪): 旧画面留着, 新数据算好后从左上角逐行覆盖, 多出来的旧行再擦掉
            local out line
            printf '\033[2J\033[H\033[?25l'; echo " 正在采样 3 秒 ..."
            while true; do
                out=$(cpu_usage_show 3)
                printf '\033[H'
                while IFS= read -r line; do printf '%s\033[K\n' "$line"; done <<< "$out"
                printf '\033[K\n （每 3 秒刷新，按回车停止）\033[K\n\033[J'
                read -rt 1 k && break
            done
            printf '\033[?25h' ;;
        *) return ;;
    esac
}

# ---------------- 硬盘 IO 测试
io_dd() {  # 写|读 文件 MB数 -> 速度 (如 "512 MB/s")
    local out
    if [[ "$1" == 写 ]]; then
        out=$(LC_ALL=C dd if=/dev/zero of="$2" bs=1M count="$3" oflag=direct conv=fdatasync 2>&1) ||
            out=$(LC_ALL=C dd if=/dev/zero of="$2" bs=1M count="$3" conv=fdatasync 2>&1)   # 不支持直写的文件系统
    else
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        out=$(LC_ALL=C dd if="$2" of=/dev/null bs=1M iflag=direct 2>&1) ||
            out=$(LC_ALL=C dd if="$2" of=/dev/null bs=1M 2>&1)
    fi
    awk '/copied/{print $(NF-1), $NF}' <<< "$out"
}

io_bench() {
    local avail mb f yn w1 w2 w3 r
    avail=$(df -Pm /root 2>/dev/null | awk 'NR==2{print $4}')
    if ((${avail:-0} >= 2048)); then mb=1024
    elif ((${avail:-0} >= 600)); then mb=256
    else err "硬盘剩余空间不足（${avail:-0} MB），无法测试"; return; fi
    title "硬盘 IO 测试"
    echo " 硬盘剩余：${avail} MB"
    warn "会临时写入一个 ${mb}MB 的测试文件（测完自动删除），期间硬盘会很忙"
    read -rp "开始测试？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    f="/root/.wsm-iotest.$$"
    trap 'rm -f "${f:-}"' RETURN
    echo
    printf ' 写入测试 1/3 ...'; w1=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 写入测试 2/3 ...'; w2=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 写入测试 3/3 ...'; w3=$(io_dd 写 "$f" "$mb"); printf '\r\033[K'
    printf ' 读取测试 ...';    r=$(io_dd 读 "$f" "$mb");  printf '\r\033[K'
    rm -f "$f"; trap - RETURN
    [[ -z "$w1$w2$w3$r" ]] && { err "测试失败（dd 没有输出结果）"; return; }
    echo -e "${CYAN}测试结果${NC}（每次 ${mb}MB）"
    echo -e " 写入：${GREEN}${w1:-失败}${NC} / ${GREEN}${w2:-失败}${NC} / ${GREEN}${w3:-失败}${NC}"
    echo -e " 读取：${GREEN}${r:-失败}${NC}"
    echo " 参考：机械硬盘约 100 MB/s，普通 SSD 300 MB/s 以上，NVMe 可达 1 GB/s 以上"
}

# ---------------- BBR
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

bbr_menu() {
    local cc yn avail
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    title "BBR 加速"
    echo " 当前拥塞控制：${cc:-未知}    队列：$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [[ "$cc" == bbr ]]; then
        echo -e " 状态：${GREEN}BBR 已开启${NC}"
        read -rp "关闭 BBR（恢复系统默认 cubic）？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$BBR_CONF"
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
        info "已关闭 BBR（当前：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)）"
        return
    fi
    echo " 状态：未开启"
    echo " BBR 能明显提升高延迟、有丢包线路的速度，适合代理/中转服务器；只改内核参数，不占资源"
    # 内核 4.9 以上才自带 BBR
    if ! awk -v k="$(uname -r)" 'BEGIN{split(k, a, "[.-]"); exit !(a[1] > 4 || (a[1] == 4 && a[2] >= 9))}'; then
        err "内核版本 $(uname -r) 太旧（需要 4.9 以上），请先升级内核"; return
    fi
    read -rp "开启 BBR？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    modprobe tcp_bbr 2>/dev/null
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if [[ " $avail " != *" bbr "* ]]; then
        err "这台机器的内核没有 BBR 模块（可用：${avail:-未知}）。OpenVZ/LXC 这类容器 VPS 不能自己改，需要服务商开启"
        return
    fi
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "$BBR_CONF"
    sysctl -p "$BBR_CONF" >/dev/null 2>&1
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$cc" == bbr ]]; then
        info "BBR 已开启，重启后也会保持（配置文件：${BBR_CONF}）"
    else
        rm -f "$BBR_CONF"
        err "开启失败（当前：${cc:-未知}），这台 VPS 可能不允许修改内核参数"
    fi
}

# ---------------- 禁 Ping
# 用内核参数只关掉"回应 ping", 其他 ICMP (如探测网络 MTU 用的) 照常, 不影响正常上网和代理
PING_CONF="/etc/sysctl.d/99-disable-ping.conf"

ping_state() {
    [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == 1 ]] && echo "已禁用" || echo "允许"
}

ping_menu() {
    local yn has6=0 f
    sysctl -n net.ipv6.icmp.echo_ignore_all >/dev/null 2>&1 && has6=1
    title "禁 Ping"
    echo -e " 当前：IPv4 Ping ${GREEN}$(ping_state)${NC}$( ((has6)) && [[ "$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null)" == 1 ]] && echo "，IPv6 Ping 已禁用")"
    if [[ "$(ping_state)" == 已禁用 ]]; then
        read -rp "恢复 Ping（允许别人 ping 通这台服务器）？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$PING_CONF"
        sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
        ((has6)) && sysctl -w net.ipv6.icmp.echo_ignore_all=0 >/dev/null 2>&1
        # 别的配置文件里也写了禁 ping 的话, 重启后还会生效, 提示一下
        f=$(grep -lE '^[[:space:]]*net\.ipv4\.icmp_echo_ignore_all[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | head -1)
        [[ -n "$f" ]] && warn "${f} 里也设置了禁 ping，重启后会再次生效，需要的话请删掉那一行"
        info "Ping 已恢复（当前：$(ping_state)）"
        return
    fi
    echo " 禁用后：别人 ping 这台服务器会超时，扫描器更难发现它；网站、SSH、代理不受影响"
    echo " 注意：用 ping 做监控的工具（如部分测速、在线监控）会显示这台离线；tcping 照常可用"
    read -rp "禁用 Ping？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    {
        echo "# managed by wsm: 禁止回应 ping"
        echo "net.ipv4.icmp_echo_ignore_all=1"
        ((has6)) && echo "net.ipv6.icmp.echo_ignore_all=1"
    } > "$PING_CONF"
    sysctl -p "$PING_CONF" >/dev/null 2>&1
    if [[ "$(ping_state)" == 已禁用 ]]; then
        info "已禁用 Ping，重启后也会保持$( ((has6)) && echo "（IPv4 和 IPv6）")"
    else
        rm -f "$PING_CONF"
        err "设置失败，这台 VPS 可能不允许修改内核参数（如 OpenVZ/LXC 容器）"
    fi
}

# ---------------- 回程线路检测
# 从本机 traceroute 到国内 4 个城市的电信/联通/移动, 按经过的骨干网 IP 段判断线路类型
# 判断规则参考开源项目 oneclickvirt/backtrace (IP 段 + 经过顺序), 结果是推测, 仅供参考
# 每个目标: 名称 首选IP 运营商 备用IP...
# 备用 IP 取自 spiritLHLS/icmp_targets (MIT 协议) 2026-10-16 的数据: 各省会回应 ping 的地址, 首选不回应时换着试
RT_TARGETS=(
    "北京电信 219.141.140.10 CT 106.37.68.13 106.37.68.245"
    "北京联通 202.106.195.68 CU 221.222.185.232 221.222.185.246"
    "北京移动 221.179.155.161 CM 211.136.25.153 211.136.25.12"
    "上海电信 202.96.209.133 CT 101.226.94.50 101.226.94.13"
    "上海联通 210.22.97.1 CU 112.64.235.107 112.64.235.17"
    "上海移动 211.136.112.200 CM 117.185.117.117 117.185.117.17"
    "广州电信 58.60.188.222 CT 14.22.119.35 14.22.119.2"
    "广州联通 210.21.196.6 CU 122.13.24.8 122.13.24.1"
    "广州移动 120.196.165.24 CM 211.139.145.129 211.139.145.13"
    "成都电信 61.139.2.69 CT 118.112.1.150 118.112.1.245"
    "成都联通 119.6.6.6 CU 119.6.217.100 119.6.217.10"
    "成都移动 211.137.96.205 CM 36.133.60.2 36.133.60.241"
)

# 每一跳的 IP -> 所属骨干网
RT_ASN_AWK='
function asn(ip,  a) {
    split(ip, a, ".")
    if (ip ~ /^59\.43\./) return "AS4809"
    if (ip ~ /^202\.97\./) return "AS4134"
    if (ip ~ /^(218\.105|210\.51)\./) return "AS9929"
    if (ip ~ /^(202\.77|43\.252|61\.14)\./) return "AS10099"
    if (ip ~ /^219\.158\./) return "AS4837"
    if (a[1] == 223 && ((a[2] == 118 && a[3] == 32) || (a[2] == 120 && a[3] >= 128) ||
        (a[2] == 119 && (a[3] == 8 || a[3] == 9 || (a[3] >= 10 && a[3] <= 15) || (a[3] >= 26 && a[3] <= 29) ||
         (a[3] >= 32 && a[3] <= 37) || a[3] == 74 || a[3] == 75 || a[3] == 88 || a[3] == 89 ||
         a[3] == 100 || a[3] == 252 || a[3] == 253)))) return "AS58807"
    if (ip ~ /^223\.(118|119|120|121)\./) return "AS58453"
    if (ip ~ /^(221\.183|111\.24)\./) return "AS9808"
    if (ip ~ /^(69\.194|203\.22)\./) return "AS23764"
    return ""
}
'

rt_parse() {  # traceroute输出文件 : 每跳一行 "跳数 IP 毫秒 骨干网"
    awk "$RT_ASN_AWK"'
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ { ms = ($3 ~ /^[0-9.]+$/) ? $3 : "-"; print $1, $2, ms, asn($2) }
        $1 ~ /^[0-9]+$/ && $2 == "*"       { print $1, "*", "-", "" }' "$1"
}

rt_classify() {  # 运营商(CT/CU/CM) 解析文件 -> 线路名称
    awk -v c="$1" '
        { if ($4 != "") { n[$4]++; if (!($4 in f)) f[$4] = NR } }
        function first(k) { return (k in f) ? f[k] : -1 }
        END {
            if (c == "CT") {
                if (first("AS4809") >= 0) {
                    if (n["AS4809"] < 2) { print "电信CN2混合 [优质线路]"; exit }
                    if (first("AS4134") < 0 || (f["AS4809"] < f["AS4134"] && n["AS4134"] <= 1)) { print "电信CN2 GIA [精品线路]"; exit }
                    if (f["AS4809"] < f["AS4134"]) { print "电信CN2混合 [优质线路]"; exit }
                    print "电信CN2 GT [优质线路]"; exit
                }
                if (first("AS23764") >= 0) { print "电信CTGNET [精品线路]"; exit }
                if (n["AS4134"] > 1) { print "电信163 [普通线路]"; exit }
                print (n["AS4134"] == 1) ? "只看到电信入口，无法判断" : "没看到电信骨干网"; exit
            }
            if (c == "CU") {
                if (first("AS9929") >= 0) {
                    if (first("AS4837") >= 0 && f["AS4837"] < f["AS9929"]) { print "联通9929混合 [优质线路]"; exit }
                    print "联通9929 [优质线路]"; exit
                }
                if (first("AS10099") >= 0) { print "联通CUG [优质线路]"; exit }
                if (n["AS4837"] > 1) { print "联通4837 [普通线路]"; exit }
                print (n["AS4837"] == 1) ? "只看到联通入口，无法判断" : "没看到联通骨干网"; exit
            }
            if (first("AS58807") >= 0) {
                if (first("AS58453") >= 0 && f["AS58453"] < f["AS58807"]) { print "移动CMIN2混合 [优质线路]"; exit }
                print "移动CMIN2 [精品线路]"; exit
            }
            if (first("AS58453") >= 0) { print "移动CMI [普通线路]"; exit }
            if (first("AS9808") >= 0) { print "移动CMNET [普通线路]"; exit }
            print "没看到移动骨干网"
        }' "$2"
}

rt_one() {  # 输出前缀 运营商 IP... : 最多试 3 次 (换备用 IP / 换探测方式), 判断出线路就停
    local out=$1 c=$2 ip k=0 label best="" bestn=-1 n
    shift 2
    for ip in "$@"; do
        k=$((k + 1)); ((k > 3)) && break
        if ((k < 3)); then
            traceroute -n -I -q 1 -w 2 -m 30 "$ip" > "$out.raw" 2>/dev/null       # ICMP
        else
            traceroute -n -T -p 80 -q 1 -w 2 -m 30 "$ip" > "$out.raw" 2>/dev/null # 最后一次换 TCP, 有的线路只放行 TCP
        fi
        rt_parse "$out.raw" > "$out.try"
        label=$(rt_classify "$c" "$out.try")
        n=$(awk '$4 != ""' "$out.try" | wc -l)                         # 认出骨干网的跳数
        if ((n > bestn)); then bestn=$n; cp "$out.try" "$out.hops"; echo "$ip $k" > "$out.used"; fi
        [[ "$label" == *线路* ]] && break                                 # 已判断出线路
    done
    rm -f "$out.raw" "$out.try"
}

ensure_traceroute() { ensure_pkg traceroute traceroute "回程线路检测"; }

route_check() {
    local t i name ip c alts tries line label last ms c1 c2 sel myip
    title "回程线路检测"
    echo " 回程 = 数据从这台服务器回到国内的路线，决定你下载/看视频的速度和稳定性"
    echo " 检测北京、上海、广州、成都的电信 / 联通 / 移动，约 30 秒"
    ensure_traceroute || return
    t=$(mktemp -d)
    printf ' 检测中（判断不出的会换备用地址重试，约 30～90 秒）...'
    for i in "${!RT_TARGETS[@]}"; do
        read -r name ip c alts <<< "${RT_TARGETS[i]}"
        # shellcheck disable=SC2086
        rt_one "$t/$i" "$c" "$ip" $alts &
    done
    wait
    printf '\r\033[K'
    echo -e "${CYAN}检测结果${NC}（线路是根据途经的骨干网推测的）"
    for i in "${!RT_TARGETS[@]}"; do
        read -r name ip c _ <<< "${RT_TARGETS[i]}"
        [[ -f "$t/$i.used" ]] && read -r ip tries < "$t/$i.used"
        label=$(rt_classify "$c" "$t/$i.hops")
        # 到达目标的延迟; 目标没回应时不显示中途某一跳的延迟, 免得误导
        ms=$(awk -v ip="$ip" '$2 == ip && $3 != "-" {printf "%.0f ms", $3; exit}' "$t/$i.hops")
        case "$label" in
            *精品*) c1=$GREEN ;; *优质*) c1=$CYAN ;; *普通*) c1=$YELLOW ;; *) c1=$NC ;;
        esac
        printf ' %s  %b%s%b  %s\n' "$name" "$c1" "$label" "$NC" "${ms:-终点不回应}"
    done
    echo
    echo " 说明："
    echo " 终点不回应：目标地址不回 ping，只是测不到延迟，线路判断照样有效"
    echo " 没看到骨干网 / 无法判断：途中路由器不回应探测，换了备用地址和方式还是看不到，多测几次或换时间再测"
    echo
    read -rp "查看某一条的详细路由？输入序号 1-${#RT_TARGETS[@]}（回车跳过）: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#RT_TARGETS[@]})); then
        read -r name ip c _ <<< "${RT_TARGETS[sel-1]}"
        [[ -f "$t/$((sel - 1)).used" ]] && read -r ip tries < "$t/$((sel - 1)).used"
        echo
        echo -e "${CYAN}${name}（${ip}，第 ${tries:-1} 次尝试）详细路由${NC}"
        printf ' %-4s %-16s %-9s %s\n' "跳" "IP" "延迟" "骨干网"
        while read -r h hip hms has; do
            case "$has" in
                AS4809) has="电信CN2" ;; AS4134) has="电信163" ;; AS23764) has="电信CTGNET" ;;
                AS9929) has="联通9929" ;; AS10099) has="联通CUG" ;; AS4837) has="联通4837" ;;
                AS58807) has="移动CMIN2" ;; AS58453) has="移动CMI" ;; AS9808) has="移动CMNET" ;;
            esac
            printf ' %-4s %-16s %-9s %s\n' "$h" "$hip" "$([[ "$hms" == - ]] && echo - || echo "${hms}ms")" "$has"
        done < "$t/$((sel - 1)).hops"
    fi
    rm -rf "$t"
}

# ---------------- 流媒体 / AI 解锁检测
# 按各平台网页/接口的返回特征判断; 平台改版后可能不准, 结果仅供参考
# 检测方法和请求头 / cookie 对照 lmc999/RegionRestrictionCheck (2025-12) 的写法; 少了 cookie 和浏览器请求头时,
# Netflix / YouTube / ChatGPT 返回的页面不一样, 容易误判
UA_WEB="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
UA_SEC_CH='"Google Chrome";v="125", "Chromium";v="125", "Not.A/Brand";v="24"'
UL_NF_COOKIE='flwssn=d2c72c47-49e9-48da-b7a2-2dc6d7ca9fcf; nfvdid=BQFmAAEBEMZa4XMYVzVGf9-kQ1HXumtAKsCyuBZU4QStC6CGEGIVznjNuuTerLAG8v2-9V_kYhg5uxTB5_yyrmqc02U5l1Ts74Qquezc9AE-LZKTo3kY3g%3D%3D; SecureNetflixId=v%3D3%26mac%3DAQEAEQABABSQHKcR1d0sLV0WTu0lL-BO63TKCCHAkeY.%26dt%3D1745376277212; NetflixId=v%3D3%26ct%3DBgjHlOvcAxLAAZuNS4_CJHy9NKJPzUV-9gElzTlTsmDS1B59TycR-fue7f6q7X9JQAOLttD7OnlldUtnYWXL7VUfu9q4pA0gruZKVIhScTYI1GKbyiEqKaULAXOt0PHQzgRLVTNVoXkxcbu7MYG4wm1870fZkd5qrDOEseZv2WIVk4xIeNL87EZh1vS3RZU3e-qWy2tSmfSNUC-FVDGwxbI6-hk3Zg2MbcWYd70-ghohcCSZp5WHAGXg_xWVC7FHM3aOUVTGwRCU1RgGIg4KDKGr_wsTRRw6HWKqeA..; gsid=09bb180e-fbb1-4bf6-adcb-a3fa1236e323; OptanonConsent=isGpcEnabled=0&datestamp=Wed+Apr+23+2025+10%3A47%3A11+GMT%2B0800+(%E4%B8%AD%E5%9B%BD%E6%A0%87%E5%87%86%E6%97%B6%E9%97%B4)&version=202411.1.0&browserGpcFlag=0&isIABGlobal=false&hosts=&consentId=f13f841e-c75d-4f95-ab04-d8f581cac53e&interactionCount=0&isAnonUser=1&landingPath=https%3A%2F%2Fwww.netflix.com%2Fsg-zh%2Ftitle%2F81280792&groups=C0001%3A1%2CC0002%3A1%2CC0003%3A1%2CC0004%3A1'
UL_YT_COOKIE='YSC=FSCWhKo2Zgw; VISITOR_PRIVACY_METADATA=CgJERRIEEgAgYQ%3D%3D; PREF=f7=4000; __Secure-YEC=CgtRWTBGTFExeV9Iayjele2yBjIKCgJERRIEEgAgYQ%3D%3D; SOCS=CAISOAgDEitib3FfaWRlbnRpdHlmcm9udGVuZHVpc2VydmVyXzIwMjQwNTI2LjAxX3AwGgV6aC1DTiACGgYIgMnpsgY; VISITOR_INFO1_LIVE=Di84mAIbgKY; __Secure-BUCKET=CGQ'
UL_DISNEY_KEY='ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84'
UL_DISNEY_TOKEN='grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange&latitude=0&longitude=0&platform=browser&subject_token=DISNEYASSERTION&subject_token_type=urn%3Abamtech%3Aparams%3Aoauth%3Atoken-type%3Adevice'
UL_DISNEY_GRAPHQL='{"query":"mutation refreshToken($input: RefreshTokenInput!) {\n            refreshToken(refreshToken: $input) {\n                activeSession {\n                    sessionId\n                }\n            }\n        }","variables":{"input":{"refreshToken":"ILOVEDISNEY"}}}'

ul_netflix() {
    local r1 r2 region t
    local -a h=(-H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
        -H 'accept-language: en-US,en;q=0.9' -b "$UL_NF_COOKIE" -H "sec-ch-ua: $UA_SEC_CH" -H 'sec-ch-ua-mobile: ?0'
        -H 'sec-ch-ua-platform: "Windows"' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate'
        -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1' -A "$UA_WEB")
    r1=$(curl $UL_OPT -fsL 'https://www.netflix.com/title/81280792' "${h[@]}")   # LEGO 忍者 (非自制剧)
    r2=$(curl $UL_OPT -fsL 'https://www.netflix.com/title/70143836' "${h[@]}")   # 绝命毒师 (非自制剧)
    [[ -z "$r1" || -z "$r2" ]] && { echo "? 检测失败（连不上）"; return; }
    if grep -q 'Oh no!' <<< "$r1" && grep -q 'Oh no!' <<< "$r2"; then echo "! 仅自制剧"; return; fi
    region=$(sed -n 's/.*"id":"\([^"]*\)".*"countryName":"[^"]*".*/\1/p' <<< "$r1" | head -1)
    echo "Y 完整解锁${region:+（地区 $region）}"
}

ul_disney() {  # 走 Disney+ 自己的登录接口: 设备注册 -> 换令牌 -> 查地区
    local r a tok rt g pre region sup
    [[ $UL_OPT == *-6* ]] && { echo "? 暂不支持用 IPv6 检测"; return; }
    r=$(curl $UL_OPT -s 'https://disney.api.edge.bamgrid.com/devices' -X POST -H "authorization: Bearer $UL_DISNEY_KEY" \
        -H 'content-type: application/json; charset=UTF-8' -A "$UA_WEB" \
        -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}')
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    grep -qi '403 ERROR' <<< "$r" && { echo "N 不支持（IP 被封）"; return; }
    a=$(sed -n 's/.*"assertion" *: *"\([^"]*\)".*/\1/p' <<< "$r" | head -1)
    [[ -z "$a" ]] && { echo "? 检测失败（页面异常）"; return; }
    tok=$(curl $UL_OPT -s 'https://disney.api.edge.bamgrid.com/token' -X POST -H "authorization: Bearer $UL_DISNEY_KEY" \
        -A "$UA_WEB" -d "${UL_DISNEY_TOKEN/DISNEYASSERTION/$a}")
    grep -qiE 'forbidden-location|403 ERROR' <<< "$tok" && { echo "N 不支持（IP 被封）"; return; }
    rt=$(sed -n 's/.*"refresh_token" *: *"\([^"]*\)".*/\1/p' <<< "$tok" | head -1)
    g=$(curl $UL_OPT -sL 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql' -X POST \
        -H "authorization: $UL_DISNEY_KEY" -A "$UA_WEB" -d "${UL_DISNEY_GRAPHQL/ILOVEDISNEY/$rt}")
    pre=$(curl $UL_OPT -sL 'https://disneyplus.com' -o /dev/null -w '%{url_effective}' -A "$UA_WEB")
    region=$(grep -o '"countryCode" *: *"[^"]*"' <<< "$g" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    sup=$(grep -oE '"inSupportedLocation" *: *(true|false)' <<< "$g" | head -1 | sed 's/.*: *//')
    [[ -z "$region" ]] && { echo "N 不支持"; return; }
    [[ "$region" == JP ]] && { echo "Y 支持（地区 JP）"; return; }
    [[ "$pre" =~ preview|unavailable ]] && { echo "N 不支持"; return; }
    case "$sup" in
        true) echo "Y 支持（地区 $region）" ;;
        false) echo "! 地区 $region 即将上线" ;;
        *) echo "? 无法判断（地区 $region）" ;;
    esac
}

ul_youtube() {
    local r region
    r=$(curl $UL_OPT -sL 'https://www.youtube.com/premium' -H 'accept-language: en-US,en;q=0.9' \
        -H "cookie: $UL_YT_COOKIE" -A "$UA_WEB")
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    grep -q 'www.google.cn' <<< "$r" && { echo "N 不支持（地区 CN）"; return; }
    grep -qi 'Premium is not available in your country' <<< "$r" && { echo "N 不支持"; return; }
    region=$(grep -o '"INNERTUBE_CONTEXT_GL" *: *"[^"]*"' <<< "$r" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if grep -qi 'ad-free' <<< "$r"; then echo "Y 支持${region:+（地区 $region）}"; else echo "? 检测失败（页面异常）"; fi
}

ul_prime() {
    local r region
    [[ $UL_OPT == *-6* ]] && { echo "? 暂不支持用 IPv6 检测"; return; }
    r=$(curl $UL_OPT -sL 'https://www.primevideo.com' -A "$UA_WEB")
    [[ -z "$r" ]] && { echo "? 检测失败（连不上）"; return; }
    grep -qi 'isServiceRestricted' <<< "$r" && { echo "N 不支持"; return; }
    region=$(grep -o '"currentTerritory":"[^"]*"' <<< "$r" | head -1 | cut -d'"' -f4)
    if [[ -n "$region" ]]; then echo "Y 支持（地区 $region）"; else echo "? 检测失败（页面异常）"; fi
}

ul_chatgpt() {
    local r1 r2 loc a=0 b=0
    r1=$(curl $UL_OPT -s 'https://api.openai.com/compliance/cookie_requirements' -H 'accept: */*' \
        -H 'accept-language: en-US,en;q=0.9' -H 'authorization: Bearer null' -H 'content-type: application/json' \
        -H 'origin: https://platform.openai.com' -H 'referer: https://platform.openai.com/' -H "sec-ch-ua: $UA_SEC_CH" \
        -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' -H 'sec-fetch-dest: empty' \
        -H 'sec-fetch-mode: cors' -H 'sec-fetch-site: same-site' -A "$UA_WEB")
    r2=$(curl $UL_OPT -s 'https://ios.chat.openai.com/' -H 'accept: */*;q=0.8' -H 'accept-language: en-US,en;q=0.9' \
        -H "sec-ch-ua: $UA_SEC_CH" -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' \
        -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' \
        -H 'upgrade-insecure-requests: 1' -A "$UA_WEB")
    [[ -z "$r1" || -z "$r2" ]] && { echo "? 检测失败（连不上）"; return; }
    loc=$(curl $UL_OPT -s 'https://chatgpt.com/cdn-cgi/trace' | sed -n 's/^loc=//p')
    grep -qi 'unsupported_country' <<< "$r1" && a=1
    grep -qi 'VPN' <<< "$r2" && b=1
    if ((a == 0 && b == 0)); then echo "Y 支持${loc:+（地区 $loc）}"
    elif ((a == 1 && b == 1)); then echo "N 不支持${loc:+（地区 $loc）}"
    elif ((a == 0)); then echo "! 仅网页版可用（App 不行）"
    else echo "! 仅 App 可用（网页版不行）"; fi
}

ul_claude() {
    local u
    u=$(curl $UL_OPT -sL -o /dev/null -w '%{url_effective}' -A "$UA_WEB" 'https://claude.ai/')
    [[ -z "$u" ]] && { echo "? 检测失败（连不上）"; return; }
    case "$u" in
        https://claude.ai/*) echo "Y 支持" ;;
        *app-unavailable-in-region*) echo "N 不支持（地区限制）" ;;
        *) echo "? 无法判断（跳转到 ${u:0:40}）" ;;
    esac
}

# Gemini 支持的国家/地区 (三位代码, 来自 oneclickvirt/UnlockTests 2026-10 的列表; 不在里面的如 CHN HKG MAC RUS IRN PRK CUB SYR)
UL_GEMINI_OK="
ALA ALB DZA ASM AND AGO AIA ATA ATG ARG ARM ABW AUS AUT AZE BHR BGD BRB BEL BLZ BEN BMU BTN BOL BIH
BWA BRA IOT VGB BRN BGR BFA BDI CPV KHM CMR CAN BES CYM CAF TCD CHL CXR CCK COL COM COK CRI CIV HRV
CUW CZE COD DNK DJI DMA DOM ECU EGY SLV GNQ ERI EST SWZ ETH FLK FRO FJI FIN FRA GUF PYF ATF GAB GEO
DEU GHA GIB GRC GRL GRD GLP GUM GTM GGY GIN GNB GUY HTI HMD HND HUN ISL IND IDN IRQ IRL IMN ISR ITA
JAM JPN JEY JOR KAZ KEN KIR KWT KGZ LAO LVA LBN LSO LBR LBY LIE LTU LUX MDG MWI MYS MDV MLI MLT MHL
MTQ MRT MUS MYT MEX FSM MDA MCO MNG MNE MSR MAR MOZ MMR NAM NRU NPL NLD NCL NZL NIC NER NGA NIU NFK
MKD MNP NOR OMN PAK PLW PSE PAN PNG PRY PER PHL PCN POL PRT PRI QAT CYP COG REU ROU RWA BLM SHN KNA
LCA MAF SPM VCT WSM SMR STP SAU SEN SRB SYC SLE SGP SXM SVK SVN SLB SOM ZAF SGS KOR SSD ESP LKA SDN
SUR SJM SWE CHE TWN TJK TZA THA BHS GMB TLS TGO TKL TON TTO TUN TUR TKM TCA TUV VIR UGA UKR ARE GBR
USA UMI URY UZB VUT VAT VEN VNM WLF ESH YEM ZMB ZWE XKX
"

ul_gemini() {
    # 打开 Gemini 网页: 页面里会写 Google 判断的地区 (,2,1,200,"JPN" 这样的三位代码), 在支持列表里就是支持;
    # 页面里有 45631641,null,true 或 45617354,null,true 也表示可用 (这两个标记会随改版变化, 只当辅助判断)
    # 不用 API 判断: 带无效 key 请求时 Google 先校验 key, 不管哪个地区都返回 "key 无效", 会被误判成支持
    local r code cc ok=0
    r=$(curl $UL_OPT -sL 'https://gemini.google.com' -A "$UA_WEB" -H 'accept-language: en-US,en;q=0.9' -w '\n__HTTP__%{http_code}')
    code=${r##*__HTTP__}; r=${r%__HTTP__*}
    [[ -z "$r" || $code == 000 ]] && { echo "? 检测失败（连不上）"; return; }
    [[ $code == 403 || $code == 451 ]] && { echo "N 不支持（IP 被封）"; return; }
    cc=$(grep -o ',2,1,200,"[A-Z]\{3\}"' <<< "$r" | head -1 | sed 's/.*"\([A-Z]*\)"/\1/')
    grep -qE '45631641,null,true|45617354,null,true' <<< "$r" && ok=1
    if [[ -n $cc && " ${UL_GEMINI_OK//$'\n'/ } " == *" $cc "* ]]; then echo "Y 支持（地区 $cc）"
    elif ((ok)); then echo "Y 支持${cc:+（地区 $cc）}"
    else echo "N 不支持${cc:+（地区 $cc）}"; fi
}

unlock_check() {
    local c t i n v ipinfo f
    local -a names=("Netflix" "Disney+" "YouTube Premium" "Prime Video" "ChatGPT" "Claude" "Gemini")
    local -a funcs=(ul_netflix ul_disney ul_youtube ul_prime ul_chatgpt ul_claude ul_gemini)
    title "流媒体 / AI 解锁检测"
    mitem 1 "用 IPv4 检测"
    mitem 2 "用 IPv6 检测"
    mback
    read -r -p "请选择 [1]: " c
    case "${c:-1}" in
        1) UL_OPT="-4 --max-time 10" ;;
        2) curl -6 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1 || { err "这台服务器没有可用的 IPv6"; return; }
           UL_OPT="-6 --max-time 10" ;;
        *) return ;;
    esac
    ipinfo=$(curl $UL_OPT -s https://www.cloudflare.com/cdn-cgi/trace)
    echo " 出口 IP：$(sed -n 's/^ip=//p' <<< "$ipinfo")    地区：$(sed -n 's/^loc=//p' <<< "$ipinfo")"
    printf ' 检测中（约 10 秒）...'
    t=$(mktemp -d)
    for i in "${!funcs[@]}"; do ( "${funcs[i]}" > "$t/$i" 2>/dev/null ) & done
    wait
    printf '\r\033[K'
    for i in "${!funcs[@]}"; do
        ((i == 0)) && echo -e "${CYAN}流媒体${NC}"
        ((i == 4)) && echo -e "${CYAN}AI${NC}"
        v=$(cat "$t/$i"); f=${v:0:1}; v=${v:2}
        case "$f" in
            Y) printf '  %-16s %b✔ %s%b\n' "${names[i]}" "$GREEN" "$v" "$NC" ;;
            N) printf '  %-16s %b✘ %s%b\n' "${names[i]}" "$RED" "$v" "$NC" ;;
            !) printf '  %-16s %b! %s%b\n' "${names[i]}" "$YELLOW" "$v" "$NC" ;;
            *) printf '  %-16s ? %s\n' "${names[i]}" "${v:-检测失败}" ;;
        esac
    done
    rm -rf "$t"
    echo
    echo " 说明：判断方法参考 RegionRestrictionCheck，平台改版后可能不准，仅供参考"
}
# ---------------- 网速测试 (只用 curl, 不跑第三方测速脚本)
# 多线程同时下载 / 上传若干秒, 用总流量 ÷ 实际用时算出带宽
# 节点: 官方 Speedtest 服务器列表 (和 speedtest-cli 用的同一个接口, 按本机 IP 给出附近的服务器),
#       按距离从近到远排: 同城 → 临近城市 → 更远; 每个先试测 2 秒, 下载和上传都正常才用它, 不行就换下一个
#       Speedtest 都不行时用 Cloudflare 最近机房, 再不行用附近的 Linode 机房 (只能测下载)
# Cloudflare 单次最多给 1 亿字节 (超过直接拒绝), 这里每次取 2500 万, 循环下载
ST_CF_DOWN="https://speed.cloudflare.com/__down?bytes=25000000"
ST_CF_UP="https://speed.cloudflare.com/__up"
ST_UA_CLI="Mozilla/5.0 (Linux-x86_64; U; 64bit; en-us) Python/3.11 (KHTML, like Gecko) speedtest-cli/2.1.3"
ST_MAX_TRY=10      # Speedtest 服务器最多试几个
ST_IPV="-4"

st_now() { date +%s.%N; }
st_mbps() { awk -v b="$1" -v d="$2" 'BEGIN{ if (d <= 0 || b < 100000) print ""; else printf "%.1f", b * 8 / d / 1000000 }'; }
st_fmt() {  # Mbps -> "123.4 Mbps (15.4 MB/s)"
  [[ -n $1 ]] || { echo "${R}失败${N}"; return 0; }
  awk -v m="$1" -v g="$G" -v n="$N" 'BEGIN{ printf "%s%s Mbps%s (%.1f MB/s)", g, m, n, m / 8 }'
}

st_latency() {  # 网址 -> 平均延迟毫秒 (取 5 次 TCP 连接时间)
  local i v out=""
  for i in 1 2 3 4 5; do
    v=$(curl $ST_IPV -s -o /dev/null --connect-timeout 5 --max-time 8 -w '%{time_connect}' "$1" 2>/dev/null) || continue
    [[ $v =~ ^[0-9.]+$ ]] && out+="$v "
  done
  [[ -n $out ]] || return 0
  printf '%s\n' $out | awk '$1 > 0 {s += $1; n++} END{ if (n) printf "%.0f", s / n * 1000 }'
}

st_down() {  # 网址 秒数 线程数 -> Mbps (空 = 失败)
  local url=$1 sec=$2 n=$3 t i start end deadline
  t=$(mktemp -d)
  deadline=$(( $(date +%s) + sec )); start=$(st_now)
  for ((i = 0; i < n; i++)); do
    (
      local r rc
      while :; do
        r=$(( deadline - $(date +%s) )); ((r < 1)) && break
        curl $ST_IPV -fs -o /dev/null --connect-timeout 5 --max-time "$r" -w '%{size_download}\n' "$url" >> "$t/$i" 2>/dev/null
        rc=$?; [[ $rc == 0 || $rc == 28 ]] || break   # 28 = 到时间了; 其他错误不再重试
      done
    ) &
  done
  wait; end=$(st_now)
  st_mbps "$(cat "$t"/* 2>/dev/null | awk '{s += $1} END{print s + 0}')" "$(awk -v a="$start" -v b="$end" 'BEGIN{print b - a}')"
  rm -rf "$t"
}

st_up() {  # 上传地址 秒数 线程数 -> Mbps
  local url=$1 sec=$2 n=$3 t i start end deadline
  t=$(mktemp -d)
  head -c 5242880 /dev/urandom > "$t/blob" 2>/dev/null   # 5MB 随机数据 (防止被压缩; Speedtest 服务器单次上传上限约 7MB)
  deadline=$(( $(date +%s) + sec )); start=$(st_now)
  for ((i = 0; i < n; i++)); do
    (
      local r rc
      while :; do
        r=$(( deadline - $(date +%s) )); ((r < 1)) && break
        curl $ST_IPV -s -o /dev/null --connect-timeout 5 --max-time "$r" -w '%{size_upload}\n' \
          -f -H 'Content-Type: application/octet-stream' --data-binary @"$t/blob" "$url" >> "$t/u$i" 2>/dev/null
        rc=$?; [[ $rc == 0 || $rc == 28 ]] || break
      done
    ) &
  done
  wait; end=$(st_now)
  st_mbps "$(cat "$t"/u* 2>/dev/null | awk '{s += $1} END{print s + 0}')" "$(awk -v a="$start" -v b="$end" 'BEGIN{print b - a}')"
  rm -rf "$t"
}

st_pick_ip() {  # 优先 IPv4, 没有 IPv4 的机器用 IPv6
  ST_IPV="-4"
  curl -4 -s -o /dev/null --max-time 5 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null && return 0
  curl -4 -s -o /dev/null --max-time 5 https://www.speedtest.net/ 2>/dev/null && return 0
  if curl -6 -s -o /dev/null --max-time 5 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
    ST_IPV="-6"; warn "这台服务器没有可用的 IPv4, 改用 IPv6 测试"; return 0
  fi
  err "连不上测速服务器, 请检查网络"; return 1
}

st_threads() { local c; c=$(nproc 2>/dev/null || echo 1); ((c >= 4)) && echo 8 || echo 4; }

st_cf_cand() {
  local colo
  colo=$(curl $ST_IPV -s --max-time 6 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^colo=//p')
  printf 'Cloudflare %s|https://speed.cloudflare.com/__down?bytes=0|%s|%s\n' "${colo:-最近机房}" "$ST_CF_DOWN" "$ST_CF_UP"
}

st_linode_cands() {  # 国家代码 -> 附近的 Linode 机房 (只能测下载, 上传地址留空)
  local r
  case $1 in
    JP|KR|TW|HK|CN|MO) r="tokyo2:东京 singapore:新加坡" ;;
    SG|MY|ID|TH|VN|PH|KH|MM) r="singapore:新加坡 tokyo2:东京" ;;
    IN|PK|BD|LK|AE|SA) r="mumbai1:孟买 singapore:新加坡" ;;
    AU|NZ) r="syd1:悉尼 singapore:新加坡" ;;
    CA) r="toronto1:多伦多 newark:纽瓦克" ;;
    GB|IE) r="london:伦敦 frankfurt:法兰克福" ;;
    DE|NL|FR|BE|LU|CH|AT|IT|ES|PT|PL|CZ|SE|NO|DK|FI|RU|UA|RO|BG|HU|TR) r="frankfurt:法兰克福 london:伦敦" ;;
    *) r="fremont:弗里蒙特 dallas:达拉斯" ;;   # 美国和其他地区
  esac
  local x h f
  for x in $r; do
    h=${x%%:*}; f=${h%1}; [[ $h == tokyo2 || $h == syd1 ]] && f=$h
    printf 'Linode %s|http://speedtest.%s.linode.com/|http://speedtest.%s.linode.com/100MB-%s.bin|\n' "${x#*:}" "$h" "$h" "$f"
  done
}

st_client() {  # -> 本机 IP|纬度|经度|运营商  (speedtest.net 识别的)
  local x
  x=$(curl $ST_IPV -s --max-time 10 -A "$ST_UA_CLI" "https://www.speedtest.net/speedtest-config.php" 2>/dev/null \
      || curl $ST_IPV -s --max-time 10 -A "$ST_UA_CLI" "http://www.speedtest.net/speedtest-config.php" 2>/dev/null)
  x=$(grep -o '<client [^>]*>' <<< "$x" | head -1)
  [[ -n $x ]] || return 1
  printf '%s|%s|%s|%s\n' "$(sed -n 's/.* ip="\([^"]*\)".*/\1/p' <<< "$x")" "$(sed -n 's/.* lat="\([^"]*\)".*/\1/p' <<< "$x")" \
    "$(sed -n 's/.* lon="\([^"]*\)".*/\1/p' <<< "$x")" "$(sed -n 's/.* isp="\([^"]*\)".*/\1/p' <<< "$x")"
}

st_ookla_near() {  # 纬度 经度 -> 附近的 Speedtest 服务器, 按距离从近到远: 距离km|名称|测延迟地址|下载地址|上传地址
  local lat=$1 lon=$2 u xml=""
  for u in "https://www.speedtest.net/speedtest-servers-static.php" "http://c.speedtest.net/speedtest-servers-static.php" \
           "https://www.speedtest.net/speedtest-servers.php" "http://c.speedtest.net/speedtest-servers.php"; do
    xml=$(curl $ST_IPV -s --max-time 15 -A "$ST_UA_CLI" "$u?threads=4" 2>/dev/null)
    [[ $xml == *'<server '* ]] && break
  done
  [[ $xml == *'<server '* ]] || return 0
  printf '%s\n' "$xml" | sed 's/<server /\n<server /g' | grep '^<server ' | awk -v la="$lat" -v lo="$lon" '
    function attr(k,  m) { if (match($0, " " k "=\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m); return m } return "" }
    function rad(d) { return d * 3.14159265358979 / 180 }
    { u = attr("url"); sla = attr("lat"); slo = attr("lon"); if (u == "" || sla == "") next
      d = 0
      if (la != "" && lo != "") {
        a = sin(rad(sla - la) / 2) ^ 2 + cos(rad(la)) * cos(rad(sla)) * sin(rad(slo - lo) / 2) ^ 2
        d = 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
      }
      base = u; sub(/\/[^\/]*$/, "", base)                 # .../speedtest/upload.php -> .../speedtest
      host = u; sub(/^https?:\/\//, "", host); sub(/\/.*$/, "", host)
      printf "%d|%s (%s, %s)|http://%s/|%s/random4000x4000.jpg|%s\n", d, attr("sponsor"), attr("name"), attr("cc"), host, base, u
    }' | sort -t'|' -k1,1n | awk -F'|' '!seen[$3]++' | head -"$ST_MAX_TRY"
}

# st_try 秒数 线程 候选... : 依次试, 先各测 2 秒确认下载和上传都正常, 正常的才正式测
# 候选格式: 距离km|名称|测延迟地址|下载地址|上传地址 (上传地址空 = 只能测下载, 只在最后兜底时用)
# 结果: ST_NAME ST_KM ST_LAT ST_D ST_U (- = 不能测上传) ST_TRIED
st_try() {
  local sec=$1 n=$2 c km name lu du uu
  shift 2
  ST_NAME=""; ST_KM=""; ST_LAT=""; ST_D=""; ST_U=""; ST_TRIED=0
  for c in "$@"; do
    IFS='|' read -r km name lu du uu <<< "$c"
    ST_TRIED=$((ST_TRIED + 1))
    printf '\r\033[K  试第 %d 个节点: %s ...' "$ST_TRIED" "${name:0:40}"
    ST_LAT=$(st_latency "$lu"); [[ -n $ST_LAT ]] || continue
    [[ -n $(st_down "$du" 2 2) ]] || continue
    if [[ -n $uu ]]; then [[ -n $(st_up "$uu" 2 2) ]] || continue; fi
    printf '\r\033[K  测试中: %s (下载 / 上传各 %s 秒) ...' "${name:0:40}" "$sec"
    ST_D=$(st_down "$du" "$sec" "$n"); [[ -n $ST_D ]] || continue
    if [[ -n $uu ]]; then ST_U=$(st_up "$uu" "$sec" "$n"); [[ -n $ST_U ]] || continue; else ST_U="-"; fi
    ST_NAME=$name; ST_KM=$km
    printf '\r\033[K'
    return 0
  done
  printf '\r\033[K'; ST_LAT=""; return 1
}

speed_quick() {  # 本地最近节点: 延迟 + 下载 + 上传
  local cl ip lat lon isp loc n tr c
  local -a cands=()
  title "网速测试"
  echo "  ${D}测这台服务器自己的带宽, 测试期间会占满带宽; 按千兆带宽算约用 2.5GB 流量${N}"
  st_pick_ip || return 1
  n=$(st_threads)
  printf '  查找附近的测速节点 ...'
  cl=$(st_client); IFS='|' read -r ip lat lon isp <<< "$cl"
  tr=$(curl $ST_IPV -s --max-time 6 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  loc=$(sed -n 's/^loc=//p' <<< "$tr")
  [[ -n $ip ]] || ip=$(sed -n 's/^ip=//p' <<< "$tr")
  [[ -n $lat ]] && mapfile -t cands < <(st_ookla_near "$lat" "$lon")
  while IFS= read -r c; do cands+=("0|$c"); done < <(st_cf_cand; st_linode_cands "${loc:-US}")
  printf '\r\033[K'
  echo "  $(kv 出口 "$T${ip:-未知}${isp:+ ($isp)}${loc:+ $loc}$N")   $(kv 线程 "$T$n$N")"
  st_try 10 "$n" "${cands[@]}"
  if [[ -z $ST_NAME ]]; then err "试了 $ST_TRIED 个节点都不能正常测, 请稍后再试"; return 1; fi
  echo "  $(kv 测速节点 "$T$ST_NAME$N")$( ((ST_KM > 0)) && echo "   ${D}距离约 $ST_KM km${N}")"
  ((ST_TRIED > 1)) && echo "  ${D}(前 $((ST_TRIED - 1)) 个节点不能正常测下载/上传, 已自动换到这个)${N}"
  echo
  echo "  $(kv 延迟 "$T$ST_LAT ms$N")"
  echo "  $(kv 下载 "$(st_fmt "$ST_D")")"
  if [[ $ST_U == - ]]; then echo "  $(kv 上传 "${D}所有节点都测不了上传, 这个节点只能测下载${N}")"
  else echo "  $(kv 上传 "$(st_fmt "$ST_U")")"; fi
}

# ---------------- 服务器工具的菜单
bbr_state() { [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; }

menu_net() {
    local c
    while true; do
        title "网络设置"
        echo "  BBR: $(bbr_state && echo "${G}已开启${N}" || echo "${D}未开启${N}")    Ping: $([[ $(ping_state) == 已禁用 ]] && echo "${Y}已禁用${N}" || echo "${G}允许${N}")"
        echo
        mitem 1 "BBR 加速" "开启 / 关闭"
        mitem 2 "禁 Ping" "禁用 / 恢复"
        mitem 3 "端口转发" "TCP / UDP 中转"
        mback
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) (bbr_menu); pause ;;
            2) (ping_menu); pause ;;
            3) forward_menu ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

menu_check() {
    local c
    while true; do
        title "网络检测"
        mitem 1 "网速测试" "本地 延迟 / 下载 / 上传, 约 25 秒"
        mitem 2 "回程线路检测" "电信 / 联通 / 移动"
        mitem 3 "流媒体 / AI 解锁" "Netflix / YouTube / ChatGPT ..."
        mback
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) (speed_quick); pause ;;
            2) (route_check); pause ;;
            3) (unlock_check); pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

menu_perf() {
    local c
    while true; do
        title "性能测试"
        mitem 1 "CPU 占用状态" "各核 / 细节 / 最耗 CPU 的程序"
        mitem 2 "CPU 性能测试" "单核 / 多核"
        mitem 3 "内存性能测试" "读 / 写速度"
        mitem 4 "硬盘 IO 测试" "读 / 写速度"
        mback
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) (cpu_usage); pause ;;
            2) (cpu_bench); pause ;;
            3) (mem_bench); pause ;;
            4) (io_bench); pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ================================================================ CPU 性能测试
# 优先用 sysbench (很多 VPS 测评脚本用的同一种测法, 得分可以直接对比); 装不上就用 openssl 粗测
cpu_steal_read() {  # 输出: 总时间 steal时间
  local _ u n s i w q sq st _r
  read -r _ u n s i w q sq st _r < /proc/stat
  echo "$((u + n + s + i + w + q + sq + ${st:-0})) ${st:-0}"
}

bench_ensure_sysbench() {
  command -v sysbench >/dev/null 2>&1 && return 0
  confirm "需要安装测试工具 sysbench (很小, 只在测试时运行), 现在安装?" y || return 1
  info "正在安装 sysbench ..."
  if [[ $PM == apt ]]; then
    pkg_install sysbench >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; pkg_install sysbench >/dev/null 2>&1; }
  else
    pkg_install sysbench >/dev/null 2>&1 || { dnf install -y epel-release >/dev/null 2>&1; pkg_install sysbench >/dev/null 2>&1; }
  fi
  command -v sysbench >/dev/null 2>&1 && { info "sysbench 已安装"; return 0; }
  warn "sysbench 安装失败"
  return 1
}

bench_sysbench() {  # 线程数 秒数 -> 每秒事件数
  sysbench cpu --cpu-max-prime=10000 --threads="$1" --time="$2" run 2>/dev/null |
    awk '/events per second/{print $NF; exit}'
}

bench_openssl() {  # 进程数 秒数 -> SHA256 速度 MB/s
  local out v
  if (($1 > 1)); then out=$(openssl speed -seconds "$2" -bytes 16384 -multi "$1" sha256 2>/dev/null)
  else out=$(openssl speed -seconds "$2" -bytes 16384 sha256 2>/dev/null); fi
  v=$(awk '$1=="sha256"{v=$NF} END{print v}' <<< "$out")
  if [[ -z $v ]]; then  # 老版本 openssl 不认 -bytes
    if (($1 > 1)); then out=$(openssl speed -seconds "$2" -multi "$1" sha256 2>/dev/null)
    else out=$(openssl speed -seconds "$2" sha256 2>/dev/null); fi
    v=$(awk '$1=="sha256"{v=$NF} END{print v}' <<< "$out")
  fi
  v=${v%k}
  [[ -n $v ]] && awk -v k="$v" 'BEGIN{printf "%.0f", k / 1024}'
}

cpu_bench() {
  local c mode tool cores model load s1="" sm="" a b st0 tt0 st1 tt1 steal unit
  cores=$(nproc 2>/dev/null || echo 1)
  model=$(awk -F: '/^(model name|Model Name|Hardware|cpu model)/{print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -s ' ' | sed 's/^ //')
  [[ -z $model ]] && model=$(lscpu 2>/dev/null | awk -F: '/^Model name/{print $2; exit}' | tr -s ' ' | sed 's/^ //')
  read -r load _ < /proc/loadavg
  title "CPU 性能测试"
  echo "  型号: ${model:-未知}"
  echo "  核心: ${cores} 个    当前负载: ${load}"
  if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c * 0.5)}'; then
    warn "服务器现在比较忙, 测出来会偏低"
  fi
  echo
  choose c "测试内容:" "单核 + 多核 (约 25 秒)" "只测单核 (10 秒)" "只测多核 (10 秒)" "返回" || return 0
  case $c in 单核*) mode=both ;; 只测单核*) mode=single ;; 只测多核*) mode=multi ;; *) return 0 ;; esac
  if bench_ensure_sysbench; then
    tool=sysbench; unit="分"
  elif command -v openssl >/dev/null 2>&1; then
    tool=openssl; unit="MB/s"
    warn "改用 openssl 粗测 (SHA256 计算速度), 得分和 sysbench 不能直接比"
  else
    warn "没有可用的测试工具"; return 1
  fi
  warn "测试期间 CPU 会跑满, 网站和机器人可能短暂变慢"
  confirm "开始测试?" y || return 0
  echo
  if [[ $mode != multi ]]; then
    printf '  测试单核 ...'
    if [[ $tool == sysbench ]]; then s1=$(bench_sysbench 1 10); else s1=$(bench_openssl 1 5); fi
    printf '\r\e[K'
  fi
  if [[ $mode != single ]]; then
    printf '  测试多核 (%s 线程) ...' "$cores"
    read -r tt0 st0 < <(cpu_steal_read)
    if [[ $tool == sysbench ]]; then sm=$(bench_sysbench "$cores" 10); else sm=$(bench_openssl "$cores" 5); fi
    read -r tt1 st1 < <(cpu_steal_read)
    printf '\r\e[K'
    steal=$(awk -v a=$((st1 - st0)) -v b=$((tt1 - tt0)) 'BEGIN{if (b > 0) printf "%.1f", a * 100 / b; else print 0}')
  fi
  if [[ -z $s1$sm ]]; then warn "测试没有输出结果"; return 1; fi
  echo "${B}测试结果${N} ${D}($tool)${N}"
  [[ -n $s1 ]] && { printf '  '; pad_w "单核得分" 12; printf '%s %s\n' "${G}${s1}${N}" "$unit"; }
  [[ -n $sm ]] && { printf '  '; pad_w "多核得分" 12; printf '%s %s %s\n' "${G}${sm}${N}" "$unit" "${D}(${cores} 线程)${N}"; }
  if [[ -n $s1 && -n $sm ]] && ((cores > 1)); then
    a=$(awk -v m="$sm" -v s="$s1" 'BEGIN{if (s > 0) printf "%.1f", m / s; else print 0}')
    printf '  '; pad_w "多核/单核" 12; printf '%s 倍 %s\n' "$a" "${D}(理想是 ${cores} 倍)${N}"
  fi
  if [[ -n $sm ]]; then
    printf '  '; pad_w "被宿主占用" 12; printf '%s%%' "$steal"
    if awk -v s="$steal" 'BEGIN{exit !(s >= 10)}'; then printf ' %s\n' "${Y}(偏高, 这台 VPS 可能超售)${N}"; else echo; fi
  fi
  echo
  if [[ $tool == sysbench ]]; then
    echo "  ${D}得分 = sysbench 每秒计算次数, 越高越好${N}"
  else
    echo "  ${D}得分 = 每秒 SHA256 计算量, 越高越好${N}"
  fi
  if [[ -n $s1 && -n $sm ]] && ((cores > 1)) && awk -v a="$a" -v c="$cores" 'BEGIN{exit !(a < c * 0.6)}'; then
    echo "  ${D}多核倍数明显低于核心数: 可能是超线程, 或核心被限速/超售${N}"
  fi
}

os_short() {
  local n v
  n=$( . /etc/os-release 2>/dev/null; echo "${ID:-linux}" ); v=$( . /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}" )
  case $n in
    debian) n=Debian ;; ubuntu) n=Ubuntu ;; centos) n=CentOS ;; rocky) n=Rocky ;; almalinux) n=Alma ;; rhel) n=RHEL ;; ol) n=Oracle ;;
  esac
  echo "$n${v:+ $v}"
}

pct_color() {  # 百分比 : >=90 红, >=80 黄, 其他正常
  if (($1 >= 90)); then printf '%s' "$R"; elif (($1 >= 80)); then printf '%s' "$Y"; else printf '%s' "$T"; fi
}

kv() { printf '%s%s%s %s' "$D" "$1" "$N" "$2"; }   # kv 标签 值 : 状态栏里的一项

dashboard() {
  local disk mem load n=0 f phps w=52
  disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')
  mem=$(free -m 2>/dev/null | awk '/^Mem:/{if ($2 > 0) printf "%d", ($2-$7)*100/$2; else print 0}')
  read -r load _ < /proc/loadavg
  echo
  printf '  %s╭%s╮%s\n' "$L" "$(rep ─ $w)" "$N"
  printf '  %s│%s  %sWSM%s %sServer Manager%s  %sv%s%s\e[%dG%s│%s\n' "$L" "$N" "$BD$B" "$N" "$T" "$N" "$D" "$WSM_VER" "$N" $((w + 4)) "$L" "$N"
  printf '  %s│%s  %s   %s\e[%dG%s│%s\n' "$L" "$N" "$(kv IP "$T${SERVER_IP:-未知}$N")" "$(kv 系统 "$T$(os_short)$N")" $((w + 4)) "$L" "$N"
  printf '  %s╰%s╯%s\n' "$L" "$(rep ─ $w)" "$N"
  printf '  %s   %s   %s\n' "$(kv SSH端口 "$T$(ssh_port_now)$N")" \
    "$(kv 密码登录 "$(ssh_nopass_now && echo "${G}已关闭" || echo "${Y}开启")$N")" \
    "$(kv BBR "$(bbr_state && echo "${G}开启" || echo "${D}未开启")$N")"
  printf '  %s   %s   %s\n' "$(kv 磁盘 "$(pct_color "${disk:-0}")${disk:-?}%$N")" \
    "$(kv 内存 "$(pct_color "${mem:-0}")${mem:-?}%$N")" "$(kv 负载 "$T$load$N")"
  if web_installed; then
    for f in "$META_DIR"/*.conf; do [[ -e $f ]] && n=$((n + 1)); done
    phps=$(php_installed | sort -V | tr '\n' ' '); phps=${phps% }
    printf '  %s   %s   %s\n' "$(kv Nginx "$(systemctl is-active --quiet nginx && echo "${G}● 运行中" || echo "${R}● 未运行")$N")" \
      "$(kv PHP "$T${phps:-无}$N")" "$(kv 站点 "$T$n 个$N")"
  else
    printf '  %s\n' "$(kv 网站环境 "${D}○ 未安装$N")"
  fi
}

web_dashboard() {
  local n=0 f phps logmb
  for f in "$META_DIR"/*.conf; do [[ -e $f ]] && n=$((n + 1)); done
  phps=$(php_installed | sort -V | tr '\n' ' '); phps=${phps% }
  printf '  %s   %s   %s\n' "$(kv Nginx "$(svc_state nginx)")" "$(kv 站点 "$T$n 个$N")" "$(kv PHP "$T${phps:-未安装}$N")"
  if unit_exists mariadb; then printf '  %s\n' "$(kv MariaDB "$(svc_state mariadb)")"; fi
  logmb=$(du -sm /var/log/nginx 2>/dev/null | awk '{print $1+0}')
  if (( ${logmb:-0} >= 1024 )); then
    echo "  ${Y}提示: 网站日志已占用 ${logmb}MB, 7 → 清理网站日志${N}"
  fi
  if (( $(swap_total) == 0 && $(free -m | awk '/^Mem:/{print $2+0}') <= 4096 )); then
    echo "  ${Y}提示: 没有 Swap, 内存吃紧时数据库容易被杀, 主菜单 6 → Swap 可创建${N}"
  fi
}

sec() { printf '\n  %s%s%s %s%s%s\n' "$S$BD" "$1" "$N" "$L" "$(rep ─ $((48 - $(disp_w "$1"))))" "$N"; }

main_menu() {
  local c
  SERVER_IP=$(public_ip)
  ui_load
  realip_ensure
  [[ -f $GUARD_CONF ]] && guard_ensure_global >/dev/null 2>&1
  web_installed && wsm_logrotate
  while true; do
    dashboard
    sec 服务器
    mitem 1 "系统信息" "配置 / 负载 / IP / 虚拟化"
    mitem 2 "SSH 安全" "端口 / 密钥 / 密码登录"
    mitem 3 "网络设置" "BBR / 禁 Ping / 端口转发"
    mitem 4 "网络检测" "网速 / 回程线路 / 解锁检测"
    mitem 5 "性能测试" "CPU / 内存 / 硬盘 IO"
    mitem 6 "系统维护" "服务 / Swap / 时区 / 告警 / 组件"
    sec 网站与应用
    if web_installed; then mitem 7 "网站面板 ›" "站点 / SSL / PHP / 数据库 / 备份"
    else mitem 7 "安装网站环境" "Nginx + PHP + MariaDB 一键安装"; fi
    mitem 8 "程序下载" "3x-ui / 哪吒 / WordPress …"
    mitem 9 "TG机器人" "添加 / 管理 Telegram 机器人"
    printf '\n  %s%s%s\n' "$L" "$(rep ─ 50)" "$N"
    printf '  %s%3s%s  %s%s%s\e[24G%s%s0%s  %s退出%s\n' "$BD$B" 10 "$N" "$T" "更新 / 卸载" "$N" "$BD$R" "" "$N" "$R" "$N"
    echo
    read -r -p "请选择: " c || exit 0
    case $c in
      1) (sys_info); pause ;;
      2) ssh_menu ;;
      3) menu_net ;;
      4) menu_check ;;
      5) menu_perf ;;
      6) menu_system ;;
      7) if web_installed; then menu_web; else web_install_flow && menu_web; fi ;;
      8) menu_store ;;
      9) tgbot_run ;;
      10) update_menu ;;
      0|q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ================================================================ TG机器人 (独立脚本 tggl, 这里只是入口)
# 机器人的安装管理在另一个仓库的 tg-bot-gl.sh 里, 它自带 tgbot 命令 (每次运行都拉最新版)
# wsm 只负责打开它, 两边互不依赖: 卸载 wsm 不影响机器人, 单独输入 tgbot 也能用
TGBOT_BIN=/usr/local/bin/tgbot
TGBOT_URL="https://raw.githubusercontent.com/chentiti888/tggl/main/tg-bot-gl.sh"

tgbot_run() {
  local tmp
  if [[ -x $TGBOT_BIN ]] && grep -q 'tgbot-launcher' "$TGBOT_BIN" 2>/dev/null; then
    TGBOT_FROM_WSM=1 bash "$TGBOT_BIN" "$@"
    return 0
  fi
  title "TG机器人"
  echo "  Telegram 机器人管理工具: 从仓库拉取机器人 → 装依赖 → 写入 Token/ID → 启动并开机自启"
  echo "  ${D}独立的脚本 (chentiti888/tggl), 打开时不安装任何软件; 以后也可以直接输入 tgbot 打开${N}"
  echo
  confirm "下载并打开?" y || return 0
  tmp=$(mktemp)
  if curl -fsSL --retry 2 --max-time 30 -H 'Cache-Control: no-cache' "$TGBOT_URL?t=$(date +%s)" -o "$tmp" 2>/dev/null \
      && head -n1 "$tmp" | grep -q bash && bash -n "$tmp" 2>/dev/null; then
    TGBOT_FROM_WSM=1 bash "$tmp" "$@"
  else
    err "下载失败, 请检查网络: $TGBOT_URL"; pause
  fi
  rm -f "$tmp"
  return 0
}

web_install_flow() {
  title "安装网站环境"
  echo "  将安装: ${T}Nginx${N}、${T}certbot${N} (证书)、${T}PHP${N} (可选版本)、${T}MariaDB${N} (可选)"
  echo "  装好后会开机自启; 以后不需要了可以在 网站面板 → 卸载网站环境 里完整卸载"
  echo
  confirm "开始安装?" y || return 1
  (cmd_install) || true
  web_installed || { err "网站环境没有安装成功"; pause; return 1; }
  pause
}

menu_web() {
  local c
  while true; do
    web_installed || return 0
    title "网站面板"
    web_dashboard
    echo
    mitem 1 "网站管理" "新建 / 设置 / 删除 / 统计"
    mitem 2 "SSL 证书" "申请 / 续期"
    mitem 3 "PHP 管理" "版本 / 扩展 / 参数"
    mitem 4 "数据库" "创建 / 备份 / phpMyAdmin"
    mitem 5 "备份与搬家" "全量 / 异地 / 定时"
    mitem 6 "安全防护" "源站 / CDN / 防CC / 防篡改"
    mitem 7 "Nginx 维护" "重载 / 错误日志 / 清理日志"
    mitem 8 "卸载网站环境" "完整卸载 Nginx / PHP / MariaDB"
    mback
    read -r -p "请选择: " c || return 0
    case $c in
      1) menu_sites ;;
      2) menu_ssl ;;
      3) menu_php ;;
      4) menu_db ;;
      5) menu_backup ;;
      6) menu_security ;;
      7) menu_nginx ;;
      8) (web_uninstall); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_nginx() {
  local c
  while true; do
    title "Nginx 维护"
    mitem 1 "检测并重载配置"
    mitem 2 "查看全局错误日志" "最近 50 行"
    mitem 3 "清理网站日志"
    mback
    read -r -p "请选择: " c || return 0
    case $c in
      1) nginx -t && systemctl reload nginx && info "配置正确, 已重载"; pause ;;
      2) tail -n 50 /var/log/nginx/error.log 2>/dev/null || warn "暂无日志"; pause ;;
      3) (logs_clean); pause ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

menu_system() {
  local c
  while true; do
    title "系统维护"
    echo "  $(kv Swap "$T$(swap_state)$N")   $(kv 时区 "$T$(tz_get)$N")   $(kv 告警 "$(tg_ready 2>/dev/null && [[ -f $TG_CRON ]] && echo "${G}开" || echo "${D}关")$N")"
    echo
    mitem 1 "服务管理" "启停 / 重启 / 开机自启"
    mitem 2 "磁盘与内存" "使用情况"
    mitem 3 "Swap 虚拟内存" "创建 / 删除"
    mitem 4 "服务器时区" "定时任务按它执行"
    mitem 5 "Telegram 告警" "服务挂了 / 磁盘满 / 证书到期"
    mitem 6 "已安装组件" "wsm 装过的软件, 可卸载"
    mback
    read -r -p "请选择: " c || return 0
    case $c in
      1) (manage_service) ;;
      2) df -h /; echo; free -h; web_installed && du -sh "$WWW_ROOT" "$BACKUP_DIR" 2>/dev/null; pause ;;
      3) swap_menu ;;
      4) (tz_menu); pause ;;
      5) tg_menu ;;
      6) comp_menu ;;
      0|q) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ================================================================ 已安装组件 / 卸载
# 基础系统工具: 就算是 wsm 装的也不卸载 (很多程序都依赖它们)
COMP_KEEP=" curl ca-certificates openssl cron cronie unzip tar gzip epel-release dnf-plugins-core software-properties-common apt-transport-https lsb-release python3 iptables e2fsprogs "
COMP_TOOLS="sysbench traceroute"

comp_list() {  # 输出: 包名<TAB>用途<TAB>日期  (只列现在还装着的)
  local p f d t
  local -A seen=()
  if [[ -f $LEDGER ]]; then
    while IFS=$'\t' read -r p f d; do
      [[ -n $p ]] || continue
      if [[ $p == @rclone ]]; then [[ -f /usr/bin/rclone ]] || { ledger_del "$p"; continue; }
      else pkg_has "$p" || { ledger_del "$p"; continue; }; fi
      [[ $COMP_KEEP == *" $p "* ]] && continue
      seen[$p]=1; printf '%s\t%s\t%s\n' "$p" "$f" "$d"
    done < "$LEDGER"
  fi
  # 记录功能之前就装上的 (老版本 wsm / 原 SSH 小工具装的)
  for t in sysbench:性能测试 traceroute:回程线路检测 iptables-persistent:端口转发; do
    p=${t%%:*}
    [[ -z ${seen[$p]:-} ]] && pkg_has "$p" && printf '%s\t%s\t%s\n' "$p" "${t#*:} (之前安装)" "-"
  done
  return 0
}

comp_remove() {
  local p=$1 f=${2:-}
  if [[ $f == 网站环境* ]]; then
    warn "$p 属于网站环境, 请到 网站面板 → 卸载网站环境 (或 PHP 管理 → 卸载 PHP 版本)"; return 1
  fi
  case $p in
    @rclone)
      [[ -f $FB_CONF ]] && warn "异地备份在用 rclone, 卸载后异地备份会失败"
      confirm "卸载 rclone?" n || return 0
      rm -f /usr/bin/rclone /usr/local/share/man/man1/rclone.1; ledger_del @rclone; info "已卸载 rclone (配置 /root/.config/rclone 保留)"; return 0 ;;
    iptables-persistent|netfilter-persistent)
      fwd_collect 2>/dev/null
      ((${#FWD_RULES[@]})) && warn "还有 ${#FWD_RULES[@]} 条端口转发规则, 卸载后重启服务器这些规则会丢失"
      confirm "卸载 iptables-persistent (开机恢复规则的服务)?" n || return 0
      systemctl disable --now netfilter-persistent >/dev/null 2>&1
      pkg_remove iptables-persistent netfilter-persistent >/dev/null 2>&1
      ledger_del iptables-persistent; ledger_del netfilter-persistent
      info "已卸载 iptables-persistent"; return 0 ;;
    mariadb-server)
      warn "卸载 MariaDB 后, 依赖它的网站会无法连接数据库 (数据文件仍保留在 /var/lib/mysql)"
      confirm_typed "确认卸载 MariaDB" || return 0
      systemctl stop mariadb >/dev/null 2>&1 ;;
    *) confirm "卸载 $p${f:+ ($f)}?" n || return 0 ;;
  esac
  pkg_remove "$p" >/dev/null 2>&1
  if pkg_has "$p"; then err "$p 卸载失败"; return 1; fi
  ledger_del "$p"; info "已卸载 $p"
}

comp_menu() {
  local c i p f d n
  local -a rows=()
  while true; do
    title "已安装组件"
    mapfile -t rows < <(comp_list)
    if ((${#rows[@]} == 0)); then
      echo "  ${D}wsm 还没有安装过任何软件, 系统是干净的${N}"
    else
      printf '  %s     ' "$D"; pad_w "软件包" 26; pad_w "用途" 26; printf '安装日期%s\n' "$N"
      for i in "${!rows[@]}"; do
        IFS=$'\t' read -r p f d <<< "${rows[i]}"
        printf '  %s%3d%s  %s' "$BD$B" $((i + 1)) "$N" "$T"; pad_w "${p#@}" 26; printf '%s%s' "$N" "$D"; pad_w "${f:-程序下载}" 26; printf '%s%s\n' "$d" "$N"
      done
    fi
    echo
    echo "  ${D}说明: 只列 wsm 装上去的; 网站环境请到 网站面板 → 卸载网站环境${N}"
    echo "  ${D}      程序下载 里的扩展程序 (3x-ui / 哪吒 等) 在各自菜单里卸载${N}"
    echo
    ((${#rows[@]})) && mitem t "清理测试工具" "$COMP_TOOLS"
    mback
    read -r -p "输入序号卸载: " c || return 0
    case $c in
      0|q|'') return 0 ;;
      t|T)
        n=0
        for p in $COMP_TOOLS; do
          pkg_has "$p" || continue
          pkg_remove "$p" >/dev/null 2>&1 && { ledger_del "$p"; info "已卸载 $p"; n=$((n + 1)); }
        done
        ((n)) || info "没有需要清理的测试工具"; pause ;;
      *)
        if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#rows[@]})); then
          IFS=$'\t' read -r p f d <<< "${rows[c - 1]}"
          (comp_remove "$p" "$f"); pause
        else warn "无效选择"; fi ;;
    esac
  done
}

# ---------------- 卸载网站环境
web_uninstall() {
  local n=0 f p dbs="" pk
  local -a pkgs=() svcs=()
  title "卸载网站环境"
  for f in "$META_DIR"/*.conf; do [[ -e $f ]] && n=$((n + 1)); done
  echo "  将停止并卸载: Nginx、certbot、所有 PHP 版本$(unit_exists mariadb && echo "、MariaDB (单独确认)")"
  echo "  同时清理: wsm 的网站配置、证书自动续期、源站保护、防 CC 规则、CDN 定时任务"
  echo "  不会动: 服务器工具的设置 (SSH / BBR / 端口转发 / Swap)、程序下载里的独立软件 (3x-ui / 哪吒 等)"
  echo
  if ((n)); then
    warn "现在有 ${n} 个站点, 卸载后这些网站全部无法访问"
    echo "  建议先做一次全量备份: 网站面板 → 备份与搬家 → 全量备份"
  fi
  confirm_typed "确认卸载网站环境" || { info "已取消, 没有改动"; return 0; }

  # 1. 先关掉依赖 Nginx 的功能
  if cfw_active || [[ -f $CFW_UNIT ]]; then cfw_disable >/dev/null 2>&1; fi
  systemctl disable --now wsm-cf-firewall >/dev/null 2>&1; rm -f "$CFW_UNIT"; systemctl daemon-reload
  rm -f /etc/cron.d/wsm-certbot "$CFW_CRON" /etc/logrotate.d/wsm
  [[ -f $CRON_TASKS ]] && sed -i '/ backup-site \| backup-db /d' "$CRON_TASKS"   # 网站/数据库备份任务 (自定义命令保留)
  # 2. 停服务 (含网站应用自己的后台服务, 如 Xboard 队列)
  while read -r f; do
    [[ -n $f ]] || continue
    p=$(app_of_site "$f")
    [[ -n $p ]] && ! app_soft "$p" && svcs+=($(app_call "$p" units "$f"))
  done < <(list_site_names)
  for p in ${svcs[@]+"${svcs[@]}"}; do
    systemctl disable --now "$p" >/dev/null 2>&1; rm -f "/etc/systemd/system/$p" "/etc/systemd/system/$p.service"
  done
  systemctl daemon-reload >/dev/null 2>&1
  svcs=(nginx)
  for p in $(php_installed); do svcs+=("$(php_svc "$p")"); done
  for p in "${svcs[@]}"; do systemctl disable --now "$p" >/dev/null 2>&1; done
  # 3. 要卸载的包: 安装记录里属于网站环境的; 没有记录 (老版本装的) 就按默认清单
  if [[ -f $LEDGER ]]; then
    while IFS=$'\t' read -r p f _; do
      [[ $f == 网站环境* && $COMP_KEEP != *" $p "* ]] && pkgs+=("$p")
    done < "$LEDGER"
  fi
  if ((${#pkgs[@]} == 0)); then
    pkgs=(nginx certbot)
    pkg_has nginx-common && pkgs+=(nginx-common)
    pkg_has python3-certbot-dns-cloudflare && pkgs+=(python3-certbot-dns-cloudflare)
  fi
  info "正在卸载 Nginx / certbot / PHP ..."
  if [[ $PM == apt ]]; then
    pkg_has nginx-common && pkgs+=(nginx-common)   # 依赖包也要 purge, 不然重装时不会重新生成 nginx.conf
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}" >/dev/null 2>&1
    mapfile -t pk < <(dpkg-query -W -f='${Package} ${Status}\n' 'php*' 2>/dev/null | awk '/install ok installed/{print $1}')
    ((${#pk[@]})) && DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pk[@]}" >/dev/null 2>&1
    # PHP 软件源 (wsm 安装 PHP 时加的)
    if [[ $OS_ID == ubuntu ]]; then
      ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi ondrej && add-apt-repository -y --remove ppa:ondrej/php >/dev/null 2>&1
    else
      rm -f /etc/apt/sources.list.d/php-sury.list
      pkg_has debsuryorg-archive-keyring && dpkg -r debsuryorg-archive-keyring >/dev/null 2>&1
    fi
  else
    dnf remove -y "${pkgs[@]}" >/dev/null 2>&1
    dnf remove -y 'php*-php-*' >/dev/null 2>&1
  fi
  for p in "${pkgs[@]}" "${pk[@]+"${pk[@]}"}"; do ledger_del "$p"; done
  [[ -f $LEDGER ]] && awk -F'\t' '$2 !~ /^网站环境/' "$LEDGER" > "$LEDGER.tmp" && mv -f "$LEDGER.tmp" "$LEDGER"
  rm -rf /etc/nginx /var/log/nginx "$ACME_ROOT" "$META_DIR" "$CERT_DIR" "$AUTH_DIR" 2>/dev/null
  rm -f "$CFW_IPS" "$CDN_ALLOW" 2>/dev/null
  if unit_exists mariadb; then
    echo
    dbs=$(mysql -N -e 'SHOW DATABASES' 2>/dev/null | grep -vxE 'information_schema|performance_schema|mysql|sys' | paste -sd' ' -)
    echo "  MariaDB 里的数据库: ${dbs:-无}"
    if confirm "同时卸载 MariaDB?" n; then
      systemctl disable --now mariadb >/dev/null 2>&1
      pkg_remove mariadb-server mariadb-client >/dev/null 2>&1; ledger_del mariadb-server
      if [[ -d /var/lib/mysql ]]; then
        warn "数据库文件还在 /var/lib/mysql"
        confirm_typed "删除全部数据库文件 (不可恢复)" && rm -rf /var/lib/mysql && info "已删除数据库文件"
      fi
    fi
  fi
  [[ $PM == apt ]] && DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1
  if [[ -d $WWW_ROOT ]]; then
    echo
    echo "  网站文件在 $WWW_ROOT ($(du -sh "$WWW_ROOT" 2>/dev/null | cut -f1)), 备份在 $BACKUP_DIR"
    confirm_typed "删除网站文件 (不可恢复)" && rm -rf "$WWW_ROOT" && rmdir /www 2>/dev/null && info "已删除网站文件"
  fi
  echo
  info "网站环境已卸载"
  [[ -d $BACKUP_DIR ]] && echo "  备份文件保留在 $BACKUP_DIR (不需要可以手动删除)"
}

# ---------------- 卸载 wsm 本身
wsm_uninstall() {
  local keep_ssh=1 c
  title "卸载 wsm"
  echo "  将删除: wsm / ssb 命令、wsm 的配置 ($WSM_DIR)、wsm 的定时任务 (含 计划任务 里添加的) 和日志配置"
  if web_installed; then
    warn "网站环境还装着。只卸载 wsm 的话, 网站照常运行, 但证书自动续期、定时备份、告警等会停止"
    choose c "怎么处理网站环境?" "先完整卸载网站环境, 再卸载 wsm" "保留网站环境, 只卸载 wsm" || return 0
    if [[ $c == 先* ]]; then web_uninstall; web_installed && { err "网站环境没有卸载完成, 已停止"; return 1; }; fi
  fi
  echo
  echo "  服务器工具改过的系统设置默认保留 (SSH 端口和密钥登录 / BBR / 禁 Ping / 端口转发 / Swap)"
  if [[ -f $SSH_DROPIN ]] || grep -q '^# wsm-ssh begin' "$SSH_MAIN" 2>/dev/null; then
    confirm "SSH 设置还原成系统默认? (端口恢复 22、允许密码登录; 选 n 保留现在的设置)" n && keep_ssh=0
  fi
  confirm_typed "确认卸载 wsm" || { info "已取消"; return 0; }
  if ((keep_ssh == 0)); then
    ssh_apply 0 "" && info "SSH 已还原 (现在端口 $(ssh_port_now))"
  fi
  rm -f /etc/cron.d/wsm-* /etc/logrotate.d/wsm
  if cfw_active || [[ -f $CFW_UNIT ]]; then cfw_disable >/dev/null 2>&1; fi
  rm -rf "$WSM_DIR"
  rm -f /var/log/wsm-*.log
  [[ -L $WSM_ALIAS ]] && rm -f "$WSM_ALIAS"
  rm -rf "$SELF_BAK" 2>/dev/null
  rm -f "$WSM_BIN"
  info "wsm 已卸载, 感谢使用"
  exit 0
}

usage() {
  cat <<EOF
wsm v$WSM_VER - Server Manager   (ssb 是同一个命令)

  wsm                               交互菜单 (推荐)
  ── 服务器工具 (不需要网站环境) ──
  wsm sysinfo                       系统信息
  wsm ssh                           SSH 安全 (密钥登录/导入公钥/关闭密码/改端口)
  wsm keys                          导入公钥 (从仓库拉取 / 粘贴)
  wsm key-download [私钥文件]       下载服务器上的私钥
  wsm bbr | noping                  BBR 加速 / 禁 Ping (开关)
  wsm fwd                           端口转发 (TCP/UDP)
  wsm speedtest                     网速测试 (本地 延迟/下载/上传)
  wsm route | unlock                回程线路检测 / 流媒体与 AI 解锁检测
  wsm bench                         性能测试 (CPU 占用/CPU/内存/硬盘)
  wsm components                    已安装组件 (查看/卸载 wsm 装过的软件)
  wsm tgbot                         TG机器人管理 (独立脚本, 也可以直接输入 tgbot)
  wsm uninstall                     卸载 wsm
  ── 网站 ──
  wsm install                       一键安装网站环境 (Nginx/PHP/MariaDB/certbot)
  wsm web                           网站面板
  wsm web-uninstall                 卸载网站环境
  wsm add-php|add-static [域名]     新建站点
  wsm app list                      扩展程序模块列表 (及各自的站点/安装状态)
  wsm app add [模块|网址|文件]      添加模块 (不写=从仓库选)
  wsm app remove|update <模块>      删除 / 更新模块
  wsm app <模块> install [域名]     安装软件 / 部署新站点 (如 wsm app wordpress install)
  wsm app <模块> uninstall          卸载独立软件 (如 wsm app xui uninstall)
  wsm app <模块> [参数...]          模块自己的命令 (如 wsm app xboard info 域名)
  wsm guard [域名] [on|off]         防 CC / 防恶意 bot
  wsm cf-firewall [on|off|refresh]  源站保护: 80/443 只允许 CDN (默认关闭)
  wsm cdn                           CDN 设置 (真实IP开关 / 添加其他 CDN)
  wsm realip [on|off]               CDN 真实 IP 开关 (默认开启)
  wsm tg                            Telegram 告警设置
  wsm icons nerd|plain              菜单图标: Nerd 字体图标 / 普通符号
  wsm timezone [Asia/Shanghai]      查看 / 设置服务器时区
  wsm add-proxy [域名] [后端URL]    新建反向代理
  wsm update [-y]                   从 Git 仓库更新脚本 (-y 不确认)
  wsm rollback                      回滚到上一个版本
  wsm stats [域名] [1|y|7|30|all]   访问统计 (不写域名=全站概览)
  wsm cpu-bench                     CPU 性能测试 (单核/多核)
  wsm add-redirect [域名] [目标]    新建域名重定向
  wsm ssl [域名]                    申请/更换证书
  wsm list                          站点列表
  wsm certs                         证书总览
  wsm renew                         立即续期全部证书
  wsm backup-site [域名] [份数]     备份网站
  wsm backup-db [库名|--all] [份数] 备份数据库
  wsm backup-all                    全量备份 (网站+数据库+配置), 并上传异地
  wsm restore-all [文件]            从全量备份还原 / 搬家到本机
  wsm tamper-lock|tamper-unlock [域名]      防篡改: 锁定/解锁网站文件
  wsm tamper-check [域名] [ask|report|restore]  防篡改: 完整性检测/还原
  wsm db-create [库名]              创建数据库
  wsm php-install [版本]            安装 PHP
  wsm del [域名]                    删除站点
  wsm status                        服务状态
  wsm store                         程序下载 (交互)
  wsm app-list                      软件列表和安装状态
  wsm app-install|app-uninstall <ID>  安装/卸载软件 (ID 见 app-list)
EOF
}

# ================================================================ 入口
[[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != "$0" ]] && return 0

[[ ${1:-} == version || ${1:-} == -v || ${1:-} == --version ]] && { echo "$WSM_VER"; exit 0; }
need_root
detect_os
web_installed && mkdir -p "$META_DIR" "$CERT_DIR" "$AUTH_DIR"
[[ ${1:-menu} == menu ]] && self_install   # 只装 wsm 命令本身, 不装任何软件
apps_load

# 这些命令需要网站环境 (没装会提示一键安装)
case ${1:-} in
  add-php|add-static|add-proxy|add-redirect|ssl|del|list|certs|renew|backup-site|guard|cf-firewall|cf-refresh|cdn|realip|stats|tamper-*)
    need_web || exit 1 ;;
esac

case ${1:-menu} in
  menu)         [[ -d $APPS_DIR || -d $META_DIR ]] && apps_migrate_once; main_menu ;;
  sysinfo)      sys_info ;;
  speedtest)    speed_quick ;;
  tgbot)        shift; tgbot_run "$@" ;;
  bbr)          bbr_menu ;;
  noping)       ping_menu ;;
  fwd)          forward_menu ;;
  route)        route_check ;;
  unlock)       unlock_check ;;
  bench)        menu_perf ;;
  keys)         import_keys ;;
  key-download) key_download "${2:-}" ;;
  components)   comp_menu ;;
  web)          if web_installed; then menu_web; else web_install_flow && menu_web; fi ;;
  uninstall)    wsm_uninstall ;;
  web-uninstall) web_installed && web_uninstall ;;
  icons)        ui_icon_set "${2:-}" ;;
  timezone)     if [[ -n ${2:-} ]]; then tz_set "$2"; else echo "时区: $(tz_get)  时间: $(tz_now)"; fi ;;
  install)      web_install_flow ;;   # 先说明要装什么, 确认后才开始
  php-install)  install_php "${2:-}" ;;
  db-install)   install_db ;;
  db-create)    db_create "${2:-}" ;;
  add-php)      add_site php "${2:-}" ;;
  add-static)   add_site static "${2:-}" ;;
  app)          shift; apps_migrate_once; app_cli "$@" ;;
  add-wp)       app_cli wordpress install "${2:-}" ;;           # 旧命令, 兼容保留
  add-xboard)   app_cli xboard install "${2:-}" ;;
  xboard-update|xboard-info|xboard-domains) app_cli xboard "${1#xboard-}" "${2:-}" "${3:-}" "${4:-}" ;;
  update)       update_run "${2:-}" ;;
  rollback)     update_rollback ;;
  stats)        stats_cli "${2:-}" "${3:-1}" ;;
  cpu-bench)    cpu_bench ;;
  guard)        guard_cli "${2:-}" "${3:-}" ;;
  cf-firewall)  cfw_cli "${2:-}" ;;
  cf-refresh)   cf_refresh_all ;;
  cdn)          cdn_menu ;;
  realip)       case ${2:-} in on|off) realip_set "$2" ;; *) echo "CDN 真实IP: $(realip_state)" ;; esac ;;
  monitor)      mon_check ;;
  tg)           tg_menu ;;
  ssh)          ssh_menu ;;
  add-proxy)    add_site proxy "${2:-}" "${3:-}" ;;
  add-redirect) add_site redirect "${2:-}" "${3:-}" ;;
  ssl)          use_site "${2:-}" && ssl_pick_method "$SITE" ;;
  del)          del_site "${2:-}" ;;
  list)         list_sites ;;
  certs)        list_certs ;;
  renew)        certbot renew --deploy-hook "systemctl reload nginx" ;;
  backup-site)  backup_site "${2:-}" "${3:-7}" ;;
  backup-db)    backup_db "${2:-}" "${3:-7}" ;;
  backup-all)   fb_run "${2:-}" ;;
  restore-all)  fb_restore "${2:-}" ;;
  tamper-lock)  use_site "${2:-}" && tamper_lock "$SITE" ;;
  tamper-unlock) use_site "${2:-}" && tamper_unlock "$SITE" ;;
  tamper-check) tamper_check "${2:-}" "${3:-ask}" ;;
  status)       dashboard ;;
  store)        menu_store ;;
  app-list)     app_list ;;
  app-install)  app_install "${2:-}" ;;
  app-uninstall) app_uninstall "${2:-}" ;;
  version|-v|--version) echo "$WSM_VER" ;;
  help|-h|--help) usage ;;
  *)            usage ;;
esac

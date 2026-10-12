# wsm 程序模块: Xboard 面板
# shellcheck shell=bash disable=SC2034
# 无容器部署: PHP-FPM + MariaDB + Redis + systemd 队列 + cron
# 本文件由 wsm 载入使用 (程序下载 → 扩展程序 → 添加模块), 不能单独运行。
APP_ID=xboard
APP_NAME="Xboard 面板"
APP_DESC="机场面板, 自动建站+数据库+Redis+队列+定时任务"
APP_VER=1.1

XB_REPO_HTTPS=${XB_REPO_HTTPS:-https://github.com/chentiti888/xboard.git}
XB_REPO_SSH=${XB_REPO_SSH:-git@github.com:chentiti888/xboard.git}
XB_DATA=$APPS_DATA/xboard

XB_REPO_HTTPS=${XB_REPO_HTTPS:-https://github.com/chentiti888/xboard.git}
XB_REPO_SSH=${XB_REPO_SSH:-git@github.com:chentiti888/xboard.git}

xb_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_' | cut -c1-30; }

xb_env_set() {  # xb_env_set 文件 键 值
  local v=${3//\\/\\\\}; v=${v//&/\\&}; v=${v//|/\\|}
  if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$v|" "$1"
  else printf '%s=%s\n' "$2" "$3" >> "$1"; fi
}

xb_git() { GIT_TERMINAL_PROMPT=0 git -c safe.directory="$1" -C "$1" "${@:2}"; }

xb_remote_head() {  # 仓库最新提交 (先 HTTPS, 再 SSH)
  local h
  h=$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "${XB_REPO:-$XB_REPO_HTTPS}" HEAD 2>/dev/null | cut -c1-7)
  [[ -z $h && -z ${XB_REPO:-} ]] && h=$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "$XB_REPO_SSH" HEAD 2>/dev/null | cut -c1-7)
  echo "$h"
}

xb_commit_info() { xb_git "$1" log -1 --format='%h  %cd  %s' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null; }

xb_check_update() {  # xb_check_update 站点 : 对比本地和仓库, 有新提交就提示更新
  use_site "${1:-}" || return 1
  local app=${ROOT%/public} n
  [[ -d $app/.git ]] || { err "$app 不是 git 部署的, 无法检查"; return 1; }
  info "检查仓库更新 ..."
  xb_git "$app" fetch -q origin main || { err "连接仓库失败 (检查网络或仓库权限)"; return 1; }
  echo "  当前版本: $(xb_commit_info "$app")"
  n=$(xb_git "$app" rev-list --count HEAD..origin/main 2>/dev/null)
  if [[ ${n:-0} == 0 ]]; then info "已经是最新版"; return 0; fi
  echo "  仓库有 ${G}$n${N} 个新提交:"
  xb_git "$app" log --format='    %h  %cd  %s' --date=format:'%m-%d %H:%M' HEAD..origin/main | head -10
  ((n > 10)) && echo "    ..."
  confirm "现在更新? (数据库和 .env 不受影响)" y && XB_NOCONFIRM=1 xb_update "$DOMAIN"
}

xb_safe_dir() {
  git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$1" \
    || git config --global --add safe.directory "$1"
}

xb_composer() {  # xb_composer 程序目录 PHP命令
  (cd "$1" && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
    "$2" "$(command -v composer)" install --no-dev -o -q)
}

xb_abort() {
  [[ -n ${XB_APP:-} ]] && rm -rf -- "$XB_APP"
  [[ -n ${XB_DB:-} ]] && mysql -e "DROP DATABASE IF EXISTS \`$XB_DB\`; DROP USER IF EXISTS '$XB_DB'@'localhost';" 2>/dev/null
  die "$1 (已清理)"
}

xb_pick_php() {  # -> XB_PHP (Xboard 需要 PHP 8.2+)
  local x; local -a list=()
  for x in $(php_installed | sort -V); do
    awk -v v="$x" 'BEGIN { exit !(v + 0 >= 8.2) }' && list+=("$x")
  done
  if (( ${#list[@]} == 0 )); then
    warn "Xboard 需要 PHP 8.2 以上, 先安装 PHP 8.2"
    install_php 8.2 || return 1
    XB_PHP=8.2
  elif (( ${#list[@]} == 1 )); then XB_PHP=${list[0]}
  else choose XB_PHP "选择 PHP 版本 (Xboard 需要 8.2+):" "${list[@]}" || return 1
  fi
}

xb_php_ready() {  # xb_php_ready PHP版本: 补齐扩展, 放开 Xboard 需要的函数
  local v=$1 pv e f cur new
  pv=$(php_pkgver "$v")
  for e in mysql curl gd mbstring xml zip intl bcmath redis; do
    if [[ $PM == apt ]]; then pkg_install "php$v-$e" >/dev/null 2>&1 || true
    else
      case $e in mysql) e=mysqlnd ;; redis) e='pecl-redis*' ;; esac
      pkg_install "php${pv}-php-$e" >/dev/null 2>&1 || pkg_install "php${pv}-php-pecl-$e" >/dev/null 2>&1 || true
    fi
  done
  f=$(php_ini_file "$v")
  if [[ -f $f ]] && grep -q '^disable_functions' "$f"; then
    cur=$(grep -m1 '^disable_functions' "$f" | sed -E 's/^disable_functions *= *//; s/"//g')
    new=$(printf '%s' "$cur" | tr ',' '\n' | grep -vxE 'putenv|proc_open|pcntl_alarm|pcntl_signal' | paste -sd, -)
    sed -i '/^disable_functions/d' "$f"
    if [[ -n $new ]]; then ini_set_kv "$f" disable_functions "$new"; fi
  fi
  systemctl restart "$(php_svc "$v")" >/dev/null 2>&1 || true
  return 0
}

xb_services() {  # xb_services 域名 程序目录 PHP版本
  local k php; k=$(xb_slug "$1"); php=$(command -v "$(php_bin "$3")" || php_bin "$3")
  cat > "/etc/systemd/system/xboard-$k.service" <<EOF
[Unit]
Description=Xboard queue ($1)
After=network.target

[Service]
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$2
ExecStart=$php artisan horizon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  printf '* * * * * %s cd %s && %s artisan schedule:run >> /dev/null 2>&1\n' "$WEB_USER" "$2" "$php" > "/etc/cron.d/xboard-$k"
  chmod 644 "/etc/cron.d/xboard-$k"
  systemctl daemon-reload
  systemctl enable --now "xboard-$k" >/dev/null 2>&1 || warn "队列服务启动失败, 请查看: systemctl status xboard-$k"
}

xb_install() {  # xb_install [域名]
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} app root v php email pw dbn dbp k out h secure scheme
  title "一键部署 Xboard"
  command -v git >/dev/null 2>&1 || pkg_install git || die "git 安装失败"
  if ! command -v mysql >/dev/null 2>&1; then
    confirm "Xboard 需要数据库, 现在安装 MariaDB 吗?" y || return 1
    install_db || return 1
  fi
  if ! unit_exists redis-server && ! unit_exists redis; then
    confirm "Xboard 需要 Redis, 现在安装吗?" y || return 1
    install_redis || return 1
  fi
  install_composer || return 1
  ask domain "① 网站域名 (如 panel.example.com)" || return 1
  valid_domain "$domain" || die "域名格式不正确: $domain"
  [[ -f $(meta_file "$domain") ]] && die "站点已存在: $domain"
  v=$(domain_used "$domain") && die "域名 $domain 已被站点 $v 使用"
  app=$WWW_ROOT/$domain; root=$app/public
  safe_root "$app" || die "网站目录不合法: $app"
  if [[ -d $app && -n $(ls -A "$app" 2>/dev/null) ]]; then
    die "目录 $app 里已有文件, 请换一个域名或先清空该目录"
  fi
  read -r -p "② 管理员邮箱 [admin@$domain]: " email || return 1
  email=${email:-admin@$domain}
  [[ $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "邮箱格式不正确"
  xb_pick_php || return 1
  v=$XB_PHP; php=$(php_bin "$v")

  mkdir -p "$app"; XB_APP=$app
  info "检查仓库最新版本 ..."
  k=$(xb_remote_head)
  [[ -n $k ]] && echo "  仓库最新提交: ${G}$k${N} (下面部署的就是这个版本)"
  info "下载 Xboard 源码 ..."
  if [[ -n ${XB_REPO:-} ]]; then
    GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$XB_REPO" "$app"
  else
    GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$XB_REPO_HTTPS" "$app" 2>/dev/null \
      || GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$XB_REPO_SSH" "$app"
  fi || xb_abort "下载失败 (仓库是私有的话, 服务器需要配置 GitHub SSH 密钥)"
  [[ -f $app/artisan ]] || xb_abort "源码不完整"
  xb_safe_dir "$app"
  echo "  已下载: $(xb_commit_info "$app")"
  xb_php_ready "$v"
  info "安装依赖 (需要几分钟, 请耐心等待) ..."
  xb_composer "$app" "$php" || xb_abort "安装依赖失败"

  k=$(printf '%s' "$domain" | tr -c 'A-Za-z0-9' '_' | cut -c1-12)
  dbn="xb_${k}_$(openssl rand -hex 2)"
  dbp=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  mysql -e "CREATE DATABASE \`$dbn\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
CREATE USER '$dbn'@'localhost' IDENTIFIED BY '$dbp'; \
GRANT ALL PRIVILEGES ON \`$dbn\`.* TO '$dbn'@'localhost'; FLUSH PRIVILEGES;" \
    || xb_abort "创建数据库失败"
  XB_DB=$dbn

  cp "$app/.env.example" "$app/.env"
  xb_env_set "$app/.env" APP_KEY "base64:$(openssl rand -base64 32)"
  xb_env_set "$app/.env" DB_CONNECTION mysql
  xb_env_set "$app/.env" DB_HOST 127.0.0.1
  xb_env_set "$app/.env" DB_PORT 3306
  xb_env_set "$app/.env" DB_DATABASE "$dbn"
  xb_env_set "$app/.env" DB_USERNAME "$dbn"
  xb_env_set "$app/.env" DB_PASSWORD "$dbp"
  chown -R "$WEB_USER:$WEB_USER" "$app"
  chmod 640 "$app/.env"

  info "导入数据库 ..."
  out=$(cd "$app" && runuser -u "$WEB_USER" -- env CACHE_DRIVER=array QUEUE_CONNECTION=sync SESSION_DRIVER=array \
        "$php" artisan migrate --force 2>&1) || { printf '%s\n' "$out" | tail -8; xb_abort "导入数据库失败"; }
  h=$(mktemp --suffix=.php); chmod 644 "$h"
  cat > "$h" <<'PHP'
<?php
$base = $argv[1];
require $base . '/vendor/autoload.php';
$app = require $base . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$pw = \App\Utils\Helper::guid(false);
if (!\App\Console\Commands\XboardInstall::registerAdmin($argv[2], $pw)) { fwrite(STDERR, "admin fail\n"); exit(1); }
\App\Services\Plugin\PluginManager::installDefaultPlugins();
echo "ADMINPW=$pw\n";
echo "SECURE=" . hash('crc32b', config('app.key')) . "\n";
PHP
  out=$(cd "$app" && runuser -u "$WEB_USER" -- env CACHE_DRIVER=array QUEUE_CONNECTION=sync SESSION_DRIVER=array \
        "$php" "$h" "$app" "$email" 2>&1); rm -f "$h"
  pw=$(printf '%s\n' "$out" | sed -n 's/^ADMINPW=//p')
  secure=$(printf '%s\n' "$out" | sed -n 's/^SECURE=//p')
  [[ -n $pw && -n $secure ]] || { printf '%s\n' "$out" | tail -8; xb_abort "创建管理员失败"; }
  xb_env_set "$app/.env" INSTALLED true
  XB_APP=""; XB_DB=""

  PRESET_ROOT=$root PRESET_PHP=$v add_site php "$domain" \
    || { err "站点创建失败, 程序在 $app, 数据库 $dbn 已创建, 管理员密码: $pw"; return 1; }
  load_meta "$domain"
  PHPVER=$v; REWRITE=laravel
  apply_site >/dev/null
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  xb_env_set "$app/.env" APP_URL "$scheme://$domain"
  xb_services "$domain" "$app" "$v"
  app_mark_site "$domain" xboard
  xb_secure_save "$domain" "$secure"
  if confirm "开启防 CC / 防恶意 bot 吗? (节点接口和订阅链接不受影响)" y; then
    guard_set "$domain" on || warn "防护没开成功, 以后可在 [站点设置] 里开启"
  fi
  echo
  info "Xboard 部署完成 (请截图或记下下面的信息)"
  echo "  后台地址: $scheme://$domain/$secure"
  echo "  管理员:   $email"
  echo "  密码:     $pw"
  echo "  数据库:   $dbn  密码 $dbp (已写入 .env)"
  echo "  程序目录: $app"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS, 建议到 [SSL 证书] 里开启"
  echo "  以后管理 (更新 / 后台地址 / 重置密码 / 域名分离):"
  echo "    程序下载 → Xboard 面板,  或命令: wsm app xboard $domain"
  return 0
}

xb_update() {  # xb_update [域名]
  use_site "${1:-}" || return 1
  local app=${ROOT%/public} php k
  [[ $ROOT == */public && -f $app/artisan ]] || { err "$DOMAIN 不是 Xboard 站点"; return 1; }
  php=$(php_bin "$PHPVER"); k=$(xb_slug "$DOMAIN")
  warn "更新会用仓库里的最新代码覆盖程序文件, 数据库和 .env 不受影响"
  [[ -n ${XB_NOCONFIRM:-} ]] || confirm "继续更新 $DOMAIN ?" y || return 0
  xb_safe_dir "$app"
  (cd "$app" && GIT_TERMINAL_PROMPT=0 git fetch -q origin main && git reset -q --hard origin/main) \
    || { err "拉取代码失败 (检查网络或仓库权限)"; return 1; }
  info "安装依赖 ..."
  xb_composer "$app" "$php" || { err "安装依赖失败"; return 1; }
  chown -R "$WEB_USER:$WEB_USER" "$app"
  (cd "$app" && runuser -u "$WEB_USER" -- "$php" artisan xboard:update) || warn "xboard:update 出错, 请看上面的信息"
  systemctl restart "xboard-$k" >/dev/null 2>&1 || true
  info "更新完成: $(xb_commit_info "$app")"
}

xb_domains() {  # xb_domains [站点] [订阅域名] [节点域名]
  use_site "${1:-}" || return 1
  local app=${ROOT%/public} php sub=${2:-} node=${3:-} n u h out scheme=http changed=0 s_url="" n_url=""
  [[ $ROOT == */public && -f $app/artisan ]] || { err "$DOMAIN 不是 Xboard 站点"; return 1; }
  php=$(php_bin "$PHPVER")
  title "Xboard 域名分离 (主页 / 订阅 / 节点)"
  echo "  主页域名: $DOMAIN"
  echo "  其他绑定: ${ALIASES:-(无)}"
  echo
  echo "  建议: 三个域名都解析到本机; 主页开橙云, 订阅和节点两个设为灰云(仅DNS)。"
  echo "  留空 = 不改这一项。"
  if [[ -z $sub && -z $node ]]; then
    read -r -p "① 订阅域名 (如 sub.example.com): " sub || return 1
    read -r -p "② 节点安装/通信域名 (如 node.example.com): " node || return 1
  fi
  [[ -n $sub || -n $node ]] || { warn "没有输入任何域名"; return 0; }
  for n in $sub $node; do
    valid_domain "$n" || { err "域名格式不正确: $n"; return 1; }
    if u=$(domain_used "$n" "$DOMAIN"); then err "$n 已被站点 $u 使用"; return 1; fi
  done
  for n in $sub $node; do
    [[ $n == "$DOMAIN" || " $ALIASES " == *" $n "* ]] && continue
    ALIASES="${ALIASES:+$ALIASES }$n"; changed=1
  done
  if (( changed )); then
    apply_site || return 1
    info "已把新域名绑定到站点 $DOMAIN"
  fi
  if [[ $SSL == 1 && $CERT_MODE == le ]]; then
    if (( changed )); then
      info "重新申请覆盖全部域名的证书 ..."
      ssl_le_http "$DOMAIN" || { err "证书申请失败, 面板里的订阅/节点域名没有修改。请检查 DNS 解析后再运行一次"; return 1; }
      load_meta "$DOMAIN"
    fi
    scheme=https
  elif [[ $SSL == 1 ]]; then
    scheme=https; warn "当前不是 Let's Encrypt 证书, 请确认证书包含: $sub $node"
  else
    warn "站点还没启用 HTTPS, 订阅/节点地址暂时用 http, 建议先到 [SSL 证书] 开启后再运行本命令"
  fi
  [[ -n $sub ]] && s_url="$scheme://$sub"
  [[ -n $node ]] && n_url="$scheme://$node"
  h=$(mktemp --suffix=.php); chmod 644 "$h"
  cat > "$h" <<'PHP'
<?php
$base = $argv[1];
require $base . '/vendor/autoload.php';
$app = require $base . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$set = [];
if (($argv[2] ?? '') !== '') $set['subscribe_url'] = $argv[2];
if (($argv[3] ?? '') !== '') $set['node_panel_url'] = $argv[3];
admin_setting($set);
echo "OK\n";
PHP
  out=$(cd "$app" && runuser -u "$WEB_USER" -- "$php" "$h" "$app" "$s_url" "$n_url" 2>&1); rm -f "$h"
  [[ $out == *OK* ]] || { printf '%s\n' "$out" | tail -8; err "写入面板设置失败"; return 1; }
  echo
  info "完成"
  [[ -n $s_url ]] && echo "  订阅地址前缀: $s_url   (已写入后台「订阅URL」)"
  [[ -n $n_url ]] && echo "  节点通信域名: $n_url   (节点管理里新生成的安装命令会用它)"
  echo
  echo "  还需要你在 Cloudflare 做:"
  echo "   - ${sub:-订阅域名}、${node:-节点域名} 的 DNS 记录指向本机 IP, 并设为灰云(仅DNS)"
  echo "   - 主页域名 $DOMAIN 保持橙云"
  echo "  注意: 已安装的节点不会自动改, 要改节点上 /etc/xboard-node/config.yml 里的面板地址, 或重新安装。"
}

xb_php_run() {  # xb_php_run 程序目录 PHP命令 模式 [参数...]  (以网站用户运行 Xboard 辅助脚本)
  local app=$1 php=$2 h out; shift 2
  h=$(mktemp --suffix=.php); chmod 644 "$h"
  cat > "$h" <<'PHP'
<?php
$base = $argv[1]; $mode = $argv[2] ?? 'info';
require $base . '/vendor/autoload.php';
$app = require $base . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if ($mode === 'info') {
    echo "SECURE=" . admin_setting('secure_path', admin_setting('frontend_admin_path', hash('crc32b', config('app.key')))) . "\n";
    foreach (\App\Models\User::where('is_admin', 1)->orderBy('id')->pluck('email') as $e) echo "ADMIN=$e\n";
} elseif ($mode === 'reset') {
    $u = \App\Models\User::where('email', $argv[3] ?? '')->first();
    if (!$u) { fwrite(STDERR, "邮箱不存在\n"); exit(1); }
    $pw = ($argv[4] ?? '') !== '' ? $argv[4] : \App\Utils\Helper::guid(false);
    $u->password = password_hash($pw, PASSWORD_DEFAULT);
    $u->password_algo = null;
    $u->password_salt = null;
    if (!$u->save()) { fwrite(STDERR, "保存失败\n"); exit(1); }
    echo "NEWPW=$pw\n";
}
PHP
  out=$(cd "$app" && runuser -u "$WEB_USER" -- "$php" "$h" "$app" "$@" 2>&1); local rc=$?
  rm -f "$h"
  printf '%s\n' "$out"
  return $rc
}

xb_info() {  # xb_info [域名]: 查看后台地址/管理员, 重置管理员密码
  use_site "${1:-}" || return 1
  local app=${ROOT%/public} php out secure scheme=http c e pw np
  local -a admins=()
  [[ $ROOT == */public && -f $app/artisan ]] || { err "$DOMAIN 不是 Xboard 站点"; return 1; }
  php=$(php_bin "$PHPVER")
  [[ $SSL == 1 ]] && scheme=https
  while true; do
    out=$(xb_php_run "$app" "$php" info) || { printf '%s\n' "$out" | tail -5; err "读取失败 (数据库或 Redis 没启动?)"; return 1; }
    secure=$(printf '%s\n' "$out" | sed -n 's/^SECURE=//p')
    [[ -n $secure ]] && xb_secure_save "$DOMAIN" "$secure"
    mapfile -t admins < <(printf '%s\n' "$out" | sed -n 's/^ADMIN=//p')
    title "Xboard 后台信息 · $DOMAIN"
    echo "  后台地址: $scheme://$DOMAIN/$secure"
    if ((${#admins[@]})); then
      for e in "${admins[@]}"; do echo "  管理员:   $e"; done
    else
      warn "没有找到管理员账号"
    fi
    echo "  密码:     数据库里只存加密值, 查不到原密码, 忘了就重置"
    echo "  程序目录: $app"
    choose c "操作:" "重置管理员密码" "返回" || return 0
    [[ $c == 重置* ]] || return 0
    ((${#admins[@]})) || { warn "没有管理员账号可重置"; continue; }
    if ((${#admins[@]} == 1)); then e=${admins[0]}
    else choose e "重置哪个管理员?" "${admins[@]}" || continue; fi
    read -r -p "新密码 (至少 8 位, 直接回车自动生成): " pw || continue
    if [[ -n $pw && ${#pw} -lt 8 ]]; then warn "密码至少 8 位"; continue; fi
    confirm "确定重置 $e 的密码?" y || continue
    out=$(xb_php_run "$app" "$php" reset "$e" "$pw") || { printf '%s\n' "$out" | tail -5; err "重置失败"; continue; }
    np=$(printf '%s\n' "$out" | sed -n 's/^NEWPW=//p')
    info "已重置, 请记下 (只显示这一次):"
    echo "  后台地址: $scheme://$DOMAIN/$secure"
    echo "  管理员:   $e"
    echo "  新密码:   $np"
    pause
  done
}

xb_purge() {  # xb_purge 域名 网站根目录  (删除站点时调用)
  local app=${2%/public} k; k=$(xb_slug "$1")
  [[ $2 == */public && -f $app/artisan ]] || return 0
  systemctl disable --now "xboard-$k" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/xboard-$k.service" "/etc/cron.d/xboard-$k"
  systemctl daemon-reload >/dev/null 2>&1 || true
  info "已移除 Xboard 队列服务和计划任务"
  grep -m1 '^DB_DATABASE=' "$app/.env" 2>/dev/null | sed 's/^DB_DATABASE=/   数据库未删除: /'
  if safe_root "$app" && confirm "同时删除 Xboard 程序目录 $app ?" n; then rm -rf -- "$app"; fi
}

xb_is_site() { [[ $ROOT == */public && -f ${ROOT%/public}/artisan ]]; }  # 依赖已 load_meta

xb_path_file() { echo "$XB_DATA/$1.path"; }

xb_secure_save() {  # xb_secure_save 域名 后台路径: 记录后台路径, 变化时刷新防护白名单
  local f; f=$(xb_path_file "$1")
  [[ $2 =~ ^[A-Za-z0-9_-]{4,64}$ ]] || return 0
  [[ -f $f && $(head -1 "$f") == "$2" ]] && return 0
  mkdir -p "$XB_DATA"; echo "$2" > "$f"
  guard_refresh_global
}

xb_secure_detect() {  # xb_secure_detect 域名: 读取 Xboard 后台路径并记录
  ( load_meta "$1"; xb_is_site || exit 0
    out=$(xb_php_run "${ROOT%/public}" "$(php_bin "$PHPVER")" info 2>/dev/null) || exit 1
    sp=$(printf '%s\n' "$out" | sed -n 's/^SECURE=//p')
    [[ -n $sp ]] && xb_secure_save "$1" "$sp" )
}

xb_migrate_old() {  # 旧版 wsm 把后台路径存在 sites/<域名>.xbpath, 搬到模块数据目录
  local f d
  for f in "$META_DIR"/*.xbpath; do
    [[ -f $f ]] || continue
    d=${f##*/}; d=${d%.xbpath}
    mkdir -p "$XB_DATA" && mv -f "$f" "$(xb_path_file "$d")" 2>/dev/null
  done
  return 0
}
xb_migrate_old

# ---------------------------------------------------------------- 模块接口
app_xboard_install() { xb_install "${1:-}"; }

app_xboard_detect() {  # 老站点认领: Laravel 目录结构 + Xboard 特有文件或队列服务
  xb_is_site || return 1
  [[ -f ${ROOT%/public}/app/Console/Commands/XboardInstall.php \
     || -f /etc/systemd/system/xboard-$(xb_slug "$DOMAIN").service ]]
}

app_xboard_menu() {  # app_xboard_menu 站点
  local d=$1 c
  while true; do
    title "Xboard 面板 · $d"
    echo "  程序版本: $( load_meta "$d"; xb_commit_info "${ROOT%/public}" )"
    choose c "操作:" "后台地址 / 重置管理员密码" "检查更新" "域名分离 (主页/订阅/节点)" \
      "刷新防 CC 后台白名单" "返回" || return 0
    case $c in
      后台*) (xb_info "$d") ;;
      检查更新) (xb_check_update "$d"); pause ;;
      域名*) (xb_domains "$d"); pause ;;
      刷新*) if xb_secure_detect "$d"; then info "已刷新 (后台改了路径后用这个)"; else warn "读取后台路径失败"; fi; pause ;;
      *) return 0 ;;
    esac
  done
}

app_xboard_guard_skip() {  # 不限速: 节点通信接口 / 订阅链接 / 各站点后台
  local f p
  echo '    "~^/api/v[12]/server/"   1;'
  echo '    "~^/api/v1/client/subscribe"   1;'
  echo '    "~^/[A-Za-z0-9_-]+/[0-9A-Fa-f]{32}/?(\?|$)"   1;'
  for f in "$XB_DATA"/*.path; do
    [[ -s $f ]] || continue
    p=$(head -1 "$f")
    [[ $p =~ ^[A-Za-z0-9_-]{4,64}$ ]] || continue
    printf '    "~^/api/v2/%s/"   1;\n' "$p"
    printf '    "~^/%s/?(\\?|$)"   1;\n' "$p"
  done
  return 0
}

app_xboard_guard_on() { xb_secure_detect "$1" || warn "没读到 Xboard 后台路径, 后台可能会被限速"; }

app_xboard_units() { echo "xboard-$(xb_slug "$1")"; }

app_xboard_backup_paths() {
  local f
  for f in /etc/systemd/system/xboard-*.service /etc/cron.d/xboard-*; do [[ -e $f ]] && echo "$f"; done
  return 0
}

app_xboard_purge() { xb_purge "$1" "$2"; rm -f "$(xb_path_file "$1")"; }

app_xboard_cli() {  # wsm app xboard [域名] | update|info|domains [域名] ...
  case ${1:-} in
    update)  xb_update "${2:-}" ;;
    check)   xb_check_update "${2:-}" ;;
    info)    xb_info "${2:-}" ;;
    domains) xb_domains "${2:-}" "${3:-}" "${4:-}" ;;
    "")      app_module_menu xboard ;;
    *)       [[ -f $(meta_file "$1") ]] || { err "用法: wsm app xboard [install|update|info|domains] [域名]"; return 1; }
             app_xboard_menu "$1" ;;
  esac
}

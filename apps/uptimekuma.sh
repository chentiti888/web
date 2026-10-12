# shellcheck shell=bash disable=SC2034
# wsm 程序模块: Uptime Kuma 在线监控 (github.com/louislam/uptime-kuma)
# Node.js 直装 + systemd, wsm 建反代站点。不能单独运行。
APP_ID=uptimekuma
APP_NAME="Uptime Kuma"
APP_DESC="网站/接口/端口在线监控, 掉线告警 (支持 Telegram)"
APP_VER=1.2

UK_REPO=louislam/uptime-kuma
UK_DIR=/opt/uptime-kuma
UK_PORT=3001
UK_UNIT=uptime-kuma
UK_USER=uptime-kuma

uk_git() { GIT_TERMINAL_PROMPT=0 git -c safe.directory="$UK_DIR" -C "$UK_DIR" "$@"; }

uk_version() { sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$UK_DIR/package.json" 2>/dev/null | head -1; }

uk_node_ready() {  # Uptime Kuma 2.x 需要 Node.js 20.4 以上
  local m
  m=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
  if [[ -z $m ]] || ((m < 20)); then
    warn "需要 Node.js 20 以上 (当前: $(node -v 2>/dev/null || echo 未安装)), 先安装 Node.js"
    install_nodejs || return 1
    m=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
    [[ -n $m ]] && ((m >= 20)) || { err "Node.js 版本还是太低, 请选 22 或 24"; return 1; }
  fi
  command -v git >/dev/null 2>&1 || pkg_install git >/dev/null 2>&1 || { err "git 安装失败"; return 1; }
}

uk_build() {  # 安装依赖 + 下载前端 (在程序目录里)
  info "安装依赖 (需要几分钟) ..."
  (cd "$UK_DIR" && npm ci --omit dev --no-audit --no-fund >/dev/null 2>&1) || { err "npm 安装依赖失败"; return 1; }
  info "下载前端文件 ..."
  (cd "$UK_DIR" && npm run download-dist >/dev/null 2>&1) || { err "下载前端失败"; return 1; }
  chown -R "$UK_USER:$UK_USER" "$UK_DIR"
}

app_uptimekuma_install() {
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} scheme
  title "部署 Uptime Kuma"
  [[ -f /etc/systemd/system/$UK_UNIT.service ]] && { err "本机已经装过 Uptime Kuma"; return 1; }
  [[ -e $UK_DIR ]] && { err "目录 $UK_DIR 已存在, 请先处理"; return 1; }
  app_port_free "$UK_PORT" || { err "端口 $UK_PORT 已被占用"; return 1; }
  uk_node_ready || return 1
  app_new_domain domain "① 访问域名 (如 status.example.com)" || return 1
  ver_pick "Uptime Kuma" "$UK_REPO" || return 1
  [[ -n $PICK_VER ]] || { err "需要一个版本号才能安装 (没检测到最新版时请手动输入, 如 2.0.2)"; return 1; }

  info "下载 Uptime Kuma $PICK_VER ..."
  GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$PICK_VER" "https://github.com/$UK_REPO.git" "$UK_DIR" 2>/dev/null \
    || { rm -rf "$UK_DIR"; err "下载失败 (版本号 $PICK_VER 不存在或网络问题)"; return 1; }
  id "$UK_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$UK_DIR" "$UK_USER"
  mkdir -p "$UK_DIR/data"
  uk_build || { rm -rf "$UK_DIR"; return 1; }
  app_systemd "$UK_UNIT" "Uptime Kuma" "$UK_DIR" "$(command -v node) server/server.js" "$UK_USER" \
    "UPTIME_KUMA_HOST=127.0.0.1" "UPTIME_KUMA_PORT=$UK_PORT" "DATA_DIR=$UK_DIR/data/" "NODE_ENV=production"
  app_wait_port "$UK_PORT" 60 || warn "还没启动起来, 请查看: journalctl -u $UK_UNIT -n 30"

  app_proxy_site "$domain" "$UK_PORT" || { err "站点创建失败, 程序已在本机 $UK_PORT 端口运行"; return 1; }
  app_mark_site "$domain" uptimekuma
  load_meta "$domain"
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  echo
  info "Uptime Kuma $(uk_version) 已部署"
  echo "  访问地址: $scheme://$domain/"
  echo "  ${R}马上打开它创建管理员账号${N} (第一个打开的人就能设置, 别拖)"
  echo "  首次打开会让你选数据库: 选 SQLite (内置) 就行"
  echo "  通知方式里可以加 Telegram, 网站掉线会发消息"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS, 建议到 [SSL 证书] 里开启"
  return 0
}

app_uptimekuma_detect() { [[ $TYPE == proxy && $UPSTREAM == *":$UK_PORT"* && -f $UK_DIR/server/server.js ]]; }
app_uptimekuma_units() { echo "$UK_UNIT"; }
app_uptimekuma_backup_paths() {
  [[ -d $UK_DIR ]] && echo "$UK_DIR"
  [[ -f /etc/systemd/system/$UK_UNIT.service ]] && echo "/etc/systemd/system/$UK_UNIT.service"
  return 0
}

app_uptimekuma_purge() {  # 停止并移除服务
  systemctl disable --now "$UK_UNIT" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$UK_UNIT.service"; systemctl daemon-reload >/dev/null 2>&1
  echo "   已停止并移除服务 $UK_UNIT"
}
app_uptimekuma_files() { [[ -d $UK_DIR ]] && find "$UK_DIR" -mindepth 1 -maxdepth 1 ! -name data; return 0; }
app_uptimekuma_data() { echo "$UK_DIR/data"; }
app_uptimekuma_cleanup() {
  [[ -d $UK_DIR ]] && rmdir "$UK_DIR" 2>/dev/null
  [[ -d $UK_DIR ]] || userdel "$UK_USER" >/dev/null 2>&1
  return 0
}

app_uptimekuma_menu() {  # app_uptimekuma_menu 站点
  local d=$1 c cur old
  while true; do
    cur=$(uk_version)
    title "Uptime Kuma · $d"
    echo "  访问地址: https://$d/"
    echo "  程序版本: ${cur:-未知}   服务: $(svc_state "$UK_UNIT")"
    choose c "操作:" "检查更新" "重启" "查看日志" "卸载 (删除站点和程序)" "返回" || return 0
    case $c in
      检查更新)
        if app_check_update "Uptime Kuma" "$UK_REPO" "$cur" && confirm "升级到 $PICK_VER ? (监控数据不受影响)" y; then
          old=$(uk_git rev-parse HEAD 2>/dev/null)
          systemctl stop "$UK_UNIT"
          if uk_git fetch -q --depth 1 origin tag "$PICK_VER" && uk_git checkout -q -f "$PICK_VER" && uk_build; then
            systemctl start "$UK_UNIT"
            app_wait_port "$UK_PORT" 60 && info "已升级到 $(uk_version)" || warn "还没启动起来, 请查看日志"
          else
            warn "升级失败, 恢复旧版本"
            [[ -n $old ]] && uk_git checkout -q -f "$old" && uk_build
            systemctl start "$UK_UNIT"
          fi
        fi
        pause ;;
      重启) systemctl restart "$UK_UNIT" && info "已重启"; pause ;;
      查看日志) journalctl -u "$UK_UNIT" -n 40 --no-pager; pause ;;
      卸载*) (app_site_uninstall "$d"); pause; [[ -f $(meta_file "$d") ]] || return 0 ;;
      *) return 0 ;;
    esac
  done
}

# shellcheck shell=bash disable=SC2034
# wsm 程序模块: 哪吒监控 面板 (github.com/nezhahq/nezha)
# 二进制直装 + systemd, wsm 建反代站点 (含 Agent 用的 gRPC 和 WebSocket)。不能单独运行。
APP_ID=nezha
APP_NAME="哪吒监控"
APP_DESC="多台 VPS 状态监控/告警面板, 二进制直装"
APP_VER=1.0

NZ_REPO=nezhahq/nezha
NZ_DIR=/opt/nezha/dashboard
NZ_PORT=8008
NZ_UNIT=nezha-dashboard

nz_fetch() {  # nz_fetch 版本(可空) 临时目录 -> 程序文件 NZ_BIN_NEW
  local url f
  NZ_BIN_NEW=""
  command -v unzip >/dev/null 2>&1 || pkg_install unzip >/dev/null 2>&1 || { err "unzip 安装失败"; return 1; }
  url=$(gh_asset_url "$NZ_REPO" "$1" "dashboard-linux-$(arch_go).zip")
  info "下载哪吒面板 ${1:-最新版} ..."
  curl -fL --max-time 300 -o "$2/nz.zip" "$url" || { err "下载失败: $url"; return 1; }
  mkdir -p "$2/x"; unzip -q -o "$2/nz.zip" -d "$2/x" || { err "解压失败"; return 1; }
  for f in "$2"/x/dashboard* "$2"/x/*/dashboard*; do
    [[ -f $f ]] && { NZ_BIN_NEW=$f; chmod +x "$f"; return 0; }
  done
  err "安装包里没找到程序文件"; return 1
}

nz_site_conf() {  # Agent 走 gRPC, 面板实时数据走 WebSocket
  app_site_conf "$1" <<EOF
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$remote_addr;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://127.0.0.1:$NZ_PORT;
    }
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header Origin \$scheme://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:$NZ_PORT;
    }
EOF
}

app_nezha_install() {
  command -v nginx >/dev/null 2>&1 || die "还没有安装环境, 请先执行: wsm install"
  local domain=${1:-} tmp scheme
  title "部署哪吒监控面板"
  [[ -f /etc/systemd/system/$NZ_UNIT.service ]] && { err "本机已经装过哪吒面板 (一台装一个就够了)"; return 1; }
  app_port_free "$NZ_PORT" || { err "端口 $NZ_PORT 已被占用"; return 1; }
  app_new_domain domain "① 面板域名 (如 nz.example.com)" || return 1
  ver_pick "哪吒面板" "$NZ_REPO" || return 1
  tmp=$(mktemp -d)
  nz_fetch "$PICK_VER" "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$NZ_DIR/data"
  install -m 755 "$NZ_BIN_NEW" "$NZ_DIR/dashboard"
  rm -rf "$tmp"
  [[ -f $NZ_DIR/data/config.yaml ]] || printf 'language: zh_CN\nlisten_port: %s\n' "$NZ_PORT" > "$NZ_DIR/data/config.yaml"
  app_systemd "$NZ_UNIT" "Nezha Dashboard" "$NZ_DIR" "$NZ_DIR/dashboard"
  app_wait_port "$NZ_PORT" 30 || warn "面板还没启动起来, 请查看: journalctl -u $NZ_UNIT -n 30"

  app_proxy_site "$domain" "$NZ_PORT" || { err "站点创建失败, 面板已在本机 $NZ_PORT 端口运行"; return 1; }
  load_meta "$domain"
  nz_site_conf "$domain"
  apply_site >/dev/null
  app_mark_site "$domain" nezha
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  echo
  info "哪吒面板 $(nz_version) 已部署 (请记下)"
  echo "  后台地址: $scheme://$domain/dashboard"
  echo "  初始账号: admin   初始密码: admin   ${R}登录后马上改密码${N} (头像 → 个人信息)"
  echo
  echo "  被监控的 VPS 怎么接入 (二选一, 在后台 [系统设置] 里填 [Agent 对接地址]):"
  echo "   - $domain:443 并勾选 TLS  (要先开 HTTPS, 并且这个域名在 Cloudflare 设为灰云)"
  echo "   - 本机IP:$NZ_PORT 不勾 TLS  (不经过 Nginx, 开了源站保护也不影响这个端口)"
  echo "  然后在后台 [服务器] 里点 [安装命令], 复制到被监控的 VPS 上运行即可"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS, 建议到 [SSL 证书] 里开启"
  return 0
}

nz_version() { "$NZ_DIR/dashboard" -v 2>/dev/null | head -1; }

app_nezha_detect() { [[ $TYPE == proxy && $UPSTREAM == *":$NZ_PORT"* && -x $NZ_DIR/dashboard ]]; }
app_nezha_units() { echo "$NZ_UNIT"; }
app_nezha_backup_paths() {
  [[ -d $NZ_DIR ]] && echo "$NZ_DIR"
  [[ -f /etc/systemd/system/$NZ_UNIT.service ]] && echo "/etc/systemd/system/$NZ_UNIT.service"
  return 0
}

app_nezha_purge() {
  systemctl disable --now "$NZ_UNIT" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$NZ_UNIT.service"; systemctl daemon-reload >/dev/null 2>&1
  info "已停止并移除哪吒面板服务"
  if [[ -d $NZ_DIR ]] && confirm "同时删除面板程序和数据 $NZ_DIR (所有服务器记录)?" n; then rm -rf -- "${NZ_DIR:?}"; fi
}

app_nezha_menu() {  # app_nezha_menu 站点
  local d=$1 c cur tmp
  while true; do
    cur=$(nz_version)
    title "哪吒监控 · $d"
    echo "  后台地址: https://$d/dashboard"
    echo "  程序版本: ${cur:-未知}   服务: $(svc_state "$NZ_UNIT")"
    choose c "操作:" "检查更新" "重启面板" "查看日志" "返回" || return 0
    case $c in
      检查更新)
        if app_check_update "哪吒面板" "$NZ_REPO" "$cur" && confirm "升级到 $PICK_VER ?" y; then
          tmp=$(mktemp -d)
          if nz_fetch "$PICK_VER" "$tmp"; then
            systemctl stop "$NZ_UNIT"
            cp -f "$NZ_DIR/dashboard" "$NZ_DIR/dashboard.bak"
            install -m 755 "$NZ_BIN_NEW" "$NZ_DIR/dashboard"
            systemctl start "$NZ_UNIT"
            if app_wait_port "$NZ_PORT" 30; then info "已升级到 $(nz_version)"
            else
              warn "新版本没启动起来, 已恢复旧版本"
              systemctl stop "$NZ_UNIT"; mv -f "$NZ_DIR/dashboard.bak" "$NZ_DIR/dashboard"; systemctl start "$NZ_UNIT"
            fi
          fi
          rm -rf "$tmp"
        fi
        pause ;;
      重启*) systemctl restart "$NZ_UNIT" && info "已重启"; pause ;;
      查看日志) journalctl -u "$NZ_UNIT" -n 40 --no-pager; pause ;;
      *) return 0 ;;
    esac
  done
}

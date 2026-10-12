# shellcheck shell=bash disable=SC2034
# wsm 程序模块: OpenList 网盘挂载/文件列表 (github.com/OpenListTeam/OpenList, AList 社区版)
# 二进制直装 + systemd, wsm 建反代站点。不能单独运行。
APP_ID=openlist
APP_NAME="OpenList"
APP_DESC="网盘挂载/文件列表/WebDAV (AList 社区版), 二进制直装"
APP_VER=1.3

OL_REPO=OpenListTeam/OpenList
OL_DIR=/opt/openlist
OL_PORT=5244
OL_UNIT=openlist

ol() { "$OL_DIR/openlist" --data "$OL_DIR/data" "$@"; }

ol_fetch() {  # ol_fetch 版本(可空) 临时目录 -> 程序文件 OL_BIN_NEW
  local url
  OL_BIN_NEW=""
  url=$(gh_asset_url "$OL_REPO" "$1" "openlist-linux-$(arch_go).tar.gz")
  info "下载 OpenList ${1:-最新版} ..."
  curl -fL --max-time 300 -o "$2/ol.tgz" "$url" || { err "下载失败: $url"; return 1; }
  tar -xzf "$2/ol.tgz" -C "$2" || { err "解压失败"; return 1; }
  [[ -f $2/openlist ]] || { err "安装包里没找到程序文件"; return 1; }
  chmod +x "$2/openlist"; OL_BIN_NEW=$2/openlist
}

ol_site_conf() {  # 上传和 WebDAV 不限制文件大小
  local loc
  {
    for loc in /api/fs/put /api/fs/form /dav/; do
      cat <<EOF
    location ^~ $loc {
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_pass http://127.0.0.1:$OL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF
    done
  } | app_site_conf "$1"
}

ol_local_only() {  # 只监听本机, 统一从域名访问
  local f=$OL_DIR/data/config.json
  [[ -f $f ]] && sed -i 's/"address": *"0\.0\.0\.0"/"address": "127.0.0.1"/' "$f"
}

ol_version() { ol version 2>/dev/null | sed -n 's/^Version: *//p' | head -1; }

app_openlist_install() {
  command -v nginx >/dev/null 2>&1 || need_web_env || return 1
  local domain=${1:-} tmp pw scheme
  title "部署 OpenList"
  [[ -f /etc/systemd/system/$OL_UNIT.service ]] && { err "本机已经装过 OpenList"; return 1; }
  app_port_free "$OL_PORT" || { err "端口 $OL_PORT 已被占用 (装过 AList 的话请先停掉)"; return 1; }
  app_new_domain domain "① 访问域名 (如 pan.example.com)" || return 1
  ver_pick OpenList "$OL_REPO" || return 1
  tmp=$(mktemp -d)
  ol_fetch "$PICK_VER" "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$OL_DIR/data"
  install -m 755 "$OL_BIN_NEW" "$OL_DIR/openlist"
  rm -rf "$tmp"
  pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
  ol admin set "$pw" >/dev/null 2>&1 || warn "设置管理员密码失败, 可在本模块菜单里重新设置"
  ol_local_only   # 上一步会生成配置文件
  app_systemd "$OL_UNIT" "OpenList" "$OL_DIR" "$OL_DIR/openlist --data $OL_DIR/data server"
  app_wait_port "$OL_PORT" 30 || warn "还没启动起来, 请查看: journalctl -u $OL_UNIT -n 30"
  app_ver_set openlist "$(ol_version)"

  app_proxy_site "$domain" "$OL_PORT" || { err "站点创建失败, 程序已在本机 $OL_PORT 端口运行, 管理员密码 $pw"; return 1; }
  load_meta "$domain"
  ol_site_conf "$domain"
  apply_site >/dev/null
  app_mark_site "$domain" openlist
  scheme=http; [[ $SSL == 1 ]] && scheme=https
  echo
  info "OpenList $(ol_version) 已部署 (请记下)"
  echo "  访问地址: $scheme://$domain/"
  echo "  管理员:   admin"
  echo "  密码:     $pw"
  echo "  WebDAV:   $scheme://$domain/dav/  (同一个账号)"
  echo "  登录后在 [管理 → 存储] 里添加网盘"
  [[ $SSL == 1 ]] || warn "还没启用 HTTPS, 建议到 [SSL 证书] 里开启"
  return 0
}

app_openlist_detect() { [[ $TYPE == proxy && $UPSTREAM == *":$OL_PORT"* && -x $OL_DIR/openlist ]]; }
app_openlist_units() { echo "$OL_UNIT"; }
app_openlist_backup_paths() {
  [[ -d $OL_DIR ]] && echo "$OL_DIR"
  [[ -f /etc/systemd/system/$OL_UNIT.service ]] && echo "/etc/systemd/system/$OL_UNIT.service"
  return 0
}

app_openlist_purge() {  # 停止并移除服务
  systemctl disable --now "$OL_UNIT" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$OL_UNIT.service"; systemctl daemon-reload >/dev/null 2>&1
  echo "   已停止并移除服务 $OL_UNIT"
}
app_openlist_files() { echo "$OL_DIR/openlist"; echo "$OL_DIR/openlist.bak"; }
app_openlist_data() { echo "$OL_DIR/data"; }   # 存储配置和账号
app_openlist_cleanup() { rmdir "$OL_DIR" 2>/dev/null; return 0; }

app_openlist_menu() {  # app_openlist_menu 站点
  local d=$1 c cur tmp pw
  while true; do
    cur=$(ol_version); [[ -n $cur ]] || cur=$(app_ver_get openlist)
    title "OpenList · $d"
    echo "  访问地址: https://$d/"
    echo "  程序版本: ${cur:-未知}   服务: $(svc_state "$OL_UNIT")"
    choose c "操作:" "检查更新" "重置管理员密码" "重启" "查看日志" "卸载 (删除站点和程序)" "返回" || return 0
    case $c in
      检查更新)
        if app_check_update OpenList "$OL_REPO" "$cur" && confirm "升级到 $PICK_VER ?" y; then
          tmp=$(mktemp -d)
          if ol_fetch "$PICK_VER" "$tmp"; then
            systemctl stop "$OL_UNIT"
            cp -f "$OL_DIR/openlist" "$OL_DIR/openlist.bak"
            install -m 755 "$OL_BIN_NEW" "$OL_DIR/openlist"
            systemctl start "$OL_UNIT"
            if app_wait_port "$OL_PORT" 30; then app_ver_set openlist "$PICK_VER"; info "已升级到 $(ol_version)"
            else
              warn "新版本没启动起来, 已恢复旧版本"
              systemctl stop "$OL_UNIT"; mv -f "$OL_DIR/openlist.bak" "$OL_DIR/openlist"; systemctl start "$OL_UNIT"
            fi
          fi
          rm -rf "$tmp"
        fi
        pause ;;
      重置*)
        pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
        systemctl stop "$OL_UNIT"
        if ol admin set "$pw" >/dev/null 2>&1; then info "已重置, 账号 admin  新密码: $pw"; else err "重置失败"; fi
        systemctl start "$OL_UNIT"; pause ;;
      重启) systemctl restart "$OL_UNIT" && info "已重启"; pause ;;
      查看日志) journalctl -u "$OL_UNIT" -n 40 --no-pager; pause ;;
      卸载*) (app_site_uninstall "$d"); pause; [[ -f $(meta_file "$d") ]] || return 0 ;;
      *) return 0 ;;
    esac
  done
}

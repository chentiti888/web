# shellcheck shell=bash disable=SC2034
# wsm 程序模块: 3x-ui 面板 (官方脚本: github.com/MHSanaei/3x-ui)
# 独立软件类: 自带网页服务, 不建站点。本文件由 wsm 载入使用, 不能单独运行。
APP_ID=xui
APP_TYPE=soft
APP_NAME="3x-ui 面板"
APP_DESC="Xray 多协议节点面板 (x-ui 增强版)"
APP_VER=1.1

XUI_REPO=MHSanaei/3x-ui

app_xui_installed() { command -v x-ui >/dev/null 2>&1 || [[ -x /usr/local/x-ui/x-ui ]]; }
app_xui_detect() { app_xui_installed; }
app_xui_version() { /usr/local/x-ui/x-ui -v 2>/dev/null | head -1; }
app_xui_units() { unit_exists x-ui && echo x-ui; return 0; }

app_xui_install() {
  echo "将运行 3x-ui 官方安装脚本, 安装过程中按提示设置面板端口和账号密码。"
  warn "节点不要用 80/443 端口 (被 Nginx 占用); 开了源站保护也不影响其他端口"
  ver_pick 3x-ui "$XUI_REPO" || return 0
  confirm "开始安装${PICK_VER:+ $PICK_VER}?" y || return 0
  bash <(curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) ${PICK_VER:+"$PICK_VER"} \
    || { err "安装失败, 请检查网络"; return 1; }
}

app_xui_uninstall() {
  confirm_typed "确认卸载 3x-ui (面板和节点配置都会删除)" || return 1
  x-ui uninstall
}

app_xui_menu() {
  local c
  while true; do
    title "3x-ui 面板"
    echo "  状态: ${G}已安装${N}   服务: $(svc_state x-ui)   版本: $(app_xui_version)"
    choose c "操作:" "打开 x-ui 管理菜单" "查看面板地址和账号" "重启" "检查更新" "返回" || return 0
    case $c in
      打开*) x-ui ;;
      查看*) x-ui settings 2>/dev/null || /usr/local/x-ui/x-ui setting -show true; pause ;;
      重启) systemctl restart x-ui && info "已重启"; pause ;;
      检查更新)
        app_check_update 3x-ui "$XUI_REPO" "$(app_xui_version)" && confirm "升级到 $PICK_VER ? (用官方升级程序, 节点配置不受影响)" y && x-ui update
        pause ;;
      *) return 0 ;;
    esac
  done
}

#!/usr/bin/env bash

cd "$(
  cd "$(dirname "$0")" || exit
  pwd
)" || exit

# 字体颜色配置
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Font="\033[0m"
GreenBG="\033[42;37m"
RedBG="\033[41;37m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"

# 变量
shell_version="0.0.2"
github_branch="xray"
version_cmp="/tmp/version_cmp.tmp"
xray_conf_dir="/usr/local/etc/xray"
website_dir="/www/xray_web/"
xray_access_log="/var/log/xray/access.log"
xray_error_log="/var/log/xray/error.log"
VERSION=$(echo "${VERSION}" | awk -F "[()]" '{print $2}')

function print_ok() {
  echo -e "${OK} ${GreenBG} $1 ${Font}"
}

function print_error() {
  echo -e "${ERROR} ${RedBG} $1 ${Font}"
}

function is_root() {
  if [[ 0 == "$UID" ]]; then
    print_ok "当前用户是root用户，开始安装流程"
  else
    print_error "当前用户不是root用户，请切换到root用户后重新执行脚本"
    exit 1
  fi
}

judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

function system_check() {
  source '/etc/os-release'

  if [[ "${ID}" == "centos" && ${VERSION_ID} -ge 7 ]]; then
    print_ok "当前系统为 Centos ${VERSION_ID} ${VERSION}"
    INS="yum install -y"
  elif [[ "${ID}" == "debian" && ${VERSION_ID} -ge 9 ]]; then
    print_ok "当前系统为 Debian ${VERSION_ID} ${VERSION}"
    INS="apt install -y"
    $INS update
  elif [[ "${ID}" == "ubuntu" && $(echo "${VERSION_ID}" | cut -d '.' -f1) -ge 16 ]]; then
    print_ok "当前系统为 Ubuntu ${VERSION_ID} ${UBUNTU_CODENAME}"
    INS="apt install -y"
    $INS update
  else
    print_error "当前系统为 ${ID} ${VERSION_ID} 不在支持的系统列表内"
    exit 1
  fi

  $INS dbus

  # 关闭各类防火墙
  systemctl stop firewalld
  systemctl disable firewalld
  systemctl stop nftables
  systemctl disable nftables
  systemctl stop ufw
  systemctl disable ufw
}

function nginx_install() {
  if ! command -v nginx >/dev/null 2>&1; then
    ${INS} nginx
    judge "Nginx 安装"
  else
    print_ok "Nginx 已存在"
  fi
}
function dependency_install() {
  ${INS} wget git lsof
  judge "安装 wget git lsof"

  if [[ "${ID}" == "centos" ]]; then
    ${INS} crontabs
  else
    ${INS} cron
  fi
  judge "安装 crontab"

  if [[ "${ID}" == "centos" ]]; then
    touch /var/spool/cron/root && chmod 600 /var/spool/cron/root
    systemctl start crond && systemctl enable crond
  else
    touch /var/spool/cron/crontabs/root && chmod 600 /var/spool/cron/crontabs/root
    systemctl start cron && systemctl enable cron

  fi
  judge "crontab 自启动配置 "

  ${INS} bc
  judge "安装 bc"

  ${INS} unzip
  judge "安装 unzip"

  ${INS} curl
  judge "安装 curl"

# Nginx 后置 无需编译 不再需要
#  if [[ "${ID}" == "centos" ]]; then
#    yum -y groupinstall "Development tools"
#  else
#    ${INS} build-essential
#  fi
#  judge "编译工具包 安装"

  if [[ "${ID}" == "centos" ]]; then
    ${INS} pcre pcre-devel zlib-devel epel-release
  else
    ${INS} libpcre3 libpcre3-dev zlib1g-dev dbus
  fi

  ${INS} jq

  if ! command -v jq; then
    wget -P /usr/bin https://raw.githubusercontent.com/wulabing/V2Ray_ws-tls_bash_onekey/xray/binary/jq && chmod +x /usr/bin/jq
    judge "安装 jq"
  fi
}

function basic_optimization() {
  # 最大文件打开数
  sed -i '/^\*\ *soft\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
  sed -i '/^\*\ *hard\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
  echo '* soft nofile 65536' >>/etc/security/limits.conf
  echo '* hard nofile 65536' >>/etc/security/limits.conf

  # 关闭 Selinux
  if [[ "${ID}" == "centos" ]]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
  fi
}
function domain_check() {
  read -rp "请输入你的域名信息(eg:www.wulabing.com):" domain
  domain_ip=$(ping "${domain}" -c 1 | sed '1{s/[^(]*(//;s/).*//;q}')
  print_ok "正在获取 公网ip 信息，请耐心等待"
  local_ip=$(curl https://api-ipv4.ip.sb/ip)
  echo -e "域名dns解析IP：${domain_ip}"
  echo -e "本机IP: ${local_ip}"
  sleep 2
  if [[ $(echo "${local_ip}" | tr '.' '+' | bc) -eq $(echo "${domain_ip}" | tr '.' '+' | bc) ]]; then
    print_ok "域名dns解析IP 与 本机IP 匹配"
    sleep 2
  else
    print_error "请确保域名添加了正确的 A 记录，否则将无法正常使用 xray"
    print_error "域名dns解析IP 与 本机IP 不匹配 是否继续安装？（y/n）" && read -r install
    case $install in
    [yY][eE][sS] | [yY])
      print_ok "继续安装"
      sleep 2
      ;;
    *)
      print_error "安装终止"
      exit 2
      ;;
    esac
  fi
}

function port_exist_check() {
  if [[ 0 -eq $(lsof -i:"$1" | grep -i -c "listen") ]]; then
    print_ok "$1 端口未被占用"
    sleep 1
  else
    print_error "检测到 $1 端口被占用，以下为 $1 端口占用信息"
    lsof -i:"$1"
    print_error "5s 后将尝试自动 kill 占用进程"
    sleep 5
    lsof -i:"$1" | awk '{print $2}' | grep -v "PID" | xargs kill -9
    print_ok "kill 完成"
    sleep 1
  fi
}
function update_sh() {
  ol_version=$(curl -L -s https://raw.githubusercontent.com/wulabing/V2Ray_ws-tls_bash_onekey/${github_branch}/install.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
  echo "$ol_version" >$version_cmp
  echo "$shell_version" >>$version_cmp
  if [[ "$shell_version" < "$(sort -rV $version_cmp | head -1)" ]]; then
    echo -e "${OK} ${GreenBG} 存在新版本，是否更新 [Y/N]? ${Font}"
    read -r update_confirm
    case $update_confirm in
    [yY][eE][sS] | [yY])
      wget -N --no-check-certificate https://raw.githubusercontent.com/wulabing/V2Ray_ws-tls_bash_onekey/${github_branch}/install.sh
      echo -e "${OK} ${GreenBG} 更新完成 ${Font}"
      exit 0
      ;;
    *) ;;

    esac
  else
    echo -e "${OK} ${GreenBG} 当前版本为最新版本 ${Font}"
  fi
}
function modify_UUID() {
  [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
  cat ${xray_conf_dir}/config.json | jq 'setpath(["inbounds",0,"settings","clients",0,"id"];"'${UUID}'")' >${xray_conf_dir}/config_tmp.json
  mv -f ${xray_conf_dir}/config_tmp.json ${xray_conf_dir}/config.json
  judge "Xray UUID 修改"
}

function modify_tls_version() {
  cat ${xray_conf_dir}/config.json | jq 'setpath(["inbounds",0,"streamSettings","xtlsSettings","minVersion"];"'$1'")' >${xray_conf_dir}/config_tmp.json
  mv -f ${xray_conf_dir}/config_tmp.json ${xray_conf_dir}/config.json
  judge "Xray TLS_version 修改"
}

function configure_nginx() {
  nginx_conf="/etc/nginx/conf.d/${domain}.conf"
  cd /etc/nginx/conf.d/ && rm -f ${domain}.conf && wget -O ${domain}.conf https://raw.githubusercontent.com/wulabing/V2Ray_ws-tls_bash_onekey/xray/config/web.conf
  sed -i "/server_name/c \\\tserver_name ${domain};" ${nginx_conf}
  judge "Nginx config modify"
}

function tls_type() {
  echo "请选择支持的 TLS 版本（default:3）:"
  echo "1: TLS1.1 TLS1.2 and TLS1.3（兼容模式）"
  echo "2: TLS1.2 and TLS1.3 (兼容模式)"
  echo "3: TLS1.3 only"
  read -rp "请输入：" tls_version
  [[ -z ${tls_version} ]] && tls_version=3
  if [[ $tls_version == 3 ]]; then
    modify_tls_version "1.3"
  elif [[ $tls_version == 2 ]]; then
    modify_tls_version "1.2"
  else
    modify_tls_version "1.1"
  fi
}

function configure_xray() {
  cd /usr/local/etc/xray && rm -f config.json && wget -O config.json https://raw.githubusercontent.com/wulabing/V2Ray_ws-tls_bash_onekey/xray/config/xray_xtls-rprx-direct.json
  modify_UUID
  tls_type
}

function xray_install() {
  print_ok "安装 xray"
  curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
  judge "xray 安装"
}

function ssl_install() {
  if [[ "${ID}" == "centos" ]]; then
    ${INS} socat nc
  else
    ${INS} socat netcat
  fi
  judge "安装 SSL 证书生成脚本依赖"

  curl https://get.acme.sh | sh
  judge "安装 SSL 证书生成脚本"
}

function acme() {
  if "$HOME"/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --force; then
    print_ok "SSL 证书生成成功"
    sleep 2
    mkdir /ssl
    if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath /ssl/xray.crt --keypath /ssl/xray.key --ecc --force; then
      print_ok "SSL 证书配置成功"
      sleep 2
    fi
  else
    print_error "SSL 证书生成失败"
    rm -rf "$HOME/.acme.sh/${domain}_ecc"
    exit 1
  fi
}

function ssl_judge_and_install() {
  if [[ -f "/ssl/xray.key" || -f "/ssl/xray.crt" ]]; then
    echo "/ssl 目录下证书文件已存在"
    echo -e "${OK} ${GreenBG} 是否删除 [Y/N]? ${Font}"
    read -r ssl_delete
    case $ssl_delete in
    [yY][eE][sS] | [yY])
      rm -rf /ssl/*
      echo -e "${OK} ${GreenBG} 已删除 ${Font}"
      ;;
    *) ;;

    esac
  fi

  if [[ -f "/ssl/xray.key" || -f "/ssl/xray.crt" ]]; then
    echo "证书文件已存在"
  elif [[ -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" ]]; then
    echo "证书文件已存在"
    "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath /ssl/xray.key --keypath /ssl/xray.crt --ecc
    judge "证书应用"
  else
    ssl_install
    acme
  fi

  # xray 默认以 nobody 用户运行，证书权限适配
  chown -R nobody.nobody /ssl/*
}

function configure_web() {
  rm -rf /www/xray_web
  mkdir -p /www/xray_web
  # 该处保留引用源
  wget -O web.tar.gz https://github.com/jiuqi9997/xray-yes/raw/main/web.tar.gz
  tar xzf web.tar.gz -C /www/xray_web
  judge "站点伪装"
  rm -f web.tar.gz
}
function xray_uninstall() {
  curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- remove --purge
  systemctl stop nginx
  rm -rf $website_dir
  print_ok "卸载完成"
  exit 0
}
function basic_information() {
  print_ok "vless+tcp+xtls+nginx 安装成功"
}

function show_access_log() {
  [ -f ${xray_access_log} ] && tail -f ${xray_access_log} || echo -e "${RedBG}log文件不存在${Font}"
}

function show_error_log() {
  [ -f ${xray_error_log} ] && tail -f ${xray_error_log} || echo -e "${RedBG}log文件不存在${Font}"
}

function bbr_boost_sh() {
    [ -f "tcp.sh" ] && rm -rf ./tcp.sh
    wget -N --no-check-certificate "https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
}

function mtproxy_sh() {
     wget -N --no-check-certificate "https://github.com/whunt1/onekeymakemtg/raw/master/mtproxy_go.sh" && chmod +x mtproxy_go.sh && bash mtproxy_go.sh
}

function install_xray() {
  is_root
  system_check
  dependency_install
  basic_optimization
  domain_check
  port_exist_check 80
  port_exist_check 443
  xray_install
  configure_xray
  nginx_install
  configure_nginx
  configure_web
  ssl_judge_and_install
  #  xray_qr_config
  basic_information
}

menu() {
  update_sh
  echo -e "\t xray 安装管理脚本 ${Red}[${shell_version}]${Font}"
  echo -e "\t---authored by wulabing---"
  echo -e "\thttps://github.com/wulabing\n"

  echo -e "—————————————— 安装向导 ——————————————"""
  echo -e "${Green}0.${Font}  升级 脚本"
  echo -e "${Green}1.${Font}  安装 xray (vless+tcp+xtls+nginx)"
  echo -e "—————————————— 配置变更 ——————————————"
  echo -e "${Green}11.${Font} 变更 UUID"
  echo -e "${Green}12.${Font} 变更 TLS 最低适配版本"
  echo -e "—————————————— 查看信息 ——————————————"
  echo -e "${Green}21.${Font} 查看 实时访问日志"
  echo -e "${Green}22.${Font} 查看 实时错误日志"
  #    echo -e "${Green}23.${Font}  查看 V2Ray 配置信息"
  echo -e "—————————————— 其他选项 ——————————————"
  echo -e "${Green}31.${Font} 安装 4合1 bbr 锐速安装脚本"
  echo -e "${Green}32.${Font} 安装 MTproxy(支持TLS混淆)"
  echo -e "${Green}33.${Font} 卸载 xray"

  read -rp "请输入数字：" menu_num
  case $menu_num in
  0)
    update_sh
    ;;
  1)
    install_xray
    ;;
  11)
    modify_UUID
    ;;
  13)
    modify_tls_version
    ;;
  21)
    xray_access_log
    ;;
  22)
    xray_error_log
    ;;
  31)
    bbr_boost_sh
    ;;
  32)
    mtproxy_sh
    ;;
  33)
    xray_uninstall
    ;;
  *)
    echo -e "${RedBG}请输入正确的数字${Font}"
    ;;
  esac
}
menu "$@"

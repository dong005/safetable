#!/bin/bash

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="/usr/local/safetable"
LOG_FILE="/var/log/safetable.log"

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -u, --uninstall  卸载服务和规则"
    echo "  -i, --install    安装服务"
    echo "  -r, --restart    重启服务"
    echo "  -s, --status     查看服务状态"
    echo "  --update         更新中国IP列表"
    echo "  --setup-repo     配置YUM源"
    echo "  --offline        离线安装（不下载IP列表）"
    exit 0
}

# 检查是否以root权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo "错误: 请使用root权限运行此脚本"
        exit 1
    fi
}

# 配置YUM源
setup_repo() {
    echo "正在配置YUM源..."
    
    # 备份原有的repo文件
    if [ -d "/etc/yum.repos.d" ]; then
        mkdir -p /etc/yum.repos.d/backup
        mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null
    fi
    
    # 复制CentOS-Base.repo文件
    if [ -f "$SCRIPT_DIR/CentOS-Base.repo" ]; then
        cp "$SCRIPT_DIR/CentOS-Base.repo" /etc/yum.repos.d/
        echo "已应用CentOS-Base.repo配置"
    else
        echo "警告: 未找到CentOS-Base.repo文件"
    fi
    
    # 清除缓存并重新生成
    yum clean all
    yum makecache
    
    echo "YUM源配置完成"
}

# 检查必要的软件包是否已安装
check_packages() {
    log "正在检查必要的软件包..."
    
    # 安装EPEL仓库
    if ! rpm -q epel-release &>/dev/null; then
        log "安装EPEL仓库..."
        yum install -y epel-release || {
            log "警告: 无法安装EPEL仓库，某些功能可能受限"
        }
    fi
    
    # 更新系统
    log "更新系统软件包..."
    yum update -y -q
    
    # 安装必要软件包
    local packages=("ipset" "iptables" "iptables-services" "wget" "curl")
    
    for pkg in "${packages[@]}"; do
        if ! rpm -q $pkg &>/dev/null; then
            log "安装 $pkg..."
            yum install -y $pkg || {
                log "错误: 无法安装 $pkg"
                return 1
            }
        fi
    done
    
    # 确保iptables服务已启用并启动
    systemctl enable iptables >/dev/null 2>&1
    systemctl start iptables >/dev/null 2>&1
    
    # 禁用firewalld（如果已安装）
    if systemctl is-active firewalld >/dev/null 2>&1; then
        log "检测到firewalld，正在停止并禁用..."
        systemctl stop firewalld
        systemctl disable firewalld
    fi
    
    # 加载必要的内核模块
    local modules=("ip_set" "xt_set" "ip_set_hash_net")
    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^${mod}"; then
            log "加载内核模块: $mod"
            modprobe $mod || {
                log "警告: 无法加载内核模块 $mod"
            }
        fi
    done
    
    # 确保模块在重启后自动加载
    echo -e "ip_set\nxt_set\nip_set_hash_net" > /etc/modules-load.d/safetable.conf
    
    log "软件包检查完成"
}

# 初始化中国IP列表
init_china_ip() {
    log "正在初始化中国IP列表..."
    
    # 创建IP列表目录
    mkdir -p "$CONFIG_DIR/data"
    CHINA_IP_FILE="$CONFIG_DIR/data/china.txt"
    
    # 检查是否为离线安装
    if [ "$OFFLINE_INSTALL" = "true" ]; then
        log "离线安装模式，使用预设的中国IP列表..."
        
        # 检查是否有预设的IP列表文件
        if [ -f "$SCRIPT_DIR/china_ip.txt" ]; then
            cp "$SCRIPT_DIR/china_ip.txt" "$CHINA_IP_FILE"
            log "使用预设的IP列表文件: $SCRIPT_DIR/china_ip.txt"
        else
            log "警告: 未找到预设的中国IP列表文件，将使用基本内网IP"
            # 创建基本的内网IP列表
            cat > "$CHINA_IP_FILE" << EOF
# 内网IP段
192.168.0.0/16
172.16.0.0/12
10.0.0.0/8
127.0.0.0/8
# 本地回环
::1/128
fe80::/10
fc00::/7
EOF
        fi
    else
        # 在线下载中国IP列表
        if command -v wget &>/dev/null; then
            log "正在从APNIC下载中国IP列表..."
            if ! wget --no-check-certificate -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' 2>/dev/null | \
                awk -F\| '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > "${CHINA_IP_FILE}.tmp"; then
                log "错误: 无法下载中国IP列表"
                return 1
            fi
            
            # 检查下载的文件是否有效
            if [ -s "${CHINA_IP_FILE}.tmp" ]; then
                mv "${CHINA_IP_FILE}.tmp" "$CHINA_IP_FILE"
                log "成功下载中国IP列表，共 $(wc -l < "$CHINA_IP_FILE") 个IP段"
            else
                log "错误: 下载的IP列表为空"
                return 1
            fi
            
            # 添加内网IP段到列表
            cat >> "$CHINA_IP_FILE" << EOF

# 内网IP段
192.168.0.0/16
172.16.0.0/12
10.0.0.0/8
127.0.0.0/8
# 本地回环
::1/128
fe80::/10
fc00::/7
EOF
        else
            log "错误: wget未安装，无法下载中国IP列表"
            return 1
        fi
    fi
    
    # 初始化ipset
    log "正在创建ipset集合..."
    ipset destroy china 2>/dev/null
    if ! ipset create china hash:net family inet hashsize 65536 maxelem 1000000; then
        log "错误: 无法创建ipset集合"
        return 1
    fi
    
    # 添加IP到ipset
    log "正在添加IP到ipset..."
    local count=0
    while read ip; do
        # 跳过空行和注释
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue
        
        if ipset add china "$ip" 2>/dev/null; then
            ((count++))
        fi
    done < "$CHINA_IP_FILE"
    
    # 保存ipset规则
    mkdir -p /etc/ipset
    ipset save > "/etc/ipset/ipset.rules"
    
    log "中国IP列表初始化完成，共添加 $count 个IP段"
    return 0
}

# 更新中国IP列表
update_china_ip() {
    echo "正在更新中国IP列表..."
    
    # 检查是否以root权限运行
    check_root
    
    # 检查并安装必要的软件包
    check_packages
    
    # 检查wget是否已安装
    if ! command -v wget &>/dev/null; then
        echo "错误: wget未安装，无法更新中国IP列表"
        exit 1
    fi
    
    # 创建IP列表目录
    mkdir -p "$CONFIG_DIR/data"
    CHINA_IP_FILE="$CONFIG_DIR/data/china.txt"
    
    # 下载最新的 IP 列表
    wget --no-check-certificate -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
        awk -F\| '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > "$CHINA_IP_FILE" || {
        echo "错误: 无法下载中国IP列表"
        exit 1
    }
    
    # 创建新的 ipset
    ipset create china_new hash:net maxelem 65536
    ipset flush china_new
    
    # 添加中国 IP
    while read ip; do
        ipset add china_new $ip
    done < "$CHINA_IP_FILE"
    
    # 添加内网 IP
    ipset add china_new 192.168.0.0/16
    ipset add china_new 172.16.0.0/12
    ipset add china_new 10.0.0.0/8
    ipset add china_new 127.0.0.0/8
    
    # 交换新旧 ipset
    ipset swap china_new china
    ipset destroy china_new
    
    # 保存新的配置
    mkdir -p /etc/ipset
    ipset save china > "/etc/ipset/china.conf"
    cp "/etc/ipset/china.conf" "$CONFIG_DIR/china.conf"
    
    # 应用 iptables 规则
    apply_iptables_rules
    
    echo "中国IP列表更新完成: $(date)" | tee -a $LOG_FILE
}

# 应用iptables规则
apply_iptables_rules() {
    log "正在应用防火墙规则..."
    
    # 检查ipset集合是否存在
    if ! ipset list china >/dev/null 2>&1; then
        log "错误: ipset集合'china'不存在，请先初始化中国IP列表"
        return 1
    fi
    
    # 加载必要的内核模块
    for module in ip_tables iptable_filter ip_conntrack ip_conntrack_ftp ip_nat_ftp; do
        modprobe $module 2>/dev/null
    done
    
    # 清空现有规则和链
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
    iptables -t nat -X
    iptables -t mangle -X
    
    # 设置默认策略
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # 允许本地回环
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # 允许已建立的连接
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # 允许Ping (ICMP)
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
    iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # 允许SSH连接（22端口）
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # SIP相关端口（5060-5080）只允许中国IP访问
    for port in 5060 5061 5070 5080; do
        # UDP协议
        iptables -A INPUT -p udp --dport $port -m set --match-set china src -j ACCEPT
        iptables -A INPUT -p udp --dport $port -j LOG --log-prefix "[SIP-UDP-DROP] " --log-level 4
        iptables -A INPUT -p udp --dport $port -j DROP
        
        # TCP协议
        iptables -A INPUT -p tcp --dport $port -m set --match-set china src -j ACCEPT
        iptables -A INPUT -p tcp --dport $port -j LOG --log-prefix "[SIP-TCP-DROP] " --log-level 4
        iptables -A INPUT -p tcp --dport $port -j DROP
    done
    
    # 允许DNS查询
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    
    # 允许NTP时间同步
    iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
    
    # 允许HTTP/HTTPS（用于yum更新等）
    iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
    
    # 记录被拒绝的数据包（限制日志大小）
    iptables -N LOGGING
    iptables -A INPUT -j LOGGING
    iptables -A LOGGING -m limit --limit 2/min -j LOG --log-prefix "[IPTABLES-DROP] " --log-level 4
    iptables -A LOGGING -j DROP
    
    # 保存iptables规则
    mkdir -p /etc/iptables
    if ! iptables-save > /etc/iptables/rules.v4; then
        log "警告: 无法保存iptables规则"
        return 1
    fi
    
    # 配置iptables服务
    if ! systemctl is-active iptables >/dev/null 2>&1; then
        systemctl enable iptables --now
    else
        systemctl restart iptables
    fi
    
    # 保存当前配置
    service iptables save
    
    log "防火墙规则应用完成"
    return 0
}

# 恢复防火墙规则
restore_firewall() {
    echo "正在恢复防火墙规则..."
    
    local iprule_file="$CONFIG_DIR/iprule.conf"
    local china_file="$CONFIG_DIR/china.conf"
    
    # 检查配置文件是否存在，如果配置目录下没有，则尝试从项目根目录复制
    if [ ! -f "$china_file" ] && [ -f "$SCRIPT_DIR/ipset_rules.conf" ]; then
        echo "从项目根目录复制 ipset 规则..."
        cp "$SCRIPT_DIR/ipset_rules.conf" "$china_file"
    fi
    
    if [ ! -f "$iprule_file" ] && [ -f "$SCRIPT_DIR/iptables_rules.conf" ]; then
        echo "从项目根目录复制 iptables 规则..."
        cp "$SCRIPT_DIR/iptables_rules.conf" "$iprule_file"
    fi
    
    # 再次检查配置文件是否存在
    if [ ! -f "$china_file" ]; then
        echo "错误: 未找到 ipset 规则文件"
        exit 1
    fi
    
    if [ ! -f "$iprule_file" ]; then
        echo "错误: 未找到 iptables 规则文件"
        exit 1
    fi
    
    # 清空现有规则
    iptables -F
    iptables -X
    iptables -Z
    
    # 恢复 ipset 规则
    echo "正在恢复 ipset 规则..."
    ipset restore < "$china_file"
    
    # 恢复 iptables 规则
    echo "正在恢复 iptables 规则..."
    iptables-restore < "$iprule_file"
    
    # 保存当前规则到项目根目录，方便查看
    if [ -d "$SCRIPT_DIR" ]; then
        iptables-save > "$SCRIPT_DIR/iptables_rules.conf"
        ipset save > "$SCRIPT_DIR/ipset_rules.conf"
        echo "当前防火墙规则已保存到项目根目录"
    fi
    
    # 显示当前规则状态
    echo -e "\n=== 当前 iptables 规则 ==="
    iptables -L -v -n --line-numbers
    echo -e "\n=== 当前 ipset 规则 ==="
    ipset list
    
    echo -e "\n防火墙规则恢复完成"
}

# 安装服务
install_service() {
    check_root
    
    echo "正在安装SafeTable服务..."
    
    # 配置YUM源（如果不是离线安装）
    if [ "$OFFLINE_INSTALL" != "true" ]; then
        setup_repo
    fi
    
    # 检查必要的软件包
    check_packages
    
    # 创建必要的目录
    mkdir -p $CONFIG_DIR
    chmod 755 $CONFIG_DIR
    
    # 复制脚本到安装目录
    cp "$SCRIPT_DIR/safetable.sh" $CONFIG_DIR/
    if [ -f "$SCRIPT_DIR/CentOS-Base.repo" ]; then
        cp "$SCRIPT_DIR/CentOS-Base.repo" $CONFIG_DIR/
    fi
    if [ -f "$SCRIPT_DIR/china_ip.txt" ]; then
        cp "$SCRIPT_DIR/china_ip.txt" $CONFIG_DIR/
    fi
    chmod +x $CONFIG_DIR/safetable.sh
    
    # 创建init.d服务文件
    cat > /etc/init.d/safetable << 'EOF'
#!/bin/bash
#
# safetable    Start/Stop the SafeTable Firewall service
#
# chkconfig: 2345 90 10
# description: SafeTable Firewall Rules for SIP protection

### BEGIN INIT INFO
# Provides: safetable
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: SafeTable Firewall Rules
# Description: SafeTable Firewall Rules for SIP protection
### END INIT INFO

# Source function library.
. /etc/init.d/functions

start() {
    echo -n "Starting SafeTable Firewall: "
    /usr/local/safetable/safetable.sh --restore
    RETVAL=$?
    if [ $RETVAL -eq 0 ]; then
        success
    else
        failure
    fi
    echo
    return $RETVAL
}

stop() {
    echo -n "Stopping SafeTable Firewall: "
    # 清除防火墙规则
    iptables -F
    RETVAL=$?
    if [ $RETVAL -eq 0 ]; then
        success
    else
        failure
    fi
    echo
    return $RETVAL
}

restart() {
    stop
    start
}

status() {
    echo "SafeTable 状态:"
    ipset list china | head -n 20
    echo "..."
    echo "iptables 规则:"
    iptables -L | grep china
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart|reload)
        restart
        ;;
    status)
        status
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
esac

exit $?
EOF
    
    # 添加执行权限
    chmod +x /etc/init.d/safetable
    
    # 创建定时更新任务
    cat > /etc/cron.d/safetable-update << 'EOF'
# 每周一凌晨更新中国IP列表
0 0 * * 1 root /usr/local/safetable/safetable.sh --update > /var/log/safetable-update.log 2>&1
EOF
    
    # 初始化IP规则
    init_china_ip
    
    # 初始化防火墙规则
    apply_iptables_rules
    
    # 保存初始规则到项目根目录
    if [ -d "$SCRIPT_DIR" ]; then
        iptables-save > "$SCRIPT_DIR/iptables_rules.conf"
        ipset save > "$SCRIPT_DIR/ipset_rules.conf"
        echo "初始防火墙规则已保存到项目根目录"
    fi
    
    # 启用并启动服务
    chkconfig --add safetable
    chkconfig safetable on
    service safetable start
    
    echo "SafeTable服务安装完成"
    echo "=================================="
    echo "服务名称: safetable"
    echo "配置目录: $CONFIG_DIR"
    echo "日志文件: $LOG_FILE"
    echo "定时更新: 每周一凌晨"
    echo "=================================="
}

# 卸载服务
uninstall_service() {
    check_root
    
    echo "正在卸载SafeTable服务..."
    
    # 停止服务
    service safetable stop 2>/dev/null
    chkconfig safetable off 2>/dev/null
    
    # 删除服务文件
    rm -f /etc/init.d/safetable
    rm -f /etc/cron.d/safetable-update
    rm -rf $CONFIG_DIR
    
    echo "卸载完成"
}

# 主函数
main() {
    # 初始化变量
    OFFLINE_INSTALL="false"
    
    # 处理 --restore 参数
    if [ "$1" = "--restore" ] || [ "$1" = "-r" ]; then
        restore_firewall
        exit 0
    fi
    
    # 如果没有参数，显示帮助
    if [ $# -eq 0 ]; then
        show_help
    fi
    
    # 处理命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -u|--uninstall)
                uninstall_service
                exit 0
                ;;
            -i|--install)
                shift
                # 检查是否有--offline参数
                if [[ "$1" == "--offline" ]]; then
                    OFFLINE_INSTALL="true"
                    shift
                fi
                install_service
                exit 0
                ;;
            -r|--restart)
                service safetable restart
                exit 0
                ;;
            -s|--status)
                service safetable status
                exit 0
                ;;
            --update)
                check_root
                update_china_ip
                exit 0
                ;;
            --restore)
                check_root
                restore_firewall
                exit 0
                ;;
            --setup-repo)
                check_root
                setup_repo
                exit 0
                ;;
            --offline)
                OFFLINE_INSTALL="true"
                # 如果只有--offline参数，则默认执行安装
                if [ $# -eq 1 ]; then
                    install_service
                    exit 0
                fi
                ;;
            *)
                echo "未知选项: $1"
                show_help
                ;;
        esac
        shift
    done
}

# 执行主函数
main "$@"

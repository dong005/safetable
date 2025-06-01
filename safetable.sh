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
    echo "正在检查必要的软件包..."
    
    # 检查ipset是否已安装
    if ! rpm -q ipset &>/dev/null; then
        echo "ipset未安装，尝试安装..."
        yum -y install ipset || {
            echo "警告: 无法通过YUM安装ipset，尝试使用本地安装..."
            if [ -f "$SCRIPT_DIR/packages/ipset.rpm" ]; then
                rpm -ivh "$SCRIPT_DIR/packages/ipset.rpm" || { 
                    echo "错误: 无法安装ipset"; 
                    exit 1; 
                }
            else
                echo "错误: 未找到ipset安装包，请手动安装ipset后重试"
                exit 1
            fi
        }
    fi
    
    # 检查iptables是否已安装
    if ! rpm -q iptables &>/dev/null; then
        echo "iptables未安装，尝试安装..."
        yum -y install iptables || {
            echo "警告: 无法通过YUM安装iptables，尝试使用本地安装..."
            if [ -f "$SCRIPT_DIR/packages/iptables.rpm" ]; then
                rpm -ivh "$SCRIPT_DIR/packages/iptables.rpm" || { 
                    echo "错误: 无法安装iptables"; 
                    exit 1; 
                }
            else
                echo "错误: 未找到iptables安装包，请手动安装iptables后重试"
                exit 1
            fi
        }
    fi
    
    # 检查wget是否已安装
    if ! rpm -q wget &>/dev/null; then
        echo "wget未安装，尝试安装..."
        yum -y install wget || {
            echo "警告: 无法通过YUM安装wget，尝试使用本地安装..."
            if [ -f "$SCRIPT_DIR/packages/wget.rpm" ]; then
                rpm -ivh "$SCRIPT_DIR/packages/wget.rpm" || { 
                    echo "错误: 无法安装wget"; 
                    exit 1; 
                }
            else
                echo "警告: 未找到wget安装包，将无法在线更新IP列表"
            fi
        }
    fi
    
    echo "软件包检查完成"
}

# 初始化中国IP列表
init_china_ip() {
    echo "正在初始化中国IP列表..."
    
    # 创建IP列表目录
    mkdir -p "$CONFIG_DIR/data"
    CHINA_IP_FILE="$CONFIG_DIR/data/china.txt"
    
    # 检查是否为离线安装
    if [ "$OFFLINE_INSTALL" = "true" ]; then
        echo "离线安装模式，使用预设的中国IP列表..."
        
        # 检查是否有预设的IP列表文件
        if [ -f "$SCRIPT_DIR/china_ip.txt" ]; then
            cp "$SCRIPT_DIR/china_ip.txt" "$CHINA_IP_FILE"
        else
            echo "警告: 未找到预设的中国IP列表文件，将使用基本内网IP"
            # 创建基本的内网IP列表
            cat > "$CHINA_IP_FILE" << EOF
192.168.0.0/16
172.16.0.0/12
10.0.0.0/8
127.0.0.0/8
EOF
        fi
    else
        # 在线下载中国IP列表
        if command -v wget &>/dev/null; then
            echo "正在下载中国IP列表..."
            wget --no-check-certificate -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
                awk -F\| '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > "$CHINA_IP_FILE" || {
                echo "警告: 无法下载中国IP列表，使用预设的IP列表..."
                if [ -f "$SCRIPT_DIR/china_ip.txt" ]; then
                    cp "$SCRIPT_DIR/china_ip.txt" "$CHINA_IP_FILE"
                else
                    echo "警告: 未找到预设的中国IP列表文件，将使用基本内网IP"
                    # 创建基本的内网IP列表
                    cat > "$CHINA_IP_FILE" << EOF
192.168.0.0/16
172.16.0.0/12
10.0.0.0/8
127.0.0.0/8
EOF
                fi
            }
        else
            echo "警告: wget未安装，无法下载中国IP列表，使用预设的IP列表..."
            if [ -f "$SCRIPT_DIR/china_ip.txt" ]; then
                cp "$SCRIPT_DIR/china_ip.txt" "$CHINA_IP_FILE"
            else
                echo "警告: 未找到预设的中国IP列表文件，将使用基本内网IP"
                # 创建基本的内网IP列表
                cat > "$CHINA_IP_FILE" << EOF
192.168.0.0/16
172.16.0.0/12
10.0.0.0/8
127.0.0.0/8
EOF
            fi
        fi
    fi
    
    # 初始化ipset
    ipset destroy china 2>/dev/null
    ipset create china hash:net maxelem 65536
    ipset flush china
    
    # 添加IP到ipset
    while read ip; do
        ipset add china $ip
    done < "$CHINA_IP_FILE"
    
    # 保存ipset规则
    mkdir -p /etc/ipset
    ipset save china > "/etc/ipset/china.conf"
    cp "/etc/ipset/china.conf" "$CONFIG_DIR/china.conf"
    
    echo "中国IP列表初始化完成"
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
    echo "正在应用防火墙规则..."
    
    # 清空现有规则
    iptables -F
    iptables -X
    iptables -Z
    
    # 设置默认策略
    iptables -P INPUT ACCEPT
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # 允许本地回环
    iptables -A INPUT -i lo -j ACCEPT
    
    # 允许已建立的连接
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # 允许Ping
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # 允许SSH连接（修改为您自己的SSH端口）
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # 允许SIP相关端口（5060-5080）
    iptables -A INPUT -p udp --dport 5060:5080 -m set --match-set china src -j ACCEPT
    iptables -A INPUT -p udp --dport 5060:5080 -j DROP
    iptables -A INPUT -p tcp --dport 5060:5080 -m set --match-set china src -j ACCEPT
    iptables -A INPUT -p tcp --dport 5060:5080 -j DROP
    
    # 保存防火墙规则到配置目录
    iptables-save > "$CONFIG_DIR/iprule.conf"
    
    # 同时保存到项目根目录，方便查看
    if [ -d "$SCRIPT_DIR" ]; then
        iptables-save > "$SCRIPT_DIR/iptables_rules.conf"
        echo "防火墙规则已保存到: $SCRIPT_DIR/iptables_rules.conf"
    fi
    
    echo "防火墙规则应用完成"
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

# 中国 IP 防护系统

这是一个基于 iptables 和 ipset 的防火墙系统，用于保护 SIP 服务（端口 5060-5080），只允许来自中国大陆的 IP 地址访问。系统包含自动更新机制和开机自启动功能。

## 功能特点

- 自动获取并更新中国大陆 IP 地址列表
- 保护 SIP 端口（5060-5080），阻止非中国大陆 IP 访问
- 支持 TCP 和 UDP 协议
- 系统重启后自动恢复防火墙规则
- 每周自动更新 IP 地址列表
- 包含内网 IP 地址（192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8）

## 系统要求

- Debian/Ubuntu 系统
- root 权限
- 依赖包：ipset, wget

## 安装方法

1. 将所有文件放在 `/root/sh` 目录下
2. 执行安装脚本：
   ```bash
   cd /root/sh
   ./install.sh
   ```

## 目录结构

- `/usr/local/firewall/`
  - `china.sh` - 初始化中国 IP 列表
  - `iprule.sh` - 设置 iptables 规则
  - `restore-firewall.sh` - 恢复防火墙规则
  - `update-china-ip.sh` - 更新 IP 列表

- `/etc/systemd/system/`
  - `china-firewall.service` - 防火墙服务
  - `china-ip-update.service` - IP 更新服务
  - `china-ip-update.timer` - 定时更新器

## 配置文件

- `/root/sh/china.conf` - IP 地址集合配置
- `/root/sh/iprule.conf` - iptables 规则配置
- `/etc/china.txt` - 中国 IP 地址列表

## 使用方法

### 查看服务状态
```bash
# 查看防火墙服务状态
systemctl status china-firewall.service

# 查看更新定时器状态
systemctl status china-ip-update.timer

# 查看当前 IP 规则
ipset list china

# 查看防火墙规则
iptables -L
```

### 手动操作

```bash
# 手动更新 IP 列表
systemctl start china-ip-update.service

# 重启防火墙服务
systemctl restart china-firewall.service
```

## 日志查看

- IP 更新日志：`/var/log/china-ip-update.log`
- 系统日志：`journalctl -u china-firewall.service`
- 更新器日志：`journalctl -u china-ip-update.service`

## 更新周期

- IP 地址列表每周自动更新一次
- 更新时间：每周一 00:00:00
- 数据来源：APNIC 官方统计数据

## 安全说明

1. 此系统会阻止所有非中国大陆 IP 对 SIP 端口的访问
2. 内网 IP 地址会被自动允许
3. 系统不会影响其他端口的访问规则

## 故障排除

1. 如果服务无法启动：
   ```bash
   journalctl -u china-firewall.service -n 50
   ```

2. 如果 IP 更新失败：
   ```bash
   journalctl -u china-ip-update.service -n 50
   ```

3. 如果需要重置规则：
   ```bash
   systemctl restart china-firewall.service
   ```

## 卸载方法

1. 停止并禁用服务：
   ```bash
   systemctl stop china-firewall.service china-ip-update.timer
   systemctl disable china-firewall.service china-ip-update.timer
   ```

2. 删除服务文件：
   ```bash
   rm -f /etc/systemd/system/china-firewall.service
   rm -f /etc/systemd/system/china-ip-update.service
   rm -f /etc/systemd/system/china-ip-update.timer
   ```

3. 删除脚本和配置：
   ```bash
   rm -rf /usr/local/firewall
   ```

4. 重新加载 systemd：
   ```bash
   systemctl daemon-reload
   ```

## 注意事项

1. 确保系统时间准确，这会影响自动更新的执行
2. 不要手动修改 ipset 规则，这可能会导致防护失效
3. 如果需要临时禁用防护，使用 `systemctl stop china-firewall.service`
4. 建议定期检查日志确保系统正常运行

## 技术支持

如果遇到问题，请检查：
1. 系统日志
2. 服务状态
3. IP 规则是否正确加载
4. 防火墙规则是否正确应用

## 许可证

This software is licensed under the GPL-2.0 License.

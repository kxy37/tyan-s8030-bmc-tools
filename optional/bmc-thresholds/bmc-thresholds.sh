#!/bin/bash
# bmc-thresholds —— 修正并**保持** BMC 传感器阈值
#
# 【为什么需要它】
# 有些主板的 BMC 把一个传感器的告警阈值设得过低，而该传感器恰好位于发热部件
# 附近，导致正常使用中反复误报（例如蜂鸣器长鸣 + 主板故障灯）。
# 典型例子：TYAN S8030 的 MB_Air_Inlet（主板进风温度）出厂上限只有 50°C，
# 而这块板的传感器位置正好在显卡散热鳍片下方 —— 装了 GeForce/Quadro 显卡后
# 显卡尾气直接吹在它上面，很容易撞线报警。
#
# 【为什么是一个服务 + 定时器，而不是一次 ipmitool 命令】
# 很多 BMC 在**完全断电（拔电源线）后会把可设阈值恢复成出厂默认值**。
# 单独执行 `ipmitool sensor thresh ...` 会在下次断电后失效。
# 本服务在「开机 30 秒后」以及「每 10 分钟」检查一次：
#   读当前实际生效的阈值 → 与目标不符才写回（幂等，不会反复刷写）。
#
# 【配置】/etc/bmc-thresholds.conf，每行：
#     <传感器名> <传感器编号(16进制)> <目标上限°C>
#   见 bmc-thresholds.conf.example
#
# 【手动运行】
#   sudo bmc-thresholds.sh                    # 用默认配置
#   sudo bmc-thresholds.sh /path/to/other.conf
#
# 【读取阈值的陷阱 —— 重要】
#   `ipmitool sdr get <名>` 显示的是 **SDR 记录里的出厂规格值，永远不变**，
#   不能用来判断你是否改成功了。
#   要看**实际生效值**，用以下任一方式：
#     ipmitool raw 0x04 0x27 <传感器编号>      # 第 6 字节 = 上限（16进制）
#     ipmitool sensor get <名> | grep -i "Upper critical"
#     ipmitool sensor | grep <名>              # 表格形式

set -u

CONF="${1:-/etc/bmc-thresholds.conf}"
LOGTAG=bmc-thresholds
rc=0

log() { logger -t "$LOGTAG" "$*" 2>/dev/null; echo "$*"; }

if [ ! -r "$CONF" ]; then
    echo "无法读取配置文件: $CONF" >&2
    exit 2
fi

if ! command -v ipmitool >/dev/null 2>&1; then
    echo "未找到 ipmitool，请先安装" >&2
    exit 2
fi

# 应用一条：$1=传感器名 $2=编号(如 0x32) $3=目标上限(°C)
apply_one() {
    local name="$1" num="$2" want="$3" raw cur curdec

    # Get Sensor Thresholds -> [读数, LNC, LCR, LNR, UNC, UCR, UNR]
    raw=$(ipmitool raw 0x04 0x27 "$num" 2>/dev/null) || {
        log "$name: 读取阈值失败（传感器编号 $num 是否正确？）"
        return 1
    }
    cur=$(printf '%s\n' "$raw" | awk '{print $6}')
    if [ -z "$cur" ]; then
        log "$name: 阈值响应异常: $raw"
        return 1
    fi

    curdec=$((16#$cur))
    if [ "$curdec" -eq "$want" ]; then
        echo "$name: 上限 $curdec°C —— 已是目标值，不动"
        return 0
    fi

    if ipmitool sensor thresh "$name" ucr "$want" >/dev/null 2>&1; then
        log "$name: 上限 $curdec°C -> $want°C 已应用"
        return 0
    fi
    log "$name: 写入 $want°C 失败"
    return 1
}

echo "=== bmc-thresholds（配置: $CONF）==="
applied=0
checked=0

# 注意：必须用 while read 按【行】读，不能写成 `for line in $VAR`
# （后者会按空白分词，把一行的三个字段拆成三个"行"，全部匹配失败）
while read -r name num want; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac          # 跳过注释
    [ -n "${want:-}" ] || continue                 # 跳过字段不全的行

    checked=$((checked + 1))
    apply_one "$name" "$num" "$want" || rc=1
done < "$CONF"

if [ "$checked" -eq 0 ]; then
    echo "配置文件里没有有效的阈值条目"
    rc=1
fi

exit $rc

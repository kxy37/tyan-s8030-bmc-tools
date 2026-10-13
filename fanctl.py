#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fanctl —— 给「BMC 不做风扇温控」的服务器主板加上 CPU 风扇自动调速。

背景
----
有些服务器主板的 BMC 把风扇钉死在固定占空比上，不随温度变化。以 TYAN S8030
系列（AMI MegaRAC BMC）为例：CPU 风扇出厂固定 30% 占空比，无论 CPU 多热都不动。

这类主板通常保留了厂商的 OEM IPMI 命令，可以直接设置某个风扇通道的占空比：

    ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 <风扇通道号> 0x01 <占空比 0x00~0x64>

本程序在主机侧定时读取 CPU 温度，按一条温度曲线计算目标占空比，再通过上述命令
下发，从而把「固定转速」变成「随温度自动调速」。

出处与致谢
----------
* 上述 OEM 命令最初由 Chiphell 论坛用户 wangmice 发现并公开：
  https://www.chiphell.com/thread-2604921-1-1.html
* 参考实现：
  - https://github.com/BiteMeIfYouCan/TYANS8030FAN  （Python，多分区曲线）
  - https://github.com/sonmihpc/AutoFan               （Go，GPU 温度驱动）
* 本程序为独立实现，未复制上述项目的代码。

安全设计
--------
* MIN_DUTY 默认等于出厂占空比（30%），因此任何时候都不会比原厂更热；
* 每周期最多变化 MAX_STEP%，避免转速忽高忽低；
* DEADBAND 死区防抖；
* 读不到温度 / 进程异常 / 收到 SIGTERM 时，一律切到 FAILSAFE_DUTY 保底；
* systemd 单元配了 Restart=always 与 ExecStopPost 兜底。

用法
----
    sudo ./fanctl.py --show-config      # 打印当前生效配置（不动作）
    sudo ./fanctl.py --once             # 只跑一轮，便于验证
    sudo ./fanctl.py --dry-run --once   # 只计算不下发（安全演练）
    sudo ./fanctl.py                    # 常驻运行（生产用 systemd 托管）

配置文件（可选，默认 /etc/fanctl.conf，见 fanctl.conf.example）。
命令行 --config 指定其它路径。
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import signal
import subprocess
import sys
import time

DEFAULT_CONFIG_PATH = "/etc/fanctl.conf"

# ---------------------------------------------------------------------------
# 默认值：适用于 TYAN S8030 系列（S8030GM2NE / GM4NE 等，AMI MegaRAC BMC）
# 其它主板请用配置文件覆盖 fan_idx 与 temp_sensor
# ---------------------------------------------------------------------------
DEFAULTS = {
    "fan_idx": 0x00,          # CPU 风扇通道号
    "temp_sensor": 0x01,      # 温度传感器编号（S8030 上 0x01 = CPU_Tctl_Value）
    "interval": 10,           # 采样周期（秒）
    "min_duty": 30,           # 最低占空比（建议 = 出厂值）
    "max_duty": 100,
    "failsafe_duty": 60,      # 保底占空比（读不到温度 / 退出时）
    "max_step": 15,           # 每周期最大变化量（%）
    "deadband": 2,            # 死区（%）
    "curve": [(45, 30), (55, 40), (65, 55), (75, 78), (85, 100)],
}

log = logging.getLogger("fanctl")


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
def parse_curve(text: str):
    """'45:30, 55:40, 65:55' -> [(45,30),(55,40),(65,55)]"""
    pts = []
    for item in text.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError(f"曲线格式应为 温度:占空比，收到 {item!r}")
        t, d = item.split(":", 1)
        pts.append((float(t), float(d)))
    if len(pts) < 2:
        raise ValueError("曲线至少需要两个点")
    pts.sort()
    return pts


def load_config(path: str):
    cfg = dict(DEFAULTS)
    if not path or not os.path.exists(path):
        return cfg, f"(未使用配置文件，全部取内置默认值)"
    used = []
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            key, val = (s.strip() for s in line.split("=", 1))
            if key not in DEFAULTS:
                log.warning("配置文件里无法识别的项，已忽略: %s", key)
                continue
            if key == "curve":
                cfg[key] = parse_curve(val)
            elif key in ("fan_idx", "temp_sensor"):
                cfg[key] = int(val, 0)          # 支持 0x00 写法
            else:
                cfg[key] = type(DEFAULTS[key])(val)
            used.append(key)
    return cfg, f"(读取配置文件 {path}，覆盖项: {', '.join(used) or '无'})"


# ---------------------------------------------------------------------------
# 曲线
# ---------------------------------------------------------------------------
def duty_for(temp_c: float, cfg) -> float:
    """分段线性插值，并夹在 [min_duty, max_duty] 之间。"""
    curve = cfg["curve"]
    if temp_c <= curve[0][0]:
        return cfg["min_duty"]
    if temp_c >= curve[-1][0]:
        return cfg["max_duty"]
    for (t0, d0), (t1, d1) in zip(curve, curve[1:]):
        if t0 <= temp_c <= t1:
            if t1 == t0:
                return d1
            return d0 + (d1 - d0) * (temp_c - t0) / (t1 - t0)
    return cfg["max_duty"]


# ---------------------------------------------------------------------------
# IPMI
# ---------------------------------------------------------------------------
SENSOR_INVALID = 0x20   # 状态字节该位置位 = 读数不可用


def read_cpu_temp(cfg, dry_run=False):
    """读 CPU 温度。失败返回 None（None 表示"不知道"，绝不当作 0 处理）。"""
    cmd = ["ipmitool", "raw", "0x04", "0x2d", f"0x{cfg['temp_sensor']:02x}"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        log.warning("读取温度超时")
        return None
    if out.returncode != 0:
        log.warning("ipmitool 读温度失败 rc=%s: %s", out.returncode, out.stderr.strip())
        return None
    fields = out.stdout.split()
    if len(fields) < 2:
        log.warning("温度响应异常: %r", out.stdout)
        return None
    try:
        reading, status1 = int(fields[0], 16), int(fields[1], 16)
    except ValueError:
        log.warning("温度响应无法解析: %r", out.stdout)
        return None
    if status1 & SENSOR_INVALID:
        log.warning("该温度传感器不可用（status 0x%02x）", status1)
        return None
    return reading


def set_duty(duty, cfg, dry_run=False):
    """下发占空比。"""
    duty = max(cfg["min_duty"], min(cfg["max_duty"], int(round(duty))))
    cmd = ["ipmitool", "raw", "0x2e", "0x44", "0xfd", "0x19", "0x00",
           f"0x{cfg['fan_idx']:02x}", "0x01", f"0x{duty:02x}"]
    if dry_run:
        log.info("[dry-run] 将下发: %s  (占空比 %d%%)", " ".join(cmd), duty)
        return True
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        log.error("下发占空比 %d%% 超时", duty)
        return False
    if out.returncode != 0:
        log.error("下发占空比 %d%% 失败 rc=%s: %s", duty, out.returncode, out.stderr.strip())
        return False
    log.info("CPU 风扇占空比 -> %d%%", duty)
    return True


# ---------------------------------------------------------------------------
# 控制循环
# ---------------------------------------------------------------------------
class Controller:
    def __init__(self, cfg, dry_run=False):
        self.cfg = cfg
        self.dry_run = dry_run
        self.last_duty = None
        self.stopping = False

    def tick(self):
        cfg = self.cfg
        temp = read_cpu_temp(cfg, self.dry_run)
        if temp is None:
            if self.last_duty != cfg["failsafe_duty"]:
                log.warning("读不到温度 —— 切到保底 %d%%", cfg["failsafe_duty"])
                set_duty(cfg["failsafe_duty"], cfg, self.dry_run)
                self.last_duty = cfg["failsafe_duty"]
            return

        target = duty_for(temp, cfg)
        if self.last_duty is None:
            log.info("CPU %d°C -> 占空比 %d%%（初始）", temp, round(target))
            if set_duty(target, cfg, self.dry_run):
                self.last_duty = round(target)
            return

        delta = target - self.last_duty
        if abs(delta) < cfg["deadband"]:
            log.debug("CPU %d°C -> 目标 %d%%（在死区内，保持 %d%%）",
                      temp, round(target), self.last_duty)
            return
        step = max(-cfg["max_step"], min(cfg["max_step"], delta))
        new_duty = round(self.last_duty + step)
        log.info("CPU %d°C -> 占空比 %d%%（目标 %d%%，原 %d%%）",
                 temp, new_duty, round(target), self.last_duty)
        if set_duty(new_duty, cfg, self.dry_run):
            self.last_duty = new_duty

    def shutdown(self, signum, _frame):
        if self.stopping:
            return
        self.stopping = True
        log.info("收到信号 %d —— 恢复保底占空比 %d%%", signum, self.cfg["failsafe_duty"])
        set_duty(self.cfg["failsafe_duty"], self.cfg, self.dry_run)
        sys.exit(0)


def describe(cfg):
    lines = [
        "生效配置:",
        f"  风扇通道号 (fan_idx)      : 0x{cfg['fan_idx']:02x}",
        f"  温度传感器 (temp_sensor)  : 0x{cfg['temp_sensor']:02x}",
        f"  采样周期 (interval)       : {cfg['interval']} 秒",
        f"  占空比范围                : {cfg['min_duty']}% ~ {cfg['max_duty']}%",
        f"  保底占空比 (failsafe)     : {cfg['failsafe_duty']}%",
        f"  每周期最大变化 (max_step) : {cfg['max_step']}%",
        f"  死区 (deadband)           : {cfg['deadband']}%",
        "  温度曲线 (温度°C : 占空比%):",
    ]
    for t, d in cfg["curve"]:
        lines.append(f"    {t:>6.1f} -> {d:>5.1f}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="CPU 风扇温度曲线自动调速（IPMI OEM 命令）")
    ap.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="配置文件路径")
    ap.add_argument("--once", action="store_true", help="只跑一轮就退出")
    ap.add_argument("--dry-run", action="store_true", help="只计算不下发")
    ap.add_argument("--show-config", action="store_true", help="打印配置后退出")
    ap.add_argument("--debug", action="store_true", help="输出调试日志")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    try:
        cfg, note = load_config(args.config)
    except Exception as exc:
        log.error("配置文件有误: %s", exc)
        return 2
    log.info("%s %s", describe(cfg), note)

    if args.show_config:
        return 0

    ctrl = Controller(cfg, dry_run=args.dry_run)
    if args.once:
        ctrl.tick()
        return 0

    signal.signal(signal.SIGTERM, ctrl.shutdown)
    signal.signal(signal.SIGINT, ctrl.shutdown)

    log.info("fanctl 启动: 通道 0x%02x, 曲线 %s, 下限 %d%%, 周期 %ds",
             cfg["fan_idx"], cfg["curve"], cfg["min_duty"], cfg["interval"])
    while True:
        try:
            ctrl.tick()
        except Exception:
            log.exception("控制循环异常 —— 切保底")
            set_duty(cfg["failsafe_duty"], cfg, args.dry_run)
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    sys.exit(main())

# 其它方案对比

本项目只解决 TYAN S8030 上的两个具体毛病，覆盖面窄。如果你的需求超出这个范围
（例如要给**多个风扇各自一条曲线**），下面这些方案更合适。

---

## 一、p2afan —— 寄存器级方案

仓库：<https://github.com/larkinwc/p2afan>

它**绕开厂商的 IPMI 命令**，从主机侧经 ASPEED 的 P2A 桥（`BAR1+0xf004` 写 AHB 地址，
`BAR1+0x10000` 开 64 KiB 窗口）直接读写 BMC 内部总线上 `0x1E786000` 处的 PWM/tach 控制器。

### 和本项目的区别

关键点：**它的执行对象和本项目是同一个**（都是 ASPEED 的 PWM 占空比寄存器），
区别只在"用什么途径去写"。

| | 本项目（fanctl） | p2afan |
|---|---|---|
| 写入对象 | ASPEED PWM 占空比寄存器 | **同一个寄存器** |
| 途径 | 厂商 IPMI 命令 `0x2e 0x44`（经 BMC 转发） | 主机侧 P2A 桥直接写 |
| 能控几个通道 | **只有厂商命令暴露的那些**（S8030GM2NE 实测只有 CPU_FAN） | **全部** PWM 通道 |
| 依赖 | 需要厂商命令存在 | 不依赖厂商命令，但要 P2A 桥可用 |
| 安装复杂度 | 低（一个 .py + systemd） | 较高（需要 `pwm-dump` / `map` 重扫本机映射） |
| 温度源 | IPMI 传感器 | IPMI / hwmon / 任意 PCI 设备 / 任意命令 |
| 4-pin 风扇 | ✅ 可控 | ✅ 可控 |
| **3-pin 风扇** | ❌ **控不了** | ❌ **同样控不了** |

### ⚠️ 常见误解：它**不能**解决 3-pin 风扇

**3-pin 风扇没有 PWM 输入脚是硬件层面的限制，换任何软件都绕不过。**
p2afan 写的是 PWM 占空比寄存器，所以它和本项目一样控不了 3-pin 风扇 ——
只能换成 4-pin PWM 风扇（或改用支持电压调速的硬件，服务器主板通常不支持）。

### 什么时候该用 p2afan

- 你需要给**多个风扇各自一条曲线**（例如 2 张显卡 + 硬盘笼 + CPU 分别按不同温度调速），
  而厂商命令只暴露了一个通道；
- 你的板子根本没有可用的厂商风扇命令；
- 你想要**比厂商命令更细的控制**（直接读写寄存器、可调 rise/fall、可 dump 寄存器状态排查）。

安装和配置细节见它的 [README](https://github.com/larkinwc/p2afan)。两个实操注意点：

- `install.sh` 在较新的 systemd 上会误判（它期望 `systemctl is-active` 返回 `unknown:4`，
  新版返回 `inactive:4`），需要照它的步骤手工安装；
- 它的通道↔风扇映射是在作者自己的机箱上推导的，**换机器必须用
  `p2afan pwm-dump` 和 `p2afan map` 重新推导**。

---

## 二、其它社区实现（同为 IPMI 命令路线）

| 项目 | 语言 | 特点 |
|---|---|---|
| [BiteMeIfYouCan/TYANS8030FAN](https://github.com/BiteMeIfYouCan/TYANS8030FAN) | Python | 多分区曲线（cpu / 机箱 / 硬盘 / PCIE），温度源用 lm-sensors、LSI 阵列卡、smartctl |
| [sonmihpc/AutoFan](https://github.com/sonmihpc/AutoFan) | Go | 按 **GPU 温度**调速，带 RPM 打包 |
| [AIMFIRST-VN/gigabyte-tyan-passive-gpu-fan-control](https://github.com/AIMFIRST-VN/gigabyte-tyan-passive-gpu-fan-control) | — | Gigabyte MZ92-FS0 / Tyan 被动散热显卡场景 |

它们和本项目走的是**同一条 IPMI 命令**（`0x2e 0x44`），所以**受同样的通道限制**：
在 S8030GM2NE 上同样只能控 CPU 风扇。

> 注意：`TYANS8030FAN` 的 README 里那张通道表（`0x00=cpu, 0x02=机箱, 0x03=硬盘, 0x04=PCIE`）
> 是在 **S8030GM4NE-2T** 上得到的，**在 S8030GM2NE 上实测不成立**（只有 `0x00` 有效）。
> 同厂商不同型号的固件差异，务必自己扫一遍确认。

---

## 三、怎么选

```
只是想给 CPU 风扇加个温度曲线？
  └─ 用本项目 fanctl（最省事，零依赖）

想给多个风扇各配一条曲线，且风扇是 4-pin？
  └─ 用 p2afan（先换 4-pin 风扇，再用 pwm-dump / map 重扫映射）

风扇是 3-pin？
  └─ 任何软件方案都无效。要么换 4-pin 风扇，要么改造风道/机箱
```

## 四、原始出处

`0x2e 0x44` 这条命令的最初发现者：Chiphell 用户 wangmice
《[今天无意中发现泰安S8030通过ipmi控制风扇速度的命令](https://www.chiphell.com/thread-2604921-1-1.html)》。
上面几个项目都引用了它。

# docs —— 参考资料

## S8030_v2.0c_031326.pdf

TYAN/MiTAC 官方主板手册：**MiTAC Server Board S8030 (MOA) User Guide, Rev. 2.0c, Mar. 2026**，
共 156 页。

**版权归 MiTAC Computing Technology Corporation 所有**，此处收录仅为方便对照本项目的技术判断。
官方下载入口：<https://www.tyan.com/support/download-center>（按 `S8030GM2NE` 查找）。
若权利人要求，会立即移除。

> ⚠️ 手册第 2 页的免责声明写明：本手册内容仅供参考，MiTAC 不对其准确性或适用性作任何担保。
> 因此**下面这些页码只作为定位线索**，动手前请以你手上实物/固件版本为准。

---

## 本项目相关的页码（导航）

| 页码 | 章节 | 和本项目的关系 |
|---|---|---|
| **p26** | 2.5 LED Definitions | 排查"主板亮红灯/橙灯"时对照 LED 定义 |
| **p33–34** | 2.8 Installing the Memory | **Memory Population Table** —— 4 条内存应插 C0/D0/G0/H0；A0/B0/E0/F0 只在插满 8 条时才列出 |
| **p72** | 3.3.10 Hardware Health Configuration | **`Fan Speed Control` [Manual / Full Speed]` 与 `PWM Minimal Duty Cycle`（出厂 30）**。手册原文明确建议：装 GeForce/Quadro 显卡时应把 `Fan Speed Control` 改成 `[Full Speed]` |
| **p141–144** | Appendix II: Fan and Temp Sensors | **传感器定义与板图位置**。`MB_Air_Inlet` = "Temperature of the M/B Air Inlet Area"，位于主板下边缘、紧贴 SYS_FAN2/FAN3 插座旁；`SYS_Air_Inlet` = 前面板外接传感器（未装则为 Absent） |

## 几句话的背景（为什么这些页码重要）

本项目的两个组件，都是在这台机器上**实际踩坑排查**出来的，手册里的这几页正好是判断依据：

1. **`fanctl`（CPU 风扇曲线）** —— 手册 p72 说明了主板的风扇策略是"Manual + 最低占空比"
   或"Full Speed"两种，**没有温度曲线选项**。这就是为什么 BMC 不随温度调速，
   也是为什么我们要在主机侧自己实现曲线。

2. **`bmc-thresholds`（阈值修正）** —— 手册 p141–144 给出了 `MB_Air_Inlet` 的**物理位置**，
   这是判断"为什么它老是撞 50°C"的关键：它就在主板边缘，装了显卡后尾气正好吹在它上面。
   配合实测数据（它的读数比"出风"传感器还高，物理上倒挂），可以确认它已经不在测进风了。

3. **内存插法（p33–34）** —— 排查"D0 通道不识别"时，这张表确认了 C0/D0/G0/H0 是官方
   推荐的 4 条插法（不是插错槽位），从而把问题收窄到硬件故障。

> 顺带一提：手册 p33 的板图显示，D0 是 CPU 插座上方那组内存中**最靠外**的一条
> （上排从内到外 A0 → B0 → C0 → D0），下方那组是 E0 → F0 → G0 → H0。
> 下方那组更靠近 PCIe/显卡区，所以实测 G0/H0 的温度比 C0/D0 高约 10°C。

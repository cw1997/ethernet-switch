# DE2-115 Quartus II 工程

双端口 100M 全双工 MII 交换机，带 PHY 状态、参数化监控、UART Console、LED、
LCD 和数码管。顶层为 `hdl/es_switch_de2_115_top.sv`，器件为 `EP4CE115F29C7`。
JP1 必须置于 **MII**，JP7 保持默认 2.5 V。

## 编译与连接

安装支持 Cyclone IV E 的 Quartus II 13.0sp1/13.1 Web Edition 及器件库。

```bat
build.bat
build.bat C:\altera\13.1\quartus
```

GUI 可打开 `ethernet_switch.qpf`。产物为 `output_files/ethernet_switch.sof`。
QSF 包含源文件、引脚和电平，SDC 包含时钟及板级约束。个别板卡使用 C8 速度等级，
请按实际器件修改 QSF 的 DEVICE。网口对端须支持自协商 100M 全双工。

## 按键与页面

- KEY0：按下保持系统复位。
- KEY1：清空 MAC 表，每次按下触发一次。
- KEY2：上一页；KEY3：下一页。
- 页面为汇总、端口0、端口1，首尾循环。LCD 与数码管共用页面，复位默认汇总。
- 功能按键消抖 20 ms；KEY2/KEY3 同时按下不切页。
- 页面控制按 `NUM_PORTS` 生成 N+1 页；板上实际连接两个网口。

## 显示

`HEX7..4` 为 RX pps，`HEX3..0` 为 TX pps。达到 10000 时除以 1000 显示整数
kpps；LEDG4/5 分别指示 RX/TX 单位。不依赖小数点。

LCD 两行分别为 RX/TX，末尾 k 表示 kbit/s，六位十进制值向下取整。前八字符为
ALL 时表示汇总，否则是零起始端口号的八位十六进制。例如 `00000000R100000k`
表示端口0 RX 为 100000 kbit/s。没有有效采样时显示横线。

绿色 LED：0 心跳，1 采样和 PHY 就绪，2/3 两端口收发允许，4/5 RX/TX 的 kpps
单位，6/7/8 分别指示汇总/端口0/端口1。

红色 LED：0..3 为 P0 RX/TX、P1 RX/TX 活动，保持 100 ms；4/5 端口错误，6 PHY
管理错误，7 Console 错误，8 队列窗口峰值达到 224/256 节拍，9..17 为四个收发
方向的平均负载条，每格 10%。错误灯保持至复位，具体原因使用串口查询。

## 参数与串口

`REFRESH_INTERVAL_MS=500` 配置采样毫秒数，必须为正。活动保持、消抖、PHY 轮询
独立计时。pps 和 bit/s 按实际窗口换算，不直接使用半秒计数。

串口编译期默认参数：

- `UART_BAUD_RATE=115200`
- `UART_DATA_BITS=8`
- `UART_PARITY=SW_UART_PARITY_NONE`
- `UART_STOP_BITS=1`
- `UART_FLOW_CONTROL=SW_UART_FLOW_NONE`

Console 支持 7/8 位、无/奇/偶校验、1/2 停止位及 RTS/CTS；独立 UART 另支持
5/6 位。FPGA 侧 RTS/CTS 低有效，已连接 UART_RTS/UART_CTS；None 模式无需握手线。
使用板载 RS-232，终端默认 115200/8N1/无流控。

```text
help
status
port 0
mac all
mac 1
```

支持 CR/LF/CRLF；端口参数是十进制零起始编号。输出为带字段名及单位的十六进制
整数，每条统计命令固定一份快照。一次处理一条命令；超长、非法、忙时输入有诊断。
详见[监控说明](../../../docs/monitor.zh-Hans.md)和[完整 ABI](../../../docs/monitor.md)。

## PHY 管理

释放复位后等待 20 ms，MDIO 逐地址探测 88E1111，板卡默认地址为 ENET0=16、
ENET1=17。仅通告 100M 全双工，关闭其他速率和暂停帧能力，再重启自协商。
每 100 ms 轮询，BMSR 读两次处理 latch-low，再读寄存器17确认速率、双工及解析
完成。仅确认 100M 全双工后允许收发；未知、无应答或不兼容模式不假报正常。
管理错误会重试，恢复后错误灯仍保持到复位。

MAC 表是尚未失效的学习记录，不是在线设备列表，老化默认关闭。断链期间不保证
排队帧交付，不提供重传或动态速率切换。

## 时钟与限制

核心直接使用 50 MHz，无 PLL；100M 八位组周期为四个核心周期。既有 MII TX_CLK
由负沿翻转分频，与数据边沿相隔 10 ns。SDC 沿用引脚处至少 5 ns 建立及最多 5 ns
布线偏斜预算；这低于 IEEE 的通用 15 ns 建立要求。

RX 仍直接采样 PHY 异步数据，没有异步 FIFO，不能宣称 RX CDC 已闭合。本次不
增加千兆或半双工。低速外设使用异步边界 SDC 例外，协议时序由 RTL 计数器和模型
验证，不等同于外设引脚级静态时序闭合。

引脚依据 [Terasic 官方手册](https://www.terasic.com.tw/attachment/archive/502/DE2_115_User_manual.pdf)
Tables 4-2/3/4/6/18：ENET、KEY、LED、HEX 为 2.5 V；LCD、UART、CLOCK_50 为
3.3-V LVTTL。寄存器依据 [Marvell 88E1111 手册](https://www.marvell.com/content/dam/marvell/en/public-collateral/transceivers/marvell-phys-transceivers-alaska-88e1111-datasheet.pdf)。

## 验证

```sh
ci/check-toolchain.sh
make lint rtl unit param mii rmii sim synth
```

`make monitor` 纳入 unit，覆盖统计、UART、页面、LCD、PHY 和 Console。满速及慢
端口洪泛测试逐周期比较持续管理读取与空闲接口的转发输出。

2026-11-05 本机 Quartus II 13.1 完整编译在综合前因许可报错：
`Error (292032): You cannot use the specified license with Remote Desktop`。
本次新增逻辑尚无 Fitter/TimeQuest 及实板验证结果。需在可用许可会话执行
`build.bat`，确认 50 MHz 和 MII 输出约束，再下载 SOF 检查实际外设。

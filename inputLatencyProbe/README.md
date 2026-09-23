# 第五人格输入到画面延迟探针

这个独立工具估算 macOS 收到 `mouseMoved` 后，到第五人格主游戏窗口出现可见画面变化之间的软件延迟，并保留可复查的原始数据。

## 编译

```bash
./buildIdentityVInputLatencyProbe.command
```

构建产物：

```text
./inputLatencyProbe/IdentityVInputLatencyProbe
```

## 运行

1. 启动“第五人格 Mac”，进入游戏并对准一面有纹理、没有动画的静态墙面。
2. 在终端运行下面的命令，然后在 30 秒内切回游戏：

```bash
./inputLatencyProbe/IdentityVInputLatencyProbe
```

3. 工具只会选择前台 bundle id 为 `com.xunfeng.identityv.mac` 的窗口，并过滤小于 `500×300` 的小窗，选择剩余窗口中面积最大的一个。
4. 听到开始提示音后，连续左右甩鼠 15–20 秒。幅度和速度可自然变化，不要完全匀速，也不要打开菜单或让其他角色/特效在画面中移动。听到第二声提示音后结束。

默认时长为 18 秒。指定 20 秒：

```bash
./inputLatencyProbe/IdentityVInputLatencyProbe --duration 20
```

## 权限

首次运行需要 macOS 的两项权限：

- **输入监控**：只让 `CGEventTap(listenOnly)` 读取 `mouseMoved` 时间戳和 X/Y delta。
- **屏幕与系统音频录制**：ScreenCaptureKit 只读取指定游戏窗口；配置中明确关闭音频和鼠标指针采集。

若权限不足，工具会发起系统请求、打印中文提示并退出。请到“系统设置 → 隐私与安全性”给 `IdentityVInputLatencyProbe`、终端或实际显示在权限列表中的宿主程序授权，完全退出该程序后再运行。工具不会代替用户修改系统设置。

## 输出

每次运行都会在这里创建独立目录：

```text
~/Library/Application Support/IdentityVOnMac/Diagnostics/InputLatency/
```

- `mouse_events.csv`：原始 CGEvent 时间戳、回调时间、X/Y delta、输入能量。
- `frame_samples.csv`：每帧时间、帧间隔、低分辨率亮度差异强度；不含画面像素。
- `correlation.csv`：`0–250 ms`、步长 `1 ms` 的互相关曲线。
- `raw_samples.json`：本次元数据及两路完整原始标量样本。
- `result.json`：延迟估算、置信度、分段稳定性、警告和测量边界。

## 测量边界

结果是 **software input-to-visible-window latency**：起点为 macOS 的 CGEvent 时间戳，终点为 ScreenCaptureKit 标记的目标窗口可见帧变化。它可用于比较 Wine/游戏/渲染链路，但不是完整的“手到光子”延迟。

明确不包含：

- 鼠标传感器、无线链路和 USB 上报到 CGEvent 之前的硬件延迟；
- 显示器从上到下的扫描输出；
- LCD/OLED 面板像素响应和过冲；
- 相机或高速摄影系统本身的延迟。

ScreenCaptureKit 的帧时间也会受窗口合成与采样量化影响，因此单次低置信度结果不宜当作绝对真值。建议相同场景重复测量 3 次，看估算是否集中。

工具不会注入键鼠输入，不会修改游戏或系统设置，不会保存截图、视频或音频。

## 分析自测

无需权限和游戏，可验证互相关实现能否找回已知的 73 ms 合成延迟：

```bash
./inputLatencyProbe/IdentityVInputLatencyProbe --self-test
```

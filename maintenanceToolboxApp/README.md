# 第五人格工具箱

这是维护者专用的单一诊断 App，与面向玩家的 RC1 启动器分开构建，也不会进入玩家发行 DMG。产物为 `maintenanceToolboxApp/build/第五人格工具箱.app`；公开候选的 bundle ID 是 `com.fengyin.identityv.toolbox`，可执行文件仍叫 `IdentityVMonitor`。旧 `com.xunfeng.identityv.monitor` 的偏好和系统授权不能仅凭新名字当作已转移，按[身份与旧安装兼容](../docs/firstPartyIdentity.md)分别处理。

```zsh
./buildMaintenanceToolbox.command
```

在项目根目录运行该命令只更新本地构建产物；查看新产物可用 `./devIterate.command toolbox run`，明确决定更新日常安装版时再用 `./installIdentityVApps.command toolbox`。安装器会备份旧 App 并在失败时尝试回滚；路径与恢复细节见[项目维护入口](../README.md)。工具箱源码位于 `maintenanceToolboxApp/Sources/`，图标在 `maintenanceToolboxApp/Assets/`；构建时共享 `sharedDiagnostics/GameHealth.swift`、`ResourceSampling.swift` 与 `DenseMonitoring.swift`。共享只涉及明确列入构建的源码，工具箱不接管玩家 App 的构建、分发或游戏管理。

它只识别 `dwrg.exe`、启动和精确停止自身持有的高密度采集器、导出同一时间窗的 Metal trace，并提供可拖拽、无标题、跨 Space 的性能浮窗。工具箱主 App 是唯一的 ScreenCaptureKit/TCC 请求者；浮窗是随工具箱按需启动的仅显示 accessory helper，只经 stdin 接收数值、EOF 后退出，不含采集或授权路径，因此能覆盖 Wine 独立全屏 Space 而不会增加第二个用户可见 App 或权限身份。它不能启动、结束、下载、修复或卸载游戏，也不控制 idv-login。

## 精简负载浮窗

2026-09-12 起只显示两行：`CPU 游戏 125%`、`GPU 游戏 62% · 全局 78%`（示例数值）。FPS、帧间隔、GPU 毫秒、Present Delay 和内存继续由 Metal HUD 提供。CPU 按最近约一秒的进程时间差计算，100% 代表一个逻辑核心；不会按整机核心数稀释。Wine 辅助进程可能脱离游戏的父子树，尚不能可靠合计整个容器，因此暂按风吟允许的方案只显示游戏主进程。

资源计数由独立 utility 队列每秒读取；显示浮窗不启动 ScreenCaptureKit，也不需要屏幕录制权限。GPU 全局值来自驱动设备忙碌率，游戏值来自当前 PID 的 AGX `AppUsage.accumulatedGPUTime` 增量；后者是 GPU 时间占比，可能受并行队列影响，不能与全局值直接相减。当前 M1 Pro/macOS 27 已用独立 Metal 负载验证；缺失、PID 更换、计数倒退或 GPU client 集合改变时显示 `--`。驱动字段并非稳定公共 API，升级后需复核。

联合采集同时写 `resource-metrics.jsonl`，包含全局 CPU、游戏 CPU/GPU、全局 GPU、游戏 RSS 和最后 GPU 提交标记，文件仍为独占 `0600`。浮窗不常驻显示采集状态或后台进程排名。疑似卡死检测、系统提示和确认重启由公开启动器承担，与工具箱是否打开无关；触发条件与限制见[启动器说明](../playerLauncherApp/README.md)。

## 画面变化率

点击工具箱里可见的“启用画面采集权限”才会调用 macOS 的屏幕录制授权；联合采集后台只预检，未授权则明确记录为部分失败，绝不自行弹窗。界面明确区分“未授权”“已授权（尚未开始采集）”和“已授权（采集中）”，并在 App 重新激活、点击刷新及授权请求完成后重新预检；若 macOS 尚未把刚授予的权限应用到当前进程，会明确提示完全退出后重新打开工具箱。采样只读取目标游戏窗口的中央区域，不保存截图、视频或音频。

`visual-fps.jsonl` 写入本轮采集目录，目录 `0700`、文件 `0600`。文件以 `O_EXCL|O_NOFOLLOW` 创建并由本轮持有到结束；已有文件、符号链接或写入失败都会 fail closed，且该轮不会把“没有一条数值”误报为成功。每约 250ms 一条，含 `captureFPS`、逐样本精确差异率 `sampleChangedFPS`、去除 TAA/微噪声后的 `perceptualVisualFPS`、平均采样差异、显著变化采样比、当前/最大连续无变化时间和状态。首帧不计为变化。这些分析数值只进日志，不再占据浮窗。

### 自动冻结栈

只有维护者显式开始“联合采集”、画面采集已实际输出且目标窗口在最近 0.5 秒内重新确认仍在屏幕上时，工具箱才会启用自动冻结栈。它要求刚发生过明显画面运动，随后中央 ROI 连续至少 `1s` 无感知变化、捕获帧率不少于 `15 FPS`；静态大厅、失去可见性或低 capture 速率均不会触发，并且恢复可见后必须先出现新的运动。每轮最多五次、事件之间至少 15 秒。

触发时只对当前受管记录中的同一 `dwrg.exe` PID 运行 `/usr/bin/sample <pid> 1 100 -mayDie -file /dev/fd/1`；启动前复验 PID、当前 UID 和精确 `dwrg.exe` 命令，绝不 sudo、绝不按名称等待、绝不触发任何 macOS 授权。`sample` 本身可能短暂 suspend 目标，因此使用约十次/秒的低频采样，并在 marker 中明确记录。`-file /dev/fd/1` 指向已经 `O_NOFOLLOW|O_EXCL` 打开的 `0600` stdout 文件描述符，避免工具在 `/tmp` 落副本；stderr 同样受管。两者写入本轮目录的 `FreezeStack-<时间>-<UUID>/` 私有子目录，另有记录实际静止时长的 `event.json` marker。`sample` 有 2.5 秒硬超时；TERM 后仍未退出会再有界 KILL 并由终止回调保留 ownership 至真正退出。停止联合采集、流停止或工具箱退出都会终止工具箱自己启动的 sample 子进程；停止后的过期事件不会再写 marker。失败只留下 marker，不影响高密度、画面或 Metal 采集。

## 联合采集与 Metal

2026-09-20 修复立即导出：GUI locale 导致中文进程路径被转义，以及读取快照时 Start 重入导致旧快照误判新采集器退出。统一 UTF-8 完整快照、拒绝过期观察，并提前锁定停止以免重复导出；Metal overview 的错误 JSON 不再算成功。本机曾完成一次采集/导出/停止回归，但迁仓后仍须以新候选复测权限与进程生命周期。

2026-09-11 修复：状态刷新不再丢弃待收尾采集的内存 ownership；Dense 自行退出时，本窗口自动结束画面记录并导出，重复停止在异步收尾前即被锁住。显示浮窗重复进入画面启动时复用本轮已独占打开的文件句柄，不重建同一路径。历史文件仍不自动接管；该契约由本仓的进程自检和生命周期测试覆盖。

联合采集固定包含高密度记录，可选择“包含画面变化率”和“导出 Metal trace”（默认都开启）。停止只对本窗口当前、经 PID/UID/目标 PID/可执行路径/输出路径复验的采集器发送 SIGTERM，并有界等待退出；确认停止后才会结束本轮画面记录和导出 Metal。视觉关闭而 Metal 开启时会明确显示“高密度 + Metal”，不是视觉失败。

Metal 导出只接受 `Diagnostics/Dense` 的直接受管子目录（逐级 `lstat`、当前 UID、私有目录、无符号链接），每轮新建一个不可预存的 `Metal-<结束毫秒>-<UUID>` 私有目录。`collect.stderr.log`、`overview.stderr.log` 和 overview JSON 都用独占、无跟随链接的 `0600` 文件创建；只接受该目录里新出现且唯一匹配目标 PID 的 trace。任一目录、文件、权限、collect 或 overview 校验失败都不会报告导出成功。

Metal HUD 开关只维护 `~/Library/Application Support/IdentityVOnMac/Maintenance/metal-hud.env`：`schema=1` 与 `enabled=0|1`。父目录逐级校验，缺失时只单级创建 `0700`；文件只接受当前 UID 的普通非链接 `0400/0600` 文件。写入经独占、无跟随链接的 `0600` 临时文件再 rename，并复验结果。它只影响下次启动或重启游戏，不会改变当前游戏、写全局环境或自动重启。第一版不在工具箱新增“诊断模式启动”：普通启动器的 runner 按自身最新版安装状态、所选区服和 `selectedEngineId` 启动，并静默读取这份维护者私有配置，只把 HUD 环境注入最终 `dwrg.exe`；工具箱不读取 runtime catalog、prefix 或游戏路径，因而 r1→r4 或区服切换无需同步适配。没有这份安全配置的普通用户完全不启用 HUD，公开启动器界面也不显示相关控件。

工具箱退出后不会接管历史 sampler；重新打开时只会把它显示为外部活动采集，不能安全地“停止并导出”旧记录。旧独立性能浮窗已退役，构建脚本会明确拒绝执行；工具箱只提示迁移，不会自动启动、结束或删除旧 App。

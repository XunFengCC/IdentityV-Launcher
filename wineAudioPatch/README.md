# Wine CoreAudio：仅暴露 macOS 默认输入设备

## 目的与范围

第五人格在 macOS 上启动时不应把内建麦克风、连续互通 iPhone 麦克风、耳机等每一个输入设备都呈现为独立的 Windows Capture endpoint。本提案让 Wine 只向 Windows 暴露 **当前 macOS 默认输入设备**；用户仍在“系统设置 → 声音 → 输入”里选择麦克风，下一次启动游戏时 Wine 随之读取新的默认设备。

输出设备枚举保持原样：游戏仍可看到 Wine 原先提供的全部播放设备。

这正好匹配产品意图：游戏不承担设备选择器，macOS 承担唯一的全局默认输入选择器。

## 已核对的 CodeWeavers 26.1 依据

最初的产品判断来自 Wine `wine-11.0` tag 的
`dlls/winecoreaudio.drv/coreaudio.c`：

- 源码：<https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winecoreaudio.drv/coreaudio.c#L219-L356>
- 原始文件 SHA-256：`fc1bc2fc50e6aba3b4750b1c3dbe882c391db1906d817c699b379152d9ce4724`
- tag 所指 Git 对象：`ce295733f9a67970b7f60d7af201f2ac16441a50`

`unix_get_endpoint_ids()` 已先按 flow 取得 `kAudioHardwarePropertyDefaultOutputDevice` 或 `kAudioHardwarePropertyDefaultInputDevice`，随后却无条件读取 `kAudioHardwarePropertyDevices` 并逐个生成 endpoint。当前仅用 `default_idx` 标识默认项，因而所有 input-capable macOS 设备都会进入 Windows 的 Capture 列表。

现在已在本机的 CodeWeavers 26.1 源码包上完成精确 rebase。这个包是当前
Wine 11 + DXMT 0.80 runtime 的来源记录；它不是用上游 Wine 11.0 替代品：

- 源码包：CodeWeavers 26.1 对应源码 `crossover-sources-26.1.0.tar.gz`，由维护者通过 `CROSSOVER_SOURCE_ARCHIVE` 指定本机路径；本仓不保存其私人下载位置。
- 包版本：`sources/wine/VERSION` = `Wine version 11.0`
- 源码包 SHA-256：`e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`
- 未修改 CodeWeavers `coreaudio.c` SHA-256：`635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c`
- rebase 后 `coreaudio.c` SHA-256：`275dd583074c5335432ea54104c111080e6f3a0cfcdaedf786bff88014d06324`

补丁在 `eCapture` 分支成功获得 `default_id` 后，直接分配一个只含该 ID 的本地
数组。于是 Capture 路径不会调用 `kAudioHardwarePropertyDevices` 的 DataSize 或
Data 查询，连全局设备列表本身都不读取；这才避免由 Wine 设备枚举唤起连续互通
等输入设备。`eRender` 仍完整保留原有的全局设备枚举与默认索引逻辑。

若默认输入查询失败，或返回 `kAudioObjectUnknown`，Capture 以 `S_OK` 返回零个
endpoint，不退回到全局设备枚举。这是有意的 fail-closed 行为：此时游戏暂时没有
语音输入，但不会为了“猜一个设备”而重新触发所有输入设备的枚举；用户恢复或选择
macOS 默认输入后，下次启动会重新读取它。

## 运行时适配边界

这台机器实际运行的是 **CodeWeavers Wine / CrossOver runtime**，不是这份原样
Wine 上游树。`default-input-only.patch` 现为供审查和隔离构建的 CodeWeavers
26.1 rebase；它仍然**不能直接替换 `winecoreaudio` 或投入发布**，直到完成与
实际发布配置一致的完整构建、分发签名和语音回归。

尤其不能把一份自行编译的 dylib 直接塞进当前已签名 runtime：这会破坏上游签名
边界，也没有经过该 runtime 的回归验证。现有模块
`lib/wine/x86_64-unix/winecoreaudio.so` 的 SHA-256 是
`64c2ff993e7e2341ef28a4b2fcc0bb23b0fa207ab3bcd89fa2963e8f3d319881`，由
`Developer ID Application: BIN WANG (CDBU86HA53)` 签名，带 hardened runtime。
隔离构建产物不得覆盖它；回滚就是继续使用这份未修改 runtime。

## 可复现隔离检查

[`verifyCodeWeavers26.1.command`](verifyCodeWeavers26.1.command) 会验证源码包与
源文件哈希、重放补丁，并在新建的 `build-26.1/rebuild-*` 目录中完成 native arm64
的 `dlls/winecoreaudio.drv/winecoreaudio.so` 编译。它不接触 runtime、prefix、
launcher、游戏，也不会访问麦克风。该检查需要 Bison >= 3.0；当前系统自带版本是
2.3，所以本轮把 Bison 3.8.2 也仅装在 `build-26.1/deps/` 内供检查使用，绝不写进
系统路径。

本轮结果会在每次新建的隔离 build root 中记录模块 SHA-256；最近一次 arm64
compile-check 产物为 `a6433da6514d6f673f31c16a9a9bc4ab7d84257935a12b2413ab3bd942bbc18b`。
源码级 rebase 的固定 SHA 是上面的 `275dd…06324`。它链接
CoreAudio、AudioUnit、AudioToolbox、CoreMIDI、AppKit 与 AVFoundation，说明精确
源码中的 CoreAudio 代码和补丁可完整通过模块编译。它不是发布物：现用 runtime
模块是 x86_64，本机缺少 CodeWeavers 原始 x86_64 PE 交叉编译工具链与 32-bit
development libraries，直接 `arch -x86_64 ./configure --enable-win64` 会在
`-mabi=ms` / MinGW 检查失败，普通 x86_64 configure 会在 32-bit libraries 检查
失败。因此尚不能声称与已发布 runtime 的完整 configure flags、第三方依赖闭包、
签名或可运行行为一致。该隔离产物仅带 linker 自动加入的 ad-hoc 签名、没有 Team
ID；它绝不能替换发布模块。

## 验收计划

1. 在隔离 prefix 中，以匹配源码构建的 runtime 启动 Wine；macOS 默认输入设为内建麦克风，同时让 iPhone 连续互通麦克风在线。
2. 在 Windows 声音 Capture 端点与游戏语音设置中确认仅存在一个输入设备，且语音录入正常。
3. 完全退出 Wine/游戏；在 macOS 系统设置切换默认输入，重新启动后确认唯一端点随之变更。
4. 输出端点数量、游戏声音和设备切换按未改 runtime 的基线回归。

## TCC 是独立问题

“只枚举默认输入”不能消除 macOS 麦克风权限要求。Wine CoreAudio 仍需在首次访问录音时获得一次 TCC 麦克风许可。

风吟的实际观察不是“每次启动都重复弹窗”：通常启动不会再询问，修改 runtime、签名身份或相关音频状态后较容易重新出现授权提示。这个低频再授权现象仍不能由本补丁推断为已修复；它属于稳定 bundle/signing identity、请求者归属和 TCC 记录是否持续的独立验证项。应在固定签名的最终 Wine loader/外壳上先连续全退出重开，再分别改变 runtime/签名与默认输入做对照；无论提示是否出现，每次启动都会重新枚举全部 Capture 端点才是本补丁要稳定消除的问题。

## 非目标

- 不创建虚拟声卡，不改系统默认输入，也不拦截其他 App 的音频。
- 不写 Wine prefix 注册表来隐藏设备；Wine 每次枚举后会重新生成端点，注册表删除不是持久方案。
- 不负责游戏内账号/登录状态，也不改变系统麦克风权限的用户控制权。

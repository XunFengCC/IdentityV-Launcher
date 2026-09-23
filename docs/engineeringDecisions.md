# 工程边界与验证依据

本文记录当前产品源码树的关键取舍。快速接手从[开发者指南](developerGuide.md)进入，版本变化看[变更记录](../CHANGELOG.md)，已退役操作入口看[历史命令](legacyCommands.md)。本页是公开可读的工程说明；个人账号、原始诊断、截图和本机运行记录保存在私人项目档案，不是阅读本仓的前置条件。

## 一个仓、两个 App

`第五人格启动器.app` 面向玩家，负责游戏下载、校验、启动、修复、卸载与反馈；`第五人格工具箱.app` 面向维护者，负责性能浮窗与按需采集。它们需要相同的游戏健康、资源采样和采集生命周期契约，所以代码同仓，构建与安装目标仍分开。游戏 runner 在启动器内嵌，不能把 `gameRunnerApp/` 当成另一个供玩家单独安装的桌面产品。

旧源码目录名曾使 `toolboxApp/` 指向玩家启动器、`monitorApp/` 指向维护者工具箱。独立仓以 `playerLauncherApp/`、`maintenanceToolboxApp/`、`gameRunnerApp/` 明确归属。`DenseMonitoring.swift` 被两款 App 编译，现归 `sharedDiagnostics/`；构建脚本显式列入共享源码，避免工具箱跨入玩家 App 的私有目录。构建和安装的对人入口分别用 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command`、`buildGameRunner.command` 与 `installIdentityVApps.command`，`devIterate.command` 仍按 `launcher`、`toolbox` 区分目标。

## 运行环境与分发输入

游戏、基础 Wine runtime、网易下载核心和可选 `idv-login` 不随玩家 App 打包；相关下载或组件按清单指定来源、版本和哈希，安装在用户环境。`runtimeBootstrap/releasePayloads/` 的四枚已签名 Wine 补丁是当前 App 构建所需的精确字节，因而纳入本仓而非依赖旧本机目录。`runtime-manifest.json` 的 `sha256` 校验分发字节，`sourceSha256` 对应签名前的来源字节；重新签名会改变前者，不可在构建时暗换。签名补丁与 runner 模板中的预编译输入不等于人写的源代码，相关来源、对应源码与许可证见[运行环境说明](../runtimeBootstrap/README.md)及[第三方材料](../notices/README.md)。

新仓从审查过的当前源码建立首个提交，后续正常开发在这里提交。旧私人仓的历史和原始现场另行保留，不导入未来可能公开的产品提交链；有价值的根因与适用条件在本仓用脱敏说明和测试表达。公开前仍须审查所有拟推 refs 可达的旧版本和元数据；凭据扫描只是辅助，不能证明没有个人信息。

这项选择在 2026-09-23 的独立仓基线中解决了一个具体复建问题：旧私人工作树把四枚**已签名** runtime 替换文件放在忽略目录，单凭原源码清单复建会缺失精确输入。新仓把这四枚已核来源与 SHA-256 的文件作为受控构建输入纳入版本管理，manifest 同时保存签名前来源哈希和当前分发哈希；[材料入口](../notices/README.md)给出对应源码与构建说明。这样可从干净克隆复建候选，但不能由“可复建”推论基础 CodeWeavers/Wine 闭包已有本项目再分发权。当前 RC1 仍由用户从锁定的上游地址取得基础 runtime；若改为本项目镜像，完整闭包 BOM、许可和源码审查需要另做。

## 签名、安装与验证的界限

目录和脚本名的可读性更改本身不改变 bundle ID、TCC/Keychain 身份、用户安装数据目录或兼容协议；这些是既有安装的身份与恢复契约。公开前第一方身份另按[具体迁移方案](firstPartyIdentity.md)调整，同时保留旧数据路径和必要兼容引用。构建脚本仅生成候选；`devIterate.command ... run` 会打开候选，`... install` 和 `installIdentityVApps.command` 才更新 `/Applications`。对 App 内脚本、资源或签名输入的修改须重建、签名并视发行目标重新公证。只有仓外文档或路径的改变不会追溯改变已签 DMG 的字节，但对应源码包与哈希仍须重算。

静态测试、两款 App 构建、签名树和 Gatekeeper 验证各覆盖不同条件；它们不代替干净 macOS 首次安装、授权提示、真实对局及国际服登录保持。当前 1.0.0-rc.1 仍是发布前候选，最终发行审查与公开上传是后续独立步骤。

`1.0.0-rc.1` 是 2026-09-09 选定的候选**版本名**，不是此后每轮相同版本号字节的功能验收。2026-09-23 新身份候选完成签名、公证与本机旧装升级，并由安装版内嵌 runner 进入国服大厅。初次游戏内语音发送报未检测到声音；后来从日用启动器正常启动、同一游戏会话里，合盖仍失败，开盖后可录入。引擎选择的是 MacBook Pro 内建麦克风，Apple [硬件安全说明](https://support.apple.com/en-au/guide/security/secbbd20b00b/web)明确 Apple silicon MacBook 合盖会断开内建麦克风，这解释了本次差异，不需要据无新弹窗重置 TCC。双服 GUI 之前漏走麦克风权限前置检查，已在候选源码补上；它是独立的首次授权路径修复，不是合盖无声的根因。

同一局较早时内建键盘 F 区曾有效，Rainy 75 外接键盘 F11 与 Fn+F11 均触发系统音量提示；稍后风吟重测，内建也与 Rainy 一样失效。watcher 较早的标准 F 行租约日志只能证实中间状态，不能证明她实际按键时仍持有租约。Rainy 75 [厂商手册](https://drivers.sfo3.digitaloceanspaces.com/Rainy_75_EN.pdf)把 Mac 模式的 F10–F12 单按列为媒体键，但不能用手册上的切换预期冒充本机解决。风吟又换一把外接键盘：F1–F9 单按被游戏捕获，F10/F12 触发系统音量 HUD、F11 显示桌面；Fn+F10/F11/F12 得到无 HUD 的预期音量行为。这里无 HUD 路径是游戏进程经 CoreAudio 调**当前 macOS 默认输出设备**，不是独立游戏音量；有 HUD 通常是系统媒体键处理路径。对应时段 runner 多次记录 `mode change unavailable` 并撤回租约。因此“Rainy 固件是唯一原因”“整个外接 F 区失效”都已被反证。正常结束游戏后，同一四键盘服务集合的短时探针能成功写入并恢复租约，这又推翻“当前接口静态永久拒写”；运行中失败条件和特殊键 usage/系统热键路径仍待分辨。反复切窗这轮没有爆音；原先声学异常仍是一次真实反馈，目前既未重现，也没有根因修复。用户可见的当前状态集中在[变更记录](../CHANGELOG.md)，身份升级的已证实范围和兼容理由在[第一方身份说明](firstPartyIdentity.md)；原始私人现场不作为公开文档的必读前置。

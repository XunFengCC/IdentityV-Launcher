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

`1.0.0-rc.1` 是 2026-09-09 选定的候选**版本名**，不是此后每轮相同版本号字节的功能验收。2026-09-23 新身份候选完成签名、公证与本机旧装升级，并由安装版内嵌 runner 进入国服大厅；游戏内发送语音仍报未检测到声音，前台 F11 的系统音量提示与项目 F 区说明有待核对，切窗时偶发声音异常。此前的麦克风流初始化与 watcher“已进入标准 F 键行”日志，只证明中间步骤，不能覆盖用户这次端到端反例；现阶段尚未判定是身份迁移回归、既有缺陷还是环境因素。用户可见的当前状态集中在[变更记录](../CHANGELOG.md)，身份升级的已证实范围和兼容理由在[第一方身份说明](firstPartyIdentity.md)；原始私人现场不作为公开文档的必读前置。

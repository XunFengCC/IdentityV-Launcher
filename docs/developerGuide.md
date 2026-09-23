# 开发者指南：项目框架与维护入口

这是已有 macOS 开发基础的维护者接手本仓时的路径。玩家的安装与使用看[项目首页](../README.md)；逐个顶层对象及脚本副作用看[项目地图](../projectMap.md)。本页说明模块如何协作、从哪里改、如何验证，不重复目录清单。关键取舍与兼容原因在[工程边界](engineeringDecisions.md)和[第一方身份迁移](firstPartyIdentity.md)；发行材料与签名分别有[封包](../releasePackaging/README.md)、[签名](../signing/README.md)说明。

## 运行与构建关系

玩家 App 的界面和调度位于 `playerLauncherApp/Sources/`。下载与校验依次由 `productCatalog/`、`productManager/`、`manifestPlanner/`、`gameDownloader/` 等模块负责；共享 Wine/DXMT 输入由 `runtimeManifest/` 与 `runtimeBootstrap/` 锁定、取得和核验。玩家点启动游戏后，内嵌的 `gameRunnerApp/IdentityV-Mac.app` 承接启动命令，调用 Wine，再进入游戏。`gameRunnerApp/IdentityV-AGTK.app` 是历史/开发模板，不在当前玩家 App 内出货。

维护者工具箱的 UI、浮窗和采集在 `maintenanceToolboxApp/Sources/`，独立构建与安装。两款 App 显式编译 `sharedDiagnostics/` 的健康、采样、采集状态和受限旧偏好迁移源码；工具箱不调用玩家 App 的私有源码目录。游戏运行数据、账号、prefix 与基础 runtime 在用户环境，仓库中保存来源、版本与哈希契约，并非真实用户数据。模块的逐项归属和源码入口见[地图](../projectMap.md)。

## 修改一处功能时

1. 先从界面所属 App 的 README 与 `Sources/` 找调用，再沿上面的模块关系定位实现；若跨两款 App，确认是明确共享的行为再放入 `sharedDiagnostics/`。先看对应测试与[工程取舍](engineeringDecisions.md)，避免只复制旧兼容分支。
2. 在当前用户游戏/App 未依赖的隔离工作副本中修改。根入口 `./devIterate.command launcher build`、`./devIterate.command toolbox build` 只生成候选；玩家启动器构建还会更新仓内 runner 模板、签名输入与可再生输出，不能在有运行中的同一路径候选时原地覆盖。`keyboard build` 仅构建键盘组件，不产生可安装 App。需构建工具以各脚本的实际前置为准；主要使用 macOS SDK/Xcode 命令行工具，玩家构建还调用 Go 与若干本仓检查。
3. 优先跑改动模块自己的合约测试，再对受影响 App 做完整构建与签名树/部署目标检查。构建脚本会调用多项自检；通过只证明对应静态与候选条件。`./devIterate.command … run` 会打开候选，`… install` 或 `./installIdentityVApps.command` 会替换 `/Applications` 并备份旧 App，这两步属于明确安排的真实运行/安装验收，不能和 `build` 混用。
4. 若更改 App/runner 内容或签名输入，发行候选需从确切源码提交重建、签名、公证并重算对应源码与材料哈希；纯文档整理不回写已签 App。版本及对用户的变化同步[变更记录](../CHANGELOG.md)，原因、失败路径和适用边界留在相关测试、代码注释或工程说明。结构、入口或脚本效果改变时，同步[项目地图](../projectMap.md)；普通函数细节不必改地图。

## 入口和兼容边界

日常开发用 `devIterate.command`；独立构建用 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command` 和由玩家构建调用的 `buildGameRunner.command`。封包器 `releasePackaging/buildAlpha1Preview.command` **仍是现役脚本**，其中 `Alpha1` 只是保留的历史文件名，实际版本取 App 元数据，不应用文件名推断版本。旧独立 runner 安装器和退役浮窗入口已退出仓库根目录；缘由及恢复旧实现的方法见[历史命令](legacyCommands.md)。其余根脚本的读/写、安装、提权和服务影响以[地图的命令表](../projectMap.md#根目录文件构建与开发入口)为准，不要把 `*.command` 当作说明文档双击。

第一方 bundle ID、Developer ID 签名、TCC、Keychain service/account 与用户运行数据目录分别是兼容契约。改源码目录名不自动迁移它们；需要改变身份时按[身份方案](firstPartyIdentity.md)核旧数据与恢复。已有本地候选不等于可公开发布：公开前还要审查拟推 Git refs、隐私、许可证、最终包和真实安装/游戏结果。

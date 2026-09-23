# 第五人格启动器 · IdentityV Launcher

这是在 Apple Silicon Mac 上运行《第五人格》PC 互通版的非官方项目。**第五人格启动器**供玩家管理国服和国际服的下载、校验、启动、修复、卸载与本地反馈；**第五人格工具箱**供维护者看性能浮窗、启动联合采集并导出诊断。两款 App 同仓，构建、安装和分发各自独立。原创代码采用 [GPL-3.0-or-later](LICENSE)；游戏、Wine、DXMT、网易下载核心和 `idv-login` 各遵循原有来源与许可，见[第三方材料](notices/README.md)。

目前是 **1.0.0-rc.1 发布准备**，尚未公开发布。本机候选曾通过 Developer ID 签名和公证；迁入本仓及目录更名后须从新根目录重新验证，不能据此推定首次安装、所有 macOS 版本或真实对局已通过发行验收。玩家 DMG 仅包含启动器，工具箱供维护者单独使用。启动器内嵌游戏 runner，但不夹带游戏本体、基础 Wine runtime、网易下载核心或可选 `idv-login` 二进制。

初次接触代码先读[项目地图](projectMap.md)：它解释源码、构建、候选、运行时和测试，并逐项说明本仓当前根文件与顶层目录。想了解为何两款 App 同仓、共享源码和已签补丁如何管理，读[工程边界](docs/engineeringDecisions.md)。玩家可见的当前限制见[随 App 打包的说明](playerLauncherApp/Resources/currentRoute.md)。

## 支持范围与现状

首版目标是 Apple Silicon Mac 和 macOS 15。可执行文件的静态部署目标检查覆盖 macOS 14，但还需相应系统上的真实首次安装与授权回归。国服曾在本机完成下载、登录、进厅、对局、输入、声音与重启；国际服到达登录/大厅资源阶段，扫码后的登录保持仍待实际用户验证。游戏更新、反作弊和服务端变化可能使旧结果失效。

两服的游戏文件与 Wine prefix 独立，运行环境共享。运行环境与可选组件按锁定来源下载和校验；相关契约见[运行环境](runtimeBootstrap/README.md)、[产品目录](productCatalog/products.json)及[IDV Login 组件](idvLoginComponent/README.md)。玩家的已安装 App、游戏数据与 Keychain 身份不由源码目录更名自动改变。

## 构建、运行、安装

在本仓根目录使用 `devIterate.command`。默认 `build` 只生成候选；`run` 会打开候选，`install` 会更新 `/Applications` 并保留旧 App 备份。阅读脚本不会执行它们，运行前先确认选择的动作。

```zsh
./devIterate.command launcher build   # playerLauncherApp/build/第五人格启动器.app
./devIterate.command toolbox build    # maintenanceToolboxApp/build/第五人格工具箱.app
./devIterate.command keyboard build   # 只构建键盘组件
```

独立构建入口为 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command`；`buildGameRunner.command` 负责内嵌 runner。`installIdentityVApps.command` 明确安装目标，先验签、更新 `/Applications` 并备份旧版，失败时尝试恢复。构建目录与真正安装态不要混同；只为检查源码时无须运行安装器。构建输入、签名与候选封包步骤见[发行说明](releasePackaging/README.md)及[签名说明](signing/README.md)。

反馈可从启动器界面生成本地脱敏诊断包，再交由邮件客户端由用户检查并发送；应用不会替用户静默发送。产品源码入口在[playerLauncherApp](playerLauncherApp/README.md)和[maintenanceToolboxApp](maintenanceToolboxApp/README.md)，共有的健康、采样与采集状态逻辑在 `sharedDiagnostics/`。修改用户可见文案时，要核对 App 内说明、发行介绍和实际包内容一致。

## 发行前仍需完成

从本仓新根目录复建两款 App、检查对应源码和第三方材料，再针对最终候选做干净环境首次安装、TCC/IDV Login 授权、国服对局与国际服登录保持回归。公开仓历史、暂存文件及发行物还须按隐私和许可证逐项审查。签名、公证或源码哈希通过只说明各自所检验的条件，不代表这些真实场景已经完成。

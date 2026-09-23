# 历史命令与现役入口

仓库根目录只放当前构建、维护或安装流程仍可能使用的命令。脚本是否留在根目录按调用关系和实际效果判断，不按文件名是否旧式命名一刀切。完整现役命令及副作用见[项目地图](../projectMap.md)；一般开发从[开发者指南](developerGuide.md)中的 `devIterate.command` 开始。

| 历史入口 | 退出根目录的原因 | 当前做法 |
| --- | --- | --- |
| `buildIdentityVOverlayApp.command` | 旧独立性能浮窗已并入维护者工具箱；原脚本只打印退役错误并退出，仓内外的活动脚本无调用。根目录保留它会暗示仍有一款可构建的旧 App。 | 构建 `maintenanceToolboxApp` 用 `devIterate.command toolbox build` 或 `buildMaintenanceToolbox.command`。 |
| `installIdentityVLauncherApp.command` | 原入口把 `gameRunnerApp/IdentityV-Mac.app` 单独装作 `/Applications/第五人格 Mac.app`，并要求旧 bundle ID `com.xunfeng.identityv.mac`。当前模板已是内嵌的 `com.fengyin.identityv.runner`，所以原脚本的身份检查必然拒绝；仓内外活动源码/脚本无调用。它不适合作为新候选的兼容安装壳。 | 玩家安装只走已验签、备份旧 App 的 `installIdentityVApps.command launcher`；runner 随玩家 App 内嵌，不单独安装。 |

这两份脚本的原字节仍可从 Git 历史找到；需要审查旧行为时，先用 `git log --all -- <文件名>` 找到删除前的提交，再以 `git show <提交>:<文件名>` 只读查看。恢复旧 App 应使用事先保存并验签的**旧安装备份**，不能拿当前 runner 模板运行旧安装器。私人旧工程树另有可恢复归档，但本公开文档不依赖它。

仍留根目录的几个旧式名称有实际调用：`releasePackaging/buildAlpha1Preview.command` 是现役封包器，版本从 App 元数据读取；`installIdentityVIdvLoginLauncherShim.command` 被 `updateIdentityVIdvLoginComponent.command` 调用；`stopIdentityVMonitoring.command` 仍被玩家 App 作为旧监测清理资源装包。它们的作用与退出条件应在改动调用链时一起复核，不能仅因为名字历史化就删除。`buildIdentityVCommandGraveForwarder.command` 等附带 `--install-active` 的特殊模式仍可能改已装 App，日常完整构建并不调用这些安装模式。

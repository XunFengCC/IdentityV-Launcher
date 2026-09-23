# 第一方身份与旧安装兼容

当前仓的产品前缀采用 `com.fengyin.identityv`。这是本项目选择的反域名式命名空间，不声称持有 `fengyin.com`，也不更改 Apple 开发者账户、Team ID、Developer ID 证书姓名或第三方组件身份。下面的映射只针对本仓实际出货的第一方代码；源码目录、进程显示名和用户数据路径不按 bundle ID 全局替换。

| 对象 | 旧标识 | 新标识及理由 |
| --- | --- | --- |
| 玩家桌面 App | `com.xunfeng.identityv.launcher` | `com.fengyin.identityv.launcher`；玩家入口。 |
| 维护者工具箱 App | `com.xunfeng.identityv.monitor` | `com.fengyin.identityv.toolbox`；产品是一款工具箱，监测只是其中一项能力。 |
| 玩家 App 内嵌游戏 runner | `com.xunfeng.identityv.mac` | `com.fengyin.identityv.runner`；只负责交给 Wine 启动游戏，不是第二款玩家桌面 App。 |
| 玩家 App 辅助程序 | `...launcher.hang-prompt`、`...launcher.microphone-authorization`、`...toolbox.{product-manager,download-supervisor,manifest-planner,downloader-core-bootstrap,global-adapter,runtime-bootstrap,diagnostic-exporter}` | 统一到 `com.fengyin.identityv.launcher.<职责>`；原 `toolbox` 是玩家 App 的旧目录名，不再用于新签名。IDV Login downloader 同属玩家 App。 |
| 工具箱采样/展示辅助程序 | `...monitor.sampler`、`...monitor.display` | `com.fengyin.identityv.toolbox.sampler`、`.toolbox.display`；归属独立维护者 App。 |
| runner 内自研辅助程序和音频 dylib | 原 `...function-keys`、`...game-activator`、`...login-dns-compat`、`...mouse-acceleration-controller`、`...command-grave-forwarder` 及按文件名自动生成的音频签名标识 | 统一到 `com.fengyin.identityv.runner.<职责>`；音频候选按阶段各有确定标识。 |
| 内嵌安装状态检查工具 | `...privileged-state` | `com.fengyin.identityv.installer.privileged-state`；可在安装授权后运行，但本次构建验证不运行安装器。 |

`gameRunnerApp/IdentityV-AGTK.app` 是没有进入当前玩家 App 的历史/开发模板，保留其旧 `...agtkwine` 身份供旧路线辨认，不为表面一致性改变它。四枚已有签名和哈希锁定的 runtime patch 是独立发行输入，本次不重签、不改它们的 ID 或哈希；第三方 Wine、网易下载核心和 `idv-login` 的身份也不改。

有些旧标识必须继续**作为兼容查询目标**出现，不能当成新签名遗漏：新的 IDV Login 临时 launchd 服务是 `system/com.fengyin.identityv.idv-login`，启动和停止组件在替换共享 plist 或清理 Hosts 前也撤销旧 `system/com.xunfeng.identityv.idv-login`，避免升级后两个代理并行；卸载器缺少停止组件时同时检查两种标签。旧浮窗的 `...overlay` / `...monitor-overlay` 仍供精确识别、停止或卸载；旧 runner 和工具箱 ID 仍用于辨认迁移期间可能运行的旧进程。CoreAudio 设备别名 UID `com.xunfeng.identityv.system-default-input.v1` 是音频设备选择契约，保留以免用户的旧选择断开。Swift Dispatch 队列标签不参与 App 身份、TCC 或 Keychain，源码更新它们只是可读性整理。

## 用户数据、权限和升级

- 文件态数据继续使用 `~/Library/Application Support/IdentityVOnMac`、`~/Library/Logs/IdentityVOnMac`、`~/Library/Application Support/第五人格` 和既有系统组件目录；不搬迁游戏、prefix、runtime、IDV Login 配置或系统 CA。新 App 使用旧文件路径时须沿用已有所有权和符号链接防护。
- 旧玩家 App `UserDefaults` 域中实际存在登录跟随、授权说明确认和窗口位置等键；旧工具箱域中存在窗口位置。新 App 在首次运行、任何业务模型读取偏好之前，从**确切旧域**只读取已知键，按类型复制到新域；已有新值优先，迁移一次后用新域 marker 防止把旧值反复覆盖。迁移不读取或写出密码，不删除旧域，也不触发系统提示。旧 App 仍可从原偏好和安装备份恢复。
- 本项目第一方用户设置没有使用随 bundle ID 改变的 Keychain service/account；公证 profile、代码签名证书仍在既有 Keychain。系统 Keychain 中由 IDV Login 管理的 CA 是独立的已登记状态，本阶段不导入、导出或改信任。若后续实机发现未覆盖的 Keychain 访问约束，以实物为准再补迁移，不据静态搜索宣称必然无影响。
- 新 bundle ID 可能使 macOS 将麦克风、屏幕录制、AppleEvents 等视作新的权限请求者。源 plist 和 Hardened Runtime entitlements 要随新 ID 匹配，签名与公证验证其声明；**构建成功不证明旧 TCC 授权转移**。日用 App 升级时先保留旧 App 备份，按可见提示由用户确认实际授权；真实首次安装和旧装升级分别验收，不静默触发系统弹窗。

## 验证与回退顺序

1. 从干净提交构建玩家 App 和工具箱，枚举包中每个 Mach-O 的签名 ID，检查外层 plist、内嵌 runner、辅助程序、新 entitlements、麦克风/AppleEvents 合约与部署目标；跑偏好迁移的隔离合成用例，不操作真实用户偏好。
2. 从这一提交生成对应源码与材料，封包、Developer ID 签名、公证、staple，验证 DMG 与挂载 App 的 Gatekeeper/签名树和逐文件哈希。旧身份候选保留作回退，不复用其“已公证”结论给新字节。
3. 真正安装前记录旧 App 签名/版本及偏好键的**非敏感元数据**，确认本机旧数据可恢复；安装器保留旧 App 备份。由用户在场完成可能出现的授权/管理员提示，再核实登录跟随、两款 App 的窗口和设置、IDV Login、麦克风、工具箱屏幕录制和 Finder 打开报告。若 TCC 或登录升级失败，退出新 App，恢复旧 App 与原偏好/数据，按具体失败证据修正；不能仅用 `tccutil reset` 掩盖问题。

这份记录描述新发行候选身份与迁移设计，不表示已经改了日用安装或真实系统权限。公开发布仍需最终隐私、许可与真实环境审查。

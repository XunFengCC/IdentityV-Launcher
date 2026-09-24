# 第五人格启动器发行封包

本目录负责从一个已构建的启动器 App 生成 DMG、第三方许可与对应源码材料 ZIP，以及两者的 SHA-256 清单。封包器不会安装 App、启动游戏、申请系统权限或替换 runtime。发布候选还要配上精确匹配的项目源码归档/公开 Git tag，并把它与 [ReleaseMaterials](../notices/README.md)、DMG 和统一校验清单放在同一发行位置；封包器生成的材料 ZIP 本身不包含完整项目源码，也不等同于正式公开发布。

## 版本与当前实物

版本取自 App 的 `IdentityVReleaseVersion`。**1.0.0-rc.1 已于 2026-09-23 公开发布**；源码当前仍保留这个号码用于日常构建，封包器会拒绝以这个已用号码再次发行。下一次封包先确定范围，再把 `IdentityVReleaseVersion` 增至新候选号并从干净提交重建。[变更记录](../CHANGELOG.md)说明已发布内容与未决问题。脚本文件名 `buildAlpha1Preview.command` 为兼容既有调用保留的历史名称，不决定版本号或签名方式。以下是 RC1 已发布物的文件名示例：

- `第五人格启动器-1.0.0-rc.1.dmg`
- `第五人格启动器-1.0.0-rc.1-ReleaseMaterials.zip`
- `第五人格启动器-1.0.0-rc.1-ProjectSource.zip`（与最终候选相配的项目源码；单独归档）
- `SHA256SUMS.txt`

`/Applications` 中的已装 App、工作树 `build/` 里的候选和公开 DMG 是三个不同对象；版本号相同也不能共享签名、公证和源码对应结论。RC1 的公开标签固定在 `3bac291`。公开后的 emoji 回归与语音消息破音已登记，不能把开发中的候选字体或 runtime 当作已发布修复。干净首次安装、macOS 15 实机和国际服登录的验收状态仍应单独核对。

## 生成步骤

在项目根目录运行：

```zsh
./notices/prepareReleaseNotices.command
./releasePackaging/preparePackagingEnvironment.command
./releasePackaging/buildAlpha1Preview.command
```

第三方材料生成器仅在 `notices/.build/` 重建忽略的中间产物；封包器在 Developer ID 模式下对 staging App 签名、公证和 staple，再对 DMG 自身签名、公证和 staple。两者分别按适合的 Gatekeeper 类型验收。公证 profile 从 `IDENTITYV_NOTARY_PROFILE` 读取，凭据只放在钥匙串。构建模式为 `auto` 时优先选用可用的 Developer ID，缺 profile 会直接失败。若明确选择 ad-hoc 或本地开发签名，生成物不是普通用户可直接信任的正式候选，需清楚标记为内部测试。

若 App 尚未构建，使用 `./releasePackaging/buildAlpha1Preview.command --rebuild`；该选项调用玩家启动器构建脚本，会改写 `playerLauncherApp/build/第五人格启动器.app`，并按构建脚本实际设置使用签名身份。若需保留默认构建，可先由调用方在隔离目录完成构建，再设置绝对路径 `IDENTITYV_BUILD_ROOT=/绝对构建目录`；封包器会从同一目录读取 App。`--output /绝对输出目录` 可将最终产物及暂存区放到指定位置。省略 `--rebuild` 时，封包器仍会核对 App 内 `build-provenance.json` 的源码提交、构建前干净状态、包内 manifest/catalog/Info 哈希、当前源码资源和唯一默认运行时；缺失或不一致就拒绝封包。

首次使用时 `preparePackagingEnvironment.command` 只创建本目录被忽略的 `.venv`，固定安装 `dmgbuild 1.6.7`，不改系统 Python。封包用隔离 staging、禁入内容扫描、运行时补丁哈希校验、签名树验证、麦克风用途声明契约、最高 macOS 部署目标审计和只读 DMG 挂载复验。DMG 可见布局是启动器 App 与指向 `/Applications` 的拖放入口，另带 Finder 背景元数据；游戏、基础 Wine runtime、`DWRG.dmg`、网易下载核心及 `idv-login` 二进制不得进入 App/DMG。

材料 ZIP 包含项目 GPL 原文、第三方 notice、选定组件的对应源码及补丁/构建说明，但不含完整启动器源码归档。发布前必须复核生成后的 `ThirdPartyNotices/` 和 `CorrespondingSources/` 与最终 App 实际包含的组件/版本一致；若 idv-login、runtime patch、Go helper 或其他依赖版本改变，材料锁和发行说明也要一起更新。不得把材料包生成成功当作第三方分发权审计通过的证明。

项目源码 ZIP 由发行方从审查过的明确 Git 提交另外生成，不由 `buildAlpha1Preview.command` 自动产生。它应包含构建所需的 runner 模板与 runtime patch 二进制输入，排除机内诊断和可再生构建输出；从**干净副本**全量构建 App，再为纳入的源码逐文件生成 `SOURCE-SHA256SUMS.txt`，压缩并从解压副本复验文件哈希和可执行位。后续修改若改变 App 构建输入，须重建、重封并重新生成对应源码归档；仅以同名版本号不能证明对应。

发行版本对应固定字节，因此封包器会拒绝覆盖输出目录内已有的同名 DMG、材料 ZIP 或清单。请为每轮候选使用新建的空输出目录。全部验证完成后，三个文件依次移入输出目录；若移动阶段遇到磁盘错误，目录可能只含部分新产物，此时将整目录视为失败候选并保留作证据。封包结束时私有 `.stage-*` 与挂载目录会清理。成功后复算清单、检查 ZIP 内容、验证 DMG、公证票据与签名。

## 验收边界

签名有效、公证 Accepted、staple 和 `spctl` 接受只能证明代码身份及 Gatekeeper 状态，不能替代新系统/干净账户首次安装、TCC 权限、登录代理和游戏实测。已有 `/Applications` App 的公证状态不会传递给从源码目录另行构建的 App。运行时补丁重新签名会改变字节摘要，必须同步发行专用 manifest/catalog 并验证装机迁移；详见[签名边界](../signing/README.md)和[版本命名约定](versioning.md)。

# 签名、公证与权限身份

构建脚本统一加载 `signing/lib/signIdentityV.sh`。`IDENTITYV_SIGNING_MODE=auto` 默认优先使用本机可用的 Developer ID Application；没有时可用本地开发身份或 ad-hoc，身份不可用则失败，不静默降级。Apple 面向外部分发的[Developer ID 说明](https://developer.apple.com/developer-id/)是发行身份的上游依据。**构建成功不等于公证或真实授权通过。**

签名按“松散可执行文件 → 内嵌 App → 外层 App”进行，包括 `Contents/MacOS` 中的 runner zsh 脚本。曾出现外层公证通过、内层脚本仍是 ad-hoc 导致 Gatekeeper 拒绝的失败路径，所以不能只看公证结果；`identityv_verify_bundle_tree` 和 `spctl` 应分别检查整树与最终 App。Hardened Runtime 使用 `--options runtime` 和时间戳。`RuntimePatches/` 四枚已经单独签名、按精确哈希锁定，普通 App 重签时不得顺手重签它们：时间戳会改变字节，必须先同步 `runtime-manifest.json` 与 runtime catalog 并重新验证。来源与哈希契约见[运行环境说明](../runtimeBootstrap/README.md)。

## 权限声明为什么放在这里

Hardened Runtime 下，麦克风和 AppleEvents 等受保护能力要求**实际负责请求的 App** 带对应 entitlement。历史上身份切换后若只换签名却未加麦克风 entitlement，会出现“没有授权弹窗且无法录音”；TCC 设置中即使显示已允许，也不能替代二进制实际声明。当前 `entitlements/` 按 bundle ID 定义启动器的麦克风与 AppleEvents、内嵌 runner 的麦克风、工具箱的 AppleEvents；签名脚本按身份应用并在构建中验证。新增能力时先确认责任进程，再改声明和合约测试。

bundle ID、签名团队、Keychain/TCC 身份及用户数据路径是既有安装的兼容契约。公开前第一方 bundle ID 已按[身份与旧安装兼容](../docs/firstPartyIdentity.md)统一到 `com.fengyin.identityv`，旧域偏好和权限仍须分别处理；Apple 签名团队、证书与用户数据路径不随之改变。换 bundle ID 可能使系统重新要求授权；换机器/用户也需要重新确认。私钥、API key、密码仅在 Keychain 或 owner-only 存储，绝不提交或写入普通日志。`setupLocalDevelopmentSigning.command --create` 和 `setupNotaryCredentials.command` 是需要人有意执行的身份设置操作，**普通构建不会自动创建证书或写凭据**。

公证入口是 `notarizeIdentityV.command`；封包器在 Developer ID 模式下先公证并 staple App，再签名、公证并 staple DMG，凭据 profile 从 `IDENTITYV_NOTARY_PROFILE` 读取。缺少所需身份或 profile 应 fail closed。若使用 App Store Connect Team Key，`notarytool` 需要 issuer；Individual Key 不提供 issuer。发行流程与 DMG 验证见[封包说明](../releasePackaging/README.md)。最终候选仍须在干净系统完成首次安装、麦克风和其他 TCC 授权、IDV Login 与游戏回归；签名树、公证和 Gatekeeper 各自只能证明自身检查的边界。

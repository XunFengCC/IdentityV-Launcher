# 运行环境补丁来源与隔离候选

本目录保留当前运行环境补丁的源码差异 `patches/`，以及隔离的自建 r4 候选 runner 和 HUD 合约测试。它**不**包含游戏、基础 Wine runtime、用户 prefix、真实日志或旧维护者机器路径。补丁对应的 CodeWeavers Wine、DXMT 等上游版本与第三方许可见[第三方台账](../notices/THIRD_PARTY_STATUS.md)；随玩家 App 构建使用的四枚已签补丁在[`runtimeBootstrap/releasePayloads/`](../runtimeBootstrap/README.md)另按精确哈希锁定。

`runSelfbuiltGameR4.command` 仅供维护者对已经验证且隔离的候选做实验。运行前需显式设置 `IDENTITYV_R4_RUNTIME` 与 `IDENTITYV_R4_PREFIX` 为各自已有的路径；脚本不提供任何本机默认 runtime/prefix，也不把 r4 选为玩家产品默认。`--preflight` 只验证，真正打开游戏还必须另给 `--confirm-game-launch`。`tests/runSelfbuiltGameR4MetalHud.test.command` 提取并检查 Metal HUD 环境隔离逻辑，不启动游戏。r4 是历史试验分支，不能把其测试通过当成 RC1 的游戏回归。

旧 Data 卷和个人实机排查的完整过程保留在私人项目档案。本仓保留可维护的补丁和使用条件，不能凭旧路径创建同名目录便宣称重新得到当时的结果。更换 Wine/DXMT 版本时，先核对上游是否已经解决相同问题，再决定重基或删除补丁；重签预编译输入后须刷新 manifest/catalog 的分发哈希并重做构建验证。

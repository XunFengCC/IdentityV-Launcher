# 预览版卸载生命周期

`uninstallIdentityVPreview.command` 提供两档、默认不写入的预览：

- `--preserve-game`：撤销项目 App、root helper、sudoers、IDV Login 组件、精确受管 Hosts 行、性能浮窗 LaunchAgent、日志、prefix、下载/修复工作目录；保留游戏目录与重新导入所需的安装记录。
- `--remove-tool-data`：在上一档基础上，再删除启动器的 installation/products 状态。它仍逐项删除，不递归删除整个 `~/Library/Application Support/IdentityVOnMac`；默认内部 `Games/` 和任意外置 gameRoot 永远不在目标内。
- `--remove-idv-login-data`：额外、明确地删除 `~/Library/Application Support/idv-login`；这可能清掉 IDV Login 自己的账号/扫码/登录状态，必须单独显式选择，默认保留。

它的系统删除目标是写死 allow-list，而不是从游戏配置、环境变量或用户输入中解析；真实执行要求 root 调用时明确传入 `--execute`，脚本自身不会提权或弹密码框。安装器会写一个无秘密的 `install-manifest.json`，用于审计这份闭合清单。

IDV Login 首次运行可能由上游把其自签名 CA 写入 System.keychain。项目只会在启动就绪后，确认固定用户目录中的 CA PEM 与 System.keychain 中的同一 DER 完全相等、且其 subject/issuer/CA 特征均符合预期时，写入 root-owned `0600` 的 `idv-login-system-ca.json`。台账保存 SHA-1（仅供 macOS `security delete-certificate -Z` 使用）、SHA-256、subject/issuer、CA 标记和公开 DER 见证；它可追加多枚轮换 CA。

卸载绝不以 `Netease Login Helper CA` 名称批量删除。只有台账中的每枚 DER 在当时的 System.keychain 里仍精确匹配时才撤销；如果用户的 IDV Login PEM 仍在，则还必须与台账中的其中一枚一致。账号目录已先行删除时，root-owned 台账和 System.keychain 的双重精确核验仍可完成撤销。旧安装没有台账时 fail closed：不会猜删任何系统证书。

共享 Wine/DXMT runtime、下载核心和它们的 `runtime-binding.json` 都位于本工具专属的用户态 `Components`/状态边界；两档卸载都会移除这些兼容层与工作文件，但不会删除默认 `Games/` 或外置 `gameRoot`。`--preserve-game` 会保留 `installation.json`/`products.json` 供重新安装启动器后识别，`--remove-tool-data` 才连这两份状态一并移除。

Alpha 强制 `compat-hosts-only`：启动前会拒绝存在的、未带本项目独占 tag 的同域名 loopback 映射，以免擅自把历史或用户自己的 hosts 行认领为本项目状态。它不安装 CA，也不修改系统代理；因此旧版未标记 hosts 行需要用户先人工确认和处理。

当前 `testUninstaller.command` 覆盖 dry-run、固定范围、参数拒绝和非 root fail-closed；实际 root 回归应放在干净机/临时 APFS 卷进行。

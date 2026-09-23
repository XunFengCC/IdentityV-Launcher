# 固定 IDV Login 组件

当前固定上游未修改的 `idv-login` `v6.3.0-stable` 原始 macOS arm64 二进制。唯一发行清单是 `../idvLoginComponent.json`；下载器编译时锁定版本、完整 URL、大小与 SHA-256，测试同时核对启动器的版本/缓存常量，避免只换清单而旧版 UI 仍误判“已安装”。

维护者已有官方下载成品时，可离线暂存：

```zsh
./stageIdvLoginReleasePayload.command /绝对路径/idv-login-v6.3.0-stable-mac
```

它离线校验精确大小、SHA-256 和 arm64 架构，并写入 Git 忽略、权限 `0700/0600` 的 `releaseCache/6.3.0/`，只用于维护者安装准备。构建 App 不需要这个 cache，也不会从 `/Library` 现有安装或旧 App 提取二进制。

最终 App 的 `InstallerPayload/` 含 manifest、root 安装器、特权 helper 输入、state tool、迁移脚本、预览卸载器和 ThirdPartyNotices，**不含 idv-login 二进制**。用户安装时从固定的上游 Release 下载。

跨版本由现有安装器先停止旧后台、备份配置并隔离全部旧 Python 热修复覆盖层，再原子切换 `current`。不能只替换可执行文件：旧覆盖层可能盖住新版模块。账号与证书保留，原始内容不写入项目日志；具体安全边界以本目录源码和合约测试为准。

## 用户侧下载缓存

启动器安装时把固定版本下载到用户态的版本缓存槽。下载器先复验已完成文件，兼容复用旧预览版 UUID 槽中通过精确大小、SHA-256 和 arm64 Mach-O 检查的同版成品；未完成的 `.partial` 以 HTTP Range 继续，服务端忽略 Range 时安全从零下载。缓存写入使用进程自动释放的文件锁、`0700/0600` 权限和原子发布，不接受 symlink。

网络中断或安装器失败会保留可续传 partial/已验证成品；成功安装后也保留成品供重新安装。只有用户在管理员授权前明确拒绝本轮安装时，启动器才清理这一稳定槽中的 final 与 partial。

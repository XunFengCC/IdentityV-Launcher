# Wine 11：GMP / PCRE2 / zstd 依赖闭包审计

范围：2026-08-29 对维护者隔离的 `wine11-codeweavers-26.1-dxmt-0.80`
runtime 中三枚依赖的只读盘点，及一个**未激活** APFS clone 候选的重建验证。没有修改
`installation.json`、prefix、App、launcher.env，也没有启动或停止 Wine/游戏进程。

## 原 runtime 证据

| 库 | 原 SHA-256 | 原身份 / current / compatibility | 架构、minos | 由库本身探测的版本 |
| --- | --- | --- | --- | --- |
| `libgmp.10.dylib` | `ac596895f94965af3b85d3341cc0be0bac633c9a5f906d49412112380d739a61` | `@loader_path/libgmp.10.dylib` / 16.0.0 / 16.0.0 | x86_64, 26.0 | GMP 6.3.0 |
| `libpcre2-8.0.dylib` | `3ff394b17a8edb0e66fb1fe9eb67c34d2e9e902b5daf12a4cf08d3198a7b7fc1` | `@loader_path/libpcre2-8.0.dylib` / 16.0.0 / 16.0.0 | x86_64, 26.0 | PCRE2 10.47 (2025-10-21) |
| `libzstd.1.dylib` | `a57eeb5a8c547dad7e677a280a1e09a3bac6ba9968d90c962f3a5a453c62e73a` | `@loader_path/libzstd.1.dylib` / 1.5.7 / 1.0.0 | x86_64, 26.0 | zstd 1.5.7 |

每枚库仅依赖自身（dylib ID）与 `/usr/lib/libSystem.B.dylib`。版本是通过 `dlopen` 和
`__gmp_version`、`pcre2_config_8(PCRE2_CONFIG_VERSION)`、`ZSTD_versionString()` 读取，
不是按文件名猜测。

## 上游源码与校验

| 组件 | 官方源 | 本地归档 SHA-256 |
| --- | --- | --- |
| GMP 6.3.0 | GNU GMP / GNU FTP：`https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz` | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |
| PCRE2 10.47 | PCRE2Project 官方 GitHub release：`https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2` | `47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7` |
| zstd 1.5.7 | facebook/zstd 官方 tag：`https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz` | `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3` |

三者均以 `clang -arch x86_64 -mmacosx-version-min=14.0` 和
`MACOSX_DEPLOYMENT_TARGET=14.0` 构建；`file`/`vtool` 均显示 x86_64、minos 14.0。

## 未激活候选与 fail-closed 结论

候选槽：维护者隔离的 `wine11-codeweavers-26.1-dxmt-0.80-macos14-deps-gmp-pcre2-zstd-r1`；本仓不保存其本机路径或运行态。

候选三个替换文件（依次 GMP/PCRE2/zstd）SHA-256：

```text
b25b382a90dda844517078c7d3dda3a44bd4a10c99bbd86aad37b0a90c8d589a
09b6e680ccd8ca452a88d08981593237986ef58576a903290df74dd9a7696e00
d5894bcd6c7eac70765f7d5186c5c98537ee983d89f240b6a47b93bac1c7b314
```

其 install-name、compatibility/current versions 均已与原库保持一致，但**不得激活**：

- PCRE2 通过完整原导出符号集比对（缺失 0）。
- GMP 缺失 3 个原导出：`___gmpn_addlsh_nc`、`___gmpn_rsblsh_nc`、`___gmpn_sublsh2_n`。
- zstd 缺失 409 个原导出，包括 COVER、FSE、HUF 和 legacy 内部符号；标准上游动态库默认未导出这些符号。

所以三库的 minOS 26 均已从**候选文件**清除到 14.0，但该候选没有满足“原导出完整超集”这道保守门，不能仅凭编译成功直接激活。
`wine --version` 在该隔离槽中无 UI 返回 `wine-11.0`，只能证明 Wine 可执行入口仍存在，不能替代库 ABI 验收。
完整运行时扫描最高 minos 现为 15.0，来自 DXMT `winemetal.so`；即使三库 ABI 问题解决，也仍非 macOS 14 完整 runtime。

## 实际消费者 ABI（第二轮只读核对）

候选整槽的 `otool -L` 直接消费者只有：GMP 为 `libgnutls.30.dylib` 与
`libhogweed.6.dylib`；PCRE2 为 `libglib-2.0.0.dylib`；zstd 没有槽内其他直接消费者。
对这些消费者的 `nm -uUj` 和 `dyld_info -bind` 与缺失符号集取交集后为 0：三枚 GMP
缺失和 409 枚 zstd 缺失均**没有静态加载消费者**。

另外，整槽 Mach-O 的未定义符号中没有 `_dlsym`；以 412 个缺失名作为固定字节串扫描、
同时排除三枚目标 dylib，命中 0 个文件。因此在此静态检查范围内，它们归类为“原库额外
公开但无人引用”；没有证据指向动态查找。不过静态检查不能证明未来加载的外部插件或应用
永远不会按字符串查找，故仍保留“无法由静态扫描排除的外部动态查找”风险。

结论需要分层：**严格导出超集门失败**，但候选满足“当前 runtime 槽内的静态加载闭包”。
这不足以授权激活；最小后续冷烟测门应是在隔离 prefix、隔离用户目录和隔离 wineserver
环境中，仅执行候选 `wine --version`，随后执行不启动 Windows 应用的 Wine loader/`ntdll`
装载检查，捕获 `dyld`/Wine stderr 并确认没有符号绑定错误。该门通过后才可考虑由主流程
另行授权的干净系统图形、音频与游戏测试；DXMT 15.0 阻塞仍独立存在。

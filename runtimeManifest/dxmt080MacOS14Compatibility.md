# DXMT 0.80 的 macOS 14 向下兼容审计

审计时间：2026-08-29。范围仅限活动 Wine 11 runtime 的只读 Mach-O/包闭包检查，以及来自 DXMT 官方 GitHub 的 `v0.80` 源码与构建说明。不修改 `installation.json`、`launcher.env`、App、活动 runtime 或 prefix。

## 结论

**不能为当前 Wine 11 + DXMT 0.80 runtime 声明 macOS 14 支持，也没有生成可激活的 DXMT 替换槽。**

DXMT 官方将 macOS Sonoma（14）列为 v0.80 的构建前提，但并不等于每一个编译产物都可在 14 上运行。活动包的 `winemetal.so` 自身最低版本为 **15.0**；更重要的是，官方 v0.80 源码对 Metal 3.2/AIR 明确设置 `air64-apple-macosx15.0.0`，并把相应的 Metal API 放在 `@available(macOS 15, *)` 门后。macOS 14 分支会限制到 Metal 3.1，但仍必须取得与 Wine ABI 匹配的完整交叉构建。

活动运行时另有 GMP、PCRE2、zstd 三枚 `minos 26.0` 依赖，因此即使单独重建 DXMT 成功，整槽也不能降为 macOS 14。完整闭包证据见 [macosCompatibilityAudit.md](macosCompatibilityAudit.md)。

## 活动 DXMT 包的事实

对象：维护者隔离的 `wine11-codeweavers-26.1-dxmt-0.80` runtime 中的 `lib/dxmt/x86_64-unix/winemetal.so`。

| 项 | 结果 |
| --- | --- |
| 格式 / 架构 | Mach-O 64-bit shared library / x86_64 |
| SHA-256 | `16e32803d0d25d3bb41d59e1560f00d0919d76c6fa9b21dbe0ef827bb213faf0` |
| `LC_BUILD_VERSION` | platform macOS，`minos 15.0`，SDK 15.1 |
| install-name | `@rpath/winemetal.so` |
| Wine ABI 依赖 | `@rpath/winemac.so`、`@rpath/ntdll.so` |
| Apple 图形依赖 | weak `Metal`，强 `MetalFX`，以及 CoreFoundation/Foundation/CoreGraphics/QuartzCore/AppKit/ColorSync |
| 其他依赖 | sqlite3、libSystem、zlib、ncurses、libxml2、libc++、libobjc |

未定义符号包含 `MTLFXSpatialScalerDescriptor` / `MTLFXTemporalScalerDescriptor`、Metal 的 binary archive / counter / mesh pipeline 类，以及 sqlite3 API；未发现旧 wiki 所称的 `macdrv_*` 未定义私有符号。`nm -gU` 有 15,258 个全局符号（它静态携带了大量 LLVM 导出，不能把该数误读为 Wine ABI 表面）。

包内文件共 15 枚：一个 x86_64 Unix `winemetal.so`、6 个 x86_64 Windows DLL、4 个 i386 Windows DLL，加 `nvapi64.dll` 与 `nvngx.dll`。所有文件的可复查哈希由 [auditDxmt080MacOS14Compatibility.command](auditDxmt080MacOS14Compatibility.command) 输出；该脚本只读，不会启动 Wine 或读取 prefix。

## 官方 v0.80 的来源与要求

从官方 `3Shain/dxmt` 的带注释 tag `v0.80` 以 `--recurse-submodules` 获取源码，tag 指向提交：`589adb780354b461645b29999cefaf533594ee99`。实测时使用隔离源码目录，本仓不保存维护者的本机路径。

官方 `docs/DEVELOPMENT.md` 的明确要求：

- macOS Sonoma 及以后；
- Meson 1.3+；
- **LLVM 15（精确 major）**，含 headers 和 static libraries；
- Xcode 16+ 与 Metal toolchain；
- Wine 8+ headers/tools；用于 Wine 时为 cross build；
- 64-bit Windows DLL + x86_64 Unixlib 的 `build-win64.txt` 还要求 `x86_64-w64-mingw32-{gcc,g++,ar,strip,windres}`。

本机有 Xcode 27 / Metal toolchain，Meson 1.12.0 也满足 `>= 1.3`；真正缺少的是 LLVM 15、mingw-w64 cross compiler，且现存 CodeWeavers 源树只含一小部分 `dlls/`，没有可传给 DXMT 的完整 Wine build tree、headers 和 `winebuild` 工具。因此阻塞是**LLVM/mingw 工具链 + 完整 Wine 交叉构建输入缺失**，不是可以安全用现成 15.0 二进制改 load command 的问题。

同时，官方 v0.80 源码本身具有版本分支：`DeviceImpl` 在 macOS 14 上限制 `metal_version_` 为 Metal 3.1；只有 macOS 15+ 可升到 Metal 3.2。`setup_metal_version()` 的 3.2 case 明确设置 `air64-apple-macosx15.0.0`。这证明 15.0 不是纯粹的无意 SDK 漂移，但也不能单靠源码文字推断 3.1 路径已在 macOS 14 与本 Wine/runtime 闭包实测成功。

## 未执行的操作与后续门

由于审计时游戏正在运行，未创建/替换 APFS DXMT candidate runtime，也未运行任何 Wine/prefix/D3D 命令。唯一 Wine 查询是直接执行活动 Unix Wine 二进制的 `--version`：exit 0，输出 `wine-11.0`，无 UI、无 prefix。

若未来要继续，先在外置盘隔离准备官方要求的 x86_64 LLVM 15、mingw-w64 和完整且 ABI 对应的 Wine build tree；本机 Meson 已满足版本门。以 `MACOSX_DEPLOYMENT_TARGET=14.0`、`CFLAGS/CXXFLAGS=-arch x86_64 -mmacosx-version-min=14.0` 配置官方 v0.80 cross build。仅在产物通过 x86_64、`minos <=14.0`、install-name/依赖、预期 Unixlib 导出、包 DLL 哈希和无 UI `wine --version` 门后，才能放入全新 APFS clone 槽。之后还必须先解决 GMP/PCRE2/zstd closure，并在真正 macOS 14 冷机上做图形实测，才有产品级兼容性结论。

官方依据：[DXMT v0.80 DEVELOPMENT.md](https://raw.githubusercontent.com/3Shain/dxmt/v0.80/docs/DEVELOPMENT.md)、[DXMT Installation Guide](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks)。

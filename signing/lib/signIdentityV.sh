#!/bin/zsh
# signIdentityV.sh — IdentityVOnMac 共享代码签名入口（source 使用，不直接执行）。
#
# 为什么存在：ad-hoc 签名的 designated requirement 绑定单次构建的 cdhash，每次
# 重建都会改变代码身份，麦克风/屏幕录制授权随之失效；正式发行还需要 Developer ID
# 加 Hardened Runtime 与安全时间戳。把“身份解析”和“由内到外签名”集中到一处，
# 避免十几个构建脚本各写一份、行为漂移。
#
# 适用条件：只负责调用 codesign；不创建证书、不改钥匙串、不动 TCC。证书创建仍由
# signing/setupLocalDevelopmentSigning.command（本机开发）或 Xcode（Developer ID）完成。
#
# 身份解析优先级（由高到低）：
#   1. IDENTITYV_SIGNING_IDENTITY：完整身份名（如
#      "Developer ID Application: Qingxiong Yang (VNTCB2984V)"）或 40 位 SHA-1，
#      同时接受 "-" 表示显式 ad-hoc。指定后必须可用，否则退出 70，绝不静默退回。
#   2. IDENTITYV_SIGNING_MODE：
#        adhoc        -> ad-hoc（--timestamp=none），离线可用
#        developer-id -> 必须找到 Developer ID Application，否则退出 70
#        local        -> 必须找到本地开发证书，否则退出 70
#        auto（默认） -> 有 Developer ID Application 就用它；否则沿用旧配置引用；
#                        再否则 ad-hoc（保持既有日常构建行为）
#   3. 旧配置引用文件 signing-identity.txt（本地开发证书 SHA-1）
#
# 签名顺序：内层松散 Mach-O → 内嵌 .app（由深到浅）→ 外层 .app；不使用 --deep
# （--deep 已废弃，且只把外层选项套一遍，无法产出可公证的 Developer ID 树）。
#
# RuntimePatches 默认跳过：它们是字节锁定的发行载荷，摘要同时记在
# runtimeBootstrap/runtime-manifest.json 与 runtimeManifest/runtime-catalog.json，
# 运行期还会被 runner 校验；重签会破坏这三处校验，必须按独立流程同步摘要并提升
# runtime 版本，见 signing/README.md。确需重签时显式设
# IDENTITYV_SIGN_RUNTIME_PATCHES=1，并自行完成摘要/版本同步。

: "${IDENTITYV_SIGNING_IDENTITY:=}"
: "${IDENTITYV_SIGNING_MODE:=auto}"
IDENTITYV_SIGNING_REFERENCE="${IDENTITYV_SIGNING_REFERENCE:-$HOME/Library/Application Support/IdentityVOnMac/Development/signing-identity.txt}"
IDENTITYV_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# entitlements 目录：按被签目标的 bundle id 取 <bundle-id>.entitlements。
# 为什么存在：Hardened Runtime 下 tccd 对麦克风等受保护服务要求**责任 App** 带对应
# entitlement，否则不弹窗直接拒绝（2026-09-21 实测：Developer ID + runtime 后游戏
# 没有音频输入、系统也不申请权限）。放在这里的文件按 bundle id 自动匹配，是为了让
# 签名层而不是每个构建脚本记得这件事；原因、适用条件与验收见 signing/README.md。
IDENTITYV_ENTITLEMENTS_DIR="${IDENTITYV_ENTITLEMENTS_DIR:-${${(%):-%x}:A:h}/../entitlements}"
IDENTITYV_RESOLVED_IDENTITY=""
IDENTITYV_RESOLVED_KIND=""

_identityv_list_identities() {
  /usr/bin/security find-identity -v -p codesigning "$IDENTITYV_LOGIN_KEYCHAIN" 2>/dev/null
}

_identityv_find_developer_id() {
  local line
  for line in "${(@f)$(_identityv_list_identities)}"; do
    if [[ "$line" == *'"Developer ID Application: '*'"'* ]]; then
      line="${line#*\"}"
      print -- "${line%%\"*}"
      return 0
    fi
  done
  return 0
}

_identityv_find_local_dev() {
  local line
  for line in "${(@f)$(_identityv_list_identities)}"; do
    if [[ "$line" == *'"Fengyin IdentityV Local Development"'* ]]; then
      print -- 'Fengyin IdentityV Local Development'
      return 0
    fi
  done
  return 0
}

# 判定候选身份在当前钥匙串里是否为有效代码签名身份。候选可以是身份名或 SHA-1。
# 这里用 zsh 字符串匹配而不是 `security ... | grep -q`：脚本普遍开着
# `set -o pipefail`，下游命中即退出会让 security 收到 SIGPIPE，管道整体被判失败，
# 把有效身份误判成不可用。
_identityv_identity_is_usable() {
  local candidate="$1" text
  [[ -n "$candidate" ]] || return 1
  [[ "$candidate" == "-" ]] && return 0
  text="$(_identityv_list_identities)"
  if [[ ${#candidate} == 40 && "$candidate" != *[^0-9A-Fa-f]* ]]; then
    [[ "${text:u}" == *"${candidate:u}"* ]]
  else
    [[ "$text" == *"\"$candidate\""* ]]
  fi
}

# 判定候选身份属于哪一类（developer-id / local / adhoc），用于选择签名选项与校验强度。
# 不能只看字符串前缀：显式传入 Developer ID 的 40 位 SHA-1 时前缀判断会误判为 local。
_identityv_identity_kind() {
  local candidate="$1" line
  [[ "$candidate" == "-" ]] && { print -- adhoc; return 0; }
  for line in "${(@f)$(_identityv_list_identities)}"; do
    if [[ "$line" == *"$candidate"* ]]; then
      if [[ "$line" == *"Developer ID Application"* ]]; then
        print -- developer-id
      else
        print -- local
      fi
      return 0
    fi
  done
  print -- local
}

# 解析签名身份，结果写入 IDENTITYV_RESOLVED_IDENTITY / IDENTITYV_RESOLVED_KIND。
identityv_resolve_identity() {
  local candidate="" mode="${IDENTITYV_SIGNING_MODE:-auto}"
  if [[ -n "$IDENTITYV_SIGNING_IDENTITY" ]]; then
    candidate="$IDENTITYV_SIGNING_IDENTITY"
    _identityv_identity_is_usable "$candidate" || {
      print -u2 -- "签名身份不可用：$candidate（钥匙串中没有匹配的有效身份）。"
      return 70
    }
  else
    case "$mode" in
      adhoc)
        candidate="-" ;;
      developer-id)
        candidate="$(_identityv_find_developer_id)"
        [[ -n "$candidate" ]] || {
          print -u2 -- "IDENTITYV_SIGNING_MODE=developer-id，但登录钥匙串里没有 Developer ID Application 证书。"
          return 70
        } ;;
      local)
        [[ -f "$IDENTITYV_SIGNING_REFERENCE" ]] && candidate="$(<"$IDENTITYV_SIGNING_REFERENCE")"
        [[ -n "$candidate" ]] || candidate="$(_identityv_find_local_dev)"
        [[ -n "$candidate" ]] || {
          print -u2 -- "IDENTITYV_SIGNING_MODE=local，但没有本地开发签名证书。"
          return 70
        }
        _identityv_identity_is_usable "$candidate" || {
          print -u2 -- "本地开发签名身份不可用：$candidate"
          return 70
        } ;;
      auto)
        candidate="$(_identityv_find_developer_id)"
        if [[ -z "$candidate" && -f "$IDENTITYV_SIGNING_REFERENCE" ]]; then
          candidate="$(<"$IDENTITYV_SIGNING_REFERENCE")"
          [[ -n "$candidate" ]] || {
            print -u2 -- '本地签名身份引用为空；请修复配置，构建不会自动退回临时签名。'
            return 70
          }
          _identityv_identity_is_usable "$candidate" || {
            print -u2 -- "本地开发签名身份不可用：$candidate"
            return 70
          }
        fi
        [[ -n "$candidate" ]] || candidate="-" ;;
      *)
        print -u2 -- "未知 IDENTITYV_SIGNING_MODE：$mode"
        return 64 ;;
    esac
  fi
  if [[ "$candidate" == "-" ]]; then
    IDENTITYV_RESOLVED_KIND=adhoc
  else
    IDENTITYV_RESOLVED_KIND="$(_identityv_identity_kind "$candidate")"
  fi
  IDENTITYV_RESOLVED_IDENTITY="$candidate"
  return 0
}

_identityv_is_macho() {
  /usr/bin/file -b "$1" 2>/dev/null | /usr/bin/grep -q 'Mach-O'
}

# 按 .app 的 CFBundleIdentifier 找对应 entitlements 文件；没配置或没有该文件时返回 1。
# 用 bundle id 而不是路径匹配：同一个 App 在 build/、staging、/Applications 下路径不同，
# 只有身份标识能稳定对应到"这个 App 需要哪些受保护能力"。
_identityv_entitlements_path() {
  local app="$1" bundle_id candidate
  [[ -n "${IDENTITYV_ENTITLEMENTS_DIR:-}" && -d "$IDENTITYV_ENTITLEMENTS_DIR" ]] || return 1
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app/Contents/Info.plist" 2>/dev/null)" || return 1
  [[ -n "$bundle_id" ]] || return 1
  candidate="$IDENTITYV_ENTITLEMENTS_DIR/$bundle_id.entitlements"
  [[ -f "$candidate" ]] || return 1
  print -- "$candidate"
}

# 用已解析的身份签一个目标。附加参数原样传给 codesign（如 --identifier/--entitlements）。
# 真实身份统一带 --options runtime --timestamp；ad-hoc 保持 --timestamp=none。
identityv_codesign() {
  local target="$1"; shift
  [[ -n "$IDENTITYV_RESOLVED_IDENTITY" ]] || {
    print -u2 -- "尚未解析签名身份，先调用 identityv_resolve_identity。"
    return 70
  }
  if [[ "$IDENTITYV_RESOLVED_KIND" == adhoc ]]; then
    /usr/bin/codesign --force --timestamp=none "$@" --sign - "$target"
  else
    /usr/bin/codesign --force --options runtime --timestamp "$@" \
      --sign "$IDENTITYV_RESOLVED_IDENTITY" "$target"
  fi
}

# 签一个 bundle 目录里除内嵌 .app 与（默认）RuntimePatches 之外的代码：Mach-O 与
# `Contents/MacOS` 下的非 Mach-O 可执行体。普通源码复制/ZIP 可能丢失脚本签名
# xattr；若先签同目录主 Mach-O，codesign 会因未签名脚本子组件提前失败。因此先
# 签可执行脚本，再签 Mach-O，干净源码包也能建立完整签名树。
# 判定必须用相对 $root 的路径：外层 app 自身的绝对路径也含 ".app/"，直接匹配完整
# 路径会把整个外层目录都跳过，导致辅助二进制留在 ad-hoc。
_identityv_sign_loose_macho() {
  local root="$1" sign_patches="${IDENTITYV_SIGN_RUNTIME_PATCHES:-0}" candidate rel
  while IFS= read -r -d '' candidate; do
    rel="${candidate#$root/}"
    case "$rel" in
      *.app/*) continue ;;
      Contents/MacOS/*)
        [[ -f "$candidate" && -x "$candidate" ]] || continue
        _identityv_is_macho "$candidate" || identityv_codesign "$candidate"
        ;;
    esac
  done < <(/usr/bin/find "$root" -type f -print0 2>/dev/null)

  while IFS= read -r -d '' candidate; do
    rel="${candidate#$root/}"
    case "$rel" in
      *.app/*) continue ;;
    esac
    if [[ "$rel" == */RuntimePatches/* || "$rel" == RuntimePatches/* ]]; then
      [[ "$sign_patches" == 1 ]] || continue
    fi
    _identityv_is_macho "$candidate" || continue
    # 保留既有 identifier：构建脚本会给辅助二进制指定 com.xunfeng.* 标识，
    # 重新签名若不保留会退化成 codesign 默认的 <文件名>-<cdhash>。
    identityv_codesign "$candidate" --preserve-metadata=identifier
  done < <(/usr/bin/find "$root" -type f -print0 2>/dev/null)
}

# 由内到外签整个 .app。entitlements 按 bundle id 从 IDENTITYV_ENTITLEMENTS_DIR 自动匹配；
# 可选 IDENTITYV_APP_ENTITLEMENTS 显式覆盖外层主可执行文件的 entitlements。
identityv_sign_bundle_tree() {
  local app="$1" nested ent_file
  [[ -d "$app" ]] || { print -u2 -- "签名目标不存在：$app"; return 66; }
  # -depth 保证更深的 .app 先出现，先签子再签父。
  while IFS= read -r nested; do
    [[ -n "$nested" ]] || continue
    _identityv_sign_loose_macho "$nested"
    ent_file="$(_identityv_entitlements_path "$nested")" || ent_file=""
    if [[ -n "$ent_file" ]]; then
      identityv_codesign "$nested" --entitlements "$ent_file"
    else
      identityv_codesign "$nested"
    fi
  done < <(/usr/bin/find "$app/Contents" -type d -name '*.app' -depth 2>/dev/null)
  _identityv_sign_loose_macho "$app"
  ent_file="${IDENTITYV_APP_ENTITLEMENTS:-}"
  if [[ -z "$ent_file" ]]; then
    ent_file="$(_identityv_entitlements_path "$app")" || ent_file=""
  fi
  if [[ -n "$ent_file" ]]; then
    identityv_codesign "$app" --entitlements "$ent_file"
  else
    identityv_codesign "$app"
  fi
  return 0
}

# 断言 entitlements 契约：凡在 entitlements 目录里声明了文件的 .app，其实际签名必须
# 携带文件里声明的每个键。为什么单独断言：`codesign --verify` 不会因为"忘了加
# entitlement"而失败，症状要等到 TCC 拒绝麦克风时才出现（2026-09-21 实际发生过），
# 所以必须在签名后当场把"声明"和"实际签名"对上。
_identityv_verify_entitlements() {
  local app="$1" ent_file
  ent_file="$(_identityv_entitlements_path "$app")" || return 0
  /usr/bin/python3 - "$app" "$ent_file" <<'PY'
import plistlib
import subprocess
import sys

app, expected_path = sys.argv[1], sys.argv[2]
with open(expected_path, "rb") as handle:
    expected = plistlib.load(handle)
proc = subprocess.run(
    ["/usr/bin/codesign", "-d", "--entitlements", ":-", app],
    capture_output=True)
text = proc.stdout.decode("utf-8", "replace").strip()
actual = {}
if text:
    try:
        actual = plistlib.loads(text.encode("utf-8"))
    except Exception as error:  # noqa: BLE001 - 无法解析等同缺失，报出来更好
        print(f"无法解析已签 entitlements（{error}）：{app}", file=sys.stderr)
        raise SystemExit(1)
missing = sorted(key for key in expected if key not in actual)
if missing:
    print(f"缺少 entitlements {missing}：{app}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# 校验整棵树；Developer ID 模式下额外断言内层代码（Mach-O 与 MacOS 下的脚本）都带
# Hardened Runtime 与安全时间戳。entitlements 契约对所有签名身份都校验。
identityv_verify_bundle_tree() {
  local app="$1" nested candidate rel info is_code
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || return 1
  # entitlements 目录不存在时不能静默跳过：那正是"签名看起来通过、TCC 却拒绝"的
  # 失败模式。目录在这里是固定契约，缺失按配置错误处理。
  [[ -d "$IDENTITYV_ENTITLEMENTS_DIR" ]] || {
    print -u2 -- "entitlements 目录不存在：$IDENTITYV_ENTITLEMENTS_DIR"
    return 1
  }
  _identityv_verify_entitlements "$app" || return 1
  while IFS= read -r nested; do
    [[ -n "$nested" ]] || continue
    _identityv_verify_entitlements "$nested" || return 1
  done < <(/usr/bin/find "$app/Contents" -type d -name '*.app' -depth 2>/dev/null)
  [[ "$IDENTITYV_RESOLVED_KIND" == developer-id ]] || return 0
  while IFS= read -r -d '' candidate; do
    rel="${candidate#$app/}"
    case "$rel" in
      *.app/*) continue ;;
    esac
    [[ "$rel" == */RuntimePatches/* || "$rel" == RuntimePatches/* ]] && continue
    is_code=0
    if _identityv_is_macho "$candidate"; then
      is_code=1
    else
      case "$rel" in
        Contents/MacOS/*) [[ -f "$candidate" && -x "$candidate" ]] && is_code=1 ;;
      esac
    fi
    (( is_code )) || continue
    # 先把输出收到变量再匹配：`codesign ... | grep -q` 在下游命中即退出时会让
    # codesign 收到 SIGPIPE，配合 pipefail 会把正确的签名判成校验失败。
    info="$(/usr/bin/codesign -d --verbose=4 "$candidate" 2>&1 || true)"
    [[ "$info" == *"flags="*"runtime"* ]] || {
      print -u2 -- "缺少 Hardened Runtime：$candidate"
      return 1
    }
    [[ "$info" == *"Timestamp="* ]] || {
      print -u2 -- "缺少安全时间戳：$candidate"
      return 1
    }
  done < <(/usr/bin/find "$app" -type f -print0 2>/dev/null)
  return 0
}

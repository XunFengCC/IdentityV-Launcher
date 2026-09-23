#!/bin/zsh
# notarizeIdentityV.command — 用 notarytool 提交公证并 staple 单个产物。
#
# 用法：notarizeIdentityV.command <路径.app|路径.dmg> [--profile 钥匙串配置名]
#
# 凭据只存钥匙串，脚本与文档不保存 Apple ID 密码或 app 专用密码。首次配置：
#   xcrun notarytool store-credentials identityv-notary \
#     --apple-id <你的 Apple ID> --team-id VNTCB2984V --password <app 专用密码>
# 之后用 --keychain-profile identityv-notary 调用；也可用环境变量
# IDENTITYV_NOTARY_PROFILE 指定配置名。
#
# 为什么先公证 .app 再装进 DMG：DMG 继承内部 App 的公证结果，但两者都要各自
# staple，用户离线首次打开时 Gatekeeper 才能凭本地票据放行。
set -euo pipefail

artifact="${1:-}"
profile="${IDENTITYV_NOTARY_PROFILE:-}"
if [[ "${2:-}" == "--profile" && -n "${3:-}" ]]; then
  profile="$3"
fi
[[ -n "$artifact" ]] || { print -u2 -- "用法：${0:t} <路径.app|路径.dmg> [--profile 配置名]"; exit 64; }
[[ -e "$artifact" ]] || { print -u2 -- "产物不存在：$artifact"; exit 66; }
[[ -n "$profile" ]] || { print -u2 -- "缺少公证凭据配置名：设置 IDENTITYV_NOTARY_PROFILE 或传 --profile。"; exit 64; }

artifact="${artifact:A}"
work="$(/usr/bin/mktemp -d /private/tmp/identityv-notary.XXXXXX)"
cleanup() { /bin/rm -rf -- "$work"; }
trap cleanup EXIT INT TERM

case "$artifact" in
  *.app)
    upload="$work/$(/usr/bin/basename "$artifact").zip"
    /usr/bin/ditto -c -k --keepParent "$artifact" "$upload" ;;
  *.dmg|*.pkg|*.zip)
    upload="$artifact" ;;
  *)
    print -u2 -- "不支持的公证产物类型（需要 .app/.dmg/.pkg/.zip）：$artifact"
    exit 64 ;;
esac

print -- "提交公证：$artifact"
submit_json="$work/submit.json"
if ! /usr/bin/xcrun notarytool submit "$upload" --keychain-profile "$profile" \
    --wait --output-format json > "$submit_json"; then
  print -u2 -- "notarytool 提交失败；原始输出："
  /bin/cat "$submit_json" >&2 || true
  exit 1
fi

submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submit_json" 2>/dev/null || true)"
# 不能叫 status：zsh 里 status 是只读特殊参数（等同 $?），赋值会直接报错退出。
notary_status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$submit_json" 2>/dev/null || true)"
print -- "公证结果：${notary_status:-未知}（submission ${submission_id:-未知}）"

if [[ "$notary_status" != "Accepted" ]]; then
  print -u2 -- "公证未通过。Apple 的问题日志："
  if [[ -n "$submission_id" ]]; then
    /usr/bin/xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2 || true
  fi
  exit 1
fi

/usr/bin/xcrun stapler staple "$artifact"
/usr/bin/xcrun stapler validate "$artifact"
case "$artifact" in
  *.app) /usr/sbin/spctl -a -vvv -t exec "$artifact" ;;
  *.dmg) /usr/sbin/spctl -a -t open --context context:primary-signature -v "$artifact" ;;
esac
print -- "已公证并 staple：$artifact"

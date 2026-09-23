#!/bin/zsh
# setupNotaryCredentials.command — 交互式把公证凭据存入登录钥匙串。
#
# 两种凭据二选一，都只把结果存进钥匙串，脚本不写任何秘密到文件或日志：
#
#  1) app 专用密码（简单，适合偶尔发版）：
#       setupNotaryCredentials.command --apple-id <你的 Apple ID> --team-id <团队 ID>
#     先在 https://account.apple.com → 登录与安全 → App 专用密码 生成一串
#     xxxx-xxxx-xxxx-xxxx，再在下面的隐藏提示里粘贴。
#
#  2) App Store Connect API 密钥（长期/自动化）：
#       setupNotaryCredentials.command --api-key <AuthKey_XXXX.p8> --key-id <10位> --issuer <UUID>
#     Individual Key 省略 --issuer。
#     密钥在 appstoreconnect.apple.com → 用户和访问 → 集成 → App Store Connect API
#     生成；当前本机 notarytool 明确支持 Team Key 与 Individual Key，前者必填
#     --issuer，后者不得提供。密钥的权限与可用性仍由 notarytool 验证。
#
# 存储后公证脚本只引用钥匙串配置名，不再接触密码或密钥文件。
set -euo pipefail

profile="fengyin-notary"
apple_id=""
team_id=""
api_key=""
key_id=""
issuer=""

while (( $# > 0 )); do
  case "$1" in
    --profile) profile="${2:-}"; shift ;;
    --apple-id) apple_id="${2:-}"; shift ;;
    --team-id) team_id="${2:-}"; shift ;;
    --api-key) api_key="${2:-}"; shift ;;
    --key-id) key_id="${2:-}"; shift ;;
    --issuer) issuer="${2:-}"; shift ;;
    -h|--help)
      print -- "用法："
      print -- "  ${0:t} --apple-id <Apple ID> --team-id <团队 ID>     # app 专用密码"
      print -- "  ${0:t} --api-key <p8> --key-id <ID> --issuer <UUID>   # 团队 API 密钥"
      print -- "  ${0:t} --api-key <p8> --key-id <ID>                   # 个人 API 密钥"
      exit 0 ;;
    *) print -u2 -- "未知参数：$1"; exit 64 ;;
  esac
  shift
done

if [[ -n "$api_key" || -n "$key_id" || -n "$issuer" ]]; then
  [[ -f "$api_key" && -n "$key_id" ]] || {
    print -u2 -- "API 密钥方式需要同时给出存在的 .p8 文件和 --key-id；团队密钥还需 --issuer。"
    exit 64
  }
  if [[ -n "$issuer" ]]; then
    print -- "把 App Store Connect 团队 API 密钥存入钥匙串配置「$profile」"
    /usr/bin/xcrun notarytool store-credentials "$profile" \
      --key "$api_key" --key-id "$key_id" --issuer "$issuer"
  else
    print -- "把 App Store Connect 个人 API 密钥存入钥匙串配置「$profile」"
    /usr/bin/xcrun notarytool store-credentials "$profile" \
      --key "$api_key" --key-id "$key_id"
  fi
else
  [[ -n "$apple_id" && -n "$team_id" ]] || {
    print -u2 -- "app 专用密码方式需要 --apple-id 和 --team-id；不要把账号写死在发行源码中。"
    exit 64
  }
  print -- "把 app 专用密码存入钥匙串配置「$profile」"
  print -- "Apple ID：$apple_id   Team ID：$team_id"
  print -- ""
  print -- "请先到 https://account.apple.com → 登录与安全 → App 专用密码 生成一个，"
  print -- "然后在下面的提示处粘贴（输入时不显示字符）。"
  print -- ""
  /usr/bin/xcrun notarytool store-credentials "$profile" \
    --apple-id "$apple_id" --team-id "$team_id"
fi

print -- ""
print -- "完成：凭据已存入登录钥匙串，配置名「$profile」。"
print -- "验证：xcrun notarytool history --keychain-profile $profile"

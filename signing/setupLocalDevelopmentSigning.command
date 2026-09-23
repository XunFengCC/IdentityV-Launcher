#!/bin/zsh
# Explicit, interactive setup only. Not run by ordinary builds or background
# maintenance. The private key goes into login Keychain; only a public SHA-1
# certificate reference is stored in the development configuration directory.
set -euo pipefail
umask 077
[[ $# == 1 && "$1" == --create ]] || {
  print '用法：setupLocalDevelopmentSigning.command --create'
  print '创建本地开发代码签名身份；可能出现钥匙串/用户信任授权，不提供 Apple 公证或公开发行身份。'
  exit 64
}
[[ "$EUID" != 0 ]] || { print -u2 '请以当前桌面用户运行，不要使用 sudo。'; exit 64; }
name='Fengyin IdentityV Local Development'
directory="$HOME/Library/Application Support/IdentityVOnMac/Development"
reference="$directory/signing-identity.txt"
keychain="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$keychain" ]] || exit 1
if [[ -e "$reference" ]]; then
  print -u2 '已有签名身份引用；保留它，不自动生成第二把钥匙。'
  exit 1
fi
if /usr/bin/security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  print -u2 '钥匙串已有同名证书；请核查现有身份，不自动重复创建。'
  exit 1
fi
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$temporary"' EXIT
cat > "$temporary/request.conf" <<'CONF'
[req]
prompt=no
distinguished_name=subject
x509_extensions=extensions
[subject]
CN=Fengyin IdentityV Local Development
O=Fengyin Local Development
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CONF
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 1825 \
  -config "$temporary/request.conf" -keyout "$temporary/key.pem" -out "$temporary/certificate.pem" >/dev/null 2>&1
# The empty transport password is not a secret. The transient container is
# owner-only; it is removed even on failure. Keychain ACL permits codesign,
# never all applications (-A), and user trust is limited to codeSign policy.
/usr/bin/openssl pkcs12 -export -inkey "$temporary/key.pem" -in "$temporary/certificate.pem" \
  -name "$name" -out "$temporary/identity.p12" -passout pass:
/usr/bin/security import "$temporary/identity.p12" -k "$keychain" -f pkcs12 -P '' -T /usr/bin/codesign
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary/certificate.pem"
fingerprint="$(/usr/bin/openssl x509 -in "$temporary/certificate.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
[[ "$fingerprint" != *[^0-9A-F]* && ${#fingerprint} == 40 ]] || exit 1
/usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "$fingerprint" || {
  print -u2 '证书已导入，但尚未成为有效代码签名身份；未切换构建配置。'
  exit 1
}
/bin/mkdir -p "$directory"
/bin/chmod 700 "$directory"
/usr/bin/printf '%s\n' "$fingerprint" > "$reference"
/bin/chmod 600 "$reference"
print -- "本地代码签名身份已就绪：$name"
print -- "公开证书指纹引用：$reference"

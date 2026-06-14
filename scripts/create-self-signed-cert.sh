#!/bin/bash
# 生成自签名 codesign cert 并导入 keychain。
#
# 用途：没有 Apple Developer ID 时让 codesign 能跑通，给身边人分发时
# 第一次 Gatekeeper 会拦，用户 Right-click → Open 即可绕过。
#
# 跟 Apple Developer ID 区别：
#   - Apple Developer ID = $99/年 + 真公证 + Gatekeeper 不拦
#   - 自签名 = 0 成本 + 第一次拦 + Right-click 绕
#
# 跑法：
#   bash scripts/create-self-signed-cert.sh
#   # 生成 Common Name "DreamVault Developer" 的 cert 到 login keychain
#   # 默认 10 年有效期（macOS 要求 codesign cert 不超过 10 年）
#
# 卸载：
#   security delete-certificate -c "DreamVault Developer" ~/Library/Keychains/login.keychain-db
#   security delete-identity -c "DreamVault Developer"  # 一并删 private key

set -e

CERT_NAME="${DREAMVAULT_CERT_NAME:-DreamVault Developer}"
KEYCHAIN="${DREAMVAULT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
TMPDIR="$(mktemp -d -t dv-cert)"
trap '/bin/rm -rf "$TMPDIR"' EXIT

# 已经存在？
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> '$CERT_NAME' 已经存在，无需重新生成。"
    security find-identity -p codesigning "$KEYCHAIN" | grep "$CERT_NAME"
    exit 0
fi

echo "==> 生成 RSA 4096 private key..."
openssl genrsa -out "$TMPDIR/dv.key" 4096 2>/dev/null

echo "==> 生成自签名 v3 cert（含 Code Signing EKU + 10 年有效期）..."
# 4096-bit RSA + sha256 signature + 10 年（macOS 限制 codesign cert 有效期 ≤ 10 年）
cat > "$TMPDIR/dv.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no
[req_dn]
CN = $CERT_NAME
O = DreamVault (self-signed)
C = US
[v3_ca]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
openssl req -new -x509 -sha256 \
    -key "$TMPDIR/dv.key" \
    -out "$TMPDIR/dv.crt" \
    -days 3650 \
    -config "$TMPDIR/dv.cnf" 2>&1 | tail -3

echo "==> 把 cert + key 打包成 p12（macOS security import 兼容的 legacy 格式）..."
# 用 -legacy + AES-256-CBC + PBES2 已被 macOS 拒绝；改用 -keypbe PBE-SHA1-3DES
# -certpbe PBE-SHA1-3DES 是 macOS security import 唯一兼容的组合。
# macOS 13+ 在某些情况下接受 AES，但保险起见走 SHA1-3DES。
openssl pkcs12 -export \
    -inkey "$TMPDIR/dv.key" \
    -in "$TMPDIR/dv.crt" \
    -out "$TMPDIR/dv.p12" \
    -password "pass:dreamvault" \
    -name "$CERT_NAME" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 2>&1 | tail -2

echo "==> 导入 keychain..."
# -A 让任何 app 访问（避免 codesign 时弹"允许访问"框）
security import "$TMPDIR/dv.p12" \
    -k "$KEYCHAIN" \
    -P "dreamvault" \
    -A \
    -T /usr/bin/codesign 2>&1 | tail -3

# 强制 keychain 解锁一次（避免后续 codesign 卡在"allow access"）
security unlock-keychain -p "" "$KEYCHAIN" 2>/dev/null || true

echo "==> 验证 identity..."
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | grep "$CERT_NAME" | head -1 | awk -F'"' '{print $2}')
if [ -z "$IDENTITY" ]; then
    echo "ERROR: import 后没找到 identity，请检查 keychain 状态" >&2
    exit 1
fi
echo "OK: identity = '$IDENTITY'"
echo
echo "用法："
echo "  codesign --force --deep --options=runtime --sign '$IDENTITY' /path/to/MyApp.app"
echo "  # 或 build-app.sh 默认会用 'DreamVault Developer' 自动找"

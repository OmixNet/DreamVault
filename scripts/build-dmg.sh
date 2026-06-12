#!/bin/bash
# 把签好名的 ~/Applications/DreamVault.app 打成可分发的 DMG。
#
# 流程：
#   1. 准备 staging 目录（DreamVault.app + /Applications 软链接）
#   2. hdiutil 创建只读 DMG（UDZO 压缩）
#   3. 简单的 Finder 排版（不依赖 AppleScript 库；用户双击后自己拖）
#
# 跑法：
#   bash scripts/build-app.sh       # 先签名
#   bash scripts/build-dmg.sh        # 打到 ~/Desktop/DreamVault-<version>.dmg
#
# 输出：
#   ~/Desktop/DreamVault-<version>.dmg
#
# DMG 形态（标准 macOS）：
#   - 背景：纯白（无背景图，避免维护图标资源）
#   - 内容：DreamVault.app + /Applications 软链接
#   - 用户拖到 Applications 完成安装
#
# 跟 Apple Developer ID DMG 区别：
#   - 自签名 DMG：用户第一次开 Finder 提示"无法验证开发者"，需
#     Right-click DMG → Open → Open
#   - Developer ID DMG：双击直接挂载
#   - DMG 本体不需要公证，公证是 .app 的事（spctl 评估 .app）

set -e

APP_DIR="$HOME/Applications/DreamVault.app"
VERSION="${DREAMVAULT_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "0.2.1")}"
DMG_NAME="DreamVault-${VERSION}"
DMG_PATH="$HOME/Desktop/${DMG_NAME}.dmg"
STAGING="$(mktemp -d -t dv-dmg)"
DMG_TMP="$(mktemp -d -t dv-dmg-final)"
trap '/Users/biomatrix/.mavis/bin/mavis-trash "$STAGING" "$DMG_TMP" 2>/dev/null || /bin/rm -rf "$STAGING" "$DMG_TMP"' EXIT

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: $APP_DIR 不存在，先跑：bash scripts/build-app.sh" >&2
    exit 1
fi

# 检查 .app 是否真的签了名（如果 linker-signed 默认的 ad-hoc 用户也认得但不专业）
if codesign -dv "$APP_DIR" 2>&1 | grep -q "adhoc"; then
    echo "WARNING: $APP_DIR 还是 ad-hoc 签名，Gatekeeper 会拦"
    echo "    建议先跑 create-self-signed-cert.sh 生成自签名 cert"
    if [ -t 1 ]; then
        read -p "    继续打 DMG? [y/N] " YN
        if [ "$YN" != "y" ] && [ "$YN" != "Y" ]; then
            exit 1
        fi
    fi
fi

echo "==> [1/4] 准备 staging 目录..."
cp -R "$APP_DIR" "$STAGING/DreamVault.app"
ln -s /Applications "$STAGING/Applications"
ls -la "$STAGING"

echo "==> [2/4] 计算 DMG 体积..."
# hdiutil 用 KB 单位，预留 20% 余量
SIZE_KB=$(du -sk "$STAGING" | awk '{print int($1 * 1.2)}')

echo "==> [3/4] 创建只读压缩 DMG ($SIZE_KB KB)..."
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -size "${SIZE_KB}k" \
    "$DMG_PATH" 2>&1 | tail -3

echo "==> [4/4] 验证 DMG..."
# 挂载一下看内容对不对
MOUNT_OUT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1)
MOUNT_POINT=$(echo "$MOUNT_OUT" | tail -1 | awk '{print $3}')
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "ERROR: DMG 挂载失败" >&2
    echo "$MOUNT_OUT" >&2
    exit 1
fi
echo "    Mounted at: $MOUNT_POINT"
ls -la "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" 2>&1 | tail -1
echo
echo "==> 完成！"
echo "    DMG: $DMG_PATH"
ls -la "$DMG_PATH"
echo
echo "用法："
echo "  open $DMG_PATH"
echo "  # Finder 弹出窗口，把 DreamVault.app 拖到 Applications"
echo
echo "给身边人：把这个 DMG 文件丢给他们。第一次打开会拦，"
echo "  Right-click DMG → Open → Open 即可（一次性绕过 Gatekeeper）"
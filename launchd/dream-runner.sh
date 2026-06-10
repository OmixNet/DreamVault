#!/bin/bash
# DreamVault 夜间 dream 调度 wrapper
#
# launchd plist 调这个脚本（不是直接调 dream 二进制），由它负责：
#   1. 找 release 或 debug 版的 dream 二进制
#   2. 设好 PATH（Xcode toolchain 必须在）+ 环境变量
#   3. 调 dream run --vault ...
#   4. 把 stdout/stderr 都引到 launchd 的 log 文件
#
# 设计要点：
# - 调一次就退（不是守护进程，launchd 调一次我们跑一次）
# - cd 到 vault 根，dream 内部会自己 git commit
# - exit code 透传给 launchd（2=dream 阶段失败，3=git 失败 → launchctl 看得到）

set -e

# —— 1. 找 dream 二进制 ——
REPO="/Users/biomatrix/Desktop/APP/DreamVault"
DREAM_BIN="$REPO/.build/release/dream"
if [ ! -x "$DREAM_BIN" ]; then
    DREAM_BIN="$REPO/.build/debug/dream"
fi
if [ ! -x "$DREAM_BIN" ]; then
    echo "dream 二进制不存在: $DREAM_BIN" >&2
    echo "请先 'cd $REPO && swift build -c release' 或 'swift build'" >&2
    exit 1
fi

# —— 2. PATH + 环境 ——
# Xcode toolchain：让 /usr/bin/swift driver（如果 dream 内部需要）能找到 swift-test
# Homebrew 路径：让可能的 git / 其他工具找得到
export PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# vault 配置（plist 也传了 EnvironmentVariables，但显式再写一次更稳）
export DREAMVAULT_LLM="${DREAMVAULT_LLM:-ollama}"
export DREAMVAULT_VAULT="${DREAMVAULT_VAULT:-/Users/biomatrix/.dreamvault}"

# —— 3. 跑 dream ——
# 注意：cd 到 vault 让 dream 内部用相对路径找 .dream/ 一切正常
cd "$DREAMVAULT_VAULT" || cd "$REPO"
exec "$DREAM_BIN" run --vault "$DREAMVAULT_VAULT" --llm "$DREAMVAULT_LLM" --verbose

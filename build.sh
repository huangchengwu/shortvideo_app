#!/bin/bash

# 设置遇到错误即停止
set -e

PROJECT_DIR=$(pwd)
CACHE_DIR="$PROJECT_DIR/media_kit_cache"
TARGET_DIR="$PROJECT_DIR/build/media_kit_libs_android_video/v1.1.7"
VERSION="v1.1.7"
BASE_URL="https://github.com/media-kit/libmpv-android-video-build/releases/download/$VERSION"

# 本地代理配置（对应你的 Clash 混合端口 7897）
PROXY_URL="http://127.0.0.1:7897"

echo "=========================================="
echo "🚀 开始自动化构建流程（智能检查与下载）..."
echo "=========================================="

# 1. 确保本地备份目录存在
mkdir -p "$CACHE_DIR"

# 需要的 4 个底层 .jar 文件列表
FILES=(
    "default-arm64-v8a.jar"
    "default-armeabi-v7a.jar"
    "default-x86_64.jar"
    "default-x86.jar"
)

# 2. 检查本地缓存，如果缺少则通过 wget + 本地代理自动下载
for file in "${FILES[@]}"; do
    if [ ! -f "$CACHE_DIR/$file" ]; then
        echo "📥 本地未找到 $file，正在通过本地代理 ($PROXY_URL) 下载..."
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        wget -O "$CACHE_DIR/$file" "$BASE_URL/$file"
        echo "✅ $file 下载成功！"
    else
        echo "✔️ 检测到本地已存在: $file"
    fi
done

# 3. 执行 Flutter 清理与依赖获取
echo "🧹 清理旧构建 (flutter clean)..."
flutter clean

echo "📦 获取 Flutter 依赖 (flutter pub get)..."
flutter pub get

# 4. 自动复制 .jar 文件到 Gradle 缓存目录
echo "📂 正在恢复 media_kit 的离线依赖包..."
mkdir -p "$TARGET_DIR"
cp -v "$CACHE_DIR"/*.jar "$TARGET_DIR"/
echo "✅ 离线依赖恢复完成！"

# 5. 开始打包
echo "🔨 开始编译打包 Release APK..."
flutter build apk --release

echo "=========================================="
echo "🎉 打包完成！APK 路径: build/app/outputs/flutter-apk/app-release.apk"
echo "=========================================="


adb install -r  build/app/outputs/flutter-apk/app-release.apk


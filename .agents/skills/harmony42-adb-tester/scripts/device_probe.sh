#!/usr/bin/env bash
# Device Probe and Pre-Test Stabilization for HarmonyOS 4.2 Tablets
set -euo pipefail

ADB="/home/haoshuai/Android/Sdk/platform-tools/adb"

echo "=== 1. Checking Attached Devices ==="
$ADB devices

echo "=== 2. Device Specifications ==="
MODEL=$($ADB shell getprop ro.product.model | tr -d '\r')
HW_VER=$($ADB shell getprop hw_sc.build.platform.version | tr -d '\r')
ANDROID_VER=$($ADB shell getprop ro.build.version.release | tr -d '\r')
echo "Model: $MODEL"
echo "HarmonyOS Version: $HW_VER"
echo "AOSP Base: Android $ANDROID_VER"

echo "=== 3. Storage Mount Check ==="
$ADB shell "df -h | grep -E 'emulated|storage'"

echo "=== 4. Stabilizing Device Environment for Testing ==="
# Lock to Landscape, disable auto-rotation
$ADB shell settings put system accelerometer_rotation 0
$ADB shell settings put system user_rotation 1

# Reset screen density and size
$ADB shell wm size reset
$ADB shell wm density reset

# Disable window animations for fast reliable UIAutomator dump
$ADB shell settings put global window_animation_scale 0.0
$ADB shell settings put global transition_animation_scale 0.0
$ADB shell settings put global animator_duration_scale 0.0

echo "=== Device Stabilization Complete. Ready for Testing. ==="

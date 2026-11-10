#!/bin/bash
# 在 macOS 上无人值守运行一次 MT5 回测/优化。
# 用法： ./run_mt5.sh single_test.ini
# 说明： 官方 MT5 Mac 版是 Wine 封装。下面两个路径是常见默认值，
#        不同版本可能不同，请先在“终端”里 ls 确认，或用环境变量覆盖。
set -euo pipefail

WINE="${WINE:-/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64}"
export WINEPREFIX="${WINEPREFIX:-$HOME/Library/Application Support/net.metaquotes.wine.metatrader5}"
MT5_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"

INI="${1:?用法: $0 <配置.ini>}"
[ -x "$WINE" ] || { echo "找不到 wine: $WINE（请设置 WINE 环境变量）"; exit 1; }
[ -f "$MT5_DIR/terminal64.exe" ] || { echo "找不到 terminal64.exe: $MT5_DIR"; exit 1; }

# 配置文件复制到 Wine 的 C 盘，用 Windows 路径传给终端
mkdir -p "$WINEPREFIX/drive_c/xs_cfg" "$MT5_DIR/reports"
cp "$INI" "$WINEPREFIX/drive_c/xs_cfg/run.ini"

# 回测前必须没有其它 MT5 实例占用同一数据目录
cd "$MT5_DIR"
"$WINE" terminal64.exe "/config:C:\\xs_cfg\\run.ini"
echo "完成：报告在 $MT5_DIR/reports/"

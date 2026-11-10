#!/bin/bash
# Walk-Forward 批处理：训练 TRAIN_M 个月 + 测试 TEST_M 个月，每次向前滚动 TEST_M 个月。
# 用法： ./run_wfo.sh 2025-01-01 2026-10-01
# 无人值守： caffeinate -i nohup ./run_wfo.sh 2025-01-01 2026-10-01 > wfo.log 2>&1 &
set -euo pipefail
cd "$(dirname "$0")"

START="${1:?起始日 YYYY-MM-DD}"
END="${2:?结束日 YYYY-MM-DD}"
TRAIN_M="${TRAIN_M:-3}"
TEST_M="${TEST_M:-1}"

addm() { date -j -v+"$2"m -f "%Y-%m-%d" "$1" "+%Y-%m-%d"; }   # macOS 的 date 语法
dot()  { echo "${1//-/.}"; }

from="$START"
n=1
while :; do
  fwd=$(addm "$from" "$TRAIN_M")
  to=$(addm "$fwd" "$TEST_M")
  [[ "$to" > "$END" ]] && break
  name=$(printf "wfo_%02d_%s_%s" "$n" "${fwd//-/}" "${to//-/}")
  sed -e "s/__FROM__/$(dot "$from")/" -e "s/__FWD__/$(dot "$fwd")/" \
      -e "s/__TO__/$(dot "$to")/" -e "s/__NAME__/$name/" \
      optimize_wfo_template.ini > "/tmp/$name.ini"
  echo "[$(date '+%F %T')] 窗口 $n：训练 $from → $fwd，测试 $fwd → $to"
  ./run_mt5.sh "/tmp/$name.ini"
  from=$(addm "$from" "$TEST_M")
  n=$((n + 1))
done
echo "全部完成。每个窗口生成 <name>.xml（训练段）与 <name>.forward.xml（测试段）。"

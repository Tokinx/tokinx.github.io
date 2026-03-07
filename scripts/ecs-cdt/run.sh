#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INTERVAL=60

# 1MiB 上限
MAX_LOG_BYTES=$((1024 * 100))

trim_log() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return 0

  # wc -c 比 stat 更通用（不同系统 stat 参数不一样）
  local size
  size="$(wc -c < "$logfile" 2>/dev/null || echo 0)"

  if (( size > MAX_LOG_BYTES )); then
    local tmp
    tmp="$(mktemp "$SCRIPT_DIR/.trim-log.tmp.XXXXXX")"
    # 保留最后 MAX_LOG_BYTES 字节
    tail -c "$MAX_LOG_BYTES" "$logfile" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$logfile"
  fi
}

discover_tasks() {
  local tasks=()
  shopt -s nullglob
  tasks=( "$SCRIPT_DIR"/task.*.py )
  shopt -u nullglob
  printf '%s\n' "${tasks[@]}"
}

# 自动选择解释器：优先 venv，其次 python3
PYTHON="$SCRIPT_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3 || true)"
fi

if [[ -z "${PYTHON:-}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: python3 not found, and .venv/bin/python not executable" >&2
  exit 1
fi

# INTERVAL 安全检查，避免除以 0
if (( INTERVAL <= 0 )); then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: INTERVAL must be > 0" >&2
  exit 1
fi

while true; do
  mapfile -t TASK_SCRIPTS < <(discover_tasks)
  if (( ${#TASK_SCRIPTS[@]} == 0 )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no task.*.py found in $SCRIPT_DIR" >&2
  fi

  for SCRIPT_PATH in "${TASK_SCRIPTS[@]}"; do
    SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
    TASK_BASENAME="${SCRIPT_NAME%.py}"
    LOGFILE="$SCRIPT_DIR/${TASK_BASENAME}.log"
    LOCKFILE="/tmp/${TASK_BASENAME}.lock"

    trim_log "$LOGFILE"

    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$TS] run $SCRIPT_NAME (python: $PYTHON)" >> "$LOGFILE"

    # 先拿锁（明确区分“锁占用” vs “执行失败”）
    exec 9>"$LOCKFILE"
    if flock -n 9; then
      "$PYTHON" "$SCRIPT_PATH" >> "$LOGFILE" 2>&1
      RC=$?
      TS_DONE="$(date '+%Y-%m-%d %H:%M:%S')"
      echo "[$TS_DONE] done (exit=$RC)" >> "$LOGFILE"
      flock -u 9
    else
      echo "[$TS] skipped (locked)" >> "$LOGFILE"
    fi
    exec 9>&-

    trim_log "$LOGFILE"
  done

  # 对齐到整分钟
  sleep $(( INTERVAL - $(date +%s) % INTERVAL ))
done

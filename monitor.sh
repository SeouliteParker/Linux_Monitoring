#!/bin/bash
# monitor.sh - 시스템 상태 수집 및 로깅 스크립트

APP_NAME="agent-app-linux-x86"
APP_PORT=15034
LOG_FILE="/var/log/agent-app/monitor.log"
CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# 1) 프로세스 확인 (sudo 래퍼 제외, 실행 파일 경로로 시작하는 것만)
PID=$(pgrep -f "^/.*/${APP_NAME}" | head -n 1)
if [ -z "$PID" ]; then
  echo "Checking process '${APP_NAME}'... [FAIL]"
  exit 1
fi
echo "Checking process '${APP_NAME}'... [OK] (PID: ${PID})"

# 2) 포트 확인
if ss -tln | grep -q ":${APP_PORT} "; then
  echo "Checking port ${APP_PORT}... [OK]"
else
  echo "Checking port ${APP_PORT}... [FAIL]"
  exit 1
fi

# 3) 방화벽 점검 (경고만)
if grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
  :
else
  echo "[WARNING] Firewall is not active"
fi

# 4) 자원 수집
CPU=$(top -bn1 | awk '/Cpu\(s\)/ {printf "%.1f", 100 - $8}')
MEM=$(free | awk '/Mem:/ {printf "%.1f", $3/$2*100}')
DISK=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')

echo
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU}%"
echo "MEM Usage : ${MEM}%"
echo "DISK Used : ${DISK}%"
echo

# 5) 임계값 경고 (경고만)
awk -v v="$CPU" -v t="$CPU_LIMIT" 'BEGIN{exit !(v>t)}' && echo "[WARNING] CPU threshold exceeded (${CPU}% > ${CPU_LIMIT}%)"
awk -v v="$MEM" -v t="$MEM_LIMIT" 'BEGIN{exit !(v>t)}' && echo "[WARNING] MEM threshold exceeded (${MEM}% > ${MEM_LIMIT}%)"
[ "$DISK" -gt "$DISK_LIMIT" ] && echo "[WARNING] DISK threshold exceeded (${DISK}% > ${DISK_LIMIT}%)"

# 6) 로그 기록
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PID:${PID} CPU:${CPU}% MEM:${MEM}% DISK_USED:${DISK}%" >> "$LOG_FILE"
echo
echo "[INFO] Log appended: ${LOG_FILE}"
exit 0

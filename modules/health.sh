#!/bin/bash
# System Health Check & Auto-Repair Module

system_health_check() {
  local issues_found=0
  local issues_fixed=0
  local disk_full=false

  print_logo
  draw_box 70 "SYSTEM HEALTH & AUTO-REPAIR"
  echo ""

  # Load config
  if [ -f "${CONFIG_FILE:-}" ]; then
    source "$CONFIG_FILE"
  fi

  ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU:-80}
  ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM:-85}
  ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK:-90}
  AUTO_FIX=${AUTO_FIX:-false}

  print_status "info" "Running comprehensive system diagnostics..."
  echo ""

  # CPU (sampled from /proc/stat over 0.5s)
  local cpu1 cpu2 cpu_usage
  cpu1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  sleep 0.5
  cpu2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  cpu_usage=$(awk -v a="$cpu1" -v b="$cpu2" 'BEGIN {
    split(a, x, " "); split(b, y, " ")
    total = y[1] - x[1]; idle = y[2] - x[2]
    printf "%.1f", (total > 0) ? (1 - idle / total) * 100 : 0
  }')

  if awk -v a="$cpu_usage" -v b="$ALERT_THRESHOLD_CPU" 'BEGIN {exit !(a < b)}'; then
    print_status "ok" "CPU Usage: ${cpu_usage}%"
  else
    print_status "error" "CPU Usage: ${cpu_usage}% (High!)"
    issues_found=$((issues_found + 1))
  fi

  # Memory
  echo ""
  local mem_total mem_used mem_percent
  read -r mem_total mem_used < <(free -m | awk '/^Mem:/ {print $2, $3}')
  mem_percent=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN {printf "%.1f", (u / t) * 100}')

  if awk -v a="$mem_percent" -v b="$ALERT_THRESHOLD_MEM" 'BEGIN {exit !(a < b)}'; then
    print_status "ok" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
  else
    print_status "error" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
    issues_found=$((issues_found + 1))
  fi

  # Disk
  echo ""
  print_status "info" "Disk Usage:"

  local fs size used avail pct mount usage
  while read -r fs size used avail pct mount; do
    usage=${pct%\%}
    if [ "$usage" -lt "$ALERT_THRESHOLD_DISK" ]; then
      print_status "ok" "$mount: $used/$size ($pct used, $avail free)"
    else
      print_status "error" "$mount: $used/$size ($pct used)"
      issues_found=$((issues_found + 1))
      disk_full=true
    fi
  done < <(df -hP / /home 2>/dev/null | tail -n +2 | sort -u -k6,6)

  # Autofix (only when a filesystem is over threshold)
  if [ "$AUTO_FIX" = "true" ] && [ "$disk_full" = "true" ]; then
    echo ""
    print_status "fix" "Cleaning up disk space..."

    if command -v paccache &>/dev/null; then
      echo "  Pruning package cache (keeping 2 versions)..."
      paccache -rk2 >/dev/null 2>&1 || true
    elif command -v pacman &>/dev/null; then
      echo "  Cleaning package cache..."
      pacman -Sc --noconfirm </dev/null >/dev/null 2>&1 || true
    fi

    echo "  Cleaning journal logs..."
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    echo "  Cleaning temp files..."
    systemd-tmpfiles --clean >/dev/null 2>&1 || true

    issues_fixed=$((issues_fixed + 1))
  fi
  # Services echo ""
  print_status "info" "Checking system services..."

  local failed_list failed_services
  failed_list=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
  failed_services=$(grep -c . <<<"$failed_list" || true)

  if [ "$failed_services" -eq 0 ]; then
    print_status "ok" "All services running normally"
  else
    print_status "error" "$failed_services failed service(s)"
    while IFS= read -r unit; do
      echo -e "    ${RED}▸${NC} $unit"
    done <<<"$failed_list"
    issues_found=$((issues_found + 1))
  fi

  # Summary
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$issues_found" -eq 0 ]; then
    print_status "ok" "System is healthy! No issues detected."
  else
    echo -e "${YELLOW}Found $issues_found issue(s)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Fixed $issues_fixed issue(s) automatically${NC}"
    else
      echo -e "${GRAY}Enable AUTO_FIX to apply automatic repairs${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
}

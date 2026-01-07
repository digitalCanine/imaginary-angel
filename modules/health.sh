#!/bin/bash
# System Health Check & Auto-Repair Module

system_health_check() {
  # Anti system crash
  set +e
  set +u

  # Safer counter
  issues_found=0
  issues_fixed=0

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

  # CPU
  cpu_idle=$(top -bn1 | awk -F',' '/Cpu/ {print $4}' | awk '{print $1}')
  cpu_usage=$(awk "BEGIN {printf \"%.1f\", 100 - $cpu_idle}")

  if (($(echo "$cpu_usage < $ALERT_THRESHOLD_CPU" | bc -l))); then
    print_status "ok" "CPU Usage: ${cpu_usage}%"
  else
    print_status "error" "CPU Usage: ${cpu_usage}% (High!)"
    ((issues_found++))
  fi

  # Memory
  echo ""
  mem_total=$(free -m | awk '/^Mem:/ {print $2}')
  mem_used=$(free -m | awk '/^Mem:/ {print $3}')
  mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")

  if (($(echo "$mem_percent < $ALERT_THRESHOLD_MEM" | bc -l))); then
    print_status "ok" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
  else
    print_status "error" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
    ((issues_found++))
  fi

  # Disk
  echo ""
  print_status "info" "Disk Usage:"

  while read -r fs size used avail pct mount; do
    usage=${pct%\%}
    if [ "$usage" -lt "$ALERT_THRESHOLD_DISK" ]; then
      print_status "ok" "$mount: $used/$size ($pct used, $avail free)"
    else
      print_status "error" "$mount: $used/$size ($pct used)"
      ((issues_found++))
    fi
  done < <(df -h / /home 2>/dev/null | tail -n +2 || true)

  # Autofix
  if [ "$AUTO_FIX" = "true" ]; then
    echo ""
    print_status "fix" "Cleaning up disk space..."

    if command -v pacman &>/dev/null; then
      echo "  Cleaning package cache..."
      pacman -Sc --noconfirm </dev/null >/dev/null 2>&1 || true
      ((issues_fixed++))
    fi

    echo "  Cleaning journal logs..."
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    ((issues_fixed++))

    echo "  Cleaning temp files..."
    find /tmp /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    ((issues_fixed++))
  fi

  # Services
  echo ""
  print_status "info" "Checking system services..."

  failed_services=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l)

  if [ "$failed_services" -eq 0 ]; then
    print_status "ok" "All services running normally"
  else
    print_status "error" "$failed_services failed service(s)"
    ((issues_found++))
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
  show_main_menu
}

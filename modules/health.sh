#!/bin/bash
# System Health Check & Auto-Repair Module

system_health_check() {
  print_logo
  draw_box 70 "SYSTEM HEALTH & AUTO-REPAIR"
  echo ""

  # Load config with defaults if variables don't exist
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi

  # Set defaults if not defined
  ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU:-80}
  ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM:-85}
  ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK:-90}
  AUTO_FIX=${AUTO_FIX:-false}

  local issues_found=0
  local issues_fixed=0

  print_status "info" "Running comprehensive system diagnostics..."
  echo ""

  # ========== CPU USAGE ==========
  local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')

  if (($(echo "$cpu_usage < $ALERT_THRESHOLD_CPU" | bc -l))); then
    print_status "ok" "CPU Usage: ${cpu_usage}%"
  else
    print_status "error" "CPU Usage: ${cpu_usage}% (High!)"
    ((issues_found++))

    # Find CPU hogs
    echo -e "  ${YELLOW}Top CPU consumers:${NC}"
    ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "    %s (PID %s): %.1f%%\n", $11, $2, $3}'

    if [ "$AUTO_FIX" = "true" ]; then
      echo ""
      echo -e "  ${CYAN}Attempting to reduce CPU load...${NC}"

      # Kill clearly problematic processes (runaway scripts, etc)
      ps aux --sort=-%cpu | head -6 | tail -5 | while read line; do
        local pid=$(echo "$line" | awk '{print $2}')
        local cpu=$(echo "$line" | awk '{print $3}')
        local cmd=$(echo "$line" | awk '{print $11}')

        # Only kill non-system processes using >90% CPU
        if (($(echo "$cpu > 90" | bc -l))) && [[ ! "$cmd" =~ ^(/usr/bin|/usr/sbin|/sbin|/bin) ]]; then
          echo "    Terminating runaway process: $cmd (PID $pid)"
          kill -15 "$pid" 2>/dev/null || true
          ((issues_fixed++))
        fi
      done
    fi
  fi

  # ========== MEMORY USAGE ==========
  echo ""
  local mem_total=$(free -m | awk '/^Mem:/{print $2}')
  local mem_used=$(free -m | awk '/^Mem:/{print $3}')
  local mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")

  if (($(echo "$mem_percent < $ALERT_THRESHOLD_MEM" | bc -l))); then
    print_status "ok" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
  else
    print_status "error" "Memory: ${mem_used}MB / ${mem_total}MB (${mem_percent}%) (Critical!)"
    ((issues_found++))

    echo -e "  ${YELLOW}Top memory consumers:${NC}"
    ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "    %s (PID %s): %.1f%%\n", $11, $2, $4}'

    if [ "$AUTO_FIX" = "true" ]; then
      echo ""
      print_status "fix" "Clearing system caches..."
      sync
      echo 3 >/proc/sys/vm/drop_caches
      ((issues_fixed++))

      # Check if swap is available and not used
      local swap_total=$(free -m | awk '/^Swap:/{print $2}')
      local swap_used=$(free -m | awk '/^Swap:/{print $3}')

      if [ "$swap_total" -gt 0 ] && [ "$swap_used" -gt 0 ]; then
        print_status "fix" "Optimizing swap usage..."
        swapoff -a && swapon -a
        ((issues_fixed++))
      fi
    fi
  fi

  # ========== DISK USAGE ==========
  echo ""
  print_status "info" "Disk Usage:"

  df -h / /home 2>/dev/null | tail -n +2 | while read -r line; do
    local usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    local mount=$(echo "$line" | awk '{print $6}')
    local size=$(echo "$line" | awk '{print $2}')
    local used=$(echo "$line" | awk '{print $3}')
    local avail=$(echo "$line" | awk '{print $4}')

    if [ "$usage" -lt "$ALERT_THRESHOLD_DISK" ]; then
      print_status "ok" "$mount: ${used}/${size} (${usage}% used, ${avail} free)"
    else
      print_status "error" "$mount: ${used}/${size} (${usage}% used) - CRITICAL!"
      ((issues_found++))
    fi
  done

  if [ "$AUTO_FIX" = "true" ]; then
    echo ""
    print_status "fix" "Cleaning up disk space..."

    # Clean package cache
    if command -v pacman &>/dev/null; then
      echo "  Cleaning package cache..."
      yes | pacman -Scc >/dev/null 2>&1 || true
      ((issues_fixed++))
    fi

    # Clean journal logs older than 7 days
    echo "  Cleaning old journal logs..."
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    ((issues_fixed++))

    # Remove old temp files
    echo "  Removing old temporary files..."
    find /tmp -type f -atime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    ((issues_fixed++))

    # Clean user cache
    echo "  Cleaning user cache directories..."
    find /home -type d -name ".cache" -exec sh -c 'find "$1" -type f -atime +30 -delete' _ {} \; 2>/dev/null || true
    ((issues_fixed++))
  fi

  # ========== FAILED SERVICES ==========
  echo ""
  print_status "info" "Checking system services..."

  local failed_services=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l)
  if [ "$failed_services" -eq 0 ]; then
    print_status "ok" "All services running normally"
  else
    print_status "error" "$failed_services failed service(s) detected"
    ((issues_found++))

    systemctl list-units --state=failed --no-legend 2>/dev/null | while read -r line; do
      local service=$(echo "$line" | awk '{print $1}')
      echo "    ${RED}▸${NC} $service"

      if [ "$AUTO_FIX" = "true" ]; then
        echo "      Attempting restart..."
        systemctl restart "$service" 2>/dev/null && {
          print_status "fix" "Successfully restarted $service"
          ((issues_fixed++))
        } || {
          print_status "warn" "Could not restart $service - may need manual intervention"
        }
      fi
    done
  fi

  # ========== ZOMBIE PROCESSES ==========
  echo ""
  local zombie_count=$(ps aux | awk '$8 ~ /Z/ {print $0}' | wc -l)

  if [ "$zombie_count" -eq 0 ]; then
    print_status "ok" "No zombie processes detected"
  else
    print_status "warn" "$zombie_count zombie process(es) found"
    ((issues_found++))

    echo ""
    echo -e "  ${YELLOW}Zombie processes:${NC}"
    ps aux | awk '$8 ~ /Z/ {print $0}' | while read -r line; do
      local pid=$(echo "$line" | awk '{print $2}')
      local ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      local cmd=$(echo "$line" | awk '{print $11}')

      echo "    ${RED}▸${NC} PID $pid (parent: $ppid): $cmd"
    done

    if [ "$AUTO_FIX" = "true" ]; then
      echo ""
      print_status "fix" "Cleaning up zombie processes..."

      # Kill parent processes of zombies
      ps aux | awk '$8 ~ /Z/ {print $2}' | while read zpid; do
        local parent=$(ps -o ppid= -p "$zpid" 2>/dev/null | tr -d ' ')
        if [ -n "$parent" ] && [ "$parent" -gt 1 ]; then
          echo "  Sending SIGCHLD to parent process $parent..."
          kill -HUP "$parent" 2>/dev/null || true
          ((issues_fixed++))
        fi
      done
    fi
  fi

  # ========== SYSTEM LOAD ==========
  echo ""
  local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  local load_1min=$(echo "$load" | awk -F',' '{print $1}' | xargs)
  local cpu_cores=$(nproc)
  local load_per_core=$(awk "BEGIN {printf \"%.2f\", $load_1min/$cpu_cores}")

  if (($(echo "$load_per_core < 1.0" | bc -l))); then
    print_status "ok" "System Load: $load (${load_per_core} per core)"
  elif (($(echo "$load_per_core < 2.0" | bc -l))); then
    print_status "warn" "System Load: $load (${load_per_core} per core - elevated)"
  else
    print_status "error" "System Load: $load (${load_per_core} per core - HIGH!)"
  fi

  # ========== SYSTEM UPTIME ==========
  echo ""
  local uptime_str=$(uptime -p)
  local uptime_days=$(uptime -s | xargs -I{} bash -c 'echo $(( ($(date +%s) - $(date -d "{}" +%s)) / 86400 ))')

  print_status "ok" "Uptime: $uptime_str"

  if [ "$uptime_days" -gt 90 ]; then
    print_status "warn" "System has been running for $uptime_days days - consider rebooting"
  fi

  # ========== SUMMARY ==========
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$issues_found" -eq 0 ]; then
    print_status "ok" "System is healthy! No issues detected."
  else
    echo -e "${YELLOW}Found $issues_found issue(s)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Fixed $issues_fixed issue(s) automatically${NC}"

      if [ "$issues_fixed" -lt "$issues_found" ]; then
        echo -e "${YELLOW}$(($issues_found - $issues_fixed)) issue(s) require manual attention${NC}"
      fi
    else
      echo -e "${GRAY}Enable AUTO_FIX in Configuration menu to enable automatic repairs${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
  show_main_menu
}

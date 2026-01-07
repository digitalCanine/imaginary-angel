#!/bin/bash
# Process Analysis & Cleanup Module

process_analysis() {
  print_logo
  draw_box 80 "PROCESS ANALYSIS & CLEANUP"
  echo ""

  # Load config with defaults
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
  AUTO_FIX=${AUTO_FIX:-false}

  local suspicious=0
  local cleaned=0

  print_status "info" "Analyzing running processes for anomalies..."
  echo ""

  # Resource hog
  print_status "info" "Top CPU consumers:"
  echo ""
  echo -e "${CYAN}PID     USER       CPU%   MEM%   TIME      COMMAND${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  ps aux --sort=-%cpu | head -11 | tail -10 | while read line; do
    local pid=$(echo "$line" | awk '{print $2}')
    local user=$(echo "$line" | awk '{print $1}')
    local cpu=$(echo "$line" | awk '{print $3}')
    local mem=$(echo "$line" | awk '{print $4}')
    local time=$(echo "$line" | awk '{print $10}')
    local cmd=$(echo "$line" | awk '{print $11}')

    printf "%-6s  %-10s  %-5s  %-5s  %-8s  %s\n" "$pid" "$user" "$cpu" "$mem" "$time" "$cmd"
  done

  echo ""
  print_status "info" "Top memory consumers:"
  echo ""
  echo -e "${CYAN}PID     USER       CPU%   MEM%   VSZ        COMMAND${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  ps aux --sort=-%mem | head -11 | tail -10 | while read line; do
    local pid=$(echo "$line" | awk '{print $2}')
    local user=$(echo "$line" | awk '{print $1}')
    local cpu=$(echo "$line" | awk '{print $3}')
    local mem=$(echo "$line" | awk '{print $4}')
    local vsz=$(echo "$line" | awk '{print $5}')
    local cmd=$(echo "$line" | awk '{print $11}')

    printf "%-6s  %-10s  %-5s  %-5s  %-10s  %s\n" "$pid" "$user" "$cpu" "$mem" "$vsz" "$cmd"
  done

  # Sussy processes
  echo ""
  print_status "info" "Scanning for suspicious processes..."
  echo ""

  # Check for processes running from /tmp or /dev/shm
  local tmp_procs=$(ps aux | awk '{if ($11 ~ /^(\/tmp|\/dev\/shm)/) print $0}')
  local tmp_count=$(echo "$tmp_procs" | grep -v '^$' | wc -l)

  if [ "$tmp_count" -gt 0 ]; then
    print_status "error" "$tmp_count process(es) running from temporary directories!"
    ((suspicious++))

    echo ""
    echo -e "  ${RED}Processes from temporary locations:${NC}"
    echo "$tmp_procs" | while read line; do
      if [ -n "$line" ]; then
        local pid=$(echo "$line" | awk '{print $2}')
        local user=$(echo "$line" | awk '{print $1}')
        local cpu=$(echo "$line" | awk '{print $3}')
        local mem=$(echo "$line" | awk '{print $4}')
        local cmd=$(echo "$line" | awk '{print $11}')

        echo "    ${RED}▸${NC} PID $pid ($user): $cmd [CPU: ${cpu}%, MEM: ${mem}%]"

        if [ "$AUTO_FIX" = "true" ]; then
          echo "      ${YELLOW}Terminating suspicious process...${NC}"
          kill -9 "$pid" 2>/dev/null || true
          ((cleaned++))
        fi
      fi
    done
  else
    print_status "ok" "No processes running from temporary directories"
  fi

  # Check for hidden processes
  echo ""
  local hidden_procs=$(ps aux | awk '{if ($11 ~ /^[[:space:]]|^\.\.?\//) print $0}')
  local hidden_count=$(echo "$hidden_procs" | grep -v '^$' | wc -l)

  if [ "$hidden_count" -gt 0 ]; then
    print_status "warn" "$hidden_count process(es) with suspicious names detected"
    ((suspicious++))

    echo ""
    echo -e "  ${YELLOW}Suspicious process names:${NC}"
    echo "$hidden_procs" | while read line; do
      if [ -n "$line" ]; then
        local pid=$(echo "$line" | awk '{print $2}')
        local cmd=$(echo "$line" | awk '{print $11}')
        echo "    ${YELLOW}▸${NC} PID $pid: $cmd"
      fi
    done
  else
    print_status "ok" "No processes with suspicious names"
  fi

  # Process with deleted binaries
  echo ""
  print_status "info" "Checking for processes with deleted executables..."

  local deleted_count=0
  local deleted_list=""

  for exe in /proc/*/exe; do
    if [ -L "$exe" ]; then
      local target=$(readlink "$exe" 2>/dev/null)
      if echo "$target" | grep -q "(deleted)"; then
        ((deleted_count++))
        local pid=$(echo "$exe" | cut -d'/' -f3)
        local cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
        if [ -n "$cmd" ]; then
          deleted_list="${deleted_list}    ${YELLOW}▸${NC} PID $pid: $cmd (binary deleted)\n"
        fi
      fi
    fi
  done

  if [ "$deleted_count" -eq 0 ]; then
    print_status "ok" "All process binaries exist on disk"
  else
    print_status "warn" "$deleted_count process(es) running from deleted executables"
    echo -e "    ${YELLOW}(These processes should be restarted)${NC}"
    echo ""
    echo -e "$deleted_list"
  fi

  # Zombies
  echo ""
  print_status "info" "Checking for zombie processes..."

  local zombies=$(ps aux | awk '$8 ~ /Z/ {print $0}')
  local zombie_count=$(echo "$zombies" | grep -v '^$' | wc -l)

  if [ "$zombie_count" -eq 0 ]; then
    print_status "ok" "No zombie processes found"
  else
    print_status "error" "$zombie_count zombie process(es) detected"
    ((suspicious++))

    echo ""
    echo -e "  ${RED}Zombie processes:${NC}"
    echo "$zombies" | while read line; do
      if [ -n "$line" ]; then
        local pid=$(echo "$line" | awk '{print $2}')
        local ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        local user=$(echo "$line" | awk '{print $1}')
        local cmd=$(echo "$line" | awk '{print $11}')

        echo "    ${RED}▸${NC} PID $pid (parent: $ppid, user: $user): $cmd"

        if [ "$AUTO_FIX" = "true" ] && [ -n "$ppid" ] && [ "$ppid" -gt 1 ]; then
          echo "      ${YELLOW}Sending SIGCHLD to parent process...${NC}"
          kill -CHLD "$ppid" 2>/dev/null || true
          sleep 1

          # If still zombie, kill parent
          if ps -p "$pid" -o stat= 2>/dev/null | grep -q Z; then
            echo "      ${YELLOW}Terminating parent process $ppid...${NC}"
            kill -9 "$ppid" 2>/dev/null || true
            ((cleaned++))
          else
            ((cleaned++))
          fi
        fi
      fi
    done
  fi

  # Process statistic
  echo ""
  local total_procs=$(ps aux | wc -l)
  local user_procs=$(ps aux | awk '$1 != "root" {print}' | wc -l)
  local root_procs=$(ps aux | awk '$1 == "root" {print}' | wc -l)
  local threads=$(ps -eLf | wc -l)

  print_status "info" "Process summary:"
  echo "    Total processes: $total_procs"
  echo "    Root processes: $root_procs"
  echo "    User processes: $user_procs"
  echo "    Total threads: $threads"

  # Summary
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$suspicious" -eq 0 ]; then
    print_status "ok" "No suspicious processes detected - system is clean"
  else
    echo -e "${RED}Found $suspicious suspicious process(es)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Cleaned $cleaned process(es) automatically${NC}"

      if [ "$cleaned" -lt "$suspicious" ]; then
        echo -e "${YELLOW}$(($suspicious - $cleaned)) issue(s) require manual investigation${NC}"
      fi
    else
      echo -e "${GRAY}Enable AUTO_FIX in Configuration menu to automatically terminate suspicious processes${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
  show_main_menu
}

#!/bin/bash
# System Reports & Diagnostics Module

system_reports() {
  print_logo
  draw_box 70 "SYSTEM REPORTS & DIAGNOSTICS"
  echo ""

  box_line "  ${CYAN}1${NC}) Generate Full System Report"
  box_line "  ${CYAN}2${NC}) View System Logs (journalctl)"
  box_line "  ${CYAN}3${NC}) View Failed Login Attempts"
  box_line "  ${CYAN}4${NC}) View Kernel Messages (dmesg)"
  box_line "  ${CYAN}5${NC}) Hardware Information"
  box_line "  ${CYAN}6${NC}) Performance Report"
  box_line "  ${CYAN}7${NC}) Security Summary"
  box_line ""
  box_line "  ${CYAN}0${NC}) Back to Main Menu"
  box_line ""
  draw_box_bottom 70

  echo ""
  echo -e -n "${WHITE}Select option:${NC} "
  read -r choice

  case $choice in
  1) generate_full_report ;;
  2) view_system_logs ;;
  3) view_failed_logins ;;
  4) view_kernel_messages ;;
  5) hardware_info ;;
  6) performance_report ;;
  7) security_summary ;;
  0) show_main_menu ;;
  *)
    echo -e "${RED}Invalid option${NC}"
    sleep 1
    system_reports
    ;;
  esac
}

generate_full_report() {
  local report_file="$LOG_DIR/system-report-$(date +%Y%m%d-%H%M%S).txt"

  echo ""
  print_status "info" "Generating comprehensive system report..."
  echo ""

  {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║            IMAGINARY ANGEL SYSTEM REPORT                       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "SYSTEM INFORMATION"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    uname -a
    echo ""
    echo "Uptime: $(uptime -p)"
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "CPU INFORMATION"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    lscpu | head -20
    echo ""
    echo "CPU Usage:"
    mpstat 1 1 2>/dev/null || top -bn1 | grep "Cpu(s)" || echo "CPU stats unavailable"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "MEMORY USAGE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    free -h
    echo ""
    echo "Memory Intensive Processes:"
    ps aux --sort=-%mem | head -11
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "DISK USAGE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    df -h
    echo ""
    echo "Inode Usage:"
    df -i
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "NETWORK CONFIGURATION"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    ip addr show
    echo ""
    echo "Routing Table:"
    ip route show
    echo ""
    echo "DNS Configuration:"
    cat /etc/resolv.conf 2>/dev/null || echo "DNS config unavailable"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "ACTIVE SERVICES"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    systemctl list-units --type=service --state=running --no-pager
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "FAILED SERVICES"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    systemctl list-units --state=failed --no-pager || echo "No failed services"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "SECURITY STATUS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Firewall Status:"
    if systemctl is-active --quiet ufw; then
      ufw status
    elif systemctl is-active --quiet firewalld; then
      firewall-cmd --list-all
    else
      echo "No firewall active"
    fi
    echo ""
    echo "Failed Login Attempts (last 24h):"
    journalctl --since "24 hours ago" | grep -i "failed" | wc -l
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "RECENT ERRORS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    journalctl -p err -b | tail -20 || echo "No recent errors"
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
    echo "PACKAGE STATISTICS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    if command -v pacman &>/dev/null; then
      echo "Total Packages: $(pacman -Q | wc -l)"
      echo "Explicitly Installed: $(pacman -Qe | wc -l)"
      echo "Updates Available: $(pacman -Qu 2>/dev/null | wc -l)"
    elif command -v dpkg &>/dev/null; then
      echo "Total Packages: $(dpkg -l | grep "^ii" | wc -l)"
    fi
    echo ""

    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    END OF REPORT                               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"

  } >"$report_file" 2>&1

  print_status "ok" "Report saved to: $report_file"
  echo ""
  echo -e -n "${WHITE}View report now? (y/N):${NC} "
  read -r view

  if [[ "$view" =~ ^[Yy]$ ]]; then
    less "$report_file"
  fi

  wait_key
  system_reports
}

view_system_logs() {
  echo ""
  print_status "info" "Opening system logs (journalctl)..."
  echo ""

  journalctl -xe

  system_reports
}

view_failed_logins() {
  echo ""
  print_status "info" "Failed Login Attempts:"
  echo ""

  # Check SSH failures
  local ssh_fails=$(journalctl -u sshd --since "7 days ago" 2>/dev/null | grep -i "failed" | wc -l)
  print_status "info" "SSH failed attempts (last 7 days): $ssh_fails"

  if [ "$ssh_fails" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent SSH failures:${NC}"
    journalctl -u sshd --since "7 days ago" 2>/dev/null | grep -i "failed" | tail -20
  fi

  # Check for failed sudo attempts
  echo ""
  local sudo_fails=$(journalctl --since "7 days ago" 2>/dev/null | grep -i "sudo.*FAILED" | wc -l)
  print_status "info" "Failed sudo attempts (last 7 days): $sudo_fails"

  if [ "$sudo_fails" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent sudo failures:${NC}"
    journalctl --since "7 days ago" 2>/dev/null | grep -i "sudo.*FAILED" | tail -10
  fi

  # Check auth log if available
  if [ -f /var/log/auth.log ]; then
    echo ""
    local auth_fails=$(grep -i "authentication failure" /var/log/auth.log 2>/dev/null | wc -l)
    print_status "info" "Authentication failures in auth.log: $auth_fails"
  fi

  wait_key
  system_reports
}

view_kernel_messages() {
  echo ""
  print_status "info" "Recent Kernel Messages:"
  echo ""

  dmesg | less

  system_reports
}

hardware_info() {
  echo ""
  print_status "info" "Hardware Information:"
  echo ""

  echo -e "${CYAN}═══ CPU ═══${NC}"
  lscpu | grep -E "Model name|Architecture|CPU\(s\)|Thread|Core|Socket|MHz"

  echo ""
  echo -e "${CYAN}═══ Memory ═══${NC}"
  free -h

  if command -v dmidecode &>/dev/null; then
    echo ""
    echo -e "${CYAN}═══ Memory Modules ═══${NC}"
    dmidecode -t memory 2>/dev/null | grep -A 5 "Memory Device" | grep -E "Size|Speed|Type:" | head -20
  fi

  echo ""
  echo -e "${CYAN}═══ Disks ═══${NC}"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT

  if command -v smartctl &>/dev/null; then
    echo ""
    echo -e "${CYAN}═══ Disk Health (SMART) ═══${NC}"
    for disk in $(lsblk -d -n -o NAME | grep -E "^sd|^nvme"); do
      echo ""
      echo "Drive: /dev/$disk"
      smartctl -H "/dev/$disk" 2>/dev/null || echo "  SMART not available"
    done
  fi

  echo ""
  echo -e "${CYAN}═══ PCI Devices ═══${NC}"
  lspci | head -20

  if command -v sensors &>/dev/null; then
    echo ""
    echo -e "${CYAN}═══ Temperature Sensors ═══${NC}"
    sensors 2>/dev/null || echo "  No sensors detected"
  fi

  wait_key
  system_reports
}

performance_report() {
  echo ""
  print_status "info" "Performance Analysis:"
  echo ""

  # CPU
  echo -e "${CYAN}═══ CPU Performance ═══${NC}"
  local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
  local cpu_cores=$(nproc)
  local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)

  echo "CPU Cores: $cpu_cores"
  echo "Current Usage: ${cpu_usage}%"
  echo "Load Average (1min): $load_avg"
  echo "Load per Core: $(awk "BEGIN {printf \"%.2f\", $load_avg/$cpu_cores}")"

  # Memory
  echo ""
  echo -e "${CYAN}═══ Memory Performance ═══${NC}"
  local mem_total=$(free -m | awk '/^Mem:/{print $2}')
  local mem_used=$(free -m | awk '/^Mem:/{print $3}')
  local mem_free=$(free -m | awk '/^Mem:/{print $4}')
  local mem_cached=$(free -m | awk '/^Mem:/{print $6}')
  local mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")

  echo "Total: ${mem_total}MB"
  echo "Used: ${mem_used}MB (${mem_percent}%)"
  echo "Free: ${mem_free}MB"
  echo "Cached: ${mem_cached}MB"

  # Disk I/O
  echo ""
  echo -e "${CYAN}═══ Disk I/O ═══${NC}"
  if command -v iostat &>/dev/null; then
    iostat -x 1 2 | tail -n +4
  else
    echo "Install 'sysstat' package for detailed I/O statistics"
  fi

  # Top Processes
  echo ""
  echo -e "${CYAN}═══ Top Resource Consumers ═══${NC}"
  echo "CPU:"
  ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "  %s (PID %s): %.1f%%\n", $11, $2, $3}'

  echo ""
  echo "Memory:"
  ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "  %s (PID %s): %.1f%%\n", $11, $2, $4}'

  wait_key
  system_reports
}

security_summary() {
  echo ""
  print_status "info" "Security Summary:"
  echo ""

  # Firewall
  echo -e "${CYAN}═══ Firewall Status ═══${NC}"
  if systemctl is-active --quiet ufw; then
    print_status "ok" "UFW is active"
    ufw status numbered 2>/dev/null | head -10
  elif systemctl is-active --quiet firewalld; then
    print_status "ok" "firewalld is active"
  else
    print_status "error" "No firewall detected"
  fi

  # SSH Security
  echo ""
  echo -e "${CYAN}═══ SSH Security ═══${NC}"
  if [ -f /etc/ssh/sshd_config ]; then
    local root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}')
    local pass_auth=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}')

    if [ "$root_login" = "no" ]; then
      print_status "ok" "Root login disabled"
    else
      print_status "error" "Root login enabled"
    fi

    echo "Password Authentication: ${pass_auth:-default}"
  fi

  # Recent Failed Logins
  echo ""
  echo -e "${CYAN}═══ Failed Login Attempts ═══${NC}"
  local failed_count=$(journalctl --since "24 hours ago" 2>/dev/null | grep -i "failed" | wc -l)

  if [ "$failed_count" -eq 0 ]; then
    print_status "ok" "No failed logins in last 24h"
  elif [ "$failed_count" -lt 10 ]; then
    print_status "info" "$failed_count failed attempts (normal)"
  else
    print_status "warn" "$failed_count failed attempts (elevated)"
  fi

  # Open Ports
  echo ""
  echo -e "${CYAN}═══ Open Ports ═══${NC}"
  local open_ports=$(ss -tulnp 2>/dev/null | grep LISTEN | wc -l)
  echo "Listening services: $open_ports"
  ss -tulnp 2>/dev/null | grep LISTEN | head -10

  # Updates
  echo ""
  echo -e "${CYAN}═══ System Updates ═══${NC}"
  if command -v pacman &>/dev/null; then
    local updates=$(pacman -Qu 2>/dev/null | wc -l)

    if [ "$updates" -eq 0 ]; then
      print_status "ok" "System is up to date"
    else
      print_status "warn" "$updates update(s) available"
    fi
  fi

  wait_key
  system_reports
}

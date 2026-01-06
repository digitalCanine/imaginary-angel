#!/bin/bash
# Service Management & Optimization Module

service_manager() {
  print_logo
  draw_box 75 "SERVICE MANAGEMENT & OPTIMIZATION"
  echo ""

  box_line "  ${CYAN}1${NC}) View Active Services"
  box_line "  ${CYAN}2${NC}) View Failed Services"
  box_line "  ${CYAN}3${NC}) Restart Failed Services"
  box_line "  ${CYAN}4${NC}) Disable Unnecessary Services"
  box_line "  ${CYAN}5${NC}) Service Resource Usage"
  box_line "  ${CYAN}6${NC}) Boot Time Analysis"
  box_line ""
  box_line "  ${CYAN}0${NC}) Back to Main Menu"
  box_line ""
  draw_box_bottom 75

  echo ""
  echo -e -n "${WHITE}Select option:${NC} "
  read -r choice

  case $choice in
  1) view_active_services ;;
  2) view_failed_services ;;
  3) restart_failed_services ;;
  4) disable_unnecessary ;;
  5) service_resource_usage ;;
  6) boot_time_analysis ;;
  0) show_main_menu ;;
  *)
    echo -e "${RED}Invalid option${NC}"
    sleep 1
    service_manager
    ;;
  esac
}

view_active_services() {
  echo ""
  print_status "info" "Active Services:"
  echo ""

  systemctl list-units --type=service --state=running --no-pager

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

view_failed_services() {
  echo ""
  print_status "info" "Failed Services:"
  echo ""

  local failed=$(systemctl list-units --type=service --state=failed --no-legend)

  if [ -z "$failed" ]; then
    print_status "ok" "No failed services!"
  else
    systemctl list-units --type=service --state=failed --no-pager

    echo ""
    echo -e "${YELLOW}Use 'journalctl -u <service>' to view logs${NC}"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

restart_failed_services() {
  echo ""
  print_status "info" "Checking for failed services..."

  local failed_services=$(systemctl list-units --type=service --state=failed --no-legend | awk '{print $1}')

  if [ -z "$failed_services" ]; then
    print_status "ok" "No failed services to restart"
    echo ""
    echo -e "${GRAY}Press Enter to return to service menu...${NC}"
    read -r
    service_manager
    return
  fi

  echo ""
  print_status "info" "Failed services:"
  echo "$failed_services" | while read service; do
    echo "  ${RED}▸${NC} $service"
  done

  echo ""
  echo -e -n "${YELLOW}Attempt to restart all failed services? (y/N):${NC} "
  read -r confirm

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo ""
    print_status "info" "Restarting failed services..."

    echo "$failed_services" | while read service; do
      echo "  Restarting $service..."

      if systemctl restart "$service" 2>/dev/null; then
        print_status "ok" "$service restarted successfully"
      else
        print_status "error" "Failed to restart $service"
        echo "    ${GRAY}Check logs: journalctl -u $service${NC}"
      fi
    done
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

disable_unnecessary() {
  echo ""
  print_status "info" "Analyzing services for optimization..."
  echo ""

  # List of commonly unnecessary services
  local candidates=(
    "bluetooth.service"
    "cups.service"
    "avahi-daemon.service"
    "ModemManager.service"
  )

  echo -e "${YELLOW}The following services are commonly disabled on systems that don't need them:${NC}"
  echo ""

  local found_any=false

  for service in "${candidates[@]}"; do
    if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
      print_status "info" "$service is enabled"
      found_any=true

      # Provide context
      case "$service" in
      bluetooth.service)
        echo "    ${GRAY}(Only needed if you use Bluetooth devices)${NC}"
        ;;
      cups.service)
        echo "    ${GRAY}(Only needed if you use printers)${NC}"
        ;;
      avahi-daemon.service)
        echo "    ${GRAY}(mDNS/Zeroconf - rarely needed)${NC}"
        ;;
      ModemManager.service)
        echo "    ${GRAY}(Only needed for mobile broadband)${NC}"
        ;;
      esac
    fi
  done

  if [ "$found_any" = false ]; then
    print_status "ok" "No unnecessary services detected"
    echo ""
    echo -e "${GRAY}Press Enter to return to service menu...${NC}"
    read -r
    service_manager
    return
  fi

  echo ""
  echo -e "${RED}WARNING: Only disable services you're sure you don't need!${NC}"
  echo -e -n "${WHITE}Enter service name to disable (or 'q' to quit):${NC} "
  read -r service

  if [ "$service" = "q" ] || [ -z "$service" ]; then
    service_manager
    return
  fi

  if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
    echo ""
    echo -e -n "${YELLOW}Disable $service? (y/N):${NC} "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      systemctl stop "$service" 2>/dev/null
      systemctl disable "$service" 2>/dev/null
      print_status "ok" "$service disabled"
    fi
  else
    print_status "error" "Service not found or not enabled"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

service_resource_usage() {
  echo ""
  print_status "info" "Service Resource Usage (Top 10 by Memory):"
  echo ""

  echo -e "${CYAN}SERVICE                               CPU%    MEM%${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Get all active services and their resource usage
  systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | while read service; do
    local main_pid=$(systemctl show -p MainPID "$service" 2>/dev/null | cut -d= -f2)

    if [ -n "$main_pid" ] && [ "$main_pid" != "0" ]; then
      local usage=$(ps -p "$main_pid" -o %cpu,%mem,comm 2>/dev/null | tail -1)

      if [ -n "$usage" ]; then
        local cpu=$(echo "$usage" | awk '{print $1}')
        local mem=$(echo "$usage" | awk '{print $2}')
        local comm=$(echo "$usage" | awk '{print $3}')

        # Only show if using resources
        if [ -n "$cpu" ] && [ -n "$mem" ]; then
          printf "%-35s  %5s   %5s\n" "$service" "$cpu" "$mem"
        fi
      fi
    fi
  done | sort -k3 -rn | head -10

  echo ""
  echo -e "${GRAY}Note: Only showing services with active processes${NC}"

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

boot_time_analysis() {
  echo ""
  print_status "info" "Boot Time Analysis:"
  echo ""

  if command -v systemd-analyze &>/dev/null; then
    # Overall boot time
    print_status "info" "Overall Boot Time:"
    systemd-analyze

    echo ""
    print_status "info" "Top 10 Slowest Services:"
    echo ""
    systemd-analyze blame | head -10

    echo ""
    print_status "info" "Critical Chain (services blocking boot):"
    echo ""
    systemd-analyze critical-chain | head -20

  else
    print_status "error" "systemd-analyze not available"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to service menu...${NC}"
  read -r
  service_manager
}

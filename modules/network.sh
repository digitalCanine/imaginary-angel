#!/bin/bash
# Network Threat Detection Module

network_threat_detection() {
  print_logo
  draw_box 75 "NETWORK THREAT DETECTION"
  echo ""

  # Load config with defaults
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
  AUTO_FIX=${AUTO_FIX:-false}

  local threats=0
  local blocked=0

  print_status "info" "Analyzing network traffic and connections..."
  echo ""

  # ========== SUSPICIOUS CONNECTIONS ==========
  print_status "info" "Checking for suspicious network connections..."
  echo ""

  # Check for connections to unusual ports
  local unusual_connections=$(ss -tunap 2>/dev/null | grep ESTAB |
    awk '{print $6}' | grep -oE ':([0-9]+)$' | tr -d ':' |
    grep -vE '^(80|443|22|21|25|110|143|993|995|587|53|123)$' | wc -l)

  if [ "$unusual_connections" -eq 0 ]; then
    print_status "ok" "All connections on standard ports"
  else
    print_status "warn" "$unusual_connections connection(s) to unusual ports detected"

    echo -e "  ${YELLOW}Connections to non-standard ports:${NC}"
    while IFS= read -r line; do
      local remote=$(echo "$line" | awk '{print $6}')
      local port=$(echo "$remote" | grep -oE ':([0-9]+)$' | tr -d ':')
      local process=$(echo "$line" | awk '{print $7}' | grep -oP '\(".*?"\)' | tr -d '()"' || echo "unknown")

      if ! echo "$port" | grep -qE '^(80|443|22|21|25|110|143|993|995|587|53|123)$'; then
        echo -e "    ${YELLOW}▸${NC} $remote ($process) - port $port"
      fi
    done < <(ss -tunap 2>/dev/null | grep ESTAB)
  fi

  # ========== MULTIPLE CONNECTIONS FROM SINGLE IP ==========
  echo ""
  print_status "info" "Detecting potential port scans or DDoS attempts..."

  # Count connections per remote IP
  local connection_analysis=$(ss -tunap 2>/dev/null | grep ESTAB | awk '{print $6}' |
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn)

  local found_suspicious=false

  if [ -n "$connection_analysis" ]; then
    while IFS= read -r line; do
      local count=$(echo "$line" | awk '{print $1}')
      local ip=$(echo "$line" | awk '{print $2}')

      if [ "$count" -gt 10 ]; then
        print_status "error" "Suspicious: $ip has $count active connections!"
        threats=$((threats + 1))
        found_suspicious=true

        if [ "$AUTO_FIX" = "true" ] && command -v ufw &>/dev/null; then
          print_status "fix" "Blocking $ip..."
          ufw deny from "$ip" >/dev/null 2>&1
          blocked=$((blocked + 1))
        fi
      elif [ "$count" -gt 5 ]; then
        print_status "warn" "$ip has $count active connections (monitoring)"
        found_suspicious=true
      fi
    done <<<"$connection_analysis"

    if [ "$found_suspicious" = false ]; then
      print_status "ok" "No suspicious connection patterns detected"

      # Show top 3 connection sources for reference
      echo ""
      echo -e "  ${CYAN}Top connection sources:${NC}"
      echo "$connection_analysis" | head -3 | while IFS= read -r line; do
        local count=$(echo "$line" | awk '{print $1}')
        local ip=$(echo "$line" | awk '{print $2}')
        echo -e "    ${BLUE}▸${NC} $ip: $count connection(s)"
      done
    fi
  else
    print_status "info" "No active external connections to analyze"
  fi

  # ========== LISTENING PORTS ANALYSIS ==========
  echo ""
  print_status "info" "Analyzing listening services..."
  echo ""

  local listening_services=$(ss -tulnp 2>/dev/null | grep LISTEN)

  if [ -z "$listening_services" ]; then
    print_status "info" "No listening services detected"
  else
    local listening_count=$(echo "$listening_services" | wc -l)
    print_status "info" "Found $listening_count listening service(s)"
    echo ""

    while IFS= read -r line; do
      local addr=$(echo "$line" | awk '{print $5}')
      local port=$(echo "$addr" | rev | cut -d: -f1 | rev)
      local process=$(echo "$line" | awk '{print $7}' | grep -oP '\(".*?"\)' | tr -d '()"' || echo "unknown")

      # Check if listening on all interfaces (0.0.0.0 or ::)
      if echo "$addr" | grep -qE '^(0\.0\.0\.0|\*|\[::\])'; then
        # Check if it's a known safe service
        if echo "$process" | grep -qE '(sshd|httpd|nginx|apache|mysqld|postgres)'; then
          print_status "ok" "Port $port: $process (exposed to internet - standard service)"
        else
          print_status "warn" "Port $port: $process (exposed to all interfaces)"
          echo -e "    ${GRAY}Consider binding to localhost if not needed externally${NC}"
        fi
      else
        print_status "ok" "Port $port: $process (localhost only - secure)"
      fi
    done <<<"$listening_services"
  fi

  # ========== UNUSUAL NETWORK ACTIVITY ==========
  echo ""
  print_status "info" "Checking for unusual network activity patterns..."

  # Check for processes with excessive network usage
  if command -v nethogs &>/dev/null; then
    print_status "info" "Top bandwidth consumers:"
    timeout 3 nethogs -t 2>/dev/null | tail -10 ||
      print_status "info" "Install 'nethogs' for detailed bandwidth monitoring"
  else
    print_status "info" "Install 'nethogs' for bandwidth analysis (pacman -S nethogs)"
  fi

  # ========== DNS REQUESTS ANALYSIS ==========
  echo ""
  print_status "info" "Checking DNS configuration..."

  if [ -f /etc/resolv.conf ]; then
    local dns_servers=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}')

    echo -e "  ${CYAN}Configured DNS servers:${NC}"
    while IFS= read -r server; do
      # Check for suspicious DNS servers
      if echo "$server" | grep -qE '^(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9)$'; then
        echo -e "    ${GREEN}▸${NC} $server (trusted public DNS)"
      elif echo "$server" | grep -qE '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
        echo -e "    ${BLUE}▸${NC} $server (local network)"
      else
        echo -e "    ${YELLOW}▸${NC} $server (verify this DNS server)"
      fi
    done <<<"$dns_servers"
  fi

  # ========== ARP CACHE POISONING CHECK ==========
  echo ""
  print_status "info" "Checking for ARP spoofing attempts..."

  local arp_duplicates=$(arp -an 2>/dev/null | awk '{print $4}' | sort | uniq -d | wc -l)

  if [ "$arp_duplicates" -eq 0 ]; then
    print_status "ok" "No duplicate MAC addresses in ARP cache"
  else
    print_status "error" "Duplicate MAC addresses detected - possible ARP spoofing!"
    threats=$((threats + 1))

    echo -e "  ${RED}Duplicate MAC addresses:${NC}"
    while IFS= read -r mac; do
      echo "    $mac"
      arp -an 2>/dev/null | grep "$mac" | while IFS= read -r line; do
        echo "      $line"
      done
    done < <(arp -an 2>/dev/null | awk '{print $4}' | sort | uniq -d)
  fi

  # ========== ACTIVE NETWORK INTERFACES ==========
  echo ""
  print_status "info" "Network interface status:"
  echo ""

  while IFS= read -r line; do
    local iface=$(echo "$line" | awk '{print $1}')
    local state=$(echo "$line" | awk '{print $2}')
    local addr=$(echo "$line" | awk '{print $3}')

    if [ "$state" = "UP" ]; then
      print_status "ok" "$iface: $addr (active)"

      # Check for promiscuous mode (packet sniffing)
      if ip link show "$iface" 2>/dev/null | grep -q "PROMISC"; then
        print_status "warn" "$iface is in PROMISCUOUS mode (packet capture active)"
        threats=$((threats + 1))
      fi
    else
      print_status "info" "$iface: $state"
    fi
  done < <(ip -br addr show)

  # ========== RECENT CONNECTION LOG ==========
  echo ""
  print_status "info" "Recent connection attempts (last hour)..."

  if [ -f /var/log/auth.log ]; then
    local recent_connections=$(grep -i "connection" /var/log/auth.log 2>/dev/null |
      grep "$(date +'%b %d %H')" | wc -l)
    echo "  Found $recent_connections connection attempts in the last hour"
  elif command -v journalctl &>/dev/null; then
    local recent_ssh=$(journalctl -u sshd --since "1 hour ago" 2>/dev/null |
      grep -i "connection" | wc -l)
    echo "  Found $recent_ssh SSH connection attempts in the last hour"
  fi

  # ========== PACKET FILTERING RULES ==========
  echo ""
  print_status "info" "Active packet filtering rules..."

  if command -v ufw &>/dev/null && systemctl is-active --quiet ufw; then
    local ufw_rules=$(ufw status numbered 2>/dev/null | grep -c "^\[")
    print_status "ok" "UFW active with $ufw_rules rule(s)"
  elif command -v iptables &>/dev/null; then
    local ipt_rules=$(iptables -L -n 2>/dev/null | grep -c "^Chain")
    print_status "info" "iptables active with $ipt_rules chain(s)"
  else
    print_status "warn" "No packet filtering detected"
  fi

  # ========== SUMMARY ==========
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

  if [ "$threats" -eq 0 ]; then
    print_status "ok" "No network threats detected - system is secure"
  else
    echo -e "${RED}Detected $threats potential network threat(s)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Blocked $blocked threat(s) automatically${NC}"

      if [ "$blocked" -lt "$threats" ]; then
        echo -e "${YELLOW}$(($threats - $blocked)) threat(s) require manual investigation${NC}"
      fi
    else
      echo -e "${GRAY}Enable AUTO_FIX in Configuration menu to automatically block threats${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
  show_main_menu
}

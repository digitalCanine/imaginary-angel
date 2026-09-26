#!/bin/bash
# Network Threat Detection Module

# Addresses auto-blocking must never touch: loopback, private/link-local ranges
# (the LAN, the router, DNS forwarders) and the client of an SSH session
is_blockable_ip() {
  local ip=$1
  case "$ip" in
  127.* | 10.* | 192.168.* | 169.254.* | 0.*) return 1 ;;
  172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 1 ;;
  esac
  if [ -n "${SSH_CLIENT:-}" ] && [ "${SSH_CLIENT%% *}" = "$ip" ]; then
    return 1
  fi
  # sudo drops SSH_CLIENT, so also check live sshd sessions
  if ss -Htnp state established 2>/dev/null | awk '/"sshd/ {print $4}' | grep -q "^$ip:"; then
    return 1
  fi
  return 0
}

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

  # Sussy connections
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

  # Several connections from one IP
  echo ""
  print_status "info" "Detecting potential port scans or DDoS attempts..."

  # Count connections per remote IP
  # Only inbound connections (to a port this machine listens on) count: a browser
  # easily opens 10+ outbound connections to one CDN, and that is not an attack
  local listen_ports=$(ss -Htln 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | sort -u | tr '\n' ' ')
  local connection_analysis=$(ss -Htn state established 2>/dev/null |
    awk -v ports=" $listen_ports" '{n = split($3, a, ":"); if (index(ports, " " a[n] " ")) print $4}' |
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
          if ! is_blockable_ip "$ip"; then
            print_status "info" "Not blocking $ip (local network or your own SSH session)"
          elif ufw deny from "$ip" >/dev/null 2>&1; then
            print_status "fix" "Blocked $ip"
            blocked=$((blocked + 1))
          else
            print_status "error" "Could not block $ip"
          fi
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

  # Listening ports
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

  # unsual activites
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

  # DNS requests
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

  dump_neighbor_table() {
    if command -v arp >/dev/null 2>&1; then
      arp -an 2>/dev/null | grep -Ev '<incomplete>|\(incomplete\)' | awk '
      {
        ip=""; mac="";
        for (i=1;i<=NF;i++) {
          if ($i ~ /^\(.*\)$/) { ip=$i; gsub(/[()]/,"",ip); }
          if ($i=="at") mac=$(i+1);
        }
        if (ip!="" && mac!="") print ip, mac;
      }'
    elif command -v ip >/dev/null 2>&1; then
      ip neigh show 2>/dev/null | awk '
      !/FAILED|INCOMPLETE/ {
        ip=$1; mac="";
        for (i=1;i<=NF;i++) if ($i=="lladdr") mac=$(i+1);
        if (mac!="") print ip, mac;
      }'
    fi
  }

  get_mac_for_ip() {
    dump_neighbor_table | awk -v gw="$1" '$1==gw{print $2; exit}'
  }

  get_gateway_ip() {
    if command -v ip >/dev/null 2>&1; then
      ip route show default 2>/dev/null | awk '/^default/{print $3; exit}'
    elif [ "$(uname)" = "Darwin" ]; then
      route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
    else
      netstat -rn 2>/dev/null | awk '/^default|^0\.0\.0\.0/{print $2; exit}'
    fi
  }

  # ARP check body
  echo ""
  print_status "info" "Checking for ARP spoofing/poisoning..."

  # Under sudo $HOME can be the user's home, so keep root's state in angel's cache
  local ARP_STATE_DIR="${CACHE_DIR:-/var/cache/imaginary-angel}/arpcheck"
  local ARP_STATE_FILE="$ARP_STATE_DIR/gateway_mac"
  mkdir -p "$ARP_STATE_DIR" 2>/dev/null

  local gateway_ip gateway_mac known_mac
  gateway_ip=$(get_gateway_ip)

  if [ -z "$gateway_ip" ]; then
    print_status "info" "Could not determine default gateway; skipping gateway MAC check"
  else
    # Refresh the neighbor entry; many routers don't answer ping, which is fine
    ping -c 1 -W 1 "$gateway_ip" >/dev/null 2>&1 || true
    gateway_mac=$(get_mac_for_ip "$gateway_ip")

    if [ -z "$gateway_mac" ]; then
      print_status "info" "Could not resolve MAC for gateway $gateway_ip"
    elif [ -f "$ARP_STATE_FILE" ]; then
      known_mac=$(cat "$ARP_STATE_FILE" 2>/dev/null)
      if [ -n "$known_mac" ] && [ "$gateway_mac" != "$known_mac" ]; then
        print_status "error" "Gateway MAC changed: $gateway_ip was $known_mac, now $gateway_mac"
        threats=$((threats + 1))
        echo -e "  ${RED}This is the strongest indicator of active ARP spoofing.${NC}"
        echo "  If you haven't replaced your router, treat this as a live attack."
      else
        print_status "ok" "Gateway MAC unchanged ($gateway_ip -> $gateway_mac)"
      fi
      echo "$gateway_mac" 2>/dev/null >"$ARP_STATE_FILE" || print_status "warn" "Could not save the gateway MAC baseline to $ARP_STATE_FILE"
    else
      print_status "info" "No baseline yet - recording gateway MAC ($gateway_ip -> $gateway_mac)"
      echo "$gateway_mac" 2>/dev/null >"$ARP_STATE_FILE" || print_status "warn" "Could not save the gateway MAC baseline to $ARP_STATE_FILE"
    fi
  fi

  echo ""
  print_status "info" "Scanning for MAC addresses claiming multiple IP addresses..."

  local pairs filtered dup_macs
  pairs=$(dump_neighbor_table)

  if [ -z "$pairs" ]; then
    print_status "info" "No ARP/neighbor entries available to scan"
  else
    filtered=$(echo "$pairs" | awk '
    {
      mac=tolower($2)
      if (mac ~ /^00:00:5e:00:0[12]:/) next   # VRRP
      if (mac ~ /^00:00:0c:07:ac:/) next        # HSRP
      if (mac ~ /^00:07:b4:/) next               # GLBP
      print
    }')
    dup_macs=$(echo "$filtered" | awk '{print $2}' | sort | uniq -d)

    if [ -z "$dup_macs" ]; then
      print_status "ok" "No MAC address is claiming multiple IP addresses"
    else
      print_status "error" "MAC address(es) claiming multiple IPs - likely ARP poisoning!"
      threats=$((threats + 1))
      echo -e "  ${RED}Conflicting entries (verify - could also be a bridge/proxy-ARP setup):${NC}"
      while IFS= read -r mac; do
        [ -z "$mac" ] && continue
        echo "    $mac:"
        echo "$filtered" | awk -v m="$mac" '$2==m{print "      " $1}'
      done <<<"$dup_macs"
    fi
  fi

  # Active interfaces
  echo ""
  print_status "info" "Network interface status:"
  echo ""

  while IFS= read -r line; do
    local iface=$(echo "$line" | awk '{print $1}')
    local state=$(echo "$line" | awk '{print $2}')
    local addr=$(echo "$line" | awk '{print $3}')

    if [ "$state" = "UP" ]; then
      print_status "ok" "$iface: $addr (active)"

      # Check for packet sniffing
      if ip link show "$iface" 2>/dev/null | grep -q "PROMISC"; then
        print_status "warn" "$iface is in PROMISCUOUS mode (packet capture active)"
        threats=$((threats + 1))
      fi
    else
      print_status "info" "$iface: $state"
    fi
  done < <(ip -br addr show)

  # Recent connections
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

  # Packet filtering rule
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

  # Summary
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
}

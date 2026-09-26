#!/bin/bash
# Security Audit & Hardening Module

security_audit() {
  print_logo
  draw_box 70 "SECURITY AUDIT & HARDENING"
  echo ""

  # Load config with defaults
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
  AUTO_FIX=${AUTO_FIX:-false}

  local vulnerabilities=0
  local fixed=0

  print_status "info" "Running comprehensive security audit..."
  echo ""

  # SSH
  print_status "info" "Checking SSH configuration..."

  if command -v sshd &>/dev/null && [ -f /etc/ssh/sshd_config ]; then
    # sshd -T prints the effective config, including sshd_config.d drop-ins
    # (where hardening puts its settings); fall back to the main file
    local sshd_eff root_login empty_pw pass_auth
    sshd_eff=$(sshd -T 2>/dev/null || true)
    if [ -z "$sshd_eff" ]; then
      sshd_eff=$(grep -Ei '^[[:space:]]*(PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication)[[:space:]]' \
        /etc/ssh/sshd_config 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    fi
    root_login=$(awk '$1 == "permitrootlogin" {print $2; exit}' <<<"$sshd_eff")
    empty_pw=$(awk '$1 == "permitemptypasswords" {print $2; exit}' <<<"$sshd_eff")
    pass_auth=$(awk '$1 == "passwordauthentication" {print $2; exit}' <<<"$sshd_eff")

    local ssh_bad=false
    if [ "$root_login" = "yes" ]; then
      print_status "error" "SSH root login with a password is ENABLED (critical security risk)"
      vulnerabilities=$((vulnerabilities + 1))
      ssh_bad=true
    else
      print_status "ok" "SSH root login: ${root_login:-prohibit-password}"
    fi

    if [ "$pass_auth" = "no" ]; then
      print_status "ok" "SSH using key-based authentication"
    else
      print_status "warn" "SSH password authentication is enabled (key-based is more secure)"
    fi

    if [ "$empty_pw" = "yes" ]; then
      print_status "error" "SSH allows empty passwords!"
      vulnerabilities=$((vulnerabilities + 1))
      ssh_bad=true
    fi

    if [ "$ssh_bad" = true ] && [ "$AUTO_FIX" = "true" ]; then
      # Writes a drop-in, validates it with sshd -t and reloads (existing sessions stay up)
      print_status "fix" "Applying SSH hardening..."
      if run_hardening ssh; then
        fixed=$((fixed + 1))
      fi
    fi
  else
    print_status "info" "SSH not installed"
  fi

  # Firewall
  echo ""
  print_status "info" "Checking firewall status..."

  local firewall_active=false

  if systemctl is-active --quiet ufw 2>/dev/null; then
    print_status "ok" "Firewall (UFW) is active"
    firewall_active=true
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    print_status "ok" "Firewall (firewalld) is active"
    firewall_active=true
  elif iptables -L -n 2>/dev/null | grep -q "Chain INPUT (policy DROP"; then
    print_status "ok" "Firewall (iptables) is active"
    firewall_active=true
  else
    print_status "error" "No active firewall detected!"
    vulnerabilities=$((vulnerabilities + 1))

    if [ "$AUTO_FIX" = "true" ]; then
      # Keeps SSH reachable if sshd is in use (including the current session)
      print_status "fix" "Enabling the firewall (UFW)..."
      if run_hardening firewall; then
        fixed=$((fixed + 1))
      fi
    fi
  fi

  # Privileged users
  echo ""
  print_status "info" "Checking for users with UID 0 (superuser privileges)..."

  local uid0_users=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
  local uid0_count=$(echo "$uid0_users" | grep -v '^root$' | wc -l)

  if [ "$uid0_count" -eq 0 ]; then
    print_status "ok" "Only root has UID 0"
  else
    print_status "error" "Additional users with UID 0 detected:"
    while IFS= read -r user; do
      echo -e "    ${RED}▸${NC} $user"
    done <<<"$(echo "$uid0_users" | grep -v '^root$')"
    vulnerabilities=$((vulnerabilities + 1))
  fi

  # Passwords
  echo ""
  print_status "info" "Checking password security..."

  # Check for users with empty passwords
  local empty_pass_count=0
  if [ -r /etc/shadow ]; then
    # An empty field means no password at all; "!" or "*" means locked, which is safe
    empty_pass_count=$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null | wc -l)
  fi

  if [ "$empty_pass_count" -eq 0 ]; then
    print_status "ok" "No users with empty passwords"
  else
    print_status "error" "$empty_pass_count user(s) can log in without a password"
    vulnerabilities=$((vulnerabilities + 1))
  fi

  # World writable files
  echo ""
  print_status "info" "Checking for dangerous file permissions..."

  local writable_etc=$(find /etc -type f -perm -002 2>/dev/null | wc -l)

  if [ "$writable_etc" -eq 0 ]; then
    print_status "ok" "No world-writable files in /etc"
  else
    print_status "error" "$writable_etc world-writable file(s) in /etc"
    vulnerabilities=$((vulnerabilities + 1))

    if [ "$AUTO_FIX" = "true" ]; then
      print_status "fix" "Removing world-write permissions from /etc files..."
      find /etc -type f -perm -002 -exec chmod o-w {} \; 2>/dev/null || true
      fixed=$((fixed + 1))
    fi
  fi

  # SUID
  echo ""
  print_status "info" "Checking SUID binaries (run with elevated privileges)..."

  local suid_bins=$(find /usr/bin /usr/sbin /bin /sbin -perm -4000 -type f 2>/dev/null)
  local suid_count=$(echo "$suid_bins" | wc -l)

  print_status "info" "Found $suid_count SUID binaries"

  # Show all SUID binaries
  echo ""
  echo -e "  ${CYAN}SUID binaries:${NC}"
  while IFS= read -r binary; do
    local perms=$(stat -c "%a" "$binary" 2>/dev/null)
    local owner=$(stat -c "%U" "$binary" 2>/dev/null)
    echo -e "    ${BLUE}▸${NC} $binary (${owner}, ${perms})"
  done <<<"$suid_bins"

  # Check for unusual SUID binaries
  echo ""
  local suspicious_suid=$(echo "$suid_bins" |
    grep -vE '(sudo|su|passwd|ping|mount|umount|fusermount|pkexec|newgrp|chsh|chfn|unix_chkpwd|userhelper|staprun)')

  if [ -n "$suspicious_suid" ]; then
    local suspicious_count=$(echo "$suspicious_suid" | wc -l)
    print_status "warn" "$suspicious_count potentially unusual SUID binaries found:"

    while IFS= read -r binary; do
      echo -e "    ${YELLOW}▸${NC} $binary"
    done <<<"$suspicious_suid"

    echo ""
    echo -e "  ${GRAY}Note: Review these binaries to ensure they're legitimate${NC}"
  else
    print_status "ok" "All SUID binaries appear standard"
  fi

  # MAC
  echo ""
  print_status "info" "Checking Mandatory Access Control (MAC) system..."

  if command -v aa-status &>/dev/null; then
    if aa-status --enabled 2>/dev/null; then
      print_status "ok" "AppArmor is enabled and active"
    else
      print_status "warn" "AppArmor is installed but not enabled"
      vulnerabilities=$((vulnerabilities + 1))

      if [ "$AUTO_FIX" = "true" ]; then
        # AppArmor also needs the lsm= kernel parameter, which harden.sh adds
        print_status "fix" "Enabling AppArmor (active after reboot)..."
        if run_hardening apparmor; then
          fixed=$((fixed + 1))
        fi
      fi
    fi
  elif command -v sestatus &>/dev/null; then
    local se_status=$(sestatus | grep "SELinux status" | awk '{print $3}')
    if [ "$se_status" = "enabled" ]; then
      print_status "ok" "SELinux is enabled"
    else
      print_status "warn" "SELinux is installed but not enabled"
    fi
  else
    print_status "warn" "No MAC system (AppArmor/SELinux) detected"
    vulnerabilities=$((vulnerabilities + 1))
  fi

  # Failed logins
  echo ""
  print_status "info" "Checking for suspicious login activity..."

  local failed_ssh=$(journalctl -u sshd --since "24 hours ago" 2>/dev/null | grep -i "failed" | wc -l)

  if [ "$failed_ssh" -eq 0 ]; then
    print_status "ok" "No failed SSH login attempts in last 24h"
  elif [ "$failed_ssh" -lt 10 ]; then
    print_status "info" "$failed_ssh failed SSH login attempts in last 24h (normal)"
  elif [ "$failed_ssh" -lt 50 ]; then
    print_status "warn" "$failed_ssh failed SSH login attempts in last 24h (elevated)"
  else
    print_status "error" "$failed_ssh failed SSH login attempts in last 24h (possible attack!)"
    vulnerabilities=$((vulnerabilities + 1))

    # Show top attacking IPs
    echo -e "  ${YELLOW}Top attacking IPs:${NC}"
    journalctl -u sshd --since "24 hours ago" 2>/dev/null |
      grep -i "failed" |
      grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' |
      sort | uniq -c | sort -rn | head -5 |
      while read count ip; do
        echo "    $ip: $count attempts"
      done
  fi

  # Opened ports
  echo ""
  print_status "info" "Checking for exposed services..."

  local exposed_ports=$(ss -tulnp 2>/dev/null | grep LISTEN | wc -l)
  print_status "info" "$exposed_ports service(s) listening on network ports"

  # Check for commonly exploited ports
  if ss -tulnp 2>/dev/null | grep -q ":23 "; then
    print_status "error" "Telnet (port 23) is running - HIGHLY INSECURE!"
    vulnerabilities=$((vulnerabilities + 1))
  fi

  if ss -tulnp 2>/dev/null | grep -q ":21 "; then
    print_status "warn" "FTP (port 21) is running - consider SFTP instead"
  fi

  # Kernel hardening
  echo ""
  print_status "info" "Checking kernel security parameters..."

  # Check if IP forwarding is disabled
  if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 0 ]; then
    print_status "ok" "IP forwarding is disabled"
  else
    print_status "warn" "IP forwarding is enabled (only needed for routers)"
  fi

  # Check if SYN cookies are enabled
  if [ "$(cat /proc/sys/net/ipv4/tcp_syncookies)" -eq 1 ]; then
    print_status "ok" "SYN cookie protection enabled"
  else
    print_status "warn" "SYN cookie protection disabled"

    if [ "$AUTO_FIX" = "true" ]; then
      # Writes /etc/sysctl.d (Arch doesn't read /etc/sysctl.conf at boot) and applies it
      print_status "fix" "Enabling SYN cookie protection..."
      if run_hardening sysctl; then
        fixed=$((fixed + 1))
      fi
    fi
  fi

  # Summary
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"

  if [ "$vulnerabilities" -eq 0 ]; then
    print_status "ok" "Security audit complete - no critical vulnerabilities found!"
  else
    echo -e "${RED}Found $vulnerabilities security issue(s)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Fixed $fixed issue(s) automatically${NC}"

      if [ "$fixed" -lt "$vulnerabilities" ]; then
        echo -e "${YELLOW}$(($vulnerabilities - $fixed)) issue(s) require manual attention${NC}"
      fi
    else
      echo -e "${GRAY}Enable AUTO_FIX in Configuration menu to automatically fix issues${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
}

#!/bin/bash
# System Integrity & Recovery Module

integrity_check() {
  print_logo
  draw_box 75 "SYSTEM INTEGRITY & RECOVERY"
  echo ""

  # Load config with defaults
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
  AUTO_FIX=${AUTO_FIX:-false}

  local issues=0
  local fixed=0

  print_status "info" "Verifying system integrity..."
  echo ""

  # Package DB integrity
  print_status "info" "Checking package database integrity..."

  if command -v pacman &>/dev/null; then
    # Check for broken packages
    # grep -c (not wc -l): echo of an empty string is still one line
    # "Permission denied" means we couldn't look (non-root run), not that a file is bad
    local broken_output=$(pacman -Qk 2>&1 | grep "^warning" | grep -v "(Permission denied)" || true)
    local broken=$(grep -c . <<<"$broken_output" || true)

    if [ "$broken" -eq 0 ]; then
      print_status "ok" "Package database integrity verified"
    else
      print_status "error" "$broken package file(s) have integrity issues"
      issues=$((issues + 1))

      echo ""
      echo -e "  ${RED}Packages with integrity issues:${NC}"
      local count=0
      while IFS= read -r line; do
        if [ "$count" -lt 20 ]; then
          # Extract package name from warning
          local pkg=$(echo "$line" | grep -oP '(?<=: )\S+(?=:)' | head -1)
          if [ -n "$pkg" ]; then
            echo -e "    ${RED}▸${NC} $pkg"
          else
            echo -e "    ${YELLOW}▸${NC} $line"
          fi
        fi
        count=$((count + 1))
      done <<<"$broken_output"

      if [ "$broken" -gt 20 ]; then
        echo -e "    ${GRAY}... and $(($broken - 20)) more${NC}"
      fi

      if [ "$AUTO_FIX" = "true" ]; then
        echo ""
        print_status "fix" "Reinstalling packages with integrity issues..."

        # Extract unique package names and reinstall
        local packages=$(echo "$broken_output" | grep -oP '(?<=: )\S+(?=:)' | cut -d: -f1 | sort -u | head -10)

        if [ -n "$packages" ]; then
          while IFS= read -r pkg; do
            if [ -n "$pkg" ]; then
              # Only reinstall the exact installed version: pulling a newer one from
              # the sync DB without a full -Syu is a partial upgrade and can break the system
              local installed_ver sync_ver
              installed_ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
              sync_ver=$(pacman -Si "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')
              if [ -z "$sync_ver" ]; then
                print_status "warn" "Skipping $pkg: not in the sync repos (AUR or local package)"
                continue
              fi
              if [ "$installed_ver" != "$sync_ver" ]; then
                print_status "warn" "Skipping $pkg: repo has $sync_ver, installed is $installed_ver (run a full update first)"
                continue
              fi
              echo "  Reinstalling $pkg..."
              if pacman -S --noconfirm "$pkg" >/dev/null 2>&1; then
                print_status "ok" "Reinstalled $pkg"
                fixed=$((fixed + 1))
              else
                print_status "error" "Failed to reinstall $pkg"
              fi
            fi
          done <<<"$packages"
        fi
      else
        echo ""
        echo -e "  ${CYAN}To rebuild these packages:${NC}"
        echo "    pacman -S --noconfirm \$(pacman -Qk 2>&1 | grep 'warning:' | awk '{print \$2}' | cut -d: -f1 | sort -u)"
      fi
    fi
  elif command -v dpkg &>/dev/null; then
    # Anything not installed-ok (ii), removed-with-config (rc), unknown (un),
    # held (hi) or purged (pn), including states carrying an error flag (e.g. iiR)
    local broken_packages=$(dpkg -l 2>/dev/null | awk 'NR > 5 && $1 !~ /^(ii|rc|un|hi|pn)$/' || true)
    local broken=$(grep -c . <<<"$broken_packages" || true)

    if [ "$broken" -eq 0 ]; then
      print_status "ok" "Package database integrity verified"
    else
      print_status "error" "$broken package(s) not fully installed"
      issues=$((issues + 1))

      echo ""
      echo -e "  ${RED}Broken packages:${NC}"
      while IFS= read -r line; do
        local pkg=$(echo "$line" | awk '{print $2}')
        echo -e "    ${RED}▸${NC} $pkg"
      done <<<"$broken_packages"

      if [ "$AUTO_FIX" = "true" ]; then
        print_status "fix" "Fixing broken packages..."
        if apt-get -f install -y >/dev/null 2>&1; then
          fixed=$((fixed + 1))
        fi
      else
        echo ""
        echo -e "  ${CYAN}To rebuild: ${NC}sudo apt-get -f install"
      fi
    fi
  fi

  # Critical system files
  echo ""
  print_status "info" "Checking critical system files..."

  local critical_files=(
    "/etc/passwd"
    "/etc/shadow"
    "/etc/group"
    "/etc/gshadow"
    "/etc/fstab"
    "/etc/sudoers"
    "/etc/hostname"
    "/etc/hosts"
  )

  for file in "${critical_files[@]}"; do
    if [ -f "$file" ]; then
      # Check file permissions
      local perms=$(stat -c "%a" "$file")

      case "$file" in
      */shadow | */gshadow)
        # Distros differ (000, 600, 640); anything at least this strict is fine
        if [ "$perms" != "640" ] && [ "$perms" != "600" ] && [ "$perms" != "400" ] && [ "$perms" != "000" ]; then
          print_status "warn" "$file has permissions $perms (expected 640 or stricter)"
          issues=$((issues + 1))

          if [ "$AUTO_FIX" = "true" ]; then
            print_status "fix" "Fixing permissions on $file"
            chmod 640 "$file"
            fixed=$((fixed + 1))
          fi
        else
          print_status "ok" "$file (permissions: $perms)"
        fi
        ;;
      */sudoers)
        if [ "$perms" != "440" ] && [ "$perms" != "640" ]; then
          print_status "warn" "$file has permissions $perms (should be 440)"
          issues=$((issues + 1))

          if [ "$AUTO_FIX" = "true" ]; then
            print_status "fix" "Fixing permissions on $file"
            chmod 440 "$file"
            fixed=$((fixed + 1))
          fi
        else
          print_status "ok" "$file (permissions: $perms)"
        fi
        ;;
      *)
        print_status "ok" "$file exists (permissions: $perms)"
        ;;
      esac
    else
      print_status "error" "$file is MISSING!"
      issues=$((issues + 1))
    fi
  done

  # Config file merge
  echo ""
  print_status "info" "Checking for pending configuration merges..."

  local pacnew_count=$(find /etc -name "*.pacnew" 2>/dev/null | wc -l)
  local pacsave_count=$(find /etc -name "*.pacsave" 2>/dev/null | wc -l)
  local rpmnew_count=$(find /etc -name "*.rpmnew" 2>/dev/null | wc -l)

  if [ "$pacnew_count" -gt 0 ]; then
    print_status "warn" "$pacnew_count .pacnew file(s) need to be merged"
    issues=$((issues + 1))

    local count=0
    while IFS= read -r file; do
      if [ "$count" -lt 5 ]; then
        echo -e "    ${YELLOW}▸${NC} $file"
      fi
      count=$((count + 1))
    done < <(find /etc -name "*.pacnew" 2>/dev/null)

    if [ "$pacnew_count" -gt 5 ]; then
      echo -e "    ${GRAY}... and $(($pacnew_count - 5)) more${NC}"
    fi
  fi

  if [ "$pacsave_count" -gt 0 ]; then
    print_status "info" "$pacsave_count .pacsave backup file(s) found"
  fi

  if [ "$rpmnew_count" -gt 0 ]; then
    print_status "warn" "$rpmnew_count .rpmnew file(s) need attention"
  fi

  if [ "$pacnew_count" -eq 0 ] && [ "$pacsave_count" -eq 0 ] && [ "$rpmnew_count" -eq 0 ]; then
    print_status "ok" "No pending configuration merges"
  fi

  # Filesystem intergrity
  echo ""
  print_status "info" "Checking filesystem integrity..."

  # Check for filesystem errors in dmesg
  local fs_errors=$(dmesg | grep -i "error\|corrupt\|fail" | grep -i "ext4\|xfs\|btrfs" | wc -l)

  if [ "$fs_errors" -eq 0 ]; then
    print_status "ok" "No filesystem errors detected in kernel log"
  else
    print_status "error" "$fs_errors filesystem error(s) found in kernel log"
    issues=$((issues + 1))

    local count=0
    while IFS= read -r line; do
      if [ "$count" -lt 5 ]; then
        echo -e "    ${RED}▸${NC} $(echo $line | cut -c1-70)..."
      fi
      count=$((count + 1))
    done < <(dmesg | grep -i "error\|corrupt\|fail" | grep -i "ext4\|xfs\|btrfs" | tail -5)
  fi

  # Check disk usage and inodes
  echo ""
  print_status "info" "Checking disk space and inodes..."

  while IFS= read -r line; do
    local mount=$(echo "$line" | awk '{print $6}')
    local usage=$(echo "$line" | awk '{print $5}' | tr -d '%')

    [[ "$usage" =~ ^[0-9]+$ ]] || continue

    if [ "$usage" -gt 95 ]; then
      print_status "error" "$mount is critically full (${usage}%)"
      issues=$((issues + 1))
    fi
  # -P: one line per filesystem; dedupe by device so a shared / and /home count once
  done < <(df -hP / /home 2>/dev/null | tail -n +2 | awk '!seen[$1]++')

  # Check inode usage
  while IFS= read -r line; do
    local mount=$(echo "$line" | awk '{print $6}')
    local iuse=$(echo "$line" | awk '{print $5}' | tr -d '%')

    # btrfs and some other filesystems report "-" for inodes
    [[ "$iuse" =~ ^[0-9]+$ ]] || continue

    if [ "$iuse" -gt 90 ]; then
      print_status "warn" "$mount has ${iuse}% inodes used"
      issues=$((issues + 1))
    fi
  done < <(df -iP / /home 2>/dev/null | tail -n +2 | awk '!seen[$1]++')

  # Boot intergrity
  echo ""
  print_status "info" "Checking boot configuration..."

  if [ -d /boot ]; then
    # Check if boot partition has space
    local boot_free=$(df /boot 2>/dev/null | tail -1 | awk '{print $4}')

    if [ -n "$boot_free" ]; then
      if [ "$boot_free" -lt 10000 ]; then
        print_status "warn" "/boot partition low on space"
        issues=$((issues + 1))
        # Arch keeps one version per kernel package, so there are no old kernels to
        # prune; removing a kernel package automatically could leave nothing bootable
        echo -e "    ${GRAY}Check for kernels you no longer use: pacman -Q | grep -E '^linux(-lts|-zen|-hardened)? '${NC}"
      else
        print_status "ok" "/boot has adequate space"
      fi
    fi

    # Check for bootloader
    if [ -f /boot/grub/grub.cfg ] || [ -f /boot/grub2/grub.cfg ]; then
      print_status "ok" "GRUB bootloader configuration found"
    elif [ -f /boot/loader/loader.conf ] || [ -f /efi/loader/loader.conf ] ||
      { command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; }; then
      print_status "ok" "systemd-boot configuration found"
    elif [ -d /boot/efi/EFI ] || [ -d /boot/EFI ] || [ -d /efi/EFI ]; then
      print_status "ok" "EFI boot configuration found"
    else
      print_status "warn" "Could not verify bootloader configuration"
    fi
  fi

  # System journal
  echo ""
  print_status "info" "Checking systemd journal..."

  if command -v journalctl &>/dev/null; then
    local journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9.]+[A-Z]+' | head -1)

    print_status "info" "Journal size: $journal_size"

    # Check for journal errors
    # -q drops the "-- No entries --" line, which wc -l would count as an error
    local journal_errors=$(journalctl -q -p err -b --no-pager 2>/dev/null | grep -c . || true)

    if [ "$journal_errors" -eq 0 ]; then
      print_status "ok" "No errors in current boot journal"
    else
      print_status "warn" "$journal_errors error(s) logged in current boot"

      echo ""
      echo -e "${YELLOW}Recent errors:${NC}"
      local count=0
      while IFS= read -r line; do
        if [ "$count" -lt 5 ]; then
          echo -e "    ${YELLOW}▸${NC} $(echo $line | cut -c1-70)..."
        fi
        count=$((count + 1))
      done < <(journalctl -q -p err -b --no-pager 2>/dev/null | tail -5)
    fi
  fi

  # Swap space
  echo ""
  print_status "info" "Checking swap configuration..."

  local swap_total=$(free -m | awk '/^Swap:/{print $2}')
  local swap_used=$(free -m | awk '/^Swap:/{print $3}')

  if [ "$swap_total" -eq 0 ]; then
    # Swapless setups are common and deliberate, so this is informational only
    print_status "info" "No swap space configured"
  else
    local swap_percent=$(awk "BEGIN {printf \"%.0f\", ($swap_used/$swap_total)*100}")

    if [ "$swap_used" -eq 0 ]; then
      print_status "ok" "Swap: ${swap_total}MB configured (none used)"
    elif [ "$swap_percent" -lt 50 ]; then
      print_status "ok" "Swap: ${swap_used}MB/${swap_total}MB used (${swap_percent}%)"
    else
      print_status "warn" "Swap: ${swap_used}MB/${swap_total}MB used (${swap_percent}%) - high usage"
    fi
  fi

  # Summary
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

  if [ "$issues" -eq 0 ]; then
    print_status "ok" "System integrity verified - no issues found!"
  else
    echo -e "${RED}Found $issues integrity issue(s)${NC}"

    if [ "$AUTO_FIX" = "true" ]; then
      echo -e "${GREEN}Fixed $fixed issue(s) automatically${NC}"

      if [ "$fixed" -lt "$issues" ]; then
        echo -e "${YELLOW}$(($issues - $fixed)) issue(s) require manual attention${NC}"
      fi
    else
      echo -e "${GRAY}Enable AUTO_FIX in Configuration menu to automatically repair issues${NC}"
    fi
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to main menu...${NC}"
  read -r
}

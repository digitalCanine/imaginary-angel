#!/bin/bash
# Package Management Module

package_manager() {
  while true; do
    print_logo
    draw_box 65 "PACKAGE MANAGEMENT & UPDATES"
    echo ""

    box_line "  ${CYAN}1${NC}) System Update"
    box_line "  ${CYAN}2${NC}) Search Packages"
    box_line "  ${CYAN}3${NC}) List Installed Packages"
    box_line "  ${CYAN}4${NC}) Remove Orphaned Packages"
    box_line "  ${CYAN}5${NC}) Clean Package Cache"
    box_line "  ${CYAN}6${NC}) Check for Outdated Packages"
    box_line "  ${CYAN}7${NC}) Show Package Statistics"
    box_line ""
    box_line "  ${CYAN}0${NC}) Back to Main Menu"
    box_line ""
    draw_box_bottom 65

    echo ""
    echo -e -n "${WHITE}Select option:${NC} "
    read -r choice

    case $choice in
    1) system_update ;;
    2) search_packages ;;
    3) list_packages ;;
    4) remove_orphans ;;
    5) clean_cache ;;
    6) check_outdated ;;
    7) package_stats ;;
    0) return ;;
    *)
      echo -e "${RED}Invalid option${NC}"
      sleep 1
      ;;
    esac
  done
}

system_update() {
  echo ""
  print_status "info" "Updating system packages..."
  echo ""

  if command -v pacman &>/dev/null; then
    print_status "info" "Checking for updates..."
    local updates
    if command -v checkupdates &>/dev/null; then
      updates=$(checkupdates 2>/dev/null | grep -c . || true)
    else
      # No checkupdates: -Syu below syncs and shows its own summary
      updates=-1
    fi

    if [ "$updates" -eq 0 ]; then
      print_status "ok" "System is up to date!"
    else
      [ "$updates" -gt 0 ] && print_status "info" "$updates package(s) can be updated"
      echo ""
      pacman -Syu
    fi

  elif command -v apt-get &>/dev/null; then
    # Debian-based
    print_status "info" "Updating package lists..."
    apt-get update

    echo ""
    print_status "info" "Upgrading packages..."
    apt-get dist-upgrade

  elif command -v dnf &>/dev/null; then
    # Fedora-based
    print_status "info" "Updating system..."
    dnf upgrade -y

  else
    print_status "error" "No supported package manager found"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

search_packages() {
  echo ""
  echo -e -n "${WHITE}Enter package name to search:${NC} "
  read -r pkg

  if [ -z "$pkg" ]; then
    return
  fi

  echo ""
  print_status "info" "Searching for '$pkg'..."
  echo ""

  if command -v pacman &>/dev/null; then
    pacman -Ss "$pkg" | less -R
  elif command -v apt-cache &>/dev/null; then
    apt-cache search "$pkg" | less
  elif command -v dnf &>/dev/null; then
    dnf search "$pkg" | less
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

list_packages() {
  echo ""
  print_status "info" "Installed packages:"
  echo ""

  if command -v pacman &>/dev/null; then
    pacman -Q | less
  elif command -v dpkg &>/dev/null; then
    dpkg -l | less
  elif command -v rpm &>/dev/null; then
    rpm -qa | less
  fi
}

remove_orphans() {
  echo ""
  print_status "info" "Finding orphaned packages..."
  echo ""

  if command -v pacman &>/dev/null; then
    local orphans=$(pacman -Qtdq 2>/dev/null)

    if [ -z "$orphans" ]; then
      print_status "ok" "No orphaned packages found"
      echo ""
      echo -e "${GRAY}Press Enter to return to package menu...${NC}"
      read -r
      return
    fi

    echo "$orphans"
    echo ""
    echo -e -n "${YELLOW}Remove these packages? (y/N):${NC} "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      print_status "info" "Removing orphaned packages..."
      pacman -Rns $orphans || true
      print_status "ok" "Orphaned packages removed"
    fi

  elif command -v apt-get &>/dev/null; then
    print_status "info" "Removing unused packages..."
    apt-get autoremove -y
    print_status "ok" "Cleanup complete"

  else
    print_status "info" "Orphan removal not supported for this package manager"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

clean_cache() {
  echo ""
  print_status "info" "Cleaning package cache..."
  echo ""

  if command -v pacman &>/dev/null; then
    local cache_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')
    print_status "info" "Current cache size: $cache_size"

    echo ""
    if command -v paccache &>/dev/null; then
      echo -e "${YELLOW}This will remove all cached packages except the latest 2 versions${NC}"
    else
      echo -e "${YELLOW}paccache not found (pacman-contrib); falling back to 'pacman -Sc',${NC}"
      echo -e "${YELLOW}which removes cached versions of packages that are no longer installed${NC}"
    fi
    echo -e -n "${WHITE}Continue? (y/N):${NC} "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      if command -v paccache &>/dev/null; then
        paccache -rk2
      else
        pacman -Sc
      fi
      print_status "ok" "Cache cleaned"

      local new_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')
      print_status "info" "New cache size: $new_size"
    fi

  elif command -v apt-get &>/dev/null; then
    local cache_size=$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
    print_status "info" "Current cache size: $cache_size"

    apt-get clean
    print_status "ok" "Cache cleaned"

  else
    print_status "info" "Cache cleaning not available for this package manager"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

check_outdated() {
  echo ""
  print_status "info" "Checking for outdated packages..."
  echo ""

  if command -v pacman &>/dev/null; then
    local outdated
    if command -v checkupdates &>/dev/null; then
      # Syncs into a temp DB: fresh results, no root, system DB untouched
      outdated=$(checkupdates 2>/dev/null || true)
    else
      print_status "warn" "checkupdates not found (pacman-contrib); results reflect the last sync"
      outdated=$(pacman -Qu 2>/dev/null || true)
    fi

    if [ -z "$outdated" ]; then
      print_status "ok" "All packages are up to date!"
    else
      local count=$(echo "$outdated" | wc -l)
      print_status "warn" "$count package(s) can be updated:"
      echo ""
      echo "$outdated"
    fi

  elif command -v apt &>/dev/null; then
    apt list --upgradable 2>/dev/null

  else
    print_status "info" "Check not available for this package manager"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

package_stats() {
  echo ""
  print_status "info" "Package Statistics:"
  echo ""

  if command -v pacman &>/dev/null; then
    local total=$(pacman -Q | wc -l)
    local explicit=$(pacman -Qe | wc -l)
    local deps=$(pacman -Qd | wc -l)
    local orphans=$(pacman -Qtdq 2>/dev/null | wc -l)
    local cache_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')

    echo "  Total packages: $total"
    echo "  Explicitly installed: $explicit"
    echo "  Dependencies: $deps"
    echo "  Orphaned: $orphans"
    echo "  Cache size: $cache_size"

  elif command -v dpkg &>/dev/null; then
    local total=$(dpkg -l | grep "^ii" | wc -l)
    local cache_size=$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}')

    echo "  Total packages: $total"
    echo "  Cache size: $cache_size"

  else
    print_status "info" "Statistics not available for this package manager"
  fi

  echo ""
  echo -e "${GRAY}Press Enter to return to package menu...${NC}"
  read -r
}

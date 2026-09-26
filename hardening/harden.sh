#!/bin/bash
# Imaginary Linux system hardening

set -uo pipefail

HARDEN_VERSION=1

CONFIG_FILE="/etc/imaginary-angel.conf"
STATE_DIR="/var/lib/imaginary-angel/hardening"
MANIFEST="$STATE_DIR/manifest"
BACKUP_DIR="$STATE_DIR/backup"

# LSM order recommended for Arch kernels with AppArmor added
LSM_LIST="landlock,lockdown,yama,integrity,apparmor,bpf"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CHANGES=0
WARNINGS=0
ERRORS=0
REBOOT_NEEDED=false

info() { echo -e "${BLUE}[harden]${NC} $1"; }
ok() { echo -e "${GREEN}[harden]${NC} $1"; }
warn() {
  echo -e "${YELLOW}[harden]${NC} $1"
  WARNINGS=$((WARNINGS + 1))
}
# Prints only; run_step counts the failure once when the step returns non-zero
fail() { echo -e "${RED}[harden]${NC} $1"; }

HEADER="# Managed by imaginary-angel hardening (v${HARDEN_VERSION}).
# This file is rewritten on every run. To override a value, put it in a
# higher-numbered file in the same directory instead of editing this one."

# Settings
load_settings() {
  local vars=(HARDEN_FIREWALL HARDEN_APPARMOR HARDEN_COREDUMPS HARDEN_SSH
    HARDEN_SU_WHEEL HARDEN_STRICT HARDEN_LOCK_MODULES)
  local defaults=(true true true true true false false)
  local -A from_env=()
  local i var

  # Remember what the caller passed so the config file can't override it
  for var in "${vars[@]}"; do
    [ -n "${!var+x}" ] && from_env[$var]="${!var}"
  done

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi

  for i in "${!vars[@]}"; do
    var=${vars[$i]}
    if [ -n "${from_env[$var]+x}" ]; then
      printf -v "$var" '%s' "${from_env[$var]}"
    elif [ -z "${!var:-}" ]; then
      printf -v "$var" '%s' "${defaults[$i]}"
    fi
  done
}

# File helpers
is_managed() { grep -qxF "$1" "$MANIFEST" 2>/dev/null; }

record() {
  is_managed "$1" || echo "$1" >>"$MANIFEST"
}

unrecord() {
  [ -f "$MANIFEST" ] || return 0
  grep -vxF "$1" "$MANIFEST" >"$MANIFEST.tmp" || true
  mv -f "$MANIFEST.tmp" "$MANIFEST"
}

backup() {
  local src=$1 dest="$BACKUP_DIR$1"
  [ -e "$src" ] || return 0
  [ -e "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")" && cp -a "$src" "$dest"
}

# Writes atomically and only counts a change when the content differs.
install_file() {
  local dest=$1 mode=$2 tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp=$(mktemp "${dest}.XXXXXX") || return 1

  if ! {
    echo "$HEADER"
    echo
    cat
  } >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    record "$dest"
    return 0
  fi

  is_managed "$dest" || backup "$dest"
  chmod "$mode" "$tmp" && mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
  record "$dest"
  CHANGES=$((CHANGES + 1))
}

# Remove a file only if this script created it (used when a setting is turned off)
remove_managed() {
  local file=$1
  is_managed "$file" || return 0
  rm -f "$file"
  unrecord "$file"
  CHANGES=$((CHANGES + 1))
  info "Removed $file (setting turned off)"
}

pkg_install() {
  pacman -Q "$1" &>/dev/null && return 0
  info "Installing $1..."
  pacman -S --needed --noconfirm "$1" >/dev/null
}

live() { [ "$IN_CHROOT" = false ]; }

# Hardening
harden_sysctl() {
  info "Kernel and network parameters..."

  install_file /etc/sysctl.d/60-imaginary-hardening.conf 644 <<'EOF' || return 1
# Kernel information leaks
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Memory and exploit mitigations
kernel.randomize_va_space = 2
kernel.kexec_load_disabled = 1
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0

# Filesystem link and file protections
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Reverse path filtering in loose mode (2): safe with VPNs and multiple interfaces
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore ICMP redirects and source-routed packets
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ICMP and TCP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
EOF

  if [ "$HARDEN_STRICT" = true ]; then
    install_file /etc/sysctl.d/61-imaginary-strict.conf 644 <<'EOF' || return 1
# Only root can ptrace (breaks gdb/strace attach for normal users)
kernel.yama.ptrace_scope = 2

# Log packets with impossible source addresses (can be noisy)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF
  else
    remove_managed /etc/sysctl.d/61-imaginary-strict.conf
  fi

  if [ "$HARDEN_LOCK_MODULES" = true ]; then
    install_file /etc/sysctl.d/62-imaginary-lock-modules.conf 644 <<'EOF' || return 1
# No kernel modules can be loaded after boot (servers only: breaks USB
# devices, VPNs and anything else that loads a module on demand)
kernel.modules_disabled = 1
EOF
  else
    remove_managed /etc/sysctl.d/62-imaginary-lock-modules.conf
  fi

  if live; then
    # modules_disabled is one-way until reboot, so never apply it live
    sysctl --system >/dev/null 2>&1 || warn "Some sysctl values could not be applied live (they apply on reboot)"
    if [ "$HARDEN_LOCK_MODULES" = true ]; then
      REBOOT_NEEDED=true
    fi
  fi
  ok "Kernel and network parameters set"
}

harden_modules() {
  info "Blocking rarely used filesystems and network protocols..."

  install_file /etc/modprobe.d/60-imaginary-blacklist.conf 644 <<'EOF' || return 1
# Rare filesystems with a history of kernel bugs
install cramfs /usr/bin/false
install freevxfs /usr/bin/false
install jffs2 /usr/bin/false
install hfs /usr/bin/false
install hfsplus /usr/bin/false

# Rare network protocols with a history of kernel bugs
install dccp /usr/bin/false
install sctp /usr/bin/false
install rds /usr/bin/false
install tipc /usr/bin/false
EOF
  ok "Module blacklist written"
}

harden_coredumps() {
  if [ "$HARDEN_COREDUMPS" != true ]; then
    remove_managed /etc/systemd/coredump.conf.d/60-imaginary.conf
    remove_managed /etc/security/limits.d/60-imaginary-coredump.conf
    return 0
  fi

  info "Disabling core dumps..."
  install_file /etc/systemd/coredump.conf.d/60-imaginary.conf 644 <<'EOF' || return 1
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  install_file /etc/security/limits.d/60-imaginary-coredump.conf 644 <<'EOF' || return 1
* hard core 0
EOF
  ok "Core dumps disabled"
}

harden_ssh() {
  [ "$HARDEN_SSH" = true ] || return 0

  if ! command -v sshd &>/dev/null || [ ! -d /etc/ssh ]; then
    info "OpenSSH not installed, skipping SSH hardening"
    return 0
  fi

  info "Hardening SSH..."
  local dropin=/etc/ssh/sshd_config.d/10-imaginary-hardening.conf
  local existed=false
  [ -f "$dropin" ] && existed=true

  install_file "$dropin" 644 <<'EOF' || return 1
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    warn "sshd_config does not include sshd_config.d/*.conf, so the SSH hardening is not active"
  fi

  # Host keys are generated on first boot
  if compgen -G "/etc/ssh/ssh_host_*_key" >/dev/null; then
    local err
    if ! err=$(sshd -t 2>&1); then
      fail "sshd rejected the new config, rolling back: $err"
      if [ "$existed" = false ]; then
        rm -f "$dropin"
        unrecord "$dropin"
      fi
      return 1
    fi
  fi

  if live && systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || warn "Could not reload sshd; restart it to apply the new config"
  fi
  ok "SSH hardened (root login and empty passwords disabled)"
}

harden_su() {
  [ "$HARDEN_SU_WHEEL" = true ] || return 0

  info "Restricting su to the wheel group..."

  # Without a wheel member, restricting su could leave nobody able to use it
  local members
  members=$(getent group wheel | cut -d: -f4)
  if [ -z "$members" ]; then
    warn "The wheel group has no members, skipping su restriction to avoid a lockout"
    return 0
  fi

  local f
  for f in /etc/pam.d/su /etc/pam.d/su-l; do
    [ -f "$f" ] || continue

    if grep -Eq '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid' "$f"; then
      continue
    elif grep -Eq '^#[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid' "$f"; then
      # Uncomment the line Arch ships instead of appending our own
      backup "$f"
      sed -i -E 's/^#([[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid)/\1/' "$f" || return 1
      CHANGES=$((CHANGES + 1))
    else
      warn "$f has no pam_wheel line to enable; restrict su manually if needed"
    fi
  done
  ok "su restricted to wheel group"
}

harden_permissions() {
  info "Tightening permissions on sensitive paths..."

  chmod 700 /root 2>/dev/null || true

  local path
  for path in /home/*/.ssh; do
    [ -d "$path" ] && chmod 700 "$path"
  done
  for path in /etc/ssh/ssh_host_*_key; do
    [ -f "$path" ] && chmod 600 "$path"
  done
  ok "Permissions tightened"
}

harden_umask() {
  local file=/etc/profile.d/60-imaginary-umask.sh
  if [ "$HARDEN_STRICT" = true ]; then
    info "Setting a stricter default umask..."
    install_file "$file" 644 <<'EOF' || return 1
# New files are not readable by other users (group can still read)
umask 027
EOF
    ok "Default umask set to 027"
  else
    remove_managed "$file"
  fi
}

harden_resolved() {
  [ -f /usr/lib/systemd/systemd-resolved ] || return 0

  info "Configuring DNS-over-TLS for systemd-resolved..."
  local dnssec="# DNSSEC left at the systemd default (strict mode sets it to yes)"
  [ "$HARDEN_STRICT" = true ] && dnssec="DNSSEC=yes"

  install_file /etc/systemd/resolved.conf.d/60-imaginary.conf 644 <<EOF || return 1
[Resolve]
# Use encrypted DNS when the server supports it, fall back otherwise
DNSOverTLS=opportunistic
$dnssec
EOF

  if live; then
    systemctl try-restart systemd-resolved 2>/dev/null || true
  fi
  ok "systemd-resolved configured (only used if resolved is enabled)"
}

harden_firewall() {
  [ "$HARDEN_FIREWALL" = true ] || return 0

  info "Configuring firewall..."

  if live; then
    # Don't replace a firewall the user already set up
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      ok "firewalld is active, leaving it in place"
      return 0
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
      ok "UFW is already active, leaving its rules in place"
      return 0
    fi
  fi

  pkg_install ufw || {
    fail "Could not install ufw"
    return 1
  }

  ufw default deny incoming >/dev/null || return 1
  ufw default allow outgoing >/dev/null || return 1

  # Only open SSH when the server is actually enabled, and rate-limit it
  if systemctl is-enabled --quiet sshd.service 2>/dev/null; then
    ufw limit 22/tcp comment 'SSH' >/dev/null || warn "Could not add the SSH firewall rule"
    info "SSH is enabled, allowed port 22 with rate limiting"
  fi

  if live; then
    ufw --force enable >/dev/null || return 1
  else
    # 'ufw enable' mark it enabled so the new system starts it on boot instead
    sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf || return 1
  fi
  systemctl enable ufw.service >/dev/null 2>&1 || return 1
  CHANGES=$((CHANGES + 1))
  ok "Firewall enabled: deny incoming, allow outgoing"
}

# Add lsm=... to every bootloader config we can find. Returns 1 if none found.
add_lsm_param() {
  local param="lsm=$LSM_LIST" found=false changed=false entry esp

  if [ -f /etc/default/grub ]; then
    found=true
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*lsm=' /etc/default/grub; then
      :
    elif grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' /etc/default/grub; then
      backup /etc/default/grub
      sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $param\"/" /etc/default/grub
      changed=true
      if [ -f /boot/grub/grub.cfg ]; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 ||
          warn "grub-mkconfig failed; run it manually to apply the AppArmor parameter"
      fi
    else
      warn "Could not parse GRUB_CMDLINE_LINUX_DEFAULT; add '$param' manually"
    fi
  fi

  # kernel-install (systemd-boot) regenerates entries from this file on kernel updates
  if [ -f /etc/kernel/cmdline ]; then
    found=true
    if ! grep -q 'lsm=' /etc/kernel/cmdline; then
      backup /etc/kernel/cmdline
      sed -i "1s/\$/ $param/" /etc/kernel/cmdline
      changed=true
    fi
  fi

  # Existing systemd-boot entries
  for esp in /boot /efi /boot/efi; do
    for entry in "$esp"/loader/entries/*.conf; do
      [ -f "$entry" ] || continue
      found=true
      grep -q '^options.*lsm=' "$entry" && continue
      backup "$entry"
      if grep -q '^options' "$entry"; then
        sed -i "s/^options.*/& $param/" "$entry"
      else
        echo "options $param" >>"$entry"
      fi
      changed=true
    done
  done

  if [ "$changed" = true ]; then
    CHANGES=$((CHANGES + 1))
    REBOOT_NEEDED=true
  fi
  [ "$found" = true ]
}

harden_apparmor() {
  [ "$HARDEN_APPARMOR" = true ] || return 0

  info "Enabling AppArmor..."
  pkg_install apparmor || {
    fail "Could not install apparmor"
    return 1
  }
  systemctl enable apparmor.service >/dev/null 2>&1 || return 1

  if ! add_lsm_param; then
    warn "No GRUB or systemd-boot config found; add 'lsm=$LSM_LIST' to your kernel command line"
    return 0
  fi

  if live && [ "$REBOOT_NEEDED" = true ]; then
    ok "AppArmor enabled (active after reboot)"
  else
    ok "AppArmor enabled"
  fi
}

# Main
run_step() {
  if ! "$1"; then
    fail "Step '$1' failed"
    ERRORS=$((ERRORS + 1))
  fi
}

main() {
  if [ "$EUID" -ne 0 ]; then
    echo "harden.sh must be run as root" >&2
    exit 1
  fi

  load_settings

  if systemd-detect-virt --chroot &>/dev/null; then
    IN_CHROOT=true
  else
    IN_CHROOT=false
  fi

  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  touch "$MANIFEST"

  info "Imaginary hardening v${HARDEN_VERSION} ($([ "$IN_CHROOT" = true ] && echo "chroot" || echo "live system"))"
  [ "$HARDEN_STRICT" = true ] && info "Strict mode is on"
  echo ""

  run_step harden_sysctl
  run_step harden_modules
  run_step harden_coredumps
  run_step harden_ssh
  run_step harden_su
  run_step harden_permissions
  run_step harden_umask
  run_step harden_resolved
  run_step harden_firewall
  run_step harden_apparmor

  {
    echo "version=$HARDEN_VERSION"
    echo "applied=$(date -Iseconds)"
    echo "strict=$HARDEN_STRICT"
  } >"$STATE_DIR/state"

  echo ""
  info "Done: $CHANGES change(s), $WARNINGS warning(s), $ERRORS error(s)"
  info "Files written are listed in $MANIFEST; originals are in $BACKUP_DIR"
  if [ "$REBOOT_NEEDED" = true ] && live; then
    warn "Reboot to finish applying the changes"
  fi

  [ "$ERRORS" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
  main "$@"
fi

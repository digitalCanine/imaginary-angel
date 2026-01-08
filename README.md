# Imaginary Angel

`The system stands, quietly.`

**System Guardian for Imaginary Linux**

Imaginary Angel is a comprehensive system security and maintenance tool designed for Imaginary Linux. It provides automated system health checks, security auditing, network threat detection, process analysis, and system recovery capabilities.

![Version](https://img.shields.io/badge/version-1.0-purple)
![License](https://img.shields.io/badge/license-MIT-blue)
![Arch](https://img.shields.io/badge/arch-linux-blue)

## Features

### System Health & Auto-Repair

- Real-time CPU, memory, and disk monitoring
- Automatic cleanup of temporary files and package caches
- Service health monitoring and recovery
- Configurable alert thresholds
- Optional automatic fixes for common issues

### Security Audit & Hardening

- SSH security configuration checks
- Firewall status verification
- User privilege auditing
- Password security analysis
- World-writable file detection
- SUID binary analysis
- MAC system (AppArmor/SELinux) verification
- Failed login attempt monitoring

### Network Threat Detection

- Suspicious connection monitoring
- Port scan detection
- DDoS attempt identification
- ARP spoofing detection
- DNS configuration verification
- Network interface analysis
- Packet filtering rule inspection

### Process Analysis & Cleanup

- Resource-intensive process identification
- Suspicious process detection
- Zombie process cleanup
- Deleted binary detection
- Process running from temporary directories

### System Integrity & Recovery

- Package database integrity verification
- Critical system file checks
- Configuration file merge detection
- Filesystem integrity analysis
- Boot configuration verification
- Systemd journal analysis

### Package Management

- System updates
- Package search and installation
- Orphaned package cleanup
- Package cache management
- Outdated package detection
- Package statistics

### Service Management

- Active service monitoring
- Failed service restart
- Unnecessary service identification
- Service resource usage analysis
- Boot time analysis

### System Reports & Diagnostics

- Comprehensive system reports
- System log viewing (journalctl)
- Failed login attempt tracking
- Kernel message analysis
- Hardware information
- Performance reports
- Security summaries

## Installation

### From Imaginary Linux Repository (Recommended)

Add this to your `pacman.conf`

```
[imaginary]
SigLevel = Optional TrustAll
Server = https://github.com/digitalcanine/imaginary-repo/releases/download/packages
```

```bash
sudo pacman -S imaginary-angel
```

### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/digitalcanine/imaginary-angel.git
cd imaginary-angel
```

2. Install dependencies:

```bash
sudo pacman -S bash coreutils util-linux procps-ng net-tools iproute2 systemd grep sed awk bc
```

3. Install the package:

```bash
makepkg -si
```

## Dependencies

### Required

- `bash` - Shell interpreter
- `coreutils` - Core utilities (cat, chmod, etc.)
- `util-linux` - System utilities (lsblk, findmnt, etc.)
- `procps-ng` - Process utilities (ps, top, free)
- `net-tools` - Network tools (arp, netstat)
- `iproute2` - IP routing utilities (ip, ss)
- `systemd` - System and service manager
- `grep` - Pattern matching
- `sed` - Stream editor
- `awk` - Text processing
- `bc` - Calculator for floating point math

### Optional (for enhanced features)

- `ufw` - Uncomplicated Firewall
- `nethogs` - Network bandwidth monitor
- `smartmontools` - Disk health monitoring (smartctl)
- `lm_sensors` - Hardware temperature sensors
- `sysstat` - Performance monitoring (iostat, mpstat)
- `paccache` - Pacman cache cleanup utility
- `apparmor` - Mandatory Access Control
- `reflector` - Mirror list optimization

## Usage

### Running Imaginary Angel

```bash
sudo imaginary-angel
```

The tool requires root privileges to perform system checks and repairs.

### Main Menu Options

1. **System Health & Auto-Repair** - Monitor system resources and fix common issues
2. **Security Audit & Hardening** - Scan for security vulnerabilities
3. **Network Threat Detection** - Analyze network traffic and connections
4. **Process Analysis & Cleanup** - Identify and clean suspicious processes
5. **System Integrity & Recovery** - Verify system file integrity
6. **Package Management & Updates** - Manage system packages
7. **Service Management & Optimization** - Manage systemd services
8. **System Reports & Diagnostics** - Generate comprehensive reports
9. **Configuration** - Adjust settings and thresholds

### Configuration

Edit `/etc/imaginary-angel.conf` to customize behavior:

```bash
# Imaginary Angel Configuration
AUTO_FIX=false                    # Enable automatic fixes
LOG_RETENTION_DAYS=30             # Log retention period
ALERT_THRESHOLD_CPU=80            # CPU alert threshold (%)
ALERT_THRESHOLD_MEM=85            # Memory alert threshold (%)
ALERT_THRESHOLD_DISK=90           # Disk alert threshold (%)
SUSPICIOUS_PROCESS_CHECK=true    # Enable process monitoring
NETWORK_ANOMALY_DETECTION=true   # Enable network monitoring
```

### Enabling Auto-Fix

To enable automatic repairs:

1. Run imaginary-angel: `sudo imaginary-angel`
2. Navigate to Configuration menu (option 9)
3. Toggle Auto-Fix (option 1)

When enabled, the tool will automatically attempt to fix detected issues.

## Examples

### Quick System Health Check

```bash
sudo imaginary-angel
# Select option 1 (System Health & Auto-Repair)
```

### Security Audit

```bash
sudo imaginary-angel
# Select option 2 (Security Audit & Hardening)
```

### Generate Full System Report

```bash
sudo imaginary-angel
# Select option 8 (System Reports & Diagnostics)
# Select option 1 (Generate Full System Report)
```

Reports are saved to `/var/log/imaginary-angel/`

## Logs and Data

- **Log Directory**: `/var/log/imaginary-angel/`
- **Cache Directory**: `/var/cache/imaginary-angel/`
- **Configuration**: `/etc/imaginary-angel.conf`

## Security Considerations

Imaginary Angel requires root privileges to:

- Read system configuration files
- Monitor processes and network connections
- Apply security fixes
- Manage services and packages

Always review changes before enabling AUTO_FIX mode.

## Troubleshooting

### Module Loading Errors

Ensure the `modules` directory is in the same location as the main script:

```bash
/usr/bin/imaginary-angel
/usr/share/imaginary-angel/modules/
```

### Permission Errors

Make sure you're running with sudo:

```bash
sudo imaginary-angel
```

### Missing Dependencies

Install all required packages:

```bash
sudo pacman -S bash coreutils util-linux procps-ng net-tools iproute2 systemd grep sed awk bc
```

### Development

The project structure:

```
imaginary-angel/
├── angel                    # Main script
├── modules/                 # Feature modules
│   ├── health.sh
│   ├── security.sh
│   ├── network.sh
│   ├── process.sh
│   ├── integrity.sh
│   ├── packages.sh
│   ├── services.sh
│   └── reports.sh
└── README.md
```

## Version History

### v1.0 (Shamshel) - Current

- Initial release
- System health monitoring
- Security auditing
- Network threat detection
- Process analysis
- System integrity checks
- Package management
- Service management
- System reporting

## License

MIT License - See LICENSE file for details

## Author

Created for Imaginary Linux by digitalcanine

## Links

- **GitHub**: <https://github.com/digitalcanine/imaginary-angel>
- **Imaginary Linux**: <https://github.com/digitalcanine/imaginary-linux>
- **Issues**: <https://github.com/digitalcanine/imaginary-angel/issue>

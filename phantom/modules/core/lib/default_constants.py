"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Default Constants - Phantom-WG için merkezi varsayılan değerler
    ========================================================================

    Bu modül, Phantom-WG uygulaması genelinde kullanılan tüm varsayılan
    yapılandırma değerlerini içerir. Bu sabitler, yapılandırma dosyaları veya
    kullanıcı ayarları tarafından geçersiz kılınabilecek fabrika varsayılanlarını
    temsil eder.

    İçerik:
        - Ağ yapılandırma varsayılanları (subnet, port, interface)
        - DNS sunucu varsayılanları (birincil, ikincil, yedek)
        - Operasyonel varsayılanlar (log satırları, sayfalama boyutları)
        - IP adresi yapılandırma değerleri (CIDR notasyonları)

    Kullanım:
        Bu sabitler doğrudan import edilerek kullanılabilir veya yapılandırma
        sistemi tarafından varsayılan değerler olarak referans alınabilir.

    Not:
        Bu dosya "orphan" durumda tutulmuştur - henüz hiçbir modül tarafından
        import edilmemektedir. Migration süreci tamamlandığında, bu sabitler
        ilgili modüllerdeki yerel tanımların yerini alacaktır.

EN: Default Constants - Centralized default values for Phantom-WG
    ====================================================================

    This module contains all default configuration values used across the
    Phantom-WG application. These constants represent factory defaults
    that can be overridden by configuration files or user settings.

    Contents:
        - Network configuration defaults (subnet, port, interface)
        - DNS server defaults (primary, secondary, fallback)
        - Operational defaults (log lines, pagination sizes)
        - IP address configuration values (CIDR notations)

    Usage:
        These constants can be directly imported for use or referenced as
        default values by the configuration system.

    Note:
        This file is kept in "orphan" state - not yet imported by any module.
        Once migration is complete, these constants will replace local
        definitions in respective modules.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
"""

# =============================================================================
# NETWORK DEFAULTS
# =============================================================================

# WireGuard Network Configuration
DEFAULT_WG_NETWORK = "10.8.0.0/24"
DEFAULT_WG_PORT = 51820
DEFAULT_WG_INTERFACE = "wg_main"

# IP Address Configuration
DEFAULT_HOST_CIDR = "/32"
DEFAULT_CLIENT_CIDR = "/24"

# Connection Settings
DEFAULT_KEEPALIVE = 25
DEFAULT_MTU = 1420

# Network Services
DEFAULT_SSH_PORT = "22"

# =============================================================================
# DNS DEFAULTS
# =============================================================================

DEFAULT_DNS_PRIMARY = "8.8.8.8"
DEFAULT_DNS_SECONDARY = "1.1.1.1"
DEFAULT_DNS_FALLBACK = "8.8.4.4"

# =============================================================================
# OPERATIONAL DEFAULTS
# =============================================================================

# Logging
DEFAULT_LOG_LINES = 50

# Pagination
DEFAULT_PAGE_SIZE = 20
DEFAULT_LATEST_COUNT = 5

# =============================================================================
# FILE SYSTEM & PATHS
# =============================================================================

# State and Backup Files
GHOST_STATE_FILENAME = "ghost-state.json"
BACKUPS_DIR = "backups"

# =============================================================================
# DATABASE
# =============================================================================

# Table Names
CLIENTS_TABLE_NAME = "clients"
IP_ASSIGNMENTS_TABLE_NAME = "ip_assignments"

# =============================================================================
# VALIDATION & SECURITY
# =============================================================================

# Key and Name Constraints
WG_KEY_LENGTH = 44
MAX_CLIENT_NAME_LENGTH = 50

# File Permissions
WG_CONFIG_PERMISSIONS = 0o600

# Configurable Settings
ACTIVE_CONNECTION_THRESHOLD = 180 # seconds
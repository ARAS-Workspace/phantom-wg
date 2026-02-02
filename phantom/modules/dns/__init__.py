"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG DNS Modülü
    ============================
    
    WireGuard VPN için DNS sunucu yönetimi modülü. Bu modül, sistem
    genelindeki DNS ayarlarını yönetir ve tüm istemciler için geçerli
    DNS sunucularını yapılandırır.
    
    Özellikler:
        - Birincil ve ikincil DNS sunucu yapılandırması
        - DNS sunucu bağlantı testi
        - Sistem genelinde DNS değişiklikleri
        - Otomatik yapılandırma yenileme

EN: Phantom-WG DNS Module
    ============================
    
    DNS server management module for WireGuard VPN. This module manages
    system-wide DNS settings and configures valid DNS servers for all
    clients.
    
    Features:
        - Primary and secondary DNS server configuration
        - DNS server connectivity testing
        - System-wide DNS changes
        - Automatic configuration refresh

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .module import DnsModule

__all__ = ["DnsModule"]

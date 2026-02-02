"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Ghost Mode Modülü
    ===================================
    
    Sansüre dayanıklı WireGuard bağlantıları sağlayan modül. Bu modül,
    wstunnel kullanarak WireGuard trafiğini WebSocket üzerinden tüneller
    ve SSL/TLS şifrelemesi ile gizler. DPI (Deep Packet Inspection) ve
    sansür sistemlerini atlatmak için tasarlanmıştır.
    
    Özellikler:
        - WebSocket üzerinden WireGuard tünelleme
        - Otomatik SSL sertifikası yönetimi (Let's Encrypt)
        - Güvenlik duvarı kuralları yönetimi
        - Otomatik yeniden bağlanma ve dayanıklılık

EN: Phantom-WG Ghost Mode Module
    ===================================
    
    Module providing censorship-resistant WireGuard connections. This module
    tunnels WireGuard traffic over WebSocket using wstunnel and hides it
    with SSL/TLS encryption. Designed to bypass DPI (Deep Packet Inspection)
    and censorship systems.
    
    Features:
        - WireGuard tunneling over WebSocket
        - Automatic SSL certificate management (Let's Encrypt)
        - Firewall rules management
        - Automatic reconnection and resilience

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .module import GhostModule

__all__ = ["GhostModule"]

"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Ana Paketi
    ============================
    
    Basit ve güçlü WireGuard VPN yönetim sistemi.
    
    Ana Bileşenler:
        - api/: API katmanı
        - bin/: Giriş noktaları (CLI ve Terminal Arayüzü)
        - cli/: Etkileşimli kullanıcı arayüzü
        - modules/: Plugin tabanlı özellik modülleri
        - scripts/: Sistem yardımcı scriptleri

EN: Phantom-WG Main Package
    ==============================
    
    Simple and powerful WireGuard VPN management system.
    
    Main Components:
        - api/: API layer
        - bin/: Entry points (CLI and Terminal Interface)
        - cli/: Interactive user interface
        - modules/: Plugin-based feature modules
        - scripts/: System utility scripts

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

__version__ = "core-v1"
__author__ = "Rıza Emre ARAS"
__copyright__ = "© 2025 Rıza Emre ARAS - All Rights Reserved"
__all__ = ["__version__", "__author__", "__copyright__"]

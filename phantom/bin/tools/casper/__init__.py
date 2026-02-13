"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Casper - Ghost Mode Configuration Exporter
    =========================================================================

    Casper, Ghost Mode aktifken kullanıcıların WireGuard client
    konfigürasyonlarını görüntülemelerine olanak sağlayan basit bir araçtır.
    
    Ana Özellikler:
        - ghost-state.json dosyasından Ghost Mode durumunu kontrol eder
        - Phantom API üzerinden client verilerini alır (Core/export_client)
        - Ghost API'den wstunnel komutunu alır (Ghost/status)
        - AllowedIPs'i sunucu IP'sini hariç tutacak şekilde hesaplar
    
    Kullanım:
        phantom-casper [kullanıcı_adı]
    
    Çıktı Formatı:
        # Wstunnel Command (for run client side): [komut]
        [WireGuard konfigürasyonu]
        
EN: Phantom-WG Casper - Ghost Mode Configuration Exporter
    ====================================================================
    
    Casper is a simple tool that allows users to view their WireGuard
    client configurations when Ghost Mode is active.
    
    Key Features:
        - Checks Ghost Mode status from ghost-state.json file
        - Retrieves client data via Phantom API (Core/export_client)
        - Fetches wstunnel command from Ghost API (Ghost/status)
        - Calculates AllowedIPs to exclude server IP
    
    Usage:
        phantom-casper [username]
    
    Output Format:
        # Wstunnel Command (for run client side): [command]
        [WireGuard configuration]

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from .core import CasperService

__all__ = [
    "CasperService",
]

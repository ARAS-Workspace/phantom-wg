"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Casper iOS - Ghost Mode iOS Configuration Exporter
    =========================================================================

    Casper iOS, Ghost Mode aktifken kullanıcıların Phantom-WG iOS uygulaması
    için JSON formatında konfigürasyon üretir.

    Ana Özellikler:
        - ghost-state.json dosyasından Ghost Mode durumunu kontrol eder
        - Phantom API üzerinden client verilerini alır (Core/export_client)
        - AllowedIPs'i sunucu IPv4 IP'sini hariç tutacak şekilde hesaplar
        - iOS uyumlu JSON çıktısı üretir

    Kullanım:
        phantom-casper-ios [kullanıcı_adı]     # iOS JSON konfigürasyonunu göster

    Çıktı Formatı:
        Phantom-WG iOS uygulamasının beklediği JSON yapısı
        (interface, peer, wstunnel bilgileri dahil)

EN: Phantom-WG Casper iOS - Ghost Mode iOS Configuration Exporter
    ====================================================================

    Casper iOS generates JSON-format configurations for the Phantom-WG iOS
    application when Ghost Mode is active.

    Key Features:
        - Checks Ghost Mode status from ghost-state.json file
        - Retrieves client data via Phantom API (Core/export_client)
        - Calculates AllowedIPs to exclude server IPv4 IP
        - Produces iOS-compatible JSON output

    Usage:
        phantom-casper-ios [username]     # Show iOS JSON configuration

    Output Format:
        JSON structure expected by Phantom-WG iOS application
        (includes interface, peer, and wstunnel information)

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from .core import CasperIOSService

__all__ = [
    "CasperIOSService",
]

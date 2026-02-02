"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Multihop Modülü
    =================================
    
    Harici VPN sağlayıcılar üzerinden çoklu atlama (multihop) yönlendirmesi
    sağlayan modül. Bu modül, istemci trafiğini harici bir VPN çıkış noktası
    üzerinden yönlendirirken, WireGuard eşler arası (peer-to-peer) erişimi
    korur.
    
    Kullanıcı Akışı:
        Client → Phantom-WG → Exit Node (VPN Provider) → Internet
        
        - Client: WireGuard istemcisi (telefon, laptop, vb.)
        - Phantom-WG: Multihop yönlendirme yapan ana sunucu
        - Exit Node: Harici VPN sağlayıcı (Mullvad, IVPN, vb.)
        - Internet: Son hedef
    
    Özellikler:
        - Harici VPN yapılandırmalarını içe aktarma
        - Çoklu atlama yönlendirmesini etkinleştirme/devre dışı bırakma
        - Otomatik handshake izleme
        - VPN bağlantı durumu testleri
        - Oturum günlüğü ve gerçek zamanlı izleme

EN: Phantom-WG Multihop Module
    =================================
    
    Module providing multihop routing through external VPN providers.
    This module routes client traffic through an external VPN exit node
    while maintaining WireGuard peer-to-peer access.
    
    User Flow:
        Client → Phantom-WG → Exit Node (VPN Provider) → Internet
        
        - Client: WireGuard client (phone, laptop, etc.)
        - Phantom-WG: Main server performing multihop routing
        - Exit Node: External VPN provider (Mullvad, IVPN, etc.)
        - Internet: Final destination
    
    Features:
        - Import external VPN configurations
        - Enable/disable multihop routing
        - Automatic handshake monitoring
        - VPN connection status tests
        - Session logging and real-time monitoring

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .module import MultihopModule

__all__ = ["MultihopModule"]

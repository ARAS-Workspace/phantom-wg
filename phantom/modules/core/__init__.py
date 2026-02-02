"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Core Modülü
    =============================
    
    Sistemin kalbi olan bu modül, WireGuard VPN'in tüm temel işlevlerini yönetir.
    Modüler mimari ile 7 işlevsel olarak özelleştirilmiş manager kullanır.
    
    Modül Yapısı:
        - module.py: Ana orchestration katmanı (14 API endpoint)
        - lib/: Managers
            • data_store.py: TinyDB ve IP yönetimi
            • key_generator.py: Kriptografik anahtar üretimi
            • common_tools.py: Ortak yardımcı araçlar
            • client_handler.py: İstemci yaşam döngüsü
            • service_monitor.py: Servis sağlık takibi
            • config_keeper.py: Yapılandırma yönetimi
            • network_admin.py: Ağ ve subnet işlemleri
            
    Özellikler:
        - Dinamik istemci ekleme (restart gerektirmez)
        - Otomatik IP tahsisi ve yönetimi
        - Subnet değişikliği ve IP yeniden haritalama
        - Güvenli anahtar üretimi
        - Servis sağlık monitörü
        - Tweak ayarları ile davranış kontrolü

EN: Phantom-WG Core Module
    =============================
    
    The heart of the system, this module manages all core WireGuard VPN functionality.
    Uses modular architecture with 7 functionally specialized managers.
    
    Module Structure:
        - module.py: Main orchestration layer (14 API endpoints)
        - lib/: Managers
            • data_store.py: TinyDB and IP management
            • key_generator.py: Cryptographic key generation
            • common_tools.py: Common utilities
            • client_handler.py: Client lifecycle
            • service_monitor.py: Service health monitoring
            • config_keeper.py: Configuration management
            • network_admin.py: Network and subnet operations
            
    Features:
        - Dynamic client addition (no restart required)
        - Automatic IP allocation and management
        - Subnet changes and IP remapping
        - Secure key generation
        - Service health monitor
        - Behavior control with tweak settings

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .module import CoreModule

__all__ = ["CoreModule"]

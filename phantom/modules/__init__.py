"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Modül Sistemi
    ================================
    
    Phantom-WG'nin plugin tabanlı modül mimarisi. Tüm modüller
    BaseModule sınıfından türetilir ve dinamik olarak yüklenir. Her modül
    belirli bir işlevsellik alanına odaklanır ve API üzerinden erişilebilir.
    
    Modül Hiyerarşisi:
        base.py          → Tüm modüllerin türediği temel sınıf
        ├── core/        → WireGuard yönetimi ve sistem çekirdeği
        ├── dns/         → DNS yapılandırma ve yönetimi
        ├── ghost/       → Sansür direnci ve WebSocket tünelleme
        └── multihop/    → VPN zincirleme ve çıkış noktası (exit node) yönetimi
    
    Modül Yaşam Döngüsü:
        1. API, modül dizinini tarar ve __all__ listesindeki modülleri yükler
        2. Her modül BaseModule'den türetilir ve 3 soyut metodu uygular
        3. PhantomAPI ile modüller otomatik keşfedilir
        4. execute_action() metodu ile modül eylemleri çalıştırılır
    
    Modüller Arası Bağımlılıklar:
        - DNS modülü → Core modülün public API'lerini kullanır
        - Ghost modülü → Core modülün firewall yönetim fonksiyonlarını kullanır
        - Multihop modülü → Core modülün ağ yapılandırma fonksiyonlarını kullanır
        - Tüm modüller → BaseModule'ün utility metodlarını kullanır

EN: Phantom-WG Module System
    ===============================
    
    Phantom-WG's plugin-based module architecture. All modules inherit
    from BaseModule class and are dynamically loaded. Each module focuses on
    a specific functionality area and is accessible through the API.
    
    Module Hierarchy:
        base.py          → Base class that all modules inherit from
        ├── core/        → WireGuard management and system core
        ├── dns/         → DNS configuration and management
        ├── ghost/       → Censorship resistance and WebSocket tunneling
        └── multihop/    → VPN chaining and exit node management
    
    Module Lifecycle:
        1. API scans module directory and loads modules from __all__ list
        2. Each module inherits from BaseModule and implements 3 abstract methods
        3. Modules are auto-discovered via PhantomAPI
        4. Module actions are executed through execute_action() method
    
    Inter-Module Dependencies:
        - DNS module → Uses Core module's public APIs
        - Ghost module → Uses Core module's firewall management functions
        - Multihop module → Uses Core module's network configuration functions
        - All modules → Use BaseModule's utility methods

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

__all__ = ["core", "dns", "ghost", "multihop"]

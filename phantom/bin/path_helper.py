"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Giriş Noktaları için Path Kurulum Yardımcısı
    ===========================================================
    
    Bu modül, phantom modülü henüz Python path'inde olmadığında oluşan
    import sorunlarını önlemek için bin dizinine yerleştirilmiştir.
    
    Ana İşlevler:
        - Geliştirme ve üretim ortamlarını otomatik tespit
        - Python sys.path'e uygun dizinleri ekleme
        - phantom modülünün import edilebilmesini sağlama
    
    Ortam Tespiti:
        - Geliştirme: Proje kök dizinini sys.path'e ekler
        - Üretim: /opt/phantom-wg dizinini sys.path'e ekler
    
    Kullanım:
        from path_helper import setup_phantom_path
        setup_phantom_path()
        from phantom.api.core import PhantomAPI  # Artık çalışır

EN: Path Setup Helper for Phantom-WG Entry Points
    ==================================================
    
    This module is placed in the bin directory to avoid import issues
    when the phantom module is not yet in the Python path.
    
    Key Functions:
        - Automatic detection of development and production environments
        - Adding appropriate directories to Python sys.path
        - Enabling import of the phantom module
    
    Environment Detection:
        - Development: Adds project root directory to sys.path
        - Production: Adds /opt/phantom-wg to sys.path
    
    Usage:
        from path_helper import setup_phantom_path
        setup_phantom_path()
        from phantom.api.core import PhantomAPI  # Now works

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import sys
from pathlib import Path


def setup_phantom_path():
    """
    TR: Phantom modülü import'ları için Python path kurulumu yapar.
    
        Bu fonksiyon, geliştirme veya üretim ortamında çalışıp çalışmadığımızı
        tespit eder ve sys.path'e uygun dizini ekler. Bu sayede phantom modülü
        ve alt modülleri sorunsuz bir şekilde import edilebilir.
        
        Tespit Mantığı:
            1. Mevcut dosyanın konumunu belirle (phantom/bin/ içinde olmalı)
            2. Geliştirme ortamı kontrolü: üst dizinde 'phantom' klasörü var mı?
            3. Varsa geliştirme ortamı, proje kökünü path'e ekle
            4. Yoksa üretim ortamı, /opt/phantom-wg'ı path'e ekle
    
    EN: Setup Python path for phantom module imports.
    
        This function detects whether we're running in development or production
        environment and adds the appropriate directory to sys.path. This allows
        the phantom module and its submodules to be imported without issues.
        
        Detection Logic:
            1. Determine current file location (should be in phantom/bin/)
            2. Check for development: is there a 'phantom' folder in parent?
            3. If yes, development environment, add project root to path
            4. If no, production environment, add /opt/phantom-wg to path
    """
    # Get the path to the current file (should be in phantom/bin/)
    current_file = Path(__file__).resolve()
    bin_dir = current_file.parent

    # Check if we're running from development environment
    # In dev: phantom/bin/path_helper.py -> go up to find phantom module
    potential_dev_root = bin_dir.parent.parent
    if (potential_dev_root / "phantom").exists():
        # Development: Add project root to path
        sys.path.insert(0, str(potential_dev_root))
    else:
        # Production: Add installation directory to path
        install_dir = Path("/opt/phantom-wg")
        if install_dir.exists():
            sys.path.insert(0, str(install_dir))

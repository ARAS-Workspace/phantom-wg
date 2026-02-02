"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG API Paketi
    ============================
    
    Bu paket, Phantom-WG sisteminin tüm API işlevselliğini sağlar.
    Modüler bir yapıda tasarlanmış olup, yanıt formatları, hata yönetimi
    ve girdi doğrulama katmanlarını içerir.
    
    Paket Bileşenleri:
        - APIResponse: Standart API yanıt formatı sınıfı
        - Exceptions: Özelleştirilmiş hata sınıfları hiyerarşisi
        - Validators: Girdi doğrulama sınıfları
        - Core: Ana API motoru (PhantomAPI)
    
    Kullanım Akışı:
        1. CLI veya programatik erişim ile API çağrısı yapılır
        2. PhantomAPI, ilgili modülü ve eylemi bulur
        3. Validators ile girdi parametreleri doğrulanır
        4. Modül eylemi çalıştırılır
        5. Sonuç APIResponse formatında döndürülür
        6. Hatalar özel exception sınıfları ile yönetilir
    
    Import Örneği:
        from phantom.api import PhantomAPI, APIResponse
        from phantom.api import ClientValidator, NetworkValidator
        from phantom.api import ClientExistsError, ValidationError

EN: Phantom-WG API Package
    ============================
    
    This package provides all API functionality for the Phantom-WG
    system. Designed with a modular architecture, it includes response
    formats, error management, and input validation layers.
    
    Package Components:
        - APIResponse: Standard API response format class
        - Exceptions: Custom exception class hierarchy
        - Validators: Input validation classes
        - Core: Main API engine (PhantomAPI)
    
    Usage Flow:
        1. API call made via CLI or programmatic access
        2. PhantomAPI finds the relevant module and action
        3. Input parameters validated with Validators
        4. Module action is executed
        5. Result returned in APIResponse format
        6. Errors managed with custom exception classes
    
    Import Example:
        from phantom.api import PhantomAPI, APIResponse
        from phantom.api import ClientValidator, NetworkValidator
        from phantom.api import ClientExistsError, ValidationError

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .response import APIResponse
from .exceptions import (
    PhantomException,
    ClientExistsError,
    ClientNotFoundError,
    ServiceNotRunningError,
    ValidationError,
    PhantomModuleNotFoundError,
    ActionNotFoundError,
    ConfigurationError
)
from .validators import (
    Validator,
    ClientValidator,
    NetworkValidator,
    DNSValidator,
    FileValidator,
    ConfigValidator
)

__all__ = [
    "APIResponse",
    "PhantomException",
    "ClientExistsError",
    "ClientNotFoundError",
    "ServiceNotRunningError",
    "ValidationError",
    "PhantomModuleNotFoundError",
    "ActionNotFoundError",
    "ConfigurationError",
    "Validator",
    "ClientValidator",
    "NetworkValidator",
    "DNSValidator",
    "FileValidator",
    "ConfigValidator"
]

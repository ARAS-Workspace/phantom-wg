"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG API için Özel İstisnalar
    ==========================================
    
    Bu modül, Phantom-WG sisteminde kullanılan tüm özel hata sınıflarını
    tanımlar. Hiyerarşik bir yapı kullanarak, hatalar kategorilere ayrılmıştır:
    
    - Yapılandırma Hataları: Sistem konfigürasyonu ile ilgili hatalar
    - İstemci Hataları: WireGuard istemci yönetimi hataları
    - Servis Hataları: Sistem servisleri ile ilgili hatalar
    - Ağ Hataları: Ağ yapılandırması ve IP tahsis hataları
    - Modül Hataları: Dinamik modül yükleme ve çalıştırma hataları
    - Doğrulama Hataları: Girdi validasyonu hataları
    - İzin Hataları: Yetkilendirme ve erişim kontrol hataları
    - Ghost Mode Hataları: Sansür direnci özelliği hataları
    - Multihop Hataları: VPN zincirleme özelliği hataları
    
    Her hata sınıfı:
        - Benzersiz bir hata kodu (code) içerir
        - HTTP durum kodu (status_code) belirtir
        - İsteğe bağlı ek veri (data) taşıyabilir
        - Standart API yanıt formatına dönüştürülebilir

EN: Custom Exceptions for Phantom-WG API
    ===========================================
    
    This module defines all custom exception classes used in the Phantom-WG
    system. Using a hierarchical structure, errors are categorized into:
    
    - Configuration Errors: System configuration related errors
    - Client Errors: WireGuard client management errors
    - Service Errors: System service related errors
    - Network Errors: Network configuration and IP allocation errors
    - Module Errors: Dynamic module loading and execution errors
    - Validation Errors: Input validation errors
    - Permission Errors: Authorization and access control errors
    - Ghost Mode Errors: Censorship resistance feature errors
    - Multihop Errors: VPN chaining feature errors
    
    Each exception class:
        - Contains a unique error code
        - Specifies an HTTP status code
        - Can carry optional additional data
        - Can be converted to standard API response format

Exception Hierarchy:
    PhantomException (Base)
    ├── ConfigurationError
    │   └── ConfigNotFoundError
    ├── ClientError
    │   ├── ClientExistsError
    │   ├── ClientNotFoundError
    │   └── InvalidClientNameError
    ├── ServiceError
    │   ├── ServiceNotRunningError
    │   └── ServiceOperationError
    ├── NetworkError
    │   ├── IPAllocationError
    │   └── PortInUseError
    ├── ModuleError
    │   ├── PhantomModuleNotFoundError
    │   └── ActionNotFoundError
    ├── ValidationError
    │   ├── MissingParameterError
    │   └── InvalidParameterError
    ├── PhantomPermissionError
    │   └── InsufficientPrivilegesError
    ├── GhostModeError
    │   ├── GhostModeActiveError
    │   └── CertificateError
    ├── MultihopError
    │   ├── VPNConfigError
    │   └── ExitNodeError
    └── InternalError

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from typing import Optional, Dict, Any


class PhantomException(Exception):
    """Base Exception Class for All Phantom-WG Errors.

    This class serves as the base exception for all custom errors in the
    Phantom-WG system. All other exception classes inherit from this.

    It provides standardized error handling and defines common attributes
    and methods for all errors. Each derived class should specify its own
    unique error code and HTTP status code.

    Attributes:
        - code: Unique error identifier
        - status_code: HTTP response status code
        - message: Human-readable error message
        - data: Optional additional error details
    """

    code: str = "PHANTOM_ERROR"
    status_code: int = 500

    def __init__(self, message: str, data: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.message = message
        self.data = data

    def to_dict(self) -> Dict[str, Any]:
        """Convert exception to dictionary format.

        This method converts the exception object to a standard dictionary
        format for use in API responses. The resulting dictionary contains
        the error message, error code, and additional data if present.

        Returns:
            Dict[str, Any]: Dictionary containing:
                - error: Human-readable error message
                - code: Unique error code
                - data: Additional error data (if provided)
        """
        result: Dict[str, Any] = {
            "error": self.message,
            "code": self.code
        }
        if self.data:
            result["data"] = self.data
        return result


class ConfigurationError(PhantomException):
    """Configuration Related Errors.

    Represents errors that occur during system configuration files,
    settings, or configuration operations.
    """
    code = "CONFIG_ERROR"
    status_code = 500


class ConfigNotFoundError(ConfigurationError):
    """Configuration file not found.

    Required configuration file does not exist in the system.
    """
    code = "CONFIG_NOT_FOUND"
    status_code = 404


class ClientError(PhantomException):
    """Client Management Related Errors.

    Represents errors that occur during creation, deletion, or
    management of WireGuard clients.
    """
    code = "CLIENT_ERROR"
    status_code = 400


class ClientExistsError(ClientError):
    """Client already exists.

    A client with the same name is already registered in the system.
    """
    code = "CLIENT_EXISTS"
    status_code = 409


class ClientNotFoundError(ClientError):
    """Client not found.

    Specified client is not registered in the system.
    """
    code = "CLIENT_NOT_FOUND"
    status_code = 404


class InvalidClientNameError(ClientError):
    """Invalid client name format.

    Client name does not comply with valid character rules.
    Only alphanumeric characters, hyphens, and underscores are allowed.
    """
    code = "INVALID_CLIENT_NAME"
    status_code = 400


class ServiceError(PhantomException):
    """Service Related Errors.

    Represents errors that occur during starting, stopping, or
    managing system services (WireGuard, wstunnel, etc.).
    """
    code = "SERVICE_ERROR"
    status_code = 503


class ServiceNotRunningError(ServiceError):
    """Required service is not running.

    System service required for the operation is not active.
    """
    code = "SERVICE_NOT_RUNNING"
    status_code = 503


class ServiceOperationError(ServiceError):
    """Service operation failed.

    The operation attempted on the service could not be completed.
    """
    code = "SERVICE_OPERATION_FAILED"
    status_code = 500


class NetworkError(PhantomException):
    """Network Related Errors.

    Represents errors related to network configuration, IP allocation,
    port management, or network connections.
    """
    code = "NETWORK_ERROR"
    status_code = 500


class IPAllocationError(NetworkError):
    """IP address allocation failed.

    Could not allocate a suitable IP address for the new client.
    All IP addresses may be in use.
    """
    code = "IP_ALLOCATION_ERROR"
    status_code = 500


class PortInUseError(NetworkError):
    """Port already in use.

    Specified port is being used by another service.
    """
    code = "PORT_IN_USE"
    status_code = 409


class ModuleError(PhantomException):
    """Module Related Errors.

    Represents errors that occur during dynamic module loading,
    module discovery, or execution of module actions.
    """
    code = "MODULE_ERROR"
    status_code = 500


class PhantomModuleNotFoundError(ModuleError):
    """Module not found.

    Specified module is not loaded or cannot be found in the system.
    """
    code = "MODULE_NOT_FOUND"
    status_code = 404


class ActionNotFoundError(ModuleError):
    """Action not found in module.

    Specified action is not defined in the related module.
    """
    code = "ACTION_NOT_FOUND"
    status_code = 404


class ValidationError(PhantomException):
    """Input Validation Errors.

    Represents errors that occur during validation of user inputs.
    Includes format, value range, or data type mismatches.
    """
    code = "VALIDATION_ERROR"
    status_code = 400


class MissingParameterError(ValidationError):
    """Required parameter is missing.

    A mandatory parameter for the operation was not provided.
    """
    code = "MISSING_PARAMETER"
    status_code = 400


class InvalidParameterError(ValidationError):
    """Parameter value is invalid.

    Provided parameter value is not in the expected format
    or value range.
    """
    code = "INVALID_PARAMETER"
    status_code = 400


class PhantomPermissionError(PhantomException):
    """Permission Related Errors.

    Represents errors related to authorization, access control,
    or file/system permissions.
    """
    code = "PERMISSION_ERROR"
    status_code = 403


class InsufficientPrivilegesError(PhantomPermissionError):
    """Insufficient privileges for operation.

    You do not have the necessary system privileges (root/sudo)
    to perform this operation.
    """
    code = "INSUFFICIENT_PRIVILEGES"
    status_code = 403


class GhostModeError(PhantomException):
    """Ghost Mode Related Errors.

    Represents errors that occur during enabling, disabling,
    or configuring the censorship resistance feature (Ghost Mode).
    """
    code = "GHOST_MODE_ERROR"
    status_code = 500


class GhostModeActiveError(GhostModeError):
    """Ghost Mode is already active.

    Ghost Mode is currently enabled. It must be disabled first.
    """
    code = "GHOST_MODE_ACTIVE"
    status_code = 409


class CertificateError(GhostModeError):
    """SSL certificate related errors.

    Errors that occur during SSL/TLS certificate generation,
    validation, or installation.
    """
    code = "CERTIFICATE_ERROR"
    status_code = 500


class MultihopError(PhantomException):
    """Multihop Related Errors.

    Represents errors that occur during VPN chaining (Multihop)
    feature configuration, exit node settings, or connection
    management.
    """
    code = "MULTIHOP_ERROR"
    status_code = 500


class VPNConfigError(MultihopError):
    """VPN configuration error.

    Provided VPN configuration file is invalid or incomplete.
    """
    code = "VPN_CONFIG_ERROR"
    status_code = 400


class ExitNodeError(MultihopError):
    """Exit node related error.

    Multihop exit node connection could not be established or was lost.
    """
    code = "EXIT_NODE_ERROR"
    status_code = 500


class InternalError(PhantomException):
    """Unexpected internal system error.

    An unexpected error occurred within the system. This usually
    indicates uncaught exceptions or system-level issues.
    """
    code = "INTERNAL_ERROR"
    status_code = 500

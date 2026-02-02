"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG API için Girdi (Input) Doğrulayıcıları (Validators)
    ==============================================
    
    Bu modül, Phantom-WG sistemindeki tüm API girdilerinin
    doğrulanması için kapsamlı bir doğrulama katmanı sağlar. Güvenlik
    ve veri bütünlüğünü korumak için kritik bir bileşendir.
    
    Ana Doğrulayıcı Kategorileri:
        - Temel Doğrulama: Gerekli alanlar ve tip kontrolü
        - İstemci Doğrulama: WireGuard istemci adı formatı ve kuralları
        - Ağ Doğrulama: IP adresleri, ağ maskeleri, portlar ve domain adları
        - DNS Doğrulama: DNS sunucu listelerinin doğrulanması
        - Dosya Doğrulama: Dosya ve dizin yollarının varlık kontrolü
        - Yapılandırma Doğrulama: WireGuard konfigürasyon formatı kontrolü
    
    Doğrulama Felsefesi:
        1. Erken Doğrulama: Hataları işlemin başında yakala
        2. Açık Hatalar: Kullanıcıya tam olarak neyin yanlış olduğunu söyle
        3. Güvenlik Öncelikli: Potansiyel güvenlik tehditlerini önle
        4. Tutarlılık: Tüm API'de aynı doğrulama kurallarını uygula

EN: Input Validators for Phantom-WG API
    ==========================================
    
    This module provides a comprehensive validation layer for all API
    inputs in the Phantom-WG system. It's a critical component
    for maintaining security and data integrity.
    
    Main Validator Categories:
        - Base Validation: Required fields and type checking
        - Client Validation: WireGuard client name format and rules
        - Network Validation: IP addresses, network masks, ports, and domains
        - DNS Validation: DNS server list validation
        - File Validation: File and directory path existence checks
        - Configuration Validation: WireGuard configuration format checking
    
    Validation Philosophy:
        1. Early Validation: Catch errors at the beginning of operations
        2. Clear Errors: Tell users exactly what's wrong
        3. Security First: Prevent potential security threats
        4. Consistency: Apply the same validation rules across all APIs

Usage Examples:
    name = ClientValidator.validate_client_name("john-laptop")

    ip = NetworkValidator.validate_ip_address("10.8.0.2", version=4)

    servers = DNSValidator.validate_dns_servers(["8.8.8.8", "8.8.4.4"])

    path = FileValidator.validate_file_path("/etc/wireguard/wg0.conf")

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import re
import ipaddress
from typing import Any, Optional, List
from pathlib import Path

from .exceptions import ValidationError, InvalidParameterError


class Validator:
    """Base Validator Class.

    Base class providing common functionality for all validators.
    This class contains shared validation operations like required
    field checking and type validation.

    Key Responsibilities:
        - Required field checking
        - Data type validation
        - Common validation logic
        - Consistent error messages
    """

    @staticmethod
    def validate_required(value: Any, field_name: str) -> Any:
        """Validate that a value is not None or empty.

        Performs basic validation for required fields. Raises
        ValidationError if the value is None or an empty string.

        Args:
            value: The value to validate
            field_name: Name of the field being validated (for error messages)

        Returns:
            Any: The validated value unchanged

        Raises:
            ValidationError: If value is None or empty string
        """
        if value is None or (isinstance(value, str) and not value.strip()):
            raise ValidationError(f"'{field_name}' is required")
        return value

    @staticmethod
    def validate_type(value: Any, expected_type: type, field_name: str) -> Any:
        """Validate that value is of expected type.

        Performs data type checking. Raises InvalidParameterError if
        the value is not of the expected type.

        Args:
            value: The value to check
            expected_type: The expected Python type
            field_name: Name of the field being validated

        Returns:
            Any: The validated value unchanged

        Raises:
            InvalidParameterError: If value is not of expected type
        """
        if not isinstance(value, expected_type):
            raise InvalidParameterError(
                f"'{field_name}' must be of type {expected_type.__name__}"
            )
        return value


class ClientValidator(Validator):
    """Client Validator.

    Provides specialized validation rules for WireGuard clients.
    Ensures client names are in valid format and comply with
    security rules.

    Validation Rules:
        - Only alphanumeric, dash, and underscore characters
        - Maximum 50 character length
        - Reserved names are prohibited
        - Case-insensitive for reserved names
    """

    CLIENT_NAME_PATTERN = re.compile(r'^[a-zA-Z0-9_-]+$')
    MAX_CLIENT_NAME_LENGTH = 50

    @classmethod
    def validate_client_name(cls, name: str) -> str:
        """Validate client name format.

        Verifies that the client name complies with all rules:
        - Required field check
        - Character length check (maximum 50)
        - Valid character check (alphanumeric, -, _)
        - Reserved name check

        Reserved names are prohibited to prevent conflicts with
        system components.

        Args:
            name: The client name to validate

        Returns:
            str: The validated client name

        Raises:
            InvalidParameterError: If name doesn't meet validation criteria
            ValidationError: If name is None or empty
        """
        cls.validate_required(name, "client_name")

        if len(name) > cls.MAX_CLIENT_NAME_LENGTH:
            raise InvalidParameterError(
                f"Client name must be {cls.MAX_CLIENT_NAME_LENGTH} characters or less"
            )

        if not cls.CLIENT_NAME_PATTERN.match(name):
            raise InvalidParameterError(
                "Client name can only contain letters, numbers, dashes, and underscores"
            )

        reserved_names = ["server", "admin", "root", "system", "ghost", "multihop"]
        if name.lower() in reserved_names:
            raise InvalidParameterError(
                f"'{name}' is a reserved name and cannot be used"
            )

        return name


class NetworkValidator(Validator):
    """Network Validator.

    Provides validation for all network configuration related values.
    Performs comprehensive validation for IP addresses, network masks,
    ports, and domain names.

    Validation Scopes:
        - IPv4 and IPv6 address validation
        - Network definition with CIDR notation
        - Valid port range (1-65535)
        - Domain name format checking
    """

    @staticmethod
    def validate_ip_address(ip: str, version: Optional[int] = None) -> str:
        """Validate IP address format.

        Verifies that the given string is a valid IP address.
        Optionally enforces a specific IP version (4 or 6).

        Args:
            ip: IP address string to validate
            version: Optional IP version (4 or 6) to enforce

        Returns:
            str: The validated IP address in canonical format

        Raises:
            ValidationError: If IP is None or empty
            InvalidParameterError: If IP format is invalid or wrong version
        """
        Validator.validate_required(ip, "ip_address")

        try:
            addr = ipaddress.ip_address(ip)
            if version:
                if version == 4 and not isinstance(addr, ipaddress.IPv4Address):
                    raise InvalidParameterError("IPv4 address required")
                elif version == 6 and not isinstance(addr, ipaddress.IPv6Address):
                    raise InvalidParameterError("IPv6 address required")
            return str(addr)
        except ValueError as e:
            raise InvalidParameterError(f"Invalid IP address: {str(e)}")

    @staticmethod
    def validate_network(network: str) -> str:
        """Validate network CIDR notation.

        Checks that the given string is a valid network definition
        in CIDR notation (e.g., 10.8.0.0/24).

        Args:
            network: Network string in CIDR notation

        Returns:
            str: The validated network in canonical format

        Raises:
            ValidationError: If network is None or empty
            InvalidParameterError: If CIDR notation is invalid
        """
        Validator.validate_required(network, "network")

        try:
            net = ipaddress.ip_network(network, strict=False)
            return str(net)
        except ValueError as e:
            raise InvalidParameterError(f"Invalid network: {str(e)}")

    @staticmethod
    def validate_port(port: int) -> int:
        """Validate network port number.

        Verifies that the given value is a valid TCP/UDP port number
        (in range 1-65535).

        Args:
            port: Port number to validate

        Returns:
            int: The validated port number

        Raises:
            InvalidParameterError: If port is not an integer or out of range
        """
        if not isinstance(port, int):
            raise InvalidParameterError("Port must be an integer")

        if not 1 <= port <= 65535:
            raise InvalidParameterError("Port must be between 1 and 65535")

        return port

    @staticmethod
    def validate_domain(domain: str) -> str:
        """Validate domain name format.

        Verifies that the given string is in valid domain name format.
        Checks compliance with RFC 1035 standards.

        Args:
            domain: Domain name to validate

        Returns:
            str: The validated domain name in lowercase

        Raises:
            ValidationError: If domain is None or empty
            InvalidParameterError: If domain format is invalid
        """
        Validator.validate_required(domain, "domain")

        domain_pattern = re.compile(
            r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*'
            r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
        )

        if not domain_pattern.match(domain):
            raise InvalidParameterError("Invalid domain name format")

        return domain.lower()


class DNSValidator(Validator):
    """DNS Validator.

    Provides specialized validation rules for DNS configuration.
    Checks validity and appropriateness of DNS server lists.

    Validation Features:
        - At least one DNS server required
        - All servers must be valid IP addresses
        - Must be provided in list format
        - Each server passes IP format validation
    """

    @staticmethod
    def validate_dns_servers(servers: List[str]) -> List[str]:
        """Validate list of DNS servers.

        Verifies that the given DNS servers are valid IP addresses
        and at least one server is present. Each server is validated
        with NetworkValidator.

        Args:
            servers: List of DNS server IP addresses

        Returns:
            List[str]: Validated list of DNS servers

        Raises:
            ValidationError: If list is empty
            InvalidParameterError: If not a list or contains invalid IPs
        """
        if not servers:
            raise ValidationError("At least one DNS server is required")

        if not isinstance(servers, list):
            raise InvalidParameterError("DNS servers must be provided as a list")

        validated = []
        for server in servers:
            validated.append(NetworkValidator.validate_ip_address(server))

        return validated


class FileValidator(Validator):
    """File Validator.

    Provides validation rules for file and directory paths.
    Performs existence checks and path validation in the
    file system.

    Validation Scopes:
        - File path validity
        - File existence check (optional)
        - Directory path validity
        - Directory existence check (optional)
    """

    @staticmethod
    def validate_file_path(path: str, must_exist: bool = True) -> Path:
        """Validate file path.

        Verifies that the given path is a valid file path and
        optionally that the file exists.

        Args:
            path: File path to validate
            must_exist: Whether to check if file exists. Defaults to True.

        Returns:
            Path: Validated Path object

        Raises:
            ValidationError: If path is None or empty
            InvalidParameterError: If file doesn't exist (when must_exist=True)
                                 or path points to directory instead of file
        """
        Validator.validate_required(path, "file_path")

        file_path = Path(path)

        if must_exist and not file_path.exists():
            raise InvalidParameterError(f"File not found: {path}")

        if must_exist and not file_path.is_file():
            raise InvalidParameterError(f"Not a file: {path}")

        return file_path

    @staticmethod
    def validate_directory(path: str, must_exist: bool = True) -> Path:
        """Validate directory path.

        Verifies that the given path is a valid directory path and
        optionally that the directory exists.

        Args:
            path: Directory path to validate
            must_exist: Whether to check if directory exists. Defaults to True.

        Returns:
            Path: Validated Path object

        Raises:
            ValidationError: If path is None or empty
            InvalidParameterError: If directory doesn't exist (when must_exist=True)
                                 or path points to file instead of directory
        """
        Validator.validate_required(path, "directory_path")

        dir_path = Path(path)

        if must_exist and not dir_path.exists():
            raise InvalidParameterError(f"Directory not found: {path}")

        if must_exist and not dir_path.is_dir():
            raise InvalidParameterError(f"Not a directory: {path}")

        return dir_path


class ConfigValidator(Validator):
    """Configuration Validator.

    Provides validation rules for WireGuard and system configuration
    files. Checks that configuration format is correct and contains
    required components.

    Validation Scopes:
        - WireGuard configuration format
        - Presence of required sections
        - Critical parameter checking
        - Boolean value conversions
    """

    @staticmethod
    def validate_wg_config(config_content: str) -> str:
        """Validate WireGuard configuration format.

        Checks that the given configuration content is a valid
        WireGuard configuration. Verifies presence of required
        sections and parameters.

        Args:
            config_content: WireGuard configuration content as string

        Returns:
            str: The validated configuration content

        Raises:
            ValidationError: If config_content is None or empty
            InvalidParameterError: If required sections or parameters are missing
        """
        Validator.validate_required(config_content, "config_content")

        if "[Interface]" not in config_content:
            raise InvalidParameterError("Missing [Interface] section in config")

        if "PrivateKey" not in config_content:
            raise InvalidParameterError("Missing PrivateKey in config")

        return config_content

    @staticmethod
    def validate_boolean(value: Any, field_name: str) -> bool:
        """Validate and convert to boolean value.

        Converts the given value to boolean. Provides flexible
        conversion for strings: "true", "yes", "1", "on" -> True;
        "false", "no", "0", "off" -> False.

        Args:
            value: Value to convert to boolean
            field_name: Field name for error messages

        Returns:
            bool: The converted boolean value

        Raises:
            InvalidParameterError: If value cannot be converted to boolean
        """
        if isinstance(value, bool):
            return value

        if isinstance(value, str):
            if value.lower() in ["true", "yes", "1", "on"]:
                return True
            elif value.lower() in ["false", "no", "0", "off"]:
                return False

        raise InvalidParameterError(f"'{field_name}' must be a boolean value")

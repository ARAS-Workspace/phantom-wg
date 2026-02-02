"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG için API Yanıt (Response) Standardizasyonu
    ================================================

    Bu modül, Phantom-WG sistemindeki tüm API yanıtları için
    standartlaştırılmış bir yanıt formatı sağlar. Tutarlı hata işleme,
    başarı yanıtları ve meta veri yönetimi sunar.
    
    Ana Özellikler:
        - Standart Yanıt Formatı: Tüm API yanıtları için tek bir format
        - Otomatik Meta Veri: Zaman damgası ve versiyon bilgisi otomatik eklenir
        - Temiz JSON Çıktısı: None değerler otomatik temizlenir
        - Factory Metodları: Başarı ve hata yanıtları için kolay oluşturma
        - Veri Sınıfı Yapısı: Type safety ve otomatik validation
    
    Yanıt Formatı:
        {
            "success": true/false,
            "data": {...} | [...],    // Başarıda veri, hatada ek detaylar
            "error": "...",           // Hata mesajı (sadece hatada)
            "code": "...",            // Hata kodu (sadece hatada)
            "metadata": {             // Her zaman mevcut
                "timestamp": "2025-01-30T12:00:00Z",
                "version": "1.0.0",
                "module": "...",      // İsteğe bağlı
                "action": "..."       // İsteğe bağlı
            }
        }

EN: API Response Standardization for Phantom-WG
    ==================================================

    This module provides a standardized response format for all API
    responses in the Phantom-WG system. It ensures consistent
    error handling, success responses, and metadata management.
    
    Key Features:
        - Standard Response Format: Single format for all API responses
        - Automatic Metadata: Timestamp and version info added automatically
        - Clean JSON Output: None values are automatically cleaned
        - Factory Methods: Easy creation for success and error responses
        - Dataclass Structure: Type safety and automatic validation
    
    Response Format:
        {
            "success": true/false,
            "data": {...} | [...],    // Data on success, extra details on error
            "error": "...",           // Error message (only on error)
            "code": "...",            // Error code (only on error)
            "metadata": {             // Always present
                "timestamp": "2025-01-30T12:00:00Z",
                "version": "1.0.0",
                "module": "...",      // Optional
                "action": "..."       // Optional
            }
        }

Usage Examples:
    # Success response
    response = APIResponse.success_response(
        data={"clients": [...], "total": 10},
        metadata={"module": "core", "action": "list_clients"}
    )
    
    # Error response
    response = APIResponse.error_response(
        error="Client not found",
        code="CLIENT_NOT_FOUND",
        data={"client_name": "john-laptop"}
    )
    
    # Direct initialization
    response = APIResponse(
        success=True,
        data={"status": "healthy"},
        metadata={"endpoint": "health_check"}
    )

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional, List, Union

from phantom import __version__
from phantom.models.responses import TypedAPIResponse


@dataclass
class APIResponse:
    """Standardized API Response Class.

    This class provides a uniform format for all API responses in the
    Phantom-WG system. It offers a consistent data structure for
    both success and error cases.

    Using the dataclass decorator provides automatic initialization, repr,
    and comparison methods. Full type safety with type hints.

    Features:
        - Automatic timestamp addition
        - Version information inclusion
        - None value cleanup
        - JSON conversion support
        - Factory method patterns

    NOTE: This class now uses TypedAPIResponse for type safety
          but maintains the same external API.
    """

    success: bool
    data: Optional[Union[Dict[str, Any], List[Any]]] = None
    error: Optional[str] = None
    code: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None

    def __post_init__(self):
        """Add timestamp and version info to metadata.

        This method runs automatically right after dataclass initialization.
        It's used to add consistent metadata to every response object.
        If metadata is None, creates a new dictionary, otherwise adds to
        existing metadata.

        Added information:
            - timestamp: UTC timestamp in ISO 8601 format
            - version: Phantom-WG API version
        """
        if self.metadata is None:
            self.metadata = {}

        # Add timestamp and version
        self.metadata.update({
            "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
            "version": __version__
        })

    def to_dict(self) -> Dict[str, Any]:
        """Convert response object to dictionary format.

        This method converts the APIResponse object to a dictionary suitable
        for JSON serialization. None values are cleaned up to provide a
        cleaner output. This ensures unnecessary fields don't appear in
        the JSON output.

        Returns:
            Dict[str, Any]: Dictionary representation of the response with None
                           values removed
        """
        # Create typed response for consistency
        typed_resp = TypedAPIResponse(
            success=self.success,
            data=self.data,
            error=self.error,
            code=self.code,
            metadata=self.metadata
        )
        return typed_resp.to_dict()

    def to_json(self, indent: int = 2) -> str:
        """Convert response object to JSON string format.

        This method converts the response object to readable JSON format.
        With ensure_ascii=False parameter, Turkish characters are properly
        preserved. Uses 2-space indentation by default.

        Args:
            indent: Number of spaces for indentation. Defaults to 2.

        Returns:
            str: JSON formatted string representation of the response
        """
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=indent)

    @classmethod
    def success_response(cls, data: Any, metadata: Optional[Dict[str, Any]] = None) -> 'APIResponse':
        """Create a successful API response.

        This factory method makes it easy to create standard response objects
        for successful operations. The success value is automatically set to
        True and it only takes data and optional metadata parameters.

        Use cases:
            - Returning client lists
            - Providing configuration info
            - Reporting operation results

        Args:
            data: The response data (can be dict, list, or any JSON-serializable type)
            metadata: Optional metadata dictionary to include in the response

        Returns:
            APIResponse: Success response object with success=True
        """
        return cls(
            success=True,
            data=data,
            metadata=metadata
        )

    @classmethod
    def error_response(cls, error: str, code: str, data: Optional[Any] = None,
                       metadata: Optional[Dict[str, Any]] = None) -> 'APIResponse':
        """Create an error API response.

        This factory method makes it easy to create standard response objects
        for error cases. The success value is automatically set to False.
        Error message and error code are required parameters.

        Error codes typically follow this format:
            - CLIENT_NOT_FOUND
            - INVALID_PARAMETER
            - SERVICE_ERROR
            - NETWORK_ERROR

        Args:
            error: Human-readable error message
            code: Machine-readable error code for programmatic handling
            data: Optional additional error details or context
            metadata: Optional metadata dictionary to include in the response

        Returns:
            APIResponse: Error response object with success=False
        """
        return cls(
            success=False,
            error=error,
            code=code,
            data=data,
            metadata=metadata
        )

    def __str__(self) -> str:
        """Return string representation of the response object.

        This method ensures the response object is displayed in JSON
        format when used with print() or str() functions. Useful for
        debugging and logging.

        Returns:
            str: JSON formatted string representation
        """
        return self.to_json()

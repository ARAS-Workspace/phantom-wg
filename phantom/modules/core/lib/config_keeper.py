"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: ConfigKeeper Manager - Yapılandırma ayarları ve çalışma zamanı tweak'leri yönetme
    ================================================================================
    
    Bu sınıf, sistem yapılandırmasının kalıcılığını ve tweak ayarlarının
    yönetimini sağlar.
    
    Ana Sorumluluklar:
        - Tweak ayarlarının doğrulanması ve güncellenmesi
        - Yapılandırma dosyası senkronizasyonu
        - Çalışma zamanı değişkenlerin güncellenmesi
        - Atomik yapılandırma değişiklikleri
        
    Desteklenen Tweak'ler:
        - restart_service_after_client_creation: false (varsayılan)
          İstemci eklendikten sonra servisi yeniden başlatır
          
    Güvenlik:
        - Atomik dosya yazma işlemleri
        - Doğrulama ve hata kontrolü
        - Çalışma zamanı senkronizasyonu

EN: ConfigKeeper Manager - Manage configuration settings and runtime tweaks
    ======================================================================
    
    This class ensures persistence of system configuration and management
    of tweak settings.
    
    Main Responsibilities:
        - Validation and updating of tweak settings
        - Configuration file synchronization
        - Runtime variable updates
        - Atomic configuration changes
        
    Supported Tweaks:
        - restart_service_after_client_creation: false (default)
          Restarts service after client addition
          
    Security:
        - Atomic file write operations
        - Validation and error checking
        - Runtime synchronization

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from pathlib import Path
from typing import Dict, Any, Callable, Optional
import logging

from phantom.api.exceptions import ValidationError, ServiceOperationError
from ..models import TweakSettingsResponse, TweakModificationResult


class ConfigKeeper:
    """Manages configuration persistence and runtime tweak settings.

    Maintains consistency between configuration files on disk and runtime
    variables in memory. Provides atomic updates and validation.

    Supported Tweaks:
        - restart_service_after_client_creation: Controls whether WireGuard
          service restarts after client operations (causes brief disconnections)

    Key Features:
        - Atomic file operations to prevent corruption
        - Runtime synchronization with configuration changes
        - Validation of setting names and values
        - Fallback to default values when needed
    """

    VALID_TWEAK_SETTINGS = [
        "restart_service_after_client_creation"
    ]

    DEFAULT_TWEAK_VALUES = {
        "restart_service_after_client_creation": False
    }

    TWEAK_DESCRIPTIONS = {
        "restart_service_after_client_creation":
            "Restart WireGuard service after adding & removing clients (causes connection drops)"
    }

    def __init__(self, config_dir: Path, logger: logging.Logger,
                 load_config_func: Callable, save_config_func: Callable,
                 runtime_updater: Optional[Callable] = None):
        self.config_dir = config_dir
        self.logger = logger
        self._load_config = load_config_func
        self._save_config = save_config_func
        self.runtime_updater = runtime_updater

    def _retrieve_current_tweaks_typed(self) -> TweakSettingsResponse:
        """Get current tweak settings with descriptions.

        Returns:
            TweakSettingsResponse with current values and descriptions

        Raises:
            ServiceOperationError: If configuration cannot be read
        """
        try:
            # Load fresh config from disk
            config = self._load_config()
            tweaks = config.get("tweaks", {})

            settings: Dict[str, bool] = {}
            descriptions: Dict[str, str] = {}

            for tweak_name in self.VALID_TWEAK_SETTINGS:
                current_value = tweaks.get(tweak_name, self.DEFAULT_TWEAK_VALUES[tweak_name])
                settings[tweak_name] = current_value

                descriptions[tweak_name] = self.TWEAK_DESCRIPTIONS[tweak_name]

            return TweakSettingsResponse(
                settings=settings,
                descriptions=descriptions
            )

        except Exception:
            self.logger.error("Failed to retrieve tweak settings")
            raise ServiceOperationError(
                "Unable to retrieve tweak settings. Please check:\n"
                "• Configuration file exists at /opt/phantom-wg/config/phantom.json\n"
                "• File permissions allow reading\n"
                "• JSON format is valid\n\n"
                "You can reset configuration with 'phantom-api reset factory_reset'"
            )

    def retrieve_current_tweaks(self) -> Dict[str, Any]:
        """Public wrapper to get tweak settings as dictionary.

        Returns:
            Dictionary with settings and descriptions
        """
        result: TweakSettingsResponse = self._retrieve_current_tweaks_typed()
        return result.to_dict()

    def _apply_tweak_modification_typed(self, setting_name: str, value: bool) -> TweakModificationResult:
        """Apply a tweak setting change with validation.

        Args:
            setting_name: Name of the tweak to modify
            value: New boolean value for the tweak

        Returns:
            TweakModificationResult with old/new values and description

        Raises:
            ValidationError: If setting name is invalid
            ServiceOperationError: If update fails
        """
        if not self.validate_tweak_name(setting_name):
            raise ValidationError(
                f"Invalid setting: {setting_name}. "
                f"Valid settings are: {', '.join(self.VALID_TWEAK_SETTINGS)}"
            )

        try:
            config = self._load_config()

            config = self.ensure_tweaks_section_exists(config)

            old_value = config["tweaks"].get(setting_name, self.DEFAULT_TWEAK_VALUES[setting_name])

            config["tweaks"][setting_name] = value

            self._save_config(config)

            if self.runtime_updater:
                self.update_runtime_values(setting_name, value)

            self.logger.info(
                f"Tweak '{setting_name}' updated from {old_value} to {value}"
            )

            return TweakModificationResult(
                setting=setting_name,
                new_value=value,
                old_value=old_value,
                message=f"Setting '{setting_name}' updated from {old_value} to {value}",
                description=self.TWEAK_DESCRIPTIONS.get(setting_name, "No description available")
            )

        except Exception:
            self.logger.error(f"Failed to update tweak setting '{setting_name}'")
            raise ServiceOperationError(
                f"Unable to update tweak setting '{setting_name}'. Common issues:\n"
                "• Configuration file is read-only or locked\n"
                "• Disk space is full\n"
                "• JSON structure is corrupted\n"
                "• Concurrent modification by another process\n\n"
                "Try again or check file permissions at /opt/phantom-wg/config/"
            )

    def apply_tweak_modification(self, setting_name: str, value: bool) -> Dict[str, Any]:
        """Public wrapper to apply tweak modification.

        Args:
            setting_name: Name of the tweak to modify
            value: New boolean value for the tweak

        Returns:
            Dictionary with modification result details
        """
        result: TweakModificationResult = self._apply_tweak_modification_typed(setting_name, value)
        return result.to_dict()

    def validate_tweak_name(self, setting_name: str) -> bool:
        """Check if a tweak name is valid.

        Args:
            setting_name: Name to validate

        Returns:
            True if name is in VALID_TWEAK_SETTINGS
        """
        return setting_name in self.VALID_TWEAK_SETTINGS

    def ensure_tweaks_section_exists(self, config: Dict[str, Any]) -> Dict[str, Any]:
        """Ensure 'tweaks' section exists in config.

        Args:
            config: Configuration dictionary

        Returns:
            Config dictionary with 'tweaks' section guaranteed
        """
        if "tweaks" not in config:
            config["tweaks"] = {}
            self.logger.debug("Created missing 'tweaks' section in configuration")
        return config

    def update_runtime_values(self, setting_name: str, value: bool) -> None:
        """Update runtime values via callback if available.

        Args:
            setting_name: Name of the setting to update
            value: New value for the setting
        """
        if self.runtime_updater:
            try:
                self.runtime_updater(setting_name, value)
                self.logger.debug(f"Runtime value updated for '{setting_name}'")
            except (AttributeError, TypeError, ValueError) as e:
                self.logger.warning(f"Failed to update runtime value for '{setting_name}': {e}")
                # Continue if runtime update fails since config is saved

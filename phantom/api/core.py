"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Ana API Motoru
    ====================================
    
    Bu modül, Phantom-WG için merkezi API motoru olarak hizmet verir ve şunları sağlar:
    
    - Modüllerin olduğu dizininden (../modules) dinamik modül keşfi ve yükleme
    - Tüm modül eylemleri için birleşik API arayüzü
    - Uygun hata yönetimi ile standartlaştırılmış istek/yanıt işleme
    - Temiz programatik erişim için modül proxy sistemi
    - Modül eylemlerine otomatik doğrulama ve parametre geçişi
    
    Ana Bileşenler:
        - PhantomAPI: Tüm modülleri yükleyen ve yöneten ana orkestratör
        - ModuleProxy: Modül eylemlerine öznitelik tarzı erişim sağlar (örn: api.core.add_client())
        - Dinamik Yükleme: Modülleri çalışma zamanında, sabit kodlanmış bağımlılıklar olmadan keşfeder
        - Hata Yönetimi: Detaylı hata yanıtları ile kapsamlı exception-handling
    
    Mimari:
        API motoru, 'phantom/modules/' dizinindeki her modülün otomatik olarak keşfedildiği
        ve BaseModule'den miras alan bir sınıf içeren geçerli bir module.py dosyası varsa
        yüklendiği eklenti tabanlı bir mimari kullanır.

EN: Phantom-WG Main API Engine
    =================================

    This module serves as the central API engine for Phantom-WG, providing:

    - Dynamic module discovery and loading from the modules directory
    - Unified API interface for all module actions
    - Standardized request/response handling with proper error management
    - Module proxy system for clean programmatic access
    - Automatic validation and parameter passing to module actions

    Key Components:
        - PhantomAPI: Main orchestrator that loads and manages all modules
        - ModuleProxy: Provides attribute-style access to module actions (e.g., api.core.add_client())
        - Dynamic Loading: Discovers modules at runtime without hardcoded dependencies
        - Error Handling: Comprehensive exception management with detailed error responses

    Architecture:
        The API engine uses a plugin-based architecture where each module in the
        'phantom/modules/' directory is automatically discovered and loaded if it
        contains a valid module.py file with a class inheriting from BaseModule.

Usage Examples:
    # Direct API usage
    api = PhantomAPI()
    response = api.execute("core", "list_clients")
    
    # Proxy usage
    api = PhantomAPI()
    response = api.core.list_clients()
    
    # List available modules
    modules = api.list_modules()

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import os
import importlib
import logging
from pathlib import Path
from typing import Optional

from phantom import __version__
from .response import APIResponse
from .exceptions import PhantomModuleNotFoundError, PhantomException


class ModuleProxy:
    """Module Proxy for Clean API Access.

    This class provides a proxy pattern for accessing module actions through
    attribute notation instead of explicit execute() calls. It enables a more
    pythonic and intuitive API interface.

    The proxy intercepts attribute access and dynamically creates callable
    methods that delegate to the main API's execute() method.

    Example:
        Instead of: api.execute("core", "add_client", client_name="john")
        You can use: api.core.add_client(client_name="john")
    """

    def __init__(self, api: 'PhantomAPI', module_name: str):
        """Initialize the module proxy.

        Args:
            api: Reference to the main PhantomAPI instance
            module_name: Name of the module this proxy represents
        """
        self.api = api
        self.module_name = module_name

    def __getattr__(self, action: str):
        """Dynamically create methods for module actions.

        When an attribute is accessed on the proxy (e.g., proxy.add_client),
        this method creates and returns a callable that will execute the
        corresponding module action when invoked.

        Args:
            action: The name of the action to execute

        Returns:
            Callable: A function that executes the module action with provided kwargs
        """

        def execute(**kwargs):
            return self.api.execute(self.module_name, action, **kwargs)

        return execute


class PhantomAPI:
    """Main API Entry Point for Phantom-WG.

    This is the central orchestrator class that manages all Phantom-WG
    modules and provides a unified interface for executing module actions.

    Key Responsibilities:
        - Automatic module discovery and loading from the modules directory
        - Module lifecycle management and instance caching
        - Request routing to appropriate module actions
        - Standardized error handling and response formatting
        - Module proxy creation for attribute-style access

    The API supports both direct execution and proxy-based access patterns,
    making it flexible for different use cases (CLI tools, scripts, etc.).

    Attributes:
        install_dir: Path to the Phantom-WG installation directory
        logger: Configured logger instance for API operations
        _modules: Dictionary of loaded module instances keyed by module name
    """

    def __init__(self, install_dir: Optional[Path] = None):
        """Initialize the Phantom API engine.

        Sets up the installation directory, configures logging, and loads all
        available modules from the modules directory. The initialization is
        designed to be quiet for clean JSON output in CLI usage.

        Args:
            install_dir: Optional custom installation directory. If not provided,
                        will attempt to auto-detect from development or production
                        locations.
        """
        self.install_dir = install_dir or self._detect_install_dir()
        self.logger = self._setup_logger()
        self._modules = {}

        # Discover and load all available modules from modules directory
        self._load_modules()

    # noinspection PyMethodMayBeStatic
    def _detect_install_dir(self) -> Path:
        """Automatically detect the Phantom-WG installation directory.

        This method uses a smart detection algorithm that works in both
        development and production environments:

        1. Development: Checks if running from source by looking for the
           'phantom' directory relative to this file's location
        2. Production: Checks the standard installation path at
           /opt/phantom-wg
        3. Fallback: Uses the current working directory if neither of the
           above locations exist

        Returns:
            Path: The detected installation directory
        """
        # Check if running from development environment (source code)
        current_file = Path(__file__).resolve()
        if (current_file.parent.parent.parent / "phantom").exists():
            return current_file.parent.parent.parent

        # Check standard production installation location
        if Path("/opt/phantom-wg").exists():
            return Path("/opt/phantom-wg")

        # Fallback to current working directory if nothing else is found
        return Path.cwd()

    # noinspection PyMethodMayBeStatic
    def _setup_logger(self) -> logging.Logger:
        """Configure and return the API logger instance.

        Sets up a logger with appropriate formatting and output handling.
        The logger is configured to be quiet by default (WARNING level) to
        avoid interfering with JSON output in CLI usage.

        Logger Configuration:
            - Name: "phantom.api" for easy filtering
            - Handler: StreamHandler for console output
            - Format: Timestamp, logger name, level, and message
            - Level: WARNING (suppresses INFO messages for clean output)

        Returns:
            logging.Logger: Configured logger instance
        """
        logger = logging.getLogger("phantom.api")

        # Configure logger only if not already configured (avoid duplicate handlers)
        if not logger.handlers:
            handler = logging.StreamHandler()
            formatter = logging.Formatter(
                '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
            )
            handler.setFormatter(formatter)
            logger.addHandler(handler)
            # Set to WARNING level to suppress INFO messages for clean JSON output
            logger.setLevel(logging.WARNING)

        return logger

    def _load_modules(self) -> None:
        """Dynamically discover and load all available modules.

        This method scans the 'phantom/modules' directory for valid module
        packages. A valid module is a directory containing a 'module.py' file
        with a class that inherits from BaseModule.

        The loading process is fault-tolerant - if one module fails to load,
        it logs the error and continues loading other modules. This ensures
        that a single broken module doesn't prevent the entire system from
        functioning.

        Module Discovery Rules:
            - Must be a directory under 'phantom/modules/'
            - Must contain a 'module.py' file
            - The module.py must have a class ending with 'Module'
            - The class must have an 'execute_action' method
        """
        modules_dir = self.install_dir / "phantom" / "modules"

        if not modules_dir.exists():
            self.logger.warning(f"Modules directory not found: {modules_dir}")
            return

        # Iterate through all subdirectories in modules directory
        for module_dir in modules_dir.iterdir():
            if module_dir.is_dir() and (module_dir / "module.py").exists():
                try:
                    self._load_module(module_dir.name)
                except Exception as e:
                    self.logger.error(f"Failed to load module '{module_dir.name}': {e}")

    def _load_module(self, module_name: str) -> None:
        """Load a specific module by name.

        This method handles the dynamic import and instantiation of a module.
        It uses Python's importlib to import the module file, then searches
        for a valid module class using naming conventions and interface checks.

        Module Class Detection:
            - Class name must end with 'Module' (e.g., CoreModule, DNSModule)
            - Must not be 'BaseModule' itself
            - Must have an 'execute_action' method (indicating it implements
              the module interface)

        Once a valid module class is found, it's instantiated with the
        installation directory and stored in the modules registry.

        Args:
            module_name: Name of the module directory to load

        Raises:
            Exception: Re-raises any exception that occurs during module loading
                      to allow the caller to handle it appropriately
        """
        try:
            # Dynamically import the module using Python's importlib
            module_path = f"phantom.modules.{module_name}.module"
            module = importlib.import_module(module_path)

            # Search for the module class within the imported module
            module_class = None
            for attr_name in dir(module):
                attr = getattr(module, attr_name)
                if (isinstance(attr, type) and
                        attr_name.endswith('Module') and
                        attr_name != 'BaseModule' and
                        hasattr(attr, 'execute_action')):
                    module_class = attr
                    break

            if module_class is not None:
                # Create an instance of the module class and register it
                # noinspection PyCallingNonCallable
                instance = module_class(self.install_dir)
                self._modules[module_name] = instance
            else:
                self.logger.warning(f"No module class found in {module_name}")

        except Exception as e:
            self.logger.error(f"Error loading module '{module_name}': {e}")
            raise

    def execute(self, module: str, action: str, **kwargs) -> APIResponse:
        """Execute a specific action on a module with given parameters.

        This is the main entry point for all module action executions. It handles:
        - Module existence validation
        - Action delegation to the appropriate module
        - Comprehensive error handling with proper response formatting
        - Debug mode support with detailed error information

        The method implements a two-tier error handling strategy:
        1. Known errors (PhantomException): Formatted and returned as structured responses
        2. Unexpected errors: Logged with full traceback and returned with debug info
           when running in debug mode

        Args:
            module: Name of the module to execute action on
            action: Name of the action to execute
            **kwargs: Arbitrary keyword arguments passed to the action

        Returns:
            APIResponse: Module's response (usually APIResponse) when successful,
                        or error APIResponse when module not found or exception occurs

        Error Handling:
            - Module not found: Returns error with list of available modules
            - PhantomException: Returns formatted error response
            - Unexpected errors: Logs full traceback and returns detailed error
              info in debug mode
        """
        try:
            # Verify that the requested module exists in the loaded modules
            if module not in self._modules:
                available = ", ".join(self._modules.keys())
                raise PhantomModuleNotFoundError(
                    f"Module '{module}' not found. Available modules: {available}",
                    data={"available_modules": list(self._modules.keys())}
                )

            # Delegate action execution to the appropriate module instance
            module_instance = self._modules[module]
            return module_instance.execute_action(action, **kwargs)

        except PhantomException as e:
            # Handle known Phantom exceptions with formatted error response
            return APIResponse.error_response(
                error=e.message,
                code=e.code,
                data=e.data
            )
        except Exception as e:
            # Log unexpected errors with full traceback for debugging
            self.logger.exception(f"Unexpected error in {module}.{action}: {str(e)}")

            # Collect detailed error information for diagnostics
            import traceback
            error_detail = {
                "exception_type": type(e).__name__,
                "exception_message": str(e),
                "module": module,
                "action": action
            }

            # Include full traceback when running in debug mode
            if os.environ.get('DEBUG_MODE') or os.environ.get('PHANTOM_DEBUG'):
                error_detail["traceback"] = traceback.format_exc()

            # Return standardized error response for unexpected errors
            return APIResponse.error_response(
                error=f"Unexpected error in {module}.{action}: {str(e)}",
                code="INTERNAL_ERROR",
                data=error_detail
            )

    def list_modules(self) -> APIResponse:
        """List all available modules with their descriptions and action counts.

        Returns a structured list of all loaded modules, ordered by preference
        for better UX. Core functionality modules are listed first, followed
        by any additional modules.

        Module Order:
            1. core - Essential WireGuard operations
            2. dns - DNS configuration management
            3. multihop - VPN chaining functionality
            4. ghost - Censorship resistance features
            5. reset - System reset operations
            6. Any additional modules (alphabetically)

        Returns:
            APIResponse: Success response containing:
                - modules: List of module info dictionaries with:
                    - name: Module identifier
                    - description: Human-readable description
                    - actions_count: Number of available actions
                - total: Total number of loaded modules
        """
        modules = []

        # Define preferred display order for better UX (core features first)
        module_order = ["core", "dns", "multihop", "ghost"]

        # Add modules in preferred order first
        for module_name in module_order:
            if module_name in self._modules:
                instance = self._modules[module_name]
                modules.append({
                    "name": module_name,
                    "description": instance.get_module_description(),
                    "actions_count": len(instance.get_actions())
                })

        # Add any remaining modules that aren't in the preferred order list
        for name, instance in self._modules.items():
            if name not in module_order:
                modules.append({
                    "name": name,
                    "description": instance.get_module_description(),
                    "actions_count": len(instance.get_actions())
                })

        return APIResponse.success_response(
            data={
                "modules": modules,
                "total": len(modules)
            }
        )

    def module_info(self, module: str) -> APIResponse:
        """Get detailed information about a specific module including all its actions.

        This method provides comprehensive information about a module, including
        its description and a list of all available actions with their descriptions.

        Special UI Handling:
            - Core module: Hides individual client actions (add/remove/export) as
              they're accessed through the client_operations submenu. Renames
              list_clients to indicate it's a menu entry point.
            - Reset module: Hides internal verify_reset_confirmation action
              which is used internally for safety checks.

        Args:
            module: Name of the module to get information about

        Returns:
            APIResponse: Success response containing:
                - name: Module identifier
                - description: Module's full description
                - actions: List of action dictionaries with:
                    - name: Action identifier
                    - description: Action's docstring or default text

        Raises:
            PhantomModuleNotFoundError: If the specified module doesn't exist
        """
        if module not in self._modules:
            raise PhantomModuleNotFoundError(f"Module '{module}' not found")

        instance = self._modules[module]
        actions = instance.get_actions()

        action_list = []

        # Special handling for core module to improve UI/UX
        if module == "core":
            # Process actions with special UI considerations
            for name, func in actions.items():
                if func:
                    # Hide individual client actions as they're accessed through submenu
                    if name in ["add_client", "remove_client", "export_client"]:
                        continue

                    if name == "list_clients":
                        action_list.append({
                            "name": name,
                            "description": "Client Operations - Manage all client operations"
                        })
                    else:
                        action_list.append({
                            "name": name,
                            "description": func.__doc__.strip() if func.__doc__ else "No description"
                        })
        else:
            # Standard handling for all other modules
            for name, func in actions.items():
                action_list.append({
                    "name": name,
                    "description": func.__doc__.strip() if func.__doc__ else "No description"
                })

        return APIResponse.success_response(
            data={
                "name": module,
                "description": instance.get_module_description(),
                "actions": action_list
            }
        )

    # Property accessors
    @property
    def core(self) -> ModuleProxy:
        """Access the Core module through a proxy interface.

        The Core module provides essential WireGuard management functionality
        including client management, server configuration, and network operations.

        Returns:
            ModuleProxy: Proxy object for the core module
        """
        return ModuleProxy(self, "core")

    @property
    def dns(self) -> ModuleProxy:
        """Access the DNS module through a proxy interface.

        The DNS module handles DNS server configuration and client config
        updates for custom DNS settings.

        Returns:
            ModuleProxy: Proxy object for the DNS module
        """
        return ModuleProxy(self, "dns")

    @property
    def ghost(self) -> ModuleProxy:
        """Access the Ghost Mode module through a proxy interface.

        The Ghost module provides censorship resistance features through
        WebSocket tunneling and SSL/TLS encryption.

        Returns:
            ModuleProxy: Proxy object for the ghost module
        """
        return ModuleProxy(self, "ghost")

    @property
    def multihop(self) -> ModuleProxy:
        """Access the Multihop module through a proxy interface.

        The Multihop module enables VPN chaining functionality, allowing
        traffic to be routed through multiple VPN servers.

        Returns:
            ModuleProxy: Proxy object for the multihop module
        """
        return ModuleProxy(self, "multihop")

    def health_check(self) -> APIResponse:
        """Perform a system health check and return API status information.

        This method provides a quick way to verify that the API is functioning
        correctly and all modules are loaded. It's useful for monitoring,
        debugging, and integration testing.

        The health check includes:
            - API version information
            - Number of loaded modules
            - List of available module names
            - Installation directory path
            - Overall health status

        Returns:
            APIResponse: Success response containing:
                - api_version: Current Phantom-WG version
                - modules_loaded: Count of successfully loaded modules
                - modules: List of module names
                - install_dir: Path to installation directory
                - status: Always "healthy" if this method executes
        """
        health_data = {
            "api_version": __version__,
            "modules_loaded": len(self._modules),
            "modules": list(self._modules.keys()),
            "install_dir": str(self.install_dir),
            "status": "healthy"
        }

        return APIResponse.success_response(data=health_data)

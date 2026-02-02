"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Phantom-WG Module Base Class

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import logging
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Dict, Any, Callable, Optional, List
import json

from ..api import APIResponse, PhantomException, ActionNotFoundError

class BaseModule(ABC):

    def __init__(self, install_dir: Optional[Path] = None):
        """
        Initialize BaseModule object and set up base directory structure.

        Creates the necessary directory structure for the module,
        initializes the logging system, loads configuration, and sets up
        module metadata.

        Args:
            install_dir: Installation directory path (default: /opt/phantom-wg)
        """
        self.install_dir = install_dir or Path("/opt/phantom-wg")
        self.config_dir = self.install_dir / "config"
        self.data_dir = self.install_dir / "data"
        self.logs_dir = self.install_dir / "logs"

        # Setup logger for this module
        self.logger = self._setup_logger()

        # Load configuration
        self.config = self._load_config()

        # Module metadata
        self.metadata = {
            "module": self.get_module_name(),
            "description": self.get_module_description()
        }

    def _setup_logger(self) -> logging.Logger:
        """
        Set up module-specific logger.

        Creates a logger with format phantom.<module_name> for each module.
        Handlers are configured by the main application.

        Returns:
            logging.Logger: Configured logger instance
        """
        logger_name = f"phantom.{self.get_module_name()}"
        logger = logging.getLogger(logger_name)

        # Don't add handlers here - let the main app configure logging
        logger.setLevel(logging.DEBUG)

        return logger

    def _load_config(self) -> Dict[str, Any]:
        """
        Load main configuration file.

        Reads system configuration from phantom.json file. Raises ConfigurationError
        if file not found or read error occurs.

        Returns:
            Dict[str, Any]: Configuration dictionary

        Raises:
            ConfigurationError: If config file not found or cannot be read
        """
        from phantom.api.exceptions import ConfigurationError

        config_file = self.config_dir / "phantom.json"

        if not config_file.exists():
            error_msg = f"Configuration file not found: {config_file}"
            self.logger.error(error_msg)
            raise ConfigurationError(error_msg)

        try:
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            error_msg = f"Error loading configuration file: {e}"
            self.logger.error(error_msg)
            raise ConfigurationError(error_msg)

    def _save_config(self, config: Optional[Dict[str, Any]] = None) -> None:
        """
        Save configuration to file.

        Saves provided configuration or current instance configuration
        to phantom.json file. Creates directory if it doesn't exist.

        Args:
            config: Configuration dictionary to save (uses instance config if None)
        """
        config_file = self.config_dir / "phantom.json"
        config_file.parent.mkdir(parents=True, exist_ok=True)

        # Use provided config or instance config
        config_to_save = config if config is not None else self.config

        with open(config_file, 'w') as f:
            json.dump(config_to_save, f, indent=2)

        # Update instance config if a different config was provided
        if config is not None:
            self.config = config

    @abstractmethod
    def get_module_name(self) -> str:
        """
        Return module name.

        Each module must return its unique name. This name is used
        in API calls and logging.

        Returns:
            str: Module name
        """
        pass

    @abstractmethod
    def get_module_description(self) -> str:
        """
        Return module description.

        Returns:
            str: Module description
        """
        pass

    @abstractmethod
    def get_actions(self) -> Dict[str, Callable]:
        """
        Return available actions for this module.

        Returns a dictionary of action names and callable functions.
        Each action becomes accessible through the API.

        Returns:
            Dict[str, Callable]: Dictionary mapping action names to functions
        """
        pass

    def execute_action(self, action: str, **kwargs) -> APIResponse:
        """
        Execute an action and return API response.

        Runs the given action with parameters, catches errors, and
        returns properly formatted API response. All actions are
        executed through this method.

        Args:
            action: Action name to execute
            **kwargs: Action parameters

        Returns:
            APIResponse: Formatted API response with success/error status
        """
        try:
            # Log the action
            self.logger.info(f"Executing action: {action} with args: {kwargs}")

            # Get available actions
            actions = self.get_actions()

            # Check if action exists
            if action not in actions:
                available = ", ".join(actions.keys())
                raise ActionNotFoundError(
                    f"Action '{action}' not found in module '{self.get_module_name()}'. "
                    f"Available actions: {available}"
                )

            # Execute the action
            result = actions[action](**kwargs)

            # Log success
            self.logger.info(f"Action '{action}' completed successfully")

            # Return success response
            return APIResponse.success_response(
                data=result,
                metadata={
                    "module": self.get_module_name(),
                    "action": action
                }
            )

        except PhantomException as e:
            # Log known errors
            self.logger.error(f"Action '{action}' failed: {e.message}")

            # Return error response
            return APIResponse.error_response(
                error=e.message,
                code=e.code,
                data=e.data,
                metadata={
                    "module": self.get_module_name(),
                    "action": action
                }
            )

        except Exception as e:
            # Log unexpected errors
            self.logger.exception(f"Unexpected error in action '{action}'")

            # Return generic error response
            return APIResponse.error_response(
                error="An unexpected error occurred",
                code="INTERNAL_ERROR",
                metadata={
                    "module": self.get_module_name(),
                    "action": action,
                    "detail": str(e) if self._is_debug_mode() else None
                }
            )

    def _is_debug_mode(self) -> bool:
        """
        Check if debug mode is enabled.

        If debug value is true in configuration, error details are
        included in API responses.

        Returns:
            bool: True if debug mode enabled, False otherwise
        """
        return self.config.get("debug", False)

    # Utility methods for modules

    def _read_json_file(self, file_path: Path) -> Dict[str, Any]:
        """
        Safely read JSON file.

        Returns empty dictionary if file doesn't exist or read error
        occurs. Errors are logged.

        Args:
            file_path: Path to JSON file

        Returns:
            Dict[str, Any]: Parsed JSON data or empty dictionary
        """
        if not file_path.exists():
            return {}

        try:
            with open(file_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            self.logger.error(f"Error reading JSON file {file_path}: {e}")
            return {}

    # noinspection PyMethodMayBeStatic
    def _write_json_file(self, file_path: Path, data: Dict[str, Any]) -> None:
        """
        Safely write to JSON file.

        Writes data in JSON format to file. Creates directory if it
        doesn't exist. File is saved with pretty formatting (indented).

        Args:
            file_path: Path to JSON file
            data: Dictionary to write to file
        """
        file_path.parent.mkdir(parents=True, exist_ok=True)

        with open(file_path, 'w') as f:
            json.dump(data, f, indent=2)

    # noinspection PyMethodMayBeStatic
    def _run_command(self, command: List[str], capture_output: bool = True, **kwargs):
        """
        Run system command and return result.

        Executes given command using subprocess. Returns a CommandResult object
        with attributes like returncode, stdout, stderr for subprocess compatibility.

        Args:
            command: Command and arguments as list
            capture_output: Whether to capture stdout/stderr
            **kwargs: Additional subprocess.run parameters

        Returns:
            CommandResult: Object with returncode, stdout, stderr attributes
        """
        import subprocess
        from phantom.models.base import CommandResult

        try:
            run_params = {
                'capture_output': capture_output,
                'text': True,
                'check': True
            }
            run_params.update(kwargs)

            result = subprocess.run(command, **run_params)

            return CommandResult(
                success=True,
                stdout=result.stdout if capture_output else "",
                stderr=result.stderr if capture_output else "",
                returncode=result.returncode
            )
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if capture_output and e.stderr else str(e)
            return CommandResult(
                success=False,
                stdout=e.stdout if capture_output and e.stdout else "",
                stderr=e.stderr if capture_output and e.stderr else error_msg,
                returncode=e.returncode,
                error=error_msg
            )
        except Exception as e:
            return CommandResult(
                success=False,
                stdout="",
                stderr=str(e),
                returncode=-1,
                error=str(e)
            )

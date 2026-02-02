"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Unit tests for phantom.api.core module

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import os
from pathlib import Path
from unittest.mock import Mock, patch
import logging

from phantom.api.core import PhantomAPI, ModuleProxy
from phantom.api.response import APIResponse
from phantom.api.exceptions import (
    ActionNotFoundError
)


class TestModuleProxy:

    def test_module_proxy_init(self):
        mock_api = Mock(spec=PhantomAPI)
        proxy = ModuleProxy(mock_api, "test_module")

        assert proxy.api == mock_api
        assert proxy.module_name == "test_module"

    def test_module_proxy_getattr(self):
        mock_api = Mock(spec=PhantomAPI)
        mock_api.execute.return_value = APIResponse.success_response({"result": "success"})

        proxy = ModuleProxy(mock_api, "test_module")

        action_func = proxy.test_action
        assert callable(action_func)

        result = action_func(param1="value1", param2="value2")

        mock_api.execute.assert_called_once_with(
            "test_module", "test_action", param1="value1", param2="value2"
        )
        assert isinstance(result, APIResponse)
        assert result.success is True
        assert result.data.get("result") == "success"

    def test_module_proxy_multiple_actions(self):
        mock_api = Mock(spec=PhantomAPI)
        mock_api.execute.return_value = APIResponse.success_response({"status": "ok"})

        proxy = ModuleProxy(mock_api, "core")

        proxy.add_client(client_name="test")
        proxy.remove_client(client_name="test")
        proxy.list_clients()

        assert mock_api.execute.call_count == 3
        calls = mock_api.execute.call_args_list
        assert calls[0][0] == ("core", "add_client")
        assert calls[1][0] == ("core", "remove_client")
        assert calls[2][0] == ("core", "list_clients")


class TestPhantomAPI:

    # noinspection PyMethodMayBeStatic
    def _create_mock_path_hierarchy(self):
        """Helper to create a mock directory hierarchy for path resolution tests."""
        mock_file = Mock(spec=Path)
        mock_parent3 = Mock(spec=Path)
        mock_parent2 = Mock(spec=Path)
        mock_parent = Mock(spec=Path)

        # Build hierarchy: file -> parent -> parent2 -> parent3
        mock_file.parent = mock_parent
        mock_parent.parent = mock_parent2
        mock_parent2.parent = mock_parent3

        return mock_file, mock_parent, mock_parent2, mock_parent3

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_api_initialization(self, mock_load_modules, mock_setup_logger, mock_detect_dir):
        mock_detect_dir.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup_logger.return_value = mock_logger

        api = PhantomAPI()

        assert api.install_dir == Path("/test/path")
        assert api.logger == mock_logger
        mock_load_modules.assert_called_once()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_api_initialization_with_custom_dir(self, mock_load, mock_setup_logger, mock_detect_dir):
        custom_path = Path("/custom/install/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup_logger.return_value = mock_logger

        api = PhantomAPI(install_dir=custom_path)

        assert api.install_dir == custom_path
        mock_detect_dir.assert_not_called()
        mock_load.assert_called_once()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_detect_install_dir_development(self, _mock_load, mock_setup, mock_detect):
        mock_detect.return_value = Path("/dev/phantom")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        assert api.install_dir == Path("/dev/phantom")

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_detect_install_dir_production(self, _mock_load, mock_setup, mock_detect):
        mock_detect.return_value = Path("/opt/phantom-wg")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        assert api.install_dir == Path("/opt/phantom-wg")

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_detect_install_dir_fallback(self, _mock_load, mock_setup, mock_detect):
        mock_detect.return_value = Path("/current/working/dir")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        assert api.install_dir == Path("/current/working/dir")

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_module')
    def test_load_modules(self, mock_load_module, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        with patch.object(Path, 'exists', return_value=True):
            with patch.object(Path, 'is_dir', return_value=True):
                with patch.object(Path, 'iterdir') as mock_iterdir:
                    # Create mock module directories
                    mock_core = Mock(spec=Path)
                    mock_core.name = "core"
                    mock_core.is_dir.return_value = True
                    mock_core.__truediv__ = lambda _self, _other: Mock(exists=Mock(return_value=True))

                    mock_dns = Mock(spec=Path)
                    mock_dns.name = "dns"
                    mock_dns.is_dir.return_value = True
                    mock_dns.__truediv__ = lambda _self, _other: Mock(exists=Mock(return_value=True))

                    # Non-directory file should be skipped
                    mock_file = Mock(spec=Path)
                    mock_file.name = "somefile.py"
                    mock_file.is_dir.return_value = False

                    mock_iterdir.return_value = [mock_core, mock_dns, mock_file]

                    _ = PhantomAPI()

                    # Only directories with module.py should be loaded
                    assert mock_load_module.call_count == 2

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_load_module_success(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        with patch('importlib.import_module') as mock_import:
            mock_module = Mock()

            class MockCoreModule:
                def __init__(self, install_dir):
                    self.install_dir = install_dir

                def execute_action(self, _action, **_kwargs):  # noqa
                    return {"success": True}

            mock_module.CoreModule = MockCoreModule
            mock_module.BaseModule = Mock()  # This should be skipped

            mock_import.return_value = mock_module

            api._load_module("core")

            mock_import.assert_called_once_with("phantom.modules.core.module")
            assert "core" in api._modules
            assert api._modules["core"] is not None
            assert isinstance(api._modules["core"], MockCoreModule)

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_load_module_not_found(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        api = PhantomAPI()

        with patch('importlib.import_module') as mock_import:
            # Module import fails
            mock_import.side_effect = ModuleNotFoundError("No module named 'phantom.modules.test'")

            with pytest.raises(ModuleNotFoundError):
                api._load_module("test")

            # Module should not be loaded
            assert "test" not in api._modules
            mock_logger.error.assert_called()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_load_module_import_error(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        api = PhantomAPI()

        with patch('importlib.import_module') as mock_import:
            mock_import.side_effect = ImportError("Import failed")

            with pytest.raises(ImportError):
                api._load_module("test")

            # Module should not be loaded
            assert "test" not in api._modules
            mock_logger.error.assert_called()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_execute_success(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.execute_action.return_value = {"result": "success"}
        api._modules = {"test": mock_module}

        result = api.execute("test", "test_action", param1="value1")

        # execute returns the module's result directly (not wrapped in APIResponse)
        assert isinstance(result, dict)
        assert result["result"] == "success"
        mock_module.execute_action.assert_called_once_with("test_action", param1="value1")

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_execute_module_not_found(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {}

        result = api.execute("nonexistent", "action")

        assert isinstance(result, APIResponse)
        assert result.success is False
        assert result.error is not None
        assert "not found" in result.error.lower()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_execute_action_not_found(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.execute_action.side_effect = ActionNotFoundError("Action not found")
        api._modules = {"test": mock_module}

        result = api.execute("test", "invalid_action")

        assert result.success is False
        assert result.code == "ACTION_NOT_FOUND"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_execute_validation_error(self, _mock_load_modules, mock_setup, mock_detect):
        from phantom.api.exceptions import ValidationError

        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.execute_action.side_effect = ValidationError("Invalid input")
        api._modules = {"test": mock_module}

        result = api.execute("test", "action")

        assert result.success is False
        assert result.code == "VALIDATION_ERROR"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_execute_generic_exception(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.execute_action.side_effect = Exception("Unexpected error")
        api._modules = {"test": mock_module}

        result = api.execute("test", "action")

        assert result.success is False
        assert result.code == "INTERNAL_ERROR"
        # logger.exception is called for generic exceptions
        mock_logger.exception.assert_called()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_list_modules(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_core = Mock()
        mock_core.get_module_description.return_value = "Core module"
        mock_core.get_actions.return_value = {"action1": {}, "action2": {}}

        mock_dns = Mock()
        mock_dns.get_module_description.return_value = "DNS module"
        mock_dns.get_actions.return_value = {"dns_action": {}}

        api._modules = {"core": mock_core, "dns": mock_dns}

        result = api.list_modules()

        # list_modules returns an APIResponse object
        assert isinstance(result, APIResponse)
        assert result.success is True
        assert "modules" in result.data
        assert len(result.data["modules"]) == 2

        core_info = next(m for m in result.data["modules"] if m["name"] == "core")
        assert core_info["description"] == "Core module"
        assert "action_count" in core_info or "actions_count" in core_info

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_module_info(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.get_module_name.return_value = "test"
        mock_module.get_module_description.return_value = "Test module"
        mock_module.get_actions.return_value = {"action1": {"description": "Test action"}}

        api._modules = {"test": mock_module}

        result = api.module_info("test")

        # module_info returns an APIResponse object
        assert isinstance(result, APIResponse)
        assert result.success is True
        assert "name" in result.data
        assert "description" in result.data
        assert "actions" in result.data
        assert result.data["name"] == "test"
        assert result.data["description"] == "Test module"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_module_info_not_found(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {}

        # module_info raises exception for non-existent module
        from phantom.api.exceptions import PhantomModuleNotFoundError
        with pytest.raises(PhantomModuleNotFoundError) as exc_info:
            api.module_info("nonexistent")

        assert "Module 'nonexistent' not found" in str(exc_info.value)

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_core_property(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {"core": Mock()}

        core_proxy = api.core

        assert isinstance(core_proxy, ModuleProxy)
        assert core_proxy.module_name == "core"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_dns_property(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {"dns": Mock()}

        dns_proxy = api.dns

        assert isinstance(dns_proxy, ModuleProxy)
        assert dns_proxy.module_name == "dns"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_ghost_property(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {"ghost": Mock()}

        ghost_proxy = api.ghost

        assert isinstance(ghost_proxy, ModuleProxy)
        assert ghost_proxy.module_name == "ghost"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_health_check(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_core = Mock()
        mock_core.execute_action.return_value = {"status": "healthy"}
        api._modules = {"core": mock_core}

        result = api.health_check()

        assert isinstance(result, APIResponse)
        assert result.success is True

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_multihop_property(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        api._modules = {"multihop": Mock()}

        multihop_proxy = api.multihop

        assert isinstance(multihop_proxy, ModuleProxy)
        assert multihop_proxy.module_name == "multihop"

    def test_module_proxy_error_handling(self):
        mock_api = Mock(spec=PhantomAPI)
        mock_api.execute.side_effect = Exception("API Error")

        proxy = ModuleProxy(mock_api, "test")

        with (pytest.raises(Exception) as exc_info):
            proxy.test_action()

        assert "API Error" in str(exc_info.value)

    @patch('pathlib.Path.resolve')
    @patch('pathlib.Path.exists')
    @patch('pathlib.Path.cwd')
    def test_detect_install_dir_direct_call(self, _mock_cwd, _mock_exists, mock_resolve):
        mock_file, mock_parent, mock_parent2, mock_parent3 = self._create_mock_path_hierarchy()
        mock_resolve.return_value = mock_file

        phantom_dir = Mock(spec=Path)
        mock_parent3.__truediv__ = Mock(return_value=phantom_dir)
        phantom_dir.exists.return_value = True

        with patch('phantom.api.core.PhantomAPI._setup_logger') as mock_setup:
            with patch('phantom.api.core.PhantomAPI._load_modules'):
                mock_setup.return_value = Mock(spec=logging.Logger)

                api = PhantomAPI()
                # The install dir should be set to parent3
                assert api.install_dir == mock_parent3

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_detect_install_dir_production_path(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/opt/phantom-wg")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()
        assert api.install_dir == Path("/opt/phantom-wg")

    @patch('pathlib.Path.resolve')
    @patch('pathlib.Path.exists')
    @patch('pathlib.Path.cwd')
    def test_detect_install_dir_fallback_cwd(self, mock_cwd, mock_exists, mock_resolve):
        mock_file, _mock_parent, _mock_parent2, mock_parent3 = self._create_mock_path_hierarchy()
        mock_resolve.return_value = mock_file

        phantom_dir = Mock(spec=Path)
        mock_parent3.__truediv__ = Mock(return_value=phantom_dir)
        phantom_dir.exists.return_value = False
        mock_exists.return_value = False

        mock_cwd.return_value = Path("/current/working/directory")

        with patch('phantom.api.core.PhantomAPI._setup_logger') as mock_setup:
            with patch('phantom.api.core.PhantomAPI._load_modules'):
                mock_setup.return_value = Mock(spec=logging.Logger)

                api = PhantomAPI()
                assert api.install_dir == Path("/current/working/directory")

    def test_setup_logger_direct_call(self):
        with patch('phantom.api.core.PhantomAPI._detect_install_dir'):
            with patch('phantom.api.core.PhantomAPI._load_modules'):
                with patch('logging.getLogger') as mock_get_logger:
                    mock_logger = Mock(spec=logging.Logger)
                    mock_logger.handlers = []  # No handlers yet
                    mock_get_logger.return_value = mock_logger

                    with patch('logging.StreamHandler') as mock_handler_class:
                        with patch('logging.Formatter') as mock_formatter_class:
                            mock_handler = Mock()
                            mock_formatter = Mock()
                            mock_handler_class.return_value = mock_handler
                            mock_formatter_class.return_value = mock_formatter

                            _ = PhantomAPI()

                            mock_get_logger.assert_called_with("phantom.api")
                            mock_handler.setFormatter.assert_called_with(mock_formatter)
                            mock_logger.addHandler.assert_called_with(mock_handler)
                            mock_logger.setLevel.assert_called_with(logging.WARNING)

    def test_setup_logger_already_configured(self):
        with patch('phantom.api.core.PhantomAPI._detect_install_dir'):
            with patch('phantom.api.core.PhantomAPI._load_modules'):
                with patch('logging.getLogger') as mock_get_logger:
                    mock_logger = Mock(spec=logging.Logger)
                    mock_logger.handlers = [Mock()]  # Already has handlers
                    mock_get_logger.return_value = mock_logger

                    _ = PhantomAPI()

                    mock_logger.addHandler.assert_not_called()
                    mock_logger.setLevel.assert_not_called()

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    def test_load_modules_warning_no_dir(self, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        with patch.object(Path, 'exists', return_value=False):
            _ = PhantomAPI()

            mock_logger.warning.assert_called()
            assert "Modules directory not found" in str(mock_logger.warning.call_args)

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    def test_load_modules_error_handling(self, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        with patch.object(Path, 'exists', return_value=True):
            with patch.object(Path, 'is_dir', return_value=True):
                with patch.object(Path, 'iterdir') as mock_iterdir:
                    mock_module = Mock(spec=Path)
                    mock_module.name = "bad_module"
                    mock_module.is_dir.return_value = True
                    mock_module.__truediv__ = lambda _self, _other: Mock(exists=Mock(return_value=True))
                    mock_iterdir.return_value = [mock_module]

                    with patch.object(PhantomAPI, '_load_module', side_effect=Exception("Load error")):
                        _ = PhantomAPI()

                        mock_logger.error.assert_called()
                        assert "Failed to load module 'bad_module'" in str(mock_logger.error.call_args)

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_load_module_no_module_class(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        api = PhantomAPI()

        with patch('importlib.import_module') as mock_import:
            mock_module = Mock()
            mock_module.SomeOtherThing = "not a class"
            mock_module.helpers = Mock()

            mock_import.return_value = mock_module

            api._load_module("empty")

            mock_logger.warning.assert_called()
            assert "No module class found in empty" in str(mock_logger.warning.call_args)
            # Module should not be loaded
            assert "empty" not in api._modules

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    @patch.dict(os.environ, {'DEBUG_MODE': '1'})
    def test_execute_debug_mode_traceback(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_logger = Mock(spec=logging.Logger)
        mock_setup.return_value = mock_logger

        api = PhantomAPI()

        mock_module = Mock()
        mock_module.execute_action.side_effect = RuntimeError("Test error")
        api._modules = {"test": mock_module}

        result = api.execute("test", "action")

        assert result.success is False
        assert result.code == "INTERNAL_ERROR"
        assert "traceback" in result.data
        assert "RuntimeError: Test error" in result.data["traceback"]

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_list_modules_extra_module(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_core = Mock()
        mock_core.get_module_description.return_value = "Core module"
        mock_core.get_actions.return_value = {}

        mock_custom = Mock()
        mock_custom.get_module_description.return_value = "Custom module"
        mock_custom.get_actions.return_value = {"custom_action": {}}

        api._modules = {"core": mock_core, "custom": mock_custom}

        result = api.list_modules()

        assert result.success is True
        assert len(result.data["modules"]) == 2
        # Core should be first (preferred order)
        assert result.data["modules"][0]["name"] == "core"
        # Custom should be second (not in preferred order)
        assert result.data["modules"][1]["name"] == "custom"

    @patch('phantom.api.core.PhantomAPI._detect_install_dir')
    @patch('phantom.api.core.PhantomAPI._setup_logger')
    @patch('phantom.api.core.PhantomAPI._load_modules')
    def test_module_info_core_special_handling(self, _mock_load_modules, mock_setup, mock_detect):
        mock_detect.return_value = Path("/test/path")
        mock_setup.return_value = Mock(spec=logging.Logger)

        api = PhantomAPI()

        mock_core = Mock()
        mock_core.get_module_name.return_value = "core"
        mock_core.get_module_description.return_value = "Core module"
        mock_core.get_actions.return_value = {
            "list_clients": Mock(__doc__="List all clients"),
            "add_client": Mock(__doc__="Add a client"),
            "remove_client": Mock(__doc__="Remove a client"),
            "export_client": Mock(__doc__="Export client config"),
            "show_stats": Mock(__doc__="Show stats")
        }

        api._modules = {"core": mock_core}

        result = api.module_info("core")

        assert result.success is True
        action_names = [a["name"] for a in result.data["actions"]]
        assert "add_client" not in action_names
        assert "remove_client" not in action_names
        assert "export_client" not in action_names
        assert "list_clients" in action_names
        assert "show_stats" in action_names
        # list_clients should have special description
        list_clients_action = next((a for a in result.data["actions"] if a["name"] == "list_clients"), None)
        assert list_clients_action is not None
        assert "Client Operations" in list_clients_action["description"]

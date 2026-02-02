#!/opt/phantom-wg/.phantom-venv/bin/python3
# noinspection DuplicatedCode
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Etkileşimli CLI
    =================================
    
    API fonksiyonlarını kullanıcı dostu menüler üzerinden sunan ana CLI arayüzü.
    Modüller dinamik olarak keşfedilir ve her modül için özel handler kullanılır.
    
    Program Akışı:
        1. Ana menüde modülleri listele
        2. Seçilen modül için handler'ı çağır
        3. Handler modüle özel UI gösterir
        4. API çağrıları yapılır ve sonuçlar gösterilir

EN: Phantom-WG Interactive CLI
    =================================
    
    Main CLI interface that presents API functions through user-friendly menus.
    Modules are discovered dynamically and each module uses a specific handler.
    
    Program Flow:
        1. List modules in main menu
        2. Call handler for selected module
        3. Handler shows module-specific UI
        4. API calls are made and results displayed

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import os
import sys
import argparse
import time
from datetime import datetime

# Rich imports
try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.prompt import Prompt, Confirm
    from rich.progress import Progress, SpinnerColumn, TextColumn

    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False
    Console = None
    Panel = None
    Prompt = None
    Confirm = None
    print("Warning: Rich library not available. Install with: pip install rich")

# Phantom imports
from phantom import __version__
from phantom.api.core import PhantomAPI

# UI imports
try:
    from phantom.cli.ui_components import UIComponents, PHANTOM_THEME

    UI_COMPONENTS_AVAILABLE = True
except ImportError:
    UIComponents = None  # type: ignore
    UI_COMPONENTS_AVAILABLE = False
    PHANTOM_THEME = None

# Module handlers
from phantom.cli.modules import HANDLERS


# noinspection DuplicatedCode
class InteractiveUI:
    """
    Simplified interactive user interface using modular handlers.

    Main Components:
        - Module discovery through API
        - Dynamic handler initialization
        - Menu-driven navigation
        - Error handling and recovery
    """

    def __init__(self):
        self.api = PhantomAPI()

        # Setup console
        if UI_COMPONENTS_AVAILABLE:
            self.ui = UIComponents()
            self.console = self.ui.console
        else:
            if RICH_AVAILABLE and Console:
                self.console = Console(theme=PHANTOM_THEME) if PHANTOM_THEME else Console()
            else:
                self.console = None
            self.ui = None

        self.running = True
        self.handlers = {}
        self._init_handlers()

    def _init_handlers(self):
        """Initialize module handlers"""
        for module_name, handler_class in HANDLERS.items():
            self.handlers[module_name] = handler_class(self.api, self.console)

    def clear_screen(self):
        """Clear the terminal screen"""
        if self.console:
            self.console.clear()
        else:
            os.system('clear' if os.name == 'posix' else 'cls')

    def print(self, message, style=None):
        """Print with optional styling"""
        if self.console and style:
            self.console.print(message, style=style)
        else:
            print(message)

    def print_panel(self, content, title=None, style="blue"):
        """Print content in a panel"""
        if self.console:
            self.console.print(Panel(content, title=title, border_style=style))
        else:
            if title:
                print(f"\n=== {title} ===")
            print(content)
            print("=" * 40)

    def print_error(self, message):
        """Print error message"""
        self.print(f"❌ Error: {message}", style="red")

    def print_success(self, message):
        """Print success message"""
        self.print(f"✅ {message}", style="green")

    # noinspection PyMethodMayBeStatic,PyProtectedMember
    def _format_bytes(self, bytes_val):
        """Format bytes to human readable format"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.1f} {unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.1f} PB"

    def display_menu(self):
        """Display main menu with Rich styling"""
        self.clear_screen()

        # Get modules
        modules_response = self.api.list_modules()
        if not modules_response.success:
            self.print_error("Failed to load modules")
            return "exit"

        modules = modules_response.data["modules"]

        if RICH_AVAILABLE and self.console:
            # Use Rich for better display
            from rich.panel import Panel
            from rich.table import Table
            from rich import box

            # Header
            self.console.print(Panel(
                "[bold cyan]Phantom-WG Control Center[/bold cyan]\n"
                "[dim]VPN Management System[/dim]",
                box=box.DOUBLE,
                border_style="cyan"
            ))

            # Create menu table
            menu = Table(
                title="Available Modules",
                box=box.ROUNDED,
                show_header=True,
                header_style="bold magenta"
            )

            menu.add_column("#", style="bold yellow", width=4)
            menu.add_column("Module", style="cyan")
            menu.add_column("Description", style="dim")

            # Module display info
            module_info = {
                "core": ("Core Management", "WireGuard client and server management"),
                "dns": ("DNS Management", "Configure DNS servers"),
                "multihop": ("Multihop VPN", "Route traffic through external VPN providers"),
                "ghost": ("Ghost Mode", "Censorship-resistant connections using wstunnel"),
                "reset": ("Factory Reset", "Reset system to defaults")
            }

            # Add modules to menu
            for i, module in enumerate(modules, 1):
                name, desc = module_info.get(module['name'], (module['name'].upper(), module['description']))
                menu.add_row(str(i), name, desc)

            menu.add_row("0", "Exit", "Return to shell")

            self.console.print(menu)

            # Get choice
            choice = Prompt.ask("\n[bold yellow]Select module[/bold yellow]", default="0")

        else:
            # Fallback to simple display
            self.clear_screen()
            self.print("🚀 Phantom-WG Interactive Console", style="bold")
            self.print("=" * 50)

            modules_response = self.api.list_modules()
            if not modules_response.success:
                self.print_error("Failed to load modules")
                return "exit"

            modules = modules_response.data["modules"]

            self.print("\nAvailable Modules:", style="bold")

            module_display_names = {
                "core": "Core Management",
                "dns": "DNS Management",
                "multihop": "Multihop VPN",
                "ghost": "Ghost Mode",
                "reset": "Factory Reset"
            }

            for i, module in enumerate(modules, 1):
                display_name = module_display_names.get(module['name'], module['name'].upper())
                self.print(f"  {i}. {display_name} - {module['description']}")

            self.print(f"\n  0. Exit")
            choice = input("\nSelect module (0 to exit): ")

        # Process choice
        if choice == "0":
            return "exit"

        try:
            idx = int(choice) - 1
            if 0 <= idx < len(modules):
                return modules[idx]["name"]
        except ValueError:
            pass

        self.print_error("Invalid selection")
        return None

    def display_module_menu(self, module_name):  # noinspection PyShadowingNames
        """Display module actions menu"""
        self.clear_screen()

        # Get module info
        info_response = self.api.module_info(module_name)
        if not info_response.success:
            self.print_error(f"Failed to load module info: {info_response.error}")
            return None

        module_data = info_response.data
        actions = module_data["actions"]

        # Special display for Core module
        if module_name == "core":
            return self._display_core_menu(module_data, actions)

        # Special display for DNS module
        if module_name == "dns":
            return self._display_dns_menu(module_data, actions)

        # Special display for Ghost module
        if module_name == "ghost":
            return self._display_ghost_menu(module_data, actions)

        # Display with Rich if available
        if RICH_AVAILABLE and self.console:
            from rich.panel import Panel
            from rich.table import Table
            from rich import box

            module_display_name = {
                "dns": "DNS Management",
                "multihop": "Multihop VPN",
                "ghost": "Ghost Mode",
                "reset": "Factory Reset"
            }.get(module_name, module_name.upper())

            # Header
            self.console.print(Panel(
                f"[bold cyan]{module_display_name}[/bold cyan]\n"
                f"[dim]{module_data['description']}[/dim]",
                box=box.DOUBLE,
                border_style="green"
            ))

            # Create actions table
            table = Table(
                title="Available Actions",
                box=box.ROUNDED,
                show_header=True,
                header_style="bold magenta"
            )

            table.add_column("#", style="bold yellow", width=4)
            table.add_column("Action", style="cyan")
            table.add_column("Description", style="dim")

            # Define action info for multihop module
            if module_name == "multihop":
                multihop_action_info = {
                    "enable_multihop": ("Enable Multihop", "Route traffic through external VPN exit node"),
                    "disable_multihop": ("Disable Multihop", "Route traffic directly through WireGuard"),
                    "import_vpn_config": ("Import VPN Config", "Add external VPN as multihop exit node"),
                    "remove_vpn_config": ("Remove VPN Config", "Delete configured exit node"),
                    "list_exits": ("List Exits", "View configured multihop exit points"),
                    "status": ("Status", "Current multihop routing configuration"),
                    "test_vpn": ("Test VPN", "Check multihop exit node connectivity"),
                    "reset_state": ("Reset State", "Clear all multihop configurations"),
                    "get_session_log": ("Session Log", "Live monitoring of multihop activity")
                }

                action_idx = 1

                for action in actions:
                    name = action["name"]
                    if name in multihop_action_info:
                        title, desc = multihop_action_info[name]
                        table.add_row(str(action_idx), title, desc)
                        action_idx += 1
            else:
                for i, action in enumerate(actions, 1):
                    table.add_row(str(i), action['name'].replace('_', ' ').title(), action['description'])

            table.add_row("0", "Back", "Return to main menu")

            self.console.print(table)
            choice = Prompt.ask("\n[bold yellow]Select action[/bold yellow]", default="0")
        else:
            # Fallback display
            self.clear_screen()
            self.print(f"📦 {module_name.upper()} Module", style="bold")
            self.print(f"Description: {module_data['description']}")
            self.print("\nAvailable Actions:")

            for i, action in enumerate(actions, 1):
                self.print(f"  {i}. {action['name']} - {action['description']}")

            self.print(f"\n  0. Back to main menu")
            choice = input("\nSelect action (0 to go back): ")

        if choice == "0":
            return "back"

        try:
            idx = int(choice) - 1
            if 0 <= idx < len(actions):
                return actions[idx]["name"]
        except ValueError:
            pass

        self.print_error("Invalid selection")
        return None

    def execute_action(self, module, action):  # noinspection PyShadowingNames
        """Execute a module action using the appropriate handler"""
        # Get handler
        handler = self.handlers.get(module)
        if not handler:
            self.print_error(f"No handler found for module: {module}")
            return

        # Debug print
        if os.environ.get('DEBUG_MODE'):
            self.print(f"\n[dim]Debug: Executing {module}.{action}[/dim]")

        # Get action parameters from handler
        try:
            kwargs = handler.handle_action(action)
        except Exception as e:
            self.print_error(f"Handler error: {str(e)}")
            if os.environ.get('DEBUG_MODE'):
                import traceback
                traceback.print_exc()
            input("\nPress Enter to continue...")
            return

        if kwargs is None:
            # User cancelled
            return

        # Debug print kwargs
        if os.environ.get('DEBUG_MODE'):
            self.print(f"[dim]Debug: kwargs = {kwargs}[/dim]")

        # Ensure kwargs is a dict for special checks
        if not isinstance(kwargs, dict):
            kwargs = {}

        # Check for special handlers
        if kwargs.get("_special") == "client_operations":
            # This is the client operations menu - it manages its own loop
            self._run_client_operations_menu(handler)
            return
        elif kwargs.get("_special") == "server_status":
            # This is the server status view - it needs custom display
            self._run_server_status_view(handler)
            return
        elif kwargs.get("_special") == "live_log":
            # This is the live log view for multihop
            self._run_live_log_view(module, action, kwargs)
            return

        # Alternative check for multihop session log
        if module == "multihop" and action == "get_session_log":
            self._run_live_log_view(module, action, kwargs)
            return  # Important: return here to prevent further execution

        # Special case for list_clients with pagination (legacy support)
        if module == "core" and action == "list_clients" and "_special" not in kwargs:
            response = self.api.execute(module, action, **kwargs)
            if response.success:
                handler.display_clients_with_pagination(response)
            else:
                self.display_response(response)
            return

        # Remove _special flag from kwargs before API call
        clean_kwargs = {k: v for k, v in kwargs.items() if k != "_special"}

        # Execute action with progress indicator
        if self.ui:
            def execute_task():
                return self.api.execute(module, action, **clean_kwargs)

            try:
                response = self.ui.show_spinner(f"Executing {action}...", execute_task)
            except Exception as e:
                self.ui.show_error(f"Operation failed: {str(e)}")
                return
        else:
            self.print(f"Executing {action}...")
            response = self.api.execute(module, action, **clean_kwargs)

        # Display response
        self.print("")  # Empty line

        # Special handling for DNS module
        if module == "dns":
            if action == "status":
                self._display_dns_status(response)
            elif action == "get_dns_servers":
                self._display_dns_servers(response)
            else:
                self.display_response(response)
        # Special handling for Reset module
        elif module == "reset" and action == "factory_reset":
            handler = self.handlers.get("reset")  # noinspection PyShadowingNames
            if handler and hasattr(handler, 'display_reset_result'):
                handler.display_reset_result(response)
                return  # Don't wait for Enter since we're rebooting
            else:
                self.display_response(response)
        # Special handling for Core module export_client
        elif module == "core" and action == "export_client":
            handler = self.handlers.get("core")  # noinspection PyShadowingNames
            if handler and hasattr(handler, 'display_export_client'):
                handler.display_export_client(response)
            else:
                self.display_response(response)
        else:
            self.display_response(response)

        # Refresh API for critical actions
        if action in ['change_dns_servers', 'disable', 'enable', 'factory_reset']:
            self.api = PhantomAPI()
            # Refresh handlers
            self._init_handlers()

        # Wait
        if RICH_AVAILABLE:
            Prompt.ask("\nPress Enter to continue")
        else:
            input("\nPress Enter to continue...")

    def display_response(self, response):
        """Display API response in a user-friendly format"""
        if response.success:
            if isinstance(response.data, dict):
                self._display_dict(response.data)
            elif isinstance(response.data, list):
                self._display_list(response.data)
            else:
                self.print_success(str(response.data))
        else:
            self.print_error(f"{response.error} (Code: {response.code})")
            if response.data:
                self.print("\nAdditional Information:")
                self._display_dict(response.data)

    def _display_dict(self, data, indent=0):
        """Display dictionary data"""
        prefix = "  " * indent
        for key, value in data.items():
            if isinstance(value, dict):
                self.print(f"{prefix}{key}:")
                self._display_dict(value, indent + 1)
            elif isinstance(value, list):
                self.print(f"{prefix}{key}:")
                for item in value:
                    if isinstance(item, dict):
                        self._display_dict(item, indent + 1)
                    else:
                        self.print(f"{prefix}  - {item}")
            else:
                self.print(f"{prefix}{key}: {value}")

    def _display_list(self, data):
        """Display list data"""
        if not data:
            self.print("No items found.")
            return

        for item in data:
            if isinstance(item, dict):
                self._display_dict(item)
                self.print("")  # Empty line between items
            else:
                self.print(f"- {item}")

    def _run_client_operations_menu(self, handler):  # noinspection PyProtectedMember
        """Run the client operations menu loop"""
        current_page = 1
        per_page = 10
        search_term = ""

        while True:
            self.clear_screen()

            if RICH_AVAILABLE and self.console:
                from rich.panel import Panel
                from rich.table import Table
                from rich import box

                # Header
                self.console.print(Panel(
                    "[bold cyan]👥 Client Operations[/bold cyan]\n"
                    "[dim]Manage WireGuard VPN Clients[/dim]",
                    box=box.DOUBLE,
                    border_style="cyan"
                ))
            else:
                self.print("👥 Client Operations")
                self.print("=" * 50)

            # Get clients list with pagination
            kwargs = {"page": current_page, "per_page": per_page}
            if search_term:
                kwargs["search"] = search_term

            response = self.api.execute("core", "list_clients", **kwargs)
            if not response.success:
                self.print_error(f"Failed to get clients: {response.error}")
                if RICH_AVAILABLE:
                    Prompt.ask("\nPress Enter to continue")
                else:
                    input("\nPress Enter to continue...")
                return

            clients = response.data.get("clients", [])
            pagination = response.data.get("pagination", {})
            total_pages = pagination.get("total_pages", 1)
            total_clients = response.data.get("total", 0)

            # Display clients table
            if RICH_AVAILABLE and self.console:
                from rich.table import Table  # noinspection PyUnresolvedReferences
                # Create clients table
                clients_table = Table(
                    title="WireGuard Clients",
                    show_header=True,
                    header_style="bold magenta"
                )

                # Add columns
                clients_table.add_column("#", style="dim", width=4)
                clients_table.add_column("Name", style="cyan")
                clients_table.add_column("IP Address", style="yellow")
                clients_table.add_column("Status", justify="center")
                clients_table.add_column("Last Seen")
                clients_table.add_column("Data Transfer", justify="right")

                if not clients:
                    clients_table.add_row("", "[dim]No clients configured[/dim]", "", "", "", "")
                else:
                    for idx, client in enumerate(clients, 1):
                        # Determine status
                        if not client.get('enabled', True):
                            status = "[yellow]●[/yellow] Disabled"
                            last_seen = "N/A"
                            transfer = "N/A"
                        elif client.get('connected'):
                            status = "[green]●[/green] Connected"
                            conn = client.get('connection', {})
                            last_seen = conn.get('latest_handshake', 'Unknown')
                            rx = self._format_bytes(conn.get('transfer', {}).get('rx', 0))
                            tx = self._format_bytes(conn.get('transfer', {}).get('tx', 0))
                            transfer = f"↓ {rx} / ↑ {tx}"
                        else:
                            status = "[red]●[/red] Offline"
                            last_seen = "N/A"
                            transfer = "↓ 0 B / ↑ 0 B"

                        clients_table.add_row(
                            str(idx),
                            client.get('name', 'Unknown'),
                            client.get('ip', 'N/A'),
                            status,
                            last_seen,
                            transfer
                        )

                # Navigation info
                nav_text = ""
                if total_pages > 1:
                    nav_text = f"Page {current_page} of {total_pages} | "
                nav_text += f"Total: {total_clients}"
                if search_term:
                    nav_text += f" | Filter: '{search_term}'"

                self.console.print(clients_table)
                self.console.print(f"\n[dim]{nav_text}[/dim]")
            else:
                # Fallback display - use existing handler method
                if not clients:
                    self.print("\nNo clients configured.", style="yellow")
                else:
                    # noinspection PyProtectedMember
                    handler._display_clients_operations_table(clients)

            # Show pagination and search info
            self.print("\n" + "─" * 80)

            # Build navigation and status on single line
            nav_parts = []

            # Navigation controls
            if current_page > 1:
                nav_parts.append("[P]revious")
            if current_page < total_pages:
                nav_parts.append("[N]ext")
            if total_pages > 1:
                nav_parts.append(f"[G]o to ({current_page}/{total_pages})")
            nav_parts.append("[S]earch")
            if search_term:
                nav_parts.append("[C]lear")
            nav_parts.append("[R]efresh")

            # Status info
            status_info = f"Total: {total_clients}"
            if search_term:
                status_info += f" | Filter: '{search_term}'"

            # Combine on one line
            nav_line = " | ".join(nav_parts) + "  ║  " + status_info
            self.print(nav_line)
            self.print("─" * 80)

            # Show operations menu
            self.print("\nClient Operations:")
            self.print("  1. Add new client")
            self.print("  2. Remove client")
            self.print("  3. Export client config")
            self.print("  0. Back to main menu")

            if RICH_AVAILABLE:
                choice = Prompt.ask("\nSelect operation or use navigation keys", default="0")
            else:
                choice = input("\nSelect operation or use navigation keys (0): ")

            # Convert to lowercase for navigation keys
            choice_lower = choice.lower()

            # Handle navigation keys
            if choice_lower == "p" and current_page > 1:
                current_page -= 1
                continue
            elif choice_lower == "n" and current_page < total_pages:
                current_page += 1
                continue
            elif choice_lower == "g" and total_pages > 1:
                page_num = handler.prompt(f"\nEnter page number (1-{total_pages})")
                try:
                    page = int(page_num)
                    if 1 <= page <= total_pages:
                        current_page = page
                    else:
                        self.print_error(f"Invalid page number. Must be between 1 and {total_pages}")
                        if RICH_AVAILABLE:
                            Prompt.ask("\nPress Enter to continue")
                        else:
                            input("\nPress Enter to continue...")
                except ValueError:
                    self.print_error("Invalid page number")
                    if RICH_AVAILABLE:
                        Prompt.ask("\nPress Enter to continue")
                    else:
                        input("\nPress Enter to continue...")
                continue
            elif choice_lower == "s":
                new_search = handler.prompt("\nEnter search term (name or IP)")
                if new_search:
                    search_term = new_search
                    current_page = 1  # Reset to first page on new search
                else:
                    search_term = ""
                continue
            elif choice_lower == "c" and search_term:
                search_term = ""
                current_page = 1
                continue
            elif choice_lower == "r":
                continue  # Refresh

            # Handle numeric choices
            if choice == "0":
                return
            elif choice == "1":
                # Add client - inline without clearing screen
                self.print("\n" + "─" * 50)
                client_name = handler.prompt("Enter new client name")
                if client_name:
                    # Show spinner or progress
                    if self.ui and hasattr(self.ui, 'show_spinner'):
                        def add_task():
                            return self.api.execute("core", "add_client", client_name=client_name)

                        try:
                            response = self.ui.show_spinner(f"Adding client '{client_name}'...", add_task)
                        except KeyboardInterrupt:
                            self.print_error("\nOperation cancelled by user")
                            if RICH_AVAILABLE:
                                Prompt.ask("\nPress Enter to continue")
                            else:
                                input("\nPress Enter to continue...")
                            continue
                    else:
                        self.print(f"\n⏳ Adding client '{client_name}'...")
                        response = self.api.execute("core", "add_client", client_name=client_name)

                    if response.success:
                        self.print_success(f"Client '{client_name}' added successfully!")

                        # Show client details from response
                        if response.data:
                            client_info = response.data.get('client', {})
                            if client_info and client_info.get('ip'):
                                self.print(f"   Assigned IP: {client_info.get('ip')}")

                        # Auto-refresh by continuing the loop
                        if RICH_AVAILABLE:
                            Prompt.ask("\nPress Enter to refresh")
                        else:
                            input("\nPress Enter to refresh...")
                        continue
                    else:
                        self.print_error(f"Failed to add client: {response.error}")
                        if RICH_AVAILABLE:
                            Prompt.ask("\nPress Enter to continue")
                        else:
                            input("\nPress Enter to continue...")
            elif choice == "2":
                # Remove client
                # noinspection PyProtectedMember
                result = handler._handle_remove_from_table(clients)
                if result:
                    if RICH_AVAILABLE:
                        Prompt.ask("\nPress Enter to continue")
                    else:
                        input("\nPress Enter to continue...")
            elif choice == "3":
                # Export client
                # noinspection PyProtectedMember
                result = handler._handle_export_from_table(clients)
                if result:
                    if RICH_AVAILABLE:
                        Prompt.ask("\nPress Enter to continue")
                    else:
                        input("\nPress Enter to continue...")
            else:
                self.print_error("Invalid selection")
                if RICH_AVAILABLE:
                    Prompt.ask("\nPress Enter to continue")
                else:
                    input("\nPress Enter to continue...")

    # noinspection PyProtectedMember, PyUnusedLocal
    def _run_server_status_view(self, handler):
        """Run the server status view with summary and detail options"""
        while True:
            self.clear_screen()

            if RICH_AVAILABLE and self.console:
                from rich.panel import Panel
                from rich import box

                # Header
                self.console.print(Panel(
                    "[bold cyan]📊 WireGuard Server Status[/bold cyan]\n"
                    "[dim]Real-time server monitoring and statistics[/dim]",
                    box=box.DOUBLE,
                    border_style="cyan"
                ))
            else:
                self.print("📊 WireGuard Server Status")
                self.print("=" * 60)

            # Get server status
            response = self.api.execute("core", "server_status")
            if not response.success:
                self.print_error(f"Failed to get server status: {response.error}")
                if RICH_AVAILABLE:
                    Prompt.ask("\nPress Enter to continue")
                else:
                    input("\nPress Enter to continue...")
                return

            status_data = response.data

            # Show summary
            self.print("\n🔍 Summary")
            self.print("─" * 40)

            # Service status
            service = status_data.get("service", {})
            if service.get("running"):
                self.print("✅ Service Status: Running", style="green")
            else:
                self.print("❌ Service Status: Stopped", style="red")

            # Interface status
            interface = status_data.get("interface", {})
            config = status_data.get("configuration", {})

            if interface.get("active"):
                self.print("🌐 Interface: Up", style="green")
                # Get address from configuration network field
                network = config.get('network', 'N/A')
                if network != 'N/A' and '/' in network:
                    # Extract base network and add .1 for server
                    base_network = network.split('/')[0]
                    prefix = network.split('/')[1]
                    # Replace last octet with 1
                    octets = base_network.split('.')
                    octets[-1] = '1'
                    address = '.'.join(octets) + '/' + prefix
                else:
                    address = 'N/A'
                self.print(f"   Address: {address}")
                # Use port from interface or configuration
                port = interface.get('port') or config.get('port', 'N/A')
                self.print(f"   Port: {port}")
            else:
                self.print("🌐 Interface: Down", style="red")

            # Client statistics from interface data
            clients = status_data.get("clients", {})
            total_configured = clients.get('total_configured', 0)
            active_connections = clients.get('active_connections', 0)
            total_peers = interface.get("total_peers", 0)
            active_peers = interface.get("active_peers", 0)

            self.print(f"\n👥 Total Clients: {total_configured}")
            self.print(f"   🟢 Connected: {active_connections}")
            self.print(f"   🟡 Disconnected: {total_configured - active_connections}")

            # Total data transfer
            total_rx = 0
            total_tx = 0
            if "peers" in interface:
                for peer in interface.get("peers", []):
                    transfer = peer.get("transfer", {})
                    total_rx += transfer.get("rx", 0)
                    total_tx += transfer.get("tx", 0)

            if total_rx > 0 or total_tx > 0:
                from .modules.core_handler import CoreUIHandler
                handler_temp = CoreUIHandler(None, None)
                rx_formatted = handler_temp._format_bytes(total_rx)  # noinspection PyProtectedMember
                tx_formatted = handler_temp._format_bytes(total_tx)  # noinspection PyProtectedMember
                self.print(f"\n📊 Total Data Transfer:")
                self.print(f"   ↓ {rx_formatted} / ↑ {tx_formatted}")

            # Detail options menu
            self.print("\n" + "─" * 60)
            self.print("\nOptions:")
            self.print("  1. View Detailed System Information")
            self.print("  2. Refresh Status")
            self.print("  0. Back to main menu")

            if RICH_AVAILABLE:
                choice = Prompt.ask("\nSelect option", default="0")
            else:
                choice = input("\nSelect option (0): ")

            if choice == "0":
                return
            elif choice == "1":
                # Show detailed system info
                self._show_detailed_system_info(status_data)
            elif choice == "2":
                # Refresh - just continue the loop
                continue
            else:
                self.print_error("Invalid selection")
                if RICH_AVAILABLE:
                    Prompt.ask("\nPress Enter to continue")
                else:
                    input("\nPress Enter to continue...")

    def _show_detailed_system_info(self, status_data):  # noinspection PyProtectedMember
        """Show detailed system and interface information"""
        self.clear_screen()

        if RICH_AVAILABLE and self.console:
            from rich.panel import Panel
            from rich import box

            # Header
            self.console.print(Panel(
                "[bold cyan]🖥️  Detailed System Information[/bold cyan]\n"
                "[dim]Complete server and interface details[/dim]",
                box=box.DOUBLE,
                border_style="cyan"
            ))
        else:
            self.print("🖥️  Detailed System Information")
            self.print("=" * 60)

        # Service Information
        service = status_data.get("service", {})
        self.print("\n🔧 Service Status:")
        self.print(f"  Status: {'Running' if service.get('running', False) else 'Stopped'}")
        self.print(f"  Service Name: {service.get('service', 'N/A')}")
        if service.get('pid'):
            self.print(f"  Process ID: {service.get('pid', 'N/A')}")
        if service.get('started_at'):
            self.print(f"  Started At: {service.get('started_at', 'N/A')}")

        # Interface Information
        interface = status_data.get("interface", {})
        peers = interface.get("peers", [])
        total_peers = len(peers)
        self.print("\n🌐 Interface Details:")
        self.print(f"  Interface Name: {interface.get('interface', 'N/A')}")
        self.print(f"  Active: {'Yes' if interface.get('active', False) else 'No'}")
        self.print(f"  Public Key: {interface.get('public_key', 'N/A')[:20]}..." if interface.get(
            'public_key') else "  Public Key: N/A")
        self.print(f"  Listen Port: {interface.get('port', 'N/A')}")
        self.print(f"  Total Peers: {total_peers}")

        # Peer Details (paginated if many)
        peers = interface.get("peers", [])
        if peers:
            self.print("\n👥 Peer Information:")
            self.print("─" * 60)

            # Show first 10 peers
            for idx, peer in enumerate(peers[:10], 1):
                self.print(f"\nPeer {idx}:")
                self.print(f"  Public Key: {peer.get('public_key', 'N/A')[:20]}..." if peer.get(
                    'public_key') else "  Public Key: N/A")
                self.print(f"  Allowed IPs: {peer.get('allowed_ips', 'N/A')}")

                if peer.get('endpoint'):
                    self.print(f"  Endpoint: {peer.get('endpoint', 'N/A')}")
                    self.print(f"  Last Handshake: {peer.get('latest_handshake', 'N/A')}")
                    self.print(f"  Status: 🟢 Connected")

                    transfer = peer.get("transfer", {})
                    if transfer:
                        from .modules.core_handler import CoreUIHandler
                        handler_temp = CoreUIHandler(None, None)
                        # noinspection PyProtectedMember
                        rx = handler_temp._format_bytes(transfer.get("received_bytes", 0))
                        # noinspection PyProtectedMember
                        tx = handler_temp._format_bytes(transfer.get("sent_bytes", 0))
                        self.print(f"  Data: ↓ {rx} / ↑ {tx}")
                else:
                    self.print(f"  Status: 🔴 Not Connected")

            if len(peers) > 10:
                self.print(f"\n... and {len(peers) - 10} more peers")

        # Configuration Details
        config = status_data.get("configuration", {})
        self.print("\n⚙️  Configuration:")
        self.print(f"  Network: {config.get('network', 'N/A')}")
        self.print(f"  DNS Servers: {', '.join(config.get('dns', []))}")
        self.print(f"  Config File: {config.get('config_file', 'N/A')}")

        # System Information
        system = status_data.get("system", {})
        self.print("\n📁 System Paths:")
        self.print(f"  Install Directory: {system.get('install_dir', 'N/A')}")
        self.print(f"  Config Directory: {system.get('config_dir', 'N/A')}")
        self.print(f"  Data Directory: {system.get('data_dir', 'N/A')}")
        self.print(f"  Firewall Status: {system.get('firewall', 'N/A')}")

        if RICH_AVAILABLE:
            Prompt.ask("\nPress Enter to continue")
        else:
            input("\nPress Enter to continue...")

    def _display_core_menu(self, module_data, actions):  # noinspection PyProtectedMember
        """Display Core module menu"""
        self.clear_screen()

        if RICH_AVAILABLE and self.console:
            from rich.panel import Panel
            from rich.table import Table
            from rich import box

            # Header
            self.console.print(Panel(
                "[bold cyan]⚡ WireGuard Core Management[/bold cyan]\n"
                f"[dim]{module_data['description']}[/dim]",
                box=box.DOUBLE,
                border_style="green"
            ))

            # Create content table
            table = Table(
                title="Available Actions",
                box=box.ROUNDED,
                show_header=True,
                header_style="bold magenta"
            )

            table.add_column("#", style="bold yellow", width=4)
            table.add_column("Action", style="cyan")
            table.add_column("Description", style="dim")
        else:
            # Fallback header
            self.print("⚡ WireGuard Core Management", style="bold")
            self.print("═" * 60)
            self.print(f"{module_data['description']}", style="dim")

        # Define action categories and descriptions
        action_info = {
            "list_clients": {
                "title": "Client Operations",
                "desc": "Add, remove, export and manage all VPN clients",
                "category": "client"
            },
            "server_status": {
                "title": "Server Status",
                "desc": "View detailed server statistics and connection info",
                "category": "monitor"
            },
            "service_logs": {
                "title": "Service Logs",
                "desc": "View WireGuard service logs for troubleshooting",
                "category": "monitor"
            },
            "latest_clients": {
                "title": "Recent Clients",
                "desc": "Display recently added clients with their status",
                "category": "client"
            },
            "restart_service": {
                "title": "Restart Service",
                "desc": "Restart WireGuard service (disconnects all clients)",
                "category": "admin"
            },
            "get_firewall_status": {
                "title": "Firewall & Security",
                "desc": "View firewall rules and security configuration",
                "category": "admin"
            },
            "get_tweak_settings": {
                "title": "Tweak Settings",
                "desc": "Configure advanced behavior settings",
                "category": "admin"
            },
            "get_subnet_info": {
                "title": "Change Default Subnet",
                "desc": "Modify VPN network subnet (requires validation)",
                "category": "admin"
            }
        }

        action_idx = 1
        action_map = {}

        if RICH_AVAILABLE and self.console:
            # Add all actions to table without section headers
            # Add actions in order: client, monitor, admin
            categories_order = ["client", "monitor", "admin"]

            for category in categories_order:
                for action in actions:
                    name = action["name"]
                    if name in action_info and action_info[name]["category"] == category:
                        info = action_info[name]
                        # noinspection PyUnboundLocalVariable
                        table.add_row(str(action_idx), info['title'], info['desc'])
                        action_map[str(action_idx)] = name
                        action_idx += 1

            table.add_row("0", "Back", "Return to main menu")  # noinspection PyUnboundLocalVariable

            self.console.print(table)  # noinspection PyUnboundLocalVariable
            choice = Prompt.ask("\n[bold yellow]Select option[/bold yellow]", default="0")
        else:
            # Fallback display without section headers
            self.print("\nAvailable Actions:")
            self.print("─" * 50)

            # Add actions in order: client, monitor, admin
            categories_order = ["client", "monitor", "admin"]

            for category in categories_order:
                for action in actions:
                    name = action["name"]
                    if name in action_info and action_info[name]["category"] == category:
                        info = action_info[name]
                        self.print(f"  {action_idx}. {info['title']}")
                        self.print(f"     {info['desc']}", style="dim")
                        action_map[str(action_idx)] = name
                        action_idx += 1

            self.print("\n" + "─" * 50)
            self.print("  0. Back to main menu")

            choice = input("\nSelect an option (0): ")

        if choice == "0":
            return "back"

        if choice in action_map:
            return action_map[choice]

        self.print_error("Invalid selection")
        return None

    def _run_live_log_view(self, module, action, kwargs):
        """Display live updating log view"""
        lines = int(kwargs.get("lines", 50))

        if RICH_AVAILABLE and self.console:
            from rich.table import Table
            from rich.panel import Panel
            from rich import box

            # Remove _special from kwargs
            clean_kwargs = {k: v for k, v in kwargs.items() if k != "_special"}

            def create_log_display():
                """Create the log display table"""
                try:
                    # Get data
                    # noinspection PyShadowingNames
                    response = self.api.execute(module, action, **clean_kwargs)

                    if not response.success:
                        return Panel(
                            f"[red]Error: {response.error}[/red]",
                            title="📄 Session Log Error",
                            border_style="red"
                        )

                    data = response.data
                    # noinspection PyShadowingNames
                    log_lines = data.get("log_lines", [])
                except Exception as e:
                    return Panel(
                        f"[red]Error in create_log_display: {str(e)}[/red]",
                        title="📄 Session Log Error",
                        border_style="red"
                    )

                # Create table
                table = Table(
                    title=f"📄 Multihop Session Log (Last {lines} lines)",
                    box=box.SIMPLE,
                    show_header=True,
                    header_style="bold magenta"
                )

                table.add_column("Time", style="cyan", width=20)
                table.add_column("Level", width=8)
                table.add_column("Message", style="white")

                # Add log lines
                if not log_lines:
                    table.add_row(
                        datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                        "INFO",
                        "[dim]No log entries yet...[/dim]"
                    )
                else:
                    # Get the last N lines
                    display_lines = log_lines[-lines:] if len(log_lines) > lines else log_lines
                    # noinspection PyShadowingNames
                    for line in display_lines:
                        # Parse log line (assuming format: timestamp [level] message)
                        if isinstance(line, dict):
                            timestamp = line.get("timestamp", "")
                            level = line.get("level", "INFO")
                            message = line.get("message", "")
                        else:
                            # Simple string parsing
                            parts = str(line).split(" ", 2)
                            if len(parts) >= 3:
                                timestamp = parts[0] + " " + parts[1]
                                level = "INFO"
                                message = parts[2]
                            else:
                                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                                level = "INFO"
                                message = str(line)

                        # Style based on level
                        level_style = {
                            "ERROR": "[red]ERROR[/red]",
                            "WARN": "[yellow]WARN[/yellow]",
                            "INFO": "[green]INFO[/green]",
                            "DEBUG": "[dim]DEBUG[/dim]"
                        }.get(level.upper(), level)

                        table.add_row(timestamp, level_style, message)

                # Add footer with monitor info
                monitor_status = data.get("monitor_status", {})
                active_exit = data.get("active_exit", "Unknown")
                footer = f"[green]• Monitoring: {active_exit}[/green]"

                # Add monitor details if available
                if isinstance(monitor_status, dict) and monitor_status.get("monitoring"):
                    footer += f" | PID: {monitor_status.get('pid', 'N/A')}"

                return Panel(
                    table,
                    title="📄 Live Session Monitor",
                    subtitle=footer,
                    border_style="cyan"
                )

            # Display with auto-refresh
            self.print("\n[dim]Loading live log view... Press Ctrl+C to exit[/dim]\n")

            try:
                # noinspection PyUnusedLocal
                last_update = time.time()

                while True:
                    # Clear and redraw
                    self.clear_screen()

                    # Get data
                    response = self.api.execute(module, action, **clean_kwargs)

                    if not response.success:
                        self.console.print(Panel(
                            f"[red]Error: {response.error}[/red]",
                            title="📄 Session Log Error",
                            border_style="red"
                        ))
                        break

                    # Display the log
                    self.console.print(create_log_display())

                    # Show update time
                    self.console.print(
                        f"\n[dim]Last updated: {datetime.now().strftime('%H:%M:%S')} - Refreshing every 15 seconds[/dim]")
                    self.console.print("[dim]Press Ctrl+C to exit[/dim]")

                    # Wait for next update
                    time.sleep(15)

            except KeyboardInterrupt:
                if self.console:
                    self.console.print("\n[yellow]Exiting log view...[/yellow]")
                else:
                    print("\nExiting log view...")
                time.sleep(0.5)  # Brief pause to show message

        else:
            # Fallback to simple display with manual refresh
            self.print("\n📄 Session Log (Press Ctrl+C to exit)")
            self.print("=" * 60)

            try:
                while True:
                    # Get log data
                    response = self.api.execute(module, action, **{k: v for k, v in kwargs.items() if k != "_special"})

                    if response.success:
                        self.clear_screen()
                        self.print("📄 Session Log")
                        self.print("=" * 60)

                        log_lines = response.data.get("log_lines", [])
                        if log_lines:
                            for line in log_lines[-lines:]:
                                self.print(line)
                        else:
                            self.print("No log entries yet...")

                        self.print("\nPress Ctrl+C to exit")
                    else:
                        self.print_error(f"Failed to get log: {response.error}")
                        break

                    # Wait before refresh
                    time.sleep(15)

            except KeyboardInterrupt:
                self.print("\nExiting log view...")

    def _display_dns_status(self, response):
        """Display DNS status in a formatted way"""
        if not response.success:
            self.display_response(response)
            return

        data = response.data

        if RICH_AVAILABLE and self.console:
            from rich.table import Table
            from rich.panel import Panel
            from rich import box

            # Configuration table
            config_table = Table(
                title="🌐 Current Configuration",
                box=box.SIMPLE,
                show_header=False
            )
            config_table.add_column("Setting", style="cyan")
            config_table.add_column("Value", style="yellow")

            config = data.get("configuration", {})
            config_table.add_row("Primary DNS", config.get("primary", "N/A"))
            config_table.add_row("Secondary DNS", config.get("secondary", "N/A"))
            config_table.add_row("Mode", data.get("mode", "standard").title())

            self.console.print(config_table)

            # Health status
            health = data.get("health", {})
            status = health.get("status", "unknown")

            if status == "healthy":
                status_icon = "✅"
                status_style = "green"
            elif status == "degraded":
                status_icon = "⚠️"
                status_style = "yellow"
            else:
                status_icon = "❌"
                status_style = "red"

            self.console.print(f"\n{status_icon} Health Status: [{status_style}]{status.upper()}[/{status_style}]")

            # Test results if available
            test_results = health.get("test_results", [])
            if test_results:
                self.console.print("\n🔍 DNS Test Results:")
                for result in test_results:
                    server = result.get("server", "N/A")
                    tests = result.get("tests", [])

                    passed = sum(1 for test in tests if test.get("success", False))
                    total = len(tests)

                    if passed == total:
                        test_status = f"[green]✓ {passed}/{total} tests passed[/green]"
                    elif passed > 0:
                        test_status = f"[yellow]⚠ {passed}/{total} tests passed[/yellow]"
                    else:
                        test_status = f"[red]✗ {passed}/{total} tests passed[/red]"

                    self.console.print(f"  • {server}: {test_status}")
        else:
            # Fallback display
            self.print("\n🌐 Current Configuration:")
            self.print("-" * 40)

            config = data.get("configuration", {})
            self.print(f"Primary DNS:   {config.get('primary', 'N/A')}")
            self.print(f"Secondary DNS: {config.get('secondary', 'N/A')}")
            self.print(f"Mode:          {data.get('mode', 'standard').title()}")

            health = data.get("health", {})
            status = health.get("status", "unknown")

            self.print(f"\nHealth Status: {status.upper()}")

            test_results = health.get("test_results", [])
            if test_results:
                self.print("\nDNS Test Results:")
                for result in test_results:
                    server = result.get("server", "N/A")
                    tests = result.get("tests", [])
                    passed = sum(1 for test in tests if test.get("success", False))
                    total = len(tests)
                    self.print(f"  • {server}: {passed}/{total} tests passed")

    def _display_dns_servers(self, response):
        """Display current DNS servers in a clean format"""
        if not response.success:
            self.display_response(response)
            return

        data = response.data

        if RICH_AVAILABLE and self.console:
            from rich.table import Table
            from rich.panel import Panel
            from rich import box

            # DNS servers table
            table = Table(
                title="🌍 Active DNS Configuration",
                box=box.ROUNDED,
                show_header=False,
                padding=(0, 2)
            )
            table.add_column("Type", style="cyan", width=15)
            table.add_column("Server", style="yellow bold")
            table.add_column("Provider", style="dim")

            # Common DNS providers
            providers = {
                "8.8.8.8": "Google DNS",
                "8.8.4.4": "Google DNS",
                "1.1.1.1": "Cloudflare DNS",
                "1.0.0.1": "Cloudflare DNS",
                "9.9.9.9": "Quad9 DNS",
                "149.112.112.112": "Quad9 DNS",
                "208.67.222.222": "OpenDNS",
                "208.67.220.220": "OpenDNS"
            }

            primary = data.get("primary", "N/A")
            secondary = data.get("secondary", "N/A")

            primary_provider = providers.get(primary, "Custom")
            secondary_provider = providers.get(secondary, "Custom")

            table.add_row("Primary DNS", primary, primary_provider)
            table.add_row("Secondary DNS", secondary, secondary_provider)

            self.console.print(table)

            # Additional info
            self.console.print("\n[dim]These DNS servers are configured for all VPN clients.[/dim]")
            self.console.print("[dim]Use 'Change DNS' option to update these settings.[/dim]")
        else:
            # Fallback display
            self.print("\n🌍 Active DNS Configuration")
            self.print("-" * 40)
            self.print(f"Primary DNS:   {data.get('primary', 'N/A')}")
            self.print(f"Secondary DNS: {data.get('secondary', 'N/A')}")
            self.print("\nThese DNS servers are configured for all VPN clients.")

    # noinspection PyUnusedLocal
    def _display_dns_menu(self, module_data, actions):
        """Display DNS module menu with compact single-line format"""
        self.clear_screen()

        if RICH_AVAILABLE and self.console:
            from rich.panel import Panel
            from rich.table import Table
            from rich import box

            # Header
            self.console.print(Panel(
                "[bold cyan]🌐 DNS Management[/bold cyan]\n"
                "[dim]Configure DNS servers for VPN clients[/dim]",
                box=box.DOUBLE,
                border_style="green"
            ))

            # Create compact table
            table = Table(
                title="DNS Configuration Options",
                box=box.ROUNDED,
                show_header=False,
                padding=(0, 1)
            )

            table.add_column("#", style="bold yellow", width=3)
            table.add_column("Action", style="cyan", width=25)
            table.add_column("Description", style="dim")

            # Define action info with shorter descriptions
            action_info = {
                "status": ("DNS Status", "View current configuration and health"),
                "get_dns_servers": ("Current Servers", "Show active DNS servers"),
                "change_dns_servers": ("Change DNS", "Update primary and secondary DNS"),
                "test_dns_servers": ("Test DNS", "Check DNS resolution performance")
            }
            action_idx = 1
            action_map = {}

            for action in actions:
                name = action["name"]
                if name in action_info:
                    title, desc = action_info[name]
                    table.add_row(str(action_idx), title, desc)
                    action_map[str(action_idx)] = name
                    action_idx += 1

            table.add_row("0", "Back", "Return to main menu")

            self.console.print(table)
            choice = Prompt.ask("\n[bold yellow]Select option[/bold yellow]", default="0")
        else:
            # Fallback display
            self.print("🌐 DNS Management", style="bold")
            self.print("=" * 60)
            self.print("Configure DNS servers for VPN clients\n")

            action_info = {
                "status": ("DNS Status", "View current configuration"),
                "get_dns_servers": ("Current Servers", "Show DNS servers"),
                "change_dns_servers": ("Change DNS", "Update DNS servers"),
                "test_dns_servers": ("Test DNS", "Test DNS resolution")
            }
            action_idx = 1
            action_map = {}

            for action in actions:
                name = action["name"]
                if name in action_info:
                    title, desc = action_info[name]
                    self.print(f"  {action_idx}. {title} - {desc}")
                    action_map[str(action_idx)] = name
                    action_idx += 1

            self.print("\n  0. Back to main menu")
            choice = input("\nSelect option (0): ")

        if choice == "0":
            return "back"

        if choice in action_map:
            return action_map[choice]

        self.print_error("Invalid selection")
        return None

    # noinspection PyUnusedLocal
    def _display_ghost_menu(self, module_data, actions):
        """Display Ghost mode specific menu"""
        if RICH_AVAILABLE and self.console:
            from rich.panel import Panel
            from rich.table import Table
            from rich import box

            # Header
            self.console.print(Panel(
                "[bold magenta]👻 Ghost Mode[/bold magenta]\n"
                "[dim]Censorship-resistant WireGuard connections[/dim]",
                box=box.DOUBLE,
                border_style="magenta"
            ))

            # Create table for Ghost actions with same style as multihop
            table = Table(
                title="Available Actions",
                box=box.ROUNDED,
                show_header=True,
                header_style="bold magenta"
            )

            table.add_column("#", style="bold yellow", width=6)
            table.add_column("Action", style="cyan", width=25)
            table.add_column("Description", style="dim")

            # Define action info with shorter descriptions - using correct API endpoint names
            action_info = {
                "enable": ("Enable Ghost Mode", "Mask WireGuard traffic as HTTPS"),
                "disable": ("Disable Ghost Mode", "Restore normal WireGuard operation"),
                "status": ("Status", "Current censorship-resistant connection status")
            }

            # Add actions using predefined info
            action_idx = 1
            action_map = {}
            for action in actions:
                name = action["name"]
                if name in action_info:
                    title, desc = action_info[name]
                    table.add_row(str(action_idx), title, desc)
                    action_map[str(action_idx)] = name
                    action_idx += 1

            table.add_row("0", "Back", "Return to main menu")

            self.console.print(table)
            choice = Prompt.ask("\n[bold yellow]Select action[/bold yellow]", default="0")
        else:
            # Fallback display
            self.clear_screen()
            self.print("👻 Ghost Mode", style="bold magenta")
            self.print("Censorship-resistant WireGuard connections")
            self.print("=" * 50)

            # Info about Casper tool for client configurations
            self.print("\n💡 Client configurations are exported using the Casper tool:")
            self.print("   phantom-casper [username]\n")

            action_info = {
                "enable": ("Enable Ghost Mode", "Mask WireGuard traffic as HTTPS"),
                "disable": ("Disable Ghost Mode", "Restore normal WireGuard operation"),
                "status": ("Status", "Current censorship-resistant connection status")
            }

            action_idx = 1
            action_map = {}
            for action in actions:
                name = action["name"]
                if name in action_info:
                    title, desc = action_info[name]
                    self.print(f"  {action_idx}. {title} - {desc}")
                    action_map[str(action_idx)] = name
                    action_idx += 1

            self.print("\n  0. Back to main menu")
            choice = input("\nSelect action (0): ")

        if choice == "0":
            return "back"

        if choice in action_map:
            return action_map[choice]

        self.print_error("Invalid selection")
        return None

    def run(self):
        """Main interactive loop"""
        # Header
        if self.ui:
            self.ui.show_header()
        else:
            self.print_panel(
                "Welcome to Phantom-WG API Console\n"
                f"Version {__version__}\n\n"
                "This is an interactive interface for managing your WireGuard VPN.\n\n"
                "© 2025 Rıza Emre ARAS - Project Phantom - All Rights Reserved",
                title="🌐 Phantom-WG",
                style="cyan"
            )

        while self.running:
            try:
                # Display main menu
                module_choice = self.display_menu()

                if module_choice == "exit":
                    if Confirm.ask("Are you sure you want to exit?", default=True):
                        self.running = False
                        self.print("\nGoodbye! 👋", style="cyan")
                        break
                elif module_choice:
                    # Display module menu
                    while True:
                        action_choice = self.display_module_menu(module_choice)

                        if action_choice == "back":
                            break
                        elif action_choice:
                            self.execute_action(module_choice, action_choice)

            except KeyboardInterrupt:
                self.print("\n\nInterrupted by user.", style="yellow")
                if Confirm.ask("Do you want to exit?", default=True):
                    self.running = False
                    break
            except Exception as e:
                self.print_error(f"Unexpected error: {str(e)}")
                if os.environ.get('DEBUG_MODE'):
                    import traceback
                    traceback.print_exc()


def main():
    """Main entry point for interactive CLI"""
    parser = argparse.ArgumentParser(
        description="Phantom-WG Interactive Console"
    )
    parser.add_argument(
        "--api-only",
        action="store_true",
        help="Run in API-only mode (JSON output)"
    )
    parser.add_argument(
        "--module",
        help="Module to execute"
    )
    parser.add_argument(
        "--action",
        help="Action to execute"
    )
    parser.add_argument(
        "--data",
        help="JSON data for the action"
    )

    args = parser.parse_args()

    if args.api_only or args.module:
        # Direct API mode
        import json
        api = PhantomAPI()

        if not args.module:
            response = api.list_modules()
            print(response.to_json())
        elif not args.action:
            response = api.module_info(args.module)
            print(response.to_json())
        else:
            kwargs = {}
            if args.data:
                try:
                    kwargs = json.loads(args.data)
                except json.JSONDecodeError:
                    print(json.dumps({
                        "success": False,
                        "error": "Invalid JSON data",
                        "code": "INVALID_JSON"
                    }))
                    sys.exit(1)

            response = api.execute(args.module, args.action, **kwargs)
            print(response.to_json())
    else:
        # Interactive mode
        ui = InteractiveUI()
        ui.run()


if __name__ == "__main__":
    main()

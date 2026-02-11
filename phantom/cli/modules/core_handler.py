"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Core Module UI Handler

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from .base import BaseUIHandler, RICH_AVAILABLE

if RICH_AVAILABLE:
    from rich.table import Table
    from rich.prompt import Prompt, Confirm
    from rich import box
    from rich.panel import Panel

# QR code generation support
try:
    import qrcode

    QRCODE_AVAILABLE = True
except ImportError:
    qrcode = None  # Define qrcode in except block
    QRCODE_AVAILABLE = False


class CoreUIHandler(BaseUIHandler):
    """ UI Handler for Core module """

    def get_module_name(self):
        """ Get module name """
        return "core"

    def handle_add_client(self):
        """Handle add_client action"""
        self.clear_screen()
        self.print("➕ Add New WireGuard Client", style="bold green")
        self.print("=" * 40)

        client_name = self.prompt("\nEnter client name")
        if not client_name:
            return None

        return {"client_name": client_name}

    def handle_remove_client(self):
        """Handle remove_client action with retry loop"""
        while True:
            self.clear_screen()
            self.print("🗑️  Remove WireGuard Client", style="bold red")
            self.print("=" * 40)

            # Get clients
            clients = self._get_client_list()
            if not clients:
                self.print("\nNo clients found.", style="yellow")
                return None

            # Display clients
            self._display_client_table(clients, show_status=True)

            client_name = self.prompt("\nEnter client name to remove (or press Enter to cancel)")
            if not client_name:
                return None

            # Check if client exists
            if not self._client_exists(client_name, clients):
                self.print_error(f"Client '{client_name}' not found")
                if not self.confirm("Would you like to try again?", default=True):
                    return None
                continue

            # Confirm removal
            if self.confirm(f"Are you sure you want to remove '{client_name}'?"):
                return {"client_name": client_name}
            else:
                return None

    def handle_export_client(self):
        """Handle export_client action with retry loop"""
        while True:
            self.clear_screen()
            self.print("📤 Export Client Configuration", style="bold blue")
            self.print("=" * 40)

            # Get clients
            clients = self._get_client_list()
            if not clients:
                self.print("\nNo clients found.", style="yellow")
                return None

            # Display clients
            self._display_client_table(clients, show_status=False)

            client_name = self.prompt("\nEnter client name (or press Enter to cancel)")
            if not client_name:
                return None

            # Check if client exists
            if not self._client_exists(client_name, clients):
                self.print_error(f"Client '{client_name}' not found")
                if not self.confirm("Would you like to try again?", default=True):
                    return None
                continue

            # Return client name only - no format needed
            return {
                "client_name": client_name
            }

    def handle_list_clients(self):
        """Handle list_clients action - Now shows client operations menu"""
        return self.handle_client_operations()

    # noinspection PyMethodMayBeStatic
    def handle_client_operations(self):
        """Handle client operations menu - returns None to stay in menu"""
        return {"_special": "client_operations"}

    # noinspection PyMethodMayBeStatic
    def handle_server_status(self):
        """Handle server_status action - returns special marker for custom display"""
        return {"_special": "server_status"}

    def handle_service_logs(self):
        """Handle service_logs action"""
        self.clear_screen()
        self.print("📄 WireGuard Service Logs", style="bold yellow")
        self.print("=" * 40)

        lines = self.prompt("\nNumber of log lines to display", default="50")
        try:
            lines = int(lines)
        except ValueError:
            lines = 50

        return {"lines": lines}

    def handle_latest_clients(self):
        """Handle latest_clients action"""
        self.clear_screen()
        self.print("🆕 Latest Added Clients", style="bold green")
        self.print("=" * 40)

        count = self.prompt("\nNumber of clients to display", default="5")
        try:
            count = int(count)
        except ValueError:
            count = 5

        # Execute the action and display results nicely
        response = self.api.execute("core", "latest_clients", count=count)

        if response.success:
            self._display_latest_clients(response.data)
            if RICH_AVAILABLE:
                Prompt.ask("\nPress Enter to continue")
            else:
                input("\nPress Enter to continue...")
            return None  # Prevent default display

        return {"count": count}

    def handle_restart_service(self):
        """Handle restart_service action"""
        self.clear_screen()
        self.print("🔄 Restart WireGuard Service", style="bold red")
        self.print("=" * 40)

        self.print("\n⚠️  Warning: This will temporarily disconnect all clients!", style="yellow")

        if self.confirm("\nAre you sure you want to restart the WireGuard service?", default=False):
            return {}
        return None

    # noinspection PyMethodMayBeStatic
    def handle_get_firewall_status(self):
        """Handle get_firewall_status action"""
        # This action returns data directly, no parameters needed
        return {}

    def display_clients_with_pagination(self, initial_response):
        """
        Display clients list with pagination support
        This method handles the pagination loop
        """
        current_page = 1
        per_page = 10
        search_term = ""

        while True:
            self.clear_screen()
            self.print("📋 WireGuard Client List", style="bold cyan")
            self.print("=" * 40)

            # Prepare parameters
            kwargs = {
                "page": current_page,
                "per_page": per_page,
                "search": search_term if search_term else None
            }

            # Get data
            if current_page == 1 and not search_term:
                response = initial_response
            else:
                response = self.api.execute("core", "list_clients", **kwargs)

            if not response.success:
                self.print_error(f"Failed to load clients: {response.error}")
                break

            data = response.data
            clients = data.get("clients", [])
            total = data.get("total", 0)
            pagination = data.get("pagination", {})

            # Display table
            if not clients:
                if search_term:
                    self.print(f"\nNo clients found matching '{search_term}'", style="yellow")
                else:
                    self.print("\nNo clients found.", style="yellow")
            else:
                self._display_clients_table(data)

            # Show pagination info
            if pagination.get("total_pages", 1) > 1:
                self.print(f"\n[dim]Page {pagination['page']} of {pagination['total_pages']} | "
                           f"Showing {pagination['showing_from']}-{pagination['showing_to']} of {total} clients[/dim]")

            # Show controls
            controls = ["[dim]Controls: ", "'r' = refresh"]
            if pagination.get("has_next"):
                controls.append("'n' = next page")
            if pagination.get("has_prev"):
                controls.append("'p' = previous page")
            controls.append("'s' = search")
            controls.append("Enter = back[/dim]")
            self.print(" | ".join(controls), style="italic")

            # Get user input
            user_input = self.prompt("").lower()

            if user_input == 'r':
                continue  # Refresh
            elif user_input == 'n' and pagination.get("has_next"):
                current_page += 1
            elif user_input == 'p' and pagination.get("has_prev"):
                current_page -= 1
            elif user_input == 's':
                search_term = self.prompt("\nSearch for client name")
                current_page = 1  # Reset to first page
            else:
                break

    def _get_client_list(self):
        """Get list of clients from API"""
        response = self.api.execute("core", "list_clients")
        if response.success:
            return response.data.get("clients", [])
        return []

    # noinspection PyMethodMayBeStatic
    def _client_exists(self, client_name, clients):
        """Check if client exists in the list"""
        return any(client.get("name") == client_name for client in clients)

    def _display_client_table(self, clients, show_status=True):
        """Display clients in a table"""
        if not self.console or not RICH_AVAILABLE:
            # Fallback display
            self.print("\nExisting clients:")
            for client in clients:
                status = "Active" if client.get("enabled", True) else "Disabled"
                if show_status:
                    self.print(f"  - {client.get('name')} ({client.get('ip')}) - {status}")
                else:
                    self.print(f"  - {client.get('name')} ({client.get('ip')})")
            return

        # Rich table
        table = Table(show_header=True, header_style="bold")
        table.add_column("Name", style="bold")
        table.add_column("IP Address", style="default")
        if show_status:
            table.add_column("Status", style="bold")

        for client in clients:
            row = [
                client.get("name", ""),
                client.get("ip", "")
            ]
            if show_status:
                status = "Active" if client.get("enabled", True) else "Disabled"
                row.append(status)
            table.add_row(*row)

        self.console.print(table)

    def _display_clients_table(self, data):
        """Display full clients table with connection details"""
        clients = data.get("clients", [])

        if not self.console or not RICH_AVAILABLE:
            # Fallback display
            for idx, client in enumerate(clients, 1):
                enabled = "Enabled" if client.get("enabled", True) else "Disabled"
                connected = "Connected" if client.get("connected", False) else "Disconnected"
                self.print(f"{idx}. {client.get('name')} - {client.get('ip')} - {enabled} - {connected}")
            return

        # Rich table
        table = Table(
            show_header=True,
            header_style="bold",
            box=box.ROUNDED,
            title_style="bold"
        )

        # Add columns
        table.add_column("#", style="dim", width=4)
        table.add_column("Name", style="bold", width=20)
        table.add_column("IP Address", style="default", width=15)
        table.add_column("Connection", justify="center", width=20)
        table.add_column("Created", style="default", width=25)
        table.add_column("Last Handshake", style="cyan", width=25)
        table.add_column("Data Transfer", justify="right", width=20)

        # Add rows
        for idx, client in enumerate(clients, 1):
            # Connection status
            enabled = client.get("enabled", True)
            connected = client.get("connected", False)

            if not enabled:  # noqa: duplicate code fragment
                connection = "⊗ Disabled"
                last_handshake = "N/A"
                data_transfer = "N/A"
            elif connected:
                connection = "● Connected"
                conn_details = client.get("connection", {})
                last_handshake = conn_details.get("latest_handshake", "N/A")

                # Format data transfer
                transfer = conn_details.get("transfer", {})
                if transfer:
                    rx = self._format_bytes(transfer.get("rx", 0))
                    tx = self._format_bytes(transfer.get("tx", 0))
                    data_transfer = f"↓ {rx} / ↑ {tx}"
                else:
                    data_transfer = "No data"
            else:
                connection = "○ Disconnected"
                last_handshake = "N/A"
                data_transfer = "N/A"

            # Format timestamp
            created = client.get("created", "Unknown")
            if created != "Unknown" and "T" in created:
                date_part, time_part = created.split("T")
                time_part = time_part.split(".")[0]
                created = f"{date_part} {time_part}"

            table.add_row(
                str(idx),
                client.get("name", ""),
                client.get("ip", ""),
                connection,
                created,
                last_handshake,
                data_transfer
            )

        self.console.print(table)

    # noinspection PyMethodMayBeStatic
    def _format_bytes(self, bytes_val):
        """Format bytes to human readable format"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.1f} {unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.1f} PB"

    def _generate_ascii_qr(self, data):
        """Generate ASCII QR code from data"""
        if not QRCODE_AVAILABLE:
            return None

        try:
            # Create a more compact QR code
            if qrcode is None:
                return None
            qr = qrcode.QRCode(  # type: ignore
                version=None,  # Auto-size
                error_correction=qrcode.constants.ERROR_CORRECT_L,  # Low error correction for smaller size
                box_size=1,
                border=0,  # No border for more compact display
            )
            qr.add_data(data)
            qr.make(fit=True)

            # Create ASCII representation with half blocks for better scaling
            ascii_qr = []
            matrix = qr.get_matrix()

            # Process two rows at a time for vertical compression
            for i in range(0, len(matrix), 2):
                ascii_row = ""
                for j in range(len(matrix[0])):
                    if i + 1 < len(matrix):
                        # Combine two vertical pixels into one character
                        top = matrix[i][j]
                        bottom = matrix[i + 1][j]

                        if top and bottom:
                            ascii_row += "█"  # Full block
                        elif top and not bottom:
                            ascii_row += "▀"  # Upper half block
                        elif not top and bottom:
                            ascii_row += "▄"  # Lower half block
                        else:
                            ascii_row += " "  # Empty
                    else:
                        # Last row if odd number of rows
                        ascii_row += "▀" if matrix[i][j] else " "

                ascii_qr.append(ascii_row)

            return "\n".join(ascii_qr)
        except Exception as e:
            self.print_error(f"Failed to generate QR code: {e}")
            return None

    def display_export_client(self, response):
        """Display export client result with QR code support"""
        if not response.success:
            self.print_error(f"{response.error}")
            return

        data = response.data
        client_info = data.get("client", {})
        config_content = data.get("config", "")

        # Display client information
        if RICH_AVAILABLE and self.console:
            # Create info panel
            info_panel = Panel(
                f"[bold]Client:[/bold] {client_info.get('name', 'Unknown')}\n"
                f"[bold]IP Address:[/bold] {client_info.get('ip', 'Unknown')}\n"
                f"[bold]Created:[/bold] {client_info.get('created', 'Unknown')}\n"
                f"[bold]Status:[/bold] {'Enabled' if client_info.get('enabled', True) else 'Disabled'}",
                title="📤 Client Export",
                box=box.ROUNDED,
                border_style="blue"
            )
            self.console.print(info_panel)
            self.console.print()

            # Display config content (raw format for easy copying)
            self.console.print("🔧 [bold green]WireGuard Configuration[/bold green]")
            self.console.print(config_content, highlight=False, markup=False)
            self.console.print()

            # Generate and display QR code if available
            if QRCODE_AVAILABLE:
                ascii_qr = self._generate_ascii_qr(config_content)
                if ascii_qr:
                    qr_panel = Panel(
                        ascii_qr,
                        title="📱 QR Code (Scan with WireGuard App)",
                        box=box.ROUNDED,
                        border_style="cyan"
                    )
                    self.console.print(qr_panel)
            else:
                self.print_warning("QR code generation not available. Install 'qrcode' package to enable.")
        else:
            # Fallback display without Rich
            self.print("\n=== Client Export ===")
            self.print(f"Client: {client_info.get('name', 'Unknown')}")
            self.print(f"IP Address: {client_info.get('ip', 'Unknown')}")
            self.print(f"Created: {client_info.get('created', 'Unknown')}")
            self.print(f"Status: {'Enabled' if client_info.get('enabled', True) else 'Disabled'}")
            self.print("\n=== WireGuard Configuration ===")
            self.print(config_content)

            # Generate QR code if available
            if QRCODE_AVAILABLE:
                ascii_qr = self._generate_ascii_qr(config_content)
                if ascii_qr:
                    self.print("\n=== QR Code (Scan with WireGuard App) ===")
                    self.print(ascii_qr)
            else:
                self.print("\n⚠️  QR code generation not available. Install 'qrcode' package to enable.")

    def _display_clients_operations_table(self, clients):
        """Display clients table for operations menu with enhanced info"""
        if not self.console or not RICH_AVAILABLE:
            # Fallback display
            for idx, client in enumerate(clients, 1):
                connected = "Connected" if client.get("connected", False) else "Disconnected"
                self.print(f"{idx}. {client.get('name')} - {client.get('ip')} - {connected}")
            return

        # Rich table with operation hints - using standard colors
        table = Table(
            show_header=True,
            header_style="bold",
            box=box.ROUNDED,
            title="📋 WireGuard Clients",
            title_style="bold"
        )

        # Add columns with standard colors that work in both light/dark themes
        table.add_column("#", style="dim", width=4)
        table.add_column("Name", style="bold", width=20)
        table.add_column("IP Address", width=15)
        table.add_column("Connection", justify="center", width=20)
        table.add_column("Last Handshake", width=25)
        table.add_column("Data Transfer", justify="right", width=20)
        table.add_column("Created", width=25)

        # Add rows
        for idx, client in enumerate(clients, 1):
            # Connection status
            connected = client.get("connected", False)
            enabled = client.get("enabled", True)

            if not enabled:  # noqa: duplicate code fragment
                connection = "⊗ Disabled"
                last_handshake = "N/A"
                data_transfer = "N/A"
            elif connected:
                connection = "● Connected"
                conn_details = client.get("connection", {})
                last_handshake = conn_details.get("latest_handshake", "N/A")

                # Format data transfer
                transfer = conn_details.get("transfer", {})
                if transfer:
                    rx = self._format_bytes(transfer.get("rx", 0))
                    tx = self._format_bytes(transfer.get("tx", 0))
                    data_transfer = f"↓ {rx} / ↑ {tx}"
                else:
                    data_transfer = "No data"
            else:
                connection = "○ Disconnected"
                last_handshake = "N/A"
                data_transfer = "N/A"

            # Format timestamp
            created = client.get("created", "Unknown")
            if created != "Unknown" and "T" in created:
                date_part, time_part = created.split("T")
                time_part = time_part.split(".")[0]
                created = f"{date_part} {time_part}"

            table.add_row(
                str(idx),
                client.get("name", ""),
                client.get("ip", ""),
                connection,
                last_handshake,
                data_transfer,
                created
            )

        self.console.print(table)

    def _handle_remove_from_table(self, clients):
        """Handle remove client from table view"""
        client_num = self.prompt("\nEnter client number to remove (or 0 to cancel)", default="0")

        if client_num == "0":
            return False

        try:
            idx = int(client_num) - 1
            if 0 <= idx < len(clients):
                client = clients[idx]
                client_name = client.get("name")

                if self.confirm(f"\nAre you sure you want to remove '{client_name}'?", default=False):
                    # Show spinner if available
                    if hasattr(self, 'console') and self.console and RICH_AVAILABLE:
                        from rich.progress import Progress, SpinnerColumn, TextColumn
                        with Progress(
                                SpinnerColumn(),
                                TextColumn("[progress.description]{task.description}"),
                                console=self.console,
                                transient=True
                        ) as progress:
                            progress.add_task(f"Removing client '{client_name}'...", total=None)
                            response = self.api.execute("core", "remove_client", client_name=client_name)
                            progress.stop()
                    else:
                        self.print(f"\n⏳ Removing client '{client_name}'...")
                        response = self.api.execute("core", "remove_client", client_name=client_name)

                    if response.success:
                        self.print_success(f"Client '{client_name}' removed successfully!")
                        return True
                    else:
                        self.print_error(f"Failed to remove client: {response.error}")
                        return False
            else:
                self.print_error("Invalid client number")
        except ValueError:
            self.print_error("Invalid input")

        return False

    def _handle_export_from_table(self, clients):
        """Handle export client from table view - shows both config and QR"""
        client_num = self.prompt("\nEnter client number to export (or 0 to cancel)", default="0")

        if client_num == "0":
            return False

        try:
            idx = int(client_num) - 1
            if 0 <= idx < len(clients):
                client = clients[idx]
                client_name = client.get("name")

                self.clear_screen()
                self.print(f"📤 Export Client Configuration: {client_name}", style="bold cyan")
                self.print("=" * 60)

                # Show spinner for export operations
                if hasattr(self, 'console') and self.console and RICH_AVAILABLE:
                    from rich.progress import Progress, SpinnerColumn, TextColumn
                    with Progress(
                            SpinnerColumn(),
                            TextColumn("[progress.description]{task.description}"),
                            console=self.console,
                            transient=True
                    ) as progress:
                        progress.add_task("Exporting configuration...", total=None)
                        conf_response = self.api.execute("core", "export_client",
                                                         client_name=client_name)
                        progress.stop()
                else:
                    self.print("\n⏳ Exporting configuration...")
                    conf_response = self.api.execute("core", "export_client",
                                                     client_name=client_name)

                if conf_response.success:
                    # Use the same display method as regular export
                    self.display_export_client(conf_response)
                    return True
                else:
                    self.print_error(f"Failed to export config: {conf_response.error}")
                    return False
            else:
                self.print_error("Invalid client number")
        except ValueError:
            self.print_error("Invalid input")

        return False

    def _handle_toggle_client(self, clients):
        """Handle enable/disable client from table view"""
        client_num = self.prompt("\nEnter client number to toggle (or 0 to cancel)", default="0")

        if client_num == "0":
            return False

        try:
            idx = int(client_num) - 1
            if 0 <= idx < len(clients):
                client = clients[idx]
                client_name = client.get("name")
                enabled = client.get("enabled", True)

                action = "disable" if enabled else "enable"
                if self.confirm(f"\nAre you sure you want to {action} '{client_name}'?", default=True):
                    # Note: This assumes enable/disable client actions exist in the API
                    response = self.api.execute("core", f"{action}_client", client_name=client_name)
                    if response.success:
                        self.print_success(f"Client '{client_name}' {action}d successfully!")
                        return True
                    else:
                        self.print_error(f"Failed to {action} client: {response.error}")
                        return False
            else:
                self.print_error("Invalid client number")
        except ValueError:
            self.print_error("Invalid input")

        return False

    def _display_latest_clients(self, data):
        """Display latest clients in a formatted way"""
        latest_clients = data.get("latest_clients", [])
        total_clients = data.get("total_clients", 0)

        self.print(f"\nShowing {len(latest_clients)} most recent clients (Total: {total_clients})")
        self.print("─" * 60)

        if not latest_clients:
            self.print("\nNo clients found.", style="yellow")
            return

        # Use Rich table if available
        if self.console and RICH_AVAILABLE:
            table = Table(
                show_header=True,
                header_style="bold cyan",
                box=box.ROUNDED,
                title_style="bold"
            )

            # Add columns
            table.add_column("#", style="dim", width=4)
            table.add_column("Name", style="bold yellow", width=20)
            table.add_column("IP Address", style="white", width=15)
            table.add_column("Created", style="cyan", width=25)
            table.add_column("Status", justify="center", width=15)
            table.add_column("Connection", width=25)

            for idx, client in enumerate(latest_clients, 1):
                # Format timestamp
                created = client.get("created", "Unknown")  # noqa: duplicate code fragment
                if created != "Unknown" and "T" in created:
                    date_part, time_part = created.split("T")
                    time_part = time_part.split(".")[0]
                    created = f"{date_part} {time_part}"

                # Status
                enabled = client.get("enabled", True)
                connected = client.get("connected", False)

                if not enabled:
                    status = "⊗ Disabled"
                    connection = "N/A"
                elif connected:
                    status = "● Active"
                    conn_details = client.get("connection", {})
                    endpoint = conn_details.get("endpoint", "N/A")
                    if endpoint != "N/A":
                        connection = endpoint.rsplit(":", 1)[0]  # Just IP (IPv4 or [IPv6])
                    else:
                        connection = "Connected"
                else:
                    status = "○ Offline"
                    connection = "Not connected"

                table.add_row(
                    str(idx),
                    client.get("name", ""),
                    client.get("ip", ""),
                    created,
                    status,
                    connection
                )

            self.console.print(table)
        else:
            # Fallback display
            for idx, client in enumerate(latest_clients, 1):
                created = client.get("created", "Unknown")  # noqa: duplicate code fragment
                if created != "Unknown" and "T" in created:
                    date_part, time_part = created.split("T")
                    time_part = time_part.split(".")[0]
                    created = f"{date_part} {time_part}"

                enabled = client.get("enabled", True)
                connected = client.get("connected", False)

                status = "Disabled" if not enabled else ("Connected" if connected else "Offline")

                self.print(f"\n{idx}. {client.get('name', 'Unknown')}")
                self.print(f"   IP Address: {client.get('ip', 'N/A')}")
                self.print(f"   Created: {created}")
                self.print(f"   Status: {status}")

                if connected and client.get("connection"):
                    conn = client.get("connection", {})
                    self.print(f"   Last Handshake: {conn.get('latest_handshake', 'N/A')}")
                    transfer = conn.get("transfer", {})
                    if transfer:
                        rx = self._format_bytes(transfer.get("rx", 0))
                        tx = self._format_bytes(transfer.get("tx", 0))
                        self.print(f"   Data Transfer: ↓ {rx} / ↑ {tx}")

        # Summary stats
        self.print("\n" + "─" * 60)
        self.print("📊 Summary:")

        # Count by status
        connected_count = sum(1 for c in latest_clients if c.get("connected", False))

        self.print(f"  • Total shown: {len(latest_clients)}")
        self.print(f"  • Connected: {connected_count}")
        self.print(f"  • Total clients in system: {total_clients}")

    def handle_get_tweak_settings(self):
        """Handle displaying and modifying tweak settings"""
        while True:
            self.clear_screen()

            if RICH_AVAILABLE and self.console:
                # Show header
                self.console.print(Panel(
                    "[bold cyan]⚙️  Tweak Settings[/bold cyan]\n"
                    "[dim]Configure advanced behavior settings[/dim]",
                    box=box.DOUBLE,
                    border_style="cyan"
                ))
            else:
                self.print("⚙️  Tweak Settings", style="bold cyan")
                self.print("=" * 50)
                self.print("Configure advanced behavior settings", style="dim")

            # Get current settings
            response = self.api.execute("core", "get_tweak_settings")
            if not response.success:
                self.print_error(f"Failed to load settings: {response.error}")
                self.prompt("\nPress Enter to continue")
                return None

            settings = response.data

            # Separate actual settings from their descriptions
            display_settings = {}
            descriptions = {}

            for key, value in settings.items():
                if key.endswith("_description"):
                    # This is a description for another setting
                    base_key = key[:-12]  # Remove "_description" suffix
                    descriptions[base_key] = value
                else:
                    # This is an actual setting
                    display_settings[key] = value

            if RICH_AVAILABLE and self.console:
                # Create settings table
                table = Table(
                    title="Current Settings",
                    box=box.ROUNDED,
                    show_header=True,
                    header_style="bold magenta"
                )

                table.add_column("#", style="bold yellow", width=4)
                table.add_column("Setting", style="cyan")
                table.add_column("Value", style="green")
                table.add_column("Description", style="dim")

                setting_map = {}
                for i, (key, value) in enumerate(display_settings.items(), 1):
                    desc = descriptions.get(key, "No description available")
                    # Convert boolean to lowercase string for display
                    display_value = str(value).lower() if isinstance(value, bool) else str(value)
                    table.add_row(str(i), key, display_value, desc)
                    setting_map[str(i)] = key

                table.add_row("0", "Back", "", "Return to main menu")

                self.console.print(table)
                choice = Prompt.ask("\n[bold yellow]Select setting to toggle (0 to go back)[/bold yellow]", default="0")
            else:
                # Fallback display
                self.print("\nCurrent Settings:")
                self.print("─" * 50)

                setting_map = {}
                for i, (key, value) in enumerate(display_settings.items(), 1):
                    desc = descriptions.get(key, "No description available")
                    # Convert boolean to lowercase string for display
                    display_value = str(value).lower() if isinstance(value, bool) else str(value)
                    self.print(f"  {i}. {key}: {display_value}")
                    self.print(f"     {desc}", style="dim")
                    setting_map[str(i)] = key

                self.print("\n  0. Back to main menu")
                choice = input("\nSelect setting to toggle (0 to go back): ")

            if choice == "0":
                return None

            if choice in setting_map:
                setting_name = setting_map[choice]
                current_value = display_settings[setting_name]

                # Toggle boolean value
                new_value = not current_value

                # Confirm change
                desc = descriptions.get(setting_name, "")
                if RICH_AVAILABLE:
                    confirm_msg = f"Change '{setting_name}' from {current_value} to {new_value}?"
                    if desc:
                        confirm_msg += f"\n[dim]{desc}[/dim]"

                    if Confirm.ask(confirm_msg):
                        # Update setting
                        update_response = self.api.execute("core", "update_tweak_setting",
                                                           setting_name=setting_name, value=new_value)

                        if update_response.success:
                            self.print_success(f"Setting updated successfully!")
                        else:
                            self.print_error(f"Failed to update setting: {update_response.error}")

                        Prompt.ask("\nPress Enter to continue")
                else:
                    confirm_msg = f"Change '{setting_name}' from {current_value} to {new_value}? [y/N]: "
                    if input(confirm_msg).lower() in ['y', 'yes']:
                        # Update setting
                        update_response = self.api.execute("core", "update_tweak_setting",
                                                           setting_name=setting_name, value=new_value)

                        if update_response.success:
                            self.print_success(f"Setting updated successfully!")
                        else:
                            self.print_error(f"Failed to update setting: {update_response.error}")

                        input("\nPress Enter to continue...")
            else:
                self.print_error("Invalid selection")
                if RICH_AVAILABLE:
                    Prompt.ask("\nPress Enter to continue")
                else:
                    input("\nPress Enter to continue...")

    def handle_get_subnet_info(self):
        """Handle subnet change workflow - shows info and guides through the process"""
        self.clear_screen()

        if RICH_AVAILABLE and self.console:
            # Header
            self.console.print(Panel(
                "[bold cyan]🔧 Change Default Subnet[/bold cyan]\n"
                "[dim]Modify VPN network subnet configuration[/dim]",
                box=box.DOUBLE,
                border_style="yellow"
            ))
        else:
            self.print("🔧 Change Default Subnet", style="bold cyan")
            self.print("=" * 50)
            self.print("Modify VPN network subnet configuration", style="dim")

        # Get current subnet info
        self.print("\n📊 Fetching current subnet information...")
        response = self.api.execute("core", "get_subnet_info")

        if not response.success:
            self.print_error(f"Failed to get subnet info: {response.error}")
            self.prompt("\nPress Enter to continue")
            return None

        info = response.data

        # Display current configuration
        self.print("\n📋 Current Configuration:")
        self.print("─" * 40)
        self.print(f"Network: {info['current_subnet']}")
        self.print(f"Interface: {info.get('main_interface', {}).get('interface', 'wg_main')}")
        self.print(f"Total Clients: {info.get('clients', {}).get('total', 0)}")
        self.print(f"Allocated IPs: {info.get('clients', {}).get('total', 0) + 1}")  # +1 for server
        self.print(f"Available IPs: {info.get('subnet_size', 254) - info.get('clients', {}).get('total', 0) - 1}")

        # Show active features that would block subnet change
        blockers = info.get('blockers', {})
        blocking_features = []

        if blockers.get('ghost_mode'):
            blocking_features.append("Ghost Mode is active")
        if blockers.get('multihop'):
            blocking_features.append("Multihop VPN is active")

        if blocking_features:
            self.print("\n⚠️  Active Features (Must be disabled first):", style="yellow")
            for feature in blocking_features:
                self.print(f"  • {feature}")
            self.print("\nSubnet change is BLOCKED due to active features.", style="red")
            self.prompt("\nPress Enter to continue")
            return None

        # Show warnings
        if info.get('warnings'):
            self.print("\n⚠️  Warnings:", style="yellow")
            for warning in info['warnings']:
                self.print(f"  • {warning}")

        # Ask if user wants to continue
        if not self.confirm("\nDo you want to change the subnet?", default=False):
            return None

        # Get new subnet
        while True:
            new_subnet = self.prompt("\nEnter new subnet (e.g., 10.8.0.0/24)")
            if not new_subnet:
                return None

            # Validate the subnet
            self.print("\n🔍 Validating subnet...")
            validate_response = self.api.execute("core", "validate_subnet_change", new_subnet=new_subnet)

            if not validate_response.success:
                self.print_error(f"Validation failed: {validate_response.error}")
                if not self.confirm("Would you like to try another subnet?", default=True):
                    return None
                continue

            validation = validate_response.data

            if not validation['valid']:
                self.print_error(f"Invalid subnet: {validation['error']}")
                if validation.get('details'):
                    for detail in validation['details']:
                        self.print(f"  • {detail}", style="yellow")

                if not self.confirm("\nWould you like to try another subnet?", default=True):
                    return None
                continue

            # Show validation results
            self.print("\n✅ Subnet validation passed!", style="green")

            # Show what will change
            self.print("\n📝 Changes to be made:")
            self.print("─" * 40)
            self.print(f"Current subnet: {info['current_subnet']}")
            self.print(f"New subnet: {new_subnet}")
            self.print(f"Clients to update: {info.get('clients', {}).get('total', 0)}")

            if validation.get('warnings'):
                self.print("\n⚠️  Additional warnings:", style="yellow")
                for warning in validation['warnings']:
                    self.print(f"  • {warning}")

            # Final confirmation
            self.print("\n⚠️  IMPORTANT:", style="red bold")
            self.print("• All clients will be disconnected temporarily")
            self.print("• Client configurations will be updated automatically")
            self.print("• WireGuard service will be restarted")
            self.print("• This operation cannot be undone")

            if self.confirm("\nAre you absolutely sure you want to proceed?", default=False):
                # Execute the subnet change
                self.print("\n🔄 Changing subnet...")

                change_response = self.api.execute("core", "change_subnet",
                                                   new_subnet=new_subnet,
                                                   confirm=True)

                if change_response.success:
                    self.print_success("\nSubnet changed successfully!")

                    result = change_response.data
                    if result.get('clients_updated'):
                        self.print(f"\n📊 Update Summary:")
                        self.print(f"  • Clients updated: {result['clients_updated']}")
                        self.print(f"  • Service restarted: Yes")
                        self.print(f"  • New subnet active: {new_subnet}")

                    self.print("\n💡 Next Steps:", style="cyan")
                    self.print("1. Inform all users about the subnet change")
                    self.print("2. Users must update their client configurations")
                    self.print("3. Use 'Export Client' to get updated configs")

                    self.prompt("\nPress Enter to continue")
                    return {"_special": "subnet_changed"}
                else:
                    self.print_error(f"\nSubnet change failed: {change_response.error}")
                    if change_response.data and change_response.data.get('rollback_performed'):
                        self.print("\n✅ Rollback completed - original configuration restored", style="yellow")

                    self.prompt("\nPress Enter to continue")
                    return None
            else:
                return None

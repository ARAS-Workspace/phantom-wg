#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG CLI UI Bileşenleri
    ===================================
    
    Rich framework kullanarak tutarlı ve güzel görünümlü kullanıcı arayüzü
    bileşenleri sağlar. Tüm CLI modülleri tarafından ortak kullanılır.
    
    Ana Özellikler:
        - Tema yönetimi: Açık/koyu terminal desteği
        - Yükleme animasyonları: Spinner ve progress bar
        - Durum mesajları: Başarı, hata, uyarı, bilgi
        - Tablo oluşturma: Veri listeleme için
        - Kullanıcı etkileşimi: Input ve onay dialogları

EN: Phantom-WG CLI UI Components
    =================================
    
    Provides consistent and beautiful user interface components using the
    Rich framework. Shared by all CLI modules.
    
    Key Features:
        - Theme management: Light/dark terminal support
        - Loading animations: Spinner and progress bar
        - Status messages: Success, error, warning, info
        - Table creation: For data listing
        - User interaction: Input and confirmation dialogs

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TimeElapsedColumn
from rich.panel import Panel
from rich.table import Table
from rich import box
from rich.theme import Theme
import time
import threading

# Theme for both light and dark terminals
PHANTOM_THEME = Theme({
    # Main colors
    "primary": "cyan",
    "secondary": "magenta",
    "success": "green",
    "error": "red",
    "warning": "yellow",
    "info": "blue",

    # UI elements
    "header": "bold cyan",
    "subheader": "cyan",
    "label": "bold",
    "value": "default",
    "dim": "dim",
    "highlight": "reverse",

    # Status
    "active": "green",
    "inactive": "red",
    "pending": "yellow",

    # Special
    "phantom": "cyan",
    "wireguard": "green",

    # Additional
    "bold": "bold",
    "italic": "italic",
    "underline": "underline",
})


class UIComponents:
    """
    Reusable UI components with consistent styling and theme support.

    Method Flow:
        1. show_header() - Display application banner
        2. show_spinner() - Show loading animation for async tasks
        3. show_progress() - Show progress bar for long operations
        4. show_status/error/success() - Display status messages
        5. create_table() - Create formatted data tables
        6. get_input/confirm_action() - User interaction
    """

    def __init__(self, console=None):
        self.console = console or Console(theme=PHANTOM_THEME)
        self._operation_lock = threading.Lock()
        self._current_operation = None

    def show_header(self):
        """Display application header"""
        header = Panel(
            "[phantom]🌐 Phantom-WG[/phantom] [dim]core-v1[/dim]\n"
            "[subheader]Advanced VPN Management System[/subheader]\n"
            "[dim]© 2025 Rıza Emre ARAS - All Rights Reserved[/dim]",
            box=box.DOUBLE,
            style="primary",
            expand=False,
            padding=(1, 2)
        )
        self.console.print(header)

    def show_spinner(self, message, task):
        """
        Show spinner while executing a task
        Blocks until task completes
        """
        with self._operation_lock:
            if self._current_operation:
                raise RuntimeError("Another operation is already in progress")

            self._current_operation = True

        result = None
        error = None

        def run_task():
            nonlocal result, error
            try:
                result = task()
            except Exception as e:
                error = e

        # Start task
        task_thread = threading.Thread(target=run_task)
        task_thread.start()

        # Spinner
        with Progress(
                SpinnerColumn(spinner_name="dots", style="primary"),
                TextColumn("[progress.description]{task.description}"),
                TimeElapsedColumn(),
                console=self.console,
                transient=True
        ) as progress:
            progress.add_task(description=f"[primary]{message}[/primary]", total=None)

            # Wait
            while task_thread.is_alive():
                time.sleep(0.1)

        # Clear lock
        with self._operation_lock:
            self._current_operation = None

        # Result
        if error:
            raise error
        return result

    def show_progress(self, message, task):
        """
        Show progress bar while executing a task
        Task should call the update callback with progress 0-100
        """
        with self._operation_lock:
            if self._current_operation:
                raise RuntimeError("Another operation is already in progress")

            self._current_operation = True

        result = None
        error = None
        progress_value = 0

        def update_progress(value):
            nonlocal progress_value
            progress_value = min(100, max(0, value))

        def run_task():
            nonlocal result, error
            try:
                result = task(update_progress)
            except Exception as e:
                error = e

        # Start task
        task_thread = threading.Thread(target=run_task)
        task_thread.start()

        # Progress bar
        with Progress(
                TextColumn("[progress.description]{task.description}"),
                BarColumn(bar_width=40, style="primary", complete_style="success"),
                TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
                TimeElapsedColumn(),
                console=self.console,
                transient=True
        ) as progress:
            task_id = progress.add_task(
                description=f"[primary]{message}[/primary]",
                total=100
            )

            # Update
            while task_thread.is_alive():
                progress.update(task_id, completed=progress_value)
                time.sleep(0.1)

            # Final
            progress.update(task_id, completed=100)

        # Clear lock
        with self._operation_lock:
            self._current_operation = None

        # Result
        if error:
            raise error
        return result

    def show_status(self, message, status="info"):
        """Show a status message with appropriate styling"""
        icons = {
            "success": "✅",
            "error": "❌",
            "warning": "⚠️",
            "info": "ℹ️",
            "pending": "⏳",
        }

        icon = icons.get(status, "")
        self.console.print(f"{icon} [{status}]{message}[/{status}]")

    def show_error(self, message, details=None):
        """Show an error message"""
        error_panel = Panel(
            f"[error]❌ {message}[/error]" + (f"\n\n[dim]{details}[/dim]" if details else ""),
            title="[error]Error[/error]",
            box=box.ROUNDED,
            border_style="error",
            expand=False
        )
        self.console.print(error_panel)

    def show_success(self, message, details=None):
        """Show a success message"""
        success_panel = Panel(
            f"[success]✅ {message}[/success]" + (f"\n\n[dim]{details}[/dim]" if details else ""),
            title="[success]Success[/success]",
            box=box.ROUNDED,
            border_style="success",
            expand=False
        )
        self.console.print(success_panel)

    # noinspection PyMethodMayBeStatic
    def create_table(self, title, headers, style="primary"):
        """Create a styled table"""
        table = Table(
            title=f"[{style}]{title}[/{style}]",
            box=box.ROUNDED,
            header_style=style,
            title_style="header",
            show_lines=True
        )

        for header in headers:
            table.add_column(header, style="label")

        return table

    # noinspection PyMethodMayBeStatic
    def confirm_action(self, message, default=False):
        """Ask for confirmation with consistent styling"""
        from rich.prompt import Confirm
        return Confirm.ask(f"[warning]{message}[/warning]", default=default)

    # noinspection PyMethodMayBeStatic
    def get_input(self, prompt, default=None):
        """Get user input with consistent styling"""
        from rich.prompt import Prompt
        return Prompt.ask(f"[primary]{prompt}[/primary]", default=default)

    def show_section(self, title, content, style="primary"):
        """Show a section with title and content"""
        section = Panel(
            content,
            title=f"[{style}]{title}[/{style}]",
            box=box.ROUNDED,
            border_style=style,
            expand=False
        )
        self.console.print(section)

    def is_operation_running(self):
        """Check if an operation is currently running"""
        with self._operation_lock:
            return self._current_operation is not None

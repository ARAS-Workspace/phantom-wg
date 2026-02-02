#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Casper - Ghost Mode Client Configuration Exporter
    ========================================================
    
    Bu araç, Ghost Mode aktifken kullanıcıların WireGuard client konfigürasyonlarını
    görüntülemelerine olanak sağlar.
    
    Ana Özellikler:
        - Ghost Mode durumunu kontrol eder
        - İstemci verilerini Phantom API üzerinden alır
        - wstunnel komutunu Ghost API'den çeker
        - WireGuard konfigürasyonunu dinamik olarak üretir
        - AllowedIPs'i sunucu IP'sini hariç tutacak şekilde hesaplar
    
    Kullanım:
        phantom-casper [kullanıcı_adı]     # İstemci konfigürasyonunu görüntüle
        phantom-casper --help              # Yardımı göster

EN: Casper - Ghost Mode Client Configuration Exporter
    ================================================
    
    This tool allows users to view their WireGuard client configurations when Ghost Mode
    is active.
    
    Key Features:
        - Checks Ghost Mode status
        - Retrieves client data via Phantom API
        - Fetches wstunnel command from Ghost API
        - Dynamically generates WireGuard configuration
        - Calculates AllowedIPs to exclude server IP
    
    Usage:
        phantom-casper [username]     # Display client configuration
        phantom-casper --help         # Show help

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import sys
import os
import argparse

# Add current directory to path to import path_helper
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from path_helper import setup_phantom_path

# Setup phantom module path
setup_phantom_path()

from phantom.casper.core import CasperService


def show_help():
    """
    TR: Yardım mesajını göster.
    
        Casper aracının kullanım bilgilerini, örneklerini ve gereksinimlerini
        gösterir. Çıktı formatı hakkında bilgi verir.
    
    EN: Show help message.
    
        Displays usage information, examples, and requirements for the Casper
        tool. Provides information about the output format.
    """
    print("Casper - Ghost Mode Configuration Exporter")
    print("=" * 45)
    print()
    print("Usage: phantom-casper [username]")
    print()
    print("Examples:")
    print("  phantom-casper john-laptop    # Show config for john-laptop")
    print("  phantom-casper alice-phone    # Show config for alice-phone")
    print()
    print("Requirements:")
    print("  - Ghost Mode must be active")
    print("  - Client must exist in the system")
    print()
    print("Output:")
    print("  - WireGuard configuration (ghost.conf)")
    print("  - Setup instructions")
    print("  - No files created - stdout only")


def main():
    """
    TR: Ana giriş noktası.
    
        Komut satırı argümanlarını işler, yardım mesajını gösterir veya
        istenen istemci için konfigürasyon dışa aktarımını gerçekleştirir.
        Hata durumlarını yakalar ve uygun çıkış kodlarıyla sonlanır.
    
    EN: Main entry point.
    
        Processes command-line arguments, shows help message or performs
        configuration export for the requested client. Catches error
        conditions and exits with appropriate exit codes.
    """
    # Initialize argument parser with custom help handling
    parser = argparse.ArgumentParser(
        description="Ghost Mode Configuration Exporter",
        add_help=False  # We handle --help ourselves for custom formatting
    )

    # Define command-line arguments
    parser.add_argument(
        "username",
        nargs="?",  # Optional positional argument
        help="Client username to export configuration for"
    )
    parser.add_argument(
        "--help", "-h",
        action="store_true",
        help="Show help message"
    )

    # Parse arguments
    args = parser.parse_args()

    # Handle help request or missing username
    if args.help or not args.username:
        show_help()
        sys.exit(0)

    # Initialize service and perform export
    try:
        # Create Casper service instance
        service = CasperService()

        # Export client configuration to stdout
        service.export_client_config(args.username)

    except KeyboardInterrupt:
        # Handle Ctrl+C gracefully
        print("\nOperation cancelled")
        sys.exit(130)  # Standard exit code for SIGINT

    except Exception as e:
        # Handle all other errors
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

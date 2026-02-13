#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Casper iOS - Ghost Mode iOS Client Configuration Exporter
    ========================================================

    Bu araç, Ghost Mode aktifken kullanıcıların Phantom-WG iOS uygulaması
    için JSON formatında konfigürasyon üretir.

    Ana Özellikler:
        - Ghost Mode durumunu kontrol eder
        - İstemci verilerini Phantom API üzerinden alır
        - AllowedIPs'i sunucu IPv4 IP'sini hariç tutacak şekilde hesaplar
        - iOS uyumlu JSON yapısı üretir

    Kullanım:
        phantom-casper-ios [kullanıcı_adı]     # iOS JSON konfigürasyonunu göster
        phantom-casper-ios --help              # Yardımı göster

EN: Casper iOS - Ghost Mode iOS Client Configuration Exporter
    ================================================

    This tool generates JSON-format configurations for the Phantom-WG iOS
    application when Ghost Mode is active.

    Key Features:
        - Checks Ghost Mode status
        - Retrieves client data via Phantom API
        - Calculates AllowedIPs to exclude server IPv4 IP
        - Produces iOS-compatible JSON structure

    Usage:
        phantom-casper-ios [username]     # Show iOS JSON configuration
        phantom-casper-ios --help         # Show help

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

from tools.casper_ios.core import CasperIOSService


def show_help():
    """
    TR: Yardım mesajını göster.

        Casper iOS aracının kullanım bilgilerini, örneklerini ve gereksinimlerini
        gösterir. Çıktı formatı hakkında bilgi verir.

    EN: Show help message.

        Displays usage information, examples, and requirements for the Casper
        iOS tool. Provides information about the output format.
    """
    print("Casper iOS - Ghost Mode iOS Configuration Exporter")
    print("=" * 52)
    print()
    print("Usage: phantom-casper-ios [username]")
    print()
    print("Examples:")
    print("  phantom-casper-ios john-laptop    # Show iOS JSON config")
    print("  phantom-casper-ios alice-phone    # Show iOS JSON config")
    print()
    print("Requirements:")
    print("  - Ghost Mode must be active")
    print("  - Client must exist in the system")
    print()
    print("Output:")
    print("  - iOS WireGuard JSON configuration")
    print("  - No files created - stdout only")


def main():
    """
    TR: Ana giriş noktası.

        Komut satırı argümanlarını işler, yardım mesajını gösterir veya
        istenen istemci için iOS konfigürasyonunu dışa aktarır.
        Hata durumlarını yakalar ve uygun çıkış kodlarıyla sonlanır.

    EN: Main entry point.

        Processes command-line arguments, shows help message or performs
        iOS configuration export for the requested client. Catches error
        conditions and exits with appropriate exit codes.
    """
    # Initialize argument parser with custom help handling
    parser = argparse.ArgumentParser(
        description="Ghost Mode iOS Configuration Exporter",
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
        # Create Casper iOS service instance
        service = CasperIOSService()

        # Export client configuration
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
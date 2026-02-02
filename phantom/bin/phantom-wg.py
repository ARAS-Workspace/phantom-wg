#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Etkileşimli CLI Arayüzü
    ======================================
    
    Bu script, Phantom-WG için zengin, etkileşimli bir terminal
    kullanıcı arayüzü sağlar.

EN: Phantom-WG Interactive CLI Interface
    =====================================
    
    This script provides a rich, interactive terminal user interface
    for Phantom-WG.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import sys
import os

# Add current directory to path to import path_helper
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from path_helper import setup_phantom_path

# Setup phantom module path
setup_phantom_path()

from phantom.cli.interactive import InteractiveUI


def main():
    ui = InteractiveUI()
    ui.run()


if __name__ == "__main__":
    main()

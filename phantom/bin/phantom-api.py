#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG API Komut Satırı Arayüzü
    ========================================
    
    Bu script, Phantom-WG API'sine komut satırından erişim sağlar.
    Tüm modül eylemlerini CLI üzerinden çalıştırmanıza olanak tanır.
    
    Kullanım:
        phantom-api <modül> <eylem> [parametreler...]
        
    Örnekler:
        phantom-api core list_clients
        phantom-api core add_client client_name="john-laptop"
        phantom-api dns change_dns_servers primary="8.8.8.8" secondary="8.8.4.4"
        phantom-api ghost enable domain="cdn.example.com"
        
    Parametre Formatları:
        - Basit değerler: param=değer
        - Listeler: param='["item1","item2"]' (JSON formatında)
        - Boolean: param=true veya param=false
        - Sayılar: param=123
        
    Çıktı Formatı:
        Tüm yanıtlar JSON formatında döndürülür ve başarı durumu,
        veri ve metadata bilgilerini içerir.

EN: Phantom-WG API Command-Line Interface
    ==========================================
    
    This script provides command-line access to the Phantom-WG API.
    It allows you to execute all module actions through the CLI.
    
    Usage:
        phantom-api <module> <action> [parameters...]
        
    Examples:
        phantom-api core list_clients
        phantom-api core add_client client_name="john-laptop"
        phantom-api dns change_dns_servers primary="8.8.8.8" secondary="8.8.4.4"
        phantom-api ghost enable domain="cdn.example.com"
        
    Parameter Formats:
        - Simple values: param=value
        - Lists: param='["item1","item2"]' (in JSON format)
        - Boolean: param=true or param=false
        - Numbers: param=123
        
    Output Format:
        All responses are returned in JSON format and include success status,
        data, and metadata information.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""
import sys
import os
import json
from textwrap import dedent

# Add current directory to path to import path_helper
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from path_helper import setup_phantom_path

# Setup phantom module path
setup_phantom_path()

from phantom.api.core import PhantomAPI


def print_help():
    """
    TR: Yardım mesajını göster
    EN: Display help message
    """
    help_text = dedent("""
        ╔═══════════════════════════════════════════════════════════════════════╗
        ║                    PHANTOM-WG API INTERFACE                           ║
        ╠═══════════════════════════════════════════════════════════════════════╣
        ║  A command-line API interface for Phantom-WG VPN management           ║
        ╚═══════════════════════════════════════════════════════════════════════╝
        
        USAGE:
            phantom-api <module> <action> [parameters...]
        
        AVAILABLE MODULES:
            core      - WireGuard server and client management
            dns       - DNS configuration management
            ghost     - Ghost Mode (censorship-resistant WebSocket tunneling)
            multihop  - Multi-hop VPN routing through external providers
        
        PARAMETER FORMAT:
            Parameters use key=value format
            Boolean: confirm=true
            String:  client_name="john-laptop"
            Number:  lines=50 or count=10
            List:    servers='["8.8.8.8","1.1.1.1"]'
        
        EXAMPLES:
            # Add a new client
            phantom-api core add_client client_name="alice-laptop"
        
            # List clients with pagination and search
            phantom-api core list_clients page=2 per_page=20 search="john"
        
            # Export client configuration
            phantom-api core export_client client_name="alice-laptop"
        
            # Check server status
            phantom-api core server_status
        
            # Enable Ghost Mode with domain (supports sslip.io/nip.io)
            phantom-api ghost enable domain="cdn.example.com"
            phantom-api ghost enable domain="157-230-114-231.sslip.io"
        
            # Change DNS servers
            phantom-api dns change_dns_servers primary="1.1.1.1" secondary="1.0.0.1"
        
            # Import and enable multihop VPN
            phantom-api multihop import_vpn_config config_path="/root/xeovo-uk.conf"
            phantom-api multihop enable_multihop exit_name="xeovo-uk"
        
            # Change subnet (requires confirmation)
            phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
        
        OUTPUT:
            All responses are in JSON format with the following structure:
            {
                "success": true/false,
                "data": { ... },
                "error": "error message if failed",
                "code": "ERROR_CODE",
                "metadata": {
                    "module": "module_name",
                    "action": "action_name",
                    "timestamp": "ISO timestamp",
                    "version": "core-v1"
                }
            }
        
        NOTES:
            • Root privileges required for system changes
            • Backup before network configuration changes
            • Use confirm=true for destructive operations
            • Ghost Mode requires domain with A record pointing to server
        
        For complete documentation: /opt/phantom-wg/phantom/bin/docs/
        Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me> - Licensed under MIT License
        WireGuard® is a registered trademark of Jason A. Donenfeld.
    """)
    print(help_text.strip())


def main():
    """
    TR: Ana program fonksiyonu - CLI argümanlarını işler ve API'yi çağırır.
    
        Bu fonksiyon şu adımları gerçekleştirir:
        1. Komut satırı argümanlarını kontrol eder
        2. Modül ve eylem isimlerini çıkarır
        3. Parametreleri anahtar=değer formatından Python dict'e dönüştürür
        4. PhantomAPI'yi başlatır ve eylemi çalıştırır
        5. Sonucu JSON formatında ekrana yazdırır
        
        Parametre Dönüşümü:
            - JSON olarak parse edilebilen değerler (listeler, dict'ler) otomatik dönüştürülür
            - Parse edilemeyen değerler string olarak kalır
            - Bu sayede hem basit string'ler hem de karmaşık veri yapıları desteklenir
    
    EN: Main program function - processes CLI arguments and calls the API.
    
        This function performs the following steps:
        1. Checks command-line arguments
        2. Extracts module and action names
        3. Converts parameters from key=value format to Python dict
        4. Initializes PhantomAPI and executes the action
        5. Prints the result in JSON format to screen
        
        Parameter Conversion:
            - Values that can be parsed as JSON (lists, dicts) are auto-converted
            - Values that can't be parsed remain as strings
            - This supports both simple strings and complex data structures
    """
    # Check for help flag
    if len(sys.argv) > 1 and sys.argv[1] in ['--help', '-h', 'help']:
        print_help()
        sys.exit(0)

    if len(sys.argv) < 3:
        print("Usage: phantom-api <module> <action> [args...]")
        print("Example: phantom-api core list_clients")
        print("\nFor detailed help, run: phantom-api --help")
        sys.exit(1)

    module = sys.argv[1]
    action = sys.argv[2]
    args = sys.argv[3:]

    # Initialize API
    api = PhantomAPI()

    # Parse arguments as key=value pairs
    kwargs = {}
    for arg in args:
        if '=' in arg:
            key, value = arg.split('=', 1)
            # Try to parse as JSON for complex types
            try:
                kwargs[key] = json.loads(value)
            except (json.JSONDecodeError, ValueError):
                kwargs[key] = value

    # Execute action
    try:
        response = api.execute(module, action, **kwargs)
        print(json.dumps(response.to_dict(), indent=2))
    except Exception as e:
        print(json.dumps({
            "success": False,
            "error": str(e),
            "code": "ERROR"
        }, indent=2))
        sys.exit(1)


if __name__ == "__main__":
    main()

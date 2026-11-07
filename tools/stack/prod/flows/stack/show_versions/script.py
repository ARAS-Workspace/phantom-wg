"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

What show-versions runs inside the daemon container.
"""

COMPONENT_VERSIONS = '''
import sys, pathlib, re

def ver(path):
    try:
        text = pathlib.Path(path).read_text()
        m = re.search(r"__version__\\s*=\\s*\\"(.+?)\\"", text)
        return m.group(1) if m else "?"
    except FileNotFoundError:
        return "not found"

def ver_file(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except FileNotFoundError:
        return "not found"

daemon    = ver("/app/phantom_daemon/__init__.py")
fw_bridge = ver("/opt/phantom/vendor/firewall_bridge/__init__.py")
fw_ver    = ver_file("/opt/phantom/vendor/firewall_bridge/VERSION")
wg_bridge = ver("/opt/phantom/vendor/wireguard_go_bridge/__init__.py")
wg_ver    = ver_file("/opt/phantom/vendor/wireguard_go_bridge/VERSION")

print(f"  Phantom Daemon        {daemon}")
print(f"  firewall-bridge       {fw_bridge}  (vendor: {fw_ver})")
print(f"  wireguard-go-bridge   {wg_bridge}  (vendor: {wg_ver})")
'''

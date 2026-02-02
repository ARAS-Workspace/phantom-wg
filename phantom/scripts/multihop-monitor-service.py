#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

MULTIHOP MONITOR SERVICE
========================

TR: Multihop VPN bağlantılarını izler ve kesintisiz bağlantıyı sağlar
    ==============================================================
    
    Bu servis, Multihop VPN bağlantılarının durumunu sürekli olarak izler
    ve bağlantı sorunlarını otomatik olarak düzeltir. systemd servisi olarak
    arka planda çalışır ve tüm olayları session log dosyasına kaydeder.
    
    Temel Sorumluluklar:
        1. WireGuard handshake süresini takip etme
        2. Bağlantı sağlığını değerlendirme (Good/Warning/Critical)
        3. Handshake timeout durumunda otomatik yeniden bağlanma
        4. Session log dosyasına durum raporlama
        5. Multihop devre dışı bırakıldığında servisi durdurma
        
    İzleme Döngüsü:
        - Her 30 saniyede bir bağlantı kontrolü
        - Handshake > 180 saniye ise yeniden bağlanma
        - Maksimum 3 yeniden bağlanma denemesi
        - Tüm durumlar session log'a kaydedilir

EN: Monitors Multihop VPN connections and ensures continuous connectivity
    ===================================================================
    
    This service continuously monitors the state of Multihop VPN connections
    and automatically fixes connection issues. Runs as a systemd service in
    the background and logs all events to a session log file.
    
    Core Responsibilities:
        1. Track WireGuard handshake age
        2. Evaluate connection health (Good/Warning/Critical)
        3. Auto-reconnect on handshake timeout
        4. Report status to session log file
        5. Stop service when multihop is disabled
        
    Monitoring Loop:
        - Connection check every 30 seconds
        - Reconnect if handshake > 180 seconds
        - Maximum 3 reconnection attempts
        - All states logged to session file

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import os
import sys
import time
import json
import subprocess
import signal
import logging
import threading
from pathlib import Path
from datetime import datetime


class MultihopMonitorService:
    def __init__(self):
        self.running = True
        self.install_dir = Path("/opt/phantom-wg")
        self.config_file = self.install_dir / "config" / "phantom.json"
        self.session_log_path = self.install_dir / "logs" / "multihop-session-current.log"

        # Settings
        self.CHECK_INTERVAL = 30  # seconds
        self.MAX_HANDSHAKE_AGE = 180  # 3 minutes
        self.RECONNECT_INTERVAL = 10  # seconds
        self.MAX_RECONNECT_ATTEMPTS = 3

        # Stop event
        self._stop_event = threading.Event()

        # Setup logging
        self._setup_logging()

        # Signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

    def _setup_logging(self):
        self.log_level_str = os.environ.get('MULTIHOP_LOG_LEVEL', 'INFO')
        log_level = getattr(logging, self.log_level_str, logging.INFO)

        # Store current log level as numeric value (Python logging standard)
        # DEBUG=10, INFO=20, WARNING=30, ERROR=40
        self.current_log_level = log_level

        # Map custom level names to standard logging levels
        self.level_map = {
            "DEBUG": logging.DEBUG,      # 10
            "INFO": logging.INFO,        # 20
            "SUCCESS": logging.INFO,     # 20 (same as INFO)
            "WARNING": logging.WARNING,  # 30
            "ERROR": logging.ERROR       # 40
        }

        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[logging.StreamHandler()]
        )
        self.logger = logging.getLogger("MultihopMonitor")
        self.logger.info(f"Monitor started with log level: {self.log_level_str}")

    # noinspection PyUnusedLocal
    def _signal_handler(self, signum, frame):
        self.logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
        self._stop_event.set()

    def _load_config(self):
        try:
            with open(self.config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            self.logger.error(f"Failed to load config: {e}")
            return None

    def _check_multihop_state(self):
        config = self._load_config()
        if not config:
            return False, None

        multihop_config = config.get("multihop", {})
        enabled = multihop_config.get("enabled", False)
        active_exit = multihop_config.get("active_exit")

        return enabled, active_exit

    def _run_command(self, cmd: list, timeout: int = None) -> dict:
        """Run command and log output at DEBUG level (inspired by multihop-interface-restore.py:93)."""
        cmd_str = ' '.join(cmd)

        # Log command execution to session log at DEBUG level
        self._log_to_session(f"Executing: {cmd_str}", "DEBUG")

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )

            # Log result details to session log at DEBUG level
            self._log_to_session(f"Return code: {result.returncode}", "DEBUG")
            if result.stdout:
                self._log_to_session(f"stdout: {result.stdout.strip()}", "DEBUG")
            if result.stderr:
                self._log_to_session(f"stderr: {result.stderr.strip()}", "DEBUG")

            return {
                "success": result.returncode == 0,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "returncode": result.returncode
            }

        except subprocess.TimeoutExpired:
            self._log_to_session(f"Command timeout: {cmd_str}", "DEBUG")
            return {
                "success": False,
                "error": f"Timeout after {timeout}s",
                "returncode": -1,
                "stdout": "",
                "stderr": ""
            }
        except Exception as e:
            self._log_to_session(f"Command error: {str(e)}", "DEBUG")
            return {
                "success": False,
                "error": str(e),
                "returncode": -1,
                "stdout": "",
                "stderr": ""
            }

    def _log_to_session(self, message: str, level: str = "INFO"):
        try:
            # Log level filtering using Python logging standard levels
            # Only write if message level >= current level
            message_level_value = self.level_map.get(level, logging.INFO)
            if message_level_value < self.current_log_level:
                return  # Skip writing lower priority messages

            # Create log directory
            self.session_log_path.parent.mkdir(parents=True, exist_ok=True)

            timestamp = datetime.now().strftime('%H:%M:%S')
            with open(self.session_log_path, 'a') as f:
                f.write(f"[{timestamp}] [{level}] {message}\n")
                f.flush()
        except Exception as e:
            self.logger.error(f"Failed to write to session log: {e}")

    def _get_handshake_age(self, interface: str = None) -> int:
        if interface is None:
            # Get interface
            config = self._load_config()
            if config:
                interface = config.get("multihop", {}).get("vpn_interface_name", "wg_vpn")
            else:
                interface = "wg_vpn"
        try:
            cmd_result = self._run_command(['wg', 'show', interface, 'latest-handshakes'], timeout=5)

            if not cmd_result["success"]:
                return -1

            lines = cmd_result["stdout"].strip().split('\n')
            # noinspection DuplicatedCode
            if lines and lines[0]:
                parts = lines[0].split()
                if len(parts) >= 2:
                    timestamp = int(parts[1])
                    current_time = int(time.time())
                    age = current_time - timestamp
                    return age

            return -1

        except Exception as e:
            self.logger.error(f"Failed to get handshake age: {e}")
            return -1

    def _refresh_vpn_connection(self, active_exit: str) -> bool:
        try:
            # Get interface
            config = self._load_config()
            if config:
                vpn_interface = config.get("multihop", {}).get("vpn_interface_name", "wg_vpn")
            else:
                vpn_interface = "wg_vpn"

            # Force re-resolution by resetting listen port
            self._run_command(['wg', 'set', vpn_interface, 'listen-port', '0'])

            time.sleep(2)

            # Check handshake
            new_age = self._get_handshake_age()
            if 0 <= new_age < 10:
                return True

            # Extract endpoint and attempt ping-based reconnection
            exit_config_file = self.install_dir / "exit_configs" / f"{active_exit}.conf"
            if exit_config_file.exists():
                with open(exit_config_file, 'r') as f:
                    config_content = f.read()

                # Extract VPN IP address
                for line in config_content.split('\n'):
                    if line.strip().startswith('Address'):
                        address = line.split('=', 1)[1].strip()
                        vpn_ip = address.split('/')[0]

                        # Send ping to trigger handshake
                        self._run_command(['ping', '-c', '1', '-W', '2', vpn_ip])
                        time.sleep(2)

                        # Check handshake again
                        new_age = self._get_handshake_age()
                        if 0 <= new_age < 10:
                            return True
                        break

            return False

        except Exception as e:
            self.logger.error(f"Failed to refresh VPN connection: {e}")
            return False

    def monitor_loop(self):
        self.logger.info("Multihop monitor service started")
        self._log_to_session("Monitor service started", "INFO")

        while self.running:
            try:
                # Check state
                enabled, active_exit = self._check_multihop_state()

                if not enabled:
                    self.logger.info("Multihop is disabled, shutting down service")
                    self._log_to_session("Monitor stopped - Multihop disabled", "INFO")
                    break

                if not active_exit:
                    self.logger.warning("No active exit configured")
                    time.sleep(self.CHECK_INTERVAL)
                    continue

                # Get age
                handshake_age = self._get_handshake_age()

                # Status logging
                if handshake_age < 0:
                    self._log_to_session("Handshake: No connection", "ERROR")
                elif handshake_age <= 120:
                    self._log_to_session(f"Handshake: {handshake_age}s [Good]", "INFO")
                elif handshake_age <= 180:
                    self._log_to_session(f"Handshake: {handshake_age}s [Warning]", "WARNING")
                else:
                    self._log_to_session(f"Handshake: {handshake_age}s [Critical]", "ERROR")

                # Check reconnection
                if handshake_age > self.MAX_HANDSHAKE_AGE:
                    self._log_to_session(f"Handshake too old ({handshake_age}s), reconnecting...", "WARNING")

                    # Reconnect
                    success = False
                    for attempt in range(1, self.MAX_RECONNECT_ATTEMPTS + 1):
                        self._log_to_session(f"Reconnection attempt {attempt}/{self.MAX_RECONNECT_ATTEMPTS}")

                        if self._refresh_vpn_connection(active_exit):
                            new_age = self._get_handshake_age()
                            self._log_to_session(f"Reconnected - New handshake: {new_age}s", "SUCCESS")
                            success = True
                            break
                        else:
                            self._log_to_session(f"Attempt {attempt} failed", "ERROR")
                            if attempt < self.MAX_RECONNECT_ATTEMPTS:
                                time.sleep(self.RECONNECT_INTERVAL)

                    if not success:
                        self._log_to_session("All reconnection attempts failed", "ERROR")
                        self.logger.error("All reconnection attempts failed")

            except Exception as e:
                self._log_to_session(f"Monitor error: {e}", "ERROR")
                self.logger.error(f"Monitor loop error: {e}")

            # Wait
            remaining = self.CHECK_INTERVAL
            while remaining > 0 and self.running:
                wait_time = min(1, remaining)
                if self._stop_event.wait(timeout=wait_time):
                    break
                remaining -= wait_time

        self.logger.info("Multihop monitor service stopped")


def main():
    # Debug output
    print(f"Starting MultihopMonitorService at {datetime.now()}")

    try:
        service = MultihopMonitorService()
        print(f"Service initialized, config file: {service.config_file}")

        # Check config
        if not service.config_file.exists():
            print(f"ERROR: Config file not found at {service.config_file}")
            sys.exit(1)

        # Check enabled
        # noinspection PyProtectedMember
        enabled, active_exit = service._check_multihop_state()
        print(f"Multihop state - enabled: {enabled}, active_exit: {active_exit}")

        if not enabled:
            service.logger.error("Multihop is not enabled, exiting")
            print("ERROR: Multihop is not enabled, exiting")
            sys.exit(1)

        service.logger.info(f"Starting monitor for exit: {active_exit}")
        print(f"Starting monitor loop for exit: {active_exit}")

        service.monitor_loop()
    except Exception as e:
        print(f"FATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()

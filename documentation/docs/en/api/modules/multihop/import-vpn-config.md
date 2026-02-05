## Multihop Module

The Multihop module routes client traffic through an external VPN provider before
exiting the Phantom server, providing dual-layer encryption and location concealment.
Traffic flow is as follows:

```
Client → Phantom Server (1st encryption) → External VPN Exit (2nd encryption) → Internet
```

This architecture ensures that the destination server only sees the IP address of the
external VPN exit point; the real address of the Phantom server or client remains hidden.
Multihop works by importing standard WireGuard configuration files, making it compatible
with any VPN provider that supports WireGuard.

### Import VPN Configuration

```bash
# Import with automatic name detection
phantom-api multihop import_vpn_config config_path="/home/user/xeovo-uk.conf"

# Import with custom name
phantom-api multihop import_vpn_config config_path="/home/user/vpn.conf" custom_name="xeovo-uk"
```

**Parameters:**

- `config_path` (required): Path to WireGuard configuration file
- `custom_name` (optional): Custom name for the configuration

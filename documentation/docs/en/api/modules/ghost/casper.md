**Exporting Client Configuration with Casper Tool:**

When Ghost Mode is active, clients need to run both a wstunnel client and use a special
WireGuard configuration to connect. The `phantom-casper` tool is a standalone utility
that provides both components together with step-by-step instructions:

```bash
# Export client configuration for Ghost Mode
phantom-casper [username]

# Example with actual client
phantom-casper demo-casper
```

**Example Output:**
```
================================================================================
PHANTOM-WG - GHOST MODE CLIENT CONFIGURATION
================================================================================

Client: demo-casper
Server: 157-230-114-231.sslip.io
Created: 2025-09-09 01:41:50

--------------------------------------------------------------------------------
STEP 1: Start wstunnel client
--------------------------------------------------------------------------------

Run this command in a separate terminal (keep it running):

    wstunnel client --http-upgrade-path-prefix "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac" \
        -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443

--------------------------------------------------------------------------------
STEP 2: WireGuard Configuration
--------------------------------------------------------------------------------

Save the following configuration to a file (e.g., phantom-ghost.conf):

[Interface]
PrivateKey = SI5AXDC9e5ERFwUKBr391MAwSeHIebG4l7R+N7xssVg=
Address = 10.8.0.2/24
DNS = 8.8.8.8, 8.8.4.4
MTU = 1420

[Peer]
PublicKey = Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=
PresharedKey = giiS7QdcN708ovmXPfrikpC+TI4lqQcXTJ5JFfqL06k=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/1, 128.0.0.0/4, 144.0.0.0/5, 152.0.0.0/6, 156.0.0.0/8,
            157.0.0.0/9, 157.128.0.0/10, 157.192.0.0/11, 157.224.0.0/14,
            157.228.0.0/15, 157.230.0.0/18, 157.230.64.0/19, 157.230.96.0/20,
            157.230.112.0/23, 157.230.114.0/25, 157.230.114.128/26,
            157.230.114.192/27, 157.230.114.224/30, 157.230.114.228/31,
            157.230.114.230/32, 157.230.114.232/29, 157.230.114.240/28,
            157.230.115.0/24, 157.230.116.0/22, 157.230.120.0/21,
            157.230.128.0/17, 157.231.0.0/16, 157.232.0.0/13, 157.240.0.0/12,
            158.0.0.0/7, 160.0.0.0/3, 192.0.0.0/2, 10.8.0.0/24
PersistentKeepalive = 25

--------------------------------------------------------------------------------
STEP 3: Connect
--------------------------------------------------------------------------------

Linux/macOS:
    sudo wg-quick up /path/to/phantom-ghost.conf

Windows:
    Import the configuration file in the WireGuard client

To disconnect:
    sudo wg-quick down /path/to/phantom-ghost.conf

================================================================================
NOTE: Keep the wstunnel command running while connected!
================================================================================
```

**Key Features of the Casper Tool:**

- Automatically calculates split routing (AllowedIPs) to exclude server IP --
  this ensures the wstunnel connection itself doesn't go through the VPN tunnel,
  preventing circular routing
- Generates wstunnel client command with correct secret path
- Provides step-by-step connection instructions per platform (Linux/macOS)
- Works with any domain configured in Ghost Mode (including sslip.io/nip.io)
- Endpoint is set to 127.0.0.1:51820; traffic is forwarded to the remote server
  through the local wstunnel client

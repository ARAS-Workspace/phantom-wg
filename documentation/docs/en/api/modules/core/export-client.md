### Export Client Configuration
```bash
# Export client configuration
phantom-api core export_client client_name="john-laptop"
```

**Parameters:**

- `client_name` (required): Client to export

**Response:**
```json
{
  "success": true,
  "data": {
    "client": {
      "name": "john-laptop",
      "ip": "10.8.0.2",
      "created": "2025-09-09T01:14:22.076656",
      "enabled": true,
      "private_key": "INPOjXGUqhzPsS4rE65U7Ao6UXdhXNqwDoQz8HgD53s=",
      "public_key": "SKv9YRp0MgHuMCthVIMBRs4Jfwb+mO3vbfvm9jOrLSY=",
      "preshared_key": "y43/xUvLJBHe7RvsGFoHnURcTzWwrEOcJxx/tT+GQVo="
    },
    "config": "
      [Interface]
      PrivateKey = INPOjXGUqhzPsS4rE65U7Ao6UXdhXNqwDoQz8HgD53s=
      Address = 10.8.0.2/24
      DNS = 8.8.8.8, 8.8.4.4
      MTU = 1420

      [Peer]
      PublicKey = Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=
      PresharedKey = y43/xUvLJBHe7RvsGFoHnURcTzWwrEOcJxx/tT+GQVo=
      Endpoint = 157.230.114.231:51820
      AllowedIPs = 0.0.0.0/0, 10.8.0.0/24
      PersistentKeepalive = 25
    "
  },
  "metadata": {
    "module": "core",
    "action": "export_client",
    "timestamp": "2025-09-09T01:14:43.740027Z",
    "version": "core-v1"
  }
}
```

**Note:** Configuration is dynamically generated from the database and current DNS settings.
QR code generation is available in the CLI interface.

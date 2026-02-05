### Change DNS Servers

Updates the primary and/or secondary DNS servers that all clients will use.
Changes are instantly reflected across all client configurations.

```bash
# Change both DNS servers
phantom-api dns change_dns_servers primary="1.1.1.1" secondary="1.0.0.1"

# Change only primary DNS
phantom-api dns change_dns_servers primary="8.8.8.8"
```

**Parameters:**

- `primary` (optional): Primary DNS server IP
- `secondary` (optional): Secondary DNS server IP

**Response:**
```json
{
  "success": true,
  "data": {
    "success": true,
    "dns_servers": {
      "primary": "1.1.1.1",
      "secondary": "1.0.0.1",
      "previous_primary": "8.8.8.8",
      "previous_secondary": "1.1.1.1"
    },
    "client_configs_updated": {
      "success": true,
      "message": "DNS configuration updated globally"
    }
  },
  "metadata": {
    "module": "dns",
    "action": "change_dns_servers",
    "timestamp": "2025-07-11T05:17:32.309051Z",
    "version": "core-v1"
  }
}
```

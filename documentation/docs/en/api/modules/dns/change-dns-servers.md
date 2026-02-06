### Change DNS Servers

Updates the primary and/or secondary DNS servers that all clients will use.
Changes are instantly reflected across all client configurations.

```bash
phantom-api dns change_dns_servers primary="1.1.1.1" secondary="1.0.0.1"
```

```bash
phantom-api dns change_dns_servers primary="8.8.8.8"
```

**Parameters:**

| Parameter   | Required | Description              |
|-------------|----------|--------------------------|
| `primary`   | No       | Primary DNS server IP    |
| `secondary` | No       | Secondary DNS server IP  |

!!! note
    At least one parameter must be provided. Omitted parameters retain their current values.

**Response Model:** [`ChangeDNSResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L54)

| Field                            | Type    | Description                          |
|----------------------------------|---------|--------------------------------------|
| `success`                        | boolean | Operation completed                  |
| `dns_servers.primary`            | string  | New primary DNS server               |
| `dns_servers.secondary`          | string  | New secondary DNS server             |
| `dns_servers.previous_primary`   | string  | Previous primary DNS server          |
| `dns_servers.previous_secondary` | string  | Previous secondary DNS server        |
| `client_configs_updated.success` | boolean | Client configs updated successfully  |
| `client_configs_updated.message` | string  | Update status message                |

??? example "Example Response"
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
      }
    }
    ```

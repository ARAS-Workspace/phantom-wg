### Get DNS Servers

Retrieves the currently configured primary and secondary DNS servers.

```bash
phantom-api dns get_dns_servers
```

**Response Model:** [`GetDNSServersResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L173)

| Field       | Type   | Description           |
|-------------|--------|-----------------------|
| `primary`   | string | Primary DNS server    |
| `secondary` | string | Secondary DNS server  |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "primary": "8.8.8.8",
        "secondary": "1.1.1.1"
      }
    }
    ```

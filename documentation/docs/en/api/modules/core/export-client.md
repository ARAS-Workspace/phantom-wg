### Export Client Configuration

Exports a client's WireGuard configuration file.

```bash
phantom-api core export_client client_name="john-laptop"
```

**Parameters:**

| Parameter     | Required | Description              |
|---------------|----------|--------------------------|
| `client_name` | Yes      | Client name to export    |

**Response Model:** [`ClientExportResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L147)

| Field                  | Type     | Description                   |
|------------------------|----------|-------------------------------|
| `client.name`          | string   | Client name                   |
| `client.ip`            | string   | Assigned IP address           |
| `client.created`       | datetime | Creation timestamp            |
| `client.enabled`       | boolean  | Active status                 |
| `client.private_key`   | string   | WireGuard private key         |
| `client.public_key`    | string   | WireGuard public key          |
| `client.preshared_key` | string   | WireGuard preshared key       |
| `config`               | string   | Full WireGuard configuration  |

!!! note
    Configuration is dynamically generated from the database and current DNS settings.
    QR code generation is available in the CLI interface.

??? example "Example Response"
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
        "config": "[Interface]\nPrivateKey = ...\nAddress = 10.8.0.2/24\n..."
      },
      "metadata": {
        "module": "core",
        "action": "export_client",
        "timestamp": "2025-09-09T01:14:43.740027Z",
        "version": "core-v1"
      }
    }
    ```

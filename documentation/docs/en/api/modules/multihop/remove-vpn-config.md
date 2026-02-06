### Remove VPN Configuration

Removes an imported VPN exit configuration from the system.

```bash
phantom-api multihop remove_vpn_config exit_name="xeovo-uk"
```

**Parameters:**

| Parameter   | Required | Description                             |
|-------------|----------|-----------------------------------------|
| `exit_name` | Yes      | Name of the VPN configuration to remove |

**Response Model:** [`RemoveConfigResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L116)

| Field        | Type    | Description                              |
|--------------|---------|------------------------------------------|
| `removed`    | string  | Name of removed configuration            |
| `was_active` | boolean | Configuration was active before removal  |
| `message`    | string  | Result message                           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "removed": "xeovo-uk",
        "was_active": false,
        "message": "VPN configuration removed successfully"
      }
    }
    ```

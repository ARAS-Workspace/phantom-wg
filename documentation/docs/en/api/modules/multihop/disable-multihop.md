### Disable Multihop

Disables multihop routing and restores direct traffic flow from Phantom server to the internet.

```bash
phantom-api multihop disable_multihop
```

**Response Model:** [`DeactivationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L100)

| Field               | Type    | Description                              |
|---------------------|---------|------------------------------------------|
| `multihop_enabled`  | boolean | Multihop status (false)                  |
| `previous_exit`     | string  | Previously active exit point             |
| `interface_cleaned` | boolean | VPN interface cleaned up                 |
| `message`           | string  | Result message                           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "multihop_enabled": false,
        "previous_exit": "xeovo-uk",
        "interface_cleaned": true,
        "message": "Multihop disabled successfully"
      }
    }
    ```

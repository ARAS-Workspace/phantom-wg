### List Exit Points

Lists all imported VPN exit configurations and shows the current multihop status.

```bash
phantom-api multihop list_exits
```

**Response Model:** [`ListExitsResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L200)

| Field                          | Type    | Description                              |
|--------------------------------|---------|------------------------------------------|
| `exits[].name`                 | string  | Exit configuration name                  |
| `exits[].endpoint`             | string  | VPN server endpoint                      |
| `exits[].active`               | boolean | Currently active exit                    |
| `exits[].provider`             | string  | VPN provider name                        |
| `exits[].imported_at`          | string  | Import timestamp                         |
| `exits[].multihop_enhanced`    | boolean | Configuration optimized for multihop     |
| `multihop_enabled`             | boolean | Multihop currently enabled               |
| `active_exit`                  | string  | Currently active exit name               |
| `total`                        | integer | Total number of configurations           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "exits": [
          {
            "name": "xeovo-uk",
            "endpoint": "uk.gw.xeovo.com:51820",
            "active": false,
            "provider": "Unknown Provider",
            "imported_at": "2025-09-09T01:16:21.977967",
            "multihop_enhanced": true
          }
        ],
        "multihop_enabled": false,
        "active_exit": null,
        "total": 1
      }
    }
    ```

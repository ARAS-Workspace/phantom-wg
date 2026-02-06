### Disable Ghost Mode

Disables Ghost Mode and restores standard WireGuard connectivity on port 51820.

```bash
phantom-api ghost disable
```

**Response Model:** [`DisableGhostResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L46)

| Field      | Type    | Description                              |
|------------|---------|------------------------------------------|
| `status`   | string  | Ghost Mode status (inactive)             |
| `message`  | string  | Result message                           |
| `restored` | boolean | Direct WireGuard connection restored     |

!!! info "Notes"
    - Restores direct WireGuard connection on port 51820
    - All clients automatically revert to standard WireGuard configuration

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "status": "inactive",
        "message": "Ghost Mode disabled successfully",
        "restored": true
      }
    }
    ```

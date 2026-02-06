### Tweak Settings

View and modify system behavior settings.

```bash
phantom-api core get_tweak_settings
```

```bash
phantom-api core update_tweak_setting setting_name="restart_service_after_client_creation" value=false
```

**Parameters for update_tweak_setting:**

| Parameter      | Required | Description                                |
|----------------|----------|--------------------------------------------|
| `setting_name` | Yes      | Name of the setting to update              |
| `value`        | Yes      | New value (boolean as string: "true"/"false") |

**Available Settings:**

| Setting                               | Default | Description                                    |
|---------------------------------------|---------|------------------------------------------------|
| `restart_service_after_client_creation` | false | Restart WireGuard service after adding clients |

!!! info
    When `false`: Uses `wg set` command to dynamically add clients (no service restart).
    When `true`: Restarts the entire WireGuard service (causes temporary disconnection for all clients).

**Response Model (get):** [`TweakSettingsResponse`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/config_models.py#L22)

**Response Model (update):** [`TweakModificationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/config_models.py#L36)

| Field         | Type    | Description              |
|---------------|---------|--------------------------|
| `setting`     | string  | Setting name             |
| `new_value`   | boolean | New value                |
| `old_value`   | boolean | Previous value           |
| `message`     | string  | Result message           |
| `description` | string  | Setting description      |

??? example "Example Response (get)"
    ```json
    {
      "success": true,
      "data": {
        "restart_service_after_client_creation": false,
        "restart_service_after_client_creation_description": "Restart WireGuard service after adding & removing clients"
      }
    }
    ```

??? example "Example Response (update)"
    ```json
    {
      "success": true,
      "data": {
        "setting": "restart_service_after_client_creation",
        "new_value": true,
        "old_value": false,
        "message": "Setting updated successfully",
        "description": "Restart WireGuard service after adding & removing clients"
      }
    }
    ```

### Tweak Settings
```bash
# Get all tweak settings
phantom-api core get_tweak_settings

# Update a specific setting
phantom-api core update_tweak_setting setting_name="restart_service_after_client_creation" value=false
```

**Parameters for update_tweak_setting:**

- `setting_name` (required): Name of the setting to update
- `value` (required): New value (boolean as string: "true"/"false")

**Available Settings:**

- `restart_service_after_client_creation`: Whether to restart WireGuard service when adding clients
  (default: false)
  - When `false`: Uses `wg set` command to dynamically add clients (no service restart)
  - When `true`: Restarts the entire WireGuard service (causes temporary disconnection for all clients)

**Response for get_tweak_settings:**
```json
{
  "success": true,
  "data": {
    "restart_service_after_client_creation": false,
    "restart_service_after_client_creation_description": "Restart WireGuard service after adding & removing clients (causes connection drops)"
  }
}
```

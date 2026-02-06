### Change Default Subnet

View current subnet info, validate changes, and migrate to a new subnet.

```bash
phantom-api core get_subnet_info
```

```bash
phantom-api core validate_subnet_change new_subnet="192.168.100.0/24"
```

```bash
phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
```

**Parameters for change_subnet:**

| Parameter    | Required | Description                    |
|--------------|----------|--------------------------------|
| `new_subnet` | Yes      | New subnet in CIDR notation    |
| `confirm`    | Yes      | Must be `true` to execute      |

**Response Model:** [`NetworkMigrationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/network_models.py#L155)

| Field             | Type    | Description                  |
|-------------------|---------|------------------------------|
| `success`         | boolean | Migration completed          |
| `old_subnet`      | string  | Previous subnet              |
| `new_subnet`      | string  | New subnet                   |
| `clients_updated` | integer | Number of clients updated    |
| `backup_id`       | string  | Backup identifier            |
| `ip_mapping`      | object  | Old to new IP mapping        |

!!! warning "Important Notes"
    - Subnet changes are blocked when Ghost Mode or Multihop is active
    - All clients will be disconnected during the change
    - Client configurations are automatically updated
    - Firewall rules (iptables and UFW) are automatically updated
    - Full backup is created before changes
    - Automatic rollback on error

??? example "Example Response (get_subnet_info)"
    ```json
    {
      "success": true,
      "data": {
        "current_subnet": "10.8.0.0/24",
        "subnet_size": 254,
        "server_ip": "10.8.0.1",
        "can_change": true,
        "blockers": {
          "ghost_mode": false,
          "multihop": false
        }
      }
    }
    ```

??? example "Example Response (change_subnet)"
    ```json
    {
      "success": true,
      "data": {
        "success": true,
        "old_subnet": "10.8.0.0/24",
        "new_subnet": "192.168.100.0/24",
        "clients_updated": 5,
        "backup_id": "subnet_change_1738257600",
        "ip_mapping": {
          "10.8.0.1": "192.168.100.1",
          "10.8.0.2": "192.168.100.2"
        }
      }
    }
    ```

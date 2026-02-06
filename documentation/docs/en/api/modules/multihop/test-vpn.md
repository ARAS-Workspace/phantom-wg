### Test VPN Connection

Tests the active VPN exit connection by performing connectivity and handshake checks.

```bash
phantom-api multihop test_vpn
```

**Response Model:** [`VPNTestResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L148)

| Field                              | Type    | Description                              |
|------------------------------------|---------|------------------------------------------|
| `exit_name`                        | string  | Tested exit point name                   |
| `endpoint`                         | string  | VPN server endpoint                      |
| `tests.connectivity.passed`        | boolean | Connectivity test passed                 |
| `tests.connectivity.host`          | string  | Tested host                              |
| `tests.handshake.passed`           | boolean | Handshake test passed                    |
| `tests.handshake.has_recent_handshake` | boolean | Recent handshake exists              |
| `tests.ip_check.passed`            | boolean | IP check passed                          |
| `tests.ip_check.vpn_ip`            | string  | VPN exit IP address                      |
| `all_tests_passed`                 | boolean | All tests passed                         |
| `message`                          | string  | Result message                           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "exit_name": "xeovo-uk",
        "endpoint": "uk.gw.xeovo.com:51820",
        "tests": {
          "connectivity": {
            "passed": true,
            "host": "google.com"
          },
          "handshake": {
            "passed": true,
            "has_recent_handshake": true
          },
          "ip_check": {
            "passed": true,
            "vpn_ip": "185.213.155.134"
          }
        },
        "all_tests_passed": true,
        "message": "All VPN tests passed"
      }
    }
    ```

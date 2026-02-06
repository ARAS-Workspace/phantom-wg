### Test DNS Servers

Tests connectivity to DNS servers by resolving a domain name.

```bash
phantom-api dns test_dns_servers
```

```bash
phantom-api dns test_dns_servers servers='["8.8.8.8","1.1.1.1"]'
```

```bash
phantom-api dns test_dns_servers domain="example.com"
```

**Parameters:**

| Parameter | Required | Description                               |
|-----------|----------|-------------------------------------------|
| `servers` | No       | JSON array of DNS servers to test         |
| `domain`  | No       | Domain to resolve (default: "google.com") |

**Response Model:** [`TestDNSResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L92)

| Field                        | Type    | Description                   |
|------------------------------|---------|-------------------------------|
| `all_passed`                 | boolean | All servers passed tests      |
| `servers_tested`             | integer | Number of servers tested      |
| `results[].server`           | string  | DNS server address            |
| `results[].success`          | boolean | Test passed                   |
| `results[].status`           | string  | Status message                |
| `results[].response_time_ms` | float   | Response time in milliseconds |
| `results[].test_domain`      | string  | Domain used for testing       |
| `results[].error`            | string  | Error message if failed       |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "all_passed": true,
        "servers_tested": 2,
        "results": [
          {
            "server": "1.1.1.1",
            "success": true,
            "status": "OK",
            "response_time_ms": null,
            "test_domain": "google.com"
          },
          {
            "server": "1.0.0.1",
            "success": true,
            "status": "OK",
            "response_time_ms": null,
            "test_domain": "google.com"
          }
        ]
      }
    }
    ```

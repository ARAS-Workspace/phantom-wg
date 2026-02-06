### DNS Status

Retrieves DNS configuration and health status including connectivity tests to configured servers.

```bash
phantom-api dns status
```

**Response Model:** [`DNSStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L161)

| Field                                    | Type   | Description                 |
|------------------------------------------|--------|-----------------------------|
| `configuration.primary`                  | string | Primary DNS server          |
| `configuration.secondary`                | string | Secondary DNS server        |
| `health.status`                          | string | Overall health status       |
| `health.test_results[].server`           | string | Tested DNS server           |
| `health.test_results[].tests[].domain`   | string | Tested domain               |
| `health.test_results[].tests[].success`  | any    | Test result (IP or boolean) |
| `health.test_results[].tests[].response` | string | DNS response                |
| `health.test_results[].tests[].error`    | string | Error message if failed     |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "mode": "standard",
        "configuration": {
          "primary": "1.1.1.1",
          "secondary": "1.0.0.1"
        },
        "health": {
          "status": "healthy",
          "test_results": [
            {
              "server": "1.1.1.1",
              "tests": [
                {
                  "domain": "google.com",
                  "success": "142.250.184.206",
                  "response": "142.250.184.206",
                  "error": null
                },
                {
                  "domain": "cloudflare.com",
                  "success": "104.16.133.229",
                  "response": "104.16.133.229",
                  "error": null
                }
              ]
            },
            {
              "server": "1.0.0.1",
              "tests": [
                {
                  "domain": "google.com",
                  "success": "142.250.184.206",
                  "response": "142.250.184.206",
                  "error": null
                },
                {
                  "domain": "cloudflare.com",
                  "success": "104.16.132.229",
                  "response": "104.16.132.229",
                  "error": null
                }
              ]
            }
          ]
        }
      }
    }
    ```

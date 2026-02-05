### DNS Durumu

```bash
phantom-api dns status
```

**Yanıt:**
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
  },
  "metadata": {
    "module": "dns",
    "action": "status",
    "timestamp": "2025-07-11T05:17:52.286147Z",
    "version": "core-v1"
  }
}
```

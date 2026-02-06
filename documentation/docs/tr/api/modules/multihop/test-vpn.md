### VPN Bağlantısını Test Et

Bağlantı ve el sıkışma kontrolleri yaparak aktif VPN çıkış bağlantısını test eder.

```bash
phantom-api multihop test_vpn
```

**Yanıt Modeli:** [`VPNTestResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L148)

| Alan                               | Tip     | Açıklama                                 |
|------------------------------------|---------|------------------------------------------|
| `exit_name`                        | string  | Test edilen çıkış noktası adı            |
| `endpoint`                         | string  | VPN sunucu uç noktası                    |
| `tests.connectivity.passed`        | boolean | Bağlantı testi geçti                     |
| `tests.connectivity.host`          | string  | Test edilen host                         |
| `tests.handshake.passed`           | boolean | El sıkışma testi geçti                   |
| `tests.handshake.has_recent_handshake` | boolean | Yakın zamanda el sıkışma var         |
| `tests.ip_check.passed`            | boolean | IP kontrolü geçti                        |
| `tests.ip_check.vpn_ip`            | string  | VPN çıkış IP adresi                      |
| `all_tests_passed`                 | boolean | Tüm testler geçti                        |
| `message`                          | string  | Sonuç mesajı                             |

??? example "Örnek Yanıt"
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

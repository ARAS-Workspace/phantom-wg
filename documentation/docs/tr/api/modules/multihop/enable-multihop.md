### Multihop'u Etkinleştir

```bash
phantom-api multihop enable_multihop exit_name="xeovo-uk"
```

**Parametreler:**

- `exit_name` (zorunlu): Kullanılacak VPN çıkış noktasının adı

**Yanıt:**
```json
{
  "success": true,
  "data": {
    "exit_name": "xeovo-uk",
    "multihop_enabled": true,
    "handshake_established": true,
    "connection_verified": true,
    "monitor_started": true,
    "traffic_flow": "İstemciler → Phantom → VPN Çıkışı (185.213.155.134:51820)",
    "peer_access": "Eşler hala doğrudan bağlanabilir",
    "message": "Multihop xeovo-uk üzerinden başarıyla etkinleştirildi"
  }
}
```

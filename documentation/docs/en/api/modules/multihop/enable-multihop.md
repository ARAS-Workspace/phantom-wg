### Enable Multihop

```bash
phantom-api multihop enable_multihop exit_name="xeovo-uk"
```

**Parameters:**
- `exit_name` (required): Name of the VPN exit point to use

**Response:**
```json
{
  "success": true,
  "data": {
    "exit_name": "xeovo-uk",
    "multihop_enabled": true,
    "handshake_established": true,
    "connection_verified": true,
    "monitor_started": true,
    "traffic_flow": "Clients → Phantom → VPN Exit (185.213.155.134:51820)",
    "peer_access": "Peers can still connect directly",
    "message": "Multihop successfully enabled via xeovo-uk"
  }
}
```

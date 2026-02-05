## Advanced Usage

The API's JSON output can be easily parsed with tools like `jq` to create monitoring
scripts, automation workflows, and custom dashboards.

### Parse JSON Responses

```bash
# Get client count
phantom-api core list_clients | jq '.data.total'

# Get active connections
phantom-api core server_status | jq '.data.clients.active_connections'

# Check if Ghost Mode is active
phantom-api ghost status | jq '.data.enabled'
```

### Health Monitoring

The following script checks the status of all critical components and alerts when
issues are detected. It can be run as a cron job for continuous monitoring.

```bash
#!/bin/bash
# Monitor system health

# Check WireGuard service
if ! phantom-api core server_status | jq -e '.data.service.running' > /dev/null; then
    echo "WARNING: WireGuard service is not running!"
fi

# Check DNS health
if ! phantom-api dns test_dns_servers | jq -e '.data.all_passed' > /dev/null; then
    echo "WARNING: DNS servers are not responding!"
fi

# Check Multihop if enabled
if phantom-api multihop status | jq -e '.data.enabled' > /dev/null; then
    if ! phantom-api multihop test_vpn | jq -e '.data.all_tests_passed' > /dev/null; then
        echo "WARNING: Multihop VPN test failed!"
    fi
fi
```

---

## Version Information

This documentation covers Phantom-WG API **core-v1**.

> **Note:** Server information, IP addresses, and client data shown in CLI preview
> recordings in this documentation were generated on a test server that was temporarily
> set up solely for creating this content and has been permanently shut down afterward.

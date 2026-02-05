## Common Operations

The following examples demonstrate how the API can be combined with shell scripts and
standard Unix tools to automate daily management tasks.

### Create Multiple Clients

```bash
# Create 100 test clients
for i in {1..100}; do
    phantom-api core add_client client_name="test-client-$i"
done
```

### Export All Client Configurations

```bash
# Export all clients as configuration files
phantom-api core list_clients per_page=1000 | jq -r '.data.clients[].name' | while read client; do
    phantom-api core export_client client_name="$client"
done
```

### Enable Full Censorship Resistance

Ghost Mode and Multihop can be used together to achieve the highest level of censorship
resistance. In this scenario, traffic first passes through an HTTPS tunnel, then reaches
the internet through an external VPN exit.

```bash
# 1. Enable Ghost Mode
phantom-api ghost enable domain="cdn.example.com"

# 2. Import external VPN
phantom-api multihop import_vpn_config config_path="/path/to/vpn-exit.conf"

# 3. Enable Multihop
phantom-api multihop enable_multihop exit_name="vpn-exit"
```

### Full System Check

```bash
# Check all components
phantom-api core server_status
phantom-api dns status
phantom-api ghost status
phantom-api multihop status
```

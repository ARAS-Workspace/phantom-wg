---
id: core
label: Core
mini_desc: Cockpit
title: Core Module
subtitle: Phantom-WG Cockpit
icon: rocket
order: 1
---
<!--suppress HtmlUnknownTarget -->
<div class="module-hero-image">
  <img src="/assets/images/ghost-cockpit.jpg" alt="Phantom-WG Cockpit" />
</div>

The Core module is the heart of **Phantom-WG** and provides fundamental WireGuard server management
operations. It consolidates essential functions such as client creation, configuration generation, firewall
management, service monitoring, and health tracking under a single interface.

**Core Module Key Functions:**

- **WireGuard Interface Management**: Configuration and control of the main WireGuard interface
- **Client Management**: Client creation, removal, listing, and configuration export
- **Cryptographic Key Generation**: Automated private, public, and preshared key generation for WireGuard
- **IP Allocation**: Automatic IP address allocation within the subnet with collision detection
- **Firewall Configuration**: UFW and iptables rule management
- **Service Monitoring**: WireGuard service health checks
- **Network Management**: Subnet changes and migration operations

## How It Works

Your Core traffic follows this path:

- **Core Flow**: Clients → Phantom-WG (Port 51820) → Internet

## Quick Start

### Client Management

Create a new client:

```bash
phantom-api core add_client client_name="ghost"
```

Export client configuration:

```bash
phantom-api core export_client client_name="ghost"
```

Remove a client:

```bash
phantom-api core remove_client client_name="ghost"
```

List clients (with pagination and search support):

```bash
phantom-api core list_clients page=1 per_page=10
```

```bash
phantom-api core list_clients search="ghost"
```

View the most recently added clients:

```bash
phantom-api core latest_clients count=5
```

### Server and Service Operations

Get comprehensive server status information:

```bash
phantom-api core server_status
```

View WireGuard service logs:

```bash
phantom-api core service_logs lines=50
```

Restart the WireGuard service:

```bash
phantom-api core restart_service
```

Check firewall configuration status:

```bash
phantom-api core get_firewall_status
```

### Network Configuration

View current subnet information:

```bash
phantom-api core get_subnet_info
```

Validate the new subnet (before applying changes):

```bash
phantom-api core validate_subnet_change new_subnet="192.168.100.0/24"
```

Change the subnet (requires confirmation):

```bash
phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
```
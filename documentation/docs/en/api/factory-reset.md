## Factory Reset

A standalone factory reset script is used to restore Phantom-WG to its initial
installation state. This operation is performed not via the API, but by running a script
directly on the server:

```bash
/opt/phantom-wg/phantom/factory-reset.sh
```

This script performs the following operations in sequence:
- Stops all active services (Ghost Mode, Multihop, WireGuard)
- Deletes all client configurations and key information
- Removes all logs, state files, and session data
- Generates new server key pair
- Resets the system to initial installation state
- Preserves SSH port configuration (your server access won't be interrupted)

**Warning:** This is an irreversible operation. No backup is created and all data is
permanently deleted. Factory reset should only be used when you want to completely
reset the system.

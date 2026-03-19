-- phantom-daemon device.db — Schema v0.1
--
-- WAL mode
--
-- IPC state persistence for wireguard-go PersistentDevice.
-- Go opens this DB, restores state on startup, persists on every IpcSet.

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS ipc_state (
    id    INTEGER PRIMARY KEY,
    dump  TEXT
);
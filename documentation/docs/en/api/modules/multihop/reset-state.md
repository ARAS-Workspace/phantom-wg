### Reset Multihop State

Resets the multihop state by cleaning up interfaces, routing rules, and monitor processes.

```bash
phantom-api multihop reset_state
```

**Response Model:** [`ResetStateResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L166)

| Field               | Type    | Description                              |
|---------------------|---------|------------------------------------------|
| `reset_complete`    | boolean | Reset completed successfully             |
| `cleanup_successful`| boolean | Cleanup operations successful            |
| `cleaned_up`        | array   | List of cleaned up items                 |
| `message`           | string  | Result message                           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "reset_complete": true,
        "cleanup_successful": true,
        "cleaned_up": [
          "wg-multihop interface",
          "routing rules",
          "monitor process"
        ],
        "message": "Multihop state reset successfully"
      }
    }
    ```

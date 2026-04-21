# phantom-stream-tool

Cloudflare Stream ops CLI for Phantom-WG. Upload videos, list them, fetch info, delete them. Returns UUID by default or full JSON when you ask for it.

## Install

```sh
cd tools/phantom-stream-tool
npm install
npm link            # makes `phantom-stream-tool` available globally
```

Verify:

```sh
phantom-stream-tool --version
```

## Configure

Copy the template and fill in your Cloudflare credentials:

```sh
cp secrets/.env.example secrets/.env
# Edit secrets/.env — it is git-ignored.
```

Or set them via CLI (writes to the same `secrets/.env`):

```sh
phantom-stream-tool config set api-token=<your-token>
phantom-stream-tool config set account-id=<your-account-id>
phantom-stream-tool config list
```

Credential resolution order (highest wins):
1. `--api-token` / `--account-id` flags
2. `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` env variables
3. `secrets/.env` (loaded via dotenv on every invocation)

## Usage

### Upload

```sh
phantom-stream-tool upload ./tutorial.mp4
# → abc123def456

phantom-stream-tool upload ./tutorial.mp4 --output=json
# → full Cloudflare Stream API response (pretty-printed)

phantom-stream-tool upload ./tutorial.mp4 \
  --name="Ghost Mode Setup" \
  --thumbnail-pct=0.1 \
  --allowed-origin=phantom.tc \
  --allowed-origin=www.phantom.tc \
  --meta=category=tutorials \
  --meta=chapter=setup
```

### List

```sh
phantom-stream-tool list                       # formatted table
phantom-stream-tool list --output=json
phantom-stream-tool list --status=ready --limit=50 --asc
phantom-stream-tool list --search="ghost"
```

### Info

```sh
phantom-stream-tool info <uuid>                      # human-readable details
phantom-stream-tool info <uuid> --output=uuid        # just the UUID (echo)
phantom-stream-tool info <uuid> --output=json        # raw API response
```

### Delete

```sh
phantom-stream-tool delete <uuid>          # confirm prompt
phantom-stream-tool delete <uuid> --yes    # skip prompt
```

### Config

```sh
phantom-stream-tool config set api-token=xxx account-id=yyy
phantom-stream-tool config get api-token
phantom-stream-tool config list            # masked display
```

## Options Reference

All passthrough options map 1-to-1 onto fields defined by the Cloudflare
Stream API. See the upstream docs for field semantics and accepted values:

- Upload (POST `/stream`) → [`create` endpoint](https://developers.cloudflare.com/api/resources/stream/methods/create/)
- Edit (POST `/stream/{uid}`) → [`edit` endpoint](https://developers.cloudflare.com/api/resources/stream/methods/edit/)
- List (GET `/stream`) → [`list` endpoint](https://developers.cloudflare.com/api/resources/stream/methods/list/)
- Video object shape → [Video resource](https://developers.cloudflare.com/api/resources/stream/)

### `upload` — CLI flag → CF API field

Cloudflare's direct-upload endpoint carries only the file itself. Any
metadata option below is applied with a second call to
`POST /stream/{uid}` that runs immediately after the upload succeeds.

| CLI flag                      | CF API field                    | Notes                                                                      |
|-------------------------------|---------------------------------|----------------------------------------------------------------------------|
| `--name <name>`               | `meta.name`                     | Merged into the `meta` JSON object. Defaults to the filename (no ext).     |
| `--meta <key=value>`          | `meta.<key>`                    | Repeatable. Each entry becomes a field on the `meta` JSON object.          |
| `--require-signed-urls`       | `requireSignedURLs`             | Boolean flag — video will not play without a signed URL.                   |
| `--allowed-origin <origin>`   | `allowedOrigins[]`              | Repeatable. Collected into an array on the patch body.                     |
| `--thumbnail-pct <number>`    | `thumbnailTimestampPct`         | Float 0.0–1.0. Position of the still thumbnail in the video.               |
| `--scheduled-deletion <iso>`  | `scheduledDeletion`             | ISO-8601 timestamp. Video is deleted automatically at that time.           |
| `--creator <id>`              | `creator`                       | Opaque identifier stored with the video.                                   |
| `--output <format>`           | —                               | `uuid` (default) or `json`. Tool-local, not sent to CF.                    |
| `--api-token <token>`         | —                               | Overrides `CLOUDFLARE_API_TOKEN` for one call.                             |
| `--account-id <id>`           | —                               | Overrides `CLOUDFLARE_ACCOUNT_ID` for one call.                            |

### `list` — CLI flag → CF API query parameter

| CLI flag                      | CF API query parameter          | Notes                                                                      |
|-------------------------------|---------------------------------|----------------------------------------------------------------------------|
| `--search <query>`            | `search`                        | Fuzzy match on video name.                                                 |
| `--status <state>`            | `status`                        | One of `ready`, `inprogress`, `queued`, `error`.                           |
| `--creator <id>`              | `creator`                       | Filter by creator identifier.                                              |
| `--before <iso>`              | `before`                        | ISO-8601 — videos created strictly before this timestamp.                  |
| `--after <iso>`               | `after`                         | ISO-8601 — videos created strictly after this timestamp.                   |
| `--asc`                       | `asc=true`                      | Sort ascending by creation time (default is descending).                   |
| `--limit <n>`                 | `limit`                         | Positive integer. Cloudflare caps at 1000.                                 |
| `--output <format>`           | —                               | `table` (default) or `json`. Tool-local, not sent to CF.                   |

### `info` and `delete`

Both take a UID argument and expose only tool-local options (`--output`,
credential overrides). See `phantom-stream-tool info --help` and
`phantom-stream-tool delete --help` for the full list.

## Notes

- Direct upload supports files up to 200 MB (Cloudflare Stream limit). Beyond that, a separate TUS resumable flow would be needed.
- `secrets/.env` is loaded via `dotenv` at every invocation. Shell-exported env variables take precedence over file values.
- `CLOUDFLARE_CUSTOMER_SUBDOMAIN` is auto-captured from the first playback URL returned by CF and persisted to `secrets/.env` so it's available for HTML embed construction.
- Debug stack traces: set `DEBUG=1` in the environment.
- Any flag not listed above is not yet plumbed through. Extending it is usually a matter of adding the option to the CLI, the typedef, and the REST client — all in the same pattern.

<!--
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
-->

# Privacy Notice — install.phantom.tc

**Last Updated:** January 2026

## Overview

`install.phantom.tc` is a Cloudflare Worker that serves the Phantom-WG bootstrap install script. It is maintained entirely from the [phantom-wg](https://github.com/ARAS-Workspace/phantom-wg) GitHub repository and deployed automatically via GitHub Actions (`.github/workflows/deploy-phantom-install.yml`).

## Source Code & Deployment

- **Source:** [`tools/phantom-install/`](https://github.com/ARAS-Workspace/phantom-wg/tree/main/tools/phantom-install)
- **Deployment:** GitHub Actions workflow, triggered on pushes to `main` that modify the `tools/phantom-install/**` path
- **Runtime:** Cloudflare Workers (stateless, no persistent storage)

## Endpoints & Data Handling

| Endpoint          | Method | Purpose                                                                | Data Handling                                                                                                   |
|-------------------|--------|------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| `/` or `/install` | GET    | Returns the install shell script                                       | Static file served; no data collected                                                                           |
| `/ip`             | GET    | Returns the caller's public IP address (via `CF-Connecting-IP` header) | IP is reflected back to the caller in the response body; it is **not** stored, logged, or transmitted elsewhere |
| `/health`         | GET    | Returns `OK` for health checks                                         | No data collected                                                                                               |

All other paths return a `404 Not Found` response.

## What This Service Does NOT Do

- **No analytics.** The Worker code contains no analytics, tracking, or usage measurement of any kind.
- **No telemetry.** No data is sent to any external service, third party, or reporting endpoint.
- **No logging.** The Worker does not write request data to any log, file, or database.
- **No database or persistent storage.** The Worker is entirely stateless — it does not use Cloudflare KV, D1, R2, Durable Objects, or any other storage mechanism.
- **No cookies or fingerprinting.** No cookies are set, and no client fingerprinting is performed.
- **No user accounts or authentication.** The service is fully public and anonymous.

## Cloudflare Infrastructure Note

As a Cloudflare Worker, this service runs on Cloudflare's global network. Cloudflare may collect operational metrics (such as request counts and error rates) through its own infrastructure dashboard, as is standard for any service running on their platform. This is inherent to the Cloudflare platform and is not controlled by the Worker code. For details, see [Cloudflare's Privacy Policy](https://www.cloudflare.com/privacypolicy/).

## Open Source & Transparency

The entire source code of this Worker, its deployment workflow, and its configuration are publicly available in the [phantom-wg](https://github.com/ARAS-Workspace/phantom-wg) repository. Every deployment is triggered from the public repository — there is no separate, private codebase.

## Changes to This Notice

This privacy notice may be updated as the service evolves. Changes will be reflected in this file with an updated date.

## Contact

For questions about this privacy notice or the install.phantom.tc service:

**Rıza Emre ARAS** — [r.emrearas@proton.me](mailto:r.emrearas@proton.me)

<!--
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
-->

# Privacy Notice — Phantom Deployment Wizard

**Last Updated:** January 2026

## Overview

Phantom Deployment Wizard is an open-source, self-hosted deployment tool that helps you provision a VPS server with Phantom-WG pre-installed. This notice explains what data the tool handles, how it flows, and what third-party services are involved.

## Third-Party Disclaimer

**Phantom-WG has no affiliation, partnership, or business relationship with SporeStack.** SporeStack is an independent third-party VPS hosting provider. This tool integrates with the SporeStack API solely because it offers a straightforward, privacy-respecting API that accepts cryptocurrency payments without requiring personal identity verification. SporeStack's own privacy and acceptable use policies apply independently to their service.

For SporeStack's policies, visit: [sporestack.com](https://sporestack.com/)

## What Data Does This Tool Collect?

### Data You Provide

| Data                   | Purpose                                                                | Where It Goes                                               |
|------------------------|------------------------------------------------------------------------|-------------------------------------------------------------|
| **SporeStack Token**   | Authenticates your SporeStack account                                  | Sent to SporeStack API for validation and server management |
| **SSH Public Key**     | Grants you SSH access to the deployed server                           | Sent to SporeStack API, which provisions it on the server   |
| **Provider Selection** | Determines which cloud provider hosts your server (Vultr/DigitalOcean) | Sent to SporeStack API as a deployment parameter            |
| **Region Selection**   | Determines the geographic location of your server                      | Sent to SporeStack API as a deployment parameter            |
| **Operating System**   | Determines the OS installed on your server                             | Sent to SporeStack API as a deployment parameter            |
| **Server Size**        | Determines the hardware specifications of your server                  | Sent to SporeStack API as a deployment parameter            |
| **Rental Period**      | Determines how long the server is rented                               | Sent to SporeStack API as a deployment parameter            |

### Data Generated During Use

| Data                               | Purpose                                            | Where It Goes                                                        |
|------------------------------------|----------------------------------------------------|----------------------------------------------------------------------|
| **SSH Private Key** (if generated) | Allows you to connect to the server via SSH        | Displayed once in your browser — **never sent to any server or API** |
| **Machine ID**                     | Identifies your deployed server for status polling | Received from SporeStack API, stored in browser session              |
| **Server IPv4 Address**            | The public IP of your deployed server              | Received from SporeStack API, stored in browser session              |
| **Deployment Configuration**       | Summary of all selected options                    | Stored in browser session; optionally exported as JSON by you        |

## Data Storage

### No Persistent Storage

This tool does **not** use any database, log file, or persistent storage mechanism. All data exists exclusively in your browser's Streamlit session state and is automatically discarded when:

- You close your browser tab
- Your browser session expires
- You click "Start Over" in the wizard

### No Server-Side Logs

The Streamlit application does not write user data to disk. Container logs (if running via Docker) contain only application-level operational messages, not user inputs or API tokens.

### Optional Export

At the end of the deployment process, you may choose to download your deployment configuration as a JSON file. This file contains your selected provider, region, OS, flavor, rental period, server IP, and machine ID. **It does not contain your SporeStack token or SSH private key.**

## External Network Connections

This tool makes outbound connections to the following services:

### 1. SporeStack API (`api.sporestack.com`)
- **Purpose:** Token validation, infrastructure queries (regions, OS, flavors), pricing quotes, server deployment, and status polling
- **Protocol:** HTTPS
- **Authentication:** Your SporeStack token (sent as part of the URL path)
- **Data sent:** Token, SSH public key, deployment parameters (provider, region, OS, flavor, days, cloud-init script)

### 2. Tor Project Check API (`check.torproject.org`) — Production Mode Only
- **Purpose:** Verifies whether the wizard is routing traffic through Tor
- **Protocol:** HTTPS
- **Data sent:** Standard HTTP request (no user data)
- **Data received:** Tor connection status and exit node IP address
- **When:** Only when the tool runs in Tor mode (`TOR_MODE=1`)

### 3. Phantom Install Script (`install.phantom.tc`) — Server-Side Only
- **Purpose:** Installs Phantom-WG on the deployed server
- **Protocol:** HTTPS
- **Important:** This connection is made **by your deployed server** via cloud-init, **not** by the wizard application itself

## What This Tool Does NOT Do

- **No analytics or telemetry.** Streamlit's built-in usage statistics are explicitly disabled (`gatherUsageStats = false`).
- **No tracking cookies or fingerprinting.** No third-party tracking scripts are loaded.
- **No user accounts or registration.** The tool does not create or manage user accounts.
- **No data sharing.** Your data is not shared with anyone other than SporeStack (as required to deploy your server).
- **No data retention.** Nothing persists after your session ends.
- **No payment processing.** All payments are handled entirely by SporeStack. This tool never handles wallet addresses, transaction IDs, or payment details.

## Tor Routing (Production Deployment)

When deployed as a Tor hidden service (using `docker-compose.hidden.yml`), all outbound traffic from the wizard — including SporeStack API calls — is routed through the Tor network. This means:

- Your real IP address is not exposed to SporeStack
- The wizard is accessible via a `.onion` address
- DNS resolution occurs through Tor

This is an optional deployment configuration. When running locally or without the Tor setup, your regular network connection is used.

## SSH Key Security

If you choose to generate an SSH keypair within the wizard:

- The **private key** is generated locally using a 4096-bit RSA algorithm (via the `paramiko` library)
- The private key is displayed **once** in your browser for you to copy
- The private key is held in browser session memory only — it is **never transmitted** to any API or server
- The **public key** is sent to SporeStack so it can be provisioned on your server

If you import an existing SSH public key, only the public key is processed. The wizard never asks for or handles your existing private key.

## Cloud-Init Script

The deployment includes a cloud-init script that runs on first boot of your server. This script:

1. Updates system packages
2. Installs `curl`
3. Downloads and runs the Phantom-WG installer from `install.phantom.tc`

The cloud-init script is visible and reviewable within the wizard before deployment (under "View Cloud Init Script"). For Vultr deployments, the script is base64-encoded before transmission; for DigitalOcean, it is sent as plaintext. In both cases, the content is identical.

## Open Source and Transparency

Phantom-WG is an open-source project. The entire codebase — including this deployment wizard, its CI/CD pipeline, and all infrastructure configurations — is publicly available and auditable on GitHub.

The wizard's production deployment (Tor hidden service) is managed directly from the repository through a GitHub Actions workflow (`.github/workflows/phantom-wizard-hidden-deployment-workflow.yml`). This means:

- **Every code change is traceable.** All updates to the wizard trigger the deployment pipeline from the public repository.
- **No hidden modifications.** The production instance is built and deployed from the same source code you can inspect on GitHub.
- **Auditable pipeline.** The workflow configuration, deployment scripts, and Docker configurations are all part of the public repository.

This approach ensures that the tool you use matches the source code you can review — there is no separate, private codebase.

## Your Rights and Control

- **Transparency:** All source code is open-source and auditable on GitHub
- **Verifiable deployment:** The production instance is deployed via a public CI/CD pipeline directly from the repository
- **Review before deploy:** The wizard shows you the exact API request body and cloud-init script before you confirm deployment
- **No lock-in:** The deployed server is a standard VPS — you have full root access via SSH
- **Session control:** Click "Start Over" at any time to clear all session data
- **Export control:** You choose whether to download the deployment configuration JSON

## Changes to This Notice

This privacy notice may be updated as the tool evolves. Changes will be reflected in this file with an updated date. Since the tool is self-hosted, you always have access to the version of this notice that corresponds to the version of the tool you are running.

## Contact

For questions about this privacy notice or the Phantom Deployment Wizard:

**Rıza Emre ARAS** — [r.emrearas@proton.me](mailto:r.emrearas@proton.me)
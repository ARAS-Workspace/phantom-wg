# ADR-0011 — Configuration Reading Follows WireGuardKit's Rules, The Leak Guards Stay

## Status

Accepted — 2026-11-16

This record captures a new decision. It does not narrow an accepted record.

- Feature: .conf reading follows WireGuardKit's rules, leak guards kept ([8e2d4d4](https://github.com/ARAS-Workspace/phantom-wg/commit/8e2d4d4594d2566cc293d099a3cd3b3fe2f7f750))

- Feature: DNS search domains and ListenPort reach the tunnel ([5b3bbaa](https://github.com/ARAS-Workspace/phantom-wg/commit/5b3bbaaef4cfb36527ecbb0ae0d16bac4d2f2d56))

## Context

**Source:** `Phantom-WG-MacOS/Domain/Parsing/ConfParser.swift`, `Phantom-WG-MacOS/Domain/Configuration/ConfigTypes.swift`, `Phantom-WG-MacOS/Models/Drafts/TunnelDrafts.swift`, `Phantom-WG-MacOS/Domain/Configuration/TunnelConfig.swift`, `PhantomTunnel/Features/WireGuardTunnel/WireGuardConfigBuilder.swift`. Commits [`8e2d4d4`](https://github.com/ARAS-Workspace/phantom-wg/commit/8e2d4d4594d2566cc293d099a3cd3b3fe2f7f750) and [`5b3bbaa`](https://github.com/ARAS-Workspace/phantom-wg/commit/5b3bbaaef4cfb36527ecbb0ae0d16bac4d2f2d56).

The app reads `.conf` text with its own parser. The import screen, the edit screen and the bulk import from the gear menu take the same path. The text is first split into sections by `ConfParser`, then validated by `validate()` in `TunnelDrafts`.

WireGuard's official app reads the same text with WireGuardKit's `wg-quick` parser. This app's tunnel extension uses WireGuardKit too. The two readings had drifted apart. In a real configuration file the `Address` value carried no prefix. The WireGuard app accepted the file and the tunnel ran. This app refused the same file.

The drift was not limited to one field. The earlier reading read some values more strictly than WireGuardKit and some lines more loosely. The defaults also differed from WireGuardKit's.

### Divergences

| Subject                                 | Earlier reading                 | WireGuardKit                    | With this decision                                                                   |
|-----------------------------------------|---------------------------------|---------------------------------|--------------------------------------------------------------------------------------|
| Address without a prefix                | Refused                         | Read as IPv4 `/32`, IPv6 `/128` | As in WireGuardKit                                                                   |
| Prefix past the limit                   | Refused                         | Clamped to the limit            | As in WireGuardKit                                                                   |
| No `MTU`                                | `1420`, accepted range 576–9200 | No value, automatic             | `0` means automatic, accepted range 0–65535                                          |
| No `PersistentKeepalive`                | `25`                            | No value, off                   | `0` means off                                                                        |
| Non-IP `DNS` entry                      | Refused                         | Becomes a search domain         | As in WireGuardKit                                                                   |
| `ListenPort`                            | Not read                        | Read                            | Read, accepted range 0–65535                                                         |
| Inline `#` comment                      | Stays part of the value         | Dropped                         | Dropped in the `[Interface]` and `[Peer]` sections, kept in the `[Wstunnel]` section |
| Unknown key                             | Silently ignored                | Error                           | Error                                                                                |
| Unknown section                         | Silently ignored                | Error                           | Error                                                                                |
| Line without `=`                        | Silently skipped                | Error                           | Error                                                                                |
| Repeated singular key                   | The last value wins             | Error                           | Error                                                                                |
| Repeated `Address`, `AllowedIPs`, `DNS` | Merged                          | Merged                          | Unchanged                                                                            |

The `[Wstunnel]` section belongs to this app and does not exist in WireGuardKit. The values of this section can carry the `#` character, so an inline comment is not dropped there.

### Deliberate Deviations

WireGuardKit accepts four cases. This app keeps refusing all four.

| Subject                               | WireGuardKit | This app                                                                      | Why                                                                                                                                                                 |
|---------------------------------------|--------------|-------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Empty `Address`                       | Accepts      | `validate()` refuses, `WireGuardConfigBuilder` refuses again in the extension | An interface without an address carries no traffic. A refusal is given instead of a tunnel that looks successful but does not work.                                 |
| Empty `AllowedIPs`                    | Accepts      | `validate()` refuses, `WireGuardConfigBuilder` refuses again in the extension | With a peer that has no route the tunnel shows `.active` but traffic flows outside the tunnel. This is a leak.                                                      |
| Standalone peer without an `Endpoint` | Accepts      | The parser refuses, `WireGuardConfigBuilder` refuses again in the extension   | This client starts the connection itself. A handshake cannot be sent to a peer without an endpoint. In Ghost mode the endpoint comes from the `[Wstunnel]` section. |
| More than one `[Peer]`                | Accepts      | A second `[Peer]` section is refused                                          | The tunnel model and the vault payload carry one peer. This model is described in the context of [ADR-0005](0005-system-keychain-tunnel-vault.md).                  |

### Measurements

- **Real file (2026-11-15):** the configuration that carries an `Address` without a prefix and was refused before is now imported as it is.
- **Search domain (2026-11-15):** the imported search domain shows in the `scutil --dns` output on the tunnel extension's `utun` resolver.
- **Harness, ConfigContract (2026-11-16):** the search domain and `ListenPort` survive `validate()`, the encoding and decoding of the vault payload, and the written `.conf` text. A payload written before the two keys existed decodes without a search domain and without a listen port. A `DNS` value made of commas only reads as no DNS server, as in WireGuard.
- **Harness, leak guard (2026-11-16):** the tunnel set up with an empty `AllowedIPs` did not become `.active`. The extension refused the configuration with `savedProtocolConfigurationIsInvalid`.

## Decision

Configuration reading follows WireGuardKit's rules. In the four cases that lead to a leak or to a tunnel that does not work, this app keeps refusing. Concretely:

1. **The reading rules are WireGuardKit's.** The last column of the "Divergences" table holds on the import screen, on the edit screen and in the bulk import. An error names the key or the line.

2. **Missing values are WireGuardKit's empty values.** Without `MTU`, `0` is written and means automatic. Without `PersistentKeepalive`, `0` is written and means off. The extension does not pass the value `0` to WireGuardKit, and WireGuardKit reads a field with no value as automatic or off. The detail screen shows these two cases as "Automatic" and "Off".

3. **Search domains and the listen port reach the tunnel.** The `interface` part of the vault payload carries the `dns_search` and `listen_port` keys. A payload written without these two keys decodes without an error. The extension passes both to WireGuardKit. The copied and exported `.conf` text writes both back. The detail screen shows both only when they have a value.

4. **The leak guards stay in two layers.** The four cases in the "Deliberate Deviations" table are refused in the app by `validate()` or by the parser. An empty `Address`, an empty `AllowedIPs` and a standalone peer without an `Endpoint` are refused once more in the extension by `WireGuardConfigBuilder`. A payload written to the vault without passing the app's validation is not set up as a tunnel either.

## Consequences

- Configurations the WireGuard app accepts are accepted here too. The cases where this app departs are listed in the "Deliberate Deviations" table.
- The reading became stricter in some places. An unknown key, an unknown section and a line that is not understood, which were silently ignored before, now give an error. A file that carries `wg-quick` keys such as `PostUp` or `Table` is now refused. The WireGuard app refuses these keys as well.
- Configurations without `MTU` and `PersistentKeepalive` are now set up with an automatic MTU and with keepalive off, not with `1420` and `25`. A user who wants these two values writes them in the file explicitly.
- The vault payload gained two keys that carry no secret. The fields that carry secrets did not change.
- `ConfigTypes.swift`, which the extension also compiles, reads an address without a prefix and a prefix past the limit as WireGuardKit does. Vault records are always written with a prefix, so the values the extension reads do not change because of this.
- Installed 2.1.x extensions do not carry the search domain and the listen port to the tunnel. These two fields take effect once the new version is installed.

## Related Records

- [ADR-0005](0005-system-keychain-tunnel-vault.md): the model of the vault payload. The model gained two fields that carry no secret. The record's decision did not change.
- [ADR-0001](0001-architectural-decision-records.md) item 6: the scope of this record. The record holds only the decision on the reading rules. It does not describe the whole structure of the parser.

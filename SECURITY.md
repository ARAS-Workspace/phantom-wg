<!--
Phantom-WG
Copyright (C) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Security Policy / Güvenlik Politikası

---

## 🇺🇸

### Reporting a Vulnerability

If you discover a security vulnerability in Phantom-WG, please report it through the channels below. You can use the PGP key for encrypted communication.

### Contact

| Method       | Address                                |
|--------------|----------------------------------------|
| Email        | issue@phantom.tc, r.emrearas@proton.me |
| GitHub Issue | For non-sensitive issues only          |

### Supported Components

Each component lives on its own branch. Reports are accepted for every component
marked **Supported**, on either its release branch or its development branch.

| Component            | Branch                     | Scope                                       |
|----------------------|----------------------------|---------------------------------------------|
| Phantom-WG Modern    | `main`                     | Supported — released server product         |
| daemon + panel       | `dev/daemon`               | Supported — development branch of Modern    |
| auth-service         | `dev/auth-service`         | Supported — ships inside Modern             |
| firewall-bridge      | `dev/firewall-bridge`      | Supported — ships inside Modern             |
| wireguard-go-bridge  | `dev/wireguard-go-bridge`  | Supported — ships inside Modern             |
| Phantom-Frontmatter  | `frontmatter`              | Supported — WSS/TLS transport layer         |
| Phantom-WG Mac       | `app/mac`                  | Supported — macOS client                    |
| Phantom-WG iOS       | `app/ios`                  | Supported — iOS client                      |
| Documentation & site | `press-kit`                | Supported — www.phantom.tc and the docs     |
| compose-bridge       | `dev/tests/compose-bridge` | Out of scope — test dependency, not shipped |

---

## 🇹🇷

### Güvenlik Açığı Bildirimi

Phantom-WG'de bir güvenlik açığı keşfettiyseniz, aşağıdaki kanallar üzerinden bildirebilirsiniz. Şifreli iletişim için PGP anahtarını kullanabilirsiniz.

### İletişim

| Yöntem       | Adres                                  |
|--------------|----------------------------------------|
| E-posta      | issue@phantom.tc, r.emrearas@proton.me |
| GitHub Issue | Yalnızca hassas olmayan konular için   |

### Desteklenen Bileşenler

Her bileşen kendi dalında yaşar. **Destekleniyor** işaretli her bileşen için,
yayın dalı ya da geliştirme dalı üzerinden bildirim kabul edilir.

| Bileşen              | Dal                        | Kapsam                                        |
|----------------------|----------------------------|-----------------------------------------------|
| Phantom-WG Modern    | `main`                     | Destekleniyor — yayındaki sunucu ürünü        |
| daemon + panel       | `dev/daemon`               | Destekleniyor — Modern'in geliştirme dalı     |
| auth-service         | `dev/auth-service`         | Destekleniyor — Modern içinde dağıtılır       |
| firewall-bridge      | `dev/firewall-bridge`      | Destekleniyor — Modern içinde dağıtılır       |
| wireguard-go-bridge  | `dev/wireguard-go-bridge`  | Destekleniyor — Modern içinde dağıtılır       |
| Phantom-Frontmatter  | `frontmatter`              | Destekleniyor — WSS/TLS taşıma katmanı        |
| Phantom-WG Mac       | `app/mac`                  | Destekleniyor — macOS istemcisi               |
| Phantom-WG iOS       | `app/ios`                  | Destekleniyor — iOS istemcisi                 |
| Döküman ve site      | `press-kit`                | Destekleniyor — www.phantom.tc ve dökümanlar  |
| compose-bridge       | `dev/tests/compose-bridge` | Kapsam dışı — test bağımlılığı, dağıtılmaz    |

---

## PGP Public Key

**Fingerprint:** `9F27 149D 11B3 651F E276  668E 92C7 9989 BA17 D56B`

🇺🇸 The same key signs every commit in this repository — verify authenticity with `git log --show-signature`.  
🇹🇷 Aynı anahtar bu depodaki her commit'i de imzalar — özgünlüğü `git log --show-signature` ile doğrulayabilirsiniz.

```
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
S98vFLEMVlrYF0QaZME=
=q4Gv
-----END PGP PUBLIC KEY BLOCK-----
```
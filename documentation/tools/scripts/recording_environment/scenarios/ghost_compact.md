# Ghost Compact - Kayıt Senaryosu

## Ortam

| Sunucu | Rol                 | Kullanıcı   |
|--------|---------------------|-------------|
| master | Kontrol sunucusu    | root        |
| server | Phantom-WG sunucusu | root        |
| client | Test istemcisi      | root/client |

## Ön Hazırlık (.bashrc)

```bash
# Phantom unveil wrapper (for recordings)
phantom-casper() {
    command phantom-casper "$@" | while IFS= read -r l; do
        printf '%s\n' "$l"
        sleep 0.04
    done
}
```

---

## Senaryo Akışı

### 1. SERVER - Ghost Mode durumunu kontrol et

```bash
ssh server
```

```bash
phantom-api ghost status
```

---

### 2. SERVER - Ghost Mode aktifleştir

```bash
phantom-api ghost enable domain="ghost.phantom.tc"
```

---

### 3. SERVER - Ghost Mode durumunu doğrula

```bash
phantom-api ghost status
```

---

### 4. SERVER - Test client oluştur

```bash
phantom-api core add_client client_name="test-client"
```

---

### 5. SERVER - Casper config göster

```bash
phantom-casper test-client
```

```bash
exit
```

---

### 6. CLIENT (root) - wstunnel kurulumu

```bash
ssh root@client
```

```bash
curl -LO https://github.com/erebe/wstunnel/releases/download/v10.5.2/wstunnel_10.5.2_linux_amd64.tar.gz
```

```bash
tar -xzf wstunnel_10.5.2_linux_amd64.tar.gz
```

```bash
mv wstunnel /usr/local/bin/
```

```bash
chmod +x /usr/local/bin/wstunnel
```

```bash
wstunnel --version
```

```bash
exit
```

---

### 7. CLIENT (user) - WireGuard yapılandırması

```bash
clear
```

```bash
ssh client
```

```bash
vim ghost.conf
```

*vim ile wstunnel komutu ve wireguard config yapılandırması (manuel)*

```bash
sudo wg-quick up ./ghost.conf
```

```bash
sudo wg-quick show
```

---

## Özet Akış

```
SERVER: status → enable(ghost.phantom.tc) → status → add_client → phantom-casper → exit
CLIENT(root): wstunnel kurulum → version → exit
CLIENT(user): wstunnel + wireguard yapılandırması (manuel)
```

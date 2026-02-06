# Multihop Compact - Kayıt Senaryosu

## Ortam

| Sunucu | Rol                     | Kullanıcı |
|--------|-------------------------|-----------|
| master | Kontrol sunucusu        | root      |
| server | Ana Phantom-WG sunucusu | root      |
| exit   | VPN çıkış noktası       | root      |
| client | Test istemcisi          | client    |

---

## Senaryo Akışı

### 0. MASTER - Başlangıç IP kontrol

```bash
echo "Phantom-WG Server IP: $(ssh server 'curl -s --ipv4 ifconfig.io')"
```

```bash
echo "Exit Server IP: $(ssh exit 'curl -s --ipv4 ifconfig.io')"
```

```bash
echo "Client Server IP: $(ssh client 'curl -s --ipv4 ifconfig.io')"
```

```bash
clear
```

---

### 1. EXIT - Phantom-WG kurulumu

```bash
ssh exit
```

```bash
curl -sSL https://install.phantom.tc | bash
```

---

### 2. EXIT - Subnet değiştir

```bash
phantom-api core change_subnet new_subnet="10.7.0.0/24" confirm=true
```

---

### 3. EXIT - Client oluştur ve export et

```bash
phantom-api core add_client client_name="exit-client"
```

```bash
phantom-api core export_client client_name="exit-client" | jq -r '.data.config' > exit-client.conf
```

```bash
exit
```

---

### 4. MASTER - Config dosyasını transfer et

```bash
scp exit:exit-client.conf .
```

```bash
scp exit-client.conf server:exit-server.conf
```

---

### 5. SERVER - Multihop aktifleştir

```bash
ssh server
```

```bash
phantom-api multihop status
```

```bash
phantom-api multihop import_vpn_config config_path="/root/exit-server.conf" custom_name="exit-server"
```

```bash
phantom-api multihop list_exits
```

```bash
phantom-api multihop enable_multihop exit_name="exit-server"
```

```bash
phantom-api multihop test_vpn
```

```bash
phantom-api multihop status
```

---

### 6. SERVER - Test client oluştur ve export et

```bash
phantom-api core add_client client_name="test-client"
```

```bash
phantom-api core export_client client_name="test-client" | jq -r '.data.config' > test-client.conf
```

```bash
exit
```

---

### 7. MASTER - Test client config'ini transfer et

```bash
scp server:test-client.conf .
```

```bash
scp test-client.conf client:
```

---

### 8. CLIENT - WireGuard bağlantısı kur

```bash
ssh client
```

```bash
sudo wg-quick up ./test-client.conf
```

```bash
clear
```

```bash
sudo wg show
```

```bash
curl --ipv4 ifconfig.io
```

```bash
exit
```

---

### 10. MASTER - Son IP doğrulama

```bash
clear
```

```bash
echo "Phantom-WG Server IP: $(ssh server 'curl -s --ipv4 ifconfig.io')"
```

```bash
echo "Exit Server IP: $(ssh exit 'curl -s --ipv4 ifconfig.io')"
```

```bash
echo "Client Server IP: $(ssh client 'curl -s --ipv4 ifconfig.io')"
```

---

## Özet Akış

```
MASTER: echo Server IP → echo Exit IP → echo Client IP (BAŞLANGIÇ)
EXIT:   phantom-install → change_subnet(10.7.0.0/24) → add_client → export → exit
MASTER: scp exit→master → scp master→server
SERVER: status → import → list_exits → enable → test_vpn → status → add_client → export → exit
MASTER: scp server→master → scp master→client
CLIENT: wg-quick up → wg show → curl ifconfig.io → exit
MASTER: echo Server IP → echo Exit IP → echo Client IP (SON)
```

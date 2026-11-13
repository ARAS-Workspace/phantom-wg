# Migration Guide: 1.1.5 → 2.0.0

This guide moves a running Phantom-WG Modern 1.1.5 install to 2.0.0. 2.0.0 is installed next to 1.1.5, in a directory of its own. The data and the environment files are copied into the new directory. The directory of 1.1.5 stays as it is and is the way back.

> [!NOTE]
> This guide gives the steps and their reasons in short. The full list of differences between the two versions and the measurements the steps rest on are in the [`MIGRATION`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/MIGRATION) file that comes with the distribution.

## Before You Start

**What carries over as it is**

- The WireGuard server keys. The client configurations of 1.1.5 keep working.
- Clients, the address pool, multihop exits and the firewall state.
- Users, their roles and passwords, TOTP, and the audit log.
- The TLS certificate (self-signed or from Let's Encrypt).
- The `.env.daemon` file.

**Downtime.** The stack is down from the `down` of step 3 to the `up` of step 7. In the [rehearsal run](https://github.com/ARAS-Workspace/phantom-wg/actions/runs/43168361592) this took 28 seconds, with the images pulled in step 2.

**Directories.** The examples run as root, as the 1.1.5 quick start does. 1.1.5 is in `/opt/phantom-wg` and 2.0.0 is installed in `/opt/phantom-wg-modern`. Any other directory works the same way.

## Requirements

2.0.0 asks more of the host than 1.1.5. Docker Engine 20.10 and Docker Compose v2 were enough for 1.1.5.

| Requirement    | 2.0.0                                        |
|----------------|----------------------------------------------|
| Docker Engine  | 27.0.1 or newer                              |
| Docker Compose | 2.27.2 or newer                              |
| Kernel         | 5.15 or newer                                |
| Python         | `python3` 3.9 or newer                       |
| TUN            | `/dev/net/tun`                               |
| Tools          | `bash`, `git`, `unzip` for a release archive |

> [!WARNING]
> The `gates` command reports the versions of Docker and Compose but does not compare them. Check the output of step 2 against this table.

## Steps

### 1. Looking at the Current Install

```bash
cd /opt/phantom-wg
./tools/prod.sh status
git status --short
git show HEAD:docker-compose.yml | diff - docker-compose.yml
```

This step shows the changes made by hand on your server. `git status` lists the changed files, but not a `docker-compose.yml` under `compose lock`. The last command prints the changes of that file, locked or not. It prints nothing when there is no change. Note any ports or subnets of your own. They are written to their place in step 6.

### 2. Getting the New Version

```bash
git clone --depth 1 --branch main \
  https://github.com/ARAS-Workspace/phantom-wg.git \
  /opt/phantom-wg-modern
cd /opt/phantom-wg-modern
./tools/prod.sh gates
./tools/prod.sh pull
```

- Give the directory name. A clone without a directory name takes `phantom-wg`. In `/opt` that is the directory of 1.1.5, and git stops there.
- `gates` reports what the host provides.
- `pull` downloads the images now. 1.1.5 still serves meanwhile, and the download stays out of the downtime.

<details>
<summary>Getting it from a release archive</summary>

```bash
cd /opt
unzip phantom-wg-modern-v2.0.0-amd64.zip    # or -arm64
cd /opt/phantom-wg-modern
./tools/prod.sh gates
```

The archive carries its images in `images/`. `setup` loads them in step 5, so `pull` is not needed.

</details>

### 3. Stopping the Current Install

```bash
cd /opt/phantom-wg
./tools/prod.sh down
```

The databases are copied in the next step. A running stack could leave them halfway written. The downtime starts with this command.

### 4. Copying the Data and the Environment Files

```bash
cd /opt/phantom-wg-modern
cp -a /opt/phantom-wg/container-data /opt/phantom-wg/.env.daemon \
  /opt/phantom-wg/.env.auth-service .
chown -R --reference=. container-data .env.daemon .env.auth-service
```

- `cp -a` copies the files with the owners they have in 1.1.5.
- `chown` gives the copy to the owner of this directory. The tools of 2.0.0 write as that user.
- Run this step as root, or with `sudo`. `container-data` holds files the daemon wrote as root.

### 5. Creating What Is Missing

```bash
./tools/prod.sh setup
```

`setup` creates only what is missing. Here that is `.env` and `docker-compose.override.yml`. It leaves the keys, the auth database, the TLS certificate and the address pool of 1.1.5 as they are.

### 6. Organizing the Environment Files

In `.env.auth-service`, change the value of `AUTH_PROXY_MAX_BODY` and add the new line right below it:

```ini
AUTH_PROXY_MAX_BODY=65536
AUTH_PROXY_BACKUP_MAX_BODY=67108864
```

2.0.0 limits a request body through the API to 64 KiB. Only the backup upload routes carry 64 MiB. The file works without this change too. These two lines bring it to what 2.0.0 sets.

> [!WARNING]
> The `.env.auth-service` of 1.1.5 ends without a line break. A line added with `echo >>` joins its last line, and auth-service stops on that value. Edit the file with an editor.

Write any server-specific settings you noted in step 1 to their place in 2.0.0:

| Setting in 1.1.5                                       | Its place in 2.0.0                                                                           |
|--------------------------------------------------------|----------------------------------------------------------------------------------------------|
| Ports of your own                                      | `docker-compose.override.yml`                                                                |
| Subnets of your own                                    | `PHANTOM_SUBNET_V4` and `PHANTOM_SUBNET_V6` in `.env`                                        |
| A `WIREGUARD_LISTEN_PORT` of your own in `.env.daemon` | The container side of the UDP entry in `docker-compose.override.yml` has to be the same port |

### 7. Starting the New Version

```bash
./tools/prod.sh up
./tools/prod.sh status
./tools/prod.sh show-versions
```

The downtime ends with `up`. The other two commands show the state and the versions of the services.

## Check

- [ ] The dashboard answers, and the `admin` account of 1.1.5 logs in with the same password.
- [ ] The clients of 1.1.5 are listed.
- [ ] A client connects with its configuration of 1.1.5, and its handshake shows in the dashboard.
- [ ] The traffic of that client leaves through the server. The address the internet sees is the one of the server.
- [ ] The audit log lists the entries of 1.1.5 before the new ones.

## Rollback

The directory of 1.1.5 is as it was. Step 4 only copied from it.

```bash
cd /opt/phantom-wg-modern
./tools/prod.sh down
cd /opt/phantom-wg
./tools/prod.sh up
```

What 2.0.0 wrote after step 7 (new clients, users, audit entries) stays in `/opt/phantom-wg-modern`. 1.1.5 does not have it.

## After Migration

**Let's Encrypt.** The certificate state is in `container-data/certbot` and is copied in step 4. A cron job or timer that renews the certificate names the directory of 1.1.5. Point it to the new one.

**Images and volume of 1.1.5.** Remove them once you are sure 2.0.0 serves:

```bash
docker image rm phantom-wg-daemon phantom-wg-auth-service nginx:1-alpine
docker volume rm phantom-wg_phantom-sock
```

The names come from the directory name of 1.1.5. With the directory of 1.1.5 in place, the rollback works after the removal of the images and the volume too. In that case `up` builds the images again and makes the volume again.

**Updates.** A 2.0.0 installed from a git clone is updated with `./tools/prod.sh update`. The details are in the [`UPDATE`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/UPDATE) file.

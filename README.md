# pve-crosspoint-sync

A Proxmox VE helper script that creates a Debian 12 LXC container and installs
[crosspoint-sync](https://github.com/crosspoint-reader/crosspoint-sync) **baremetal**
inside it — Node.js + systemd, no Docker.

crosspoint-sync is a self-hostable, KOSync-compatible reading-progress sync server.
It's purpose-built for [CrossPoint/CrossInk](https://github.com/CrossPointOSS/CrossPoint)
firmware (e.g. Xteink e-readers), syncing full position metadata, bookmarks, and
reading stats, but it's also fully compatible with plain KOReader's built-in
"Progress sync" plugin.

## Usage

Run as root on the Proxmox VE host, either downloaded first:

```sh
bash crosspoint-sync.sh
```

or as a one-liner:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Boisti13/pve-crosspoint-sync/master/crosspoint-sync.sh)"
```

This auto-picks the next free container ID, creates the LXC, and installs the app.
Everything is configurable via environment variables:

```sh
CTID=115 MEMORY_MB=768 REGISTRATION_DISABLED=true bash crosspoint-sync.sh
```

| Variable | Default | Notes |
|---|---|---|
| `CTID` | next free ID | Set to an existing container's ID to (re)run the installer against it instead of creating a new one |
| `CT_HOSTNAME` | `crosspoint-sync` | |
| `DISK_GB` | `4` | |
| `MEMORY_MB` | `1024` | |
| `SWAP_MB` | `512` | |
| `CORES` | `1` | |
| `BRIDGE` | `vmbr0` | |
| `IP_CONFIG` | `dhcp` | e.g. `192.168.1.50/24,gw=192.168.1.1` |
| `ROOTFS_STORAGE` | `local-lvm` | |
| `TEMPLATE_STORAGE` | `local` | |
| `APP_PORT` | `8080` | |
| `REGISTRATION_DISABLED` | `false` | Set `true` to lock out new account registration |
| `NODE_MAJOR` | `24` | Node.js major version (via NodeSource) |
| `REPO_URL` / `REPO_BRANCH` | upstream `main` | Override to pin a fork or branch |

## What it sets up

- Debian 12 LXC, Node.js (NodeSource apt repo)
- `crosspoint-sync` cloned to `/opt/crosspoint-sync/app`, built with `npm ci && npm run build`
- Runs as a dedicated unprivileged `crosspoint` system user under a hardened systemd unit
- SQLite database at `/opt/crosspoint-sync/data/crosspoint.db` (kept separate from the
  git checkout so updates never touch it)
- Config at `/opt/crosspoint-sync/crosspoint-sync.env` (edit + `systemctl restart crosspoint-sync` to change settings)

## Updating

The installer copies itself to `/usr/bin/update` inside the container on first run, so
after that you don't need this script again:

```sh
pct enter <ctid>
update
```

`update` pulls the latest crosspoint-sync code, rebuilds only if something changed,
runs `apt upgrade`, and restarts the service. It's idempotent and safe to run anytime.

Re-running `crosspoint-sync.sh` with `CTID=<existing-id>` from the Proxmox host does
the same thing without needing to `pct enter`.

## Connecting your devices

- **CrossPoint/CrossInk firmware:** Settings → KOReader Sync → Sync Server URL → `http://<ct-ip>:8080`
- **Plain KOReader:** Tools → Progress sync → Custom sync server → `http://<ct-ip>:8080`

## License

This installer script is [MIT](LICENSE) licensed, unaffiliated with the
crosspoint-sync or CrossPoint projects.

It doesn't vendor or redistribute any of their code — at install time it just
`git clone`s [crosspoint-reader/crosspoint-sync](https://github.com/crosspoint-reader/crosspoint-sync)
directly from upstream, which is itself [MIT licensed](https://github.com/crosspoint-reader/crosspoint-sync/blob/main/LICENSE).
Same license, no conflict, no code copied here.

# glinet-updater (`glu`)

Verified Tailscale and AdGuard Home updates for GL.iNet routers, run from your own computer.

GL.iNet firmware often ships old Tailscale and AdGuard Home versions. Community scripts can update them,
but you run them as `root` from a URL that can change at any time. `glu` takes a different approach:

- **The code is in this repository.** You run the commit that you reviewed. Nothing is fetched from a script URL.
- **Your computer verifies every download** before it goes to the router.
- **The router downloads nothing from the internet.** It only receives verified files over SSH.
- **Each change is reversible.** `glu` makes a backup, checks the service health after the update, and rolls back automatically if the check fails.

## How it works

```
 your computer                                      router (GL.iNet, BusyBox)
 ─────────────                                      ─────────────────────────
 glu ──HTTPS──> pkgs.tailscale.com
     │          github.com/AdguardTeam/AdGuardHome
     │
     ├─ Tailscale: ed25519 signature, chained to the
     │  root keys pinned in keys/tailscale/, + sha256
     ├─ AdGuard Home: sha256 from the release checksums.txt
     │
     └──SSH──> /tmp/glu-session.XXXXXX/agent.sh ──> sha256 check again
                                                    backup to /root/glu-backups
                                                    stop, replace, start
                                                    health check, or roll back
                                                    session folder removed
```

The agent is copied to a temporary folder for each run and deleted at the end. No `glu` code stays on the router.

### What is verified, and the limits

| Component | Check | What it proves |
|---|---|---|
| Tailscale | ed25519 signature of BLAKE2s(package) + length, made by a signing key that a pinned root key signed. This is the same scheme that `tailscale update` uses. | The package comes from Tailscale. A changed file or a changed server fails. |
| Tailscale | sha256 from `pkgs.tailscale.com` | The download is complete. |
| AdGuard Home | sha256 from the release `checksums.txt` on GitHub | The download matches the release. AdGuard publishes no signatures, so this trusts GitHub and the AdGuard release account. |
| Both | sha256 again on the router, and a test run of the new binary | The file did not change during the copy, and it runs on the router CPU. |

To change the trusted Tailscale roots, edit `keys/tailscale/` and review the change like any other code.

## Requirements

- **Your computer:** POSIX `sh`, `ssh`, `curl`, `python3` (standard library only), `awk`, `sed`. macOS and Linux work.
- **Router:** GL.iNet firmware 4.x with SSH access as `root`. Tested on a GL-BE9300 (Flint 3) with firmware 4.10.1.

## Quick start

```sh
git clone https://github.com/<you>/glinet-updater.git
cd glinet-updater
./glu status
./glu tailscale update --dry-run
./glu tailscale update
```

The default router is `root@192.168.8.1`. To use another router, set `GLU_ROUTER` or use `-r`.
An alias from `~/.ssh/config` also works (`glu -r flint status`).

## Commands

| Command | What it does |
|---|---|
| `glu status` | Shows the installed, firmware, and latest versions, the persistence state, and free space. |
| `glu doctor [--url URL]` | Checks services, persistence, and the port-forward rule. With `--url`, the router requests the URL (for example, your Cloudflare domain) and reports the HTTP result. |
| `glu tailscale update` | Downloads, verifies, and installs the latest stable Tailscale. |
| `glu adguard update` | Downloads, verifies, and installs the latest AdGuard Home. |
| `glu tailscale restore [backup\|firmware]` | Puts back the last backup, or the version from the firmware (`/rom`). |
| `glu adguard restore [backup\|firmware]` | The same for AdGuard Home. `backup` also restores `config.yaml`. |
| `glu netfix status\|apply\|remove` | Manages the port-forward reply rule (see below). |

| Option | Meaning |
|---|---|
| `-n, --dry-run` | Downloads, verifies, copies, and tests on the router. Changes nothing. |
| `-y, --yes` | Does not ask for confirmation. |
| `-f, --force` | Reinstalls or downgrades to the target version. |
| `--version VER` | Uses this version, not the latest one. |
| `--no-gl-patch` | Does not change `/usr/bin/gl_tailscale`. |
| `-r, --router HOST` | SSH target. |

## What `glu` changes on the router

| Component | Files | Persistence on firmware upgrade |
|---|---|---|
| Tailscale | `/usr/sbin/tailscaled`, `/usr/sbin/tailscale` | Adds both files and `/etc/config/tailscale` to `/etc/sysupgrade.conf` |
| Tailscale | `/usr/bin/gl_tailscale`: adds `--stateful-filtering=false` to the `--advertise-routes` line. Newer Tailscale needs it for subnet routes and exit nodes. | Not added. Run `glu tailscale update` again after a firmware upgrade. |
| AdGuard Home | `/usr/bin/AdGuardHome` (the official build supports the `--glinet` option that the GL.iNet start script uses) | Adds the binary to `/etc/sysupgrade.conf` |
| Backups | `/root/glu-backups/<component>/<timestamp>/`. `glu` keeps the 2 newest. | — |
| netfix | `ip rule` priority 5990 and `uci network.pf_reply_main` | Saved in `/etc/config/network` |

## The port-forward fix (`netfix`)

On GL.iNet firmware 4.9 and later, port forwards and replies can fail when **all three** of these are true:

1. A VPN client runs on the router. Its rules drop LAN traffic that has no VPN mark (`ip rule 9920: iif br-lan blackhole`).
2. Port forwards exist. In firmware 4.9 and later, the `port_forward.ko` module adds the connection mark `0x10000`.
3. A newer Tailscale runs (for example 1.104.x, but not the 1.92.5 in firmware 4.10.1). Its firewall rule copies the connection mark bits `0xff0000` into the packet mark. This removes GL.iNet's "no VPN" mark `0x8000`.

Then each reply from the LAN server is dropped. Cloudflare shows **error 522**.

`glu netfix apply` adds `ip rule fwmark 0x10000/0xfff000 lookup main` at priority 5990. Replies of port-forwarded connections then go out through the WAN. VPN traffic and port forwards that come in through the VPN do not change.
`glu doctor` reports when you need the rule.

## After a firmware upgrade

```sh
./glu status
./glu doctor --url https://your.domain
./glu tailscale update
```

The firmware upgrade keeps the binaries in `sysupgrade.conf`. `glu tailscale update` adds the `gl_tailscale` change again if necessary, also when Tailscale is already up to date.

## Development

- `make check` runs ShellCheck, the shfmt format check, and all tests.
- `make format` formats the shell code.

```
glu                    entry point (your computer)
lib/                   ui, util, fetch, remote (SSH), tailscale, adguard
agent/agent.sh         router side, BusyBox sh, copied for each run
tools/distsign_verify.py   Tailscale signature check, Python standard library only
keys/tailscale/        pinned Tailscale root public keys
tests/                 shell and Python tests, fixtures
```

This project is not affiliated with GL.iNet, Tailscale, or AdGuard.

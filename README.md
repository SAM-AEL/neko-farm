# neko-farm

A persistent remote browser on a small VPS. Sign in once, close the tab, and the
browser keeps running on the VPS — reachable again from anywhere over a
Cloudflare Tunnel.

Built for VPSs with roughly 1 vCPU / 1 GB RAM / 8 GB disk, where a full desktop or
a normal browser stack will not fit.

- Neko (`ghcr.io/m1k1o/neko/firefox:3`) on a host that already runs cloudflared
- UI bound to `127.0.0.1:7000`, exposed publicly through your existing tunnel
- Session, profile, and Neko login all survive restarts and reboots

## Deploy

```bash
cp deploy.env.example deploy.env   # fill in DEPLOY_HOST at minimum
yarn install                        # first time only, to get yarn.lock
yarn deploy
```

`yarn deploy:check` validates config and VPS reachability without changing
anything. Target host comes from `deploy.env`:

| Var | Meaning |
| --- | --- |
| `DEPLOY_HOST` | VPS public IP or hostname |
| `DEPLOY_USER` | SSH user |
| `DEPLOY_PORT` | SSH port |
| `DEPLOY_PATH` | Deploy directory on the VPS — must be writable by `DEPLOY_USER` |
| `PUBLIC_HOSTNAME` | Public hostname — printed at the end, not configured by the script |

What `yarn deploy` does: validate the compose file locally → check docker, disk
space, SSH, and directory writability on the VPS → rsync the stack → seed `.env` if
the server has none → `chown` the profile → `docker compose up -d`.

**`profile/` and `.env` are never synced.** The profile holds the browser session
and `.env` holds secrets; both are remote state. They are excluded from rsync,
which also protects them from `--delete`. `.env` is pushed once, on the first
deploy when the server has none — after that the server's copy wins, so rotating a
password locally will not silently change the running server.
`VPS_PUBLIC_IP` is filled in from `DEPLOY_HOST` automatically.

`DEPLOY_PATH` must be writable by the SSH user because rsync runs unprivileged —
`/opt/neko-farm` will not work for a non-root user. `~` is resolved to the remote
home directory.

`DEPLOY_USER` also needs access to the docker daemon. The script detects this and
fails with instructions if it is missing. Note that membership of the `docker`
group is equivalent to root access on that host.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | neko, memory caps, log caps, port bindings |
| `policies.json` | Firefox policy — **session persistence and uBlock live here** |
| `neko.yaml` | video capture bitrate/fps cap |
| `scripts/deploy.sh` | `yarn deploy` |
| `.env` / `deploy.env` | secrets and target host, both gitignored |
| `profile/` | persisted Firefox profile, gitignored |

`policies.json` and `neko.yaml` are both required — see "What breaks without them".

## First-time setup

### 1. VPS prep

```bash
# Verify the provider's swap is actually attached. Do not create your own —
# there is no room for a second swapfile on 8 GB.
free -h
swapon --show

# Swap a little more eagerly than the default of 10; with only 512 MB of pool,
# a low swappiness means the OOM killer fires before swap can help.
echo 'vm.swappiness=20' | sudo tee /etc/sysctl.d/99-neko.conf
sudo sysctl --system
```

Install Docker + the compose plugin. Confirm ≥1.5 GB free before the first pull —
the image is around 1–1.5 GB.

### 2. Passwords

Generate the two Neko passwords:

```bash
printf 'NEKO_PASSWORD=%s\nNEKO_PASSWORD_ADMIN=%s\n' \
  "$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)" \
  "$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)" > .env
```

`VPS_PUBLIC_IP` is set by the deploy script. No tunnel token is needed — see below.

### 3. Cloudflare Tunnel

cloudflared already runs on the VPS and owns the tunnel, so this project does not
run one. In the Zero Trust dashboard, add a **public hostname**:

- `watch.example.com` → service `http://localhost:7000`

Because cloudflared runs on the host, it reaches Neko through the published
`127.0.0.1:7000` port. Then add an **Access** policy for that hostname (email OTP
is enough) — without one, anyone who finds the hostname gets a browser they can
drive, including anything you are already signed into.

### 4. Firewall

Two inbound ports in total. The tunnel is outbound-only, so no 80/443 needed.

| Port | Proto | Purpose |
| --- | --- | --- |
| your SSH port | TCP | already open |
| `52000` | TCP | WebRTC media (single port, see above) |

If a host firewall is in play: `sudo ufw allow 52000/tcp`. Do **not** open `7000`
— it is bound to `127.0.0.1` and cloudflared reaches it over loopback.

Port 7000 is already published on `127.0.0.1` only. If you ever rebind it to
`0.0.0.0` you create a second entry point that bypasses Cloudflare Access.

### 5. Deploy and sign in

```bash
yarn deploy
```

Open `https://watch.example.com` and log in with `NEKO_PASSWORD` from `.env`.

1. Sign in to whatever site you are keeping a session on. This happens once — the
   profile persists.
2. Set the stream to a **low quality** and **mute** it if you only care about it
   running. Muted is not paused; an unattended tab keeps consuming CPU and
   bandwidth otherwise.
3. Close the browser tab. Everything keeps running on the VPS.

A datacenter IP may trigger a captcha or a bot check on first sign-in. Solve it
manually in the session; the persisted profile avoids repeats.

## Daily use

Nothing to do. The container restarts on its own (`restart: unless-stopped`).
Re-deploy after config changes with `yarn deploy`.

To check on it, open `https://watch.example.com` and log in with `NEKO_PASSWORD`.

## What breaks without them

Both of these fail in ways that look like something else, so they are worth
understanding rather than just keeping.

**`policies.json` — session persistence.** Neko ships a Firefox policy that sets
every `SanitizeOnShutdown` flag to `true`, which wipes cookies on shutdown. The
profile volume alone does **not** keep you signed in. Our copy flips all eight to
`false`. Without this you re-authenticate after every restart, and the `profile/`
mount looks broken for no visible reason.

The file is Neko's stock policy with only `SanitizeOnShutdown` and
`Homepage.StartPage` changed, so the hardened defaults (telemetry off, no password
manager, tracking protection, extension allowlist) are preserved. If Neko changes
its defaults upstream, re-derive it from:
`https://raw.githubusercontent.com/m1k1o/neko/master/apps/firefox/policies.json`
(note `master`, not `main` — the URL in Neko's own docs 404s).

uBlock Origin and SponsorBlock are already force-installed by that policy, so
there is nothing to install by hand.

**`neko.yaml` — bitrate cap.** `NEKO_VIDEO_BITRATE` and `NEKO_MAX_FPS` were removed
in v3; both now live in the capture pipeline config. This is the main CPU and
bandwidth lever on a 1 vCPU box. It is verified to parse — startup logs
`syntax check for video stream pipeline passed`.

## How traffic flows

Neko splits its traffic, and only half of it can be tunneled:

```
you --HTTPS--> Cloudflare edge --> cloudflared (VPS) --> localhost:7000   UI/signaling
you --WebRTC over TCP------------------------------> VPS:52000/tcp        video/audio
```

A Cloudflare HTTP tunnel does not proxy WebRTC media, so the media port is
exposed directly. This is by design, not a misconfiguration. If the UI loads but
the picture stays black, that port is being blocked between you and the VPS.

**Why TCP and not UDP.** WebRTC normally opens an ephemeral UDP port per
connection, so the default setup needs all of `52000-52100/udp` reachable. If
your provider's firewall wants one rule per port, that is impractical.
`NEKO_WEBRTC_TCPMUX=52000` multiplexes every media connection onto a single TCP
port instead — one rule, and TCP is the protocol most likely already permitted.
The cost is some latency and head-of-line blocking under load, so video can be
less smooth than native UDP would be.

To go back to UDP, replace the `52000:52000/tcp` mapping with
`52000-52100:52000-52100/udp` and set `NEKO_WEBRTC_EPR=52000-52100` in place of
`NEKO_WEBRTC_TCPMUX`. You can verify which one is live with:

```bash
docker compose logs neko | grep -oE 'tcpmux=[^ ]*|epr=[^ ]*'
```

## Resource notes

Budget, against 1 GB physical + 512 MB swap:

| Consumer | Budget |
| --- | --- |
| host OS + journald | ~150 MB |
| dockerd + containerd | ~80 MB |
| host cloudflared (outside Docker) | ~50 MB |
| neko (`mem_limit`) | 600 MB |
| **physical total** | **~880 MB of 1000 MB** |

`mem_limit` is load-bearing. Without it, memory growth takes the swap pool and the
stream stalls. cloudflared is not containerised here, so it is not in the compose
file and gets no `mem_limit` — its cost is the row above.

Bandwidth is counted **twice** — the stream ingresses to the VPS and then egresses
to you, so budget roughly double the stream bitrate you expect to send. Check your
host for overage billing.

If swap usage climbs and stays high after streaming settles, the workload does not
fit. Drop the stream quality or the pipeline `fps` in `neko.yaml` before raising
`mem_limit`.

## Troubleshooting

```bash
docker compose ps                      # running, or restart-looping?
docker compose logs neko | tail -30    # look for 'neko ready'
docker stats                           # live memory
free -h                                # swap headroom
docker inspect -f '{{.State.OOMKilled}}' neko-farm-neko-1
dmesg | grep -i oom
df -h                                  # disk, especially after image pulls
```

| Symptom | Likely cause |
| --- | --- |
| UI loads, picture black | TCP 52000 blocked upstream, or `VPS_PUBLIC_IP` wrong |
| Restart-looping on start | bad `neko.yaml` or `policies.json` — check logs |
| Signed out after reboot | `policies.json` not mounted, or `profile/` not chowned to 1000:1000 |
| Signed out of Neko after reboot | `neko-data` volume removed, or `NEKO_SESSION_FILE` unset |
| Swap pinned near 512 MB | workload does not fit — lower quality or `fps` |
| Captcha on sign-in | datacenter IP, expected on first attempt only |
| `yarn deploy` cannot reach VPS | `DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_PORT`, or SSH key not loaded |
| Deploy ran but old behaviour persists | remote `.env` is intentionally not overwritten — edit it on the VPS |
| `mkdir: Permission denied` on deploy | `DEPLOY_PATH` not writable by the SSH user — use `~/neko-farm` |
| `sudo: a terminal is required` on deploy | `DEPLOY_USER` lacks daemon access — add them to the `docker` group |

Reclaim disk with `docker image prune -a` before adding anything else; 8 GB is the
tightest constraint here.

## Notes

- `NEKO_SERVER_PROXY=true` is required — cloudflared terminates TLS, and without
  it Neko ignores `X-Forwarded-Proto` / `X-Forwarded-Host`.
- Media uses `NEKO_WEBRTC_TCPMUX=52000` (one TCP port). If you switch back to
  UDP, `NEKO_WEBRTC_EPR` must match the published range — Neko v3 defaults to
  59000-59100, so omitting it advertises ports you never opened.
- Firefox was chosen over Chromium deliberately: the Chromium image needs
  `shm_size` of 2 GB and runs `--no-sandbox`, neither of which suits 1 GB of RAM.
- Neko 3 renamed several environment variables from v2. `NEKO_PASSWORD` and
  `NEKO_PASSWORD_ADMIN` are v2 names and are ignored; v3 uses
  `NEKO_MEMBER_MULTIUSER_USER_PASSWORD` / `..._ADMIN_PASSWORD`.
- Firefox's password manager is disabled by Neko's policy, so if a session cookie
  ever expires you re-enter the password manually. The cookie itself persists
  indefinitely.
- If you let a page run unattended, keep it signed in rather than relying on a
  password manager, and check the site's terms — some distinguish a genuinely
  watching viewer from automation. This project is manual by design.

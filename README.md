# The Isolated Observatory

A single-command build for a web privacy measurement workstation on Arch Linux.

The premise is layered observation. Most tracking analysis looks at one layer
and infers the rest; this setup watches three at once, so the layers can be
checked against each other:

| Layer | Tool | What it answers |
|---|---|---|
| **Browser** | OpenWPM (Docker) | What did the page *do* — scripts, cookies, storage, fingerprinting API calls |
| **Wire** | tshark | What actually *left the machine* — TLS SNI, DNS, connection timing |
| **Egress** | ProtonVPN | Where the traffic appeared to come from |

Results land in SQLite, which [Datasette](https://datasette.io) turns into a
browsable, queryable UI. The design bias throughout is passive capture depth
over active interception breadth: observe thoroughly, interfere minimally.

## Scope

This is a measurement instrument. Point it at systems you own or have explicit
permission to investigate.

The authenticated-session tooling in particular drives a real browser through a
real login and records what happens. That is a reasonable thing to do to your
own accounts, and not a reasonable thing to do to anyone else's.

## Requirements

- **Arch Linux or a derivative** — Manjaro, EndeavourOS, anything with `pacman`.
  The script checks for this and exits if `pacman` is absent. On Debian or
  Ubuntu you would need to translate the `pacman -S` calls to `apt install`.
- **sudo privileges**
- **Internet connectivity**
- **~8GB free disk** — the OpenWPM image alone is roughly 4GB, and crawl
  databases grow quickly. The script warns and prompts below this.
- **A ProtonVPN account**, if you want the egress layer. Configured
  interactively; no credentials are stored in this repository.

On a `linux-hardened` kernel, Docker needs extra sysctl configuration. The
script detects this, prints the specific parameter, and continues rather than
guessing on your behalf.

## Install

```bash
git clone https://github.com/Propagator0/Observatory.git
cd Observatory
./script_setup.sh
```

The script is idempotent where it can be — safe to re-run if something fails
partway through. Each stage is a shell function, so you can also source the
script and run a single stage:

```bash
source script_setup.sh          # note: this runs main() as well
setup_python_environment        # or re-run just one stage
```

Before running, review the configuration block at the top of the script.
`OBSERVATORY_ROOT` (default `~/observatory`) is the one most worth changing —
point it at a partition with room.

**Log out and back in when it finishes.** The script adds you to the `docker`
and `wireshark` groups, and group membership does not apply to your current
session. `newgrp docker && newgrp wireshark` works as a stopgap.

## What it builds

```
~/observatory/
├── captures/          ← tshark PCAPs, one subdirectory per session
├── crawls/            ← OpenWPM SQLite databases, one per crawl
├── screenshots/
├── logs/
├── scripts/
│   ├── crawlers/      ← basic_crawl.py
│   ├── selenium/      ← authenticated_session.py
│   └── sql/           ← find_fingerprinting.sql, find_trackers.sql, session_analysis.sql
├── openwpm-repo/      ← cloned OpenWPM source
├── datasette/         ← Datasette metadata
├── .venv/             ← Datasette, Selenium, pandas, matplotlib, requests, httpx
├── docker-compose.yml
└── MANUAL.md          ← the operator manual, installed here by the setup script
```

Also installed system-wide via pacman: Docker, docker-compose, Wireshark and
tshark, Python, sqlite, tmux, htop, jq, and supporting network tooling.

## A session, end to end

```bash
# 1. Connect and confirm egress
protonvpn-cli connect --cc CH
curl https://api64.ipify.org

# 2. Find the interface traffic is leaving on
ip route show default

# 3. Start capture (tun0 for VPN traffic; use your physical interface for pre-VPN)
~/observatory/scripts/start_capture.sh tun0 session_$(date +%Y%m%d)

# 4. Crawl
source ~/observatory/.venv/bin/activate
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://example.com" \
  --name "example_$(date +%Y%m%d)" \
  --timeout 90

# 5. Stop capture
~/observatory/scripts/stop_capture.sh session_$(date +%Y%m%d)

# 6. Explore the crawl database
~/observatory/scripts/launch_datasette.sh     # http://localhost:8001

# 7. Cross-check against the wire — which hosts were actually contacted
tshark -r ~/observatory/captures/session_$(date +%Y%m%d)/capture.pcap -n \
  -Y "tls.handshake.type == 1" \
  -T fields -e tls.handshake.extensions_server_name | sort -u

protonvpn-cli disconnect
```

Step 7 is where the layers meet: the SNI list from the capture is an
independent check on what the browser instrumentation reported.

`~/observatory/scripts/observatory_tmux.sh <interface>` opens all of this as a
prepared multi-pane workspace.

## Documentation

**[Observatory Operational Manual](Observatory%20Operational%20Manual.md)** —
fifteen sections, every command written out in full and runnable. Verification,
VPN handling, capture, crawls, authenticated sessions, Datasette, tshark
analysis, SQL recipes for the OpenWPM schema, Docker management, archival, and
troubleshooting. Section 15 is a one-page quick reference.

The setup script installs a copy to `~/observatory/MANUAL.md`, so it is on the
machine you are operating.

## Handling what you capture

Output from this toolchain is sensitive by construction. Worth knowing before
you generate any:

- **PCAPs record real traffic** — everything the interface saw for the duration,
  not only the sites you meant to visit.
- **Session state is live credentials.** `authenticated_session.py` writes
  cookies and `localStorage` to JSON. Anyone holding that file holds the
  session. Treat it as a password, and delete it when the investigation is done.
- **`--password` on the command line lands in your shell history**, and is
  visible in the process list while running. Prefer the interactive login mode
  the script offers.
- **Crawl databases embed browsing history**, including any URL parameters.

The included `.gitignore` covers all of these, but the reliable protection is
keeping `OBSERVATORY_ROOT` outside any repository — which the default,
`~/observatory`, already does.

## License

MIT — see [LICENSE](LICENSE).

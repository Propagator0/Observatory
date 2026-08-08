# Observatory Operational Manual
## Package 3: The Isolated Observatory
### Arch Linux + Docker + OpenWPM + tshark + Datasette + ProtonVPN

---

> **Read before operating:**
> Every command below is shown as a complete, executable line.
> Values like interface names, session names, and URLs are concrete
> examples — replace them with your actual values where indicated.
> Commands prefixed with `#` are comments explaining the line below.
> Commands prefixed with `$` are run as your normal user.
> Commands prefixed with `sudo` require elevation — minimize these
> by ensuring group memberships are active (covered in Section 1).

---

## TABLE OF CONTENTS
1. [First-Boot Verification](#section-1--first-boot-verification)
2. [Group Membership and Session Refresh](#section-2--group-membership-and-session-refresh)
3. [Network Interface Identification](#section-3--network-interface-identification)
4. [ProtonVPN — Connect, Verify, Manage](#section-4--protonvpn--connect-verify-manage)
5. [Launching the Observatory Workspace (tmux)](#section-5--launching-the-observatory-workspace-tmux)
6. [Passive Packet Capture (tshark)](#section-6--passive-packet-capture-tshark)
7. [Running Crawls (OpenWPM)](#section-7--running-crawls-openwpm)
8. [Authenticated Session Recording (Selenium)](#section-8--authenticated-session-recording-selenium)
9. [Exploring Results (Datasette)](#section-9--exploring-results-datasette)
10. [Analyzing Captures (tshark + Wireshark)](#section-10--analyzing-captures-tshark--wireshark)
11. [SQL Analysis Against OpenWPM Databases](#section-11--sql-analysis-against-openwpm-databases)
12. [Docker Management](#section-12--docker-management)
13. [Session Archival and Cleanup](#section-13--session-archival-and-cleanup)
14. [Troubleshooting](#section-14--troubleshooting)
15. [Quick Reference Card](#section-15--quick-reference-card)

---

## SECTION 1 — FIRST-BOOT VERIFICATION

Run these immediately after the setup script completes, or after
any kernel update, to confirm all components are operational.

```bash
# Verify Docker daemon is running
systemctl is-active docker

# Expected output: active
# If output is: inactive — run: sudo systemctl start docker

# Verify Docker responds without sudo
# (only works after re-login following setup script)
docker info | grep "Server Version"

# If you get permission denied, your docker group hasn't refreshed yet.
# See Section 2.

# Verify OpenWPM image is present locally
docker images ghcr.io/openwpm/openwpm

# Expected: a row showing the image with a SIZE of ~3-4GB
# If empty: docker pull ghcr.io/openwpm/openwpm:latest

# Verify tshark is installed and has capture permissions
tshark --version

# Expected: TShark (Wireshark) 4.x.x
# If permission denied on capture: see Section 2

# Verify tshark can list interfaces without sudo
tshark -D

# Expected: numbered list of network interfaces
# If permission denied: sudo tshark -D (temporary workaround until group refresh)

# Verify Datasette is installed in the Observatory virtualenv
~/observatory/.venv/bin/datasette --version

# Expected: datasette, version 0.x.x or 1.x.x

# Verify Selenium is installed
~/observatory/.venv/bin/python -c "import selenium; print('Selenium', selenium.__version__)"

# Expected: Selenium 4.x.x

# Verify ProtonVPN CLI is available
protonvpn-cli --version

# Expected: ProtonVPN CLI version string
# If not found: protonvpn --version (alternate binary name depending on install method)

# Full health check — run all verifications in sequence and review output
echo "=== Docker ===" && docker info | grep "Server Version" && \
echo "=== OpenWPM Image ===" && docker images ghcr.io/openwpm/openwpm | tail -1 && \
echo "=== tshark ===" && tshark --version | head -1 && \
echo "=== Datasette ===" && ~/observatory/.venv/bin/datasette --version && \
echo "=== Selenium ===" && ~/observatory/.venv/bin/python -c "import selenium; print('Selenium', selenium.__version__)" && \
echo "=== All checks passed ==="
```

---

## SECTION 2 — GROUP MEMBERSHIP AND SESSION REFRESH

```bash
# Check current group memberships for your user
groups

# Expected output includes: docker wireshark
# Example: username wheel docker wireshark audio video

# If groups are missing, apply them without logging out (current shell only)
newgrp docker

# This opens a new shell with the docker group active.
# Run subsequent commands from this shell.
# Note: you may need to run this again for wireshark in a separate step.

# Apply wireshark group to current shell
newgrp wireshark

# Verify groups are now active in this shell
groups

# Permanent fix: log out of your desktop session and log back in.
# All subsequent shells will have the correct groups automatically.

# Verify docker works without sudo after group refresh
docker ps

# Expected: empty table (no running containers yet) — NOT a permission error

# Verify tshark can capture without sudo after group refresh
tshark -i eth0 -c 5 -q

# Replace eth0 with your interface (find it in Section 3)
# -c 5: capture only 5 packets then stop (this is just a permission test)
# -q: quiet mode, minimal output
# Expected: 5 packets captured, no permission errors
# If still failing: sudo setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap

# Manually set dumpcap capabilities if group approach fails
sudo setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap

# Verify capabilities were set
getcap /usr/bin/dumpcap

# Expected: /usr/bin/dumpcap cap_net_raw,cap_net_admin=eip
```

---

## SECTION 3 — NETWORK INTERFACE IDENTIFICATION

```bash
# List all network interfaces with their current state
ip link show

# Example output:
# 1: lo: <LOOPBACK,UP,LOWER_UP> ...
# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...    ← wired ethernet
# 3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...   ← wifi
# 4: tun0: <POINTOPOINT,UP,LOWER_UP> ...            ← VPN tunnel (when connected)

# Show only UP interfaces (active ones)
ip link show up

# Show IP addresses assigned to each interface
ip addr show

# Show the interface your default route uses (the one internet traffic flows through)
ip route show default

# Example output:
# default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.100 metric 100
# The interface after 'dev' is your primary egress interface: eth0

# When ProtonVPN is connected, a new interface appears (tun0 or proton0)
# Show it:
ip link show tun0

# Or find whatever VPN interface appeared:
ip link show | grep -E "tun|proton|vpn"

# List interfaces tshark can capture on (tshark's own view)
tshark -D

# Example output:
# 1. eth0
# 2. wlan0
# 3. lo (Loopback)
# 4. tun0

# Determine which interface to capture on for your investigation:
#
# Capturing eth0 or wlan0 (physical interface, pre-VPN):
#   → Sees traffic before VPN encryption
#   → Shows you the VPN tunnel traffic (encrypted blobs to ProtonVPN server)
#   → Also shows DNS queries if they leak outside the VPN
#   → Good for: detecting DNS leaks, VPN tunnel verification
#
# Capturing tun0 (VPN tunnel interface, post-VPN-decryption):
#   → Sees actual web traffic after VPN decryption
#   → Shows real HTTP/HTTPS requests and responses in plaintext-ish form
#   → Good for: seeing what sites you're actually talking to
#   → This is the interface to use for web forensic capture with VPN active
#
# For maximum coverage: capture BOTH simultaneously (see Section 6)

# Confirm interface is carrying traffic (watch packet count increase)
watch -n 1 'ip -s link show eth0'

# Replace eth0 with your interface
# Packets/bytes counters should increment as traffic flows
# Press Ctrl+C to stop watching
```

---

## SECTION 4 — PROTONVPN — CONNECT, VERIFY, MANAGE

```bash
# --- INITIAL SETUP (first time only) ---

# Log in with your ProtonVPN account credentials
protonvpn-cli login yourusername@email.com

# You will be prompted for your ProtonVPN password interactively.
# Note: use your ProtonVPN account password, not your email password.
# If you use SSO/social login for ProtonVPN, generate an OpenVPN/WireGuard
# password in the ProtonVPN web dashboard under Account → OpenVPN/WireGuard.

# --- CONNECTING ---

# Connect to the fastest available server (recommended for general use)
protonvpn-cli connect --fastest

# Connect to a specific country (Switzerland = no-logs jurisdiction, good choice)
protonvpn-cli connect --cc CH

# Connect to a specific country, WireGuard protocol (faster, lower latency)
protonvpn-cli connect --cc CH --protocol wireguard

# Connect to a specific country, OpenVPN UDP (more compatible with some networks)
protonvpn-cli connect --cc CH --protocol openvpn-udp

# Connect to a Secure Core server (routes through two countries — extra anonymity)
# Secure Core: requires ProtonVPN Plus/Visionary plan
protonvpn-cli connect --sc --cc CH

# Connect to a P2P-optimized server (useful for high-bandwidth crawls)
protonvpn-cli connect --p2p --cc SE

# Connect to a specific server by name (get server list from ProtonVPN dashboard)
protonvpn-cli connect CH#5

# --- VERIFICATION (run this every time before starting a session) ---

# Check VPN connection status
protonvpn-cli status

# Expected output when connected:
# Status:     Connected
# Server:     CH#5
# Country:    Switzerland
# Protocol:   WireGuard
# IP:         185.XXX.XXX.XXX
# Load:       23%

# Verify your public IP has changed to the VPN exit IP
curl --max-time 10 https://api64.ipify.org

# Compare this IP against what protonvpn-cli status shows.
# They should match. If your real IP appears here, VPN is not routing correctly.

# Get full IP geolocation to verify country
curl --max-time 10 https://ipapi.co/json/

# Expected: country_name should be Switzerland (or whichever country you connected to)
# If it shows your real country, something is wrong with the VPN routing.

# Verify DNS is going through VPN (not leaking to your ISP's DNS)
# This checks which DNS server resolves your queries
curl --max-time 10 https://dnsleaktest.com/

# For a quick CLI DNS leak check:
nslookup whoami.akamai.net

# The IP returned should be within the VPN's IP range, not your ISP's range

# Check for WebRTC IP leak (the leak that bypasses VPN in browsers)
# This is a manual check — go to: https://browserleaks.com/webrtc
# WebRTC should show only the VPN IP, not your real IP.
# If it shows your real IP: the Selenium authenticated session script
# does not block WebRTC, so use Firefox with WebRTC disabled for sensitive sessions.

# Disable WebRTC in Firefox for sensitive sessions:
# about:config → media.peerconnection.enabled → false

# --- MANAGING THE CONNECTION ---

# Disconnect from VPN
protonvpn-cli disconnect

# Reconnect to the same server after a disconnect
protonvpn-cli connect --last

# Refresh connection (useful if connection drops during a long crawl)
protonvpn-cli reconnect

# Enable kill switch (blocks all internet if VPN drops — critical for investigation safety)
# Note: kill switch support varies by ProtonVPN CLI version
protonvpn-cli killswitch --on

# Disable kill switch
protonvpn-cli killswitch --off

# View available servers
protonvpn-cli servers --cc CH

# Show all available country codes
protonvpn-cli servers --available-countries

# --- NETWORK STATE WITH VPN ACTIVE ---

# After connecting, verify the tun0 interface appeared
ip link show tun0

# See the VPN routing table entry
ip route show | grep tun0

# See all routes (VPN adds a default route through the tunnel)
ip route show table main
```

---

## SECTION 5 — LAUNCHING THE OBSERVATORY WORKSPACE (TMUX)

```bash
# Launch the full Observatory tmux workspace
# Argument 1: your network interface (from Section 3)
~/observatory/scripts/observatory_tmux.sh eth0

# Launch with wifi interface instead
~/observatory/scripts/observatory_tmux.sh wlan0

# Launch with VPN tunnel interface (when capturing post-VPN traffic)
~/observatory/scripts/observatory_tmux.sh tun0

# If you already have a tmux session running, attach to it
tmux attach -t observatory

# List all active tmux sessions
tmux list-sessions

# Kill the Observatory session and start fresh
tmux kill-session -t observatory && ~/observatory/scripts/observatory_tmux.sh eth0

# --- tmux NAVIGATION (essential commands for working in the workspace) ---

# Switch between panes
# Prefix key: Ctrl+B (hold Ctrl, press B, release both, then press next key)

# Move to pane by direction
# Ctrl+B then arrow key (up/down/left/right)

# Move to next pane
# Ctrl+B then o

# Move to previous pane
# Ctrl+B then ; (semicolon)

# Zoom current pane to full screen (toggle)
# Ctrl+B then z

# Create a new window (if you need more space than 4 panes)
# Ctrl+B then c

# Switch to window by number
# Ctrl+B then 0  (window 0)
# Ctrl+B then 1  (window 1)

# Detach from tmux session (leaves it running in background)
# Ctrl+B then d

# Reattach after detaching
tmux attach -t observatory

# Scroll up in a pane (to read output that scrolled off screen)
# Ctrl+B then [   (enters scroll mode)
# Arrow keys or Page Up/Down to scroll
# q to exit scroll mode

# Resize a pane
# Ctrl+B then : (colon) to enter command mode
# Then type: resize-pane -D 5   (shrink downward by 5 lines)
# Then type: resize-pane -U 5   (grow upward by 5 lines)
# Then type: resize-pane -L 10  (shrink left by 10 columns)
# Then type: resize-pane -R 10  (grow right by 10 columns)

# Create a manual tmux session if the script fails
tmux new-session -s observatory
tmux split-window -h
tmux split-window -v -t 0
tmux split-window -v -t 2
tmux select-pane -t 0
```

---

## SECTION 6 — PASSIVE PACKET CAPTURE (TSHARK)

```bash
# --- BASIC CAPTURE ---

# Start capture on eth0, named "my_investigation"
~/observatory/scripts/start_capture.sh eth0 my_investigation

# Start capture on wlan0 (wifi interface)
~/observatory/scripts/start_capture.sh wlan0 my_investigation_wifi

# Start capture on tun0 (VPN tunnel — post-VPN traffic)
~/observatory/scripts/start_capture.sh tun0 my_investigation_vpn

# Start capture with auto-generated timestamp name
~/observatory/scripts/start_capture.sh eth0

# Stop a named capture
~/observatory/scripts/stop_capture.sh my_investigation

# --- DUAL INTERFACE CAPTURE (maximum coverage) ---
# Run two tshark instances simultaneously in separate panes

# Pane 1: capture physical interface (pre-VPN, sees DNS leaks)
tshark \
  -i eth0 \
  -w ~/observatory/captures/dual_session/pre_vpn.pcap \
  -b filesize:102400 \
  -b files:10 \
  -n \
  -q &

echo $! > ~/observatory/captures/dual_session/pre_vpn.pid

# Pane 2: capture VPN tunnel (post-VPN, sees actual web traffic)
tshark \
  -i tun0 \
  -w ~/observatory/captures/dual_session/post_vpn.pcap \
  -b filesize:102400 \
  -b files:10 \
  -n \
  -q &

echo $! > ~/observatory/captures/dual_session/post_vpn.pid

# Stop both captures
kill $(cat ~/observatory/captures/dual_session/pre_vpn.pid)
kill $(cat ~/observatory/captures/dual_session/post_vpn.pid)

# --- TARGETED CAPTURE (reduce noise by filtering at capture time) ---

# Capture only HTTP and HTTPS traffic (ports 80 and 443)
tshark \
  -i tun0 \
  -w ~/observatory/captures/web_only/capture.pcap \
  -f "tcp port 80 or tcp port 443" \
  -n -q &

# Capture only DNS traffic (port 53 UDP) — for DNS leak detection
tshark \
  -i eth0 \
  -w ~/observatory/captures/dns_only/capture.pcap \
  -f "udp port 53" \
  -n -q &

# Capture and display packets in real time while also writing to file
# (useful for watching traffic as it happens during a session)
tshark \
  -i tun0 \
  -w ~/observatory/captures/live_session/capture.pcap \
  -f "tcp port 443" \
  -n \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e tls.handshake.extensions_server_name

# The -T fields -e options above print:
# timestamp | destination IP | SNI (Server Name Indication — the hostname the TLS handshake reveals)
# SNI is visible in TLS traffic even without decryption — reveals exactly which hostnames
# the browser is connecting to in real time

# Capture with host filter (only capture traffic to/from specific IP)
tshark \
  -i tun0 \
  -w ~/observatory/captures/targeted/capture.pcap \
  -f "host 142.250.185.78" \
  -n -q &

# Find the IP of a tracker domain first, then use it as filter
nslookup google-analytics.com
# Then use that IP in the host filter above

# --- LIVE MONITORING (no file write, just terminal output) ---

# Watch all TLS SNI handshakes in real time (see every HTTPS host being contacted)
tshark \
  -i tun0 \
  -n \
  -Y "tls.handshake.type == 1" \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e tls.handshake.extensions_server_name

# Watch all DNS queries in real time
tshark \
  -i eth0 \
  -n \
  -Y "dns.flags.response == 0" \
  -T fields \
  -e frame.time_relative \
  -e dns.qry.name

# Watch all HTTP requests in real time (HTTP only, not HTTPS)
tshark \
  -i tun0 \
  -n \
  -Y "http.request" \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e http.request.method \
  -e http.request.full_uri

# --- VERIFYING CAPTURE IS WORKING ---

# Check capture file is growing (size should increase every few seconds with active traffic)
watch -n 2 'ls -lh ~/observatory/captures/my_investigation/*.pcap'

# Quick packet count in a running capture file
tshark -r ~/observatory/captures/my_investigation/capture.pcap -q 2>/dev/null | tail -3

# Show capture file statistics
capinfos ~/observatory/captures/my_investigation/capture.pcap
```

---

## SECTION 7 — RUNNING CRAWLS (OPENWPM)

```bash
# --- ACTIVATE VIRTUALENV (required for all Python operations) ---

source ~/observatory/.venv/bin/activate

# Verify activation (prompt should show venv prefix, or check:)
which python
# Expected: /home/yourusername/observatory/.venv/bin/python

# --- BASIC SINGLE-SITE CRAWL ---

# Crawl one site, headless browser, default 60-second dwell time
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.nytimes.com"

# Crawl one site and watch what the browser does (headless false)
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.nytimes.com" \
  --headless false

# Crawl one site with a custom session name (makes output directory recognizable)
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.nytimes.com" \
  --name "nytimes_investigation_20240115"

# Crawl one site with extended dwell time (120 seconds on page)
# Use longer dwell times for sites that load tracking scripts on timers
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.nytimes.com" \
  --timeout 120

# --- MULTI-SITE CRAWL ---

# Crawl multiple sites in one session
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.nytimes.com" "https://www.washingtonpost.com" "https://www.theguardian.com"

# Crawl a list of news sites to compare their tracker footprints
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites \
    "https://www.bbc.com" \
    "https://www.cnn.com" \
    "https://www.foxnews.com" \
    "https://www.reuters.com" \
    "https://www.apnews.com" \
  --name "news_comparison_20240115" \
  --timeout 90

# --- CRAWL FROM FILE ---

# Create a sites file first
cat > ~/observatory/my_sites.txt << 'EOF'
# Lines starting with # are ignored
# One URL per line, include full https:// prefix
https://www.example.com
https://www.example2.com
https://shop.example.com/products
https://example.com/privacy-policy
EOF

# Run crawl from file
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --file ~/observatory/my_sites.txt

# Run crawl from file with custom name and timeout
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --file ~/observatory/my_sites.txt \
  --name "ecommerce_investigation" \
  --timeout 90 \
  --headless true

# --- DOCKER COMPOSE ALTERNATIVE (for crawls you want to run detached) ---

cd ~/observatory

# Run a crawl via Docker Compose (runs in foreground, shows container logs)
docker-compose run --rm openwpm python /scripts/crawlers/basic_crawl.py \
  --sites "https://www.example.com"

# Run a crawl detached (runs in background, keeps terminal free)
docker-compose run --rm -d openwpm python /scripts/crawlers/basic_crawl.py \
  --sites "https://www.example.com" \
  --name "background_crawl_01"

# Watch logs from a detached crawl
docker logs -f $(docker ps -q --filter "ancestor=ghcr.io/openwpm/openwpm")

# --- DIRECT DOCKER INVOCATION (maximum control) ---

# Run OpenWPM container interactively (drop to bash shell inside container)
docker run --rm \
  --network host \
  --shm-size 2g \
  -v ~/observatory/crawls:/crawl_output \
  -v ~/observatory/scripts:/scripts:ro \
  -it \
  ghcr.io/openwpm/openwpm:latest \
  /bin/bash

# Inside the container shell, run the crawl script:
# python /scripts/crawlers/basic_crawl.py --sites "https://www.example.com"

# Run OpenWPM container non-interactively with a specific crawl script
docker run --rm \
  --network host \
  --shm-size 2g \
  -v ~/observatory/crawls/custom_session:/crawl_output \
  -v ~/observatory/scripts:/scripts:ro \
  ghcr.io/openwpm/openwpm:latest \
  python /scripts/crawlers/basic_crawl.py \
  --sites "https://www.example.com" \
  --timeout 60

# --- MONITORING A RUNNING CRAWL ---

# Watch the crawl output directory for new database files
watch -n 5 'ls -lh ~/observatory/crawls/'

# Watch the OpenWPM log file (if crawl is writing it)
tail -f ~/observatory/crawls/latest_crawl/openwpm.log

# Watch Docker container resource usage (CPU/memory during crawl)
docker stats $(docker ps -q --filter "ancestor=ghcr.io/openwpm/openwpm")

# Monitor system temperature during crawl (thermal watch for the 7480)
watch -n 5 'paste <(cat /sys/class/thermal/thermal_zone*/type) <(cat /sys/class/thermal/thermal_zone*/temp) | column -s $'"'"'\t'"'"' -t'

# Monitor CPU frequency (check for thermal throttling)
watch -n 2 'grep "cpu MHz" /proc/cpuinfo | awk "{print \$4}" | sort -n | head -1 && grep "cpu MHz" /proc/cpuinfo | awk "{print \$4}" | sort -n | tail -1'
# First number: slowest core. Second: fastest core.
# If numbers drop significantly during crawl: thermal throttling is occurring.
# Mitigation: --timeout 90 with pause between sites (add sleep in crawl script)

# --- VERIFYING CRAWL OUTPUT ---

# List all crawl sessions with database sizes
find ~/observatory/crawls -name "crawl.sqlite" -exec ls -lh {} \;

# Quick row counts in a completed crawl database
sqlite3 ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite \
  "SELECT 'http_requests', COUNT(*) FROM http_requests UNION ALL
   SELECT 'javascript', COUNT(*) FROM javascript UNION ALL
   SELECT 'javascript_cookies', COUNT(*) FROM javascript_cookies UNION ALL
   SELECT 'site_visits', COUNT(*) FROM site_visits;"

# Expected: hundreds to thousands of rows per table for an active site
# A site with zero rows in javascript may have failed to load
```

---

## SECTION 8 — AUTHENTICATED SESSION RECORDING (SELENIUM)

```bash
# --- ACTIVATE VIRTUALENV ---
source ~/observatory/.venv/bin/activate

# --- MANUAL LOGIN MODE (you log in, script records state) ---

# Basic manual session: navigate to site, you log in when browser opens
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://www.example.com/login"

# Manual session with additional pages to visit after you log in
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://www.example.com/login" \
  --navigate "https://www.example.com/dashboard" "https://www.example.com/settings" "https://www.example.com/profile"

# Manual session with longer dwell time (60 seconds per page)
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://www.example.com/login" \
  --navigate "https://www.example.com/dashboard" \
  --dwell-time 60

# Manual session with custom session name and explicit capture interface
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://www.example.com/login" \
  --navigate "https://www.example.com/dashboard" "https://www.example.com/account" \
  --session-name "example_authenticated_20240115" \
  --capture-interface tun0 \
  --dwell-time 45

# --- AUTOMATED LOGIN MODE (script handles login form) ---
# Use only on accounts you own. The script tries common form selectors.

# Automated login with post-login navigation
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://www.example.com" \
  --login-url "https://www.example.com/login" \
  --auto-login \
  --username "youraccount@email.com" \
  --password "yourpassword" \
  --navigate "https://www.example.com/dashboard" "https://www.example.com/settings" \
  --dwell-time 30 \
  --session-name "example_auto_login_20240115" \
  --capture-interface tun0

# Automated login where login page is the same as target page
python ~/observatory/scripts/selenium/authenticated_session.py \
  --target "https://app.example.com" \
  --auto-login \
  --username "testuser@email.com" \
  --password "testpassword123" \
  --navigate "https://app.example.com/feed" "https://app.example.com/preferences" "https://app.example.com/privacy" \
  --dwell-time 45 \
  --session-name "app_full_authenticated_session" \
  --capture-interface tun0

# --- REVIEWING AUTHENTICATED SESSION OUTPUT ---

# List all files captured during a session
ls -la ~/observatory/crawls/example_authenticated_20240115/

# View the session summary
cat ~/observatory/crawls/example_authenticated_20240115/session_summary.json | python -m json.tool

# View cookies captured from a specific page state
cat ~/observatory/crawls/example_authenticated_20240115/page_states/01_initial/page_state.json \
  | python -m json.tool \
  | grep -A 5 '"cookies"'

# View localStorage captured from a specific page state
cat ~/observatory/crawls/example_authenticated_20240115/page_states/02_post_login/page_state.json \
  | python -m json.tool \
  | python -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('localStorage',{}), indent=2))"

# View all third-party scripts loaded on a page
cat ~/observatory/crawls/example_authenticated_20240115/page_states/02_post_login/page_state.json \
  | python -m json.tool \
  | python -c "import sys,json; d=json.load(sys.stdin); [print(s) for s in d.get('loaded_scripts',[])]"

# View all iframes on a page
cat ~/observatory/crawls/example_authenticated_20240115/page_states/02_post_login/page_state.json \
  | python -m json.tool \
  | python -c "import sys,json; d=json.load(sys.stdin); [print(f) for f in d.get('iframes',[])]"

# Open screenshot in default image viewer
xdg-open ~/observatory/crawls/example_authenticated_20240115/page_states/01_initial/screenshot.png

# Open all screenshots in sequence
for img in ~/observatory/crawls/example_authenticated_20240115/page_states/*/screenshot.png; do
  echo "Opening: $img"
  xdg-open "$img"
  sleep 2
done

# --- DISABLING WEBRTC IN FIREFOX FOR SENSITIVE SESSIONS ---
# WebRTC can leak your real IP even through VPN.
# Disable it before opening Firefox for sensitive authenticated sessions.

# Method 1: Via Firefox preferences (persistent, per-profile)
# Open Firefox → address bar: about:config → search: media.peerconnection.enabled → set to false

# Method 2: Create a Firefox profile with WebRTC disabled for forensic use
firefox --createProfile forensic-profile

# Then launch Firefox with that profile and set the preference:
firefox -P forensic-profile -url "about:config"
# Search: media.peerconnection.enabled → double-click to set false
# This profile now always has WebRTC disabled

# Launch authenticated session with WebRTC-disabled profile (requires modifying the script's
# browser Options to specify the profile path):
# options.add_argument("-profile")
# options.add_argument("/home/yourusername/.mozilla/firefox/PROFILEID.forensic-profile")
```

---

## SECTION 9 — EXPLORING RESULTS (DATASETTE)

```bash
# --- LAUNCH DATASETTE ---

# Launch with automatic database discovery (finds all crawl databases)
~/observatory/scripts/launch_datasette.sh

# Launch on a different port (if 8001 is in use)
DATASETTE_PORT=8002 ~/observatory/scripts/launch_datasette.sh

# Launch manually pointing at a specific database
source ~/observatory/.venv/bin/activate && \
datasette serve \
  ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite \
  --port 8001

# Launch pointing at multiple databases simultaneously
source ~/observatory/.venv/bin/activate && \
datasette serve \
  ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite \
  ~/observatory/crawls/news_comparison_20240115/crawl.sqlite \
  ~/observatory/crawls/ecommerce_investigation/crawl.sqlite \
  --port 8001

# Launch with extended row limit (for large result sets)
source ~/observatory/.venv/bin/activate && \
datasette serve \
  ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite \
  --port 8001 \
  --setting max_returned_rows 50000 \
  --setting sql_time_limit_ms 60000

# Launch read-only (safe for sharing, prevents accidental modification)
source ~/observatory/.venv/bin/activate && \
datasette serve \
  ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite \
  --port 8001 \
  --immutable ~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite

# Launch via Docker (no virtualenv needed)
docker run --rm \
  --network host \
  -v ~/observatory/crawls:/crawls:ro \
  datasetteproject/datasette \
  datasette serve /crawls \
  --host 0.0.0.0 \
  --port 8001

# --- OPEN IN BROWSER ---
# Datasette does not auto-open a browser. Open it manually:

# Open Datasette in your default browser
xdg-open http://localhost:8001

# Open directly to a specific database's table view
xdg-open "http://localhost:8001/crawl/http_requests"

# Open to the SQL editor
xdg-open "http://localhost:8001/crawl"

# --- USEFUL DATASETTE URLS (paste into browser after launching) ---

# All tables in the database
# http://localhost:8001/crawl

# HTTP requests table (all web requests captured)
# http://localhost:8001/crawl/http_requests

# JavaScript API calls table (fingerprinting detection)
# http://localhost:8001/crawl/javascript

# Cookie operations table
# http://localhost:8001/crawl/javascript_cookies

# localStorage operations
# http://localhost:8001/crawl/localstorage

# Site visits (what was crawled and when)
# http://localhost:8001/crawl/site_visits

# SQL editor — run custom queries
# http://localhost:8001/crawl?sql=SELECT+*+FROM+http_requests+LIMIT+100

# Filter http_requests to a specific site
# http://localhost:8001/crawl/http_requests?top_level_url=https%3A%2F%2Fwww.nytimes.com%2F

# Filter javascript table to canvas calls only
# http://localhost:8001/crawl/javascript?symbol__contains=Canvas

# Filter javascript table to WebGL calls
# http://localhost:8001/crawl/javascript?symbol__contains=WebGL

# Download the entire database as a file from Datasette UI
# http://localhost:8001/crawl.db

# --- STOPPING DATASETTE ---

# Datasette runs in foreground. Stop with:
# Ctrl+C in the terminal where it's running

# If running in a tmux pane: navigate to that pane and press Ctrl+C
```

---

## SECTION 10 — ANALYZING CAPTURES (TSHARK + WIRESHARK)

```bash
# --- BASIC CAPTURE STATISTICS ---

# Show overall statistics for a capture file
capinfos ~/observatory/captures/my_investigation/capture.pcap

# Show packet count and duration only
capinfos -c -u ~/observatory/captures/my_investigation/capture.pcap

# Count packets by protocol
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -q \
  -z io,phs

# --- EXTRACTING HOSTNAMES AND IPs ---

# List all unique destination IPs in the capture
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -T fields \
  -e ip.dst \
  | sort -u

# List all TLS SNI hostnames (what HTTPS sites were contacted — readable without decryption)
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "tls.handshake.type == 1" \
  -T fields \
  -e ip.dst \
  -e tls.handshake.extensions_server_name \
  | sort -u

# List all DNS queries made during session
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "dns.flags.response == 0" \
  -T fields \
  -e frame.time_relative \
  -e dns.qry.name \
  | sort -k2 -u

# Count unique domains contacted (via DNS queries)
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "dns.flags.response == 0" \
  -T fields \
  -e dns.qry.name \
  | sort -u \
  | wc -l

# --- HTTP TRAFFIC ANALYSIS ---

# List all HTTP request URLs (unencrypted HTTP only)
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "http.request" \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e http.request.method \
  -e http.request.full_uri

# List all HTTP POST requests (data exfiltration candidates)
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "http.request.method == POST" \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e http.request.full_uri \
  -e http.file_data

# Find requests to known tracker endpoints in capture
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "http.request" \
  -T fields \
  -e http.request.full_uri \
  | grep -iE "google-analytics|googletagmanager|doubleclick|facebook.com/tr|bat.bing|hotjar|mixpanel|amplitude|segment.io|clarity.ms"

# --- TIMING ANALYSIS ---

# Show the first 50 connections with timestamps (session timeline)
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "tcp.flags.syn == 1 and tcp.flags.ack == 0" \
  -T fields \
  -e frame.time_relative \
  -e ip.dst \
  -e tcp.dstport \
  | head -50

# Find connections that happened immediately on page load (first 5 seconds)
# These are pre-loaded trackers injected before any user interaction
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "frame.time_relative < 5 and tls.handshake.type == 1" \
  -T fields \
  -e frame.time_relative \
  -e tls.handshake.extensions_server_name

# --- DNS LEAK DETECTION ---

# Check if any DNS queries went to your ISP's DNS instead of through VPN
# First: identify your ISP's DNS server IP (visible in router settings, or:)
nmcli dev show | grep DNS

# Then search for DNS traffic to that IP in the pre-VPN capture
tshark \
  -r ~/observatory/captures/dual_session/pre_vpn.pcap \
  -n \
  -Y "dns and ip.dst == 192.168.1.1" \
  -T fields \
  -e frame.time_relative \
  -e dns.qry.name

# Replace 192.168.1.1 with your router/ISP DNS IP
# Any results here = DNS leak (queries bypassing VPN tunnel)

# --- OPENING IN WIRESHARK GUI ---

# Open a capture file in Wireshark for visual analysis
wireshark ~/observatory/captures/my_investigation/capture.pcap

# Open and immediately apply a filter (filter syntax in double quotes)
wireshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -Y "tls.handshake.type == 1"

# Open with color profiles for web traffic analysis
# (do this once inside Wireshark: View → Coloring Rules → import observatory rules)
wireshark ~/observatory/captures/my_investigation/capture.pcap

# --- USEFUL WIRESHARK DISPLAY FILTERS (paste into Wireshark filter bar) ---

# All TLS handshakes (see what HTTPS hosts were contacted)
# tls.handshake.type == 1

# All DNS queries
# dns.flags.response == 0

# All HTTP requests
# http.request

# All HTTP POST requests
# http.request.method == "POST"

# Traffic to/from a specific IP
# ip.addr == 142.250.185.78

# Traffic to a specific port
# tcp.dstport == 443

# Large packets (possible data exfiltration — unusual large POST bodies)
# frame.len > 10000 and http.request.method == "POST"

# All connections established in first 3 seconds of capture
# frame.time_relative < 3 and tcp.flags.syn == 1

# --- EXPORTING DATA FROM CAPTURES ---

# Export all HTTP objects (files transferred over HTTP) from a capture
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  --export-objects http,~/observatory/captures/my_investigation/http_objects

# List what was exported
ls -la ~/observatory/captures/my_investigation/http_objects/

# Export as CSV for import into spreadsheet
tshark \
  -r ~/observatory/captures/my_investigation/capture.pcap \
  -n \
  -Y "tls.handshake.type == 1" \
  -T fields \
  -e frame.number \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e tls.handshake.extensions_server_name \
  -E header=y \
  -E separator=, \
  -E quote=d \
  > ~/observatory/captures/my_investigation/tls_connections.csv
```

---

## SECTION 11 — SQL ANALYSIS AGAINST OPENWPM DATABASES

```bash
# --- SETUP: define a shortcut variable for the database path ---

# Set the database variable for the session (change path to your crawl)
DB=~/observatory/crawls/nytimes_investigation_20240115/crawl.sqlite

# Verify the database exists and has content
sqlite3 "$DB" ".tables"

# Expected tables:
# dns_responses    http_requests    javascript_cookies    site_visits
# http_responses   javascript       localstorage          (possibly more)

# --- SESSION OVERVIEW ---

# What sites were crawled and when?
sqlite3 "$DB" \
  "SELECT visit_id, site_url, start_time, end_time FROM site_visits ORDER BY start_time;"

# How many total requests per site?
sqlite3 "$DB" \
  "SELECT sv.site_url, COUNT(*) AS total_requests
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   GROUP BY sv.site_url
   ORDER BY total_requests DESC;"

# --- FINGERPRINTING DETECTION ---

# Run the pre-written fingerprinting detection query file
sqlite3 "$DB" < ~/observatory/scripts/sql/find_fingerprinting.sql

# Canvas fingerprinting calls only
sqlite3 "$DB" \
  "SELECT sv.site_url, j.script_url, j.symbol, j.operation, j.time_stamp
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%Canvas%' OR j.symbol LIKE '%toDataURL%' OR j.symbol LIKE '%getImageData%'
   ORDER BY j.time_stamp;"

# WebGL GPU fingerprinting calls (the UNMASKED_RENDERER query)
sqlite3 "$DB" \
  "SELECT sv.site_url, j.script_url, j.symbol, j.arguments, j.value
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%WebGL%' AND (j.arguments LIKE '%37446%' OR j.arguments LIKE '%37445%');"

# All Navigator API probing (environment fingerprinting)
sqlite3 "$DB" \
  "SELECT sv.site_url, j.script_url, j.symbol, j.value
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE 'Navigator.%'
   ORDER BY j.script_url, j.symbol;"

# AudioContext fingerprinting
sqlite3 "$DB" \
  "SELECT sv.site_url, j.script_url, j.symbol, j.time_stamp
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%AudioContext%' OR j.symbol LIKE '%createOscillator%'
   ORDER BY j.time_stamp;"

# WebRTC IP leak attempts
sqlite3 "$DB" \
  "SELECT sv.site_url, j.script_url, j.symbol, j.arguments, j.time_stamp
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%RTCPeerConnection%';"

# Fingerprinting score per site (count of fingerprinting API calls)
sqlite3 -column -header "$DB" \
  "SELECT
     sv.site_url,
     COUNT(CASE WHEN j.symbol LIKE '%Canvas%' OR j.symbol LIKE '%toDataURL%' THEN 1 END) AS canvas,
     COUNT(CASE WHEN j.symbol LIKE '%WebGL%' THEN 1 END) AS webgl,
     COUNT(CASE WHEN j.symbol LIKE '%AudioContext%' THEN 1 END) AS audio,
     COUNT(CASE WHEN j.symbol LIKE 'Navigator.%' THEN 1 END) AS navigator,
     COUNT(CASE WHEN j.symbol LIKE '%RTCPeerConnection%' THEN 1 END) AS webrtc,
     COUNT(*) AS total_api_calls
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   GROUP BY sv.site_url
   ORDER BY total_api_calls DESC;"

# --- TRACKER IDENTIFICATION ---

# Run the pre-written tracker identification query file
sqlite3 "$DB" < ~/observatory/scripts/sql/find_trackers.sql

# All unique third-party domains contacted (not on same domain as the page)
sqlite3 "$DB" \
  "SELECT DISTINCT
     sv.site_url,
     r.url
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE r.url NOT LIKE '%' || REPLACE(REPLACE(sv.site_url, 'https://', ''), 'http://', '') || '%'
   ORDER BY sv.site_url, r.url
   LIMIT 200;"

# Count distinct third-party domains per site
sqlite3 -column -header "$DB" \
  "SELECT
     sv.site_url,
     COUNT(DISTINCT SUBSTR(r.url, 1, INSTR(r.url || '/', '/') + 1)) AS third_party_domains
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE instr(r.url, REPLACE(REPLACE(sv.site_url,'https://',''),'http://','')) = 0
   GROUP BY sv.site_url
   ORDER BY third_party_domains DESC;"

# Find all POST requests to third-party domains (exfiltration)
sqlite3 "$DB" \
  "SELECT sv.site_url, r.url, r.post_body, r.time_stamp
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE r.method = 'POST'
   AND r.url NOT LIKE '%' || REPLACE(REPLACE(sv.site_url, 'https://', ''), 'http://', '') || '%'
   ORDER BY r.time_stamp;"

# Find all Google Analytics beacon requests
sqlite3 "$DB" \
  "SELECT sv.site_url, r.url, r.time_stamp
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE r.url LIKE '%google-analytics.com/collect%'
      OR r.url LIKE '%analytics.google.com/g/collect%'
   ORDER BY r.time_stamp;"

# Find all Facebook Pixel requests
sqlite3 "$DB" \
  "SELECT sv.site_url, r.url, r.time_stamp
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE r.url LIKE '%facebook.com/tr%'
      OR r.url LIKE '%connect.facebook.net%'
   ORDER BY r.time_stamp;"

# --- COOKIE ANALYSIS ---

# All cookies set via JavaScript (JS-accessible cookies, not HttpOnly)
sqlite3 -column -header "$DB" \
  "SELECT
     top_level_url,
     host,
     name,
     value,
     expiry,
     is_http_only,
     is_secure,
     same_site
   FROM javascript_cookies
   WHERE operation = 'set'
   ORDER BY expiry DESC
   LIMIT 100;"

# Long-lived tracking cookies (expires more than 30 days from now)
sqlite3 "$DB" \
  "SELECT top_level_url, host, name, value, datetime(expiry, 'unixepoch') AS expires_at
   FROM javascript_cookies
   WHERE operation = 'set'
   AND expiry > strftime('%s', 'now') + 2592000
   ORDER BY expiry DESC;"

# --- LOCALSTORAGE ANALYSIS ---

# All localStorage items written during crawl
sqlite3 -column -header "$DB" \
  "SELECT sv.site_url, ls.key, ls.value, LENGTH(ls.value) AS value_length
   FROM localstorage ls
   JOIN site_visits sv ON ls.visit_id = sv.visit_id
   ORDER BY sv.site_url, ls.key;"

# localStorage items that look like unique identifiers (long random strings)
sqlite3 "$DB" \
  "SELECT sv.site_url, ls.key, ls.value
   FROM localstorage ls
   JOIN site_visits sv ON ls.visit_id = sv.visit_id
   WHERE LENGTH(ls.value) > 20
   AND ls.value NOT LIKE '%{%'
   ORDER BY LENGTH(ls.value) DESC;"

# --- DNS RESOLUTION ANALYSIS ---

# What domains were resolved and to which IPs?
sqlite3 -column -header "$DB" \
  "SELECT sv.site_url, d.host, d.dns_resolved_ip
   FROM dns_responses d
   JOIN site_visits sv ON d.visit_id = sv.visit_id
   ORDER BY sv.site_url, d.host;"

# --- EXPORTING QUERY RESULTS ---

# Export fingerprinting summary to CSV
sqlite3 -csv -header "$DB" \
  "SELECT sv.site_url, j.symbol, j.script_url, j.time_stamp
   FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%Canvas%' OR j.symbol LIKE '%WebGL%' OR j.symbol LIKE '%AudioContext%'" \
  > ~/observatory/crawls/nytimes_investigation_20240115/fingerprinting_calls.csv

# Export all third-party HTTP requests to CSV
sqlite3 -csv -header "$DB" \
  "SELECT sv.site_url, r.url, r.method, r.time_stamp
   FROM http_requests r
   JOIN site_visits sv ON r.visit_id = sv.visit_id
   WHERE instr(r.url, REPLACE(REPLACE(sv.site_url,'https://',''),'http://','')) = 0" \
  > ~/observatory/crawls/nytimes_investigation_20240115/third_party_requests.csv

# Export to JSON using jq
sqlite3 -json "$DB" \
  "SELECT sv.site_url, j.symbol, j.script_url FROM javascript j
   JOIN site_visits sv ON j.visit_id = sv.visit_id
   WHERE j.symbol LIKE '%Canvas%'" \
  | jq '.' \
  > ~/observatory/crawls/nytimes_investigation_20240115/canvas_calls.json
```

---

## SECTION 12 — DOCKER MANAGEMENT

```bash
# --- IMAGE MANAGEMENT ---

# List all Docker images (verify OpenWPM is present)
docker images

# Pull latest OpenWPM image (update when project releases new version)
docker pull ghcr.io/openwpm/openwpm:latest

# Check OpenWPM image size
docker images ghcr.io/openwpm/openwpm:latest --format "{{.Size}}"

# Remove old/dangling images (free up disk space)
docker image prune -f

# Remove all unused images (aggressive cleanup — rebuilds will re-pull)
docker image prune -a -f

# --- CONTAINER MANAGEMENT ---

# List running containers (should be empty when not crawling)
docker ps

# List all containers including stopped ones
docker ps -a

# Stop a running container by ID (get ID from docker ps)
docker stop a1b2c3d4e5f6

# Stop all running containers (emergency stop)
docker stop $(docker ps -q)

# Remove all stopped containers (cleanup)
docker container prune -f

# View logs from the most recently run OpenWPM container
docker logs $(docker ps -lq)

# View logs from a specific container
docker logs a1b2c3d4e5f6

# View logs in real time from the most recently started container
docker logs -f $(docker ps -lq)

# --- RESOURCE MONITORING ---

# Live resource usage of all running containers
docker stats

# One-shot resource snapshot (no continuous display)
docker stats --no-stream

# --- DOCKER SYSTEM CLEANUP ---

# Show disk usage by Docker (images, containers, volumes, build cache)
docker system df

# Full system prune (removes everything not currently in use — be careful)
docker system prune -f

# Remove volumes too (only if you're sure no important data is in Docker volumes)
docker system prune --volumes -f

# --- TROUBLESHOOTING DOCKER ---

# Restart Docker daemon (if containers are misbehaving)
sudo systemctl restart docker

# View Docker daemon logs (for startup errors, especially on linux-hardened)
sudo journalctl -u docker -n 100 --no-pager

# Test that Docker can run containers with network access
docker run --rm --network host alpine wget -qO- https://api64.ipify.org

# Test that Docker inherits host VPN routing
# (this should show the VPN IP, not your real IP — if ProtonVPN is connected)
docker run --rm --network host alpine sh -c "wget -qO- https://api64.ipify.org"
```

---

## SECTION 13 — SESSION ARCHIVAL AND CLEANUP

```bash
# --- ARCHIVING A COMPLETED SESSION ---

# Create a session archive with all relevant files
SESSION_NAME="nytimes_investigation_20240115"
ARCHIVE_DIR=~/observatory/archives

mkdir -p "$ARCHIVE_DIR"

# Package the crawl database, capture files, and session notes together
tar -czf \
  "$ARCHIVE_DIR/${SESSION_NAME}_archive.tar.gz" \
  ~/observatory/crawls/$SESSION_NAME/ \
  ~/observatory/captures/$SESSION_NAME/

# Verify archive integrity
tar -tzf "$ARCHIVE_DIR/${SESSION_NAME}_archive.tar.gz" | head -20

# Check archive size
ls -lh "$ARCHIVE_DIR/${SESSION_NAME}_archive.tar.gz"

# --- GENERATING SESSION REPORT ---

# Generate a quick text report from the database
SESSION_NAME="nytimes_investigation_20240115"
DB=~/observatory/crawls/$SESSION_NAME/crawl.sqlite
REPORT=~/observatory/crawls/$SESSION_NAME/report.txt

{
  echo "OBSERVATORY SESSION REPORT"
  echo "Session: $SESSION_NAME"
  echo "Generated: $(date)"
  echo ""
  echo "=== SITES CRAWLED ==="
  sqlite3 "$DB" "SELECT site_url FROM site_visits ORDER BY start_time;"
  echo ""
  echo "=== REQUEST TOTALS ==="
  sqlite3 -column "$DB" \
    "SELECT sv.site_url, COUNT(*) AS requests
     FROM http_requests r JOIN site_visits sv ON r.visit_id = sv.visit_id
     GROUP BY sv.site_url ORDER BY requests DESC;"
  echo ""
  echo "=== FINGERPRINTING API CALLS ==="
  sqlite3 -column "$DB" \
    "SELECT sv.site_url,
       COUNT(CASE WHEN j.symbol LIKE '%Canvas%' THEN 1 END) AS canvas,
       COUNT(CASE WHEN j.symbol LIKE '%WebGL%' THEN 1 END) AS webgl,
       COUNT(CASE WHEN j.symbol LIKE '%AudioContext%' THEN 1 END) AS audio,
       COUNT(CASE WHEN j.symbol LIKE '%RTCPeerConnection%' THEN 1 END) AS webrtc
     FROM javascript j JOIN site_visits sv ON j.visit_id = sv.visit_id
     GROUP BY sv.site_url;"
  echo ""
  echo "=== KNOWN TRACKERS FOUND ==="
  sqlite3 "$DB" \
    "SELECT DISTINCT
       CASE
         WHEN r.url LIKE '%google-analytics%' THEN 'Google Analytics'
         WHEN r.url LIKE '%googletagmanager%' THEN 'Google Tag Manager'
         WHEN r.url LIKE '%doubleclick%' THEN 'Google DoubleClick'
         WHEN r.url LIKE '%facebook.com/tr%' THEN 'Facebook Pixel'
         WHEN r.url LIKE '%bat.bing%' THEN 'Bing UET'
         WHEN r.url LIKE '%hotjar%' THEN 'Hotjar'
         WHEN r.url LIKE '%mixpanel%' THEN 'Mixpanel'
         WHEN r.url LIKE '%segment.io%' THEN 'Segment'
         WHEN r.url LIKE '%fullstory%' THEN 'FullStory'
         WHEN r.url LIKE '%clarity.ms%' THEN 'Microsoft Clarity'
       END AS tracker,
       sv.site_url
     FROM http_requests r
     JOIN site_visits sv ON r.visit_id = sv.visit_id
     WHERE tracker IS NOT NULL
     ORDER BY tracker, sv.site_url;"
} > "$REPORT"

cat "$REPORT"
echo ""
echo "Report saved to: $REPORT"

# --- CLEANUP AFTER SESSION ---

# Remove all stopped Docker containers
docker container prune -f

# Remove dangling Docker images (untagged intermediate layers)
docker image prune -f

# Clear virtualenv pip cache (free disk space)
~/observatory/.venv/bin/pip cache purge

# List all Observatory disk usage
du -sh ~/observatory/crawls/
du -sh ~/observatory/captures/
du -sh ~/observatory/archives/
du -sh ~/observatory/.venv/

# Total Observatory footprint
du -sh ~/observatory/

# --- ROLLING BACK (after hostile page investigation) ---
# If you used a VM snapshot before the session (recommended for hostile pages):
# The Observatory scripts run on the HOST, not in a VM.
# For maximum safety with hostile pages:
# 1. Run Observatory scripts on host
# 2. Do the actual BROWSING in a disposable VM or container
# 3. Route the VM through the Observatory capture interface
# 4. Roll back the VM after session — host stays clean

# Delete a specific crawl session (to free disk space)
rm -rf ~/observatory/crawls/test_crawl_20240101/

# Delete a specific capture session
rm -rf ~/observatory/captures/test_session_20240101/
```

---

## SECTION 14 — TROUBLESHOOTING

```bash
# --- PROBLEM: docker: permission denied ---
# CAUSE: User not in docker group, or group hasn't refreshed

newgrp docker
# If that doesn't work: log out and back in.
# Nuclear option (not recommended, bypasses group membership):
sudo docker ps

# --- PROBLEM: tshark: Couldn't run /usr/bin/dumpcap in child process ---
# CAUSE: dumpcap missing capabilities or user not in wireshark group

sudo setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap
# Then verify:
getcap /usr/bin/dumpcap
# Then try again:
tshark -i eth0 -c 3 -q

# --- PROBLEM: OpenWPM container exits immediately with no output ---
# CAUSE: Usually insufficient shared memory (Firefox crashes without it)

# Verify --shm-size 2g is in your docker run command
# Test with explicit shm:
docker run --rm --shm-size 2g ghcr.io/openwpm/openwpm:latest \
  python -c "print('container OK')"

# If container still exits: check Docker logs
docker logs $(docker ps -lq 2>/dev/null || echo "no_container")

# --- PROBLEM: OpenWPM crawl.sqlite is empty or has zero rows ---
# CAUSE: Firefox failed to start, or page didn't load within timeout

# Increase timeout and try with visible browser:
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://www.example.com" \
  --timeout 120 \
  --headless false

# Check for OpenWPM log file:
cat ~/observatory/crawls/latest_crawl_name/openwpm.log | tail -50

# --- PROBLEM: Datasette shows "no databases found" ---
# CAUSE: No crawl.sqlite files exist yet, or path mismatch

# Find all sqlite files in Observatory:
find ~/observatory -name "*.sqlite" 2>/dev/null

# Launch Datasette with explicit path:
source ~/observatory/.venv/bin/activate && \
datasette serve ~/observatory/crawls/your_crawl_name/crawl.sqlite --port 8001

# --- PROBLEM: ProtonVPN connect fails with authentication error ---
# CAUSE: Wrong credentials (OpenVPN/WireGuard password, not account password)

# Generate OpenVPN/WireGuard credentials:
# 1. Log in at account.protonvpn.com
# 2. Go to Account → OpenVPN / IKEv2 username
# 3. Use the username and password shown there (different from your ProtonVPN login)

protonvpn-cli logout
protonvpn-cli login YOUR_OPENVPN_USERNAME

# --- PROBLEM: VPN connected but curl still shows real IP ---
# CAUSE: Split tunneling, routing leak, or kill switch not enabled

# Check routing table:
ip route show table main
# All traffic should route through tun0, not directly through eth0

# Check if tun0 interface exists:
ip link show tun0

# Force reconnect:
protonvpn-cli disconnect && protonvpn-cli connect --cc CH

# --- PROBLEM: Thermal throttling during crawl (7480) ---
# SYMPTOMS: Crawls take much longer than expected, CPU frequencies drop

# Check current temperatures:
paste <(cat /sys/class/thermal/thermal_zone*/type) \
      <(cat /sys/class/thermal/thermal_zone*/temp | awk '{print $1/1000 "°C"}') \
  | column -t

# Check CPU frequency throttling:
grep "cpu MHz" /proc/cpuinfo | awk '{print $4}' | sort -n

# Mitigations:
# 1. Use longer timeouts (--timeout 90) to slow down the crawl
# 2. Add sleep between site visits in the crawl script
# 3. Close other applications during crawl
# 4. Ensure laptop is on a hard surface (not soft surface blocking vents)
# 5. Consider reducing to 1 browser (already the default: num_browsers=1)

# Monitor temperature and frequency together:
watch -n 3 '
echo "=== CPU Frequencies ==="
grep "cpu MHz" /proc/cpuinfo | awk "{print \$4}" | sort -n | head -1 | xargs echo "Min:"
grep "cpu MHz" /proc/cpuinfo | awk "{print \$4}" | sort -n | tail -1 | xargs echo "Max:"
echo ""
echo "=== Temperatures ==="
paste <(cat /sys/class/thermal/thermal_zone*/type) \
      <(cat /sys/class/thermal/thermal_zone*/temp | awk "{print \$1/1000 \"°C\"}")
'

# --- PROBLEM: linux-hardened kernel + Docker errors ---
# CAUSE: Hardened kernel disables some features Docker needs

# Required sysctl settings for Docker on linux-hardened:
echo "kernel.unprivileged_userns_clone=1" | sudo tee /etc/sysctl.d/99-docker.conf
sudo sysctl --system

# If using user namespaces in Docker:
echo "user.max_user_namespaces=15000" | sudo tee -a /etc/sysctl.d/99-docker.conf
sudo sysctl --system

# Restart Docker after sysctl changes:
sudo systemctl restart docker

# Verify Docker can create containers:
docker run --rm hello-world

# --- PROBLEM: Selenium/geckodriver version mismatch ---
# CAUSE: Firefox updated, geckodriver version no longer matches

source ~/observatory/.venv/bin/activate

# Force geckodriver reinstall to match current Firefox:
pip install --upgrade geckodriver-autoinstaller
python -c "import geckodriver_autoinstaller; geckodriver_autoinstaller.install(True)"

# Check Firefox version:
firefox --version

# Check geckodriver version:
geckodriver --version
```

---

## SECTION 15 — QUICK REFERENCE CARD

```bash
# ════════════════════════════════════════════════════════════
# OBSERVATORY QUICK REFERENCE — copy this to a sticky note
# ════════════════════════════════════════════════════════════

# STEP 1: Connect VPN
protonvpn-cli connect --cc CH

# STEP 2: Verify VPN
curl https://api64.ipify.org

# STEP 3: Find your interface
ip route show default

# STEP 4: Launch workspace
~/observatory/scripts/observatory_tmux.sh tun0

# STEP 5: Start capture
~/observatory/scripts/start_capture.sh tun0 session_$(date +%Y%m%d)

# STEP 6: Activate virtualenv
source ~/observatory/.venv/bin/activate

# STEP 7: Run crawl
python ~/observatory/scripts/crawlers/basic_crawl.py \
  --sites "https://target-site.com" \
  --name "target_$(date +%Y%m%d)" \
  --timeout 90

# STEP 8: Stop capture
~/observatory/scripts/stop_capture.sh session_$(date +%Y%m%d)

# STEP 9: Launch Datasette
~/observatory/scripts/launch_datasette.sh
# Open: http://localhost:8001

# STEP 10: Analyze capture
tshark \
  -r ~/observatory/captures/session_$(date +%Y%m%d)/capture.pcap \
  -n \
  -Y "tls.handshake.type == 1" \
  -T fields \
  -e tls.handshake.extensions_server_name \
  | sort -u

# STEP 11: Run SQL analysis
DB=~/observatory/crawls/target_$(date +%Y%m%d)/crawl.sqlite
sqlite3 "$DB" < ~/observatory/scripts/sql/find_fingerprinting.sql
sqlite3 "$DB" < ~/observatory/scripts/sql/find_trackers.sql

# STEP 12: Generate report and archive
SESSION="target_$(date +%Y%m%d)"
tar -czf \
  ~/observatory/archives/${SESSION}_archive.tar.gz \
  ~/observatory/crawls/$SESSION/ \
  ~/observatory/captures/session_$(date +%Y%m%d)/

# DISCONNECT VPN when done
protonvpn-cli disconnect

# ════════════════════════════════════════════════════════════
# EMERGENCY STOPS
# ════════════════════════════════════════════════════════════

# Stop all Docker containers immediately
docker stop $(docker ps -q)

# Kill all tshark processes
pkill tshark

# Kill tmux session
tmux kill-session -t observatory

# Disconnect VPN
protonvpn-cli disconnect

# ════════════════════════════════════════════════════════════
# KEY FILE PATHS
# ════════════════════════════════════════════════════════════
# Crawl databases:    ~/observatory/crawls/SESSION_NAME/crawl.sqlite
# Packet captures:    ~/observatory/captures/SESSION_NAME/capture.pcap
# Session archives:   ~/observatory/archives/SESSION_NAME_archive.tar.gz
# SQL queries:        ~/observatory/scripts/sql/
# Crawl scripts:      ~/observatory/scripts/crawlers/basic_crawl.py
# Session scripts:    ~/observatory/scripts/selenium/authenticated_session.py
# Python virtualenv:  ~/observatory/.venv/bin/activate
# Docker compose:     ~/observatory/docker-compose.yml
# This manual:        ~/observatory/MANUAL.md
```

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

1. First-Boot Verification
2. Group Membership and Session Refresh
3. Network Interface Identification
4. ProtonVPN — Connect, Verify, Manage
5. Launching the Observatory Workspace (tmux)
6. Passive Packet Capture (tshark)
7. Running Crawls (OpenWPM)
8. Authenticated Session Recording (Selenium)
9. Exploring Results (Datasette)
10. Analyzing Captures (tshark + Wireshark)
11. SQL Analysis Against OpenWPM Databases
12. Docker Management
13. Session Archival and Cleanup
14. Troubleshooting
15. Quick Reference Card

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

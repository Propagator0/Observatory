#!/usr/bin/env bash
# =============================================================================
# PACKAGE 3: THE ISOLATED OBSERVATORY — SETUP SCRIPT
# Reconfigured for Arch Linux + Docker + OpenWPM + tshark + Datasette + ProtonVPN
# =============================================================================
# Philosophy: passive capture depth over active interception breadth.
# This script is idempotent where possible — safe to re-run if something fails
# partway through. Every section is labeled and can be run independently
# by sourcing the script and calling the relevant function directly.
#
# Target OS: Arch Linux (or Manjaro/EndeavourOS — any pacman-based distro)
# Tested kernel: linux and linux-lts (linux-hardened note at relevant sections)
# Required: internet connection, sudo privileges, ~8GB free disk for Docker images
#
# ETHICAL REMINDER: Point this at systems you own or have explicit permission
# to investigate. This is a measurement instrument, not a weapon.
# =============================================================================

set -euo pipefail
# -e: exit on error. -u: treat unset vars as error. -o pipefail: pipes fail loudly.
# We want to know immediately when something goes wrong rather than
# silently continuing into a broken state.

# =============================================================================
# CONFIGURATION — edit these before running
# =============================================================================

# Where all Observatory output will live. Change this to a path on a drive
# with enough space — OpenWPM SQLite databases grow fast on large crawls.
OBSERVATORY_ROOT="${HOME}/observatory"

# Where this script lives. Used to locate the operator manual that ships
# alongside it in the repository, so it can be installed next to the tools
# it documents. Resolved before any directory changes occur.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Filename of the operator manual as it appears in the repository.
MANUAL_SOURCE_NAME="Observatory Operational Manual.md"

# The network interface tshark will capture on.
# Find yours with: ip link show
# Common values: eth0, enp3s0, wlan0, wlp2s0
# If routing through ProtonVPN, traffic exits via a tun0 or proton0 interface —
# capture BOTH your physical interface (pre-VPN) and tun0 (post-VPN) for the
# full three-layer picture described in the package reasoning.
CAPTURE_INTERFACE="eth0"

# Datasette port — the browser UI for exploring OpenWPM's SQLite output
DATASETTE_PORT="8001"

# Docker image name for OpenWPM — the project's official image
# Check for newer tags at: https://github.com/openwpm/OpenWPM/pkgs/container/openwpm
OPENWPM_IMAGE="ghcr.io/openwpm/openwpm:latest"

# Your ProtonVPN credentials file path.
# ProtonVPN CLI on Linux uses a stored credentials system —
# we'll walk through the setup interactively rather than hardcoding creds here.
PROTONVPN_CREDS_NOTE="ProtonVPN credentials will be configured interactively."

# =============================================================================
# COLORS AND LOGGING — because a forensic script that's unreadable is useless
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${BLUE}  $1${RESET}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${RESET}"
    echo ""
}

log_info()    { echo -e "${CYAN}[INFO]${RESET}    $1"; }
log_success() { echo -e "${GREEN}[OK]${RESET}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $1"; }
log_step()    { echo -e "${BOLD}  →${RESET} $1"; }

# =============================================================================
# PREREQUISITE CHECK — fail fast if the environment isn't what we expect
# =============================================================================

check_prerequisites() {
    log_section "Checking Prerequisites"

    # Verify we're on a pacman-based system
    if ! command -v pacman &>/dev/null; then
        log_error "pacman not found. This script targets Arch Linux and derivatives."
        log_error "For Debian/Ubuntu, replace pacman -S with apt install throughout."
        exit 1
    fi
    log_success "pacman found — Arch-based system confirmed"

    # Check sudo access
    if ! sudo -v &>/dev/null; then
        log_error "sudo access required. Run as a user with sudo privileges."
        exit 1
    fi
    log_success "sudo access confirmed"

    # Check internet connectivity — we need to pull Docker images
    if ! curl -s --max-time 5 https://archlinux.org &>/dev/null; then
        log_error "No internet connectivity detected. Required for package downloads."
        exit 1
    fi
    log_success "Internet connectivity confirmed"

    # Warn about linux-hardened kernel and Docker
    CURRENT_KERNEL=$(uname -r)
    if echo "$CURRENT_KERNEL" | grep -q "hardened"; then
        log_warn "linux-hardened kernel detected: ${CURRENT_KERNEL}"
        log_warn "Docker on linux-hardened requires specific kernel parameters."
        log_warn "See: https://wiki.archlinux.org/title/Docker#Installation"
        log_warn "Specifically: user namespaces may need 'kernel.unprivileged_userns_clone=1'"
        log_warn "Add to /etc/sysctl.d/99-docker.conf and run: sudo sysctl --system"
        log_warn "Continuing anyway — script will verify Docker works before proceeding."
        echo ""
    fi

    # Check available disk space (need at least 8GB for Docker images + captures)
    AVAILABLE_GB=$(df "${HOME}" | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "${AVAILABLE_GB}" -lt 8 ]; then
        log_warn "Only ${AVAILABLE_GB}GB available in ${HOME}."
        log_warn "OpenWPM Docker image is ~4GB. Large crawls generate substantial SQLite files."
        log_warn "Consider pointing OBSERVATORY_ROOT at a larger partition."
        read -r -p "Continue anyway? [y/N] " CONTINUE
        [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1
    else
        log_success "Disk space: ${AVAILABLE_GB}GB available — sufficient"
    fi
}

# =============================================================================
# SECTION 1: SYSTEM PACKAGES
# Core tools that come from official Arch repos via pacman
# =============================================================================

install_system_packages() {
    log_section "Installing System Packages (pacman)"

    log_step "Updating package database..."
    sudo pacman -Sy --noconfirm

    # Core packages we need:
    # - docker: the container runtime (replaces VirtualBox for this stack)
    # - docker-compose: orchestrates multi-container setups (useful for OpenWPM + Datasette)
    # - wireshark-qt: full Wireshark GUI (tshark is included as a dependency)
    # - wireshark-cli: explicitly pulls tshark if GUI isn't desired separately
    # - python: for OpenWPM crawl scripts, Datasette, Selenium scripts
    # - python-pip: package installer
    # - git: for pulling OpenWPM repo when we need the example scripts
    # - curl wget: download tools for ProtonVPN and other assets
    # - jq: JSON processing for OpenWPM output analysis and API forensics
    # - net-tools iproute2: network interface tooling (ip, ss, etc.)
    # - sqlite: command-line SQLite for direct database queries
    # - tmux: multi-pane terminal for running all tools simultaneously
    # - htop: system resource monitor — watch for thermal throttling on the 7480

    PACKAGES=(
        docker
        docker-compose
        wireshark-qt
        python
        python-pip
        python-virtualenv
        git
        curl
        wget
        jq
        net-tools
        iproute2
        sqlite
        tmux
        htop
        bash-completion
    )

    log_step "Installing: ${PACKAGES[*]}"
    sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"
    log_success "System packages installed"

    # wireshark-qt pulls in tshark as a dependency.
    # Verify tshark is available:
    if ! command -v tshark &>/dev/null; then
        log_error "tshark not found after wireshark-qt install. Something went wrong."
        exit 1
    fi
    log_success "tshark confirmed available: $(tshark --version | head -1)"
}

# =============================================================================
# SECTION 2: DOCKER SETUP
# Install, enable, configure. This replaces VirtualBox entirely for this stack.
# On linux-hardened: extra kernel parameters may be needed (warned above).
# =============================================================================

setup_docker() {
    log_section "Setting Up Docker"

    # Enable and start Docker daemon
    log_step "Enabling Docker daemon (systemd)..."
    sudo systemctl enable --now docker

    # Verify Docker daemon is running
    if ! sudo systemctl is-active --quiet docker; then
        log_error "Docker daemon failed to start."
        log_error "Check: sudo journalctl -u docker -n 50"
        if echo "$(uname -r)" | grep -q "hardened"; then
            log_error "On linux-hardened: ensure kernel.unprivileged_userns_clone=1"
            log_error "Add to /etc/sysctl.d/99-docker.conf and run: sudo sysctl --system"
        fi
        exit 1
    fi
    log_success "Docker daemon running"

    # Add current user to docker group — avoids needing sudo for every docker command.
    # This change takes effect on next login (or after newgrp docker in this session).
    if ! groups "${USER}" | grep -q docker; then
        log_step "Adding ${USER} to docker group..."
        sudo usermod -aG docker "${USER}"
        log_warn "Group change requires re-login to take full effect."
        log_warn "For this session, we'll use 'newgrp docker' within the script where needed."
        log_warn "After script completes, log out and back in to use docker without sudo."
    else
        log_success "User ${USER} already in docker group"
    fi

    # Verify Docker works (use sudo to be safe before group refresh)
    log_step "Testing Docker with hello-world..."
    if sudo docker run --rm hello-world &>/dev/null; then
        log_success "Docker functional"
    else
        log_error "Docker test failed. Check daemon logs: sudo journalctl -u docker -n 100"
        exit 1
    fi

    # Configure Docker daemon for logging — default json-file driver with rotation
    # This prevents Docker container logs from eating all disk space during long crawls
    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
    if [ ! -f "${DOCKER_DAEMON_CONFIG}" ]; then
        log_step "Configuring Docker daemon log rotation..."
        # Arch's docker package does not ship /etc/docker, and the daemon does
        # not create it on first start — so `tee` here would fail on a clean
        # install, and under `set -e` that aborts the whole setup. Create the
        # parent directory first.
        sudo mkdir -p "$(dirname "${DOCKER_DAEMON_CONFIG}")"
        sudo tee "${DOCKER_DAEMON_CONFIG}" > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
        sudo systemctl restart docker
        log_success "Docker daemon configured with log rotation"
    else
        log_info "Docker daemon config already exists — not overwriting"
    fi
}

# =============================================================================
# SECTION 3: OPENWPM DOCKER IMAGE
# Pull the official OpenWPM container image.
# The project maintains an image at ghcr.io/openwpm/openwpm
# This is the correct approach on Arch — avoids fighting OpenWPM's Ubuntu
# assumptions against Arch's Python packaging.
# =============================================================================

setup_openwpm() {
    log_section "Setting Up OpenWPM (Docker)"

    log_step "Pulling OpenWPM Docker image: ${OPENWPM_IMAGE}"
    log_info "This image is ~3-4GB. First pull will take a while on slower connections."
    log_info "Subsequent runs will use the cached image."
    sudo docker pull "${OPENWPM_IMAGE}"
    log_success "OpenWPM image pulled"

    # Clone the OpenWPM repository for example scripts, demo crawlers,
    # and the Selenium-based interaction templates.
    # We clone into OBSERVATORY_ROOT/openwpm-repo
    OPENWPM_REPO_DIR="${OBSERVATORY_ROOT}/openwpm-repo"
    if [ ! -d "${OPENWPM_REPO_DIR}" ]; then
        log_step "Cloning OpenWPM repository (for scripts and examples)..."
        git clone https://github.com/openwpm/OpenWPM.git "${OPENWPM_REPO_DIR}"
        log_success "OpenWPM repository cloned to ${OPENWPM_REPO_DIR}"
    else
        log_info "OpenWPM repo already cloned — pulling latest..."
        git -C "${OPENWPM_REPO_DIR}" pull
        log_success "OpenWPM repository updated"
    fi

    # Verify the image contains OpenWPM by running a quick check
    log_step "Verifying OpenWPM container..."
    if sudo docker run --rm "${OPENWPM_IMAGE}" python -c "import openwpm; print('OpenWPM OK')" 2>/dev/null | grep -q "OpenWPM OK"; then
        log_success "OpenWPM Python module confirmed inside container"
    else
        log_warn "Could not verify OpenWPM module directly — image may use different entrypoint."
        log_warn "This is non-fatal; the crawl scripts will reveal any issues at runtime."
    fi
}

# =============================================================================
# SECTION 4: DIRECTORY STRUCTURE
# Create the Observatory workspace layout.
# Every investigation session will live in its own timestamped subdirectory.
# =============================================================================

create_directory_structure() {
    log_section "Creating Observatory Directory Structure"

    # The full layout:
    # observatory/
    # ├── captures/          → tshark PCAP files, one subdir per session
    # ├── crawls/            → OpenWPM output databases, one subdir per crawl
    # ├── screenshots/       → any screenshots taken during sessions
    # ├── logs/              → script and session logs
    # ├── scripts/           → our crawl scripts, Selenium scripts, analysis queries
    # │   ├── crawlers/      → OpenWPM crawl definitions
    # │   ├── selenium/      → Selenium interaction scripts for authenticated sessions
    # │   └── sql/           → useful SQL queries for OpenWPM database analysis
    # ├── openwpm-repo/      → the cloned OpenWPM repository
    # └── datasette/         → Datasette metadata and configuration

    DIRS=(
        "${OBSERVATORY_ROOT}/captures"
        "${OBSERVATORY_ROOT}/crawls"
        "${OBSERVATORY_ROOT}/screenshots"
        "${OBSERVATORY_ROOT}/logs"
        "${OBSERVATORY_ROOT}/scripts/crawlers"
        "${OBSERVATORY_ROOT}/scripts/selenium"
        "${OBSERVATORY_ROOT}/scripts/sql"
        "${OBSERVATORY_ROOT}/datasette"
    )

    for DIR in "${DIRS[@]}"; do
        mkdir -p "${DIR}"
        log_step "Created: ${DIR}"
    done

    log_success "Directory structure created under ${OBSERVATORY_ROOT}"
}

# =============================================================================
# SECTION 5: TSHARK PERMISSIONS
# tshark needs to capture on network interfaces without root.
# The wireshark group handles this — we add the user and configure dumpcap.
# =============================================================================

setup_tshark_permissions() {
    log_section "Configuring tshark / Wireshark Capture Permissions"

    # Arch's wireshark-qt package installs dumpcap with setuid capabilities
    # and creates a wireshark group. Adding our user to this group allows
    # tshark to capture without sudo — critical for running tshark in scripts.

    if ! groups "${USER}" | grep -q wireshark; then
        log_step "Adding ${USER} to wireshark group..."
        sudo usermod -aG wireshark "${USER}"
        log_warn "Group change effective on next login."
        log_warn "For this session, use 'sudo tshark' if capture fails without sudo."
    else
        log_success "User ${USER} already in wireshark group"
    fi

    # Set capabilities on dumpcap if not already set
    DUMPCAP_PATH=$(which dumpcap 2>/dev/null || echo "/usr/bin/dumpcap")
    if [ -f "${DUMPCAP_PATH}" ]; then
        log_step "Verifying dumpcap capabilities..."
        if getcap "${DUMPCAP_PATH}" | grep -q "cap_net_raw"; then
            log_success "dumpcap has cap_net_raw — non-root capture ready"
        else
            log_step "Setting dumpcap capabilities..."
            sudo setcap cap_net_raw,cap_net_admin+eip "${DUMPCAP_PATH}"
            log_success "dumpcap capabilities set"
        fi
    else
        log_warn "dumpcap not found at expected path — tshark may require sudo"
    fi

    # Verify available interfaces for capture
    log_step "Available network interfaces for capture:"
    tshark -D 2>/dev/null || sudo tshark -D 2>/dev/null || log_warn "Could not list interfaces — try after re-login"
}

# =============================================================================
# SECTION 6: PYTHON ENVIRONMENT + DATASETTE
# Datasette is pip-installable. We use a virtualenv to keep it clean.
# Selenium is also installed here for the authenticated-session scripts.
# =============================================================================

setup_python_environment() {
    log_section "Setting Up Python Environment (Datasette + Selenium)"

    VENV_DIR="${OBSERVATORY_ROOT}/.venv"

    if [ ! -d "${VENV_DIR}" ]; then
        log_step "Creating Python virtualenv at ${VENV_DIR}..."
        python -m venv "${VENV_DIR}"
        log_success "Virtualenv created"
    else
        log_info "Virtualenv already exists — reusing"
    fi

    # Activate virtualenv for the rest of this section
    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"

    log_step "Upgrading pip..."
    pip install --quiet --upgrade pip

    log_step "Installing Datasette..."
    # Datasette: the browser-UI for exploring OpenWPM's SQLite output.
    # Much more usable than DB Browser for the first-pass "what did OpenWPM find?"
    # review — filterable tables, instant search, no SQL required for basic use.
    pip install --quiet datasette

    log_step "Installing datasette-vega (visualization plugin)..."
    # datasette-vega adds charting to Datasette — visualize tracking call frequency,
    # third-party domain counts, cookie operation timelines without writing code.
    pip install --quiet datasette-vega

    log_step "Installing datasette-cluster-map (geo visualization plugin)..."
    # Maps IP addresses in OpenWPM's output — useful for visualizing where
    # tracking infrastructure is geographically concentrated.
    pip install --quiet datasette-cluster-map 2>/dev/null || log_warn "datasette-cluster-map skipped (optional)"

    log_step "Installing Selenium..."
    # Selenium is the automation driver for authenticated-session crawling —
    # the part of OpenWPM's optional layer that becomes non-optional when
    # investigation targets are behind login walls.
    pip install --quiet selenium

    log_step "Installing geckodriver-autoinstaller..."
    # Automatically downloads and installs the correct geckodriver version
    # for the installed Firefox. Saves the manual dance of matching versions.
    pip install --quiet geckodriver-autoinstaller

    log_step "Installing pandas + matplotlib (for offline analysis of OpenWPM output)..."
    # Pandas reads OpenWPM's SQLite tables directly via pd.read_sql()
    # Matplotlib generates charts for forensic reports
    pip install --quiet pandas matplotlib

    log_step "Installing requests + httpx (for manual API probing from analysis scripts)..."
    pip install --quiet requests httpx

    deactivate
    log_success "Python environment set up at ${VENV_DIR}"
}

# =============================================================================
# SECTION 7: PROTONVPN CLI
# ProtonVPN's Linux CLI is available via AUR on Arch.
# We use yay or paru if available; fall back to manual AUR clone if neither exists.
# =============================================================================

setup_protonvpn() {
    log_section "Setting Up ProtonVPN CLI"

    # Check if ProtonVPN is already installed
    if command -v protonvpn-cli &>/dev/null || command -v protonvpn &>/dev/null; then
        log_success "ProtonVPN CLI already installed"
        return 0
    fi

    # ProtonVPN provides an official Linux package. On Arch, the recommended
    # installation is via the AUR package 'protonvpn' or via their official
    # Debian/RPM packages (we'll use the official install script as fallback).

    # Check for AUR helpers
    if command -v yay &>/dev/null; then
        log_step "Installing protonvpn via yay (AUR)..."
        yay -S --needed --noconfirm protonvpn
    elif command -v paru &>/dev/null; then
        log_step "Installing protonvpn via paru (AUR)..."
        paru -S --needed --noconfirm protonvpn
    else
        log_warn "No AUR helper (yay/paru) found."
        log_warn "ProtonVPN will be installed via the official Python package."
        log_step "Installing protonvpn-cli via pip (official ProtonVPN package)..."

        # ProtonVPN publishes a Python CLI package
        # This is the cross-platform fallback that works on Arch without AUR
        source "${OBSERVATORY_ROOT}/.venv/bin/activate"
        pip install --quiet protonvpn-cli || {
            log_warn "pip install of protonvpn-cli failed."
            log_warn "Manual installation: https://protonvpn.com/support/linux-vpn-setup/"
            log_warn "Continuing script — VPN setup will need to be completed manually."
            deactivate
            return 0
        }
        deactivate
    fi

    log_success "ProtonVPN CLI installed"
    log_info "Next step: configure ProtonVPN with your account credentials."
    log_info "Run: protonvpn-cli login YOUR_PROTONVPN_USERNAME"
    log_info "Then: protonvpn-cli connect --fastest"
    log_info "For forensic use: protonvpn-cli connect --cc CH (Switzerland, zero-logs jurisdiction)"
    log_info ""
    log_info "IMPORTANT: Connect to ProtonVPN BEFORE starting any crawl session."
    log_info "Verify connection: curl https://api64.ipify.org (should show VPN IP, not your real IP)"
}

# =============================================================================
# SECTION 8: WRITE THE CRAWL SCRIPTS
# These are the actual forensic instruments — the scripts you run per session.
# =============================================================================

write_crawl_scripts() {
    log_section "Writing Crawl and Analysis Scripts"

    # ─────────────────────────────────────────────────────────────────
    # 8a: OPENWPM BASIC CRAWL SCRIPT
    # The fundamental forensic instrument. Run this against any site to get
    # a full behavioral trace: network requests, cookies, fingerprinting calls.
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/crawlers/basic_crawl.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
OBSERVATORY: OpenWPM Basic Crawl Script
========================================
Runs an instrumented Firefox browser against a list of URLs and records:
  - All HTTP/HTTPS requests and responses
  - Cookie operations (get, set, delete)
  - localStorage and sessionStorage operations
  - IndexedDB operations
  - Canvas API calls (fingerprinting detection)
  - WebGL calls (fingerprinting detection)
  - WebRTC calls (IP leak detection)
  - JavaScript cookie accesses

Output: SQLite database in the crawls/ directory.
Explore with: datasette crawls/YOUR_CRAWL.sqlite

Usage:
  python basic_crawl.py --sites "https://example.com" "https://example2.com"
  python basic_crawl.py --file sites.txt
  python basic_crawl.py --sites "https://example.com" --headless false  (see the browser)
"""

import argparse
import os
import sys
import sqlite3
from pathlib import Path
from datetime import datetime

# OpenWPM is run inside Docker, so this script generates the crawl configuration
# and then invokes the Docker container. This means you don't fight Arch vs Ubuntu.

OPENWPM_IMAGE = "ghcr.io/openwpm/openwpm:latest"
OBSERVATORY_ROOT = Path(__file__).parent.parent.parent
CRAWLS_DIR = OBSERVATORY_ROOT / "crawls"
LOGS_DIR = OBSERVATORY_ROOT / "logs"


def parse_args():
    parser = argparse.ArgumentParser(description="OpenWPM Observatory Crawl")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--sites",
        nargs="+",
        help="One or more URLs to crawl (space-separated)"
    )
    group.add_argument(
        "--file",
        type=str,
        help="Path to a text file with one URL per line"
    )
    parser.add_argument(
        "--headless",
        type=str,
        default="true",
        choices=["true", "false"],
        help="Run Firefox headless (default: true). Use false to watch the browser."
    )
    parser.add_argument(
        "--name",
        type=str,
        default=None,
        help="Name for this crawl session (default: timestamp)"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Seconds to spend on each page (default: 60)"
    )
    return parser.parse_args()


def load_sites(args):
    if args.sites:
        return args.sites
    with open(args.file, "r") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]


def build_crawl_name(args):
    if args.name:
        return args.name
    return f"crawl_{datetime.now().strftime('%Y%m%d_%H%M%S')}"


def write_openwpm_script(sites, crawl_dir, headless, timeout):
    """
    Write the OpenWPM Python script that will run INSIDE the Docker container.
    This script uses OpenWPM's native API — no subprocess games inside the container.
    """
    sites_repr = repr(sites)
    headless_bool = "True" if headless == "true" else "False"

    script = f'''#!/usr/bin/env python3
"""Auto-generated OpenWPM crawl script — runs inside Docker container."""

from openwpm.command_sequence import CommandSequence
from openwpm.commands.browser_commands import GetCommand
from openwpm.config import BrowserParams, ManagerParams
from openwpm.storage.sql_provider import SQLiteStorageProvider
from openwpm.task_manager import TaskManager
from pathlib import Path
import logging

logging.basicConfig(level=logging.INFO)

SITES = {sites_repr}
DATA_DIR = Path("/crawl_output")
DATA_DIR.mkdir(parents=True, exist_ok=True)

# ManagerParams: controls the overall crawl manager
manager_params = ManagerParams(num_browsers=1)
manager_params.data_directory = DATA_DIR
manager_params.log_path = DATA_DIR / "openwpm.log"

# BrowserParams: controls each instrumented Firefox instance
browser_params = [BrowserParams(display_mode="headless" if {headless_bool} else "xvfb")]
browser_params[0].http_instrument = True           # Capture all HTTP requests/responses
browser_params[0].cookie_instrument = True         # Capture all cookie operations
browser_params[0].navigation_instrument = True     # Capture navigation events
browser_params[0].js_instrument = True             # Capture JavaScript API calls
browser_params[0].callstack_instrument = True      # Record JS call stacks for each API call
browser_params[0].dns_instrument = True            # Capture DNS resolutions
browser_params[0].save_content = "script,sub_frame"  # Save JS source and iframe content

# js_instrument_settings: specify WHICH JavaScript APIs to monitor
# This is where canvas, WebGL, WebRTC, AudioContext fingerprinting is captured
browser_params[0].js_instrument_settings = [
    # Canvas API — the primary fingerprinting surface
    {{"object": "HTMLCanvasElement",
      "instrumentedName": "HTMLCanvasElement",
      "logSettings": {{"propertiesToInstrument": ["toDataURL", "toBlob"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # CanvasRenderingContext2D — the drawing API (fingerprinters use fillText + measure)
    {{"object": "CanvasRenderingContext2D",
      "instrumentedName": "CanvasRenderingContext2D",
      "logSettings": {{"propertiesToInstrument": ["getImageData", "measureText"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # WebGL — GPU fingerprinting (UNMASKED_RENDERER_WEBGL is the key parameter)
    {{"object": "WebGLRenderingContext",
      "instrumentedName": "WebGLRenderingContext",
      "logSettings": {{"propertiesToInstrument": ["getParameter", "getSupportedExtensions"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # Navigator API — plugins, languages, hardwareConcurrency, deviceMemory
    {{"object": "Navigator",
      "instrumentedName": "Navigator",
      "logSettings": {{"propertiesToInstrument": [
                           "plugins", "languages", "hardwareConcurrency",
                           "deviceMemory", "maxTouchPoints", "userAgent",
                           "platform", "doNotTrack"
                       ],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # AudioContext — audio fingerprinting (oscillator processing differences)
    {{"object": "AudioContext",
      "instrumentedName": "AudioContext",
      "logSettings": {{"propertiesToInstrument": ["createOscillator", "createAnalyser",
                                                    "createDynamicsCompressor", "createBuffer",
                                                    "createBufferSource"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # RTCPeerConnection — WebRTC IP leak detection
    {{"object": "RTCPeerConnection",
      "instrumentedName": "RTCPeerConnection",
      "logSettings": {{"propertiesToInstrument": ["createDataChannel", "createOffer",
                                                    "setLocalDescription"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
    # Screen API — screen resolution fingerprinting
    {{"object": "Screen",
      "instrumentedName": "Screen",
      "logSettings": {{"propertiesToInstrument": ["width", "height", "colorDepth",
                                                    "pixelDepth", "availWidth", "availHeight"],
                       "nonExistingPropertiesToInstrument": [],
                       "excludedProperties": [],
                       "logCallStack": True,
                       "preventSets": False,
                       "recursive": False,
                       "depth": 5}}}},
]

with TaskManager(
    manager_params=manager_params,
    browser_params=browser_params,
    storage_provider=SQLiteStorageProvider(DATA_DIR / "crawl.sqlite"),
    logger_kwargs={{}},
) as manager:
    for i, site in enumerate(SITES):
        print(f"[{{i+1}}/{{len(SITES)}}] Crawling: {{site}}")
        command_sequence = CommandSequence(
            site,
            site_rank=i,
            reset=True,      # Fresh browser state for each site
            timeout={timeout},
        )
        command_sequence.get(sleep=5, timeout={timeout})
        # sleep=5: wait 5 seconds after page load for JS to execute
        # This is important: fingerprinting scripts often run on a timer

        manager.execute_command_sequence(command_sequence)

print("Crawl complete. Output: /crawl_output/crawl.sqlite")
print("Tables: http_requests, http_responses, javascript_cookies,")
print("        localstorage, javascript (API call log), site_visits")
'''
    return script


def run_docker_crawl(sites, crawl_name, crawl_dir, headless, timeout):
    """Launch the OpenWPM Docker container with the crawl configuration."""
    import subprocess

    # Write the inner crawl script to the crawl directory
    inner_script = write_openwpm_script(sites, crawl_dir, headless, timeout)
    inner_script_path = crawl_dir / "inner_crawl.py"
    inner_script_path.write_text(inner_script)

    # Write sites list to file for reference
    sites_file = crawl_dir / "sites.txt"
    sites_file.write_text("\n".join(sites))

    print(f"\n→ Launching Docker container for crawl: {crawl_name}")
    print(f"→ Sites: {len(sites)}")
    print(f"→ Output: {crawl_dir}")
    print(f"→ Headless: {headless}")
    print("")

    # Docker run command:
    # --rm: remove container after exit (disposable, no state accumulates)
    # -v: mount the crawl directory as /crawl_output inside the container
    # -v: also mount the inner script so the container can run it
    # --network host: use the host network (which should be routed through ProtonVPN)
    #                 This is the key setting that makes VPN routing apply to crawls
    # --shm-size 2g: Firefox needs shared memory; containers default to 64MB which causes crashes
    cmd = [
        "docker", "run", "--rm",
        "--network", "host",          # Inherits host VPN routing — critical for privacy
        "--shm-size", "2g",           # Firefox crashes without adequate shared memory
        "-v", f"{crawl_dir}:/crawl_output",
        "-v", f"{inner_script_path}:/crawl_script.py:ro",
        OPENWPM_IMAGE,
        "python", "/crawl_script.py"
    ]

    print(f"Docker command: {' '.join(cmd)}\n")

    try:
        result = subprocess.run(cmd, check=True)
        print(f"\n✓ Crawl complete: {crawl_dir / 'crawl.sqlite'}")
        return crawl_dir / "crawl.sqlite"
    except subprocess.CalledProcessError as e:
        print(f"\n✗ Crawl failed with exit code {e.returncode}")
        print("Check Docker logs and verify:")
        print("  1. ProtonVPN is connected (protonvpn-cli status)")
        print("  2. Docker image is current (docker pull ghcr.io/openwpm/openwpm:latest)")
        print("  3. Sufficient disk space (df -h)")
        raise


def main():
    args = parse_args()
    sites = load_sites(args)
    crawl_name = build_crawl_name(args)
    crawl_dir = CRAWLS_DIR / crawl_name
    crawl_dir.mkdir(parents=True, exist_ok=True)

    print(f"Observatory Crawl: {crawl_name}")
    print(f"Sites to crawl: {len(sites)}")
    for s in sites:
        print(f"  {s}")
    print("")

    db_path = run_docker_crawl(sites, crawl_name, crawl_dir, args.headless, args.timeout)
    print(f"\nTo explore the output:")
    print(f"  source {OBSERVATORY_ROOT}/.venv/bin/activate")
    print(f"  datasette {db_path} --port 8001")
    print(f"  Open: http://localhost:8001")


if __name__ == "__main__":
    main()
PYTHON_SCRIPT

    chmod +x "${OBSERVATORY_ROOT}/scripts/crawlers/basic_crawl.py"
    log_success "Basic crawl script written"

    # ─────────────────────────────────────────────────────────────────
    # 8b: SELENIUM AUTHENTICATED SESSION SCRIPT
    # For when the investigation target is behind a login wall.
    # This is where Package 3's "optional" Selenium layer becomes mandatory.
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/selenium/authenticated_session.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
OBSERVATORY: Selenium Authenticated Session Template
======================================================
Use this when the investigation target requires login.
OpenWPM's basic crawl stops at the login wall.
This script:
  1. Opens an instrumented Firefox browser
  2. Lets you log in manually (or automates login if you provide credentials)
  3. Navigates through post-login pages you specify
  4. Captures all network traffic during the authenticated session via tshark
  5. Saves cookies, localStorage, and session state for analysis

IMPORTANT ETHICAL NOTE:
Only use authenticated session analysis on accounts you own.
Do not use this to access other users' sessions or systems you don't control.

Usage:
  python authenticated_session.py --target "https://example.com/dashboard"
  python authenticated_session.py --target "https://example.com" --auto-login --username USER --password PASS
"""

import argparse
import json
import subprocess
import time
import os
from datetime import datetime
from pathlib import Path

try:
    from selenium import webdriver
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.firefox.service import Service
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    import geckodriver_autoinstaller
except ImportError:
    print("ERROR: Selenium not installed in current environment.")
    print("Run: source observatory/.venv/bin/activate")
    exit(1)

OBSERVATORY_ROOT = Path(__file__).parent.parent.parent
CRAWLS_DIR = OBSERVATORY_ROOT / "crawls"
CAPTURES_DIR = OBSERVATORY_ROOT / "captures"
LOGS_DIR = OBSERVATORY_ROOT / "logs"


def parse_args():
    parser = argparse.ArgumentParser(description="Authenticated Session Forensics")
    parser.add_argument("--target", required=True, help="Starting URL for investigation")
    parser.add_argument("--navigate", nargs="*", default=[],
                        help="Additional URLs to visit after login")
    parser.add_argument("--auto-login", action="store_true",
                        help="Attempt automated login (requires --username and --password)")
    parser.add_argument("--username", type=str, default=None)
    parser.add_argument("--password", type=str, default=None)
    parser.add_argument("--login-url", type=str, default=None,
                        help="Login page URL if different from target")
    parser.add_argument("--session-name", type=str, default=None)
    parser.add_argument("--capture-interface", type=str, default="eth0",
                        help="Network interface for tshark capture")
    parser.add_argument("--dwell-time", type=int, default=30,
                        help="Seconds to spend on each page (default: 30)")
    return parser.parse_args()


def start_tshark_capture(session_dir, interface):
    """Start tshark in background for parallel packet capture."""
    pcap_path = session_dir / "session_capture.pcap"
    log_path = session_dir / "tshark.log"

    cmd = [
        "tshark",
        "-i", interface,
        "-w", str(pcap_path),
        # Capture filter: only capture traffic relevant to web browsing
        # Adjust ports if the target uses non-standard ports
        "-f", "tcp port 80 or tcp port 443 or udp port 53",
        "--ring-buffer", "files:5,filesize:50000",  # Rotate at 50MB, keep 5 files max
    ]

    print(f"Starting tshark capture on {interface} → {pcap_path}")
    proc = subprocess.Popen(
        cmd,
        stdout=open(log_path, "w"),
        stderr=subprocess.STDOUT
    )
    print(f"tshark PID: {proc.pid}")
    return proc, pcap_path


def stop_tshark_capture(proc):
    """Stop tshark gracefully."""
    if proc and proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=10)
        print("tshark capture stopped")


def setup_browser():
    """Configure Firefox for forensic browsing with instrumentation."""
    geckodriver_autoinstaller.install()

    options = Options()
    # NOT headless — for authenticated sessions, you need to interact with the browser
    # or at minimum observe what's happening visually
    options.headless = False

    # Forensic-friendly Firefox profile settings
    options.set_preference("privacy.trackingprotection.enabled", False)
    # Disable tracking protection — we WANT to observe all tracking,
    # not have Firefox silently block it before we can log it

    options.set_preference("network.cookie.cookieBehavior", 0)
    # Accept all cookies — again, we're observing, not blocking

    options.set_preference("dom.webdriver.enabled", False)
    # Try to hide the WebDriver flag — some sites serve different content
    # to detected automation. This isn't foolproof but helps.

    options.set_preference("useAutomationExtension", False)

    driver = webdriver.Firefox(options=options)
    driver.set_window_size(1920, 1080)
    return driver


def capture_page_state(driver, session_dir, page_name):
    """Capture the full forensic state of the current page."""
    state_dir = session_dir / "page_states" / page_name.replace("/", "_").replace(":", "")
    state_dir.mkdir(parents=True, exist_ok=True)

    # Screenshot
    driver.save_screenshot(str(state_dir / "screenshot.png"))

    # Current URL (may differ from requested URL after redirects)
    state = {
        "url": driver.current_url,
        "title": driver.title,
        "timestamp": datetime.now().isoformat(),
    }

    # Cookies
    state["cookies"] = driver.get_cookies()

    # localStorage
    try:
        local_storage = driver.execute_script("""
            let items = {};
            for (let i = 0; i < localStorage.length; i++) {
                let key = localStorage.key(i);
                items[key] = localStorage.getItem(key);
            }
            return items;
        """)
        state["localStorage"] = local_storage
    except Exception as e:
        state["localStorage"] = {"error": str(e)}

    # sessionStorage
    try:
        session_storage = driver.execute_script("""
            let items = {};
            for (let i = 0; i < sessionStorage.length; i++) {
                let key = sessionStorage.key(i);
                items[key] = sessionStorage.getItem(key);
            }
            return items;
        """)
        state["sessionStorage"] = session_storage
    except Exception as e:
        state["sessionStorage"] = {"error": str(e)}

    # All script tags (source URLs of loaded scripts)
    try:
        scripts = driver.execute_script("""
            return Array.from(document.querySelectorAll('script[src]'))
                        .map(s => s.src);
        """)
        state["loaded_scripts"] = scripts
    except Exception as e:
        state["loaded_scripts"] = {"error": str(e)}

    # Third-party iframes
    try:
        iframes = driver.execute_script("""
            return Array.from(document.querySelectorAll('iframe[src]'))
                        .map(f => ({ src: f.src, width: f.width, height: f.height }));
        """)
        state["iframes"] = iframes
    except Exception as e:
        state["iframes"] = {"error": str(e)}

    # Save state to JSON
    state_file = state_dir / "page_state.json"
    state_file.write_text(json.dumps(state, indent=2, default=str))
    print(f"  ✓ State captured: {state_dir.name}")
    return state


def main():
    args = parse_args()

    session_name = args.session_name or f"session_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    session_dir = CRAWLS_DIR / session_name
    session_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nAuthenticated Session Forensics: {session_name}")
    print(f"Target: {args.target}")
    print(f"Output: {session_dir}\n")

    # Verify ProtonVPN connection before starting
    print("Verifying VPN connection...")
    try:
        result = subprocess.run(
            ["curl", "-s", "--max-time", "5", "https://api64.ipify.org"],
            capture_output=True, text=True
        )
        current_ip = result.stdout.strip()
        print(f"Current public IP: {current_ip}")
        print("If this is your real IP (not VPN), connect ProtonVPN before proceeding!")
        time.sleep(3)
    except Exception:
        print("Could not determine public IP — ensure network connectivity")

    # Start tshark capture
    tshark_proc, pcap_path = start_tshark_capture(session_dir, args.capture_interface)
    time.sleep(2)  # Give tshark a moment to initialize before browser traffic starts

    driver = None
    all_states = []

    try:
        driver = setup_browser()
        wait = WebDriverWait(driver, 30)

        # Navigate to target
        login_url = args.login_url or args.target
        print(f"\nNavigating to: {login_url}")
        driver.get(login_url)
        time.sleep(args.dwell_time // 2)
        state = capture_page_state(driver, session_dir, "01_initial")
        all_states.append(state)

        # Login handling
        if args.auto_login and args.username and args.password:
            print("Attempting automated login...")
            # Generic login attempt — may need customization per site
            # This tries common field selectors; adjust for specific sites
            try:
                username_selectors = [
                    (By.NAME, "username"), (By.NAME, "email"), (By.NAME, "user"),
                    (By.ID, "username"), (By.ID, "email"), (By.ID, "user-email"),
                    (By.CSS_SELECTOR, "input[type='email']"),
                    (By.CSS_SELECTOR, "input[autocomplete='username']"),
                ]
                password_selectors = [
                    (By.NAME, "password"), (By.ID, "password"),
                    (By.CSS_SELECTOR, "input[type='password']"),
                    (By.CSS_SELECTOR, "input[autocomplete='current-password']"),
                ]

                username_field = None
                for selector in username_selectors:
                    try:
                        username_field = driver.find_element(*selector)
                        break
                    except Exception:
                        continue

                if username_field:
                    username_field.clear()
                    username_field.send_keys(args.username)

                    password_field = None
                    for selector in password_selectors:
                        try:
                            password_field = driver.find_element(*selector)
                            break
                        except Exception:
                            continue

                    if password_field:
                        password_field.send_keys(args.password)

                        # Find and click submit button
                        submit_selectors = [
                            (By.CSS_SELECTOR, "button[type='submit']"),
                            (By.CSS_SELECTOR, "input[type='submit']"),
                            (By.XPATH, "//button[contains(text(),'Log in')]"),
                            (By.XPATH, "//button[contains(text(),'Sign in')]"),
                        ]
                        for selector in submit_selectors:
                            try:
                                submit_btn = driver.find_element(*selector)
                                submit_btn.click()
                                break
                            except Exception:
                                continue

                        time.sleep(5)
                        state = capture_page_state(driver, session_dir, "02_post_login")
                        all_states.append(state)
                        print(f"Post-login URL: {driver.current_url}")
                    else:
                        print("Could not find password field — manual login required")
                else:
                    print("Could not find username field — manual login required")

            except Exception as e:
                print(f"Auto-login failed: {e}")
                print("Proceeding with manual login — please log in via the browser")
        else:
            print("\nManual login mode.")
            print("Please log in via the browser window.")
            print("Press Enter here when logged in and ready to continue...")
            input()
            state = capture_page_state(driver, session_dir, "02_post_login_manual")
            all_states.append(state)

        # Navigate through additional pages
        if args.navigate:
            for i, url in enumerate(args.navigate, start=3):
                print(f"\nNavigating to additional page: {url}")
                driver.get(url)
                time.sleep(args.dwell_time)
                state = capture_page_state(driver, session_dir, f"{i:02d}_{url.split('/')[-1] or 'page'}")
                all_states.append(state)

        print("\nSession navigation complete.")
        print("Press Enter to close browser and stop capture...")
        input()

    finally:
        # Save session summary
        summary = {
            "session_name": session_name,
            "target": args.target,
            "pages_visited": len(all_states),
            "pcap_file": str(pcap_path),
            "states": all_states,
            "completed_at": datetime.now().isoformat(),
        }
        summary_file = session_dir / "session_summary.json"
        summary_file.write_text(json.dumps(summary, indent=2, default=str))

        if driver:
            driver.quit()
        stop_tshark_capture(tshark_proc)

    print(f"\nSession complete. Files in: {session_dir}")
    print(f"PCAP: {pcap_path}")
    print(f"Open PCAP in Wireshark: wireshark {pcap_path}")
    print(f"Page states: {session_dir}/page_states/*/page_state.json")
    print(f"Summary: {summary_file}")


if __name__ == "__main__":
    main()
PYTHON_SCRIPT

    chmod +x "${OBSERVATORY_ROOT}/scripts/selenium/authenticated_session.py"
    log_success "Authenticated session script written"

    # ─────────────────────────────────────────────────────────────────
    # 8c: TSHARK CAPTURE LAUNCHER
    # Standalone tshark launcher for passive background capture.
    # Run this before ANY browsing session for ground-truth packet recording.
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/start_capture.sh" << 'BASH_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# OBSERVATORY: tshark Capture Launcher
# Starts a passive packet capture session in the background.
# Run this BEFORE opening any browser or starting any crawl.
# =============================================================================

OBSERVATORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURES_DIR="${OBSERVATORY_ROOT}/captures"
INTERFACE="${1:-eth0}"
SESSION_NAME="${2:-capture_$(date +%Y%m%d_%H%M%S)}"
SESSION_DIR="${CAPTURES_DIR}/${SESSION_NAME}"
PID_FILE="${SESSION_DIR}/tshark.pid"

mkdir -p "${SESSION_DIR}"

echo "Starting tshark capture:"
echo "  Interface: ${INTERFACE}"
echo "  Output:    ${SESSION_DIR}"
echo "  Use 'stop_capture.sh ${SESSION_NAME}' to stop"
echo ""

# Start tshark in background with rotating files
# -b filesize:102400  → rotate every 100MB
# -b files:10         → keep 10 files maximum (1GB total retention)
# -n                  → don't resolve hostnames (faster, forensically cleaner)
# -q                  → quiet mode (less terminal noise)
tshark \
    -i "${INTERFACE}" \
    -w "${SESSION_DIR}/capture.pcap" \
    -b filesize:102400 \
    -b files:10 \
    -n \
    -q &

TSHARK_PID=$!
echo "${TSHARK_PID}" > "${PID_FILE}"
echo "tshark started with PID ${TSHARK_PID}"
echo "PID saved to: ${PID_FILE}"
echo ""
echo "Verify capture is running:"
echo "  ls -la ${SESSION_DIR}/"
echo ""
echo "View live capture stats:"
echo "  kill -USR1 ${TSHARK_PID}   (sends statistics to tshark stdout)"
BASH_SCRIPT

    # ─────────────────────────────────────────────────────────────────
    # 8d: TSHARK CAPTURE STOPPER
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/stop_capture.sh" << 'BASH_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# OBSERVATORY: tshark Capture Stopper
# Gracefully stops a running tshark capture session.
# =============================================================================

OBSERVATORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURES_DIR="${OBSERVATORY_ROOT}/captures"
SESSION_NAME="${1:-}"

if [ -z "${SESSION_NAME}" ]; then
    echo "Usage: stop_capture.sh SESSION_NAME"
    echo ""
    echo "Active captures:"
    ls "${CAPTURES_DIR}/" 2>/dev/null | head -20
    exit 1
fi

PID_FILE="${CAPTURES_DIR}/${SESSION_NAME}/tshark.pid"

if [ ! -f "${PID_FILE}" ]; then
    echo "No PID file found for session: ${SESSION_NAME}"
    echo "tshark may have already stopped, or session name is wrong"
    exit 1
fi

TSHARK_PID=$(cat "${PID_FILE}")
echo "Stopping tshark PID ${TSHARK_PID}..."

if kill -TERM "${TSHARK_PID}" 2>/dev/null; then
    sleep 2
    echo "tshark stopped"
    rm "${PID_FILE}"
else
    echo "Process ${TSHARK_PID} not running (already stopped?)"
fi

SESSION_DIR="${CAPTURES_DIR}/${SESSION_NAME}"
echo ""
echo "Capture files in ${SESSION_DIR}:"
ls -lh "${SESSION_DIR}/"*.pcap 2>/dev/null || echo "No PCAP files found"
echo ""
echo "Open in Wireshark: wireshark ${SESSION_DIR}/capture.pcap"
echo "Analyze with tshark:"
echo "  tshark -r ${SESSION_DIR}/capture.pcap -Y 'http or tls' -T fields -e ip.dst -e http.request.uri | sort -u"
BASH_SCRIPT

    chmod +x "${OBSERVATORY_ROOT}/scripts/start_capture.sh"
    chmod +x "${OBSERVATORY_ROOT}/scripts/stop_capture.sh"
    log_success "tshark launcher scripts written"

    # ─────────────────────────────────────────────────────────────────
    # 8e: DATASETTE LAUNCHER
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/launch_datasette.sh" << 'BASH_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# OBSERVATORY: Datasette Launcher
# Opens a browser-based UI for exploring any OpenWPM SQLite database.
# =============================================================================

OBSERVATORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${OBSERVATORY_ROOT}/.venv"
CRAWLS_DIR="${OBSERVATORY_ROOT}/crawls"
PORT="${DATASETTE_PORT:-8001}"

# Find SQLite databases to serve
DB_PATHS=()
while IFS= read -r -d '' db; do
    DB_PATHS+=("$db")
done < <(find "${CRAWLS_DIR}" -name "*.sqlite" -print0 2>/dev/null)

if [ ${#DB_PATHS[@]} -eq 0 ]; then
    echo "No SQLite databases found in ${CRAWLS_DIR}/"
    echo "Run a crawl first: python scripts/crawlers/basic_crawl.py --sites https://example.com"
    exit 1
fi

echo "Datasette Observatory"
echo "Serving ${#DB_PATHS[@]} database(s):"
for db in "${DB_PATHS[@]}"; do
    echo "  ${db}"
done
echo ""
echo "Opening at: http://localhost:${PORT}"
echo "Press Ctrl+C to stop"
echo ""

source "${VENV}/bin/activate"

# Serve all found databases simultaneously
datasette serve "${DB_PATHS[@]}" \
    --port "${PORT}" \
    --setting max_returned_rows 10000 \
    --setting sql_time_limit_ms 30000 \
    --setting allow_download 1 \
    --metadata "${OBSERVATORY_ROOT}/datasette/metadata.json" 2>/dev/null \
    || datasette serve "${DB_PATHS[@]}" \
        --port "${PORT}" \
        --setting max_returned_rows 10000
BASH_SCRIPT

    chmod +x "${OBSERVATORY_ROOT}/scripts/launch_datasette.sh"
    log_success "Datasette launcher written"

    # ─────────────────────────────────────────────────────────────────
    # 8f: DATASETTE METADATA
    # Configures Datasette with human-readable descriptions of OpenWPM's tables
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/datasette/metadata.json" << 'JSON'
{
  "title": "Observatory — Web Forensics Evidence Corpus",
  "description": "OpenWPM crawl output database explorer. Each database represents one investigation session.",
  "databases": {
    "crawl": {
      "description": "OpenWPM crawl results",
      "tables": {
        "http_requests": {
          "description": "Every HTTP request made by the instrumented browser during the crawl. Key columns: top_level_url (the page being visited), url (the request URL), method, referrer, headers. Filter by top_level_url to see all requests made from a specific page."
        },
        "http_responses": {
          "description": "HTTP responses received. Join with http_requests on request_id to link requests to responses. content_hash lets you identify identical response bodies across different requests."
        },
        "javascript_cookies": {
          "description": "Cookie operations performed by JavaScript (document.cookie reads and writes). This captures JS-accessible cookies only — HttpOnly cookies are NOT here (those appear only in http_requests headers)."
        },
        "javascript": {
          "description": "JavaScript API call log — the core fingerprinting detection table. Each row is one call to an instrumented API. symbol column identifies which API was called (e.g. CanvasRenderingContext2D.toDataURL, Navigator.plugins). arguments column shows what parameters were passed. call_stack shows which script made the call."
        },
        "localstorage": {
          "description": "localStorage read and write operations. key and value columns show what was stored. Tracker-set localStorage entries often contain persistent identifiers that survive cookie deletion."
        },
        "site_visits": {
          "description": "One row per crawled URL, with timing information. Join with other tables on visit_id to scope analysis to a specific site visit."
        },
        "dns_responses": {
          "description": "DNS resolutions performed during the crawl. Shows which domains were resolved and to which IP addresses — useful for mapping tracker infrastructure and identifying CDN providers."
        }
      }
    }
  }
}
JSON

    log_success "Datasette metadata written"

    # ─────────────────────────────────────────────────────────────────
    # 8g: SQL ANALYSIS QUERIES
    # Pre-written SQL for common forensic questions against OpenWPM output
    # ─────────────────────────────────────────────────────────────────
    cat > "${OBSERVATORY_ROOT}/scripts/sql/find_fingerprinting.sql" << 'SQL'
-- ============================================================
-- FINGERPRINTING DETECTION QUERIES
-- Run against the 'javascript' table in OpenWPM output
-- In Datasette: paste into the SQL editor at /crawl?sql=...
-- Via CLI: sqlite3 crawl.sqlite < find_fingerprinting.sql
-- ============================================================

-- All canvas fingerprinting calls
SELECT
    j.visit_id,
    sv.site_url,
    j.script_url,
    j.symbol,
    j.operation,
    j.value,
    j.time_stamp
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
WHERE j.symbol LIKE '%Canvas%'
   OR j.symbol LIKE '%toDataURL%'
   OR j.symbol LIKE '%getImageData%'
ORDER BY j.time_stamp;

-- WebGL GPU fingerprinting (UNMASKED_RENDERER_WEBGL = parameter 37446)
SELECT
    j.visit_id,
    sv.site_url,
    j.script_url,
    j.symbol,
    j.arguments,
    j.value,
    j.time_stamp
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
WHERE j.symbol LIKE '%WebGL%'
   AND (j.arguments LIKE '%37446%' OR j.arguments LIKE '%37445%')
ORDER BY j.time_stamp;

-- AudioContext fingerprinting
SELECT
    j.visit_id,
    sv.site_url,
    j.script_url,
    j.symbol,
    j.time_stamp
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
WHERE j.symbol LIKE '%AudioContext%'
   OR j.symbol LIKE '%createOscillator%'
   OR j.symbol LIKE '%createDynamicsCompressor%'
ORDER BY j.time_stamp;

-- Navigator API fingerprinting (environment probing)
SELECT
    j.visit_id,
    sv.site_url,
    j.script_url,
    j.symbol,
    j.value,
    j.time_stamp
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
WHERE j.symbol LIKE 'Navigator.%'
ORDER BY j.script_url, j.symbol;

-- RTCPeerConnection calls (WebRTC IP leak attempts)
SELECT
    j.visit_id,
    sv.site_url,
    j.script_url,
    j.symbol,
    j.arguments,
    j.time_stamp
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
WHERE j.symbol LIKE '%RTCPeerConnection%'
ORDER BY j.time_stamp;

-- Summary: count fingerprinting API calls per site
SELECT
    sv.site_url,
    COUNT(CASE WHEN j.symbol LIKE '%Canvas%' OR j.symbol LIKE '%toDataURL%' THEN 1 END) AS canvas_calls,
    COUNT(CASE WHEN j.symbol LIKE '%WebGL%' THEN 1 END) AS webgl_calls,
    COUNT(CASE WHEN j.symbol LIKE '%AudioContext%' THEN 1 END) AS audio_calls,
    COUNT(CASE WHEN j.symbol LIKE 'Navigator.%' THEN 1 END) AS navigator_calls,
    COUNT(CASE WHEN j.symbol LIKE '%RTCPeerConnection%' THEN 1 END) AS webrtc_calls,
    COUNT(*) AS total_instrumented_calls
FROM javascript j
JOIN site_visits sv ON j.visit_id = sv.visit_id
GROUP BY sv.site_url
ORDER BY total_instrumented_calls DESC;
SQL

    cat > "${OBSERVATORY_ROOT}/scripts/sql/find_trackers.sql" << 'SQL'
-- ============================================================
-- THIRD-PARTY TRACKER IDENTIFICATION QUERIES
-- Run against the 'http_requests' table in OpenWPM output
-- ============================================================

-- All unique third-party domains contacted per site
-- (domains where the request domain differs from the top-level page domain)
SELECT
    sv.site_url,
    -- Extract domain from request URL
    REPLACE(REPLACE(REPLACE(r.url, 'https://', ''), 'http://', ''), SUBSTR(REPLACE(REPLACE(r.url, 'https://', ''), 'http://', ''), INSTR(REPLACE(REPLACE(r.url, 'https://', ''), 'http://', ''), '/'), 999), '') AS request_domain,
    COUNT(*) AS request_count
FROM http_requests r
JOIN site_visits sv ON r.visit_id = sv.visit_id
WHERE r.top_level_url != r.url
GROUP BY sv.site_url, request_domain
ORDER BY request_count DESC;

-- Find tracking pixels (tiny image responses < 500 bytes)
SELECT
    r.top_level_url,
    r.url,
    r.method,
    rsp.content_length,
    rsp.content_type
FROM http_requests r
JOIN http_responses rsp ON r.request_id = rsp.request_id
WHERE rsp.content_type LIKE '%image%'
  AND (rsp.content_length < 500 OR rsp.content_length IS NULL)
  AND r.top_level_url != r.url
ORDER BY rsp.content_length ASC;

-- Find POST requests to third-party domains (data exfiltration)
SELECT
    r.top_level_url,
    r.url,
    r.post_body,
    r.headers,
    r.time_stamp
FROM http_requests r
WHERE r.method = 'POST'
  AND r.top_level_url != r.url
ORDER BY r.time_stamp;

-- Cookie operations from third-party scripts
SELECT
    jc.top_level_url,
    jc.host,
    jc.name,
    jc.value,
    jc.is_http_only,
    jc.is_secure,
    jc.same_site,
    jc.expiry,
    jc.operation
FROM javascript_cookies jc
WHERE jc.host != REPLACE(REPLACE(jc.top_level_url, 'https://', ''), 'http://', '')
ORDER BY jc.expiry DESC;

-- Known tracker domains found in this crawl
-- Cross-references against common tracker patterns
SELECT
    r.url,
    r.top_level_url,
    CASE
        WHEN r.url LIKE '%google-analytics%' THEN 'Google Analytics'
        WHEN r.url LIKE '%googletagmanager%' THEN 'Google Tag Manager'
        WHEN r.url LIKE '%doubleclick%' THEN 'Google DoubleClick'
        WHEN r.url LIKE '%facebook.com/tr%' THEN 'Facebook Pixel'
        WHEN r.url LIKE '%connect.facebook%' THEN 'Facebook Connect'
        WHEN r.url LIKE '%bat.bing%' THEN 'Bing UET'
        WHEN r.url LIKE '%hotjar%' THEN 'Hotjar'
        WHEN r.url LIKE '%mixpanel%' THEN 'Mixpanel'
        WHEN r.url LIKE '%amplitude%' THEN 'Amplitude'
        WHEN r.url LIKE '%segment.io%' OR r.url LIKE '%segment.com%' THEN 'Segment'
        WHEN r.url LIKE '%fullstory%' THEN 'FullStory'
        WHEN r.url LIKE '%logrocket%' THEN 'LogRocket'
        WHEN r.url LIKE '%clarity.ms%' THEN 'Microsoft Clarity'
        WHEN r.url LIKE '%intercom%' THEN 'Intercom'
        WHEN r.url LIKE '%heap%' THEN 'Heap Analytics'
        ELSE 'Unknown'
    END AS tracker_name
FROM http_requests r
WHERE r.url LIKE '%google-analytics%'
   OR r.url LIKE '%googletagmanager%'
   OR r.url LIKE '%doubleclick%'
   OR r.url LIKE '%facebook.com/tr%'
   OR r.url LIKE '%connect.facebook%'
   OR r.url LIKE '%bat.bing%'
   OR r.url LIKE '%hotjar%'
   OR r.url LIKE '%mixpanel%'
   OR r.url LIKE '%amplitude%'
   OR r.url LIKE '%segment.io%'
   OR r.url LIKE '%segment.com%'
   OR r.url LIKE '%fullstory%'
   OR r.url LIKE '%logrocket%'
   OR r.url LIKE '%clarity.ms%'
   OR r.url LIKE '%intercom%'
   OR r.url LIKE '%heap%'
ORDER BY tracker_name, r.top_level_url;
SQL

    cat > "${OBSERVATORY_ROOT}/scripts/sql/session_analysis.sql" << 'SQL'
-- ============================================================
-- SESSION OVERVIEW QUERIES
-- Quick situational awareness when you open a new crawl database
-- ============================================================

-- What sites were crawled and when?
SELECT
    visit_id,
    site_url,
    start_time,
    end_time
FROM site_visits
ORDER BY start_time;

-- How many total requests per site?
SELECT
    sv.site_url,
    COUNT(*) AS total_requests,
    COUNT(DISTINCT REPLACE(REPLACE(r.url, 'https://', ''), 'http://', '')) AS unique_domains,
    SUM(CASE WHEN r.method = 'POST' THEN 1 ELSE 0 END) AS post_requests
FROM http_requests r
JOIN site_visits sv ON r.visit_id = sv.visit_id
GROUP BY sv.site_url
ORDER BY total_requests DESC;

-- localStorage entries written per site (persistent tracking identifiers)
SELECT
    sv.site_url,
    ls.key,
    ls.value,
    LENGTH(ls.value) AS value_length
FROM localstorage ls
JOIN site_visits sv ON ls.visit_id = sv.visit_id
ORDER BY sv.site_url, ls.key;

-- DNS resolutions (which new domains were looked up?)
SELECT
    sv.site_url,
    d.host,
    d.dns_resolved_ip
FROM dns_responses d
JOIN site_visits sv ON d.visit_id = sv.visit_id
ORDER BY sv.site_url, d.host;
SQL

    log_success "SQL analysis queries written"
}

# =============================================================================
# SECTION 9: TMUX SESSION TEMPLATE
# A tmux config that launches the full Observatory stack in one command.
# =============================================================================

write_tmux_template() {
    log_section "Writing tmux Session Template"

    cat > "${OBSERVATORY_ROOT}/scripts/observatory_tmux.sh" << 'BASH_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# OBSERVATORY: tmux Session Launcher
# Opens a fully configured tmux workspace with all Observatory tools ready.
#
# Layout:
# ┌─────────────────────┬─────────────────────┐
# │                     │                     │
# │   tshark capture    │   crawl / selenium  │
# │   (passive record)  │   (active tool)     │
# │                     │                     │
# ├─────────────────────┼─────────────────────┤
# │                     │                     │
# │   datasette UI      │   analysis / sql /  │
# │   (database view)   │   htop / logs       │
# │                     │                     │
# └─────────────────────┴─────────────────────┘
# =============================================================================

OBSERVATORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="observatory"
INTERFACE="${1:-eth0}"
SESSION_NAME="session_$(date +%Y%m%d_%H%M%S)"

# Kill existing session if running
tmux kill-session -t "${SESSION}" 2>/dev/null || true

# Create new session
tmux new-session -d -s "${SESSION}" -x 220 -y 50

# Window 0: Main Observatory workspace
tmux rename-window -t "${SESSION}:0" "observatory"

# Split into 4 panes
tmux split-window -h -t "${SESSION}:0"
tmux split-window -v -t "${SESSION}:0.0"
tmux split-window -v -t "${SESSION}:0.2"

# Pane 0 (top-left): tshark capture
tmux send-keys -t "${SESSION}:0.0" \
    "echo 'TSHARK CAPTURE PANE' && echo '' && echo 'Start capture:' && echo '  ${OBSERVATORY_ROOT}/scripts/start_capture.sh ${INTERFACE} ${SESSION_NAME}' && echo '' && echo 'Stop capture:' && echo '  ${OBSERVATORY_ROOT}/scripts/stop_capture.sh ${SESSION_NAME}'" Enter

# Pane 1 (bottom-left): Datasette
tmux send-keys -t "${SESSION}:0.1" \
    "echo 'DATASETTE PANE' && echo '' && echo 'Launch after running a crawl:' && echo '  ${OBSERVATORY_ROOT}/scripts/launch_datasette.sh' && echo '' && echo 'Access at: http://localhost:8001'" Enter

# Pane 2 (top-right): Crawl/Selenium runner
tmux send-keys -t "${SESSION}:0.2" \
    "cd ${OBSERVATORY_ROOT} && source .venv/bin/activate && echo 'CRAWL/SELENIUM PANE — venv activated' && echo '' && echo 'Run basic crawl:' && echo '  python scripts/crawlers/basic_crawl.py --sites https://example.com' && echo '' && echo 'Run authenticated session:' && echo '  python scripts/selenium/authenticated_session.py --target https://example.com'" Enter

# Pane 3 (bottom-right): Analysis / logs / htop
tmux send-keys -t "${SESSION}:0.3" \
    "cd ${OBSERVATORY_ROOT} && echo 'ANALYSIS PANE' && echo '' && echo 'SQL analysis:' && echo '  sqlite3 crawls/CRAWL_NAME/crawl.sqlite < scripts/sql/find_fingerprinting.sql' && echo '' && echo 'System monitor:' && echo '  htop'" Enter

# Select first pane
tmux select-pane -t "${SESSION}:0.0"

# Attach to session
echo "Observatory tmux session started: ${SESSION}"
echo "Attach with: tmux attach -t ${SESSION}"
tmux attach -t "${SESSION}"
BASH_SCRIPT

    chmod +x "${OBSERVATORY_ROOT}/scripts/observatory_tmux.sh"
    log_success "tmux session template written"
}

# =============================================================================
# SECTION 10: DOCKER COMPOSE FILE
# For running OpenWPM + Datasette together as a composed service.
# Useful when running longer automated crawls.
# =============================================================================

write_docker_compose() {
    log_section "Writing Docker Compose Configuration"

    cat > "${OBSERVATORY_ROOT}/docker-compose.yml" << 'YAML'
# =============================================================================
# OBSERVATORY: Docker Compose Configuration
# Orchestrates OpenWPM crawling and Datasette analysis together.
#
# Usage:
#   docker-compose run --rm openwpm python /scripts/basic_crawl.py --sites https://example.com
#   docker-compose up datasette   (start Datasette to browse crawl results)
# =============================================================================

version: '3.8'

services:

  # OpenWPM: the instrumented browser crawling engine
  openwpm:
    image: ghcr.io/openwpm/openwpm:latest
    network_mode: host         # Inherits host VPN routing (ProtonVPN must be connected on host)
    shm_size: '2gb'            # Firefox needs this; containers default to 64MB
    volumes:
      - ./crawls:/crawl_output         # OpenWPM writes SQLite databases here
      - ./scripts:/scripts:ro          # Mount our scripts read-only
      - ./screenshots:/screenshots     # Screenshot output
    environment:
      - DISPLAY=:99                    # Required for non-headless mode with Xvfb
    # Default command: drop to shell for manual script execution
    command: /bin/bash
    stdin_open: true
    tty: true

  # Datasette: browser-based SQLite explorer for OpenWPM output
  datasette:
    image: datasetteproject/datasette:latest
    network_mode: host
    volumes:
      - ./crawls:/crawls:ro            # Read-only access to all crawl databases
      - ./datasette:/datasette:ro      # Datasette metadata configuration
    command: >
      datasette serve /crawls
      --host 0.0.0.0
      --port 8001
      --setting max_returned_rows 10000
      --setting sql_time_limit_ms 30000
      --metadata /datasette/metadata.json
    # Access at: http://localhost:8001
    # Note: datasette/metadata.json is mounted for table descriptions

  # tshark: passive packet capture (run on host directly; container version has permission issues)
  # See scripts/start_capture.sh for the recommended capture approach

YAML

    log_success "Docker Compose configuration written"
}

# =============================================================================
# SECTION 11: INSTALL THE OPERATOR MANUAL
# The Quick Reference Card points operators at ~/observatory/MANUAL.md.
# Put the manual there so that reference resolves on a provisioned machine.
# =============================================================================

install_manual() {
    log_section "Installing Operator Manual"

    local src="${SCRIPT_DIR}/${MANUAL_SOURCE_NAME}"
    local dest="${OBSERVATORY_ROOT}/MANUAL.md"

    if [[ -f "${src}" ]]; then
        cp "${src}" "${dest}"
        log_success "Manual installed to ${dest}"
        log_step "All 15 sections, including the Quick Reference Card"
    else
        # Not fatal — the toolchain works without the manual. But the Quick
        # Reference Card references this path, so say plainly what's missing.
        log_warn "Manual not found next to this script — skipping"
        log_step "Expected: ${src}"
        log_step "Run the setup script from the repository checkout to install it,"
        log_step "or copy the manual to ${dest} yourself."
    fi
}

# =============================================================================
# SECTION 12: POST-INSTALL VERIFICATION
# Verify everything is working before calling the install complete.
# =============================================================================

verify_installation() {
    log_section "Verifying Installation"

    local ALL_OK=true

    # Docker
    if sudo docker info &>/dev/null; then
        log_success "Docker: running"
    else
        log_error "Docker: NOT running"
        ALL_OK=false
    fi

    # OpenWPM image
    if sudo docker image inspect "${OPENWPM_IMAGE}" &>/dev/null; then
        log_success "OpenWPM image: present"
    else
        log_error "OpenWPM image: NOT found"
        ALL_OK=false
    fi

    # tshark
    if command -v tshark &>/dev/null; then
        log_success "tshark: $(tshark --version | head -1)"
    else
        log_error "tshark: NOT found"
        ALL_OK=false
    fi

    # Python virtualenv + Datasette
    if "${OBSERVATORY_ROOT}/.venv/bin/datasette" --version &>/dev/null; then
        log_success "Datasette: $("${OBSERVATORY_ROOT}/.venv/bin/datasette" --version)"
    else
        log_error "Datasette: NOT found in virtualenv"
        ALL_OK=false
    fi

    # Selenium in virtualenv
    if "${OBSERVATORY_ROOT}/.venv/bin/python" -c "import selenium; print(selenium.__version__)" &>/dev/null; then
        log_success "Selenium: $("${OBSERVATORY_ROOT}/.venv/bin/python" -c "import selenium; print(selenium.__version__)")"
    else
        log_warn "Selenium: not verified (may still work)"
    fi

    # ProtonVPN
    if command -v protonvpn-cli &>/dev/null || command -v protonvpn &>/dev/null; then
        log_success "ProtonVPN CLI: found"
    else
        log_warn "ProtonVPN CLI: not found — install manually before running crawls"
    fi

    # Script files
    for script in \
        "${OBSERVATORY_ROOT}/scripts/crawlers/basic_crawl.py" \
        "${OBSERVATORY_ROOT}/scripts/selenium/authenticated_session.py" \
        "${OBSERVATORY_ROOT}/scripts/start_capture.sh" \
        "${OBSERVATORY_ROOT}/scripts/stop_capture.sh" \
        "${OBSERVATORY_ROOT}/scripts/launch_datasette.sh" \
        "${OBSERVATORY_ROOT}/scripts/observatory_tmux.sh"; do
        if [ -f "${script}" ]; then
            log_success "Script: ${script##*/}"
        else
            log_error "Script missing: ${script}"
            ALL_OK=false
        fi
    done

    echo ""
    if [ "${ALL_OK}" = true ]; then
        log_success "All components verified — Observatory is ready"
    else
        log_warn "Some components need attention — see errors above"
    fi
}

# =============================================================================
# SECTION 13: PRINT USAGE GUIDE
# The cheat sheet that lives with the project and gets printed at install end.
# =============================================================================

print_usage_guide() {
    log_section "Observatory Usage Guide"

    cat << 'GUIDE'

  ╔══════════════════════════════════════════════════════════════╗
  ║           OBSERVATORY — QUICK REFERENCE                      ║
  ╚══════════════════════════════════════════════════════════════╝

  BEFORE ANY SESSION:
  ───────────────────
  1. Connect ProtonVPN:
       protonvpn-cli connect --fastest
       # Or for Swiss exit (no-logs jurisdiction):
       protonvpn-cli connect --cc CH
       # Verify:
       curl https://api64.ipify.org   ← should show VPN IP, not your real IP

  2. Launch Observatory tmux workspace:
       ~/observatory/scripts/observatory_tmux.sh eth0
       # Replace eth0 with your actual interface (check: ip link show)

  RUNNING A BASIC CRAWL:
  ──────────────────────
  # Activate virtualenv
  source ~/observatory/.venv/bin/activate

  # Single site
  python ~/observatory/scripts/crawlers/basic_crawl.py \
    --sites "https://example.com"

  # Multiple sites
  python ~/observatory/scripts/crawlers/basic_crawl.py \
    --sites "https://site1.com" "https://site2.com" "https://site3.com"

  # From file (one URL per line)
  python ~/observatory/scripts/crawlers/basic_crawl.py \
    --file ~/observatory/my_sites.txt

  # Visible browser (watch what happens in real time)
  python ~/observatory/scripts/crawlers/basic_crawl.py \
    --sites "https://example.com" --headless false

  PASSIVE PACKET CAPTURE:
  ───────────────────────
  # Start (run BEFORE browser/crawl)
  ~/observatory/scripts/start_capture.sh eth0 my_session_name

  # Stop (run AFTER session complete)
  ~/observatory/scripts/stop_capture.sh my_session_name

  # Open capture in Wireshark for GUI review
  wireshark ~/observatory/captures/my_session_name/capture.pcap

  # Analyze with tshark (no GUI)
  tshark -r ~/observatory/captures/my_session_name/capture.pcap \
    -Y "http.request" -T fields -e ip.dst -e http.request.full_uri | sort -u

  AUTHENTICATED SESSIONS:
  ───────────────────────
  source ~/observatory/.venv/bin/activate

  # Manual login (you log in via browser, script records state)
  python ~/observatory/scripts/selenium/authenticated_session.py \
    --target "https://example.com/login"

  # Automated login
  python ~/observatory/scripts/selenium/authenticated_session.py \
    --target "https://example.com" \
    --auto-login \
    --username "your@email.com" \
    --password "yourpassword" \
    --navigate "https://example.com/dashboard" "https://example.com/settings"

  EXPLORING RESULTS WITH DATASETTE:
  ───────────────────────────────────
  ~/observatory/scripts/launch_datasette.sh
  # Opens http://localhost:8001 in browser (open manually)

  # Useful SQL queries are pre-written:
  # scripts/sql/find_fingerprinting.sql  ← canvas, WebGL, audio fingerprinting
  # scripts/sql/find_trackers.sql        ← third-party trackers, tracking pixels
  # scripts/sql/session_analysis.sql     ← session overview, localStorage, DNS

  # Run a query file directly:
  sqlite3 ~/observatory/crawls/YOUR_CRAWL/crawl.sqlite \
    < ~/observatory/scripts/sql/find_fingerprinting.sql

  DOCKER COMPOSE ALTERNATIVE:
  ────────────────────────────
  cd ~/observatory
  # Run a crawl via compose:
  docker-compose run --rm openwpm python /scripts/crawlers/basic_crawl.py \
    --sites "https://example.com"
  # Launch Datasette via compose:
  docker-compose up datasette

  IMPORTANT FILES AND DIRECTORIES:
  ─────────────────────────────────
  ~/observatory/
  ├── crawls/           ← OpenWPM SQLite databases (one dir per crawl)
  ├── captures/         ← tshark PCAP files (one dir per capture session)
  ├── scripts/
  │   ├── crawlers/     ← basic_crawl.py and custom crawl scripts
  │   ├── selenium/     ← authenticated_session.py and interaction scripts
  │   └── sql/          ← pre-written SQL queries for OpenWPM analysis
  ├── .venv/            ← Python virtualenv (Datasette, Selenium, etc.)
  ├── docker-compose.yml
  └── MANUAL.md         ← full operator manual, all 15 sections

  THERMAL NOTE (for the 7480):
  ─────────────────────────────
  Long crawls are CPU-intensive (Firefox + Docker + tshark simultaneously).
  Monitor with htop. If CPU cores are throttling:
    - Reduce parallel crawls (keep num_browsers=1 in crawl config)
    - Add longer sleep between page visits (--timeout flag)
    - Run capture-heavy sessions with laptop on a hard surface
    - Check: cat /sys/class/thermal/thermal_zone*/temp

GUIDE

    echo ""
    log_success "Observatory setup complete!"
    log_info "Root: ${OBSERVATORY_ROOT}"
    log_info "Remember: connect ProtonVPN before any crawl session."
    log_info "Re-login or run 'newgrp docker && newgrp wireshark' for group changes."
    echo ""
}

# =============================================================================
# MAIN — run all sections in order
# Each section is a function — you can re-run individual sections if needed.
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗ ██████╗ ███████╗███████╗██████╗ ██╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ ██╗   ██╗"
    echo "  ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██║   ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝"
    echo "  ██║  ██║██████╔╝███████╗█████╗  ██████╔╝██║   ██║███████║   ██║   ██║   ██║██████╔╝ ╚████╔╝ "
    echo "  ██║  ██║██╔══██╗╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══██║   ██║   ██║   ██║██╔══██╗  ╚██╔╝  "
    echo "  ██████╔╝██████╔╝███████║███████╗██║  ██║ ╚████╔╝ ██║  ██║   ██║   ╚██████╔╝██║  ██║   ██║   "
    echo "  ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝  "
    echo -e "${RESET}"
    echo -e "${BOLD}  Package 3: The Isolated Observatory — Setup Script${RESET}"
    echo -e "  Arch Linux + Docker + OpenWPM + tshark + Datasette + ProtonVPN"
    echo ""

    check_prerequisites
    install_system_packages
    setup_docker
    create_directory_structure
    setup_openwpm
    setup_tshark_permissions
    setup_python_environment
    setup_protonvpn
    write_crawl_scripts
    write_tmux_template
    write_docker_compose
    install_manual
    verify_installation
    print_usage_guide
}

main "$@"

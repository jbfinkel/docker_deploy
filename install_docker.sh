#!/usr/bin/env bash
# =============================================================================
# install_docker.sh
# Installs Docker Engine, Docker CLI, containerd, and Docker Compose plugin
# on any major Linux distribution.
#
# Usage:
#   sudo bash install_docker.sh              # install Docker (latest stable)
#   sudo bash install_docker.sh --version    # show installed Docker version
#   sudo bash install_docker.sh --uninstall  # remove Docker completely
#   sudo bash install_docker.sh --help       # show help
#
# Supported OS:
#   Ubuntu 20.04 / 22.04 / 24.04
#   Debian 11 / 12
#   RHEL / CentOS / Rocky Linux / AlmaLinux 7 / 8 / 9
#   Fedora 38 / 39 / 40
#   SUSE / openSUSE Leap 15
#   Raspberry Pi OS (armhf / arm64)
#   Amazon Linux 2 / 2023
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
ADD_USER_TO_GROUP=true       # add current sudo user to 'docker' group
ENABLE_ON_BOOT=true          # enable Docker service at boot
INSTALL_COMPOSE=true         # install Docker Compose v2 plugin
LOG_FILE="/var/log/install_docker.log"

# ─── COLOURS ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log()   { echo -e "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }
info()  { log "${CYAN}[INFO]${NC}  $*"; }
ok()    { log "${GREEN}[OK]${NC}    $*"; }
warn()  { log "${YELLOW}[WARN]${NC}  $*"; }
error() { log "${RED}[ERROR]${NC} $*"; exit 1; }

banner(){
  echo -e "\n${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║      Docker Engine – Install Script      ║"
  echo "╚══════════════════════════════════════════╝${NC}"
}

usage(){
  echo -e "
${BOLD}Usage:${NC}
  sudo bash $0 [OPTIONS]

${BOLD}Options:${NC}
  --no-compose        Skip Docker Compose v2 plugin installation
  --no-group          Do not add current user to the 'docker' group
  --no-boot           Do not enable Docker on system boot
  --uninstall         Remove Docker Engine, images, containers, and volumes
  --version           Print installed Docker version and exit
  --help              Show this help message

${BOLD}What gets installed:${NC}
  • docker-ce              Docker Engine (daemon)
  • docker-ce-cli          Docker CLI (docker command)
  • containerd.io          Container runtime
  • docker-buildx-plugin   BuildKit-based image builder
  • docker-compose-plugin  'docker compose' v2 command
"
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
check_root(){
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash $0"
}

detect_os(){
  [[ -f /etc/os-release ]] || error "/etc/os-release not found – cannot detect OS."
  source /etc/os-release
  OS_ID="${ID,,}"
  OS_VER="${VERSION_ID%%.*}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $VERSION_ID}"
  ARCH=$(uname -m)

  # Resolve ID_LIKE for derivatives (e.g. Mint → ubuntu, Rocky → rhel)
  ID_LIKE_VAL="${ID_LIKE:-}"

  case "$OS_ID" in
    ubuntu|debian|raspbian)                       OS_FAMILY="debian" ;;
    linuxmint|pop|elementary|kali|parrot)         OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol)               OS_FAMILY="rhel"   ;;
    fedora)                                       OS_FAMILY="fedora" ;;
    amzn)                                         OS_FAMILY="amzn"   ;;
    sles|opensuse-leap|opensuse-tumbleweed)       OS_FAMILY="suse"   ;;
    *)
      if echo "$ID_LIKE_VAL" | grep -qi "debian\|ubuntu"; then OS_FAMILY="debian"
      elif echo "$ID_LIKE_VAL" | grep -qi "rhel\|centos\|fedora"; then OS_FAMILY="rhel"
      else
        warn "Unrecognised OS '${OS_ID}'. Falling back to Docker's convenience script."
        OS_FAMILY="generic"
      fi
      ;;
  esac

  info "Detected: ${OS_PRETTY} (${ARCH}) → family: ${OS_FAMILY}"
}

check_existing_docker(){
  if command -v docker &>/dev/null; then
    local VER
    VER=$(docker --version 2>/dev/null || echo "unknown")
    warn "Docker is already installed: ${VER}"
    read -r -p "Re-install / upgrade? [y/N] " yn
    [[ "${yn,,}" == "y" ]] || { info "Nothing to do. Exiting."; exit 0; }
  fi
}

check_arch(){
  case "$ARCH" in
    x86_64|amd64)   DEB_ARCH="amd64"   ;;
    aarch64|arm64)  DEB_ARCH="arm64"   ;;
    armv7l|armhf)   DEB_ARCH="armhf"   ;;
    s390x)          DEB_ARCH="s390x"   ;;
    ppc64le)        DEB_ARCH="ppc64le" ;;
    *)
      warn "Architecture '${ARCH}' may not have official Docker packages."
      DEB_ARCH="$ARCH"
      ;;
  esac
}

# ─── INSTALL METHODS ──────────────────────────────────────────────────────────

# ── Debian / Ubuntu ───────────────────────────────────────────────────────────
install_debian(){
  info "Removing any old/conflicting Docker packages..."
  local OLD_PKGS=(docker docker-engine docker.io containerd runc
                  docker-ce docker-ce-cli docker-compose docker-compose-v2)
  apt-get remove -y "${OLD_PKGS[@]}" 2>/dev/null || true

  info "Installing prerequisites..."
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release apt-transport-https

  info "Adding Docker's official GPG key..."
  install -m 0755 -d /etc/apt/keyrings
  local KEY_URL

  # Raspbian uses a different key URL
  if [[ "$OS_ID" == "raspbian" ]]; then
    KEY_URL="https://download.docker.com/linux/raspbian/gpg"
    DOCKER_OS="raspbian"
  elif echo "$ID_LIKE_VAL $OS_ID" | grep -qi "ubuntu"; then
    KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
    DOCKER_OS="ubuntu"
    # For Ubuntu derivatives (Mint, Pop, etc.) use the Ubuntu codename
    CODENAME=$(. /etc/os-release 2>/dev/null; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}")
  else
    KEY_URL="https://download.docker.com/linux/debian/gpg"
    DOCKER_OS="debian"
    CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}")
  fi

  curl -fsSL "$KEY_URL" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  info "Adding Docker APT repository..."
  echo \
    "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DOCKER_OS} ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq

  info "Installing Docker Engine..."
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  ok "Docker installed via APT."
}

# ── RHEL / CentOS / Rocky / Alma ──────────────────────────────────────────────
install_rhel(){
  local PKG; PKG=$(command -v dnf &>/dev/null && echo dnf || echo yum)

  info "Removing any old/conflicting Docker packages..."
  $PKG remove -y docker docker-client docker-client-latest docker-common \
                 docker-latest docker-latest-logrotate docker-logrotate \
                 docker-engine podman runc 2>/dev/null || true

  info "Installing prerequisites..."
  $PKG install -y -q yum-utils curl

  info "Adding Docker CE repository..."
  yum-config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

  info "Installing Docker Engine..."
  $PKG install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  ok "Docker installed via ${PKG}."
}

# ── Fedora ────────────────────────────────────────────────────────────────────
install_fedora(){
  info "Removing any old/conflicting Docker packages..."
  dnf remove -y docker docker-client docker-client-latest docker-common \
                docker-latest docker-latest-logrotate docker-logrotate \
                docker-selinux docker-engine-selinux docker-engine \
                podman runc 2>/dev/null || true

  info "Adding Docker CE repository..."
  dnf install -y -q dnf-plugins-core curl
  dnf config-manager --add-repo \
    https://download.docker.com/linux/fedora/docker-ce.repo

  info "Installing Docker Engine..."
  dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  ok "Docker installed via dnf (Fedora)."
}

# ── Amazon Linux ──────────────────────────────────────────────────────────────
install_amzn(){
  info "Detected Amazon Linux ${OS_VER}."

  if [[ "$OS_VER" == "2023" ]]; then
    # Amazon Linux 2023 – use Docker's generic RPM repo
    info "Installing Docker on Amazon Linux 2023..."
    dnf install -y docker
  else
    # Amazon Linux 2 – use amazon-linux-extras
    info "Installing Docker on Amazon Linux 2..."
    amazon-linux-extras install -y docker
  fi

  ok "Docker installed on Amazon Linux."
}

# ── SUSE / openSUSE ───────────────────────────────────────────────────────────
install_suse(){
  info "Installing Docker on SUSE/openSUSE..."
  zypper --non-interactive install docker docker-compose
  ok "Docker installed via zypper."
}

# ── Generic fallback ──────────────────────────────────────────────────────────
install_generic(){
  warn "Using Docker's official convenience script (get.docker.com)..."
  warn "This method is NOT recommended for production systems."
  read -r -p "Continue? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || error "Aborted by user."

  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh 2>&1 | tee -a "$LOG_FILE"
  rm -f /tmp/get-docker.sh
  ok "Docker installed via convenience script."
}

# ─── POST-INSTALL ─────────────────────────────────────────────────────────────
configure_docker(){
  info "Enabling and starting Docker service..."
  systemctl daemon-reload
  systemctl enable docker 2>/dev/null || true

  if $ENABLE_ON_BOOT; then
    systemctl enable docker containerd
    ok "Docker enabled on boot."
  fi

  systemctl start docker
  ok "Docker service started."

  # Add the invoking user to the docker group so they don't need sudo
  if $ADD_USER_TO_GROUP; then
    local TARGET_USER="${SUDO_USER:-}"
    if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
      if ! groups "$TARGET_USER" | grep -q '\bdocker\b'; then
        usermod -aG docker "$TARGET_USER"
        ok "User '${TARGET_USER}' added to the 'docker' group."
        warn "Log out and back in (or run 'newgrp docker') for group change to take effect."
      else
        ok "User '${TARGET_USER}' is already in the 'docker' group."
      fi
    else
      info "Running as root – skipping group assignment. Create a non-root user and run: usermod -aG docker <username>"
    fi
  fi
}

configure_daemon(){
  info "Writing /etc/docker/daemon.json (log rotation + sane defaults)..."
  mkdir -p /etc/docker
  # Only write if file doesn't already exist
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false
}
EOF
    systemctl restart docker
    ok "daemon.json written and Docker restarted."
  else
    ok "/etc/docker/daemon.json already exists – not overwriting."
  fi
}

verify_install(){
  info "Verifying Docker installation..."

  local DOCKER_VER COMPOSE_VER
  DOCKER_VER=$(docker --version 2>/dev/null || echo "NOT FOUND")
  ok "Docker CLI  : ${DOCKER_VER}"

  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_VER=$(docker compose version)
    ok "Compose v2  : ${COMPOSE_VER}"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_VER=$(docker-compose --version)
    ok "Compose v1  : ${COMPOSE_VER}"
  else
    warn "Docker Compose not found."
  fi

  info "Running hello-world container to confirm daemon is working..."
  if docker run --rm hello-world 2>&1 | tee -a "$LOG_FILE" | grep -q "Hello from Docker"; then
    ok "hello-world test passed."
  else
    warn "hello-world test did not produce expected output. Check 'docker info' for errors."
  fi
}

# ─── UNINSTALL ────────────────────────────────────────────────────────────────
uninstall(){
  warn "This will remove Docker Engine, all images, containers, and volumes."
  read -r -p "Are you sure? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || { info "Aborted."; exit 0; }

  info "Stopping Docker service..."
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  systemctl disable docker docker.socket containerd 2>/dev/null || true

  info "Removing Docker packages..."
  case "$OS_FAMILY" in
    debian)
      apt-get purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
        docker docker.io docker-compose docker-doc podman-docker 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
      rm -f /etc/apt/sources.list.d/docker.list \
            /etc/apt/keyrings/docker.gpg
      apt-get update -qq
      ;;
    rhel|fedora)
      local PKG; PKG=$(command -v dnf &>/dev/null && echo dnf || echo yum)
      $PKG remove -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
        2>/dev/null || true
      rm -f /etc/yum.repos.d/docker-ce.repo
      ;;
    amzn)
      yum remove -y docker 2>/dev/null || true ;;
    suse)
      zypper --non-interactive remove docker docker-compose 2>/dev/null || true ;;
    *)
      warn "Manual uninstall may be required for OS '${OS_ID}'." ;;
  esac

  info "Removing Docker data (images, containers, volumes, networks)..."
  rm -rf /var/lib/docker /var/lib/containerd
  rm -f  /etc/docker/daemon.json
  rm -f  /usr/local/bin/docker-compose   # legacy standalone binary if present

  ok "Docker has been fully removed."
  exit 0
}

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
print_summary(){
  local DOCKER_VER COMPOSE_VER
  DOCKER_VER=$(docker --version 2>/dev/null || echo "unknown")
  COMPOSE_VER=$(docker compose version 2>/dev/null || echo "not installed")

  echo -e "\n${BOLD}${GREEN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║       🐳  Docker Install Complete!       ║"
  echo "╠══════════════════════════════════════════╣"
  printf "║  %-40s  ║\n" "${DOCKER_VER}"
  printf "║  %-40s  ║\n" "${COMPOSE_VER}"
  printf "║  %-40s  ║\n" "OS: ${OS_PRETTY}"
  printf "║  %-40s  ║\n" "Arch: ${ARCH}"
  echo "╠══════════════════════════════════════════╣"
  printf "║  %-40s  ║\n" "Config: /etc/docker/daemon.json"
  printf "║  %-40s  ║\n" "Data:   /var/lib/docker"
  printf "║  %-40s  ║\n" "Log:    ${LOG_FILE}"
  echo "╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}Quick reference:${NC}"
  echo "  docker run hello-world          # test installation"
  echo "  docker ps                       # list running containers"
  echo "  docker images                   # list local images"
  echo "  docker compose up -d            # start a compose stack"
  echo "  docker system prune -af         # free disk space"
  echo "  systemctl status docker         # service status"
  echo ""
  echo -e "${CYAN}Uninstall later:${NC}"
  echo "  sudo bash $0 --uninstall"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main(){
  banner
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-compose) INSTALL_COMPOSE=false ;;
      --no-group)   ADD_USER_TO_GROUP=false ;;
      --no-boot)    ENABLE_ON_BOOT=false ;;
      --uninstall)
        check_root; detect_os; uninstall ;;
      --version)
        docker --version 2>/dev/null || error "Docker is not installed."
        exit 0 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        warn "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
  done

  check_root
  detect_os
  check_existing_docker
  check_arch

  # Install by OS family
  case "$OS_FAMILY" in
    debian)  install_debian  ;;
    rhel)    install_rhel    ;;
    fedora)  install_fedora  ;;
    amzn)    install_amzn    ;;
    suse)    install_suse    ;;
    generic) install_generic ;;
  esac

  configure_docker
  configure_daemon
  verify_install
  print_summary
}

main "$@"

#!/bin/bash
#
# TS-UI installer — S-UI (sing-box) panel with TX-UI style setup flow.
# Panel binary: https://github.com/alireza0/s-ui
# Install UX inspired by: https://github.com/AghayeCoder/tx-ui

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

TSUI_FOLDER="${TSUI_FOLDER:-/usr/local/ts-ui}"
TSUI_SERVICE="${TSUI_SERVICE:-ts-ui}"
TSUI_PANEL_REPO="${TSUI_PANEL_REPO:-https://github.com/alireza0/s-ui}"

function LOGD() { echo -e "${yellow}[DEG] $* ${plain}"; }
function LOGE() { echo -e "${red}[ERR] $* ${plain}"; }
function LOGI() { echo -e "${green}[INF] $* ${plain}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n "
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *)
            echo -e "${red}Unsupported CPU architecture! ${plain}"
            rm -f install.sh
            exit 1
            ;;
    esac
}

echo "arch: $(arch)"

check_glibc_version() {
    if ! command -v ldd &>/dev/null; then
        return 0
    fi
    local glibc_version required_version="2.32"
    glibc_version=$(ldd --version | head -n1 | awk '{print $NF}')
    if [[ "$(printf '%s\n' "$required_version" "$glibc_version" | sort -V | head -n1)" != "$required_version" ]]; then
        echo -e "${red}GLIBC version $glibc_version is too old! Required: 2.32 or higher${plain}"
        echo "Please upgrade your OS to get a newer GLIBC."
        exit 1
    fi
    echo "GLIBC version: $glibc_version (meets requirement of 2.32+)"
}
check_glibc_version

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q wget curl tar tzdata socat openssl sqlite3
            ;;
        centos | rhel | almalinux | rocky | ol)
            yum -y update && yum install -y -q wget curl tar tzdata socat openssl sqlite
            ;;
        fedora | amzn)
            dnf -y update && dnf install -y -q wget curl tar tzdata socat openssl sqlite
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata socat openssl sqlite
            ;;
        opensuse-tumbleweed | opensuse)
            zypper refresh && zypper -q install -y wget curl tar timezone socat openssl sqlite3
            ;;
        alpine)
            apk update && apk add wget curl tar tzdata socat openssl sqlite
            ;;
        *)
            apt-get update && apt-get install -y -q wget curl tar tzdata socat openssl sqlite3
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    if command -v openssl &>/dev/null; then
        openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
    fi
}

get_server_ip() {
    local ip_address response http_code ip_result
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
    )
    for ip_address in "${URL_lists[@]}"; do
        response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
        http_code=$(echo "$response" | tail -n1)
        ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip_result}"
            return 0
        fi
    done
    return 1
}

install_acme() {
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        return 0
    fi
    LOGI "Installing acme.sh..."
    cd ~ || return 1
    curl -s https://get.acme.sh | sh >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        LOGE "Installation of acme.sh failed."
        return 1
    fi
    LOGI "acme.sh installed successfully."
    return 0
}

tsui_set_panel_cert() {
    local cert_file="$1"
    local key_file="$2"
    local db="${TSUI_FOLDER}/db/s-ui.db"

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        LOGE "Certificate or key file not found."
        return 1
    fi
    chmod 644 "$cert_file" 2>/dev/null
    chmod 600 "$key_file" 2>/dev/null

    if ! command -v sqlite3 &>/dev/null || [[ ! -f "$db" ]]; then
        LOGI "Set panel TLS in web UI: webCertFile=$cert_file webKeyFile=$key_file"
        return 0
    fi

    sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ('webCertFile', '${cert_file}') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ('webKeyFile', '${key_file}') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    LOGI "Panel TLS certificate paths saved to database."
    return 0
}

ssl_setup_menu() {
    local server_ip="$1"
    local choice certPath webCertFile webKeyFile domain access_proto="https"

    echo -e "${yellow}Choose an option for SSL certificate:${plain}"
    echo -e "  ${green}1.${plain} Generate a self-signed certificate (IP)"
    echo -e "  ${green}2.${plain} Get a certificate from a domain name (acme.sh)"
    echo -e "  ${green}3.${plain} Get a certificate for IP address (acme.sh, short-lived)"
    read -p "Enter your choice [1-3, default 1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            server_ip="${server_ip:-$(get_server_ip)}"
            certPath="/root/cert/${server_ip}"
            mkdir -p "$certPath"
            LOGD "Generating self-signed certificate for IP: ${server_ip}..."
            openssl req -x509 -newkey rsa:4096 \
                -keyout "${certPath}/privkey.pem" \
                -out "${certPath}/fullchain.pem" \
                -days 365 -nodes -subj "/CN=${server_ip}" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                LOGE "Generating self-signed certificate failed."
                return 1
            fi
            LOGI "Self-signed certificate generated."
            tsui_set_panel_cert "${certPath}/fullchain.pem" "${certPath}/privkey.pem"
            SSL_ACCESS_HOST="${server_ip}"
            ;;
        2)
            install_acme || return 1
            read -p "Enter your domain name: " domain
            domain="${domain// /}"
            if [[ -z "$domain" ]]; then
                LOGE "Domain cannot be empty."
                return 1
            fi
            LOGI "Using domain: ${domain}"
            certPath="/root/cert/${domain}"
            mkdir -p "$certPath"
            systemctl stop "${TSUI_SERVICE}" 2>/dev/null
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
            ~/.acme.sh/acme.sh --issue -d "${domain}" --listen-v6 --standalone --httpport 80
            if [[ $? -ne 0 ]]; then
                LOGE "Issuing certificate failed, falling back to self-signed."
                rm -rf ~/.acme.sh/"${domain}" 2>/dev/null
                openssl req -x509 -newkey rsa:4096 \
                    -keyout "${certPath}/privkey.pem" \
                    -out "${certPath}/fullchain.pem" \
                    -days 365 -nodes -subj "/CN=${domain}" 2>/dev/null
            else
                ~/.acme.sh/acme.sh --installcert -d "${domain}" \
                    --key-file "${certPath}/privkey.pem" \
                    --fullchain-file "${certPath}/fullchain.pem" \
                    --reloadcmd "systemctl restart ${TSUI_SERVICE} 2>/dev/null || true"
                ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
            fi
            webCertFile="${certPath}/fullchain.pem"
            webKeyFile="${certPath}/privkey.pem"
            tsui_set_panel_cert "$webCertFile" "$webKeyFile"
            SSL_ACCESS_HOST="${domain}"
            ;;
        3)
            install_acme || return 1
            server_ip="${server_ip:-$(get_server_ip)}"
            certPath="/root/cert/${server_ip}"
            mkdir -p "$certPath"
            systemctl stop "${TSUI_SERVICE}" 2>/dev/null
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
            ~/.acme.sh/acme.sh --issue -d "${server_ip}" --standalone \
                --server letsencrypt --certificate-profile shortlived --days 6 \
                --httpport 80 --force
            if [[ $? -ne 0 ]]; then
                LOGE "IP certificate issue failed, falling back to self-signed."
                rm -rf ~/.acme.sh/"${server_ip}" 2>/dev/null
                openssl req -x509 -newkey rsa:4096 \
                    -keyout "${certPath}/privkey.pem" \
                    -out "${certPath}/fullchain.pem" \
                    -days 365 -nodes -subj "/CN=${server_ip}" 2>/dev/null
            else
                ~/.acme.sh/acme.sh --installcert -d "${server_ip}" \
                    --key-file "${certPath}/privkey.pem" \
                    --fullchain-file "${certPath}/fullchain.pem" \
                    --reloadcmd "systemctl restart ${TSUI_SERVICE} 2>/dev/null || true"
                ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
            fi
            tsui_set_panel_cert "${certPath}/fullchain.pem" "${certPath}/privkey.pem"
            SSL_ACCESS_HOST="${server_ip}"
            ;;
        *)
            LOGE "Invalid choice."
            return 1
            ;;
    esac
    return 0
}

is_default_admin() {
    local info
    info=$("${TSUI_FOLDER}/sui" admin -show 2>/dev/null)
    echo "$info" | grep -q "Username:[[:space:]]*admin" &&
        echo "$info" | grep -q "Password:[[:space:]]*admin"
}

get_panel_path() {
    "${TSUI_FOLDER}/sui" setting -show 2>/dev/null | awk -F'\t' '/Panel path:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
}

config_after_install() {
    local server_ip config_port config_path config_username config_password
    local existing_path is_fresh=false

    if [[ ! -f "${TSUI_FOLDER}/db/s-ui.db" ]]; then
        is_fresh=true
    fi

    LOGI "Running database migration..."
    "${TSUI_FOLDER}/sui" migrate

    server_ip=$(get_server_ip)
    if [[ -z "$server_ip" ]]; then
        read -rp "Please enter your server's public IPv4 address: " server_ip
        server_ip="${server_ip// /}"
    fi

    if [[ "$is_fresh" == "true" ]]; then
        config_username=$(gen_random_string 10)
        config_password=$(gen_random_string 10)
        config_path="/$(gen_random_string 18)/"
        config_port=$(shuf -i 1024-62000 -n 1)

        read -rp "Customize panel port? (default: random ${config_port}) [y/N]: " custom_port_ans
        if [[ "${custom_port_ans}" == "y" || "${custom_port_ans}" == "Y" ]]; then
            read -rp "Panel port: " config_port
        fi

        "${TSUI_FOLDER}/sui" admin -username "${config_username}" -password "${config_password}"
        "${TSUI_FOLDER}/sui" setting -port "${config_port}" -path "${config_path}"

        echo -e "${yellow}SSL certificate setup (recommended, like TX-UI):${plain}"
        ssl_setup_menu "${server_ip}" || LOGI "Continuing without SSL — panel will use HTTP until configured."
        systemctl restart "${TSUI_SERVICE}" 2>/dev/null

        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     TS-UI installation complete          ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}Username:  ${config_username}${plain}"
        echo -e "${green}Password:  ${config_password}${plain}"
        echo -e "${green}Port:      ${config_port}${plain}"
        echo -e "${green}Path:      ${config_path}${plain}"
        if [[ -n "${SSL_ACCESS_HOST}" ]]; then
            echo -e "${green}Access:    https://${SSL_ACCESS_HOST}:${config_port}${config_path}${plain}"
        fi
        echo -e "${green}═══════════════════════════════════════════${plain}"
        LOGI "Panel URL(s) from sui uri:"
        "${TSUI_FOLDER}/sui" uri
    else
        existing_path=$(get_panel_path)
        if is_default_admin; then
            config_username=$(gen_random_string 10)
            config_password=$(gen_random_string 10)
            echo -e "${yellow}Default admin (admin/admin) detected — generating new credentials...${plain}"
            "${TSUI_FOLDER}/sui" admin -username "${config_username}" -password "${config_password}"
            echo -e "${green}Username: ${config_username}${plain}"
            echo -e "${green}Password: ${config_password}${plain}"
        fi
        if [[ "${existing_path}" == "/app/" || ${#existing_path} -lt 6 ]]; then
            config_path="/$(gen_random_string 18)/"
            echo -e "${yellow}Panel path is default or short — generating: ${config_path}${plain}"
            "${TSUI_FOLDER}/sui" setting -path "${config_path}"
        fi
        LOGI "Upgrade finished; previous settings preserved."
        "${TSUI_FOLDER}/sui" uri
    fi
}

prepare_services() {
    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        echo -e "${yellow}Stopping sing-box service...${plain}"
        systemctl stop sing-box 2>/dev/null
        rm -f "${TSUI_FOLDER}/bin/sing-box" "${TSUI_FOLDER}/bin/runSingbox.sh" "${TSUI_FOLDER}/bin/signal" 2>/dev/null
    fi
    if [[ -e "${TSUI_FOLDER}/bin" ]]; then
        echo -e "${yellow}${TSUI_FOLDER}/bin exists — check contents after migration.${plain}"
    fi
    systemctl daemon-reload
}

write_systemd_unit() {
    cat >"/etc/systemd/system/${TSUI_SERVICE}.service" <<EOF
[Unit]
Description=ts-ui Service (S-UI / sing-box panel)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=${TSUI_FOLDER}/
ExecStart=${TSUI_FOLDER}/sui
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
}

install_ts_ui() {
    cd /tmp/ || exit 1
    local last_version url

    if [[ $# -eq 0 ]]; then
        last_version=$(curl -Ls "https://api.github.com/repos/alireza0/s-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$last_version" ]]; then
            LOGE "Failed to fetch s-ui version (GitHub API). Try again later."
            exit 1
        fi
        LOGI "Latest s-ui version: ${last_version}"
    else
        last_version=$1
        LOGI "Installing s-ui version: ${last_version}"
    fi

    url="${TSUI_PANEL_REPO}/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz"
    wget -N --no-check-certificate -O "/tmp/s-ui-linux-$(arch).tar.gz" "${url}"
    if [[ $? -ne 0 ]]; then
        LOGE "Download failed: ${url}"
        exit 1
    fi

    if [[ -d "${TSUI_FOLDER}" ]]; then
        systemctl stop "${TSUI_SERVICE}" 2>/dev/null
        systemctl stop s-ui 2>/dev/null
    fi

    tar zxf "s-ui-linux-$(arch).tar.gz"
    rm -f "s-ui-linux-$(arch).tar.gz"

    chmod +x s-ui/sui
    rm -rf "${TSUI_FOLDER}"
    mkdir -p /usr/local
    mv s-ui "${TSUI_FOLDER}"

    write_systemd_unit

    local script_src
    script_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ts-ui.sh"
    if [[ -f "$script_src" ]]; then
        cp -f "$script_src" /usr/bin/ts-ui
    else
        wget -q -O /usr/bin/ts-ui "${TSUI_SCRIPT_RAW:-https://raw.githubusercontent.com/alireza0/s-ui/main/s-ui.sh}" 2>/dev/null || true
        if [[ -f /usr/bin/ts-ui ]]; then
            sed -i 's|/usr/local/s-ui|/usr/local/ts-ui|g; s|s-ui\.service|ts-ui.service|g; s|systemctl \(.*\) s-ui|systemctl \1 ts-ui|g; s|S-UI|TS-UI|g' /usr/bin/ts-ui 2>/dev/null || true
        fi
    fi
    chmod +x /usr/bin/ts-ui 2>/dev/null

    config_after_install
    prepare_services

    systemctl daemon-reload
    systemctl enable "${TSUI_SERVICE}" --now

    echo -e "${green}ts-ui (s-ui ${last_version}) is installed and running.${plain}"
    echo ""
    echo -e "┌───────────────────────────────────────────────────────┐"
    echo -e "│ ${blue}ts-ui control menu (subcommands):${plain}              │"
    echo -e "│ ${blue}ts-ui${plain}          - Admin menu                      │"
    echo -e "│ ${blue}ts-ui start${plain}    - Start                           │"
    echo -e "│ ${blue}ts-ui stop${plain}     - Stop                            │"
    echo -e "│ ${blue}ts-ui restart${plain}  - Restart                         │"
    echo -e "│ ${blue}ts-ui status${plain}   - Status                           │"
    echo -e "│ ${blue}ts-ui log${plain}      - Logs                             │"
    echo -e "│ ${blue}ts-ui update${plain}   - Update / reinstall               │"
    echo -e "│ ${blue}ts-ui uninstall${plain} - Uninstall                        │"
    echo -e "└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running TS-UI installer...${plain}"
install_base
install_ts_ui "$@"

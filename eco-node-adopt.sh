#!/usr/bin/env bash
#
# EcoSynQ Node Adoption Script
# Generates STTS hostnames, assigns roles, and registers on Headscale mesh.
#
# Usage:
#   sudo HEADSCALE_URL="https://headscale.tradingnations.cloud" \
#        PRE_AUTH_KEY_FILE="/run/ecosynq-preauth-key" \
#        NODE_ROLE="observation" NODE_REGION_CODE="VI" \
#        bash ./eco-node-adopt.sh

set -euo pipefail

HEADSCALE_URL="${HEADSCALE_URL:-${HEADSCALE_SERVER_URL:-}}"
PRE_AUTH_KEY="${PRE_AUTH_KEY:-${HEADSCALE_PRE_AUTH_KEY:-}}"
PRE_AUTH_KEY_FILE="${PRE_AUTH_KEY_FILE:-}"
PROVISIONING_API_URL="${PROVISIONING_API_URL:-}"
PROVISIONING_API_TOKEN="${PROVISIONING_API_TOKEN:-}"
PROVISIONING_API_TOKEN_FILE="${PROVISIONING_API_TOKEN_FILE:-}"
PROVISIONING_API_KEY_PATH="${PROVISIONING_API_KEY_PATH:-/api/key/generate}"
NODE_ROLE="${NODE_ROLE:-}"
NODE_REGION="${NODE_REGION:-}"
NODE_REGION_CODE="${NODE_REGION_CODE:-}"
NODE_DATACENTER="${NODE_DATACENTER:-hq}"
ALLOW_REENROLL="${ALLOW_REENROLL:-false}"
TAILSCALE_PACKAGE_VERSION="${TAILSCALE_PACKAGE_VERSION:-}"

# Secrets are passed only to the commands that require them.
export -n PRE_AUTH_KEY HEADSCALE_PRE_AUTH_KEY PROVISIONING_API_TOKEN 2>/dev/null || true

readonly SCRIPT_VERSION="2.0.0-ecosynq"
readonly CONFIG_DIR="/etc/ecosynq"
readonly NODE_IDENTITY_FILE="${CONFIG_DIR}/node-identity.json"
readonly LOG_FILE="/var/log/ecosynq-adoption.log"
readonly TAILSCALE_SIGNING_KEY_FINGERPRINT="2596A99EAAB33821893C0A79458CA832957F5868"

# Valid roles from the EcoSynQ architecture specification.
declare -ra VALID_ROLES=(
  "observation"
  "causal-inference"
  "independent-validation"
  "regional-qsa"
  "quantumvm"
  "q-topology"
  "surrealdb-projection"
  "immudb-evidence-authority"
  "checkout-registry"
)

log()  { printf '[ECOSYNQ] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '[OK] %s\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG_FILE"; }
err()  { printf '[ERROR] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    printf '[ERROR] This script must run as root (use sudo).\n' >&2
    exit 1
  fi
}

prepare_logging() {
  install -d -m 0700 "$CONFIG_DIR"
  if [[ ! -e "$LOG_FILE" ]]; then
    install -m 0600 /dev/null "$LOG_FILE"
  else
    chmod 600 "$LOG_FILE"
  fi
}

REGION_DISPLAY=""
REGION_CODE=""
SELECTED_INDEX=0

show_header() {
  echo ""
  echo "=============================================="
  echo "EcoSynQ Node Adoption"
  echo "=============================================="
  echo ""
}

select_item() {
  local prompt="$1"
  shift
  local items=("$@")
  local selected=0
  local max_idx=$(( ${#items[@]} - 1 ))
  local window_size=15
  local offset=0

  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    err "Interactive region selection requires a terminal; set NODE_REGION and NODE_REGION_CODE."
    return 1
  fi

  while true; do
    printf '\033[2J\033[H'
    show_header
    echo "$prompt"
    echo ""

    if (( selected >= window_size / 2 )); then
      offset=$((selected - window_size / 2))
    fi

    if (( offset > max_idx - window_size )); then
      offset=$((max_idx - window_size + 1))
    fi

    for ((i=offset; i<offset+window_size && i<=max_idx; i++)); do
      if [[ $i -eq $selected ]]; then
        echo "→ [$i] ${items[$i]}"
      else
        echo "  [$i] ${items[$i]}"
      fi
    done

    if (( offset > 0 )); then
      echo ""
      echo "  ↑↑↑ Press UP to scroll more"
    fi
    if (( offset + window_size <= max_idx )); then
      echo "  ↓↓↓ Press DOWN to scroll more"
    fi

    echo ""
    echo "Arrow keys to navigate, ENTER to confirm"
    echo ""

    read -rsn1 input < /dev/tty
    case "$input" in
      $'\x1b')
        read -rsn2 escape < /dev/tty
        case "$escape" in
          '[A') (( selected > 0 )) && selected=$((selected - 1)) ;;
          '[B') (( selected < max_idx )) && selected=$((selected + 1)) ;;
        esac
        ;;
      '')
        SELECTED_INDEX=$selected
        return 0
        ;;
    esac
  done
}

extract_code() {
  local display="$1"

  if [[ "$display" =~ \(([A-Za-z]{2})\)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'
    return 0
  fi

  if [[ "$display" =~ ^[A-Za-z]{2}$ ]]; then
    printf '%s\n' "$display" | tr '[:lower:]' '[:upper:]'
    return 0
  fi

  return 1
}

prompt_for_region_selection() {
  if [[ -n "$NODE_REGION" ]]; then
    REGION_DISPLAY="$NODE_REGION"
    if [[ -n "$NODE_REGION_CODE" ]]; then
      REGION_CODE="$(extract_code "$NODE_REGION_CODE" || true)"
    else
      REGION_CODE="$(extract_code "$REGION_DISPLAY" || true)"
    fi
    if [[ -z "$REGION_CODE" ]]; then
      err "NODE_REGION_CODE must be a 2-character country or territory code."
      return 1
    fi
    return 0
  fi

  select_item "Select country/territory (full name shown; 2-character code used in hostname):" "${LOCODE_DISPLAY[@]}" || return 1
  REGION_DISPLAY="${LOCODE_DISPLAY[$SELECTED_INDEX]}"
  REGION_CODE="$(extract_code "$REGION_DISPLAY")"
  NODE_REGION="$REGION_DISPLAY"
  NODE_REGION_CODE="$REGION_CODE"
}

# Full UN/LOCODE directory for interactive region selection
# Format: Display Name (CC)
declare -a LOCODE_DISPLAY=(
  "Afghanistan (AF)"
  "Albania (AL)"
  "Algeria (DZ)"
  "American Samoa (AS)"
  "Andorra (AD)"
  "Angola (AO)"
  "Anguilla (AI)"
  "Antarctica (AQ)"
  "Antigua and Barbuda (AG)"
  "Argentina (AR)"
  "Armenia (AM)"
  "Aruba (AW)"
  "Australia (AU)"
  "Austria (AT)"
  "Azerbaijan (AZ)"
  "Bahamas (BS)"
  "Bahrain (BH)"
  "Bangladesh (BD)"
  "Barbados (BB)"
  "Belarus (BY)"
  "Belgium (BE)"
  "Belize (BZ)"
  "Benin (BJ)"
  "Bermuda (BM)"
  "Bhutan (BT)"
  "Bolivia (BO)"
  "Bosnia and Herzegovina (BA)"
  "Botswana (BW)"
  "Brazil (BR)"
  "British Indian Ocean Territory (IO)"
  "Brunei Darussalam (BN)"
  "Bulgaria (BG)"
  "Burkina Faso (BF)"
  "Burundi (BI)"
  "Cabo Verde (CV)"
  "Cambodia (KH)"
  "Cameroon (CM)"
  "Canada (CA)"
  "Cayman Islands (KY)"
  "Central African Republic (CF)"
  "Chad (TD)"
  "Chile (CL)"
  "China (CN)"
  "Christmas Island (CX)"
  "Cocos (Keeling) Islands (CC)"
  "Colombia (CO)"
  "Comoros (KM)"
  "Congo (CG)"
  "Congo, Democratic Republic of the (CD)"
  "Cook Islands (CK)"
  "Costa Rica (CR)"
  "Côte d'Ivoire (CI)"
  "Croatia (HR)"
  "Cuba (CU)"
  "Cyprus (CY)"
  "Czechia (CZ)"
  "Denmark (DK)"
  "Djibouti (DJ)"
  "Dominica (DM)"
  "Dominican Republic (DO)"
  "Ecuador (EC)"
  "Egypt (EG)"
  "El Salvador (SV)"
  "Equatorial Guinea (GQ)"
  "Eritrea (ER)"
  "Estonia (EE)"
  "Eswatini (SZ)"
  "Ethiopia (ET)"
  "Falkland Islands (FK)"
  "Faroe Islands (FO)"
  "Fiji (FJ)"
  "Finland (FI)"
  "France (FR)"
  "French Guiana (GF)"
  "French Polynesia (PF)"
  "Gabon (GA)"
  "Gambia (GM)"
  "Georgia (GE)"
  "Germany (DE)"
  "Ghana (GH)"
  "Gibraltar (GI)"
  "Greece (GR)"
  "Greenland (GL)"
  "Grenada (GD)"
  "Guadeloupe (GP)"
  "Guam (GU)"
  "Guatemala (GT)"
  "Guinea (GN)"
  "Guinea-Bissau (GW)"
  "Guyana (GY)"
  "Haiti (HT)"
  "Honduras (HN)"
  "Hong Kong (HK)"
  "Hungary (HU)"
  "Iceland (IS)"
  "India (IN)"
  "Indonesia (ID)"
  "Iran (IR)"
  "Iraq (IQ)"
  "Ireland (IE)"
  "Israel (IL)"
  "Italy (IT)"
  "Jamaica (JM)"
  "Japan (JP)"
  "Jordan (JO)"
  "Kazakhstan (KZ)"
  "Kenya (KE)"
  "Kiribati (KI)"
  "Korea, Republic of (KR)"
  "Kuwait (KW)"
  "Kyrgyzstan (KG)"
  "Lao People's Democratic Republic (LA)"
  "Latvia (LV)"
  "Lebanon (LB)"
  "Lesotho (LS)"
  "Liberia (LR)"
  "Libya (LY)"
  "Liechtenstein (LI)"
  "Lithuania (LT)"
  "Luxembourg (LU)"
  "Macao (MO)"
  "Madagascar (MG)"
  "Malawi (MW)"
  "Malaysia (MY)"
  "Maldives (MV)"
  "Mali (ML)"
  "Malta (MT)"
  "Marshall Islands (MH)"
  "Martinique (MQ)"
  "Mauritania (MR)"
  "Mauritius (MU)"
  "Mayotte (YT)"
  "Mexico (MX)"
  "Micronesia (FM)"
  "Moldova (MD)"
  "Monaco (MC)"
  "Mongolia (MN)"
  "Montenegro (ME)"
  "Montserrat (MS)"
  "Morocco (MA)"
  "Mozambique (MZ)"
  "Myanmar (MM)"
  "Namibia (NA)"
  "Nauru (NR)"
  "Nepal (NP)"
  "Netherlands (NL)"
  "New Caledonia (NC)"
  "New Zealand (NZ)"
  "Nicaragua (NI)"
  "Niger (NE)"
  "Nigeria (NG)"
  "Niue (NU)"
  "Norfolk Island (NF)"
  "North Macedonia (MK)"
  "Northern Mariana Islands (MP)"
  "Norway (NO)"
  "Oman (OM)"
  "Pakistan (PK)"
  "Palau (PW)"
  "Palestine, State of (PS)"
  "Panama (PA)"
  "Papua New Guinea (PG)"
  "Paraguay (PY)"
  "Peru (PE)"
  "Philippines (PH)"
  "Pitcairn (PN)"
  "Poland (PL)"
  "Portugal (PT)"
  "Puerto Rico (PR)"
  "Qatar (QA)"
  "Réunion (RE)"
  "Romania (RO)"
  "Russian Federation (RU)"
  "Rwanda (RW)"
  "Saint Barthélemy (BL)"
  "Saint Helena, Ascension and Tristan da Cunha (SH)"
  "Saint Kitts and Nevis (KN)"
  "Saint Lucia (LC)"
  "Saint Martin (French part) (MF)"
  "Saint Pierre and Miquelon (PM)"
  "Saint Vincent and the Grenadines (VC)"
  "Samoa (WS)"
  "San Marino (SM)"
  "Sao Tome and Principe (ST)"
  "Saudi Arabia (SA)"
  "Senegal (SN)"
  "Serbia (RS)"
  "Seychelles (SC)"
  "Sierra Leone (SL)"
  "Singapore (SG)"
  "Sint Maarten (Dutch part) (SX)"
  "Slovakia (SK)"
  "Slovenia (SI)"
  "Solomon Islands (SB)"
  "Somalia (SO)"
  "South Africa (ZA)"
  "South Georgia and the South Sandwich Islands (GS)"
  "South Sudan (SS)"
  "Spain (ES)"
  "Sri Lanka (LK)"
  "Sudan (SD)"
  "Suriname (SR)"
  "Svalbard and Jan Mayen (SJ)"
  "Sweden (SE)"
  "Switzerland (CH)"
  "Syrian Arab Republic (SY)"
  "Taiwan (TW)"
  "Tajikistan (TJ)"
  "Tanzania, United Republic of (TZ)"
  "Thailand (TH)"
  "Timor-Leste (TL)"
  "Togo (TG)"
  "Tokelau (TK)"
  "Tonga (TO)"
  "Trinidad and Tobago (TT)"
  "Tunisia (TN)"
  "Turkey (TR)"
  "Turkmenistan (TM)"
  "Turks and Caicos Islands (TC)"
  "Tuvalu (TV)"
  "Uganda (UG)"
  "Ukraine (UA)"
  "United Arab Emirates (AE)"
  "United Kingdom of Great Britain and Northern Ireland (GB)"
  "United States of America (US)"
  "Uruguay (UY)"
  "Uzbekistan (UZ)"
  "Vanuatu (VU)"
  "Venezuela (VE)"
  "Viet Nam (VN)"
  "Virgin Islands (British) (VG)"
  "Virgin Islands (U.S.) (VI)"
  "Wallis and Futuna (WF)"
  "Western Sahara (EH)"
  "Yemen (YE)"
  "Zambia (ZM)"
  "Zimbabwe (ZW)"
)

generate_short_hash() {
  # 4-character hex fragment for collision reduction.
  head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4
}

generate_node_name() {
  local role="$1"
  local cc="$2"

  # Timestamp: DDHHMMSSzMMYYYY — all numeric, no separators
  local timestamp
  timestamp="$(date -u '+%d%H%M%Sz%m%Y')"

  # Short random hash for collision resistance
  local hash
  hash="$(generate_short_hash)"

  echo "${role}-${cc}-${timestamp}-${hash}"
}

resolve_node_name() {
  local role="$1"
  local region="$2"
  local region_code="$3"

  if [[ ! -s "$NODE_IDENTITY_FILE" ]]; then
    generate_node_name "$role" "$region_code"
    return 0
  fi

  local existing_name
  local existing_role
  local existing_region
  existing_name="$(jq -er '.node_name | select(type == "string" and length > 0)' "$NODE_IDENTITY_FILE" 2>/dev/null || true)"
  existing_role="$(jq -er '.node_role | select(type == "string" and length > 0)' "$NODE_IDENTITY_FILE" 2>/dev/null || true)"
  existing_region="$(jq -er '.node_region | select(type == "string" and length > 0)' "$NODE_IDENTITY_FILE" 2>/dev/null || true)"

  if [[ -z "$existing_name" || -z "$existing_role" || -z "$existing_region" ]]; then
    err "Existing identity file is incomplete; refusing to replace it automatically."
    return 1
  fi

  if [[ "$existing_role" != "$role" || "$existing_region" != "$region" ]]; then
    err "Existing identity belongs to role '$existing_role' in '$existing_region'."
    err "Role or region changes require a controlled decommission and new enrollment."
    return 1
  fi

  printf '%s\n' "$existing_name"
}

validate_role() {
  local role="$1"
  local valid

  for valid in "${VALID_ROLES[@]}"; do
    if [[ "$role" == "$valid" ]]; then
      return 0
    fi
  done

  err "Invalid role: $role"
  echo "Valid roles:"
  printf '  - %s\n' "${VALID_ROLES[@]}"
  return 1
}

validate_metadata() {
  local label="$1"
  local value="$2"
  local max_length="$3"

  if [[ -z "$value" || ${#value} -gt $max_length || "$value" =~ [[:cntrl:]] ]]; then
    err "$label is empty, too long, or contains control characters."
    return 1
  fi
}

read_secret_file() {
  local label="$1"
  local secret_file="$2"

  if [[ ! -f "$secret_file" || ! -r "$secret_file" ]]; then
    err "$label file is not a readable regular file: $secret_file"
    return 1
  fi

  local mode
  mode="$(stat -c '%a' "$secret_file")"
  if (( (8#$mode & 077) != 0 )); then
    err "$label file must not be accessible by group or other users: $secret_file"
    return 1
  fi

  local secret
  secret="$(< "$secret_file")"
  if [[ -z "$secret" || "$secret" == *$'\n'* || "$secret" == *$'\r'* ]]; then
    err "$label file is empty or contains invalid control characters."
    return 1
  fi

  printf '%s' "$secret"
}

resolve_preauth_key() {
  if [[ -n "$PRE_AUTH_KEY" && "$PRE_AUTH_KEY" != "REPLACE_WITH_HEADSCALE_PREAUTH_KEY" ]]; then
    return 0
  fi

  if [[ -z "$PROVISIONING_API_URL" || -z "$PROVISIONING_API_TOKEN" ]]; then
    err "PRE_AUTH_KEY is not set and no provisioning API credentials were provided."
    return 1
  fi

  if [[ ! "$PROVISIONING_API_URL" =~ ^https:// ]]; then
    err "PROVISIONING_API_URL must use HTTPS."
    return 1
  fi

  if [[ "$PROVISIONING_API_TOKEN" == *$'\n'* || "$PROVISIONING_API_TOKEN" == *$'\r'* ]]; then
    err "PROVISIONING_API_TOKEN contains invalid control characters."
    return 1
  fi

  if [[ ! "$PROVISIONING_API_KEY_PATH" =~ ^/[A-Za-z0-9._~/%-]+$ ]]; then
    err "PROVISIONING_API_KEY_PATH must be an absolute URL path."
    return 1
  fi

  local api_base="${PROVISIONING_API_URL%/}"
  local generate_url="${api_base}${PROVISIONING_API_KEY_PATH}"
  local auth_header_file
  auth_header_file="$(mktemp)"
  chmod 600 "$auth_header_file"
  printf 'Authorization: Bearer %s\n' "$PROVISIONING_API_TOKEN" > "$auth_header_file"

  local key_payload
  key_payload="$(jq -nc \
    --arg role "$NODE_ROLE" \
    --arg region "$REGION_DISPLAY" \
    --arg region_code "$REGION_CODE" \
    --arg datacenter "$NODE_DATACENTER" \
    '{node_role: $role, node_region: $region, node_region_code: $region_code, node_datacenter: $datacenter, reusable: false, expiration_seconds: 3600}')"

  log "Requesting pre-auth key from provisioning API"
  local response
  if ! response="$(printf '%s' "$key_payload" | curl \
    --fail \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 2 \
    --retry-all-errors \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "@$auth_header_file" \
    --data-binary @- \
    "$generate_url")"; then
    err "Failed to generate a pre-auth key from provisioning API at $generate_url"
    rm -f "$auth_header_file"
    return 1
  fi
  rm -f "$auth_header_file"

  PRE_AUTH_KEY="$(jq -er \
    '(.pre_auth_key // .preauth_key // .headscale_pre_auth_key // .auth_key) | select(type == "string" and length > 0)' \
    <<< "$response" 2>/dev/null || true)"
  unset response key_payload PROVISIONING_API_TOKEN

  if [[ -z "$PRE_AUTH_KEY" ]]; then
    err "Provisioning API returned no pre-auth key."
    return 1
  fi

  ok "Resolved pre-auth key from provisioning API"
  return 0
}

validate_environment() {
  local missing=0

  if [[ -z "$PRE_AUTH_KEY" && -n "$PRE_AUTH_KEY_FILE" ]]; then
    PRE_AUTH_KEY="$(read_secret_file PRE_AUTH_KEY "$PRE_AUTH_KEY_FILE")" || missing=$((missing + 1))
  fi
  if [[ -z "$PROVISIONING_API_TOKEN" && -n "$PROVISIONING_API_TOKEN_FILE" ]]; then
    PROVISIONING_API_TOKEN="$(read_secret_file PROVISIONING_API_TOKEN "$PROVISIONING_API_TOKEN_FILE")" || missing=$((missing + 1))
  fi

  : "${HEADSCALE_URL:?HEADSCALE_URL is required}"
  : "${NODE_ROLE:?NODE_ROLE is required}"

  if [[ ! "$HEADSCALE_URL" =~ ^https:// ]]; then
    err "HEADSCALE_URL must use HTTPS."
    missing=$((missing + 1))
  fi

  validate_metadata HEADSCALE_URL "$HEADSCALE_URL" 2048 || missing=$((missing + 1))
  validate_metadata NODE_DATACENTER "$NODE_DATACENTER" 64 || missing=$((missing + 1))
  if [[ -n "$NODE_REGION" ]]; then
    validate_metadata NODE_REGION "$NODE_REGION" 128 || missing=$((missing + 1))
  fi

  validate_role "$NODE_ROLE" || missing=$((missing + 1))

  if [[ $missing -gt 0 ]]; then
    err "Environment validation failed."
    exit 1
  fi
}

prepare_system() {
  log "Preparing system for EcoSynQ node adoption"

  export DEBIAN_FRONTEND=noninteractive

  if ! command -v curl >/dev/null 2>&1 || \
     ! command -v gpg >/dev/null 2>&1 || \
     ! command -v jq >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg jq
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    local os_id
    local codename
    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    if [[ "$os_id" != "ubuntu" || ! "$codename" =~ ^[a-z0-9]+$ ]]; then
      err "Automatic Tailscale installation supports Ubuntu with VERSION_CODENAME set."
      return 1
    fi

    local key_source
    local keyring_tmp
    local source_list_tmp
    key_source="$(mktemp)"
    keyring_tmp="$(mktemp)"
    source_list_tmp="$(mktemp)"
    trap 'rm -f "$key_source" "$keyring_tmp" "$source_list_tmp"; trap - RETURN' RETURN

    log "Installing Tailscale from its signed apt repository"
    curl \
      --fail \
      --silent \
      --show-error \
      --proto '=https' \
      --tlsv1.2 \
      --connect-timeout 10 \
      --max-time 30 \
      --retry 2 \
      "https://pkgs.tailscale.com/stable/ubuntu/${codename}.gpg" \
      --output "$key_source"

    local key_fingerprint
    key_fingerprint="$(gpg --batch --show-keys --with-colons "$key_source" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$key_fingerprint" != "$TAILSCALE_SIGNING_KEY_FINGERPRINT" ]]; then
      err "Tailscale repository signing key fingerprint mismatch."
      return 1
    fi

    gpg --batch --yes --dearmor --output "$keyring_tmp" "$key_source"
    install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
    install -m 0644 "$keyring_tmp" /usr/share/keyrings/tailscale-archive-keyring.gpg
    printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu %s main\n' \
      "$codename" > "$source_list_tmp"
    install -m 0644 "$source_list_tmp" /etc/apt/sources.list.d/tailscale.list

    apt-get update -qq
    if [[ -n "$TAILSCALE_PACKAGE_VERSION" ]]; then
      apt-get install -y -qq --no-install-recommends "tailscale=${TAILSCALE_PACKAGE_VERSION}"
    else
      apt-get install -y -qq --no-install-recommends tailscale
    fi
    ok "Tailscale installed"
  else
    ok "Tailscale already installed"
  fi

  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    log "Starting tailscaled service"
    systemctl enable --now tailscaled
  fi
}

set_hostname() {
  local node_name="$1"

  log "Setting hostname to: $node_name"
  hostnamectl set-hostname "$node_name"
  ok "Hostname set"
}

register_with_headscale() {
  local node_name="$1"
  local role="$2"
  local region="$3"
  local expected_tag="tag:${role}"

  log "Registering node with Headscale"
  log "Control URL: $HEADSCALE_URL"
  log "Node: $node_name"
  log "Role: $role"
  log "Region: $region"

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || true)"
  local existing_node_id
  existing_node_id="$(jq -r '.Self.ID // empty' <<< "$status_json" 2>/dev/null || true)"
  local needs_auth_key="true"

  if [[ -n "$existing_node_id" ]]; then
    local current_hostname
    current_hostname="$(jq -r '.Self.HostName // .Self.DNSName // empty' <<< "$status_json")"
    local identity_matches="false"
    if [[ "$current_hostname" == "$node_name" || "$current_hostname" == "$node_name".* ]] && \
      jq -e --arg tag "$expected_tag" '(.Self.Tags // []) | index($tag) != null' <<< "$status_json" >/dev/null; then
      identity_matches="true"
    fi

    if [[ "$identity_matches" != "true" && "$ALLOW_REENROLL" != "true" ]]; then
      err "The existing Tailscale identity does not match node '$node_name' and tag '$expected_tag'."
      err "Refusing silent reenrollment; set ALLOW_REENROLL=true only after approval."
      return 1
    fi

    if [[ "$identity_matches" == "true" ]]; then
      if [[ "$(jq -r '.Self.Online // false' <<< "$status_json")" == "true" ]]; then
        ok "Existing Headscale enrollment matches the persisted identity and role tag"
        return 0
      fi
      needs_auth_key="false"
    else
      warn "Approved reenrollment requested; logging out the existing Tailscale identity"
      tailscale logout
    fi
  fi

  local tailscale_up_args=(
    tailscale up
    --login-server="$HEADSCALE_URL"
    --hostname="$node_name"
    --accept-dns=false
    --accept-routes=false
    --advertise-tags="tag:${role}"
    --reset
  )

  if [[ "$needs_auth_key" == "true" ]]; then
    resolve_preauth_key || return 1
    TS_AUTHKEY="$PRE_AUTH_KEY" "${tailscale_up_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    unset PRE_AUTH_KEY
  else
    "${tailscale_up_args[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi

  log "Waiting for mesh connection"
  local online
  online="false"
  for _ in $(seq 1 20); do
    status_json="$(tailscale status --json 2>/dev/null || true)"
    online="$(jq -r '.Self.Online // false' <<< "$status_json" 2>/dev/null || echo false)"
    if [[ "$online" == "true" ]]; then
      break
    fi
    sleep 2
  done

  if [[ "$online" != "true" ]]; then
    err "Failed to register with Headscale mesh"
    err "Check: tailscale status and journalctl -u tailscaled"
    return 1
  fi

  if ! jq -e --arg tag "$expected_tag" '(.Self.Tags // []) | index($tag) != null' <<< "$status_json" >/dev/null; then
    err "Headscale enrollment is online but the required role tag '$expected_tag' is not effective."
    tailscale down || true
    return 1
  fi

  local node_ip
  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "unknown")"
  local node_id
  node_id="$(tailscale status --json 2>/dev/null | jq -r '.Self.ID // "unknown"')"

  ok "Node registered on Headscale mesh"
  log "Mesh IP: $node_ip"
  log "Node ID: $node_id"
}

write_identity_file() {
  local node_name="$1"
  local role="$2"
  local region="$3"
  local datacenter="${4:-unset}"
  local region_code="$5"

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || echo '{}')"

  local node_ip
  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "pending")"

  local node_id
  node_id="$(jq -r '.Self.ID // "pending"' <<< "$status_json")"

  local effective_tags
  effective_tags="$(jq -c '.Self.Tags // []' <<< "$status_json")"

  local os_info
  os_info="$(uname -srm)"

  local kernel_version
  kernel_version="$(uname -r)"

  local hardware
  hardware="$(hostnamectl 2>/dev/null | awk -F: '/Hardware Vendor/{gsub(/^ +/,"",$2); print $2; exit}' || true)"
  hardware="${hardware:-unknown}"

  local tailscale_binary
  tailscale_binary="$(command -v tailscale)"
  local tailscale_binary_sha256
  tailscale_binary_sha256="$(sha256sum "$tailscale_binary" | awk '{print $1}')"
  local tailscale_version
  tailscale_version="$(tailscale version 2>/dev/null | head -n 1 || echo unknown)"
  local adoption_script_sha256="streamed-unavailable"
  local adoption_script_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$adoption_script_path" && -f "$adoption_script_path" ]]; then
    adoption_script_sha256="$(sha256sum "$adoption_script_path" | awk '{print $1}')"
  fi
  local identity_tmp
  identity_tmp="$(mktemp "${CONFIG_DIR}/.node-identity.XXXXXX")"

  log "Writing identity file: $NODE_IDENTITY_FILE"

  if ! jq -n \
    --arg name "$node_name" \
    --arg role "$role" \
    --arg region "$region" \
    --arg region_code "$region_code" \
    --arg datacenter "$datacenter" \
    --arg mesh_ip "$node_ip" \
    --arg node_id "$node_id" \
    --arg os "$os_info" \
    --arg kernel "$kernel_version" \
    --arg hardware "$hardware" \
    --arg adopted_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg adoption_script_sha256 "$adoption_script_sha256" \
    --arg tailscale_version "$tailscale_version" \
    --arg tailscale_binary_sha256 "$tailscale_binary_sha256" \
    --arg headscale_url "$HEADSCALE_URL" \
    --argjson effective_tags "$effective_tags" \
    '{
      node_name: $name,
      node_role: $role,
      node_region: $region,
      node_region_code: $region_code,
      node_datacenter: $datacenter,
      mesh_ip: $mesh_ip,
      node_id: $node_id,
      os: $os,
      kernel: $kernel,
      hardware_vendor: $hardware,
      effective_tags: $effective_tags,
      adopted_at_utc: $adopted_at,
      script_version: $script_version,
      adoption_script_sha256: $adoption_script_sha256,
      tailscale_version: $tailscale_version,
      tailscale_binary_sha256: $tailscale_binary_sha256,
      headscale_server: $headscale_url,
      identity_proof_status: "unsigned-local-record"
    }' > "$identity_tmp"; then
    rm -f "$identity_tmp"
    return 1
  fi

  chmod 600 "$identity_tmp"
  mv -f "$identity_tmp" "$NODE_IDENTITY_FILE"
  ok "Identity file written"
}

display_summary() {
  local node_name="$1"
  local role="$2"
  local region="$3"
  local node_ip

  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "pending")"

  echo ""
  echo "=============================================="
  echo "EcoSynQ Node Adoption Summary"
  echo "=============================================="
  echo "Node Name:    $node_name"
  echo "Role:         $role"
  echo "Region:       $region"
  echo "Mesh IP:      $node_ip"
  echo "Headscale:    $HEADSCALE_URL"
  echo "Identity:     $NODE_IDENTITY_FILE"
  echo "Status:       ADOPTED"
  echo "=============================================="
  echo ""
}

is_entrypoint() {
  local source_path="${1:-}"
  local invocation_path="${2:-}"
  [[ -z "$source_path" || "$source_path" == "$invocation_path" ]]
}

main() {
  require_root
  prepare_logging

  validate_environment
  log "Role validated: $NODE_ROLE"

  prompt_for_region_selection
  log "Region: $REGION_DISPLAY"

  prepare_system

  local node_name
  node_name="$(resolve_node_name "$NODE_ROLE" "$REGION_DISPLAY" "$REGION_CODE")"
  ok "Generated STTS hostname: $node_name"

  register_with_headscale "$node_name" "$NODE_ROLE" "$REGION_DISPLAY"
  set_hostname "$node_name"
  write_identity_file "$node_name" "$NODE_ROLE" "$REGION_DISPLAY" "${NODE_DATACENTER:-unset}" "$REGION_CODE"
  display_summary "$node_name" "$NODE_ROLE" "$REGION_DISPLAY"

  log "Node adoption complete"
}

if is_entrypoint "${BASH_SOURCE[0]:-}" "$0"; then
  main "$@"
fi

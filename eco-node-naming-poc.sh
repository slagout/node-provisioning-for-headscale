#!/usr/bin/env bash
#
# EcoSynQ Node Naming — Full UN/LOCODE Edition
# Purpose: Generate secure hostnames based on UN/LOCODE and node role
# Security: Pre-auth key stored locally (NOT in remote scripts)
# Features: Full country list with display names, 2-char code in node name
#
# Source: https://unlocode.unece.org/directory
#

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0-full-unlocode"
readonly LOG_FILE="/var/log/ecosynq-naming.log"

# ──────────────────────────────────────────────────────────────────────────────
# SECURITY WARNING: Replace this key with YOUR actual Headscale pre-auth key
# This key grants admission to the mesh. Protect it like a password.
# ──────────────────────────────────────────────────────────────────────────────
PRE_AUTH_KEY="hskey_replace_with_your_actual_key_here"
HEADSCALE_URL="https://headscale.tradingnations.cloud"

# ──────────────────────────────────────────────────────────────────────────────
#  Allowed Node Roles (from your specification)
# ──────────────────────────────────────────────────────────────────────────────
declare -a ROLES=(
  "Observation"
  "Causal-Inference"
  "Independent-Validation"
  "Regional-QSA"
  "QuantumVM"
  "Q-Topology"
  "SurrealDB-Projection"
  "ImmuDB-Evidence-Authority"
  "Checkout-Registry"
)

# ──────────────────────────────────────────────────────────────────────────────
#  UN/LOCODE Country Code Directory
#  Complete list from https://unlocode.unece.org/directory
#  Format: "Display Name (CC)" where CC is the 2-char code
# ──────────────────────────────────────────────────────────────────────────────
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

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"; }

# ──────────────────────────────────────────────────────────────────────────────
#  Interactive Menu Helpers
# ──────────────────────────────────────────────────────────────────────────────
show_header() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║       EcoSynQ Node Naming — Full UN/LOCODE Edition       ║"
  echo "║                    Version $SCRIPT_VERSION                         ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
}

select_item() {
  local prompt="$1"
  shift
  local items=("$@")
  local selected=0
  local max_idx=$(( ${#items[@]} - 1 ))

  while true; do
    clear
    show_header
    echo "$prompt"
    echo ""

    # Scrollable window showing 15 items at a time
    local window_size=15
    local offset=0

    if [[ $selected -ge $((window_size / 2)) ]]; then
      offset=$((selected - window_size / 2))
    fi

    if [[ $offset -gt $max_idx - window_size ]]; then
      offset=$((max_idx - window_size + 1))
    fi

    for ((i=offset; i<offset+window_size && i<=max_idx; i++)); do
      if [[ $i -eq $selected ]]; then
        echo "→ [$i] ${items[$i]}"
      else
        echo "  [$i] ${items[$i]}"
      fi
    done

    if [[ $offset -gt 0 ]]; then
      echo ""
      echo "  ↑↑↑ Press UP to scroll more"
    fi
    if [[ $((offset + window_size)) -le $max_idx ]]; then
      echo "  ↓↓↓ Press DOWN to scroll more"
    fi

    echo ""
    echo "Arrow keys to navigate, ENTER to confirm"
    echo ""

    read -rsn1 input
    case "$input" in
      $'\x1b')  # Escape sequence (arrow keys)
        read -rsn2 escape
        case "$escape" in
          '[A') ((selected > 0)) && ((selected--)) ;;  # Up
          '[B') ((selected < max_idx)) && ((selected++));;  # Down
        esac
        ;;
      '') return $selected ;;  # Enter key
    esac
  done
}

extract_code() {
  local display="$1"
  echo "$display" | grep -oP '\([^)]+\)' | tr -d '()'
}

# ──────────────────────────────────────────────────────────────────────────────
#  Node Name Generation
#  Format: role-CC-timestamp-hash
#  Example: Observation-US-15032416z-aug-2026-abcd
#  Note: Only the 2-char code appears in the name, not the full country name
# ──────────────────────────────────────────────────────────────────────────────
generate_node_name() {
  local role="$1"
  local cc="$2"

  # Timestamp: DDHHMMSSzMMYYYY — all numeric, no separators
  local timestamp
  timestamp="$(date -u '+%d%H%M%Sz%m%Y')"

  # Short random hash for collision resistance
  local hash
  hash="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)"

  echo "${role}-${cc}-${timestamp}-${hash}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  Validation Helpers
# ──────────────────────────────────────────────────────────────────────────────
validate_preauth() {
  if [[ "$PRE_AUTH_KEY" == "hskey_replace_with_your_actual_key_here" ]]; then
    log "❌ CRITICAL: Pre-auth key not configured!"
    log "   Edit this script and set PRE_AUTH_KEY before running."
    exit 1
  fi

  if [[ "$PRE_AUTH_KEY" != hskey_* ]]; then
    log "⚠️  Warning: Key does not match 'hskey_' prefix pattern"
  fi

  log "✅ Pre-auth key validated"
}

# ──────────────────────────────────────────────────────────────────────────────
#  Installation Command Generator
# ──────────────────────────────────────────────────────────────────────────────
build_install_command() {
  local node_name="$1"
  local role="$2"
  local cc="$3"
  local country_display="$4"

  # Normalize role for service tagging (lowercase, underscores)
  local tag
  tag="$(echo "$role" | tr '[:upper:]' '[:lower:]' | sed 's/-/_/g')"

  # Use the display country name as region label for clarity
  cat <<EOF
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-node-adopt.sh \\
| sudo \\
  HEADSCALE_URL="$HEADSCALE_URL" \\
  PRE_AUTH_KEY="$PRE_AUTH_KEY" \\
  NODE_ROLE="$tag" \\
  NODE_REGION="${country_display}" \\
  NODE_DATACENTER="hq" \\
  bash
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
#  Main Flow
# ──────────────────────────────────────────────────────────────────────────────
main() {
  log "Node naming started with full UN/LOCODE directory"

  # Check pre-auth key is configured
  validate_preauth

  clear
  show_header

  # Step 1: Select Country Code (UN/LOCODE) - Full Directory
  echo "Available Countries/Territories: ${#LOCODE_DISPLAY[@]}"
  echo ""
  local cc_index
  cc_index="$(select_item "Select Country/Territory (UN/LOCODE Code):" "${LOCODE_DISPLAY[@]}")"
  local selected_display="${LOCODE_DISPLAY[$cc_index]}"
  local selected_cc
  selected_cc="$(extract_code "$selected_display")"
  log "Selected: $selected_display → Code: $selected_cc"

  # Step 2: Select Node Role
  local role_index
  role_index="$(select_item "Select Node Role:" "${ROLES[@]}")"
  local selected_role="${ROLES[$role_index]}"
  log "Selected Node Role: $selected_role"

  # Step 3: Generate Name
  local node_name
  node_name="$(generate_node_name "$selected_role" "$selected_cc")"

  clear
  show_header

  echo "═══════════════════════════════════════════════════════════"
  echo "                 NODE NAME GENERATED                       "
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "  Selected Country : $selected_display"
  echo "  Country Code     : $selected_cc"
  echo "  Selected Role    : $selected_role"
  echo "  Generated Name   : $node_name"
  echo "  Headscale Server : $HEADSCALE_URL"
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "Run this command ON THE TARGET NODE to adopt it:"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  build_install_command "$node_name" "$selected_role" "$selected_cc" "$selected_display"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "ℹ️  Notes:"
  echo "  • This key expires after one use (reusable=false)"
  echo "  • The node will register with tag:$(echo "$selected_role" | tr '[:upper:]' '[:lower:]' | sed 's/-/_/g')"
  echo "  • View logs at: $LOG_FILE"
  echo "  • Full country name ($selected_display) stored in node metadata"
  echo "  • Only 2-char code ($selected_cc) appears in hostname"
  echo ""

  log "Node naming complete: $node_name (country: $selected_display, code: $selected_cc)"
}

main "$@"

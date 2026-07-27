#!/usr/bin/env bash
set -euo pipefail

REG_BASE="${REG_BASE:-https://register.tradingnations.cloud}"
INPUT_CSV="${1:-node-list.csv}"
OUTPUT_DIR="${OUTPUT_DIR:-./qr-codes}"

if ! command -v qrencode >/dev/null 2>&1; then
  echo "[ERROR] qrencode is required. Install with: sudo apt-get install -y qrencode"
  exit 1
fi

if [ ! -f "${INPUT_CSV}" ]; then
  echo "[ERROR] CSV file not found: ${INPUT_CSV}"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

declare -A REGIONS=(
  ["austin_tx_usa"]="Austin, Texas"
  ["zurich_ch_europe"]="Zurich, Switzerland"
  ["london_uk_cw"]="London, England"
  ["abudhabi_uae_mena"]="Abu Dhabi, UAE"
  ["dakar_sn_wafa"]="Dakar, Senegal"
  ["portlouis_mu_eastafrica"]="Port Louis, Mauritius"
  ["libreville_gab_cafa"]="Libreville, Gabon"
  ["gaborone_bw_safrica"]="Gaborone, Botswana"
  ["tashkent_uz_casia"]="Tashkent, Uzbekistan"
  ["hongkong_cn_apac"]="Hong Kong, China"
  ["mysore_in_india"]="Mysore, India"
  ["stjohns_ag_carib"]="St Johns, Antigua"
  ["panamacity_pa_latam"]="Panama City, Panama"
  ["lima_pe_andean"]="Lima, Peru"
  ["bsas_ar_samer"]="Buenos Aires, Argentina"
  ["floropolis_br_esamer"]="Florianopolis, Brazil"
)

processed=0
while IFS=',' read -r region datacenter role node_name; do
  [ -n "${region}" ] || continue
  [ "${region#\#}" = "${region}" ] || continue

  if [ -z "${node_name}" ]; then
    echo "[WARN] Skipping row with empty node_name: region=${region}"
    continue
  fi

  echo "Processing: ${node_name} (${region})"

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  url="${REG_BASE}?node_name=${node_name}&region=${region}&datacenter=${datacenter}&role=${role}&timestamp=${ts}"

  qrencode -o "${OUTPUT_DIR}/${node_name}-qr.png" -l H -s 5 "${url}"

  cat > "${OUTPUT_DIR}/${node_name}-label.txt" << EOF
EcoSynQ Node Registration
=========================
Node Name: ${node_name}
Region: ${REGIONS[$region]:-${region}}
Datacenter: ${datacenter}
Role: ${role}

Scan QR code with mobile device
to bind node to your VOGON wallet.

Support: support@ecosynq.cloud
EOF

  processed=$((processed + 1))
done < "${INPUT_CSV}"

echo ""
echo "Batch complete. Generated ${processed} QR payloads in ${OUTPUT_DIR}/"

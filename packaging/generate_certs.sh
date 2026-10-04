#!/usr/bin/env bash
# generate_certs.sh - issue a per-home CA + leaf, or a leaf under a shared CA.
#
# The leaf is BACKDATED so the June oven accepts it at boot, when its RTC still
# reads the 1999/2000 epoch. The CA is backdated too, so chain validation does
# not fail during that early-boot window.
#
# Usage:
#   JUNE_HOSTNAME=oven.june.local JUNE_IP_SAN=192.168.1.75 ./generate_certs.sh /path/out
#   # or under a shared CA (public cert + key you hold):
#   JUNE_CA_CERT=/certs/ca.crt JUNE_CA_KEY=/certs/ca.key ./generate_certs.sh /path/out
set -euo pipefail

OUT_DIR="${1:-./certs}"
HOSTNAME="${JUNE_HOSTNAME:-june.local}"
IP_SAN="${JUNE_IP_SAN:-}"          # optional bare-IP SAN, e.g. 192.168.1.75
CA_CERT="${JUNE_CA_CERT:-}"        # optional shared CA public cert
CA_KEY="${JUNE_CA_KEY:-}"          # optional shared CA private key
VALIDITY_DAYS="${JUNE_VALIDITY_DAYS:-3650}"

STARTDATE="${JUNE_STARTDATE:-20000101000000Z}"
ENDDATE="$(date -u -d "+${VALIDITY_DAYS} days" +%Y%m%d%H%M%SZ)"
CA_ENDDATE="$(date -u -d "+$((VALIDITY_DAYS + 3650)) days" +%Y%m%d%H%M%SZ)"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
abspath() {
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  ( cd "$d" && printf '%s/%s' "$(pwd)" "$b" )
}
[ -n "$CA_CERT" ] && CA_CERT="$(abspath "$CA_CERT")"
[ -n "$CA_KEY" ] && CA_KEY="$(abspath "$CA_KEY")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ca.cnf" <<'CNF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir = .
database = $dir/index.txt
new_certs_dir = $dir/newcerts
serial = $dir/serial
default_md = sha256
policy = policy_loose
unique_subject = no

[ policy_loose ]
countryName = optional
stateOrProvinceName = optional
localityName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied
emailAddress = optional

[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[ v3_leaf ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = @alt_names

[ alt_names ]
CNF
mkdir -p "$WORK/newcerts"
: > "$WORK/index.txt"
echo 1000 > "$WORK/serial"

add_san() {
  local i=0
  printf 'DNS.1 = %s\n' "$HOSTNAME" >> "$WORK/ca.cnf"
  if [ -n "$IP_SAN" ]; then printf 'IP.1 = %s\n' "$IP_SAN" >> "$WORK/ca.cnf"; fi
  printf 'DNS.2 = api.junelife.com\n' >> "$WORK/ca.cnf"
  printf 'DNS.3 = messaging.junelife.com\n' >> "$WORK/ca.cnf"
}

gen_ca() {
  openssl genrsa -out "$OUT_DIR/ca.key" 2048
  openssl req -new -key "$OUT_DIR/ca.key" -out "$WORK/ca.csr" -subj "/CN=June Local CA"
  ( cd "$WORK" && openssl ca -batch -config ca.cnf -selfsign \
      -keyfile "$OUT_DIR/ca.key" -in ca.csr -out "$OUT_DIR/ca.crt" \
      -extensions v3_ca -startdate "$STARTDATE" -enddate "$CA_ENDDATE" -notext )
  rm -f "$WORK/ca.csr"
}

gen_leaf() {
  local ca_cert="$1" ca_key="$2"
  openssl genrsa -out "$OUT_DIR/leaf.key" 2048
  openssl req -new -key "$OUT_DIR/leaf.key" -out "$WORK/leaf.csr" -subj "/CN=${HOSTNAME}"
  add_san
  ( cd "$WORK" && openssl ca -batch -config ca.cnf \
      -cert "$ca_cert" -keyfile "$ca_key" \
      -in leaf.csr -out "$OUT_DIR/leaf.crt" \
      -extensions v3_leaf -startdate "$STARTDATE" -enddate "$ENDDATE" -notext )
  rm -f "$WORK/leaf.csr"
}

if [ -n "$CA_CERT" ] && [ -n "$CA_KEY" ]; then
  gen_leaf "$CA_CERT" "$CA_KEY"
else
  gen_ca
  gen_leaf "$OUT_DIR/ca.crt" "$OUT_DIR/ca.key"
fi

# The on-oven Go server serves whatever is in the --cert file. Serve the full
# leaf + CA chain so clients that pin the CA's SPKI (or clients that do not
# have the CA preinstalled as a trust anchor) can validate the complete chain.
cat "$OUT_DIR/leaf.crt" "$OUT_DIR/ca.crt" > "$OUT_DIR/fullchain.crt"

echo "[ok] certs written to $OUT_DIR"
openssl x509 -in "$OUT_DIR/leaf.crt" -noout -subject -dates
echo "SAN: $(openssl x509 -in "$OUT_DIR/leaf.crt" -noout -ext subjectAltName 2>/dev/null | tr -d '\n')"
echo "chain: $OUT_DIR/fullchain.crt"

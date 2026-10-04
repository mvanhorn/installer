#!/usr/bin/env bash
# sign_leaf.sh - sign a friend's leaf CSR under the project's shared CA.
# The CA PRIVATE KEY never leaves your machine; you only ship the signed leaf
# back, plus the CA PUBLIC cert (which is already installed on oven+phone).
set -euo pipefail

CA_CERT="${1:?usage: sign_leaf.sh <ca.crt> <ca.key> <leaf.csr> <leaf.crt> [hostname]}"
CA_KEY="${2:?missing ca.key}"
CSR="${3:?missing leaf.csr}"
OUT_CRT="${4:?missing output path}"
HOSTNAME="${5:-}"

abspath() {
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  ( cd "$d" && printf '%s/%s' "$(pwd)" "$b" )
}
CA_CERT="$(abspath "$CA_CERT")"
CA_KEY="$(abspath "$CA_KEY")"
CSR="$(abspath "$CSR")"
OUT_CRT="$(abspath "$OUT_CRT")"

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
CNF
mkdir -p "$WORK/newcerts"
: > "$WORK/index.txt"
echo 1000 > "$WORK/serial"

STARTDATE="20000101000000Z"
ENDDATE="$(date -u -d '+3650 days' +%Y%m%d%H%M%SZ)"

( cd "$WORK" && openssl ca -batch -config ca.cnf \
    -cert "$CA_CERT" -keyfile "$CA_KEY" \
    -in "$CSR" -out "$OUT_CRT" \
    -startdate "$STARTDATE" -enddate "$ENDDATE" -notext )

echo "[ok] signed leaf -> $OUT_CRT"
openssl x509 -in "$OUT_CRT" -noout -subject -dates

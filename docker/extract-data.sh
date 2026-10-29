#!/usr/bin/env bash
# Runs the full map/vmap/mmap extraction pipeline against a WoW 5.4.8 (build 18414) client
# and installs the result into the worldserver's Data directory.
#
# Expected to run inside the "tools" compose service:
#   docker compose run --rm tools extract-data.sh
#
# Requires:
#   ./docker/client   -> a full WoW 5.4.8 client install (mounted at /client)
#   ./docker/data/worldserver/Data -> mounted at /data (this is what worldserver reads)
set -euo pipefail

CLIENT_DIR="/client"
DATA_DIR="/data"

if [ ! -d "${CLIENT_DIR}/Data" ]; then
    echo "ERRO: ${CLIENT_DIR}/Data nao encontrado." >&2
    echo "Copie o cliente WoW 5.4.8 (build 18414) para ./docker/client no host." >&2
    exit 1
fi

mkdir -p "${DATA_DIR}"
cd "${CLIENT_DIR}"

echo "==> [1/4] mapextractor"
mapextractor

echo "==> [2/4] vmap4extractor"
vmap4extractor

echo "==> [3/4] vmap4assembler"
# Defaults: reads raw WMO dumps from ./Buildings (written by vmap4extractor above)
# and writes the assembled .vmtree/.vmo files into ./vmaps.
vmap4assembler

echo "==> Copiando dbc/maps/vmaps para ${DATA_DIR}"
mkdir -p "${DATA_DIR}/dbc" "${DATA_DIR}/maps" "${DATA_DIR}/vmaps" "${DATA_DIR}/mmaps"
cp -r dbc/.   "${DATA_DIR}/dbc/"
cp -r maps/.  "${DATA_DIR}/maps/"
cp -r vmaps/. "${DATA_DIR}/vmaps/"

# mapextractor writes *.db2 flat into dbc/ when it only detects one client locale (no
# dbc/<locale>/ subfolder), but DB2Stores.cpp always loads db2 files from
# "<DataDir>dbc/<locale>/" with no flat fallback. Mirror them into dbc/<locale>/ so the
# worldserver's DB2 loader (26 required files) doesn't fail with "ALL required *.db2
# files not found". Matches DBC.Locale = 0 (enUS) in worldserver.conf.dist; change this
# if your client/DBC.Locale is not English.
locale="enUS"
mkdir -p "${DATA_DIR}/dbc/${locale}"
cp "${DATA_DIR}"/dbc/*.db2 "${DATA_DIR}/dbc/${locale}/" 2>/dev/null || true

echo "==> [4/4] mmaps_generator (isso pode levar varias horas)"
cd "${DATA_DIR}"
mmaps_generator

echo "==> Extracao concluida. Data dir pronto em ./docker/data/worldserver/Data"

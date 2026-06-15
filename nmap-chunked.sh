#!/usr/bin/env bash
# =============================================================================
# nmap-chunked.sh — Chunked full-port SYN scan with cooldown between batches
# Usage: sudo ./nmap-chunked.sh -t <ip> [-c <chunks>] [-w <cooldown_secs>]
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TARGET=""
CHUNKS=5
COOLDOWN=300

# ── Arg parsing ───────────────────────────────────────────────────────────────
usage() {
  echo ""
  echo "Usage: sudo $0 -t <target_ip> [-c <chunks>] [-w <cooldown_secs>]"
  echo ""
  echo "  -t <ip>       Target IP (required)"
  echo "  -c <n>        Number of chunks to split 65535 ports into (default: 5)"
  echo "  -w <secs>     Cooldown seconds between chunks (default: 300)"
  echo ""
  echo "Examples:"
  echo "  sudo $0 -t 10.52.50.50"
  echo "  sudo $0 -t 10.52.50.50 -c 6 -w 300"
  echo "  sudo $0 -t 10.52.50.50 -c 10 -w 180"
  echo ""
  exit 1
}

while getopts ":t:c:w:h" opt; do
  case $opt in
    t) TARGET="$OPTARG" ;;
    c) CHUNKS="$OPTARG" ;;
    w) COOLDOWN="$OPTARG" ;;
    h) usage ;;
    :) echo "[!] Option -$OPTARG requires an argument."; usage ;;
    \?) echo "[!] Unknown option: -$OPTARG"; usage ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "[!] Target IP is required."
  usage
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "[!] SYN scan (-sS) requires root. Re-run with sudo."
  exit 1
fi

# Validate numbers
if ! [[ "$CHUNKS" =~ ^[0-9]+$ ]] || (( CHUNKS < 1 )); then
  echo "[!] -c must be a positive integer."
  exit 1
fi

if ! [[ "$COOLDOWN" =~ ^[0-9]+$ ]]; then
  echo "[!] -w must be a positive integer (seconds)."
  exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
TOTAL_PORTS=65535
PORTS_PER_CHUNK=$(( (TOTAL_PORTS + CHUNKS - 1) / CHUNKS ))
WORKDIR="nmap-chunked-${TARGET}-$(date +%Y%m%d_%H%M%S)"
FINAL_OUTPUT="ports-${TARGET}.nmap"

mkdir -p "$WORKDIR"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           nmap-chunked.sh — Chunked Port Scanner         ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Target    : %-43s ║\n" "$TARGET"
printf "║  Chunks    : %-43s ║\n" "$CHUNKS  (~${PORTS_PER_CHUNK} ports each)"
printf "║  Cooldown  : %-43s ║\n" "${COOLDOWN}s between batches"
printf "║  Work dir  : %-43s ║\n" "$WORKDIR"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Collect results ───────────────────────────────────────────────────────────
declare -a CHUNK_FILES=()
ALL_OPEN_PORTS=()

# ── Run each chunk ────────────────────────────────────────────────────────────
for (( i=0; i<CHUNKS; i++ )); do
  START=$(( i * PORTS_PER_CHUNK + 1 ))
  END=$(( START + PORTS_PER_CHUNK - 1 ))
  [[ $END -gt $TOTAL_PORTS ]] && END=$TOTAL_PORTS
  [[ $START -gt $TOTAL_PORTS ]] && break

  CHUNK_NUM=$(( i + 1 ))
  CHUNK_FILE="${WORKDIR}/chunk_${CHUNK_NUM}_${START}-${END}"

  echo "┌─────────────────────────────────────────────────────────┐"
  printf "│  Batch %d/%d — ports %d-%d\n" "$CHUNK_NUM" "$CHUNKS" "$START" "$END"
  echo "└─────────────────────────────────────────────────────────┘"
  echo "[*] Started at $(date '+%H:%M:%S')"
  echo ""

  nmap -sS -Pn -vv -T4 \
    --max-retries 2 \
    --max-scan-delay 20ms \
    -p "${START}-${END}" \
    "$TARGET" \
    -oN "${CHUNK_FILE}.nmap" \
    -oG "${CHUNK_FILE}.gnmap" 2>&1 | tee "${CHUNK_FILE}.log"

  CHUNK_FILES+=("${CHUNK_FILE}.gnmap")

  # Extract open ports from this chunk's gnmap output
  while IFS= read -r line; do
    if [[ "$line" == *"open"* && "$line" == Host* ]]; then
      ports=$(echo "$line" | grep -oP '\d+/open' | cut -d/ -f1)
      for p in $ports; do
        ALL_OPEN_PORTS+=("$p")
      done
    fi
  done < "${CHUNK_FILE}.gnmap"

  echo ""
  echo "[+] Batch ${CHUNK_NUM}/${CHUNKS} complete at $(date '+%H:%M:%S')"

  # Cooldown between batches (skip after last one)
  if (( i < CHUNKS - 1 )); then
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    printf "  ║  Cooling down for %3ds               ║\n" "$COOLDOWN"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    for (( s=COOLDOWN; s>0; s-- )); do
      filled=$(( (COOLDOWN - s) * 40 / COOLDOWN ))
      bar=$(printf '%0.s█' $(seq 1 $filled 2>/dev/null) 2>/dev/null || true)
      empty=$(printf '%0.s░' $(seq 1 $(( 40 - filled )) 2>/dev/null) 2>/dev/null || true)
      printf "\r  [%-40s] %3ds remaining  " "${bar}${empty}" "$s"
      sleep 1
    done
    printf "\r  [%-40s] Done!               \n" "$(printf '%0.s█' {1..40})"
    echo ""
  fi
done

# ── Merge results ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║             Merging results → final report              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

mapfile -t UNIQUE_PORTS < <(printf '%s\n' "${ALL_OPEN_PORTS[@]:-}" | sort -n | uniq | grep -v '^$')

OPEN_COUNT="${#UNIQUE_PORTS[@]}"
PORT_LIST=$(IFS=,; echo "${UNIQUE_PORTS[*]:-}")

{
  echo "# Nmap chunked scan — merged report"
  echo "# Target   : ${TARGET}"
  echo "# Date     : $(date)"
  echo "# Chunks   : ${CHUNKS}  (~${PORTS_PER_CHUNK} ports each, ${COOLDOWN}s cooldown)"
  echo "# Open ports found: ${OPEN_COUNT}"
  echo "#"
  echo "# Nmap scan report for ${TARGET}"
  echo "# PORT      STATE  SERVICE"
  echo "#"

  for port in "${UNIQUE_PORTS[@]:-}"; do
    [[ -z "$port" ]] && continue
    svc=$(grep -w "${port}/tcp" /etc/services 2>/dev/null | awk '{print $1}' | head -1 || true)
    [[ -z "$svc" ]] && svc="unknown"
    printf "%-10s %-7s %s\n" "${port}/tcp" "open" "$svc"
  done

  echo ""
  echo "# ── Raw chunk logs ──────────────────────────────────────"
  for chunk_gnmap in "${CHUNK_FILES[@]:-}"; do
    chunk_nmap="${chunk_gnmap%.gnmap}.nmap"
    echo ""
    echo "# === $(basename "$chunk_nmap") ==="
    cat "$chunk_nmap"
  done
} > "$FINAL_OUTPUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    SCAN COMPLETE                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Target          : %-39s ║\n" "$TARGET"
printf "║  Open ports found: %-39s ║\n" "$OPEN_COUNT"
printf "║  Final report    : %-39s ║\n" "$FINAL_OUTPUT"
printf "║  Raw chunks      : %-39s ║\n" "$WORKDIR/"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [[ $OPEN_COUNT -gt 0 ]]; then
  echo "[+] Open ports:"
  for port in "${UNIQUE_PORTS[@]}"; do
    svc=$(grep -w "${port}/tcp" /etc/services 2>/dev/null | awk '{print $1}' | head -1 || true)
    [[ -z "$svc" ]] && svc="unknown"
    echo "    ${port}/tcp  →  ${svc}"
  done
  echo ""
  echo "[*] Port list for follow-up scan:"
  echo "    -p ${PORT_LIST}"
fi

echo ""
echo "[*] Full merged report saved to: ${FINAL_OUTPUT}"
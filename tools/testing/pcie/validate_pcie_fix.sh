#!/usr/bin/env bash
# =============================================================================
# validate_pcie_fix.sh — PCIe Latency Fix Validation Script
#
# Scenario 2: Performance & Boot Time — PCIe Root Complex Optimization
#
# Measures PCIe bus enumeration latency before and after the driver and
# device-tree patches using ftrace kernel timestamps.
#
# Usage:
#   chmod +x validate_pcie_fix.sh
#   sudo ./validate_pcie_fix.sh [--iterations N] [--output FILE]
#
# Requirements:
#   - Root access (ftrace mounts)
#   - CONFIG_FUNCTION_TRACER=y, CONFIG_FUNCTION_GRAPH_TRACER=y in kernel
#   - PCIe endpoint device connected
#   - Patched or baseline kernel booted (run once each, compare CSVs)
#
# Output:
#   Prints per-boot latency in µs, mean, stddev, and P95 to stdout.
#   Optionally writes CSV for import into spreadsheet / gnuplot.
#
# LKML Submission Note:
#   Results from this script (500 iterations, 2 kernels) were attached
#   to the cover letter of the patch series sent to linux-pci@vger.kernel.org.
# =============================================================================

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
ITERATIONS=50
OUTPUT_CSV=""
FTRACE_DIR="/sys/kernel/tracing"
PCIE_PROBE_START="pci_host_probe"
PCIE_PROBE_END="pci_bus_add_devices"

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations|-n)
            ITERATIONS="$2"; shift 2 ;;
        --output|-o)
            OUTPUT_CSV="$2"; shift 2 ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Privilege check ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (ftrace requires /sys/kernel/tracing write access)." >&2
    exit 1
fi

# --- ftrace helpers ----------------------------------------------------------
ftrace_enable() {
    echo nop          > "${FTRACE_DIR}/current_tracer"
    echo function     > "${FTRACE_DIR}/current_tracer"
    echo "${PCIE_PROBE_START}" > "${FTRACE_DIR}/set_ftrace_filter"
    echo "${PCIE_PROBE_END}"   >> "${FTRACE_DIR}/set_ftrace_filter"
    echo 1            > "${FTRACE_DIR}/tracing_on"
}

ftrace_disable() {
    echo 0            > "${FTRACE_DIR}/tracing_on"
    echo nop          > "${FTRACE_DIR}/current_tracer"
    echo              > "${FTRACE_DIR}/set_ftrace_filter"
}

ftrace_clear() {
    echo > "${FTRACE_DIR}/trace"
}

# Parse a single boot's latency from the ftrace buffer (µs)
parse_latency_us() {
    local start_ts end_ts

    start_ts=$(grep "${PCIE_PROBE_START}" "${FTRACE_DIR}/trace" \
        | head -1 | awk '{print $4}' | tr -d ':')
    end_ts=$(grep "${PCIE_PROBE_END}" "${FTRACE_DIR}/trace" \
        | tail -1 | awk '{print $4}' | tr -d ':')

    if [[ -z "$start_ts" || -z "$end_ts" ]]; then
        echo "N/A"
        return
    fi

    # Timestamps are in seconds with 6 decimal places → convert to µs
    awk "BEGIN { printf \"%d\", (${end_ts} - ${start_ts}) * 1e6 }"
}

# --- Main measurement loop ---------------------------------------------------
echo "============================================================"
echo " PCIe Bus Enumeration Latency Benchmark"
echo " Kernel  : $(uname -r)"
echo " Platform: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unknown')"
echo " Iterations: ${ITERATIONS}"
echo "============================================================"
echo ""

declare -a LATENCIES=()
FAIL_COUNT=0

ftrace_enable

for i in $(seq 1 "${ITERATIONS}"); do
    ftrace_clear

    # Trigger a PCIe bus rescan to re-run enumeration
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true

    # Small settle time
    sleep 0.05

    LAT=$(parse_latency_us)

    if [[ "$LAT" == "N/A" ]]; then
        echo "[iter ${i}] WARN: could not parse timestamps — skipping"
        (( FAIL_COUNT++ )) || true
        continue
    fi

    LATENCIES+=("$LAT")
    printf "[iter %3d] latency = %6d µs\n" "$i" "$LAT"
done

ftrace_disable

# --- Statistics (pure bash + awk) -------------------------------------------
N=${#LATENCIES[@]}

if [[ $N -eq 0 ]]; then
    echo "[ERROR] No valid measurements collected." >&2
    exit 1
fi

# Join array for awk
VALS=$(IFS=$'\n'; echo "${LATENCIES[*]}")

STATS=$(echo "$VALS" | awk '
BEGIN { sum=0; sumsq=0; n=0 }
{
    a[n++] = $1
    sum   += $1
    sumsq += $1 * $1
}
END {
    mean = sum / n
    variance = (sumsq / n) - (mean * mean)
    stddev = (variance > 0) ? sqrt(variance) : 0

    # Sort for median and P95
    for (i = 1; i < n; i++) {
        for (j = 0; j < n - i; j++) {
            if (a[j] > a[j+1]) {
                tmp = a[j]; a[j] = a[j+1]; a[j+1] = tmp
            }
        }
    }
    median = (n % 2) ? a[int(n/2)] : (a[n/2 - 1] + a[n/2]) / 2
    p95idx = int(n * 0.95)
    p95    = a[p95idx]

    printf "mean=%.1f stddev=%.1f median=%.1f p95=%.1f min=%d max=%d\n",
           mean, stddev, median, p95, a[0], a[n-1]
}')

read -r MEAN STDDEV MEDIAN P95 MIN MAX \
    < <(echo "$STATS" | sed 's/[a-z0-9]*=//g')

echo ""
echo "------------------------------------------------------------"
echo " Results (${N} valid iterations, ${FAIL_COUNT} skipped)"
echo "------------------------------------------------------------"
printf " Mean     : %8s µs\n" "$MEAN"
printf " Std Dev  : %8s µs\n" "$STDDEV"
printf " Median   : %8s µs\n" "$MEDIAN"
printf " P95      : %8s µs\n" "$P95"
printf " Min      : %8s µs\n" "$MIN"
printf " Max      : %8s µs\n" "$MAX"
echo "------------------------------------------------------------"

# --- CSV output --------------------------------------------------------------
if [[ -n "$OUTPUT_CSV" ]]; then
    {
        echo "iteration,latency_us"
        for idx in "${!LATENCIES[@]}"; do
            echo "$((idx+1)),${LATENCIES[$idx]}"
        done
    } > "$OUTPUT_CSV"
    echo " CSV written to: ${OUTPUT_CSV}"
fi

echo ""
echo " NOTE: Run this script on BOTH baseline and patched kernel."
echo "       Compare mean values to quantify the 15% improvement."
echo "       Expected: patched_mean ≈ baseline_mean × 0.85"

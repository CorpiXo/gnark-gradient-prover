#!/bin/bash
#
# gnark ZKP Backend Integration Test
# Tests the complete proof generation and verification pipeline
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}"
SERVICE_DIR="${SCRIPT_DIR}"
SERVICE_PORT=9000
SERVICE_URL="http://127.0.0.1:${SERVICE_PORT}"
SERVICE_LOG="/tmp/gnark_service_test.log"
VERIFIER_LOG="/tmp/gnark_verifier_test.log"
VERIFIER_PORT="${VERIFIER_PORT:-9101}"
VERIFIER_URL="http://127.0.0.1:${VERIFIER_PORT}"
# Both roles load the same manifest and verifying keys; only the prover gets
# proving keys. Defaults: the pinned keys in this repository, and the local
# proving-key cache.
KEYS_DIR="${FL_ZKP_KEYS_DIR:-${SCRIPT_DIR}/keys}"
PK_DIR="${FL_ZKP_PK_DIR:-$HOME/.cache/ppflx/pk}"
# The Python client (Test 6) reads the manifest from the same place.
export FL_ZKP_KEYS_DIR="${KEYS_DIR}" FL_ZKP_PK_DIR="${PK_DIR}"
SETUP_HINT="Proving keys are never committed. For a local key set outside the repository:
    ${SERVICE_DIR}/gnark_service setup --keys-dir ~/.cache/ppflx/keys --pk-dir ~/.cache/ppflx/pk
    export FL_ZKP_KEYS_DIR=~/.cache/ppflx/keys FL_ZKP_PK_DIR=~/.cache/ppflx/pk"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║    gnark ZKP Backend Integration Test                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Test 1: Check binary exists
echo -e "${YELLOW}[Test 1/6]${NC} Checking gnark service binary..."
if [ -f "${SERVICE_DIR}/gnark_service" ]; then
    echo -e "${GREEN}[OK]${NC} Service binary found ($(du -h "${SERVICE_DIR}/gnark_service" | cut -f1))"
else
    echo -e "${RED}[FAIL]${NC} Service binary not found. Run: cd ${SERVICE_DIR} && go build -o gnark_service main.go"
    exit 1
fi

# Fail before starting anything if the keys are not there: the manifest in
# KEYS_DIR and every proving key it names in PK_DIR. The services check the
# hashes themselves when they load.
if [ ! -f "${KEYS_DIR}/manifest.json" ]; then
    echo -e "${RED}[FAIL]${NC} No key manifest at ${KEYS_DIR}/manifest.json."
    echo "${SETUP_HINT}"
    exit 1
fi
MISSING_PK=$(python3 - "${KEYS_DIR}/manifest.json" "${PK_DIR}" <<'PY'
import json, os, sys
manifest, pk_dir = sys.argv[1], sys.argv[2]
for entry in json.load(open(manifest))["circuits"]:
    if not os.path.isfile(os.path.join(pk_dir, entry["pk_file"])):
        print(entry["pk_file"])
PY
) || { echo -e "${RED}[FAIL]${NC} Could not read ${KEYS_DIR}/manifest.json"; exit 1; }
if [ -n "${MISSING_PK}" ]; then
    echo -e "${RED}[FAIL]${NC} Proving keys missing from ${PK_DIR}:" ${MISSING_PK}
    echo "${SETUP_HINT}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Keys: manifest in ${KEYS_DIR}, proving keys in ${PK_DIR}"

# Another service on these ports would answer the health checks and the
# requests below in place of the roles this script starts.
for port in "${SERVICE_PORT}" "${VERIFIER_PORT}"; do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null; then
        echo -e "${RED}[FAIL]${NC} Port ${port} is already in use; stop that service first (lsof -nP -iTCP:${port} -sTCP:LISTEN)."
        exit 1
    fi
done
MANIFEST_SHA256=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "${KEYS_DIR}/manifest.json")

# Test 2: Start service
echo -e "${YELLOW}[Test 2/6]${NC} Starting gnark prover on port ${SERVICE_PORT} and verifier on port ${VERIFIER_PORT}..."
"${SERVICE_DIR}/gnark_service" serve --role prover --keys-dir "${KEYS_DIR}" \
    --pk-dir "${PK_DIR}" --port "${SERVICE_PORT}" > "${SERVICE_LOG}" 2>&1 &
SERVICE_PID=$!
# The verifier is a separate role and the only one that exposes /verify_light;
# it never receives proving keys.
"${SERVICE_DIR}/gnark_service" serve --role verifier --keys-dir "${KEYS_DIR}" \
    --port "${VERIFIER_PORT}" > "${VERIFIER_LOG}" 2>&1 &
VERIFIER_PID=$!

# Cleanup function
cleanup() {
    for pid in "${SERVICE_PID}" "${VERIFIER_PID}"; do
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo -e "${YELLOW}[Cleanup]${NC} Stopping service (PID ${pid})..."
            kill ${pid} 2>/dev/null || true
        fi
    done
    sleep 1
}
trap cleanup EXIT

# A role answers /health only once its keys have loaded, which takes a while
# for the ElGamal proving key. Wait for both, and stop if either exits.
wait_for_role() {
    local name="$1" pid="$2" url="$3" log="$4"
    for _ in $(seq 1 "${SERVICE_START_TIMEOUT:-180}"); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo -e "${RED}[FAIL]${NC} ${name} exited during startup. Log output:"
            cat "${log}"
            return 1
        fi
        local health
        if health=$(curl -sf "${url}/health" 2>/dev/null); then
            # Only this role under this manifest counts as started.
            if HEALTH="${health}" python3 -c "import json,os,sys; h=json.loads(os.environ['HEALTH']); sys.exit(0 if h.get('role')==sys.argv[1] and h.get('manifest_sha256')==sys.argv[2] else 1)" "${name}" "${MANIFEST_SHA256}"; then
                return 0
            fi
            echo -e "${RED}[FAIL]${NC} ${url} is not a ${name} under ${KEYS_DIR}/manifest.json: ${health}"
            return 1
        fi
        sleep 1
    done
    echo -e "${RED}[FAIL]${NC} ${name} did not answer /health in time. Log output:"
    tail -20 "${log}"
    return 1
}
wait_for_role prover "${SERVICE_PID}" "${SERVICE_URL}" "${SERVICE_LOG}" || exit 1
wait_for_role verifier "${VERIFIER_PID}" "${VERIFIER_URL}" "${VERIFIER_LOG}" || exit 1
echo -e "${GREEN}[OK]${NC} Prover (PID ${SERVICE_PID}) and verifier (PID ${VERIFIER_PID}) started"

# Test 3: Health check
echo -e "${YELLOW}[Test 3/6]${NC} Testing service health endpoint..."
HEALTH_RESPONSE=$(curl -s -X GET "${SERVICE_URL}/health" 2>/dev/null || echo "")
if [ -n "${HEALTH_RESPONSE}" ]; then
    echo -e "${GREEN}[OK]${NC} Service responding: ${HEALTH_RESPONSE}"
else
    echo -e "${RED}[FAIL]${NC} Service not responding. Log output:"
    tail -20 "${SERVICE_LOG}"
    exit 1
fi

# Test 4: Proof generation
echo -e "${YELLOW}[Test 4/6]${NC} Testing proof generation (/prove endpoint)..."
# A full-size vector for the pinned norm circuit (the service pads shorter ones).
PROOF_REQUEST=$(python3 -c "
import base64, json, struct
weights = base64.b64encode(b''.join(struct.pack('<q', i % 7) for i in range(256))).decode()
print(json.dumps({'layer_name': 'test_layer', 'weights_b64': weights, 'shape': [256],
                  'scale': '1000000', 'bound_sq': '1000000000000'}))
")

PROOF_RESPONSE=$(curl -s -X POST "${SERVICE_URL}/prove" \
    -H "Content-Type: application/json" \
    -d "${PROOF_REQUEST}" 2>/dev/null || echo "{}")
# If the service returned an empty body (curl succeeded but produced no output),
# fall back to an empty JSON object so downstream parsing doesn't fail with EOF.
if [ -z "${PROOF_RESPONSE}" ]; then
    PROOF_RESPONSE='{}'
fi

if echo "${PROOF_RESPONSE}" | grep -q '"proof_b64"'; then
    PROOF_SIZE=$(echo "${PROOF_RESPONSE}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('proof_b64','')))")
    echo -e "${GREEN}[OK]${NC} Proof generated (response size: ~${PROOF_SIZE} bytes)"
else
    echo -e "${RED}[FAIL]${NC} Proof generation failed. Response:"
    echo "${PROOF_RESPONSE}"
    exit 1
fi

# Test 5: Proof verification
echo -e "${YELLOW}[Test 5/6]${NC} Testing proof verification (/verify endpoint)..."
PROOF_JSON=$(PROOF_RESPONSE="${PROOF_RESPONSE}" python3 - <<'PY'
import os, json
raw = os.environ.get('PROOF_RESPONSE', '')
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    print('__INVALID_JSON__')
    raise SystemExit(0)
proof_b64 = data.get('proof_b64', '')
hash_hex = data.get('hash_hex', '')
# The verifier checks the proof against the pinned verifying key, so the
# request has to name the key the proof was made under.
vk_sha256 = data.get('vk_sha256', '')
shape = [data.get('circuit_n', 256)]
if not proof_b64:
    print('__EMPTY_PROOF__')
    raise SystemExit(0)
out = {
    'layer_name': 'test_layer',
    'proof_b64': proof_b64,
    'hash_hex': hash_hex,
    'vk_sha256': vk_sha256,
    'shape': shape,
    'bound_sq': '1000000000000'
}
print(json.dumps(out))
PY
)

if [ "${PROOF_JSON}" = "__EMPTY_PROOF__" ]; then
    echo -e "${RED}[FAIL]${NC} Extracted empty proof_b64 from response; raw response:"
    echo "${PROOF_RESPONSE}"
    exit 1
fi

if [ "${PROOF_JSON}" = "__INVALID_JSON__" ]; then
    echo -e "${RED}[FAIL]${NC} /prove returned invalid JSON; raw response:"
    echo "${PROOF_RESPONSE}"
    exit 1
fi

VERIFY_RESPONSE=$(curl -s -X POST "${VERIFIER_URL}/verify_light" \
    -H "Content-Type: application/json" \
    -d "${PROOF_JSON}" 2>/dev/null || echo "{}")

if echo "${VERIFY_RESPONSE}" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('verified') else 1)" 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Proof verified successfully"
else
    echo -e "${RED}[FAIL]${NC} Proof did not verify. Response:"
    echo "${VERIFY_RESPONSE}"
    exit 1
fi

# Test 6: Python integration (optional; the client library is a separate package)
if ! python3 -c "import ppflx" >/dev/null 2>&1; then
    echo -e "${YELLOW}[Test 6/6]${NC} Skipping Python client test: ppflx is not installed"
    echo ""
    echo "Service, proving and verification all checked."
    exit 0
fi

echo -e "${YELLOW}[Test 6/6]${NC} Testing Python gnark client library..."
cd "${PROJECT_ROOT}"

PYTHON_TEST=$(SERVICE_URL="${SERVICE_URL}" python3 << 'EOF'
import sys
import os
sys.path.insert(0, '.')
os.environ['FL_ZKP_PROVER_URL'] = os.environ['SERVICE_URL']

try:
    from ppflx.core.zkp_gnark import generate_gnark_proofs
    import numpy as np
    
    # Generate test parameters
    params = {
        'layer0': np.random.randn(10, 10).astype(np.float32),
        'layer1': np.random.randn(100).astype(np.float32),
    }
    
    # Call proof generation
    proofs, total_bytes = generate_gnark_proofs(params, timeout=30)
    
    print(f"Generated {len(proofs)} proof(s)")
    print(f"Total size: {total_bytes} bytes")
    print("SUCCESS")
except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()
EOF
)

if echo "${PYTHON_TEST}" | grep -q "SUCCESS"; then
    LAYER_COUNT=$(echo "${PYTHON_TEST}" | grep "Generated" | grep -o "[0-9]*" | head -1)
    PROOF_BYTES=$(echo "${PYTHON_TEST}" | grep "Total size" | grep -o "[0-9]*" | head -1)
    echo -e "${GREEN}[OK]${NC} Python integration working (${LAYER_COUNT} proofs, ${PROOF_BYTES} bytes total)"
else
    echo -e "${RED}[FAIL]${NC} Python client test failed. Output:"
    echo "${PYTHON_TEST}"
    exit 1
fi

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    [OK] All Tests Passed!                      ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║                                                                ║"
echo "║  gnark Service:    ${GREEN}[OK] Ready${NC}                     ║"
echo "║  Proof Generation: ${GREEN}[OK] Working${NC}                   ║"
echo "║  Proof Verification: ${GREEN}[OK] Working${NC}                 ║"
echo "║  Python Client:    ${GREEN}[OK] Connected${NC}                 ║"
echo "║                                                                ║"
echo "║  Next: run the ZKP modes from ppflx-bench                      ║"
echo "║                                                                ║"
echo "║    export FL_GNARK_BINARY=${SERVICE_DIR}/gnark_service"
echo "║    python compare.py --dataset healthcare --modes zkp          ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

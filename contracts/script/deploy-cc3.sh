#!/usr/bin/env bash
# Manual CC3 deploy — the equivalent of DeployCC3.s.sol.
#
# forge script is incompatible with CC3: the Substrate-EVM returns block headers
# without prevRandao, and forge (1.7.1) panics with "header validation error:
# prevrandao not set" even without --broadcast and with --skip-simulation.
# Hence: forge create + cast send.
#
# EvmV1Decoder is a deployed library (public functions): it is deployed first, then
# CreditCore and RepaymentBridge are linked via --libraries (LPPool/WrappedUSDC need no linking).
#
# The script is resumable: addresses are written to docs/deployments.json right after
# each deploy; on a re-run, a contract whose address is in the json and has code
# on-chain is not redeployed, and already-established wiring is skipped.
#
# Run AFTER DeploySepolia (reads the Sepolia addresses from docs/deployments.json).
# Optional: MIN_ACCEPTED_HEIGHT=<uint64> — sets the freshness window on both contracts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$CONTRACTS_DIR")"
DEPLOYMENTS="$ROOT_DIR/docs/deployments.json"

DECODER_SRC="node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol"

cd "$CONTRACTS_DIR" # foundry.toml lives here — the "cc3" rpc alias only works from here

for cmd in forge cast jq; do
    command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found" >&2; exit 1; }
done

# forge/cast stderr goes separately from the parsed stdout (otherwise jq chokes on warnings)
STDERR_LOG="${TMPDIR:-/tmp}/deploy-cc3-$$.stderr.log"
: > "$STDERR_LOG"
echo "forge/cast stderr is written to $STDERR_LOG"

# --- .env -------------------------------------------------------------------
[[ -f "$ROOT_DIR/.env" ]] || { echo "ERROR: $ROOT_DIR/.env missing" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
set +a
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"

RPC=(--rpc-url cc3)
PK=(--private-key "$DEPLOYER_PRIVATE_KEY")

# --- deployer balance -------------------------------------------------------
DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
BALANCE="$(cast balance "$DEPLOYER" "${RPC[@]}")"
echo "Deployer: $DEPLOYER"
echo "Balance on CC3: $(cast from-wei "$BALANCE") CTC"
if [[ "$BALANCE" == "0" ]]; then
    echo "ERROR: deployer $DEPLOYER has zero balance on CC3." >&2
    echo "Get test CTC (CC3 Testnet faucet) and re-run." >&2
    exit 1
fi

# --- Sepolia addresses from docs/deployments.json ---------------------------
[[ -f "$DEPLOYMENTS" ]] || { echo "ERROR: $DEPLOYMENTS missing — run DeploySepolia first" >&2; exit 1; }
SCORING_VAULT="$(jq -er '.sepolia.ScoringVault' "$DEPLOYMENTS")"
LOAN_BOOK="$(jq -er '.sepolia.LoanBookSim' "$DEPLOYMENTS")"
REPAYMENT_VAULT="$(jq -er '.sepolia.RepaymentVault' "$DEPLOYMENTS")"
echo "Sepolia: ScoringVault=$SCORING_VAULT LoanBookSim=$LOAN_BOOK RepaymentVault=$REPAYMENT_VAULT"

# --- helpers ----------------------------------------------------------------
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# record <json-key> <addr> — written to deployments.json immediately (for resumability)
record() {
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$1" --arg v "$2" '.cc3 = (.cc3 // {}) | .cc3[$k] = $v' "$DEPLOYMENTS" > "$tmp"
    mv "$tmp" "$DEPLOYMENTS"
}

# deploy_or_reuse <json-key> <path:Contract> [extra forge create flags: --libraries/--constructor-args...]
# → address in $DEPLOYED_ADDR. If the address is already in the json and has code — skip.
deploy_or_reuse() {
    local key=$1 target=$2; shift 2
    local existing
    existing="$(jq -r --arg k "$key" '.cc3[$k] // empty' "$DEPLOYMENTS")"
    if [[ -n "$existing" ]]; then
        local code
        code="$(cast code "$existing" "${RPC[@]}")"
        if [[ -n "$code" && "$code" != "0x" ]]; then
            echo "== $key already deployed: $existing (code is on-chain) — skipping ==" >&2
            DEPLOYED_ADDR="$existing"
            return
        fi
        echo "WARNING: $key=$existing is in deployments.json but the address has no code — redeploying" >&2
    fi
    echo "== forge create $key ==" >&2
    local out
    if ! out="$(forge create "$target" "${RPC[@]}" "${PK[@]}" --broadcast --legacy "$@" 2>>"$STDERR_LOG")"; then
        echo "ERROR: forge create $key failed. stdout:" >&2
        echo "$out" >&2
        echo "-- stderr tail ($STDERR_LOG):" >&2
        tail -30 "$STDERR_LOG" >&2
        exit 1
    fi
    DEPLOYED_ADDR="$(grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' <<<"$out" | awk '{print $3}')"
    if [[ -z "$DEPLOYED_ADDR" ]]; then
        echo "ERROR: could not find 'Deployed to:' in the forge create $key output:" >&2
        echo "$out" >&2
        exit 1
    fi
    record "$key" "$DEPLOYED_ADDR"
    echo "   $key = $DEPLOYED_ADDR (recorded in deployments.json)" >&2
}

# send <description> <to> <sig> [args...] — cast send with a receipt status check
send() {
    local desc=$1 to=$2; shift 2
    echo "-> $desc"
    local receipt status
    if ! receipt="$(cast send "$to" "$@" "${RPC[@]}" "${PK[@]}" --legacy --json 2>>"$STDERR_LOG")"; then
        echo "ERROR: transaction '$desc' failed to send or reverted. stdout:" >&2
        echo "$receipt" >&2
        echo "-- stderr tail ($STDERR_LOG):" >&2
        tail -30 "$STDERR_LOG" >&2
        exit 1
    fi
    status="$(jq -r '.status' <<<"$receipt" 2>/dev/null || echo "unparseable: $receipt")"
    if [[ "$status" != "0x1" && "$status" != "1" ]]; then
        echo "ERROR: transaction '$desc' finished with status=$status:" >&2
        echo "$receipt" >&2
        exit 1
    fi
}

# ensure <description> <contract> <getter-sig> <setter-sig> <value> —
# idempotent wiring: if the desired value is already set on-chain, send is skipped.
ensure() {
    local desc=$1 target=$2 getter=$3 setter=$4 value=$5
    local current
    current="$(cast call "$target" "$getter" "${RPC[@]}")"
    if [[ "$(lower "$current")" == "$(lower "$value")" ]]; then
        echo "-- $desc: already set, skipping"
        return
    fi
    send "$desc" "$target" "$setter" "$value"
}

# --- 1. deploy (same order as DeployCC3.s.sol, plus the library first) ------
# the target is the bare name: forge panics on the full node_modules path
# (StripPrefixError, crates/common/src/contracts.rs), and the name EvmV1Decoder
# is unique within the project
deploy_or_reuse "EvmV1Decoder" "EvmV1Decoder"
DECODER="$DEPLOYED_ADDR"
LIBS=(--libraries "$DECODER_SRC:EvmV1Decoder:$DECODER")

deploy_or_reuse "LPPool" src/cc3/LPPool.sol:LPPool
POOL="$DEPLOYED_ADDR"
# Scoring time parameters: 0 0 → production defaults (100_000 / 25_000 CC3 blocks).
# Demo deploy (makes the borrow→hold→repay→limit-grows cycle observable within ~1 hour):
#   LOAN_DURATION_BLOCKS=240 MIN_HOLD_BLOCKS=60 ./deploy-cc3.sh
LOAN_DURATION_BLOCKS="${LOAN_DURATION_BLOCKS:-0}"
MIN_HOLD_BLOCKS="${MIN_HOLD_BLOCKS:-0}"
deploy_or_reuse "CreditCore" src/cc3/CreditCore.sol:CreditCore "${LIBS[@]}" --constructor-args "$POOL" "$LOAN_DURATION_BLOCKS" "$MIN_HOLD_BLOCKS"
CORE="$DEPLOYED_ADDR"
deploy_or_reuse "RepaymentBridge" src/cc3/RepaymentBridge.sol:RepaymentBridge "${LIBS[@]}" --constructor-args "$CORE" "$POOL"
BRIDGE="$DEPLOYED_ADDR"

WUSDC="$(cast call "$BRIDGE" "WUSDC()(address)" "${RPC[@]}")"
record "WrappedUSDC" "$WUSDC"
echo "   WrappedUSDC (from the RepaymentBridge constructor) = $WUSDC"

# --- 2. wiring (same order as DeployCC3.s.sol; idempotent) ------------------
ensure "LPPool.setCreditCore($CORE)"                    "$POOL"   "creditCore()(address)"    "setCreditCore(address)"           "$CORE"
ensure "LPPool.setBridge($BRIDGE)"                      "$POOL"   "bridge()(address)"        "setBridge(address)"               "$BRIDGE"
ensure "CreditCore.setRepaymentBridge($BRIDGE)"         "$CORE"   "repaymentBridge()(address)" "setRepaymentBridge(address)"    "$BRIDGE"
ensure "RepaymentBridge.registerRepaymentVault($REPAYMENT_VAULT)" "$BRIDGE" "repaymentVaultOnSepolia()(address)" "registerRepaymentVault(address)" "$REPAYMENT_VAULT"

# --- 2b. v4 tiered source registry ------------------------------------------
# Canonical external protocol singletons on Sepolia (identities recorded in
# docs/protocol-registry.json: Morpho per docs.morpho.org; Aave resolved from
# its AddressesProvider 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A).
MORPHO_SEPOLIA=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
AAVE_POOL_SEPOLIA=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
# LoanBookSim demotes to BONDED with a real stake — it is no longer silently
# trusted. 10 CTC covers the demo replay's attribution (repay-sim 3.5 +
# liquidation damage 3.0 = 6.5 limit-units) with headroom.
LOANBOOK_BOND_WEI=10000000000000000000

# source_tier <addr> → prints the tier enum value (0 Unknown / 1 Bonded / 2 Verified)
source_tier() {
    cast call "$CORE" "sources(address)(uint8,uint256,uint256)" "$1" "${RPC[@]}" | sed -n 1p
}

# ensure_verified <label> <addr> — idempotent registerVerifiedSource
ensure_verified() {
    local label=$1 addr=$2
    if [[ "$(source_tier "$addr")" == "2" ]]; then
        echo "-- $label: already Verified, skipping"
        return
    fi
    send "CreditCore.registerVerifiedSource($label)" "$CORE" "registerVerifiedSource(address)" "$addr"
}

ensure_verified "ScoringVault $SCORING_VAULT"        "$SCORING_VAULT"
ensure_verified "MorphoBlueSepolia $MORPHO_SEPOLIA"  "$MORPHO_SEPOLIA"
ensure_verified "AavePoolSepolia $AAVE_POOL_SEPOLIA" "$AAVE_POOL_SEPOLIA"

if [[ "$(source_tier "$LOAN_BOOK")" == "1" ]]; then
    echo "-- LoanBookSim: already Bonded, skipping"
else
    send "CreditCore.registerBondedSource(LoanBookSim, $(cast from-wei "$LOANBOOK_BOND_WEI") CTC)" \
        "$CORE" "registerBondedSource(address)" "$LOAN_BOOK" --value "$LOANBOOK_BOND_WEI"
fi

if [[ -n "${MIN_ACCEPTED_HEIGHT:-}" ]]; then
    ensure "CreditCore.setMinAcceptedHeight($MIN_ACCEPTED_HEIGHT)"      "$CORE"   "minAcceptedHeight()(uint64)" "setMinAcceptedHeight(uint64)" "$MIN_ACCEPTED_HEIGHT"
    ensure "RepaymentBridge.setMinAcceptedHeight($MIN_ACCEPTED_HEIGHT)" "$BRIDGE" "minAcceptedHeight()(uint64)" "setMinAcceptedHeight(uint64)" "$MIN_ACCEPTED_HEIGHT"
fi

# --- 3. wiring back-verification: read everything back ----------------------
FAILED=0
VERIFIED=()

# check <description> <contract> <getter-sig> <expected>
check() {
    local desc=$1 target=$2 sig=$3 expected=$4 actual
    actual="$(cast call "$target" "$sig" "${RPC[@]}")"
    if [[ "$(lower "$actual")" == "$(lower "$expected")" ]]; then
        VERIFIED+=("$desc = $actual")
    else
        echo "MISMATCH: $desc — expected $expected, on-chain $actual" >&2
        FAILED=1
    fi
}

check "LPPool.creditCore"                    "$POOL"   "creditCore()(address)"              "$CORE"
check "LPPool.bridge"                        "$POOL"   "bridge()(address)"                  "$BRIDGE"
check "CreditCore.POOL"                      "$CORE"   "POOL()(address)"                    "$POOL"
check "CreditCore.repaymentBridge"           "$CORE"   "repaymentBridge()(address)"         "$BRIDGE"

# check_tier <description> <addr> <expected tier enum value>
check_tier() {
    local desc=$1 addr=$2 expected=$3 actual
    actual="$(source_tier "$addr")"
    if [[ "$actual" == "$expected" ]]; then
        VERIFIED+=("$desc tier = $actual")
    else
        echo "MISMATCH: $desc — expected tier $expected, on-chain $actual" >&2
        FAILED=1
    fi
}
check_tier "sources[ScoringVault]"       "$SCORING_VAULT"      2
check_tier "sources[MorphoBlueSepolia]"  "$MORPHO_SEPOLIA"     2
check_tier "sources[AavePoolSepolia]"    "$AAVE_POOL_SEPOLIA"  2
check_tier "sources[LoanBookSim]"        "$LOAN_BOOK"          1
LOANBOOK_BOND_ONCHAIN="$(cast call "$CORE" "sources(address)(uint8,uint256,uint256)" "$LOAN_BOOK" "${RPC[@]}" | sed -n 2p | awk '{print $1}')"
if [[ "$LOANBOOK_BOND_ONCHAIN" == "$LOANBOOK_BOND_WEI" ]]; then
    VERIFIED+=("sources[LoanBookSim].bond = $(cast from-wei "$LOANBOOK_BOND_ONCHAIN") CTC")
else
    echo "MISMATCH: LoanBookSim bond — expected $LOANBOOK_BOND_WEI, on-chain $LOANBOOK_BOND_ONCHAIN" >&2
    FAILED=1
fi
check "RepaymentBridge.CREDIT_CORE"          "$BRIDGE" "CREDIT_CORE()(address)"             "$CORE"
check "RepaymentBridge.POOL"                 "$BRIDGE" "POOL()(address)"                    "$POOL"
check "RepaymentBridge.repaymentVaultOnSepolia" "$BRIDGE" "repaymentVaultOnSepolia()(address)" "$REPAYMENT_VAULT"
check "RepaymentBridge.WUSDC"                "$BRIDGE" "WUSDC()(address)"                   "$WUSDC"
# effective scoring time parameters (0 in env → the contract's production default)
check "CreditCore.LOAN_DURATION_BLOCKS"      "$CORE"   "LOAN_DURATION_BLOCKS()(uint256)"    "$(( LOAN_DURATION_BLOCKS == 0 ? 100000 : LOAN_DURATION_BLOCKS ))"
check "CreditCore.MIN_HOLD_BLOCKS"           "$CORE"   "MIN_HOLD_BLOCKS()(uint256)"         "$(( MIN_HOLD_BLOCKS == 0 ? 25000 : MIN_HOLD_BLOCKS ))"
if [[ -n "${MIN_ACCEPTED_HEIGHT:-}" ]]; then
    check "CreditCore.minAcceptedHeight"      "$CORE"   "minAcceptedHeight()(uint64)"        "$MIN_ACCEPTED_HEIGHT"
    check "RepaymentBridge.minAcceptedHeight" "$BRIDGE" "minAcceptedHeight()(uint64)"        "$MIN_ACCEPTED_HEIGHT"
fi

# the library must have code (linking to an empty address would revert on decoding)
DECODER_CODE="$(cast code "$DECODER" "${RPC[@]}")"
if [[ -z "$DECODER_CODE" || "$DECODER_CODE" == "0x" ]]; then
    echo "MISMATCH: EvmV1Decoder $DECODER — no code on-chain" >&2
    FAILED=1
else
    VERIFIED+=("EvmV1Decoder code on-chain = $(( (${#DECODER_CODE} - 2) / 2 )) bytes")
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo >&2
    echo "ERROR: wiring back-verification failed (see MISMATCH above)." >&2
    echo "The addresses are recorded in $DEPLOYMENTS, but the on-chain configuration" >&2
    echo "is incomplete — do not submit proofs until the wiring is fixed. The script" >&2
    echo "can be re-run: it skips whatever is already deployed and set." >&2
    exit 1
fi

# --- 4. summary -------------------------------------------------------------
echo
echo "=== CC3 deploy complete ==="
printf '%-17s %s\n' "EvmV1Decoder:"    "$DECODER"
printf '%-17s %s\n' "LPPool:"          "$POOL"
printf '%-17s %s\n' "CreditCore:"      "$CORE"
printf '%-17s %s\n' "RepaymentBridge:" "$BRIDGE"
printf '%-17s %s\n' "WrappedUSDC:"     "$WUSDC"
echo
echo "Confirmed wiring (read back on-chain):"
for line in "${VERIFIED[@]}"; do
    echo "  OK  $line"
done

#!/usr/bin/env bash
# Path-B demo scene: fill the SwapDesk treasury through a proof-delivered repayment.
#
#   1. CC3:     borrow 2 CTC (opens a fresh loan)
#   2. CC3:     confirm the loan minted and is Funded — Sepolia steps never run
#               before the loan exists on-chain (the bridge rejects proofs for
#               unknown loans)
#   3. Sepolia: approve 0.5 USDC to the RepaymentVault
#   4. Sepolia: lockRepayment(loanId, 500000)  — 0.5 USDC, within the 30% path-B cap
#
# After the lock, the worker's watcher picks up UsdcLockedForRepayment on its own
# and delivers the proof to RepaymentBridge once Sepolia attestation catches up
# (typically ~8 min). Force it early with: cd worker && pnpm worker replay <lock tx>.
#
# Sepolia RPC is pinned to publicnode (the .env Alchemy key answers 401).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DEPLOYMENTS="$ROOT_DIR/docs/deployments.json"

CC3_RPC="https://rpc.cc3-testnet.creditcoin.network"
SEPOLIA_RPC="https://ethereum-sepolia-rpc.publicnode.com"

BORROW_WEI=2000000000000000000   # 2 CTC
LOCK_UNITS=500000                # 0.5 USDC (6 decimals)
CAP_BPS=3000                     # RepaymentBridge.USDC_SHARE_CAP_BPS
EXPECTED_LOAN_ID=2

for cmd in cast jq bc; do
    command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found" >&2; exit 1; }
done

[[ -f "$ROOT_DIR/.env" ]] || { echo "ERROR: $ROOT_DIR/.env missing" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
set +a
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"

CREDIT_CORE="$(jq -r .cc3.CreditCore "$DEPLOYMENTS")"
USDC="$(jq -r .sepolia.TestUSDC "$DEPLOYMENTS")"
VAULT="$(jq -r .sepolia.RepaymentVault "$DEPLOYMENTS")"
BORROWER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"

PK=(--private-key "$DEPLOYER_PRIVATE_KEY")

# send_tx <label> <rpc> <to> <sig> [args...] — sends, waits for the receipt,
# aborts unless status is success; prints and returns the tx hash via SEND_TX_HASH
send_tx() {
    local label="$1" rpc="$2"; shift 2
    local out status
    out="$(cast send --json --rpc-url "$rpc" "${PK[@]}" "$@")"
    SEND_TX_HASH="$(jq -r .transactionHash <<<"$out")"
    status="$(jq -r .status <<<"$out")"
    if [[ "$status" != "0x1" ]]; then
        echo "ERROR: $label reverted (status $status, tx $SEND_TX_HASH)" >&2
        exit 1
    fi
    echo "  $label mined: $SEND_TX_HASH"
}

echo "Borrower:       $BORROWER"
echo "CreditCore:     $CREDIT_CORE (CC3)"
echo "RepaymentVault: $VAULT (Sepolia)"
echo

# --- preflight ---------------------------------------------------------------
CTC_BALANCE="$(cast balance "$BORROWER" --rpc-url "$CC3_RPC")"
[[ "$CTC_BALANCE" != "0" ]] || { echo "ERROR: zero CTC balance on CC3" >&2; exit 1; }

AVAILABLE_LIMIT="$(cast call "$CREDIT_CORE" "creditLimit(address)(uint256)" "$BORROWER" --rpc-url "$CC3_RPC" | awk '{print $1}')"
OPEN_DEBT="$(cast call "$CREDIT_CORE" "borrowers(address)(uint256,uint256,uint256,uint256,uint256,uint256)" "$BORROWER" --rpc-url "$CC3_RPC" | sed -n 3p | awk '{print $1}')"
if (( $(bc <<<"$AVAILABLE_LIMIT - $OPEN_DEBT < $BORROW_WEI") )); then
    echo "ERROR: available credit ($(cast from-wei "$(bc <<<"$AVAILABLE_LIMIT - $OPEN_DEBT")") CTC) below the 2 CTC borrow" >&2
    exit 1
fi

USDC_BALANCE="$(cast call "$USDC" "balanceOf(address)(uint256)" "$BORROWER" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')"
if (( USDC_BALANCE < LOCK_UNITS )); then
    echo "ERROR: TestUSDC balance $USDC_BALANCE < $LOCK_UNITS" >&2
    exit 1
fi

NEXT_ID="$(cast call "$CREDIT_CORE" "nextLoanId()(uint256)" --rpc-url "$CC3_RPC" | awk '{print $1}')"
LOAN_ID="$NEXT_ID"
if [[ "$LOAN_ID" != "$EXPECTED_LOAN_ID" ]]; then
    echo "NOTE: next loan id is $LOAN_ID, not the expected $EXPECTED_LOAN_ID — using $LOAN_ID"
fi

# --- 1. borrow on CC3 --------------------------------------------------------
echo "[1/4] Borrow 2 CTC on CC3 (loan $LOAN_ID)…"
send_tx "borrow" "$CC3_RPC" "$CREDIT_CORE" "borrow(uint256)" "$BORROW_WEI"

# --- 2. confirm the loan exists and is Funded before touching Sepolia --------
echo "[2/4] Confirming loan $LOAN_ID on CC3…"
read -r L_BORROWER L_PRINCIPAL L_INTEREST L_STATUS < <(
    cast call "$CREDIT_CORE" \
        "loans(uint256)(address,uint256,uint256,uint256,uint256,uint256,uint8,uint256)" \
        "$LOAN_ID" --rpc-url "$CC3_RPC" | awk 'NR==1||NR==2||NR==3||NR==7{printf "%s ", $1}'
)
if [[ "${L_BORROWER,,}" != "${BORROWER,,}" ]]; then
    echo "ERROR: loan $LOAN_ID borrower is $L_BORROWER, expected $BORROWER" >&2
    exit 1
fi
if [[ "$L_STATUS" != "2" ]]; then # 2 = Funded
    echo "ERROR: loan $LOAN_ID status is $L_STATUS, expected 2 (Funded)" >&2
    exit 1
fi
echo "  loan $LOAN_ID Funded: principal $(cast from-wei "$L_PRINCIPAL") CTC, interest $(cast from-wei "$L_INTEREST") CTC"

# 30% path-B cap check: locked USDC (scaled to 18 dec) must fit the cap
CAP_WEI="$(bc <<<"($L_PRINCIPAL + $L_INTEREST) * $CAP_BPS / 10000")"
LOCK_WEI="$(bc <<<"$LOCK_UNITS * 1000000000000")"
if (( $(bc <<<"$LOCK_WEI > $CAP_WEI") )); then
    echo "ERROR: lock $(cast from-wei "$LOCK_WEI") exceeds the 30% cap $(cast from-wei "$CAP_WEI")" >&2
    exit 1
fi
echo "  cap OK: locking $(cast from-wei "$LOCK_WEI") of $(cast from-wei "$CAP_WEI") CTC-face allowed"

# --- 3. approve on Sepolia ---------------------------------------------------
echo "[3/4] Approve 0.5 USDC to the vault on Sepolia…"
send_tx "approve" "$SEPOLIA_RPC" "$USDC" "approve(address,uint256)" "$VAULT" "$LOCK_UNITS"
ALLOWANCE="$(cast call "$USDC" "allowance(address,address)(uint256)" "$BORROWER" "$VAULT" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')"
if (( ALLOWANCE < LOCK_UNITS )); then
    echo "ERROR: allowance $ALLOWANCE < $LOCK_UNITS after approve" >&2
    exit 1
fi

# --- 4. lock the repayment ---------------------------------------------------
echo "[4/4] lockRepayment($LOAN_ID, $LOCK_UNITS) on Sepolia…"
send_tx "lockRepayment" "$SEPOLIA_RPC" "$VAULT" "lockRepayment(uint256,uint256)" "$LOAN_ID" "$LOCK_UNITS"
LOCK_TX="$SEND_TX_HASH"

echo
echo "Done. Lock tx (Sepolia): $LOCK_TX"
echo "The worker delivers the proof after attestation (~8 min); watch with:"
echo "  cd worker && pnpm worker status"
echo "or force once attested:"
echo "  cd worker && pnpm worker replay $LOCK_TX"

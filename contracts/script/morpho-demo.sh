#!/usr/bin/env bash
# Borrower-side steps of the TruthGate demo market on Morpho Blue Sepolia
# (market plumbing — oracle, createMarket, liquidity — is already live):
#   4. supply 100 DAI collateral (faucet-minted)
#   5. borrow 50 tUSDC
#   6. repay in full by shares — the final repay tx hash is the pipeline deliverable.
# Every transaction is checked for receipt status 1; the script aborts on failure.
set -euo pipefail

cd "$(dirname "$0")/../.."
source .env
R="${SEPOLIA_RPC%%,*}"
PK=(--private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$R")

MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
FAUCET=0xC959483DBa39aa9E78757139af0e9a2EDEb3f42D
DAI=0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357
TUSDC=0x1Cc00628a8590e4eFDA496242439d5d09e726C14
ORACLE=0x62a87bA957f07E70877EEB741eD5e0441Acc15b5
ME=0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0
P="($TUSDC,$DAI,$ORACLE,0x0000000000000000000000000000000000000000,770000000000000000)"
ID=0x8db3b66308de899b5dd81c0a9de5b423fbc8fe287e2f7d72e3b1e73250eaf722

# send <label> <cast send args...> — submits, checks receipt status, prints the tx hash
send() {
    local label=$1
    shift
    local out status tx
    out=$(cast send "$@" "${PK[@]}" --json)
    status=$(jq -r .status <<<"$out")
    tx=$(jq -r .transactionHash <<<"$out")
    if [ "$status" != "0x1" ]; then
        echo "FAILED: $label (status $status, tx $tx)" >&2
        exit 1
    fi
    echo "ok: $label  tx $tx"
    LAST_TX=$tx
}

# 4. collateral: faucet-mint 100 DAI, approve, supplyCollateral
send "faucet mint 100 DAI" \
    $FAUCET "mint(address,address,uint256)" $DAI $ME 100000000000000000000
send "approve 100 DAI to Morpho" \
    $DAI "approve(address,uint256)" $MORPHO 100000000000000000000
send "supplyCollateral 100 DAI" \
    $MORPHO "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" \
    "$P" 100000000000000000000 $ME 0x

# 5. borrow 50 tUSDC (health room: 100 DAI x 77% = 77 tUSDC)
send "borrow 50 tUSDC" \
    $MORPHO "borrow((address,address,address,address,uint256),uint256,uint256,address,address)" \
    "$P" 50000000 0 $ME $ME

# 6. full repay by shares (exact close — zero-interest market)
send "approve 60 tUSDC to Morpho" \
    $TUSDC "approve(address,uint256)" $MORPHO 60000000
SHARES=$(cast call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $ME \
    --rpc-url "$R" | sed -n 2p | awk '{print $1}')
if [ -z "$SHARES" ] || [ "$SHARES" = "0" ]; then
    echo "FAILED: borrowShares is empty or zero — nothing to repay" >&2
    exit 1
fi
echo "borrowShares: $SHARES"
send "repay full ($SHARES shares)" \
    $MORPHO "repay((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
    "$P" 0 "$SHARES" $ME 0x

echo
echo "=== REPAY TX HASH (the pipeline deliverable) ==="
echo "$LAST_TX"

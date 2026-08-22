#!/usr/bin/env bash
# Ручной деплой CC3 — аналог DeployCC3.s.sol.
#
# forge script несовместим с CC3: Substrate-EVM отдаёт заголовки блоков без
# prevRandao, и forge (1.7.1) паникует "header validation error: prevrandao not set"
# даже без --broadcast и со --skip-simulation. Поэтому — forge create + cast send.
#
# EvmV1Decoder — deployed library (public-функции): деплоится первой, CreditCore и
# RepaymentBridge линкуются через --libraries (LPPool/WrappedUSDC линковки не требуют).
#
# Скрипт возобновляемый: адреса пишутся в docs/deployments.json сразу после каждого
# деплоя; при перезапуске контракт с адресом в json и кодом on-chain не деплоится
# заново, а уже установленные связки пропускаются.
#
# Запускать ПОСЛЕ DeploySepolia (читает Sepolia-адреса из docs/deployments.json).
# Опционально: MIN_ACCEPTED_HEIGHT=<uint64> — выставит окно свежести на обоих контрактах.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$CONTRACTS_DIR")"
DEPLOYMENTS="$ROOT_DIR/docs/deployments.json"

DECODER_SRC="node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol"

cd "$CONTRACTS_DIR" # foundry.toml здесь — алиас rpc "cc3" работает только отсюда

for cmd in forge cast jq; do
    command -v "$cmd" >/dev/null || { echo "ОШИБКА: не найден '$cmd'" >&2; exit 1; }
done

# stderr forge/cast — отдельно от парсимого stdout (иначе jq падает на warning'ах)
STDERR_LOG="${TMPDIR:-/tmp}/deploy-cc3-$$.stderr.log"
: > "$STDERR_LOG"
echo "stderr forge/cast пишется в $STDERR_LOG"

# --- .env -------------------------------------------------------------------
[[ -f "$ROOT_DIR/.env" ]] || { echo "ОШИБКА: нет $ROOT_DIR/.env" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
set +a
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY не задан в .env}"

RPC=(--rpc-url cc3)
PK=(--private-key "$DEPLOYER_PRIVATE_KEY")

# --- баланс деплойера -------------------------------------------------------
DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
BALANCE="$(cast balance "$DEPLOYER" "${RPC[@]}")"
echo "Деплойер: $DEPLOYER"
echo "Баланс на CC3: $(cast from-wei "$BALANCE") CTC"
if [[ "$BALANCE" == "0" ]]; then
    echo "ОШИБКА: нулевой баланс деплойера $DEPLOYER на CC3." >&2
    echo "Получите тестовые CTC (faucet CC3 Testnet) и перезапустите." >&2
    exit 1
fi

# --- Sepolia-адреса из docs/deployments.json --------------------------------
[[ -f "$DEPLOYMENTS" ]] || { echo "ОШИБКА: нет $DEPLOYMENTS — сначала DeploySepolia" >&2; exit 1; }
SCORING_VAULT="$(jq -er '.sepolia.ScoringVault' "$DEPLOYMENTS")"
LOAN_BOOK="$(jq -er '.sepolia.LoanBookSim' "$DEPLOYMENTS")"
REPAYMENT_VAULT="$(jq -er '.sepolia.RepaymentVault' "$DEPLOYMENTS")"
echo "Sepolia: ScoringVault=$SCORING_VAULT LoanBookSim=$LOAN_BOOK RepaymentVault=$REPAYMENT_VAULT"

# --- хелперы ----------------------------------------------------------------
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# record <json-key> <addr> — сразу в deployments.json (для возобновляемости)
record() {
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$1" --arg v "$2" '.cc3 = (.cc3 // {}) | .cc3[$k] = $v' "$DEPLOYMENTS" > "$tmp"
    mv "$tmp" "$DEPLOYMENTS"
}

# deploy_or_reuse <json-key> <path:Contract> [доп. флаги forge create: --libraries/--constructor-args...]
# → адрес в $DEPLOYED_ADDR. Если адрес уже в json и по нему есть код — пропуск.
deploy_or_reuse() {
    local key=$1 target=$2; shift 2
    local existing
    existing="$(jq -r --arg k "$key" '.cc3[$k] // empty' "$DEPLOYMENTS")"
    if [[ -n "$existing" ]]; then
        local code
        code="$(cast code "$existing" "${RPC[@]}")"
        if [[ -n "$code" && "$code" != "0x" ]]; then
            echo "== $key уже задеплоен: $existing (код on-chain на месте) — пропускаю ==" >&2
            DEPLOYED_ADDR="$existing"
            return
        fi
        echo "ВНИМАНИЕ: $key=$existing есть в deployments.json, но кода по адресу нет — деплою заново" >&2
    fi
    echo "== forge create $key ==" >&2
    local out
    if ! out="$(forge create "$target" "${RPC[@]}" "${PK[@]}" --broadcast --legacy "$@" 2>>"$STDERR_LOG")"; then
        echo "ОШИБКА: forge create $key упал. stdout:" >&2
        echo "$out" >&2
        echo "-- хвост stderr ($STDERR_LOG):" >&2
        tail -30 "$STDERR_LOG" >&2
        exit 1
    fi
    DEPLOYED_ADDR="$(grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' <<<"$out" | awk '{print $3}')"
    if [[ -z "$DEPLOYED_ADDR" ]]; then
        echo "ОШИБКА: не нашёл 'Deployed to:' в выводе forge create $key:" >&2
        echo "$out" >&2
        exit 1
    fi
    record "$key" "$DEPLOYED_ADDR"
    echo "   $key = $DEPLOYED_ADDR (записан в deployments.json)" >&2
}

# send <описание> <to> <sig> [args...] — cast send с проверкой статуса receipt'а
send() {
    local desc=$1 to=$2; shift 2
    echo "-> $desc"
    local receipt status
    if ! receipt="$(cast send "$to" "$@" "${RPC[@]}" "${PK[@]}" --legacy --json 2>>"$STDERR_LOG")"; then
        echo "ОШИБКА: транзакция '$desc' не отправилась/ревертнула. stdout:" >&2
        echo "$receipt" >&2
        echo "-- хвост stderr ($STDERR_LOG):" >&2
        tail -30 "$STDERR_LOG" >&2
        exit 1
    fi
    status="$(jq -r '.status' <<<"$receipt" 2>/dev/null || echo "не распарсился: $receipt")"
    if [[ "$status" != "0x1" && "$status" != "1" ]]; then
        echo "ОШИБКА: транзакция '$desc' завершилась со status=$status:" >&2
        echo "$receipt" >&2
        exit 1
    fi
}

# ensure <описание> <contract> <getter-sig> <setter-sig> <значение> —
# идемпотентная связка: если on-chain уже стоит нужное значение, send пропускается.
ensure() {
    local desc=$1 target=$2 getter=$3 setter=$4 value=$5
    local current
    current="$(cast call "$target" "$getter" "${RPC[@]}")"
    if [[ "$(lower "$current")" == "$(lower "$value")" ]]; then
        echo "-- $desc: уже установлено, пропускаю"
        return
    fi
    send "$desc" "$target" "$setter" "$value"
}

# --- 1. деплой (порядок — как в DeployCC3.s.sol, плюс библиотека первой) ----
# таргет — голое имя: на полном node_modules-пути forge паникует (StripPrefixError,
# crates/common/src/contracts.rs), а имя EvmV1Decoder в проекте уникально
deploy_or_reuse "EvmV1Decoder" "EvmV1Decoder"
DECODER="$DEPLOYED_ADDR"
LIBS=(--libraries "$DECODER_SRC:EvmV1Decoder:$DECODER")

deploy_or_reuse "LPPool" src/cc3/LPPool.sol:LPPool
POOL="$DEPLOYED_ADDR"
# Временные параметры скоринга: 0 0 → прод-дефолты (100_000 / 25_000 блоков CC3).
# Демо-деплой (наблюдаемость цикла «занял→подержал→погасил→лимит вырос» за ~1 час):
#   LOAN_DURATION_BLOCKS=240 MIN_HOLD_BLOCKS=60 ./deploy-cc3.sh
LOAN_DURATION_BLOCKS="${LOAN_DURATION_BLOCKS:-0}"
MIN_HOLD_BLOCKS="${MIN_HOLD_BLOCKS:-0}"
deploy_or_reuse "CreditCore" src/cc3/CreditCore.sol:CreditCore "${LIBS[@]}" --constructor-args "$POOL" "$LOAN_DURATION_BLOCKS" "$MIN_HOLD_BLOCKS"
CORE="$DEPLOYED_ADDR"
deploy_or_reuse "RepaymentBridge" src/cc3/RepaymentBridge.sol:RepaymentBridge "${LIBS[@]}" --constructor-args "$CORE" "$POOL"
BRIDGE="$DEPLOYED_ADDR"

WUSDC="$(cast call "$BRIDGE" "WUSDC()(address)" "${RPC[@]}")"
record "WrappedUSDC" "$WUSDC"
echo "   WrappedUSDC (из конструктора RepaymentBridge) = $WUSDC"

# --- 2. связки (порядок — как в DeployCC3.s.sol; идемпотентно) --------------
ensure "LPPool.setCreditCore($CORE)"                    "$POOL"   "creditCore()(address)"    "setCreditCore(address)"           "$CORE"
ensure "LPPool.setBridge($BRIDGE)"                      "$POOL"   "bridge()(address)"        "setBridge(address)"               "$BRIDGE"
ensure "CreditCore.setRepaymentBridge($BRIDGE)"         "$CORE"   "repaymentBridge()(address)" "setRepaymentBridge(address)"    "$BRIDGE"
ensure "CreditCore.registerVaultOnSepolia($SCORING_VAULT)"   "$CORE"   "vaultOnSepolia()(address)"    "registerVaultOnSepolia(address)"    "$SCORING_VAULT"
ensure "CreditCore.registerLoanBookOnSepolia($LOAN_BOOK)"    "$CORE"   "loanBookOnSepolia()(address)" "registerLoanBookOnSepolia(address)" "$LOAN_BOOK"
ensure "RepaymentBridge.registerRepaymentVault($REPAYMENT_VAULT)" "$BRIDGE" "repaymentVaultOnSepolia()(address)" "registerRepaymentVault(address)" "$REPAYMENT_VAULT"

if [[ -n "${MIN_ACCEPTED_HEIGHT:-}" ]]; then
    ensure "CreditCore.setMinAcceptedHeight($MIN_ACCEPTED_HEIGHT)"      "$CORE"   "minAcceptedHeight()(uint64)" "setMinAcceptedHeight(uint64)" "$MIN_ACCEPTED_HEIGHT"
    ensure "RepaymentBridge.setMinAcceptedHeight($MIN_ACCEPTED_HEIGHT)" "$BRIDGE" "minAcceptedHeight()(uint64)" "setMinAcceptedHeight(uint64)" "$MIN_ACCEPTED_HEIGHT"
fi

# --- 3. верификация связки: читаем всё обратно ------------------------------
FAILED=0
VERIFIED=()

# check <описание> <contract> <getter-sig> <ожидаемое>
check() {
    local desc=$1 target=$2 sig=$3 expected=$4 actual
    actual="$(cast call "$target" "$sig" "${RPC[@]}")"
    if [[ "$(lower "$actual")" == "$(lower "$expected")" ]]; then
        VERIFIED+=("$desc = $actual")
    else
        echo "РАСХОЖДЕНИЕ: $desc — ожидалось $expected, on-chain $actual" >&2
        FAILED=1
    fi
}

check "LPPool.creditCore"                    "$POOL"   "creditCore()(address)"              "$CORE"
check "LPPool.bridge"                        "$POOL"   "bridge()(address)"                  "$BRIDGE"
check "CreditCore.POOL"                      "$CORE"   "POOL()(address)"                    "$POOL"
check "CreditCore.repaymentBridge"           "$CORE"   "repaymentBridge()(address)"         "$BRIDGE"
check "CreditCore.vaultOnSepolia"            "$CORE"   "vaultOnSepolia()(address)"          "$SCORING_VAULT"
check "CreditCore.loanBookOnSepolia"         "$CORE"   "loanBookOnSepolia()(address)"       "$LOAN_BOOK"
check "RepaymentBridge.CREDIT_CORE"          "$BRIDGE" "CREDIT_CORE()(address)"             "$CORE"
check "RepaymentBridge.POOL"                 "$BRIDGE" "POOL()(address)"                    "$POOL"
check "RepaymentBridge.repaymentVaultOnSepolia" "$BRIDGE" "repaymentVaultOnSepolia()(address)" "$REPAYMENT_VAULT"
check "RepaymentBridge.WUSDC"                "$BRIDGE" "WUSDC()(address)"                   "$WUSDC"
# эффективные временные параметры скоринга (0 в env → прод-дефолт контракта)
check "CreditCore.LOAN_DURATION_BLOCKS"      "$CORE"   "LOAN_DURATION_BLOCKS()(uint256)"    "$(( LOAN_DURATION_BLOCKS == 0 ? 100000 : LOAN_DURATION_BLOCKS ))"
check "CreditCore.MIN_HOLD_BLOCKS"           "$CORE"   "MIN_HOLD_BLOCKS()(uint256)"         "$(( MIN_HOLD_BLOCKS == 0 ? 25000 : MIN_HOLD_BLOCKS ))"
if [[ -n "${MIN_ACCEPTED_HEIGHT:-}" ]]; then
    check "CreditCore.minAcceptedHeight"      "$CORE"   "minAcceptedHeight()(uint64)"        "$MIN_ACCEPTED_HEIGHT"
    check "RepaymentBridge.minAcceptedHeight" "$BRIDGE" "minAcceptedHeight()(uint64)"        "$MIN_ACCEPTED_HEIGHT"
fi

# у библиотеки должен быть код (линковка на пустой адрес даст revert при декодировании)
DECODER_CODE="$(cast code "$DECODER" "${RPC[@]}")"
if [[ -z "$DECODER_CODE" || "$DECODER_CODE" == "0x" ]]; then
    echo "РАСХОЖДЕНИЕ: EvmV1Decoder $DECODER — нет кода on-chain" >&2
    FAILED=1
else
    VERIFIED+=("EvmV1Decoder code on-chain = $(( (${#DECODER_CODE} - 2) / 2 )) байт")
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo >&2
    echo "ОШИБКА: верификация связки не прошла (см. РАСХОЖДЕНИЕ выше)." >&2
    echo "Адреса записаны в $DEPLOYMENTS, но конфигурация on-chain неполна —" >&2
    echo "не подавайте proof'ы, пока связка не починена. Скрипт можно перезапустить:" >&2
    echo "уже задеплоенное и установленное он пропустит." >&2
    exit 1
fi

# --- 4. итог ----------------------------------------------------------------
echo
echo "=== Деплой CC3 завершён ==="
printf '%-17s %s\n' "EvmV1Decoder:"    "$DECODER"
printf '%-17s %s\n' "LPPool:"          "$POOL"
printf '%-17s %s\n' "CreditCore:"      "$CORE"
printf '%-17s %s\n' "RepaymentBridge:" "$BRIDGE"
printf '%-17s %s\n' "WrappedUSDC:"     "$WUSDC"
echo
echo "Подтверждённые связки (прочитаны обратно on-chain):"
for line in "${VERIFIED[@]}"; do
    echo "  OK  $line"
done

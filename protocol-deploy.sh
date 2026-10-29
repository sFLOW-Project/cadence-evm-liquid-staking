#!/usr/bin/env bash
#
# protocol-deploy.sh — end-to-end Flow + Flow EVM protocol deployment.
#
# Runs the full sequence documented in README.md ("Deployment: step by step"):
#   1.  flow project deploy       (sFlowToken, EVMRoute)
#   2.  bootstrap_protocol_account.cdc
#   3.  onboard_sflow_token_type_for_evm_bridge.cdc
#   4.  create_router_coa.cdc
#   5.  fund_router_coa_flow.cdc
#   6.  deploy_lsp_vault_evm.cdc              (LSPVault bytecode via forge + cast)
#   7.  install_liquid_staking_config.cdc
#   8.  transfer_lsp_vault_ownership_to_governance.cdc
#   9.  install_liquid_staking.cdc
#   10. register_protocol_delegator.cdc
#   11. seed_protocol_owned_sflow.cdc
#   12. install_relayer_router.cdc
#
# Usage:
#   cp protocol-deploy.config.example protocol-deploy.config   # edit values
#   export PROTOCOL_PRIVATE_KEY=<hex ECDSA_P256 private key>  # name from config
#   ./protocol-deploy.sh [path/to/protocol-deploy.config]
#
# Every step is safe to re-run: steps that are naturally idempotent on-chain (guarded by
# their own `if`/`assert` in the .cdc source) are called as-is; steps that are NOT naturally
# idempotent (COA creation, contract installs, one-shot registration/seeding) are preceded by
# an on-chain existence probe and skipped if already satisfied. Every Flow CLI / forge / cast
# invocation is retried up to RETRY_ATTEMPTS times with RETRY_DELAY_SECONDS between attempts.
#
# Requires: flow (Flow CLI), forge + cast (Foundry), jq, python3. Run from the repo root.

set -euo pipefail

# ---------------------------------------------------------------------------
# Setup & config loading
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="${1:-protocol-deploy.config}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  echo "       copy protocol-deploy.config.example to protocol-deploy.config and edit it," >&2
  echo "       or pass an explicit path as the first argument." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${NETWORK:?NETWORK must be set in $CONFIG_FILE}"
: "${ACCOUNT_NAME:?ACCOUNT_NAME must be set in $CONFIG_FILE}"
: "${ACCOUNT_KEY_FILE:?ACCOUNT_KEY_FILE must be set in $CONFIG_FILE}"
: "${PROTOCOL_PRIVATE_KEY_ENV:?PROTOCOL_PRIVATE_KEY_ENV must be set in $CONFIG_FILE}"
: "${FLOW_CONFIG_PATHS:?FLOW_CONFIG_PATHS must be set in $CONFIG_FILE}"
: "${MIN_REQUEST_AMOUNT_WEI:?MIN_REQUEST_AMOUNT_WEI must be set in $CONFIG_FILE}"
: "${MIN_OPERATION_AMOUNT:?MIN_OPERATION_AMOUNT must be set in $CONFIG_FILE}"
: "${DELEGATOR_NODE_ID:?DELEGATOR_NODE_ID must be set in $CONFIG_FILE}"
: "${DELEGATOR_COMMIT_AMOUNT:?DELEGATOR_COMMIT_AMOUNT must be set in $CONFIG_FILE}"
: "${EVM_RPC_URL:?EVM_RPC_URL must be set in $CONFIG_FILE}"

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"
PROTOCOL_FEE_PERCENT="${PROTOCOL_FEE_PERCENT:-0.1}"
UNSTAKE_UNLOCK_EPOCH_DELAY="${UNSTAKE_UNLOCK_EPOCH_DELAY:-1}"
DEPLOY_GAS_LIMIT="${DEPLOY_GAS_LIMIT:-15000000}"
TRANSFER_OWNERSHIP_GAS_LIMIT="${TRANSFER_OWNERSHIP_GAS_LIMIT:-1000000}"
ROUTER_COA_FUND_AMOUNT="${ROUTER_COA_FUND_AMOUNT:-5.0}"
MAX_ONBOARD_FLOW_FEE="${MAX_ONBOARD_FLOW_FEE:-5.0}"

PRIVATE_KEY="${!PROTOCOL_PRIVATE_KEY_ENV:-}"
if [[ -z "$PRIVATE_KEY" ]]; then
  echo "ERROR: environment variable \$$PROTOCOL_PRIVATE_KEY_ENV is not set." >&2
  echo "       export $PROTOCOL_PRIVATE_KEY_ENV=<hex ECDSA_P256 private key> before running." >&2
  exit 1
fi

FLOW_ARGS=()
for p in "${FLOW_CONFIG_PATHS[@]}"; do
  FLOW_ARGS+=(-f "$p")
done
FLOW_ARGS+=(--network "$NETWORK")

STATE_FILE="${STATE_FILE:-.protocol-deploy-state.${NETWORK}.env}"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

log()  { printf '\n==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

save_state() {
  # save_state KEY VALUE — persists a key/value across re-runs (e.g. the deployed LSPVault
  # hex address) so later steps don't need to re-derive it.
  local key="$1" value="$2"
  touch "$STATE_FILE"
  grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  printf '%s=%q\n' "$key" "$value" >> "$STATE_FILE"
  declare -g "$key=$value"
}

# retry CMD... — run CMD up to RETRY_ATTEMPTS times with RETRY_DELAY_SECONDS between
# attempts, retrying on both non-zero exit codes and on a successful exit whose stdout
# nonetheless carries a Flow transaction/script error (flow CLI prints transaction errors
# into the JSON payload while still exiting 0 — see retry_flow_json below for that case).
retry() {
  local attempt=1
  local out rc
  while true; do
    if out="$("$@" 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    rc=$?
    if (( attempt >= RETRY_ATTEMPTS )); then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    warn "command failed (attempt $attempt/$RETRY_ATTEMPTS), retrying in ${RETRY_DELAY_SECONDS}s: $*"
    printf '%s\n' "$out" >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY_SECONDS"
  done
}

# retry_flow_tx CMD... — like retry(), but additionally fails (and retries) when flow-cli
# exits 0 yet the JSON output contains a non-null top-level "error" field. `flow transactions
# send -o json` always exits 0 once the transaction is *submitted and sealed*, even if the
# transaction reverted on-chain; the only reliable signal is the "error" field in the JSON.
retry_flow_tx() {
  local attempt=1
  local out rc err
  while true; do
    rc=0
    out="$("$@" 2>&1)" || rc=$?
    if (( rc == 0 )); then
      err="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
err = d.get("error")
if err:
    print(err)
' 2>/dev/null || true)"
      if [[ -z "$err" ]]; then
        printf '%s\n' "$out"
        return 0
      fi
      rc=1
    fi
    if (( attempt >= RETRY_ATTEMPTS )); then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    warn "transaction failed (attempt $attempt/$RETRY_ATTEMPTS), retrying in ${RETRY_DELAY_SECONDS}s: $*"
    printf '%s\n' "$out" >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY_SECONDS"
  done
}

flow_tx() {
  # flow_tx <cdc file> [args...] -- sends a transaction signed/proposed/paid by $ACCOUNT_NAME,
  # retried via retry_flow_tx, requesting JSON output so retry_flow_tx can inspect the result.
  retry_flow_tx flow transactions send "$@" --signer "$ACCOUNT_NAME" "${FLOW_ARGS[@]}" -o json
}

flow_tx_args_json() {
  # flow_tx_args_json <cdc file> <args-json> -- same as flow_tx but for payloads too large/
  # structured to pass as positional CLI arguments (e.g. [UInt8] bytecode, Config tuples).
  local cdc="$1" args_json="$2"
  retry_flow_tx flow transactions send "$cdc" --args-json "$args_json" \
    --signer "$ACCOUNT_NAME" "${FLOW_ARGS[@]}" -o json
}

flow_script() {
  # flow_script <cdc file> [args...] -- executes a read-only script, retried via retry(),
  # returning the decoded JSON "value" so callers can pull strings/bools directly.
  local raw
  raw="$(retry flow scripts execute "$@" "${FLOW_ARGS[@]}" -o json)"
  python3 -c 'import json, sys; print(json.load(sys.stdin).get("value", ""))' <<<"$raw"
}

account_has_contract() {
  # account_has_contract ADDRESS NAME -- true if NAME is already deployed on ADDRESS.
  local address="$1" name="$2"
  retry flow accounts get "$address" --include contracts "${FLOW_ARGS[@]}" -o json \
    | python3 -c "import json, sys
d = json.load(sys.stdin)
sys.exit(0 if sys.argv[1] in (d.get('code') or {}) else 1)" "$name"
}

router_coa_exists() {
  # Router COA publishes &{EVM.Addressable} at /public/lspRouterCOAEvmAddr once created.
  local addr="$1"
  local value
  value="$(flow_script cadence/scripts/admin/get_router_coa_evm_address.cdc "$addr" 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "None" && "$value" != "null" ]]
}

resolve_protocol_address() {
  # The account's on-chain address, read from the merged flow config files (last one wins,
  # matching flow-cli's own -f merge order) rather than an extra flow-cli round-trip.
  local addr=""
  for p in "${FLOW_CONFIG_PATHS[@]}"; do
    local v
    v="$(jq -r --arg name "$ACCOUNT_NAME" '.accounts[$name].address // empty' "$p" 2>/dev/null || true)"
    [[ -n "$v" ]] && addr="$v"
  done
  [[ -n "$addr" ]] || die "could not resolve address for account '$ACCOUNT_NAME' from ${FLOW_CONFIG_PATHS[*]}"
  [[ "$addr" == 0x* ]] && addr="${addr:2}"
  printf '%s' "$addr"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

for bin in flow forge cast jq python3; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found on PATH: $bin"
done

log "Writing account key to $ACCOUNT_KEY_FILE (from \$$PROTOCOL_PRIVATE_KEY_ENV)"
umask 077
printf '%s' "$PRIVATE_KEY" > "$ACCOUNT_KEY_FILE"

PROTOCOL_ADDRESS="$(resolve_protocol_address)"
log "Protocol account: $ACCOUNT_NAME (0x$PROTOCOL_ADDRESS) on $NETWORK"

# ---------------------------------------------------------------------------
# Step 1: flow project deploy (sFlowToken, EVMRoute)
# ---------------------------------------------------------------------------
# `flow project deploy` is natively idempotent: unchanged contracts are reported as
# "[skipping, no changes found]" and exit 0. --update lets legitimate source changes apply.

log "Step 1/12: flow project deploy (sFlowToken, EVMRoute)"
retry flow project deploy --update "${FLOW_ARGS[@]}"

# ---------------------------------------------------------------------------
# Step 2: bootstrap_protocol_account.cdc
# ---------------------------------------------------------------------------
# Idempotent by construction (see the transaction's own doc comment): reuses existing
# storage/capabilities, safe to re-run unconditionally.

log "Step 2/12: bootstrap_protocol_account.cdc"
flow_tx cadence/transactions/deployment/bootstrap_protocol_account.cdc

# ---------------------------------------------------------------------------
# Step 3: onboard_sflow_token_type_for_evm_bridge.cdc
# ---------------------------------------------------------------------------
# Idempotent by construction: becomes a fee-free no-op once FlowEVMBridge reports the type
# no longer requires onboarding.

log "Step 3/12: onboard_sflow_token_type_for_evm_bridge.cdc"
flow_tx cadence/transactions/deployment/onboard_sflow_token_type_for_evm_bridge.cdc \
  "$MAX_ONBOARD_FLOW_FEE"

log "Resolving bridged sFlow EVM address"
SFLOW_EVM_HEX="$(flow_script cadence/scripts/deployment/get_bridged_sflow_evm_address.cdc)"
[[ -n "$SFLOW_EVM_HEX" && "$SFLOW_EVM_HEX" != "None" ]] \
  || die "could not resolve bridged sFlow EVM address after onboarding"
save_state SFLOW_EVM_HEX "$SFLOW_EVM_HEX"
log "Bridged sFlow EVM address: $SFLOW_EVM_HEX"

# ---------------------------------------------------------------------------
# Pipeline-complete short-circuit
# ---------------------------------------------------------------------------
# install_relayer_router.cdc (step 12) *moves* the router COA out of
# /storage/lspRelayerRouterCOA and unpublishes /public/lspRouterCOAEvmAddr, so
# router_coa_exists() (step 4's guard) can never again distinguish "not yet created" from
# "created, used, and consumed". If RelayerRouter is already installed, the entire pipeline
# already completed successfully on a prior run (it is step 12 and depends on every earlier
# step); skip straight to the summary instead of re-probing steps whose guards no longer work.

if account_has_contract "0x$PROTOCOL_ADDRESS" "RelayerRouter"; then
  log "RelayerRouter already installed — protocol deployment already complete, nothing to do"
  LSPVAULT_EVM_HEX="$(flow_script cadence/scripts/admin/get_lsp_vault_evm_address.cdc)"
  ROUTER_COA_EVM_HEX="${ROUTER_COA_EVM_HEX:-<consumed by install_relayer_router.cdc; see $STATE_FILE>}"
  save_state LSPVAULT_EVM_HEX "$LSPVAULT_EVM_HEX"
  log "Protocol deployment complete."
  log "  Protocol address:    0x$PROTOCOL_ADDRESS"
  log "  Router COA (EVM):    $ROUTER_COA_EVM_HEX"
  log "  LSPVault (EVM):      $LSPVAULT_EVM_HEX"
  log "  Bridged sFlow (EVM): $SFLOW_EVM_HEX"
  log "  State saved to:      $STATE_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: create_router_coa.cdc
# ---------------------------------------------------------------------------
# NOT idempotent on its own (its `assert` panics if a COA already exists at
# /storage/lspRelayerRouterCOA). Guard with an existence probe via the public capability it
# publishes, so re-running the pipeline after this step succeeded is a no-op here.

log "Step 4/12: create_router_coa.cdc"
if router_coa_exists "0x$PROTOCOL_ADDRESS"; then
  log "Router COA already exists, skipping"
else
  flow_tx cadence/transactions/deployment/create_router_coa.cdc
fi

ROUTER_COA_EVM_HEX="$(flow_script cadence/scripts/admin/get_router_coa_evm_address.cdc "0x$PROTOCOL_ADDRESS")"
[[ -n "$ROUTER_COA_EVM_HEX" && "$ROUTER_COA_EVM_HEX" != "None" ]] \
  || die "could not resolve router COA EVM address after create_router_coa.cdc"
save_state ROUTER_COA_EVM_HEX "$ROUTER_COA_EVM_HEX"
log "Router COA EVM address: $ROUTER_COA_EVM_HEX"

# ---------------------------------------------------------------------------
# Step 5: fund_router_coa_flow.cdc
# ---------------------------------------------------------------------------
# Idempotent in effect: topping up the COA's FLOW balance is safe to repeat (worst case it
# ends up with more gas headroom than strictly needed).

log "Step 5/12: fund_router_coa_flow.cdc ($ROUTER_COA_FUND_AMOUNT FLOW)"
flow_tx cadence/transactions/deployment/fund_router_coa_flow.cdc "$ROUTER_COA_FUND_AMOUNT"

# ---------------------------------------------------------------------------
# Step 6: deploy_lsp_vault_evm.cdc (forge build + cast encode + coa.deploy)
# ---------------------------------------------------------------------------
# NOT idempotent on its own: re-sending would deploy a second, distinct LSPVault (EVM CREATE
# address depends on the deployer's nonce at send time). Guard by predicting the address the
# very first call/deploy from this COA would land at (nonce 0 — create_router_coa.cdc only
# saves the COA and fund_router_coa_flow.cdc only deposits value, neither increments the
# COA's EVM nonce) and checking whether code already exists there.

log "Step 6/12: deploy LSPVault to Flow EVM"

log "forge build"
retry forge build --root evm --silent

LSPVAULT_ARTIFACT="evm/out/LSPVault.sol/LSPVault.json"
[[ -f "$LSPVAULT_ARTIFACT" ]] || die "missing build artifact: $LSPVAULT_ARTIFACT"

PREDICTED_VAULT_ADDRESS="$(cast compute-address "$ROUTER_COA_EVM_HEX" --nonce 0 2>/dev/null | awk '{print $NF}')"
[[ -n "$PREDICTED_VAULT_ADDRESS" ]] || die "cast compute-address failed for router COA $ROUTER_COA_EVM_HEX"

EXISTING_CODE="$(retry cast code "$PREDICTED_VAULT_ADDRESS" --rpc-url "$EVM_RPC_URL")"
if [[ -n "$EXISTING_CODE" && "$EXISTING_CODE" != "0x" ]]; then
  log "LSPVault already deployed at $PREDICTED_VAULT_ADDRESS, skipping deploy"
  LSPVAULT_EVM_HEX="$PREDICTED_VAULT_ADDRESS"
else
  CREATION_BYTECODE="$(jq -r '.bytecode.object' "$LSPVAULT_ARTIFACT")"
  [[ "$CREATION_BYTECODE" != "null" && -n "$CREATION_BYTECODE" ]] \
    || die "no bytecode.object in $LSPVAULT_ARTIFACT"

  CONSTRUCTOR_ARGS="$(cast abi-encode "constructor(address,address,uint256)" \
    "$SFLOW_EVM_HEX" "$ROUTER_COA_EVM_HEX" "$MIN_REQUEST_AMOUNT_WEI")"
  INIT_CODE="$(cast concat-hex "$CREATION_BYTECODE" "$CONSTRUCTOR_ARGS")"

  BYTECODE_ARG="$(python3 "$SCRIPT_DIR/scripts/deploy_helpers.py" bytes-to-json "$INIT_CODE")"
  GAS_ARG="{\"type\":\"UInt64\",\"value\":\"$DEPLOY_GAS_LIMIT\"}"
  ARGS_JSON="$(printf '[%s,%s]' "$BYTECODE_ARG" "$GAS_ARG")"

  flow_tx_args_json cadence/transactions/deployment/deploy_lsp_vault_evm.cdc "$ARGS_JSON"

  LSPVAULT_EVM_HEX="$PREDICTED_VAULT_ADDRESS"
  log "Waiting for deployed bytecode to be observable at $LSPVAULT_EVM_HEX"
  for _ in $(seq 1 "$RETRY_ATTEMPTS"); do
    EXISTING_CODE="$(cast code "$LSPVAULT_EVM_HEX" --rpc-url "$EVM_RPC_URL" 2>/dev/null || true)"
    [[ -n "$EXISTING_CODE" && "$EXISTING_CODE" != "0x" ]] && break
    sleep "$RETRY_DELAY_SECONDS"
  done
  [[ -n "$EXISTING_CODE" && "$EXISTING_CODE" != "0x" ]] \
    || die "LSPVault deploy transaction sealed but no code observed at $LSPVAULT_EVM_HEX"
fi

save_state LSPVAULT_EVM_HEX "$LSPVAULT_EVM_HEX"
log "LSPVault EVM address: $LSPVAULT_EVM_HEX"

# ---------------------------------------------------------------------------
# Step 7: install_liquid_staking_config.cdc
# ---------------------------------------------------------------------------
# NOT idempotent (its `init` mints a governance COA; re-adding the contract fails outright
# since it's already deployed). Guard with account_has_contract.

log "Step 7/12: install_liquid_staking_config.cdc"
if account_has_contract "0x$PROTOCOL_ADDRESS" "LiquidStakingConfig"; then
  log "LiquidStakingConfig already installed, skipping"
else
  LSC_CODE_RESOLVED="$(python3 "$SCRIPT_DIR/scripts/deploy_helpers.py" rewrite-imports \
    "${FLOW_CONFIG_PATHS[-1]}" "$NETWORK" "$PROTOCOL_ADDRESS" \
    cadence/contracts/LiquidStakingConfig.cdc EVMRoute)"
  FEE_RECEIVER="${PROTOCOL_FEE_RECEIVER:-0x$PROTOCOL_ADDRESS}"

  ARGS_JSON="$(python3 - "$LSC_CODE_RESOLVED" "$PROTOCOL_FEE_PERCENT" "$FEE_RECEIVER" \
      "$MIN_OPERATION_AMOUNT" "$UNSTAKE_UNLOCK_EPOCH_DELAY" "$LSPVAULT_EVM_HEX" <<'PYEOF'
import json, sys
code, fee_pct, fee_recv, min_op, unlock_delay, vault_hex = sys.argv[1:7]
print(json.dumps([
    {"type": "String", "value": code},
    {"type": "UFix64", "value": fee_pct},
    {"type": "Address", "value": fee_recv},
    {"type": "UFix64", "value": min_op},
    {"type": "UInt64", "value": str(unlock_delay)},
    {"type": "String", "value": vault_hex},
]))
PYEOF
  )"
  flow_tx_args_json cadence/transactions/deployment/install_liquid_staking_config.cdc "$ARGS_JSON"
fi

# ---------------------------------------------------------------------------
# Step 8: transfer_lsp_vault_ownership_to_governance.cdc
# ---------------------------------------------------------------------------
# Idempotent by nature of the target call: Solidity `Ownable.transferOwnership` just sets
# `owner` to the given address; calling it again with the same governance address is a no-op
# state transition (still costs gas, but never fails or double-applies).

log "Step 8/12: transfer_lsp_vault_ownership_to_governance.cdc"
flow_tx cadence/transactions/deployment/transfer_lsp_vault_ownership_to_governance.cdc \
  "$LSPVAULT_EVM_HEX" "$TRANSFER_OWNERSHIP_GAS_LIMIT"

# ---------------------------------------------------------------------------
# Step 9: install_liquid_staking.cdc
# ---------------------------------------------------------------------------
# NOT idempotent (re-adding an already-deployed contract fails). Guard with
# account_has_contract.

log "Step 9/12: install_liquid_staking.cdc"
if account_has_contract "0x$PROTOCOL_ADDRESS" "LiquidStaking"; then
  log "LiquidStaking already installed, skipping"
else
  LS_CODE_RESOLVED="$(python3 "$SCRIPT_DIR/scripts/deploy_helpers.py" rewrite-imports \
    "${FLOW_CONFIG_PATHS[-1]}" "$NETWORK" "$PROTOCOL_ADDRESS" \
    cadence/contracts/LiquidStaking.cdc LiquidStakingConfig EVMRoute sFlowToken)"
  ARGS_JSON="$(python3 -c 'import json, sys; print(json.dumps([{"type":"String","value":sys.argv[1]}]))' "$LS_CODE_RESOLVED")"
  flow_tx_args_json cadence/transactions/deployment/install_liquid_staking.cdc "$ARGS_JSON"
fi

# ---------------------------------------------------------------------------
# Step 10: register_protocol_delegator.cdc
# ---------------------------------------------------------------------------
# NOT idempotent by default (each call registers another slot and withdraws
# DELEGATOR_COMMIT_AMOUNT again). Guard with a deposit-target probe: once any slot exists,
# skip so re-running the pipeline doesn't double-commit FLOW.

log "Step 10/12: register_protocol_delegator.cdc"
HAS_TARGET="$(flow_script cadence/scripts/deployment/has_deposit_target.cdc)"
if [[ "$HAS_TARGET" == "True" || "$HAS_TARGET" == "true" ]]; then
  log "Protocol delegator already registered, skipping"
else
  flow_tx cadence/transactions/deployment/register_protocol_delegator.cdc \
    "$DELEGATOR_NODE_ID" "$DELEGATOR_COMMIT_AMOUNT"
fi

# ---------------------------------------------------------------------------
# Step 11: seed_protocol_owned_sflow.cdc
# ---------------------------------------------------------------------------
# NOT idempotent (its own `pre` condition panics if already seeded, which is effectively a
# hard guard, but we probe first to avoid the noisy failure/retry cycle it would otherwise
# trigger on every re-run).

log "Step 11/12: seed_protocol_owned_sflow.cdc"
IS_SEEDED="$(flow_script cadence/scripts/deployment/is_protocol_sflow_seeded.cdc)"
if [[ "$IS_SEEDED" == "True" || "$IS_SEEDED" == "true" ]]; then
  log "Protocol-owned sFLOW already seeded, skipping"
else
  flow_tx cadence/transactions/deployment/seed_protocol_owned_sflow.cdc
fi

# ---------------------------------------------------------------------------
# Step 12: install_relayer_router.cdc
# ---------------------------------------------------------------------------
# NOT idempotent (re-adding an already-deployed contract fails, and its init takes the
# router COA by `load`, which would panic the second time regardless). Guarded above by the
# pipeline-complete short-circuit (this step's own account_has_contract check would be
# correct too, but by the time we reach here it is already known to be false).

log "Step 12/12: install_relayer_router.cdc"
RR_CODE_RESOLVED="$(python3 "$SCRIPT_DIR/scripts/deploy_helpers.py" rewrite-imports \
  "${FLOW_CONFIG_PATHS[-1]}" "$NETWORK" "$PROTOCOL_ADDRESS" \
  cadence/contracts/RelayerRouter.cdc LiquidStaking LiquidStakingConfig EVMRoute sFlowToken)"
ARGS_JSON="$(python3 - "$RR_CODE_RESOLVED" "$LSPVAULT_EVM_HEX" "$SFLOW_EVM_HEX" <<'PYEOF'
import json, sys
code, vault_hex, sflow_hex = sys.argv[1:4]
print(json.dumps([
    {"type": "String", "value": code},
    {"type": "String", "value": vault_hex},
    {"type": "String", "value": sflow_hex},
]))
PYEOF
)"
flow_tx_args_json cadence/transactions/deployment/install_relayer_router.cdc "$ARGS_JSON"

log "Protocol deployment complete."
log "  Protocol address:    0x$PROTOCOL_ADDRESS"
log "  Router COA (EVM):    $ROUTER_COA_EVM_HEX (now owned by RelayerRouter)"
log "  LSPVault (EVM):      $LSPVAULT_EVM_HEX"
log "  Bridged sFlow (EVM): $SFLOW_EVM_HEX"
log "  State saved to:      $STATE_FILE"

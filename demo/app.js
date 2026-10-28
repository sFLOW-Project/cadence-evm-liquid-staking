/* global ethers */
const cfg = () => window.DEMO_CONFIG || {};

function showBootError(msg) {
  const el = document.getElementById("boot-error");
  if (!el) return;
  el.style.display = "block";
  el.innerHTML = `<strong>Demo failed to start.</strong> ${msg}`;
}

function cadAddr(hex) {
  const h = hex.replace(/^0x/i, "");
  return "0x" + h.toLowerCase();
}

function b64Utf8(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

/** Unwrap JSON-CDC from Flow Access REST into plain JS structures. */
function simplify(v) {
  if (v == null) return v;
  if (typeof v !== "object") return v;
  if (!("type" in v) || !("value" in v)) return v;
  const { type, value } = v;
  if (type === "Array" || /^\[.*\]$/.test(type || "")) {
    return (value ?? []).map(simplify);
  }
  if (type === "Dictionary") {
    const out = {};
    for (const pair of value ?? []) {
      const k = simplify(pair.key);
      out[String(k)] = simplify(pair.value);
    }
    return out;
  }
  if (type === "Optional") {
    return value == null ? null : simplify(value);
  }
  if (type === "Void") return null;
  const prim = new Set([
    "String",
    "Bool",
    "Address",
    "UFix64",
    "Fix64",
    "UInt64",
    "UInt32",
    "UInt8",
    "UInt256",
    "UInt",
    "Int64",
    "Int32",
    "Int8",
    "Int",
  ]);
  if (prim.has(type)) return value;
  if (type === "Struct" || (type && type.includes(".") && value && value.fields)) {
    const val = value;
    if (val && Array.isArray(val.fields)) {
      const o = { __type: val.id || type };
      for (const f of val.fields) {
        o[f.name] = simplify(f.value);
      }
      return o;
    }
    if (Array.isArray(val)) {
      const o = { __type: type };
      for (const f of val) {
        o[f.name] = simplify(f.value);
      }
      return o;
    }
  }
  return value;
}

async function runCadenceScript(scriptCadence, jsonArgs = []) {
  const c = cfg();
  const rest = (c.flowAccessRest || "").replace(/\/$/, "");
  const url = `${rest}/v1/scripts?block_height=sealed`;
  const body = {
    script: b64Utf8(scriptCadence),
    arguments: jsonArgs.map((a) => b64Utf8(JSON.stringify(a))),
  };
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(text || res.statusText);
  const outer = JSON.parse(text);
  const innerText = new TextDecoder().decode(
    Uint8Array.from(atob(outer), (ch) => ch.charCodeAt(0)),
  );
  const inner = JSON.parse(innerText);
  return simplify(inner);
}

/** Mirrors `cadence/scripts/admin/get_protocol_totals.cdc` (address-import style for REST). */
function scriptProtocolTotals(deployer) {
  const d = cadAddr(deployer);
  return `
import LiquidStaking from ${d}
import sFlowToken from ${d}

access(all) fun main(): {String: AnyStruct} {
    return {
        "totalFlowStaked": LiquidStaking.totalFlowStaked,
        "sFlowTotalSupply": sFlowToken.totalSupply,
        "protocolOwnedSFlow": LiquidStaking.protocolOwnedSFlowBalance(),
        "flowPerSFlowScaled": LiquidStaking.flowPerSFlowScaled(),
        "sFlowPerFlowScaled": LiquidStaking.sFlowPerFlowScaled()
    }
}
`.trim();
}

/** Mirrors `cadence/scripts/admin/get_protocol_config.cdc`. */
function scriptProtocolConfig(deployer) {
  const d = cadAddr(deployer);
  return `
import LiquidStakingConfig from ${d}

access(all) fun main(): {String: AnyStruct} {
    return {
        "receiver": LiquidStakingConfig.protocolFeeReceiver,
        "feePercent": LiquidStakingConfig.protocolFeePercent,
        "feeQueued": LiquidStakingConfig.protocolFeePercentQueued,
        "timelockExpiration": LiquidStakingConfig.protocolFeeTimelockExpiration,
        "paused": LiquidStakingConfig.isStakingPaused,
        "minOp": LiquidStakingConfig.minOperationAmount,
        "delay": LiquidStakingConfig.unstakeUnlockEpochDelay
    }
}
`.trim();
}

function scriptDelegator(deployer, idTable) {
  const d = cadAddr(deployer);
  const t = cadAddr(idTable);
  return `
import FlowIDTableStaking from ${t}
import LiquidStaking from ${d}

access(all) fun main(): FlowIDTableStaking.DelegatorInfo {
    return LiquidStaking.getDelegatorInfo()
}
`.trim();
}

const VAULT_ABI = [
  "error OperationAmountTooLow(uint256 minAmount, uint256 amount)",
  "error AmountNotCadenceRepresentable(uint256 amount)",
  "error StakingPaused()",
  "error UnstakingPaused()",
  "error InvalidRequest()",
  "error NotRouterCOA()",
  "error SlippageCancelValueMismatch(uint256 expectedRefund, uint256 refund)",
  "error sFlowAmountTooLow(uint256 minAmountOut, uint256 sFlowAmount)",
  "error InvalidRouterCOA()",
  "error InvalidSFlowAddress()",
  "error InvalidBacking()",
  "error NotRequestOwner()",
  "error CantCancelRequestYet()",
  "error UnstakeFulfillmentAmountInvalid(uint256 confirmedAmount, uint256 fulfilledAmount)",
  "function owner() view returns (address)",
  "function S_FLOW_ADDRESS() view returns (address)",
  "function CANCEL_REQUEST_TIMELOCK() view returns (uint256)",
  // Per-user nonce mappings (request ids are keccak256(domain, user, nonce), not sequential).
  "function stakeRequestCount(address) view returns (uint256)",
  "function unstakeRequestCount(address) view returns (uint256)",
  "function pendingWithdrawals(address) view returns (uint256)",
  "function getRate() view returns (uint256)",
  "function getSFlowQuote(uint256 flowWei) view returns (uint256 sFlowWei)",
  "function getFlowQuote(uint256 sFlowWei) view returns (uint256 flowWei)",
  "function getConfig() view returns (tuple(uint256 minRequestAmount,bool isStakingPaused,bool isUnstakingPaused,uint256 protocolFee,uint256 slippageTolerance))",
  "function stakeRequests(uint256) view returns (tuple(uint8 status,address user,uint256 amount,uint256 minAmountOut,uint256 timestamp))",
  "function unstakeRequests(uint256) view returns (tuple(uint8 status,address user,uint256 amount,uint256 flowAmount,uint256 unlockEpoch,uint256 timestamp))",
  "function requestStake() payable returns (uint256)",
  "function requestUnstake(uint256 amount) returns (uint256)",
  "function cancelStakeRequest(uint256 id)",
  "function cancelUnstakeRequest(uint256 id)",
  "function claimPendingWithdrawal()",
  "event StakeRequested(uint256 indexed id, address indexed user, uint256 amount)",
  "event StakeCancelled(uint256 indexed id, address indexed user, uint256 refundWei)",
  "event StakeFulfilled(uint256 indexed id, address indexed user, uint256 sFlowAmount)",
  "event UnstakeRequested(uint256 indexed id, address indexed user, uint256 amount)",
  "event UnstakeConfirmed(uint256 indexed id, address indexed user, uint256 flowAmount, uint256 unlockEpoch)",
  "event UnstakeFulfilled(uint256 indexed id, address indexed user, uint256 amount)",
  "event UnstakeCancelled(uint256 indexed id, address indexed user, uint256 amount)",
  "event WithdrawalClaimed(address indexed user, address indexed recipient, uint256 amount)",
  "event BackingUpdated(uint256 totalFlowStaked, uint256 totalSFlowSupply)",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

/** Matches `ILSPVault.RequestStatus` (`evm/src/interfaces/ILSPVault.sol`). */
function requestStatusLabel(n) {
  const x = Number(n);
  if (x === 0) return "NONE";
  if (x === 1) return "QUEUED";
  if (x === 2) return "AWAITING_FULFILLMENT";
  if (x === 3) return "UNSTAKE_CONFIRMED";
  if (x === 4) return "FULFILLED";
  if (x === 5) return "CANCELLED";
  return String(n);
}

function setStatus(t) {
  const el = document.getElementById("status");
  if (el) el.textContent = t || "";
}

function showErr(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = "";
  const s = document.createElement("span");
  s.className = "err";
  s.textContent = msg;
  el.appendChild(s);
}

function showOk(id, html) {
  const el = document.getElementById(id);
  if (!el) return;
  el.innerHTML = html;
}

function parseEvmWallet(pkInput, errId) {
  const pk = pkInput?.trim() || "";
  if (!pk) {
    showErr(errId, "Private key required.");
    return null;
  }
  try {
    return new ethers.Wallet(pk.startsWith("0x") ? pk : "0x" + pk);
  } catch (e) {
    showErr(errId, "Invalid key: " + (e.message || e));
    return null;
  }
}

async function assertVaultDeployed(provider, vaultAddr, errId) {
  const vaultCode = await provider.getCode(vaultAddr);
  if (!vaultAddr || vaultAddr === "0x0000000000000000000000000000000000000000" || vaultCode === "0x") {
    showErr(
      errId,
      `Invalid lspVault config: ${vaultAddr || "(unset)"}. Run deployment or set demo/config.local.js to the deployed vault address.`,
    );
    return false;
  }
  return true;
}

function fmtObj(o) {
  return JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
}

async function refreshReads() {
  const c = cfg();
  setStatus("Loading…");

  const deployer = c.cadenceDeployer;
  const idTable = c.flowIDTableStaking;
  const vaultAddr = c.lspVault;
  const stAddr = c.bridgedSFlow;

  const addrDl = document.getElementById("addr-list");
  const epDl = document.getElementById("endpoint-list");
  if (addrDl) {
    addrDl.innerHTML = `
      <dt>cadenceDeployer</dt><dd>${deployer || "—"}</dd>
      <dt>flowIDTableStaking</dt><dd>${idTable || "—"}</dd>
      <dt>lspVault</dt><dd>${vaultAddr || "—"}</dd>
      <dt>bridgedSFlow</dt><dd>${stAddr || "—"}</dd>
      <dt>evmBalanceOfAddress</dt><dd>${c.evmBalanceOfAddress || "(unset)"}</dd>
    `;
  }
  if (epDl) {
    epDl.innerHTML = `
      <dt>Flow REST</dt><dd>${c.flowAccessRest || "—"}</dd>
      <dt>EVM RPC</dt><dd>${c.evmRpc || "—"}</dd>
      <dt>chainId</dt><dd>${c.evmChainId ?? "—"}</dd>
    `;
  }

  const cadenceOk = deployer && deployer !== "0x0000000000000000";
  const evmVaultOk =
    vaultAddr && vaultAddr !== "0x0000000000000000000000000000000000000000";
  const evmTokenOk =
    stAddr && stAddr !== "0x0000000000000000000000000000000000000000";

  if (!cadenceOk) {
    document.getElementById("out-protocol-totals").textContent = "Set cadenceDeployer in config.";
    document.getElementById("out-protocol-config").textContent = "—";
    document.getElementById("out-delegator").textContent = "—";
  } else {
    try {
      const totals = await runCadenceScript(scriptProtocolTotals(deployer));
      document.getElementById("out-protocol-totals").textContent = fmtObj(totals);
    } catch (e) {
      document.getElementById("out-protocol-totals").textContent = String(e.message || e);
    }

    try {
      const pconf = await runCadenceScript(scriptProtocolConfig(deployer));
      document.getElementById("out-protocol-config").textContent = fmtObj(pconf);
    } catch (e) {
      document.getElementById("out-protocol-config").textContent = String(e.message || e);
    }

    try {
      const del = await runCadenceScript(scriptDelegator(deployer, idTable));
      document.getElementById("out-delegator").textContent = fmtObj(del);
    } catch (e) {
      const msg = String(e.message || e);
      document.getElementById("out-delegator").textContent = msg.includes("No delegator configured")
        ? "No delegator configured yet. Run cadence/transactions/deployment/register_protocol_delegator.cdc, or rerun deploy-testnet-protocol.sh."
        : msg;
    }
  }

  if (!evmVaultOk) {
    document.getElementById("out-evm-meta").textContent = "Set lspVault in config.";
    document.getElementById("out-evm-config").textContent = "—";
    document.getElementById("out-evm-balance").textContent = "—";
    document.getElementById("out-stake-requests").textContent = "—";
    document.getElementById("out-unstake-requests").textContent = "—";
    const t = new Date().toLocaleTimeString();
    setStatus(
      (!cadenceOk && !evmVaultOk
        ? "Configure cadenceDeployer and lspVault."
        : !cadenceOk
          ? "Cadence reads skipped (deployer not set)."
          : "EVM reads skipped (set lspVault).") + ` ${t}`,
    );
    return;
  }

  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const vault = new ethers.Contract(vaultAddr, VAULT_ABI, provider);
    const [owner, stOnVault, rate] = await Promise.all([
      vault.owner(),
      vault.S_FLOW_ADDRESS(),
      vault.getRate(),
    ]);
    const conf = await vault.getConfig();
    const metaInfo = {
      owner,
      S_FLOW_ADDRESS: stOnVault,
      getRate: rate.toString(),
    };
    const watchedAddr = (c.evmBalanceOfAddress || "").trim();
    if (watchedAddr && ethers.isAddress(watchedAddr)) {
      metaInfo.pendingWithdrawal = (await vault.pendingWithdrawals(watchedAddr)).toString();
    }
    document.getElementById("out-evm-meta").textContent = fmtObj(metaInfo);
    document.getElementById("out-evm-config").textContent = fmtObj({
      minRequestAmount: conf.minRequestAmount.toString(),
      isStakingPaused: conf.isStakingPaused,
      isUnstakingPaused: conf.isUnstakingPaused,
      protocolFee: conf.protocolFee.toString(),
      slippageTolerance: conf.slippageTolerance.toString(),
    });

    const balAddr = (c.evmBalanceOfAddress || "").trim();
    if (!evmTokenOk) {
      document.getElementById("out-evm-balance").textContent =
        "Set bridgedSFlow in config to query ERC-20 balance.";
    } else if (balAddr && ethers.isAddress(balAddr)) {
      const tok = new ethers.Contract(stAddr, ERC20_ABI, provider);
      const b = await tok.balanceOf(balAddr);
      document.getElementById("out-evm-balance").textContent = fmtObj({
        account: balAddr,
        bridgedSFlowBalance: b.toString(),
      });
    } else {
      document.getElementById("out-evm-balance").textContent =
        "Set evmBalanceOfAddress in config to query balanceOf.";
    }

    // Request ids are keccak256(domain, user, nonce), not sequential integers (see
    // LSPVault.sol `_nextStakeRequestId` / `_nextUnstakeRequestId`), so recent requests are
    // discovered by scanning `StakeRequested` / `UnstakeRequested` logs instead of iterating a
    // counter. Limited to a recent block window to keep RPC calls light on public endpoints.
    const latestBlock = await provider.getBlockNumber();
    const scanWindow = Number(c.evmLogScanWindowBlocks || 50_000);
    const fromBlock = Math.max(0, latestBlock - scanWindow);

    const stakeRequestedLogs = await vault.queryFilter(vault.filters.StakeRequested(), fromBlock, latestBlock);
    const recentStakeIds = stakeRequestedLogs.slice(-12).map((log) => log.args.id);
    const stakeLines = await Promise.all(
      recentStakeIds.map(async (id) => {
        const r = await vault.stakeRequests(id);
        return {
          id: id.toString(),
          status: requestStatusLabel(r.status),
          user: r.user,
          amount: r.amount.toString(),
          minAmountOut: r.minAmountOut?.toString?.() ?? String(r.minAmountOut),
          timestamp: r.timestamp?.toString?.() ?? String(r.timestamp),
        };
      }),
    );
    document.getElementById("out-stake-requests").textContent = fmtObj(stakeLines.reverse());

    const unstakeRequestedLogs = await vault.queryFilter(vault.filters.UnstakeRequested(), fromBlock, latestBlock);
    const recentUnstakeIds = unstakeRequestedLogs.slice(-12).map((log) => log.args.id);
    const unstakeLines = await Promise.all(
      recentUnstakeIds.map(async (id) => {
        const r = await vault.unstakeRequests(id);
        return {
          id: id.toString(),
          status: requestStatusLabel(r.status),
          user: r.user,
          sFlowAmount: r.amount.toString(),
          flowAmount: r.flowAmount.toString(),
          unlockEpoch: r.unlockEpoch.toString(),
          timestamp: r.timestamp?.toString?.() ?? String(r.timestamp),
        };
      }),
    );
    document.getElementById("out-unstake-requests").textContent = fmtObj(unstakeLines.reverse());
  } catch (e) {
    document.getElementById("out-evm-meta").textContent = String(e.message || e);
    document.getElementById("out-evm-config").textContent = "—";
    document.getElementById("out-evm-balance").textContent = "—";
    document.getElementById("out-stake-requests").textContent = "—";
    document.getElementById("out-unstake-requests").textContent = "—";
  }

  setStatus("Updated " + new Date().toLocaleTimeString());
}

const DEFAULT_RELAYER_TX_PATHS = {
  handle_stakes: "cadence/transactions/relayer/handle_stakes.cdc",
  initiate_unstakes: "cadence/transactions/relayer/initiate_unstakes.cdc",
  finalize_unstakes: "cadence/transactions/relayer/finalize_unstakes.cdc",
  compound_and_sync_rate: "cadence/transactions/relayer/compound_and_sync_rate.cdc",
};

function keeperRelayerTxKind() {
  const c = cfg();
  const sel = document.getElementById("keeper-tx-kind");
  return (sel?.value || c.keeperRelayerTx || "handle_stakes").trim();
}

function syncKeeperInputsForTxKind() {
  const kind = keeperRelayerTxKind();
  const fee = document.getElementById("keeper-max-bridge-fee");
  const ids = document.getElementById("keeper-ids");
  if (fee) {
    const bridge = kind === "handle_stakes" || kind === "initiate_unstakes";
    fee.disabled = !bridge;
    fee.title = bridge
      ? "Passed as ScopedFTProviders allowance cap for bridge fees."
      : "Not used for this transaction.";
  }
  if (ids) {
    ids.disabled = kind === "compound_and_sync_rate";
    ids.title =
      kind === "compound_and_sync_rate"
        ? "This transaction takes no IDs."
        : "Encoded as the Cadence transaction’s first argument ([UInt256]).";
  }
}

function keeperUInt256IdsArg() {
  const c = cfg();
  const raw = (
    document.getElementById("keeper-ids")?.value?.trim() ||
    c.keeperUInt256Ids ||
    c.handleStakesUInt256Ids ||
    "1"
  ).trim();
  const jsonIds = raw.split(/[\s,]+/).filter(Boolean).map((id) => ({
    type: "UInt256",
    value: id,
  }));
  return {
    type: "Array",
    value: jsonIds.length ? jsonIds : [{ type: "UInt256", value: "1" }],
  };
}

function keeperMaxBridgeFlowFeeArg() {
  const c = cfg();
  const v = (
    document.getElementById("keeper-max-bridge-fee")?.value?.trim() ||
    c.keeperMaxBridgeFlowFee ||
    "10.0"
  ).trim();
  return { type: "UFix64", value: v };
}

async function buildKeeperCommand() {
  const c = cfg();
  const ta = document.getElementById("keeper-cmd");
  const kind = keeperRelayerTxKind();
  const path =
    c.keeperCdcPath?.trim() ||
    DEFAULT_RELAYER_TX_PATHS[kind] ||
    DEFAULT_RELAYER_TX_PATHS.handle_stakes;
  const nf = c.networkFlag || "testnet";
  const signer = c.flowSigner || "testnet-acc";
  const cfgExtra = (c.keeperFlowCliExtra || "").trim();

  let cmd = `flow transactions send ${path} \\\n`;

  if (kind === "compound_and_sync_rate") {
    cmd += `  -n ${nf} --signer ${signer} -y --compute-limit 9999`;
  } else if (kind === "finalize_unstakes") {
    const argsJson = JSON.stringify([keeperUInt256IdsArg()]);
    cmd += `  --args-json '${argsJson}' \\\n  -n ${nf} --signer ${signer} -y --compute-limit 9999`;
  } else {
    const argsJson = JSON.stringify([
      keeperUInt256IdsArg(),
      keeperMaxBridgeFlowFeeArg(),
    ]);
    cmd += `  --args-json '${argsJson}' \\\n  -n ${nf} --signer ${signer} -y --compute-limit 9999`;
  }

  if (cfgExtra) cmd += ` ${cfgExtra}`;
  ta.value = cmd.trimEnd();
  syncKeeperInputsForTxKind();
}

async function sendEvmStake() {
  const c = cfg();
  const msgId = "evm-stake-msg";
  showOk(msgId, "");
  const flowStr = document.getElementById("stake-flow")?.value?.trim() || "0";
  const wallet = parseEvmWallet(document.getElementById("evm-pk")?.value, msgId);
  if (!wallet) return;
  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const w = wallet.connect(provider);
    const vault = new ethers.Contract(c.lspVault, VAULT_ABI, w);
    const value = ethers.parseEther(flowStr);
    if (!(await assertVaultDeployed(provider, c.lspVault, msgId))) return;
    const balance = await provider.getBalance(wallet.address);
    if (balance <= value) {
      showErr(
        msgId,
        `Insufficient Flow EVM balance for ${wallet.address}. Balance is ${ethers.formatEther(balance)} FLOW; request needs ${ethers.formatEther(value)} FLOW plus gas.`,
      );
      return;
    }
    const conf = await vault.getConfig();
    if (conf.isStakingPaused) {
      showErr(msgId, "Staking is paused on the vault.");
      return;
    }
    if (value < conf.minRequestAmount) {
      showErr(
        msgId,
        `Amount too low. Minimum is ${ethers.formatEther(conf.minRequestAmount)} FLOW.`,
      );
      return;
    }
    const tx = await vault.requestStake({ value });
    showOk(msgId, `<div class="ok">Submitted: ${tx.hash}</div>`);
    await tx.wait();
    showOk(msgId, `<div class="ok">Submitted: ${tx.hash}</div><div class="ok">Confirmed in block.</div>`);
    await refreshReads();
  } catch (e) {
    showErr(msgId, String(e.shortMessage || e.message || e));
  }
}

async function sendEvmUnstake() {
  const c = cfg();
  const msgId = "evm-unstake-msg";
  showOk(msgId, "");
  const sFlowStr = document.getElementById("unstake-sflow")?.value?.trim() || "0";
  const wallet = parseEvmWallet(document.getElementById("evm-pk")?.value, msgId);
  if (!wallet) return;
  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const w = wallet.connect(provider);
    const vault = new ethers.Contract(c.lspVault, VAULT_ABI, w);
    const amount = ethers.parseEther(sFlowStr);
    if (!(await assertVaultDeployed(provider, c.lspVault, msgId))) return;

    const stAddr = c.bridgedSFlow;
    if (!stAddr || stAddr === "0x0000000000000000000000000000000000000000") {
      showErr(msgId, "Set bridgedSFlow in demo/config.local.js to the deployed sFlow EVM address.");
      return;
    }

    const sFlow = new ethers.Contract(stAddr, ERC20_ABI, w);
    const [sFlowBalance, allowance, conf, flowEquivalent] = await Promise.all([
      sFlow.balanceOf(wallet.address),
      sFlow.allowance(wallet.address, c.lspVault),
      vault.getConfig(),
      vault.getFlowQuote(amount),
    ]);

    if (sFlowBalance < amount) {
      showErr(
        msgId,
        `Insufficient bridged sFlow for ${wallet.address}. Balance is ${ethers.formatEther(sFlowBalance)} sFlow; request needs ${ethers.formatEther(amount)} sFlow.`,
      );
      return;
    }
    if (conf.isUnstakingPaused) {
      showErr(msgId, "Unstaking is paused on the vault.");
      return;
    }
    if (flowEquivalent < conf.minRequestAmount) {
      showErr(
        msgId,
        `FLOW equivalent too low. ${ethers.formatEther(amount)} sFlow is ~${ethers.formatEther(flowEquivalent)} FLOW at the current rate; minimum is ${ethers.formatEther(conf.minRequestAmount)} FLOW.`,
      );
      return;
    }

    let statusHtml = "";
    if (allowance < amount) {
      const approveTx = await sFlow.approve(c.lspVault, amount);
      statusHtml += `<div class="ok">Approve submitted: ${approveTx.hash}</div>`;
      await approveTx.wait();
      statusHtml += `<div class="ok">Approve confirmed.</div>`;
    }

    const tx = await vault.requestUnstake(amount);
    statusHtml += `<div class="ok">Unstake submitted: ${tx.hash}</div>`;
    showOk(msgId, statusHtml);
    await tx.wait();
    showOk(msgId, statusHtml + `<div class="ok">Unstake confirmed in block.</div>`);
    await refreshReads();
  } catch (e) {
    showErr(msgId, String(e.shortMessage || e.message || e));
  }
}

/**
 * Cancels a still-`QUEUED` request (stake or unstake) owned by the signer. Only valid once
 * `CANCEL_REQUEST_TIMELOCK` (2h on-chain) has elapsed since the request was created; reverts
 * with `CantCancelRequestYet` otherwise. Stake cancellations credit `pendingWithdrawals`
 * (claim separately); unstake cancellations return the locked bridged sFlow immediately.
 */
async function sendCancelRequest(kind) {
  const c = cfg();
  const msgId = kind === "stake" ? "evm-cancel-stake-msg" : "evm-cancel-unstake-msg";
  const idInputId = kind === "stake" ? "cancel-stake-id" : "cancel-unstake-id";
  showOk(msgId, "");
  const idStr = document.getElementById(idInputId)?.value?.trim() || "";
  const wallet = parseEvmWallet(document.getElementById("evm-pk")?.value, msgId);
  if (!wallet) return;
  if (!idStr) {
    showErr(msgId, "Request id required (uint256, decimal or 0x-hex).");
    return;
  }
  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const w = wallet.connect(provider);
    const vault = new ethers.Contract(c.lspVault, VAULT_ABI, w);
    if (!(await assertVaultDeployed(provider, c.lspVault, msgId))) return;

    const id = BigInt(idStr);
    const tx =
      kind === "stake" ? await vault.cancelStakeRequest(id) : await vault.cancelUnstakeRequest(id);
    showOk(msgId, `<div class="ok">Cancel submitted: ${tx.hash}</div>`);
    await tx.wait();
    showOk(msgId, `<div class="ok">Cancel submitted: ${tx.hash}</div><div class="ok">Confirmed in block.</div>`);
    await refreshReads();
  } catch (e) {
    showErr(msgId, String(e.shortMessage || e.message || e));
  }
}

/** Pulls `pendingWithdrawals[msg.sender]` (from stake cancellation, slippage cancel, or
 *  unstake fulfillment) as native FLOW to the signer's own address. */
async function sendClaimPendingWithdrawal() {
  const c = cfg();
  const msgId = "evm-claim-msg";
  showOk(msgId, "");
  const wallet = parseEvmWallet(document.getElementById("evm-pk")?.value, msgId);
  if (!wallet) return;
  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const w = wallet.connect(provider);
    const vault = new ethers.Contract(c.lspVault, VAULT_ABI, w);
    if (!(await assertVaultDeployed(provider, c.lspVault, msgId))) return;

    const pending = await vault.pendingWithdrawals(wallet.address);
    if (pending === 0n) {
      showErr(msgId, `No pending withdrawal for ${wallet.address}.`);
      return;
    }
    const tx = await vault.claimPendingWithdrawal();
    showOk(msgId, `<div class="ok">Claim submitted: ${tx.hash}</div>`);
    await tx.wait();
    showOk(msgId, `<div class="ok">Claim submitted: ${tx.hash}</div><div class="ok">Confirmed in block.</div>`);
    await refreshReads();
  } catch (e) {
    showErr(msgId, String(e.shortMessage || e.message || e));
  }
}

try {
  if (typeof ethers === "undefined") {
    throw new Error(
      "ethers library did not load. Ensure vendor/ethers.umd.min.js is served from the demo folder.",
    );
  }

document.getElementById("btn-refresh")?.addEventListener("click", () => refreshReads());
document.getElementById("btn-keeper-cmd")?.addEventListener("click", () => buildKeeperCommand());
document.getElementById("btn-evm-stake")?.addEventListener("click", () => sendEvmStake());
document.getElementById("btn-evm-unstake")?.addEventListener("click", () => sendEvmUnstake());
document.getElementById("btn-cancel-stake")?.addEventListener("click", () => sendCancelRequest("stake"));
document.getElementById("btn-cancel-unstake")?.addEventListener("click", () => sendCancelRequest("unstake"));
document.getElementById("btn-claim-withdrawal")?.addEventListener("click", () => sendClaimPendingWithdrawal());
document.getElementById("keeper-tx-kind")?.addEventListener("change", () => buildKeeperCommand());
document.getElementById("keeper-ids")?.addEventListener("input", () => buildKeeperCommand());
document.getElementById("keeper-max-bridge-fee")?.addEventListener("input", () => buildKeeperCommand());

(() => {
  const c = cfg();
  const idsEl = document.getElementById("keeper-ids");
  const feeEl = document.getElementById("keeper-max-bridge-fee");
  const kindEl = document.getElementById("keeper-tx-kind");
  const tx = (c.keeperRelayerTx || "").trim();
  if (kindEl && tx && DEFAULT_RELAYER_TX_PATHS[tx]) kindEl.value = tx;
  if (idsEl)
    idsEl.value = (c.keeperUInt256Ids || c.handleStakesUInt256Ids || idsEl.value || "1").trim();
  if (feeEl) feeEl.value = (c.keeperMaxBridgeFlowFee || feeEl.value || "10.0").trim();
})();

refreshReads();
buildKeeperCommand();
} catch (e) {
  showBootError(String(e.message || e));
  setStatus("Startup error");
}

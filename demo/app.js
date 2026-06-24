import { ethers } from "https://esm.sh/ethers@6.16.0";

const cfg = () => window.DEMO_CONFIG || {};

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

access(all) fun main(): {String: UFix64} {
    return {
        "totalFlowStaked": LiquidStaking.totalFlowStaked,
        "sFlowTotalSupply": sFlowToken.totalSupply,
        "flowPerSFlow": LiquidStaking.flowPerSFlow(),
        "sFlowPerFlow": LiquidStaking.sFlowPerFlow()
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
  "function owner() view returns (address)",
  "function S_FLOW_ADDRESS() view returns (address)",
  "function stakeRequestCount() view returns (uint256)",
  "function getRate() view returns (uint256)",
  "function getConfig() view returns (tuple(uint256 minRequestAmount,bool isStakingPaused,uint256 protocolFee,uint256 slippageTolerance))",
  "function stakeRequests(uint256) view returns (tuple(uint8 status,address user,uint256 amount,uint256 minAmountOut))",
  "function requestStake() payable returns (uint256)",
];

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];

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
      document.getElementById("out-delegator").textContent = String(e.message || e);
    }
  }

  if (!evmVaultOk) {
    document.getElementById("out-evm-meta").textContent = "Set lspVault in config.";
    document.getElementById("out-evm-config").textContent = "—";
    document.getElementById("out-evm-balance").textContent = "—";
    document.getElementById("out-stake-requests").textContent = "—";
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
    const [owner, stOnVault, rate, count] = await Promise.all([
      vault.owner(),
      vault.S_FLOW_ADDRESS(),
      vault.getRate(),
      vault.stakeRequestCount(),
    ]);
    const conf = await vault.getConfig();
    document.getElementById("out-evm-meta").textContent = fmtObj({
      owner,
      S_FLOW_ADDRESS: stOnVault,
      getRate: rate.toString(),
      stakeRequestCount: count.toString(),
    });
    document.getElementById("out-evm-config").textContent = fmtObj({
      minRequestAmount: conf.minRequestAmount.toString(),
      isStakingPaused: conf.isStakingPaused,
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

    const n = Number(count);
    const lines = [];
    const lo = Math.max(1, n - 12);
    for (let i = n - 1; i >= lo; i--) {
      const r = await vault.stakeRequests(i);
      lines.push({
        id: i,
        status: requestStatusLabel(r.status),
        user: r.user,
        amount: r.amount.toString(),
        minAmountOut: r.minAmountOut?.toString?.() ?? String(r.minAmountOut),
      });
    }
    document.getElementById("out-stake-requests").textContent = fmtObj(lines.reverse());
  } catch (e) {
    document.getElementById("out-evm-meta").textContent = String(e.message || e);
    document.getElementById("out-evm-config").textContent = "—";
    document.getElementById("out-evm-balance").textContent = "—";
    document.getElementById("out-stake-requests").textContent = "—";
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
  const msg = document.getElementById("evm-stake-msg");
  msg.innerHTML = "";
  const flowStr = document.getElementById("stake-flow")?.value?.trim() || "0";
  const pk = document.getElementById("evm-pk")?.value?.trim() || "";
  if (!pk) {
    showErr("evm-stake-msg", "Private key required.");
    return;
  }
  let wallet;
  try {
    wallet = new ethers.Wallet(pk.startsWith("0x") ? pk : "0x" + pk);
  } catch (e) {
    showErr("evm-stake-msg", "Invalid key: " + (e.message || e));
    return;
  }
  try {
    const provider = new ethers.JsonRpcProvider(c.evmRpc, c.evmChainId, { staticNetwork: true });
    const w = wallet.connect(provider);
    const vault = new ethers.Contract(c.lspVault, VAULT_ABI, w);
    const value = ethers.parseEther(flowStr);
    const tx = await vault.requestStake({ value });
    msg.innerHTML = `<div class="ok">Submitted: ${tx.hash}</div>`;
    await tx.wait();
    msg.innerHTML += `<div class="ok">Confirmed in block.</div>`;
    await refreshReads();
  } catch (e) {
    showErr("evm-stake-msg", String(e.shortMessage || e.message || e));
  }
}

document.getElementById("btn-refresh")?.addEventListener("click", () => refreshReads());
document.getElementById("btn-keeper-cmd")?.addEventListener("click", () => buildKeeperCommand());
document.getElementById("btn-evm-stake")?.addEventListener("click", () => sendEvmStake());
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

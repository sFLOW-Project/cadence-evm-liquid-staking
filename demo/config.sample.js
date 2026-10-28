// Default demo config (safe to commit). Copy to `config.local.js` (gitignored) and override.
window.DEMO_CONFIG = Object.assign(window.DEMO_CONFIG || {}, {
  flowAccessRest: "https://rest-testnet.onflow.org",
  evmRpc: "https://testnet.evm.nodes.onflow.org",
  evmChainId: 545,
  /** Cadence account where `LiquidStaking` + `sFlowToken` live (with `0x`). */
  cadenceDeployer: "0x8e8afa4bb0c9f92d",
  /** Core contract — testnet default from `flow.json`. */
  flowIDTableStaking: "0x9eca2b38b18b5dfe",
  lspVault: "0x0000000000000000000000000000000000000000",
  bridgedSFlow: "0x0000000000000000000000000000000000000000",
  /** Block window scanned backwards from latest for `StakeRequested`/`UnstakeRequested` logs
   *  (request ids are keccak256 hashes, not sequential, so recent requests are discovered via
   *  event logs rather than a counter). Lower this if your RPC caps `eth_getLogs` ranges. */
  evmLogScanWindowBlocks: 50000,
  /** Used for bridging / tooling; Cadence vault type identifier for bridged `sFlowToken.Vault`. */
  vaultIdentifier: "A.8e8afa4bb0c9f92d.sFlowToken.Vault",
  /** Optional: EVM address to show bridged sFlow `balanceOf`. */
  evmBalanceOfAddress: "",
  flowSigner: "protocol-testnet",
  networkFlag: "testnet",
  /** Optional: override Cadence file path for the generated keeper command (otherwise derived from UI / keeperRelayerTx). */
  keeperCdcPath: "",
  /** Default relayer tx kind matching `keeper-tx-kind` (handle_stakes | initiate_unstakes | finalize_unstakes | compound_and_sync_rate). */
  keeperRelayerTx: "handle_stakes",
  /** Space- or comma-separated UInt256 ids for bridge txs / finalize (default `1`). */
  keeperUInt256Ids: "1",
  /** Back-compat alias for keeperUInt256Ids. */
  handleStakesUInt256Ids: "1",
  /** Upper bound on FLOW debited from the signer for bridge fees (`UFix64`), passed to handle_stakes / initiate_unstakes. */
  keeperMaxBridgeFlowFee: "10.0",
  /** Appended verbatim to the generated `flow transactions send` line (e.g. `--config-path flow.deploy.json`). */
  keeperFlowCliExtra: "--config-path flow.deploy.json",
});

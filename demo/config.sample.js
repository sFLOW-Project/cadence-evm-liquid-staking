// Default demo config (safe to commit). Copy to `config.local.js` (gitignored) and override.
window.DEMO_CONFIG = Object.assign(window.DEMO_CONFIG || {}, {
  flowAccessRest: "https://rest-testnet.onflow.org",
  evmRpc: "https://testnet.evm.nodes.onflow.org",
  evmChainId: 545,
  /** Cadence account where `LiquidStaking` + `sFlowToken` live (with `0x`). */
  cadenceDeployer: "0x2ebe72605dfc9fd0",
  /** Core contract — testnet default from `flow.json`. */
  flowIDTableStaking: "0x9eca2b38b18b5dfe",
  lspVault: "0xCDb6839Bb928436C412E8F1DFb02D6CeAF432B92",
  bridgedSFlow: "0x4e1ef470e39d6481199cc4577ecd75b38e217702",
  /** Used for bridging / tooling; Cadence vault type identifier for bridged `sFlowToken.Vault`. */
  vaultIdentifier: "A.2ebe72605dfc9fd0.sFlowToken.Vault",
  /** Optional: EVM address to show bridged sFlow `balanceOf`. */
  evmBalanceOfAddress: "0xF961DB7172ea9069F1E62eF92F410aC48bCc6088",
  flowSigner: "testnet-acc",
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
  keeperFlowCliExtra: "",
});

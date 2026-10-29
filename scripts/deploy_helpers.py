#!/usr/bin/env python3
"""Helpers for protocol-deploy.sh.

Subcommands:
  rewrite-imports <flow_config.json> <network> <deployer_addr> <source.cdc> [local_names...]
      Rewrites `import "Name"` identifier-syntax imports in a Cadence source file into
      `import Name from 0x...` address-syntax imports. Needed because the deployment
      transactions (`install_liquid_staking_config.cdc`, `install_liquid_staking.cdc`,
      `install_relayer_router.cdc`) pass contract source as a `String` transaction argument;
      flow-cli only rewrites `import "X"` in the *transaction file* it sends, never inside
      string argument payloads, so contracts using identifier-syntax imports must be
      pre-resolved before being embedded as a `code` argument.
      `local_names` are contract names resolved to `deployer_addr` (contracts deployed on the
      same protocol account in this run, e.g. LiquidStaking/LiquidStakingConfig/sFlowToken/
      EVMRoute/RelayerRouter) rather than looked up in the config's alias tables.

  bytes-to-json <0xHEX>
      Encodes a hex string as a JSON-Cadence `{"type":"Array","value":[{"type":"UInt8",...}]}`
      payload, for passing large bytecode blobs to `flow transactions send --args-json`.
"""
import json
import re
import sys


# Flow core-protocol / VM-bridge contracts that are not declared (or not aliased for every
# network) under "dependencies" in flow.deploy.json. Used only as a fallback when the
# project's own config has no alias for the current network. Addresses cross-checked against
# https://developers.flow.com/references/core-contracts/staking-contract-reference,
# .../epoch-contract-reference, and the canonical onflow/flow-evm-bridge flow.json.
CORE_CONTRACT_FALLBACKS = {
    "mainnet": {
        "FlowIDTableStaking": "8624b52f9ddcd04a",
        "FlowEpoch": "8624b52f9ddcd04a",
    },
    "testnet": {
        "FlowIDTableStaking": "9eca2b38b18b5dfe",
        "FlowEpoch": "9eca2b38b18b5dfe",
        # flow.deploy.json only aliases these for mainnet; testnet filled in here.
        "FlowEVMBridge": "dfc20aee650fcbdf",
        "FlowEVMBridgeConfig": "dfc20aee650fcbdf",
        "FlowEVMBridgeUtils": "dfc20aee650fcbdf",
        "ScopedFTProviders": "dfc20aee650fcbdf",
    },
    "emulator": {
        "FlowIDTableStaking": "f8d6e0586b0a20c7",
        "FlowEpoch": "f8d6e0586b0a20c7",
    },
}


def cmd_rewrite_imports(args):
    flow_config_path, network, deployer, source_file = args[:4]
    local_names = set(args[4:])

    with open(flow_config_path) as f:
        cfg = json.load(f)

    addr_map = dict(CORE_CONTRACT_FALLBACKS.get(network, {}))
    for section in ("contracts", "dependencies"):
        for name, entry in cfg.get(section, {}).items():
            aliases = entry.get("aliases", {}) if isinstance(entry, dict) else {}
            if network in aliases:
                addr_map[name] = aliases[network]

    for name in local_names:
        addr_map[name] = deployer

    with open(source_file) as f:
        src = f.read()

    def repl(m):
        name = m.group(1)
        if name not in addr_map:
            sys.exit(
                f"deploy_helpers.py: no address for import \"{name}\" on network "
                f"{network}; add an alias to {flow_config_path} or pass it as a "
                f"local contract name"
            )
        addr = addr_map[name]
        if not addr.startswith("0x"):
            addr = "0x" + addr
        return f"import {name} from {addr}"

    sys.stdout.write(re.sub(r'import\s+"(\w+)"', repl, src))


def cmd_bytes_to_json(args):
    hexstr = args[0]
    if hexstr.startswith(("0x", "0X")):
        hexstr = hexstr[2:]
    data = bytes.fromhex(hexstr)
    payload = {
        "type": "Array",
        "value": [{"type": "UInt8", "value": str(b)} for b in data],
    }
    sys.stdout.write(json.dumps(payload))


COMMANDS = {
    "rewrite-imports": cmd_rewrite_imports,
    "bytes-to-json": cmd_bytes_to_json,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.stderr.write(f"usage: {sys.argv[0]} <{'|'.join(COMMANDS)}> [args...]\n")
        sys.exit(2)
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()

# Deployment

## LSP deployment Cadence and EVM

Copy the config and insert values in the copied config (fee percent, receiver, private key and etc.):
```bash 
    cp protocol-deploy.config.example protocol-deploy.config
```

Run the script:
```bash
    ./protocol-deploy.sh
```

- The script will run the deployment using the provided config. You can configure retry attempts and delay between retries.
- All operations are running cadence transactions from [transactions/deployment](./cadence/transactions/deployment/).
- All steps are idempotent and if one one the steps fails, the script will verify current state of the deployment and run next unfinished steps.
- Due to argument size limit in bash EVM Vault contract is precompiled as bytes array in the [deploy_lsp_vault_evm transaction](./cadence/transactions/deployment/deploy_lsp_vault_evm.cdc).
- All of the deployed contract addresses will be stored in the ```.protocol-deploy-state.{network}.env```.

___

## Keeper bot

Copy the env example file and insert values in the copied evn file:
```bash 
    cd keeper; cp env.example .env
```
You can use any cadence account PK in the env as bot will only interract with permissionless router on cadence.

Run run it locally with docker-compose or create an image and deploy as a container with the dockerfile.
```bash
    docker-compose up
```

- it will create a local PG container with persitent volume
- watch EVM vault logs
- store pending unstakes
- update rewards on epoch flips
___

## Demo

Copy the config file and fill it:
```bash
    cp config.local.example.js config.local.js
```
Otherwise the demo will use [sample config](./demo/config.sample.js).

Run the demo:
```bash
    python3 -m http.server --directory ./demo/
```
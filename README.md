# Gearbox DCA Strategy Bot
For local mainnet fork testing:
```
forge install
forge test --match-path test/DCABot.t.sol
```
For testing of live Gearbox Anvil network:
Request test tokens & degen NFT [here](https://anvil.gearbox.foundation/forks/Ethereum/faucet) then operate with the scripts
```
forge script script/DCABot.s.sol --rpc-url anvilGearbox --broadcast
```
## Issues faced making the project
1) Updated USDC mainnet deployment was incompatible with older **forge-std** version of the  **dev-bots-tutorial** repo. Had to update the dependency
2) Initially thought of utilizing Foundry dependencies but couldn't compile integrations-v3 while resolving AdapterType.sol since it's reliant on node packages which I wanted to avoid - opted to copy the required interfaces in limited form
3) Got some reverts when using the wrong version of UniV3 adapter - **0xAe4d093C7322ecEC9234d480A459E3537Fd6029F** Eventually found out through the contractToAdapter call that the real adapter is **0xea8199179D6A589A0C2Df225095C1DB39A12D257**

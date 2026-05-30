# Ether Wars Contracts

Smart contracts for an onchain tournament strategy game. Players enter a tournament with equal ETH deposits, are grouped into table/island-style groups of up to 9 players, and play commit/reveal battle rounds using virtual game resources.

## Project Overview

The current architecture is tournament-based, not a persistent world or insurance protocol. ETH principal and yield/profit are handled at the tournament layer through a generic yield adapter. Gameplay state is virtual: gold, food, water, population, and army are tracked in contracts and are not ERC20/aToken balances.

## Current Architecture

```text
Players
  -> TournamentManager
       -> IYieldAdapter
            -> NoYieldAdapter now
            -> future Aave/stETH/wstETH adapter later
       -> LandLord clones
       -> BattleManager
            -> commit/reveal actions
            -> battle resolution callbacks
       -> ChainlinkVRFProvider
            -> Chainlink VRF coordinator

WorldGraph
  -> experimental future feature, not core to current table model
```

## Main Contracts

- `contracts/LandLordFactory.sol`
  - Defines `TournamentManager`.
  - Handles equal entry deposits, player registration, table assignment, round transitions, principal/yield accounting, LandLord clone creation, battle settlement hooks, and VRF handoff.

- `contracts/BattleManager.sol`
  - Handles commit/reveal rounds.
  - Current actions are `ATTACK`, `DEFEND`, and `BUILD`.
  - Enforces one attack per player per round and keeps only the highest-wager attack per defender.

- `contracts/LandLord.sol`
  - Per-player virtual city/resource state.
  - Tracks gold, food, water, population, army, buildings, derived attack/defense stats, build actions, decay, and gold transfers.
  - Does not hold ETH, aTokens, or yield assets.

- `contracts/interfaces/protocol/IYieldAdapter.sol`
  - Generic ETH yield adapter interface used by the tournament layer.

- `contracts/NoYieldAdapter.sol`
  - Minimal adapter that accepts ETH and returns 1:1 shares without generating yield.

- `contracts/ChainlinkVRFProvider.sol`
  - Thin VRF adapter. TournamentManager requests randomness and forwards approved randomness to BattleManager.

- `contracts/WorldGraph.sol`
  - Experimental future graph/map prototype. It is preserved for reference but is not part of the active table-based tournament flow.

## Tournament Flow

1. Admin deploys/configures `TournamentManager`, `LandLord` implementation, yield adapter, `BattleManager`, and VRF provider.
2. Players register with the same ETH entry deposit.
3. TournamentManager deposits ETH into the configured `IYieldAdapter`.
4. TournamentManager creates a `LandLord` clone for each player and assigns starting virtual resources.
5. Players are assigned to tables with a max size of 9.
6. Each round snapshots table membership, requests randomness, runs commit/reveal, resolves battles, applies decay, and rebalances tables between rounds.
7. At tournament end, participant principal can be claimed. Yield/profit above principal can be awarded to the winner.

## Commit/Reveal Battle Flow

Players first commit a hash, then reveal their action during the reveal phase. The commit hash includes tournament id, round id, player, action type, target, wager, salt, chain id, and BattleManager address.

Actions:

- `ATTACK`: targets an active player at the same frozen round table and includes a positive gold wager.
- `DEFEND`: default action if a player does not reveal; no wager.
- `BUILD`: no wager; improves non-gold resources through LandLord.

If multiple players attack the same defender in one round, only the highest gold wager is eligible to resolve. Ties use available randomness when possible, with deterministic fallback logic.

## Resource Model

Gold is the main tournament survival currency and the only attack wager. Food, water, population, and army are virtual game resources used for build/decay/stat mechanics.

LandLord owns gameplay accounting only. ETH principal, yield, and adapter shares stay in TournamentManager/yield adapter logic.

## Yield Adapter Model

TournamentManager depends on `IYieldAdapter`, not directly on Aave, stETH, wstETH, or any specific yield source.

Current adapter:

- `NoYieldAdapter`: holds ETH without yield and reports ETH balance as total assets.

Future adapters can implement the same interface for Aave, stETH, wstETH, or another yield source without moving financial logic into LandLord or BattleManager.

## Contracts Kept For Future/Legacy Reference

The repo still contains older SLI/insurance, reserve, premium generator, Aave, oracle, mock, and map contracts. These compile but are not the active game architecture unless explicitly wired through the current tournament model.

Notably:

- `WorldGraph.sol` is kept as an experimental future feature.
- Premium/Aave contracts may be useful as references for a future `IYieldAdapter` implementation.
- Reserve, validator insurance, beneficiary, and Chainlink Functions oracle contracts are legacy SLI architecture.

## Development Notes / TODOs

- Rename `LandLordFactory.sol` to match its current `TournamentManager` contract.
- Extract local manager/provider interfaces into dedicated interface files.
- Add tests for registration, table snapshots, commit/reveal, battle settlement, rebalancing, principal claims, and yield claims.
- Replace `NoYieldAdapter` with a real audited adapter only after choosing the final yield source.
- Review gas limits for full-table rebalancing and per-round decay loops before large tournaments.
- Audit access control, settlement accounting, and randomness assumptions before deployment.

## Commands

```bash
npm install
npm run compile
npm test
```

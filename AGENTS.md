# Repository Guidelines

## Project Structure & Module Organization

This repository contains Hardhat smart contracts for an onchain tournament strategy game. Core Solidity sources live in `contracts/`, with current game flow centered on `TournamentManager.sol`, `LandLord.sol`, `BattleManager.sol`, `ChainlinkVRFProvider.sol`, and `NoYieldAdapter.sol`. Protocol interfaces are under `contracts/interfaces/`, shared Solidity helpers under `contracts/libraries/`, and test-only contracts under `contracts/mocks/`.

Hardhat tests live in `test/` and use `*.test.js` names. Deployment scripts are in `scripts/`; architecture notes are in `scripts/docs/`. The legacy Truffle setup is preserved in `legacy/`. The React frontend is in `client/`, with source under `client/src/`, public assets under `client/public/`, and generated build output under `client/build/`.

## Build, Test, and Development Commands

- `npm install`: install root Hardhat dependencies.
- `npm run compile`: compile Solidity contracts using Hardhat.
- `npm test`: run the Hardhat test suite in `test/`.
- `npm run node`: start a local Hardhat JSON-RPC node.
- `npm run deploy`: run `scripts/deploy.js` against the configured network.
- `cd client && npm start`: run the React app locally.
- `cd client && npm run build`: produce a static frontend build.

Network configuration is in `hardhat.config.js`; use `.env` for `PRIVATE_KEY`, `MNEMONIC`, and RPC URLs.

## Coding Style & Naming Conventions

Solidity targets version `0.8.20` with optimizer enabled. Use 4-space indentation in Solidity and keep contract, interface, enum, struct, event, and error names in `PascalCase`. Use `camelCase` for functions, variables, mappings, and event parameters. Keep access-control modifiers explicit and prefer existing patterns such as `onlyAdmin`, `onlyBattleManager`, and `onlyController`.

JavaScript tests and scripts use CommonJS, `ethers`, and `chai`. Match the existing 2-space indentation in test files.

## Contract Resource Rules

Contracts should track only tournament state, virtual resources, gold allocation, battle actions, settlement, elimination, ETH deposits, and yield accounting. Buildings and tiles are front-end/UI abstractions only; do not add building-specific contract logic unless explicitly requested.

Resource allocation should be simple and auditable. Prefer direct 1:1 gold-to-resource accounting. Population should be derived from round number, not stored as mutable player state. Oxygen is a first-class survival resource alongside food, water, shelter, and army.

## Testing Guidelines

Use Hardhat tests with Mocha/Chai. Add or update tests for any contract behavior change, especially resource accounting, battle settlement, table snapshots, yield adapter withdrawals, and elimination rules. Prefer focused test names that describe behavior, for example `it("caps payment at remaining gold and eliminates an underfunded loser", ...)`.

Run `npm test` before opening a PR. Run `npm run compile` when changing Solidity interfaces, imports, or compiler-sensitive code.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, lowercase summaries, such as `add decay skip for build feature` and `switch to hardhat`. Keep commits scoped to one logical change.

Pull requests should include a concise description, key contract or frontend files touched, test results, and any deployment/configuration notes. Link related issues when available. Include screenshots only for visible frontend changes.

## Security & Configuration Tips

Do not commit private keys, mnemonics, RPC secrets, generated caches, or local deployment artifacts. Treat yield adapter, settlement, randomness, and access-control changes as high risk and document assumptions clearly in the PR.

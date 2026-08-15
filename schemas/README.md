# Indexed JSON documents

This directory defines the JSON interface between the Ether Wars indexer and frontend.

- `*.example.json` files are representative indexed documents.
- `*.schema.json` files are JSON Schema Draft-07 validation schemas.
- `definitions.schema.json` contains definitions shared by the document schemas.

Round documents retain finalized round history. Aggregate counts and settlement totals are
derived from indexed events, while lifecycle block hashes and timestamps are indexer
metadata anchored to those events. Completion flags mirror the contract's mining,
population-check, automatic-expansion, and table-rebalancing finalization stages.
`RoundEnded` does not imply that the next round has already been initialized, so that
condition is intentionally absent from `completion`.

All Solidity integers are encoded as base-10 strings so frontend consumers do not lose
precision. Addresses and byte values use `0x`-prefixed hexadecimal strings. Every document
in a published snapshot must use the same chain, tournament, block number, block hash, and
snapshot ID as the manifest.

`playerId` is an indexer-assigned identifier derived from registration order; it is not a
Solidity player ID. `seat.index` is derived from the indexed table-player array and is not a
stable onchain seat. Neighbor relationships contain all other active players at the same
table and have no canonical direction.

Player documents are indexer-owned and primarily contain blockchain-derived player and
colony state. A colony's `worldState` property is only a reference; visual state is not
embedded in the player document.

Player `roundHistory` is an ascending, per-round ledger. The round-level `action` stores
the revealed or defaulted action, including attack source colony, target player, target
colony, and wager. Each colony entry records its allocation, starting and ending resource
snapshots, and ordered resource changes. Changes are ordered by block number and log
index; signed decimal deltas are derived by comparing consecutive
`ColonyResourcesUpdated` snapshots. Battle outcomes remain in the existing battle-result
documents and are not duplicated in this ledger.
This required history field makes the player document schema version `2`; consumers of
version `1` player documents should treat a missing history as an empty array during
migration.

Player schema version `3` removes `projectedMiningYield` and
`projectedNetGoldChange` from colony economy data. Producers must omit these fields;
consumers that need projections should calculate them outside the canonical indexed
player document.

World-state documents are frontend-originated visual colony data. The backend will
eventually validate and publish their public form alongside the rest of a snapshot. The
current `world-state.schema.json` is intentionally provisional: its `buildings` entries are
generic objects, and final building and terrain formats will be defined after frontend
persistence is designed. Frontend consumers must not treat this placeholder structure as
permanent. World state is not canonical contract state.

JSON Schema validates the reference and world-state documents independently; it cannot
verify that a referenced path exists or that its player and colony identities match. Add
that cross-document integrity check to the backend snapshot validator when it is built.

The canonical resource model is Gold plus Attack, Defense, Mining, and Infrastructure.

# Indexed JSON documents

This directory defines the JSON interface between the Ether Wars indexer and frontend.

- `*.example.json` files are representative indexed documents.
- `*.schema.json` files are JSON Schema Draft-07 validation schemas.
- `definitions.schema.json` contains definitions shared by the document schemas.

All Solidity integers are encoded as base-10 strings so frontend consumers do not lose
precision. Addresses and byte values use `0x`-prefixed hexadecimal strings. Every document
in a published snapshot must use the same chain, tournament, block number, block hash, and
snapshot ID as the manifest.

`playerId` is an indexer-assigned identifier derived from registration order; it is not a
Solidity player ID. `seat.index` is derived from the indexed table-player array and is not a
stable onchain seat. Neighbor relationships contain all other active players at the same
table and have no canonical direction.

`worldState` is explicitly UI-owned. Its buildings are not contract state. The canonical
resource model is Gold plus Terraform, Attack, Defense, Mining, and Infrastructure.
Projected economy fields should be recalculated at the snapshot block and must not be
treated as already-settled transfers.

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

contract MapRegistry {

    uint128 public constant ORIGIN     = type(uint128).max / 2;
    uint256 public constant SPAWN_RADIUS = 10;

    struct Player {
        uint128 x;
        uint128 y;
        bool exists;
    }

    uint256 public nextPlayerId;

    mapping(address => Player)                        public players;
    mapping(uint128 => mapping(uint128 => address))   public grid;

    event PlayerRegistered(address indexed player, uint128 x, uint128 y);

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    /// @param anchor An already-registered player to spawn next to.
    ///               Pass address(0) only for the very first player.
    function registerPlayer(address player, address anchor) internal {
        require(!players[player].exists, "Already registered");

        uint128 cx;
        uint128 cy;

        if (anchor == address(0)) {
            // First player — seed the origin
            require(nextPlayerId == 0, "Use an anchor after first player");
            cx = ORIGIN;
            cy = ORIGIN;
        } else {
            // Anchor must exist and be registered
            Player memory a = players[anchor];
            require(a.exists, "Anchor not registered");
            cx = a.x;
            cy = a.y;
        }

        (uint128 sx, uint128 sy) = _findSpawn(cx, cy);

        players[player] = Player(sx, sy, true);
        grid[sx][sy] = player;
        nextPlayerId++;

        emit PlayerRegistered(player, sx, sy);
    }

    // -----------------------------------------------------------------------
    // Neighbor lookup — O(1), no loops
    // -----------------------------------------------------------------------

    function getNeighbors(address player)
        external view returns (address[4] memory)
    {
        Player memory p = players[player];
        require(p.exists, "Not registered");

        return [
            grid[p.x][p.y - 1],  // North  (no underflow: coords >= ORIGIN/2)
            grid[p.x][p.y + 1],  // South
            grid[p.x - 1][p.y],  // West
            grid[p.x + 1][p.y]   // East
        ];
    }

    function getNeighbors8(address player)
        external view returns (address[8] memory)
    {
        Player memory p = players[player];
        require(p.exists, "Not registered");

        return [
            grid[p.x - 1][p.y - 1],
            grid[p.x    ][p.y - 1],
            grid[p.x + 1][p.y - 1],
            grid[p.x - 1][p.y    ],
            grid[p.x + 1][p.y    ],
            grid[p.x - 1][p.y + 1],
            grid[p.x    ][p.y + 1],
            grid[p.x + 1][p.y + 1]
        ];
    }

    // -----------------------------------------------------------------------
    // Spawn search — spiral from anchor, guarantee a neighbor
    // -----------------------------------------------------------------------

    function _findSpawn(uint128 cx, uint128 cy)
        internal view returns (uint128, uint128)
    {
        // r=1 first — this guarantees the result is always adjacent to anchor
        for (uint256 r = 1; r <= SPAWN_RADIUS; r++) {
            uint256 perim = r * 8;
            for (uint256 i = 0; i < perim; i++) {
                (uint128 spawnX, uint128 spawnY) = _spiralOffset(cx, cy, r, i);
                if (grid[spawnX][spawnY] == address(0)) {
                    // For r > 1 we must verify at least one cardinal neighbor is occupied
                    if (r == 1 || _hasNeighbor(spawnX, spawnY)) {
                        return (spawnX, spawnY);
                    }
                }
            }
        }
        revert("No valid spawn found near anchor");
    }

    function _hasNeighbor(uint128 x, uint128 y) internal view returns (bool) {
        return grid[x][y - 1] != address(0) ||
               grid[x][y + 1] != address(0) ||
               grid[x - 1][y] != address(0) ||
               grid[x + 1][y] != address(0);
    }

    function _spiralOffset(uint128 cx, uint128 cy, uint256 r, uint256 i)
        internal pure returns (uint128, uint128)
    {
        uint256 side = i / r;
        uint256 pos  = i % r;

        int256 dx;
        int256 dy;

        if      (side == 0) { dx = int256(pos) - int256(r); dy = -int256(r); }
        else if (side == 1) { dx =  int256(r);              dy =  int256(pos) - int256(r); }
        else if (side == 2) { dx =  int256(r) - int256(pos);dy =  int256(r); }
        else                { dx = -int256(r);              dy =  int256(r) - int256(pos); }

        // Safe because ORIGIN = type(uint128).max / 2, so there's room on all sides
        return (
            uint128(uint256(int256(uint256(cx)) + dx)),
            uint128(uint256(int256(uint256(cy)) + dy))
        );
    }
}

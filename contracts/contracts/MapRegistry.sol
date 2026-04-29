// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MapRegistry {

    uint256 public constant MAX_NEIGHBORS = 25;
    uint256 public constant MAX_NEIGHBOR_SEARCH = 10;

    uint256 public nextPlayerId;

    mapping(uint256 => address) public playerById;
    mapping(address => uint256) public playerId;

    mapping(address => address[]) public neighbors;
    mapping(address => mapping(address => bool)) public isNeighbor;


    function registerPlayer(address player, uint256 neighborCount) internal {

        uint256 id = nextPlayerId++;

        playerById[id] = player;
        playerId[player] = id;

        if (id == 0) return;

        uint256 added;

        uint256 step = id / MAX_NEIGHBOR_SEARCH + 1;
        mapping(uint256 => bool) attempted;

        for (uint256 i = 1; i <= MAX_NEIGHBOR_SEARCH && added < neighborCount; i++) {

            uint256 index;

            if (attempted[index]) continue;
            attempted[index] = true;

            // Try nearby players first
            if (i <= neighborCount) {
                index = id > i ? id - i : 0;
            }
            // Then spread out
            else {
                uint256 spread = i * step;
                index = id > spread ? id - spread : 0;
            }

            address neighbor = playerById[index];

            bool success = _addNeighbor(player, neighbor);

            if (success) {
                added++;
            }
        }
    }


    function _addNeighbor(address a, address b) internal returns(bool){

        if (a == b) return;

        if (isNeighbor[a][b]) return false;

        if (neighbors[a].length >= MAX_NEIGHBORS) return false;
        if (neighbors[b].length >= MAX_NEIGHBORS) return false;

        neighbors[a].push(b);
        neighbors[b].push(a);

        isNeighbor[a][b] = true;
        isNeighbor[b][a] = true;

        return true;
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MapRegistry {

    uint256 public constant GRID_SIZE = 100;   // 100x100 map
    uint256 public constant SPAWN_RADIUS = 10;  // search radius for free cells

    struct Player {
        uint256 x;
        uint256 y;
        bool exists;
    }

    uint256 public nextPlayerId;

    mapping(address => Player)             public players;
    mapping(uint256 => mapping(uint256 => address)) public grid; // grid[x][y]

    event PlayerRegistered(address indexed player, uint256 x, uint256 y);

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    function registerPlayer(address player, uint256 preferredX, uint256 preferredY) internal {
        require(!players[player].exists, "Already registered");
        require(preferredX < GRID_SIZE && preferredY < GRID_SIZE, "Out of bounds");

        (uint256 spawnX, uint256 spawnY) = _findSpawn(preferredX, preferredY);

        players[player] = Player(spawnX, spawnY, true);
        grid[spawnX][spawnY] = player;
        nextPlayerId++;

        emit PlayerRegistered(player, spawnX, spawnY);
    }

    // -----------------------------------------------------------------------
    // Neighbor lookup — pure O(1), no loops needed
    // -----------------------------------------------------------------------

    // 8-directional (includes diagonals)
    function getNeighbors8(address player)
        external view returns (address[8] memory)
    {
        Player memory p = players[player];
        require(p.exists, "Not registered");

        return [
            (p.x > 0 && p.y > 0)                          ? grid[p.x-1][p.y-1] : address(0),
            (p.y > 0)                                      ? grid[p.x  ][p.y-1] : address(0),
            (p.x+1 < GRID_SIZE && p.y > 0)                ? grid[p.x+1][p.y-1] : address(0),
            (p.x > 0)                                      ? grid[p.x-1][p.y  ] : address(0),
            (p.x+1 < GRID_SIZE)                            ? grid[p.x+1][p.y  ] : address(0),
            (p.x > 0 && p.y+1 < GRID_SIZE)                ? grid[p.x-1][p.y+1] : address(0),
            (p.y+1 < GRID_SIZE)                            ? grid[p.x  ][p.y+1] : address(0),
            (p.x+1 < GRID_SIZE && p.y+1 < GRID_SIZE)      ? grid[p.x+1][p.y+1] : address(0)
        ];
    }

    // -----------------------------------------------------------------------
    // Spawn search — spiral outward from preferred position
    // -----------------------------------------------------------------------

    function _findSpawn(uint256 cx, uint256 cy)
        internal view returns (uint256, uint256)
    {
        // Try preferred cell first
        if (grid[cx][cy] == address(0)) return (cx, cy);

        // Spiral outward up to SPAWN_RADIUS
        for (uint256 r = 1; r <= SPAWN_RADIUS; r++) {
            for (uint256 i = 0; i < r * 8; i++) {
                (uint256 tx, uint256 ty) = _spiralOffset(cx, cy, r, i);
                if (tx < GRID_SIZE && ty < GRID_SIZE && grid[tx][ty] == address(0)) {
                    return (tx, ty);
                }
            }
        }

        revert("No spawn found near preferred location");
    }

    function _spiralOffset(uint256 cx, uint256 cy, uint256 r, uint256 i)
        internal pure returns (uint256, uint256)
    {
        // Walk the perimeter of a square at radius r
        uint256 side = i / r;    // 0=top, 1=right, 2=bottom, 3=left
        uint256 pos  = i % r;

        int256 dx;
        int256 dy;

        if      (side == 0) { dx = int256(pos) - int256(r); dy = -int256(r); }
        else if (side == 1) { dx =  int256(r);              dy = int256(pos) - int256(r); }
        else if (side == 2) { dx = int256(r) - int256(pos); dy =  int256(r); }
        else                { dx = -int256(r);              dy = int256(r) - int256(pos); }

        int256 tx = int256(cx) + dx;
        int256 ty = int256(cy) + dy;

        // Return (0,0) as sentinel for out-of-bounds — caller checks grid bounds
        if (tx < 0 || ty < 0) return (type(uint256).max, type(uint256).max);
        return (uint256(tx), uint256(ty));
    }
}


//V3


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
                (uint128 tx, uint128 ty) = _spiralOffset(cx, cy, r, i);
                if (grid[tx][ty] == address(0)) {
                    // For r > 1 we must verify at least one cardinal neighbor is occupied
                    if (r == 1 || _hasNeighbor(tx, ty)) {
                        return (tx, ty);
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
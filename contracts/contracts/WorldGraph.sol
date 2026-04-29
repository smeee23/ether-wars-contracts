// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract WorldGraph {

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint256 public constant MIN_DEPOSIT     = 0.1 ether;
    uint256 public constant MAX_NEIGHBORS   = 12;
    uint256 public constant BASE_NEIGHBORS  = 2;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    address reserve;
    struct Player {
        uint256 deposit;
        bool    exists;
        uint256 conquests;
    }

    uint256 public nextPlayerId;
    mapping(uint256  => address)                    public playerById;
    mapping(address  => uint256)                    public playerId;
    mapping(address  => Player)                     public players;
    mapping(address  => address[])                  public neighbors;
    mapping(address  => mapping(address => bool))   public isNeighbor;
    mapping(address  => mapping(address => bool))   public isConquered; // winner => loser

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event PlayerRegistered(address indexed player, uint256 deposit, uint256 neighborCount);
    event EdgeAdded       (address indexed a, address indexed b);
    event EdgeRemoved     (address indexed a, address indexed b);
    //event PlayerDefeated  (address indexed winner, address indexed loser, uint256 edgesAbsorbed);
    event PlayerRemoved   (address indexed player);
    event PlayerDefeated(
        address indexed winner,
        address indexed loser,
        uint256 winnerAbsorbed,  // edges winner gained (incl. odd bonus)
        uint256 paired,          // new peer-to-peer edges formed
        uint256 rescued          // zero-neighbor rescues
    );

    modifier onlyReserve(){
        require(reserve == msg.sender, "not the reserve");
        _;
    }

    constructor(address _reserve){
        reserve = _reserve;
    }


    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    function _registerPlayer(uint256 deposit) internal {
        require(deposit >= MIN_DEPOSIT,      "Deposit too small");
        require(!players[msg.sender].exists,   "Already registered");

        uint256 id = nextPlayerId++;
        playerById[id]      = msg.sender;
        playerId[msg.sender] = id;
        players[msg.sender]  = Player(deposit, true);

        uint256 targetNeighbors = _neighborCountFromDeposit(deposit);

        emit PlayerRegistered(msg.sender, deposit, targetNeighbors);

        if (id == 0) return; // First player has no one to connect to

        _seedNeighbors(msg.sender, id, targetNeighbors);
    }

    function _seedNeighbors(address player, uint256 id, uint256 target) internal {
        uint256 added;
        uint256 step = (id / 10) + 1;

        for (uint256 i = 1; i <= id && added < target; i++) {
            // Walk backwards with increasing step to sample different "regions"
            uint256 candidateId = id - ((i - 1) * step + 1);
            if (candidateId >= id) break; // underflow guard

            address candidate = playerById[candidateId];
            if (candidate == address(0)) continue;

            if (_addEdge(player, candidate)) added++;

            if (candidateId == 0) break;
        }
    }

    // -----------------------------------------------------------------------
    // Defeat
    // -----------------------------------------------------------------------

    /// @notice Called by game logic after winner beats loser.
    ///         Absorbs loser's edges into winner and removes the loser.
    function processDefeat(address winner, address loser) external {
        require(players[winner].exists,    "Winner not registered");
        require(players[loser].exists,     "Loser not registered");
        require(isNeighbor[winner][loser], "Must be neighbors to fight");

        // --- Build orphan pool (loser's neighbors, excluding winner) ---
        address[] memory pool = _buildOrphanPool(winner, loser);

        // Remove all of loser's edges upfront
        _removeAllEdges(loser);

        // Record conquest before calling _maxNeighbors so the cap is already updated
        players[winner].conquests += 1;

        // --- Step 1: Winner absorbs floor(pool / 2) ---
        uint256 winnerShare = pool.length / 2;
        uint256 winnerAbsorbed;
        uint256 poolCursor;

        for (; poolCursor < pool.length && winnerAbsorbed < winnerShare; poolCursor++) {
            if (_addEdge(winner, pool[poolCursor])) winnerAbsorbed++;
        }

        // --- Step 2: Pair up the remainder ---
        uint256 paired;
        uint256 pairStart = poolCursor;

        for (uint256 i = pairStart; i + 1 < pool.length; i += 2) {
            if (_addEdge(pool[i], pool[i + 1])) paired++;
            poolCursor = i + 2;
        }

        // --- Step 3: Odd one out goes to winner ---
        uint256 oddBonus;
        if (poolCursor < pool.length) {
            if (_addEdgeNoMax(winner, pool[poolCursor])) oddBonus = 1;
            poolCursor++;
        }

        // --- Step 4: Zero-neighbor safety net ---
        uint256 rescued;
        for (uint256 i = 0; i < pool.length; i++) {
            if (neighbors[pool[i]].length == 0) {
                if (_addEdgeNoMax(winner, pool[i])) rescued++;
            }
        }

        _removePlayer(loser);

        emit PlayerDefeated(winner, loser, winnerAbsorbed + oddBonus, paired, rescued);
    }

    /// @dev Collects loser's neighbors into a memory array, excluding winner.
    function _buildOrphanPool(address winner, address loser)
        internal view returns (address[] memory)
    {
        address[] storage raw = neighbors[loser];
        address[] memory pool = new address[](raw.length - 1);
        uint256 j;
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] != winner) pool[j++] = raw[i];
        }
        return pool;
    }

    /// @dev Removes all edges belonging to a player before deletion.
    function _removeAllEdges(address player) internal {
        address[] memory ns = neighbors[player]; // copy — we'll mutate storage
        for (uint256 i = 0; i < ns.length; i++) {
            _removeEdge(player, ns[i]);
        }
    }

    // -----------------------------------------------------------------------
    // Graph helpers
    // -----------------------------------------------------------------------

    function _addEdge(address a, address b) internal returns (bool) {
        if (a == b)                  return false;
        if (isNeighbor[a][b])        return false;
        if (neighbors[a].length >= _maxNeighbors(a)) return false;
        if (neighbors[b].length >= _maxNeighbors(b)) return false;

        neighbors[a].push(b);
        neighbors[b].push(a);
        isNeighbor[a][b] = true;
        isNeighbor[b][a] = true;

        emit EdgeAdded(a, b);
        return true;
    }

    function _addEdgeNoMax(address a, address b) internal returns (bool) {
        if (a == b)                  return false;
        if (isNeighbor[a][b])        return false;

        neighbors[a].push(b);
        neighbors[b].push(a);
        isNeighbor[a][b] = true;
        isNeighbor[b][a] = true;

        emit EdgeAdded(a, b);
        return true;
    }

    function _removeEdge(address a, address b) internal {
        if (!isNeighbor[a][b]) return;

        _removeFromArray(neighbors[a], b);
        _removeFromArray(neighbors[b], a);
        isNeighbor[a][b] = false;
        isNeighbor[b][a] = false;

        emit EdgeRemoved(a, b);
    }

    function _removeFromArray(address[] storage arr, address target) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == target) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }

    function _removePlayer(address player) internal {
        uint256 id = playerId[player];
        delete playerById[id];
        delete playerId[player];
        delete players[player];
        // neighbors[] cleaned up by caller before this
        emit PlayerRemoved(player);
    }

    // -----------------------------------------------------------------------
    // Deposit tiers
    // -----------------------------------------------------------------------

    function _neighborCountFromDeposit(uint256 deposit) internal pure returns (uint256) {
        if (deposit >= 10 ether) return 6;
        if (deposit >= 5  ether) return 4;
        if (deposit >= 1  ether) return 3;
        return BASE_NEIGHBORS;
    }

    function _maxNeighbors(address player) internal view returns (uint256) {
        uint256 base;
        uint256 deposit = players[player].deposit;
        if      (deposit >= 10 ether) base = 12;
        else if (deposit >= 5  ether) base = 8;
        else if (deposit >= 1  ether) base = 6;
        else                          base = 4;

        return base + (players[player].conquests * 2);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getNeighbors(address player) external view returns (address[] memory) {
        return neighbors[player];
    }

    /// Two-hop frontier — "territory" visible to the player
    function getFrontier(address player) external view returns (address[] memory) {
        address[] memory myNeighbors = neighbors[player];
        uint256 maxSize = myNeighbors.length * MAX_NEIGHBORS;
        address[] memory frontier = new address[](maxSize);
        uint256 count;

        for (uint256 i = 0; i < myNeighbors.length; i++) {
            address[] memory theirNeighbors = neighbors[myNeighbors[i]];
            for (uint256 j = 0; j < theirNeighbors.length; j++) {
                address n = theirNeighbors[j];
                if (n == player || isNeighbor[player][n]) continue;
                // Deduplicate (simple O(n) scan — fine at small neighbor counts)
                bool seen;
                for (uint256 k = 0; k < count; k++) {
                    if (frontier[k] == n) { seen = true; break; }
                }
                if (!seen) frontier[count++] = n;
            }
        }

        // Trim to actual size
        assembly { mstore(frontier, count) }
        return frontier;
    }
}
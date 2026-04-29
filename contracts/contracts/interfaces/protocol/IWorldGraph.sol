// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorldGraph {

    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    struct Player {
        uint256 deposit;
        bool    exists;
        uint256 conquests;
    }

    // -----------------------------------------------------------------------
    // Constants (exposed as functions)
    // -----------------------------------------------------------------------

    function MIN_DEPOSIT() external view returns (uint256);
    function MAX_NEIGHBORS() external view returns (uint256);
    function BASE_NEIGHBORS() external view returns (uint256);

    // -----------------------------------------------------------------------
    // State Getters
    // -----------------------------------------------------------------------

    function nextPlayerId() external view returns (uint256);

    function playerById(uint256) external view returns (address);
    function playerId(address) external view returns (uint256);

    function players(address) external view returns (
        uint256 deposit,
        bool exists,
        uint256 conquests
    );

    function neighbors(address) external view returns (address[] memory);

    function isNeighbor(address, address) external view returns (bool);
    function isConquered(address, address) external view returns (bool);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event PlayerRegistered(address indexed player, uint256 deposit, uint256 neighborCount);
    event EdgeAdded(address indexed a, address indexed b);
    event EdgeRemoved(address indexed a, address indexed b);
    event PlayerRemoved(address indexed player);

    event PlayerDefeated(
        address indexed winner,
        address indexed loser,
        uint256 winnerAbsorbed,
        uint256 paired,
        uint256 rescued
    );

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    function register() external payable;

    function processDefeat(address winner, address loser) external;

    function getNeighbors(address player) external view returns (address[] memory);

    function getFrontier(address player) external view returns (address[] memory);
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract RewardManager is ReentrancyGuard {
    // =========================
    // CONFIG
    // =========================

    uint256 public constant PRECISION = 1e18;

    // weights (tunable)
    uint256 public attackWeight = 2;
    uint256 public timeWeight = 1;
    uint256 public landWeight = 3;

    // =========================
    // GLOBAL STATE
    // =========================

    uint256 public rewardIndex;        // global accumulator
    uint256 public totalScore;

    uint256 public centralPool;        // unallocated funds
    uint256 public reservedRewards;    // allocated but unclaimed

    // =========================
    // PLAYER STATE
    // =========================

    struct Player {
        uint256 score;
        uint256 rewardIndexSnapshot;
        uint256 accruedRewards;

        // scoring components
        uint256 attackScore;
        uint256 landScore;

        // time tracking
        uint256 lastUpdate;
    }

    mapping(address => Player) public players;

    // =========================
    // MODIFIERS
    // =========================

    modifier update(address user) {
        _updatePlayer(user);
        _;
    }

    // =========================
    // FUNDING CENTRAL POOL
    // =========================

    receive() external payable {
        centralPool += msg.value;
    }

    function fund() external payable {
        centralPool += msg.value;
    }

    // =========================
    // DISTRIBUTION
    // =========================

    function distribute(uint256 amount) external {
        require(amount <= centralPool, "insufficient pool");
        require(totalScore > 0, "no players");

        rewardIndex += (amount * PRECISION) / totalScore;

        centralPool -= amount;
        reservedRewards += amount;
    }

    // =========================
    // CLAIM
    // =========================

    function claim() external nonReentrant update(msg.sender) {
        uint256 reward = players[msg.sender].accruedRewards;
        require(reward > 0, "no rewards");

        players[msg.sender].accruedRewards = 0;
        reservedRewards -= reward;

        (bool ok, ) = msg.sender.call{value: reward}("");
        require(ok, "transfer failed");
    }

    // =========================
    // SCORE UPDATES
    // =========================

    function recordAttack(address user, uint256 amount)
        external
        update(user)
    {
        // simple linear — you can swap for sqrt/log later
        players[user].attackScore += amount * attackWeight;

        _recomputeScore(user);
    }

    function updateLand(address user, uint256 landAmount)
        external
        update(user)
    {
        players[user].landScore = landAmount * landWeight;

        _recomputeScore(user);
    }

    // =========================
    // TIME ACCRUAL
    // =========================

    function _accrueTime(address user) internal {
        Player storage p = players[user];

        if (p.lastUpdate == 0) {
            p.lastUpdate = block.timestamp;
            return;
        }

        uint256 delta = block.timestamp - p.lastUpdate;
        if (delta == 0) return;

        uint256 timeScore = delta * timeWeight;

        p.score += timeScore;
        totalScore += timeScore;

        p.lastUpdate = block.timestamp;
    }

    // =========================
    // INTERNAL: UPDATE PLAYER
    // =========================

    function _updatePlayer(address user) internal {
        Player storage p = players[user];

        // 1. accrue rewards
        uint256 deltaIndex = rewardIndex - p.rewardIndexSnapshot;

        if (deltaIndex > 0 && p.score > 0) {
            uint256 pending = (p.score * deltaIndex) / PRECISION;
            p.accruedRewards += pending;
        }

        p.rewardIndexSnapshot = rewardIndex;

        // 2. accrue time AFTER rewards
        _accrueTime(user);
    }

    // =========================
    // INTERNAL: RECOMPUTE SCORE
    // =========================

    function _recomputeScore(address user) internal {
        Player storage p = players[user];

        uint256 oldScore = p.score;

        // recompute base (exclude time, already added)
        uint256 baseScore =
            p.attackScore +
            p.landScore;

        // keep accumulated time in score (already added via _accrueTime)
        uint256 newScore = baseScore;

        // adjust global total
        totalScore = totalScore - oldScore + newScore;

        p.score = newScore;
    }

    // =========================
    // INITIALIZATION HELPERS
    // =========================

    function initializePlayer(address user) external {
        Player storage p = players[user];

        require(p.lastUpdate == 0, "already initialized");

        p.lastUpdate = block.timestamp;
        p.rewardIndexSnapshot = rewardIndex;
    }

    // =========================
    // VIEW HELPERS
    // =========================

    function pendingRewards(address user) external view returns (uint256) {
        Player memory p = players[user];

        uint256 deltaIndex = rewardIndex - p.rewardIndexSnapshot;

        uint256 pending = p.accruedRewards;

        if (deltaIndex > 0 && p.score > 0) {
            pending += (p.score * deltaIndex) / PRECISION;
        }

        return pending;
    }
}
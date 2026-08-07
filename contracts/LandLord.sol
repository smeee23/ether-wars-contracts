// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title LandLord
 * @notice Virtual gold and resource accounting for one tournament colony.
 * @dev Gold spent on allocations is permanent. Buildings and tiles remain UI abstractions.
 */
contract LandLord is Initializable {
    enum ResourceType {
        Attack,
        Defense,
        Mining,
        Infrastructure
    }

    struct Resources {
        uint128 gold;
        uint128 attack;
        uint128 defense;
        uint128 mining;
        uint128 infrastructure;
    }

    struct ResourceStats {
        uint256 population;
        uint256 attackPower;
        uint256 defensePower;
        uint256 miningYield;
    }

    uint256 public constant POPULATION_BASE = 10;
    uint256 public constant POPULATION_GROWTH_PER_ROUND = 50;
    uint256 public constant GOLD_ALLOCATION_RATE = 1;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MINING_YIELD_BPS = 500;

    // Piecewise-linear Infrastructure curve: 10 bps/unit through 100,
    // 5 bps/unit through 500, then 2 bps/unit, capped at 50%.
    uint256 public constant INFRA_TIER_ONE = 100;
    uint256 public constant INFRA_TIER_TWO = 500;
    uint256 public constant INFRA_RATE_ONE_BPS = 10;
    uint256 public constant INFRA_RATE_TWO_BPS = 5;
    uint256 public constant INFRA_RATE_THREE_BPS = 2;
    uint256 public constant MAX_INFRA_BONUS_BPS = 5_000;
    uint256 public constant MAX_MINING_INFRA_BONUS_BPS = 3_000;

    address public lord;
    address public controller;
    uint64 public lastMiningRound;
    uint128 public eligibleMining;
    uint128 public eligibleInfrastructure;
    uint64 public successfulBuildCount;
    uint64 public lastSuccessfulBuildRound;

    Resources private resources;

    error InsufficientGold(uint256 available, uint256 required);
    error AllocationOverflow();
    error RoundAlreadySettled(uint256 roundId);
    error InvalidRoundOrder(uint256 expected, uint256 actual);
    error BuildAlreadyApplied(uint256 roundId);

    event Initialized(address indexed lord, address indexed controller);
    event GoldSpent(uint256 amount);
    event GoldAwarded(uint256 amount);
    event GoldTransferred(address indexed toLandLord, uint256 amount);
    event ResourceAllocated(ResourceType indexed resource, uint256 goldSpent, uint256 amountAdded);
    event SuccessfulBuildApplied(uint256 indexed round, uint256 successfulBuildCount);
    event MiningYieldCredited(
        uint256 indexed round,
        uint256 eligibleMining,
        uint256 infrastructureBonusBps,
        uint256 goldCredited
    );

    modifier onlyController() {
        require(msg.sender == controller, "not controller");
        _;
    }

    function initialize(
        address _lord,
        address _controller,
        uint256 createdRound,
        Resources calldata startingResources
    ) external initializer {
        require(_lord != address(0), "invalid lord");
        require(_controller != address(0), "invalid controller");
        lord = _lord;
        controller = _controller;
        resources = startingResources;
        lastMiningRound = _toUint64(createdRound);
        eligibleMining = startingResources.mining;
        eligibleInfrastructure = startingResources.infrastructure;
        emit Initialized(_lord, _controller);
    }

    function allocateResources(
        uint256 attack,
        uint256 defense,
        uint256 mining,
        uint256 infrastructure
    ) external onlyController {
        uint256 totalGold = attack + defense + mining + infrastructure;
        if (totalGold == 0) return;
        _spendGold(totalGold);
        _addAllocatedResource(ResourceType.Attack, attack);
        _addAllocatedResource(ResourceType.Defense, defense);
        _addAllocatedResource(ResourceType.Mining, mining);
        _addAllocatedResource(ResourceType.Infrastructure, infrastructure);
    }

    function settleMining(uint256 roundId)
        external
        onlyController
        returns (uint256 credited)
    {
        _requireNextRound(lastMiningRound, roundId);
        lastMiningRound = _toUint64(roundId);

        uint256 infraBonus = infrastructureBonusBps(eligibleInfrastructure);
        if (infraBonus > MAX_MINING_INFRA_BONUS_BPS) {
            infraBonus = MAX_MINING_INFRA_BONUS_BPS;
        }
        uint256 baseYield = uint256(eligibleMining) * MINING_YIELD_BPS / BASIS_POINTS;
        credited = baseYield * (BASIS_POINTS + infraBonus) / BASIS_POINTS;
        if (credited > 0) _awardGold(credited);

        emit MiningYieldCredited(roundId, eligibleMining, infraBonus, credited);
        // New Mining and Infrastructure become yield-eligible only after this round's yield.
        eligibleMining = resources.mining;
        eligibleInfrastructure = resources.infrastructure;
    }

    function applyBuildAction(uint256 roundId) external onlyController {
        if (roundId <= lastSuccessfulBuildRound) revert BuildAlreadyApplied(roundId);
        lastSuccessfulBuildRound = _toUint64(roundId);
        successfulBuildCount += 1;
        emit SuccessfulBuildApplied(roundId, successfulBuildCount);
    }

    function spendGold(uint256 amount) external onlyController {
        _spendGold(amount);
    }

    function awardGold(uint256 amount) external onlyController {
        _awardGold(amount);
    }

    function transferGoldTo(address toLandLord, uint256 amount)
        external
        onlyController
        returns (uint256 transferred)
    {
        require(toLandLord != address(0), "invalid recipient");
        transferred = amount > resources.gold ? resources.gold : amount;
        resources.gold -= uint128(transferred);
        emit GoldTransferred(toLandLord, transferred);
    }

    function getGold() external view returns (uint256) { return resources.gold; }
    function getResources() external view returns (Resources memory) { return resources; }
    function populationForRound(uint256 roundId) public view returns (uint256) {
        uint256 effectiveRound = roundId > successfulBuildCount
            ? roundId - successfulBuildCount
            : 0;
        return POPULATION_BASE + effectiveRound * POPULATION_GROWTH_PER_ROUND;
    }

    function isEliminatedByResourcesForRound(uint256 roundId) public view returns (bool) {
        return resources.gold <= populationForRound(roundId);
    }

    function getResourceStats(uint256 roundId) public view returns (ResourceStats memory) {
        return ResourceStats({
            population: populationForRound(roundId),
            attackPower: effectiveAttack(),
            defensePower: effectiveDefense(),
            miningYield: previewMiningYield()
        });
    }

    function effectiveAttack() public view returns (uint256) {
        return _effectiveCapacity(resources.attack, resources.infrastructure);
    }

    function effectiveDefense() public view returns (uint256) {
        return _effectiveCapacity(resources.defense, resources.infrastructure);
    }

    function previewMiningYield() public view returns (uint256) {
        uint256 bonus = infrastructureBonusBps(eligibleInfrastructure);
        if (bonus > MAX_MINING_INFRA_BONUS_BPS) bonus = MAX_MINING_INFRA_BONUS_BPS;
        uint256 baseYield = uint256(eligibleMining) * MINING_YIELD_BPS / BASIS_POINTS;
        return baseYield * (BASIS_POINTS + bonus) / BASIS_POINTS;
    }

    function infrastructureBonusBps(uint256 infrastructure) public pure returns (uint256 bonus) {
        uint256 first = infrastructure > INFRA_TIER_ONE ? INFRA_TIER_ONE : infrastructure;
        bonus = first * INFRA_RATE_ONE_BPS;
        if (infrastructure > INFRA_TIER_ONE) {
            uint256 secondEnd = infrastructure > INFRA_TIER_TWO ? INFRA_TIER_TWO : infrastructure;
            bonus += (secondEnd - INFRA_TIER_ONE) * INFRA_RATE_TWO_BPS;
        }
        if (infrastructure > INFRA_TIER_TWO) {
            bonus += (infrastructure - INFRA_TIER_TWO) * INFRA_RATE_THREE_BPS;
        }
        if (bonus > MAX_INFRA_BONUS_BPS) bonus = MAX_INFRA_BONUS_BPS;
    }

    function _effectiveCapacity(uint256 capacity, uint256 infrastructure)
        internal pure returns (uint256)
    {
        return capacity * (BASIS_POINTS + infrastructureBonusBps(infrastructure)) / BASIS_POINTS;
    }

    function _spendGold(uint256 amount) internal {
        require(amount > 0, "invalid amount");
        if (resources.gold < amount) revert InsufficientGold(resources.gold, amount);
        resources.gold -= uint128(amount);
        emit GoldSpent(amount);
    }

    function _awardGold(uint256 amount) internal {
        uint256 updated = uint256(resources.gold) + amount;
        if (updated > type(uint128).max) revert AllocationOverflow();
        resources.gold = uint128(updated);
        emit GoldAwarded(amount);
    }

    function _addAllocatedResource(ResourceType resource, uint256 goldAmount) internal {
        if (goldAmount == 0) return;
        uint256 allocated = goldAmount * GOLD_ALLOCATION_RATE;
        if (allocated > type(uint128).max) revert AllocationOverflow();
        if (resource == ResourceType.Attack) resources.attack = _add128(resources.attack, allocated);
        else if (resource == ResourceType.Defense) resources.defense = _add128(resources.defense, allocated);
        else if (resource == ResourceType.Mining) resources.mining = _add128(resources.mining, allocated);
        else resources.infrastructure = _add128(resources.infrastructure, allocated);
        emit ResourceAllocated(resource, goldAmount, allocated);
    }

    function _add128(uint128 current, uint256 amount) internal pure returns (uint128) {
        uint256 updated = uint256(current) + amount;
        if (updated > type(uint128).max) revert AllocationOverflow();
        return uint128(updated);
    }

    function _requireNextRound(uint64 previous, uint256 roundId) internal pure {
        if (roundId <= previous) revert RoundAlreadySettled(roundId);
        uint256 expected = uint256(previous) + 1;
        if (roundId != expected) revert InvalidRoundOrder(expected, roundId);
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert AllocationOverflow();
        return uint64(value);
    }

}

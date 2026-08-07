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
        Terraform,
        Attack,
        Defense,
        Mining,
        Infrastructure
    }

    struct Resources {
        uint128 gold;
        uint128 terraform;
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

    uint256 public constant RESOURCE_UPKEEP = 15;
    uint256 public constant POPULATION_BASE = 10;
    uint256 public constant POPULATION_GROWTH_PER_ROUND = 1;
    uint256 public constant POPULATION_UPKEEP_INTERVAL = 3;
    uint256 public constant GOLD_ALLOCATION_RATE = 1;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MIN_TERRAFORM_DRAIN_BPS = 1_500;
    uint256 public constant MAX_TERRAFORM_DRAIN_BPS = 3_000;
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
    uint64 public supportCredits;
    uint64 public lastMiningRound;
    uint64 public lastTerraformRound;
    uint128 public eligibleMining;
    uint128 public eligibleInfrastructure;

    Resources private resources;

    error InsufficientGold(uint256 available, uint256 required);
    error AllocationOverflow();
    error RoundAlreadySettled(uint256 roundId);
    error InvalidRoundOrder(uint256 expected, uint256 actual);

    event Initialized(address indexed lord, address indexed controller);
    event GoldSpent(uint256 amount);
    event GoldAwarded(uint256 amount);
    event GoldTransferred(address indexed toLandLord, uint256 amount);
    event ResourceAllocated(ResourceType indexed resource, uint256 goldSpent, uint256 amountAdded);
    event ResourcePenaltyApplied(
        uint256 indexed round,
        address indexed player,
        uint256 indexed colonyId,
        ResourceType resource,
        uint256 requested,
        uint256 applied
    );
    event BuildSupportCreditStored(uint256 supportCredits);
    event MiningYieldCredited(
        uint256 indexed round,
        uint256 eligibleMining,
        uint256 infrastructureBonusBps,
        uint256 goldCredited
    );
    event TerraformMaintenanceApplied(
        uint256 indexed round,
        uint256 population,
        uint256 required,
        uint256 available,
        uint256 shortageBps,
        uint256 infrastructureReductionBps,
        uint256 goldDrained,
        bool eliminated
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
        lastTerraformRound = _toUint64(createdRound);
        eligibleMining = startingResources.mining;
        eligibleInfrastructure = startingResources.infrastructure;
        emit Initialized(_lord, _controller);
    }

    function allocateResources(
        uint256 terraform,
        uint256 attack,
        uint256 defense,
        uint256 mining,
        uint256 infrastructure
    ) external onlyController {
        uint256 totalGold = terraform + attack + defense + mining + infrastructure;
        if (totalGold == 0) return;
        _spendGold(totalGold);
        _addAllocatedResource(ResourceType.Terraform, terraform);
        _addAllocatedResource(ResourceType.Attack, attack);
        _addAllocatedResource(ResourceType.Defense, defense);
        _addAllocatedResource(ResourceType.Mining, mining);
        _addAllocatedResource(ResourceType.Infrastructure, infrastructure);
    }

    function applyBuildAction() external onlyController {
        supportCredits += 1;
        emit BuildSupportCreditStored(supportCredits);
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

    function applyTerraformMaintenance(address player, uint256 roundId)
        external
        onlyController
        returns (uint256 drained, bool eliminated)
    {
        require(player == lord, "wrong player");
        _requireNextRound(lastTerraformRound, roundId);
        lastTerraformRound = _toUint64(roundId);

        uint256 required = terraformRequirement(roundId);
        uint256 available = resources.terraform;
        uint256 shortageBps;
        uint256 reductionBps = infrastructureBonusBps(resources.infrastructure);

        if (available < required) {
            shortageBps = (required - available) * BASIS_POINTS / required;
            uint256 drainBps = MIN_TERRAFORM_DRAIN_BPS +
                shortageBps * (MAX_TERRAFORM_DRAIN_BPS - MIN_TERRAFORM_DRAIN_BPS) /
                BASIS_POINTS;
            if (reductionBps > MAX_INFRA_BONUS_BPS) reductionBps = MAX_INFRA_BONUS_BPS;
            drainBps = drainBps * (BASIS_POINTS - reductionBps) / BASIS_POINTS;
            drained = _ceilDiv(uint256(resources.gold) * drainBps, BASIS_POINTS);
            if (drained > resources.gold) drained = resources.gold;
            resources.gold -= uint128(drained);
            if (drained > 0) emit GoldSpent(drained);
        }

        eliminated = resources.gold == 0;
        emit TerraformMaintenanceApplied(
            roundId,
            populationForRound(effectiveRoundForSupport(roundId)),
            required,
            available,
            shortageBps,
            reductionBps,
            drained,
            eliminated
        );
    }

    function spendGold(uint256 amount) external onlyController {
        _spendGold(amount);
    }

    function awardGold(uint256 amount) external onlyController {
        _awardGold(amount);
    }

    function applyResourcePenalty(
        uint256 roundId,
        uint256 colonyId,
        ResourceType resource,
        uint256 amount
    ) external onlyController returns (uint256 applied) {
        require(resource == ResourceType.Terraform, "terraform only");
        applied = amount > resources.terraform ? resources.terraform : amount;
        resources.terraform -= uint128(applied);
        if (applied > 0) {
            emit ResourcePenaltyApplied(roundId, lord, colonyId, resource, amount, applied);
        }
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
    function getPopulationEstimate() external pure returns (uint256) { return populationForRound(0); }
    function getPopulationEstimate(uint256 roundId) public pure returns (uint256) { return populationForRound(roundId); }
    function populationForRound(uint256 roundId) public pure returns (uint256) {
        return POPULATION_BASE + roundId * POPULATION_GROWTH_PER_ROUND;
    }

    function effectiveRoundForSupport(uint256 roundId) public view returns (uint256) {
        return supportCredits >= roundId ? 0 : roundId - supportCredits;
    }

    function terraformRequirement(uint256 roundId) public view returns (uint256) {
        uint256 pressure = 3 + effectiveRoundForSupport(roundId) / POPULATION_UPKEEP_INTERVAL;
        return RESOURCE_UPKEEP * pressure;
    }

    function isEliminatedByResources() public view returns (bool) { return resources.gold == 0; }
    function canSupportRound(uint256 roundId) public view returns (bool) {
        return resources.gold > 0 && resources.terraform >= terraformRequirement(roundId);
    }
    function isEliminatedByResourcesForRound(uint256) public view returns (bool) {
        return resources.gold == 0;
    }

    function getResourceStats(uint256 roundId) public view returns (ResourceStats memory) {
        return ResourceStats({
            population: populationForRound(effectiveRoundForSupport(roundId)),
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
        if (resource == ResourceType.Terraform) resources.terraform = _add128(resources.terraform, allocated);
        else if (resource == ResourceType.Attack) resources.attack = _add128(resources.attack, allocated);
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

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }
}

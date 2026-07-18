// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title LandLord
 * @notice Tournament resource state for one colony.
 * @dev This contract intentionally has no Aave, ETH, aToken, or vault logic.
 *      Gold and the other resources are virtual tournament accounting. Buildings
 *      and tiles are UI abstractions and are intentionally not tracked here.
 */
contract LandLord is Initializable {
    enum ResourceType {
        Food,
        Water,
        Oxygen,
        Shelter,
        Army
    }

    struct Resources {
        uint256 gold;
        uint256 food;
        uint256 water;
        uint256 oxygen;
        uint256 shelter;
        uint256 army;
    }

    struct ResourceStats {
        uint256 population;
        uint256 attackPower;
    }

    uint256 public constant RESOURCE_UPKEEP = 15;
    uint256 public constant POPULATION_BASE = 10;
    uint256 public constant POPULATION_GROWTH_PER_ROUND = 1;
    uint256 public constant POPULATION_UPKEEP_INTERVAL = 3;
    uint256 public constant GOLD_ALLOCATION_RATE = 1;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant ARMY_BONUS_BPS_STEP = 500;
    uint256 public constant MAX_ARMY_BONUS = 20;
    address public lord;
    address public controller;
    uint256 public supportCredits;

    Resources private resources;

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
    event SupportCheckApplied(
        uint256 indexed round,
        uint256 population,
        uint256 foodRequired,
        uint256 waterRequired,
        uint256 oxygenRequired,
        uint256 shelterRequired,
        uint256 armyRequired,
        bool eliminated
    );

    modifier onlyController() {
        require(msg.sender == controller, "not controller");
        _;
    }

    function initialize(
        address _lord,
        address _controller,
        Resources calldata startingResources
    ) external initializer {
        require(_lord != address(0), "invalid lord");
        require(_controller != address(0), "invalid controller");

        lord = _lord;
        controller = _controller;
        resources = startingResources;

        emit Initialized(_lord, _controller);
    }

    function allocateResources(
        uint256 food,
        uint256 water,
        uint256 oxygen,
        uint256 shelter,
        uint256 army
    )
        external
        onlyController
    {
        uint256 totalGold = food + water + oxygen + shelter + army;
        if (totalGold == 0) return;

        _spendGold(totalGold);
        _addAllocatedResource(ResourceType.Food, food);
        _addAllocatedResource(ResourceType.Water, water);
        _addAllocatedResource(ResourceType.Oxygen, oxygen);
        _addAllocatedResource(ResourceType.Shelter, shelter);
        _addAllocatedResource(ResourceType.Army, army);
    }

    function applyRoundUpkeep(address player, uint256 roundId)
        external
        onlyController
        returns (bool eliminated)
    {
        require(player == lord, "wrong player");
        eliminated = _applyRoundUpkeep(roundId);
    }

    function applyBuildAction() external onlyController {
        supportCredits += 1;

        emit BuildSupportCreditStored(supportCredits);
    }

    function spendGold(uint256 amount) external onlyController {
        _spendGold(amount);
    }

    function awardGold(uint256 amount) external onlyController {
        resources.gold += amount;
        emit GoldAwarded(amount);
    }

    function applyResourcePenalty(
        uint256 roundId,
        uint256 colonyId,
        ResourceType resource,
        uint256 amount
    )
        external
        onlyController
        returns (uint256 applied)
    {
        applied = _applyResourcePenalty(resource, amount);
        if (applied > 0) {
            emit ResourcePenaltyApplied(
                roundId,
                lord,
                colonyId,
                resource,
                amount,
                applied
            );
        }
    }

    function _applyResourcePenalty(ResourceType resource, uint256 amount)
        internal
        returns (uint256 applied)
    {
        if (resource == ResourceType.Food) {
            applied = amount > resources.food ? resources.food : amount;
            resources.food -= applied;
        } else if (resource == ResourceType.Water) {
            applied = amount > resources.water ? resources.water : amount;
            resources.water -= applied;
        } else if (resource == ResourceType.Oxygen) {
            applied = amount > resources.oxygen ? resources.oxygen : amount;
            resources.oxygen -= applied;
        } else if (resource == ResourceType.Shelter) {
            applied = amount > resources.shelter ? resources.shelter : amount;
            resources.shelter -= applied;
        } else if (resource == ResourceType.Army) {
            applied = amount > resources.army ? resources.army : amount;
            resources.army -= applied;
        }
    }

    function transferGoldTo(address toLandLord, uint256 amount)
        external
        onlyController
        returns (uint256 transferred)
    {
        require(toLandLord != address(0), "invalid recipient");

        transferred = amount > resources.gold ? resources.gold : amount;
        resources.gold -= transferred;

        emit GoldTransferred(toLandLord, transferred);
    }

    function getGold() external view returns (uint256) {
        return resources.gold;
    }

    function getResources() external view returns (Resources memory) {
        return resources;
    }

    function getPopulationEstimate() external pure returns (uint256) {
        return populationForRound(0);
    }

    function getPopulationEstimate(uint256 roundId) public pure returns (uint256) {
        return populationForRound(roundId);
    }

    function populationForRound(uint256 roundId) public pure returns (uint256) {
        return POPULATION_BASE + (roundId * POPULATION_GROWTH_PER_ROUND);
    }

    function effectiveRoundForSupport(uint256 roundId) public view returns (uint256) {
        uint256 supportOffset = supportCredits;
        if (supportOffset >= roundId) return 0;
        return roundId - supportOffset;
    }

    function isEliminatedByResources() public view returns (bool) {
        return resources.gold == 0;
    }

    function canSupportRound(uint256 roundId) public view returns (bool) {
        (
            uint256 foodRequired,
            uint256 waterRequired,
            uint256 oxygenRequired,
            uint256 shelterRequired,
            uint256 armyRequired
        ) = supportRequirements(roundId);

        return (
            resources.gold > 0 &&
            resources.food >= foodRequired &&
            resources.water >= waterRequired &&
            resources.oxygen >= oxygenRequired &&
            resources.shelter >= shelterRequired &&
            resources.army >= armyRequired
        );
    }

    function isEliminatedByResourcesForRound(uint256 roundId)
        public
        view
        returns (bool)
    {
        return !canSupportRound(roundId);
    }

    function supportRequirements(uint256 roundId)
        public
        view
        returns (
            uint256 foodRequired,
            uint256 waterRequired,
            uint256 oxygenRequired,
            uint256 shelterRequired,
            uint256 armyRequired
        )
    {
        uint256 pressure = _supportPressure(roundId);
        foodRequired = RESOURCE_UPKEEP * pressure;
        waterRequired = RESOURCE_UPKEEP * pressure;
        oxygenRequired = RESOURCE_UPKEEP * pressure;
        shelterRequired = RESOURCE_UPKEEP * pressure;
        armyRequired = RESOURCE_UPKEEP * pressure;
    }

    function getResourceStats(uint256 roundId) public view returns (ResourceStats memory) {
        return ResourceStats({
            population: populationForRound(effectiveRoundForSupport(roundId)),
            attackPower: resources.army
        });
    }

    function getAttackPower() external view returns (uint256) {
        return resources.army;
    }

    function getArmyBonus() external view returns (uint256) {
        uint256 total = resources.gold +
            resources.food +
            resources.water +
            resources.oxygen +
            resources.shelter +
            resources.army;
        if (total == 0) return 0;

        uint256 armyShareBps = (resources.army * BASIS_POINTS) / total;
        uint256 armyBonus = armyShareBps / ARMY_BONUS_BPS_STEP;
        return armyBonus > MAX_ARMY_BONUS ? MAX_ARMY_BONUS : armyBonus;
    }

    function _spendGold(uint256 amount) internal {
        require(amount > 0, "invalid amount");
        require(resources.gold >= amount, "insufficient gold");
        resources.gold -= amount;
        emit GoldSpent(amount);
    }

    function _addAllocatedResource(ResourceType resource, uint256 goldAmount)
        internal
    {
        if (goldAmount == 0) return;
        uint256 allocated = goldAmount * GOLD_ALLOCATION_RATE;

        if (resource == ResourceType.Food) resources.food += allocated;
        else if (resource == ResourceType.Water) resources.water += allocated;
        else if (resource == ResourceType.Oxygen) resources.oxygen += allocated;
        else if (resource == ResourceType.Shelter) resources.shelter += allocated;
        else resources.army += allocated;

        emit ResourceAllocated(resource, goldAmount, allocated);
    }

    function _applyRoundUpkeep(uint256 roundId)
        internal
        returns (bool eliminated)
    {
        (
            uint256 foodRequired,
            uint256 waterRequired,
            uint256 oxygenRequired,
            uint256 shelterRequired,
            uint256 armyRequired
        ) = supportRequirements(roundId);

        eliminated = isEliminatedByResourcesForRound(roundId);
        emit SupportCheckApplied(
            roundId,
            populationForRound(effectiveRoundForSupport(roundId)),
            foodRequired,
            waterRequired,
            oxygenRequired,
            shelterRequired,
            armyRequired,
            eliminated
        );
    }

    function _supportPressure(uint256 roundId) internal view returns (uint256) {
        uint256 effectiveRound = effectiveRoundForSupport(roundId);
        return 3 + (effectiveRound / POPULATION_UPKEEP_INTERVAL);
    }

}

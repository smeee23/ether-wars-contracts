// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title LandLord
 * @notice Tournament resource state for one player.
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
        uint256 defensePower;
    }

    uint256 public constant STARTING_GOLD = 100;
    uint256 public constant STARTING_FOOD = 100;
    uint256 public constant STARTING_WATER = 100;
    uint256 public constant STARTING_OXYGEN = 100;
    uint256 public constant STARTING_SHELTER = 100;
    uint256 public constant STARTING_ARMY = 40;

    uint256 public constant FOOD_UPKEEP = 3;
    uint256 public constant WATER_UPKEEP = 3;
    uint256 public constant OXYGEN_UPKEEP = 3;
    uint256 public constant SHELTER_UPKEEP = 2;
    uint256 public constant ARMY_UPKEEP = 1;
    uint256 public constant POPULATION_BASE = 10;
    uint256 public constant POPULATION_GROWTH_PER_ROUND = 1;
    uint256 public constant POPULATION_UPKEEP_INTERVAL = 10;
    uint256 public constant GOLD_ALLOCATION_RATE = 1;

    address public lord;
    address public controller;
    uint256 public supportCredits;

    Resources private resources;

    event Initialized(address indexed lord, address indexed controller);
    event GoldSpent(uint256 amount);
    event GoldAwarded(uint256 amount);
    event GoldTransferred(address indexed winnerLandLord, uint256 amount);
    event ResourceAllocated(ResourceType indexed resource, uint256 goldSpent, uint256 amountAdded);
    event BuildSupportCreditStored(uint256 supportCredits);
    event RoundUpkeepApplied(
        uint256 indexed round,
        uint256 population,
        uint256 foodLost,
        uint256 waterLost,
        uint256 oxygenLost,
        uint256 shelterLost,
        uint256 armyLost,
        bool eliminated
    );
    event RoundDecayApplied(
        uint256 indexed round,
        uint256 foodLost,
        uint256 waterLost,
        uint256 oxygenLost,
        uint256 shelterLost,
        uint256 armyLost
    );
    event BattleLossApplied(uint256 armyLost);
    event AttackWagerSpent(uint256 amount);
    event DefenseWagerSpent(uint256 amount);

    modifier onlyLord() {
        require(msg.sender == lord, "not lord");
        _;
    }

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

    function allocateGold(ResourceType resource, uint256 goldAmount) public onlyLord {
        _allocateGold(resource, goldAmount);
    }

    function allocateGoldByController(ResourceType resource, uint256 goldAmount)
        external
        onlyController
    {
        _allocateGold(resource, goldAmount);
    }

    /// @dev Deprecated compatibility wrapper. Allocation is now 1:1 gold to resource.
    function spendGoldToReplenish(ResourceType resource, uint256 goldAmount)
        external
        onlyLord
    {
        _allocateGold(resource, goldAmount);
    }

    /// @dev Deprecated compatibility wrapper. Allocation is now 1:1 gold to resource.
    function replenishResource(ResourceType resource, uint256 goldAmount)
        external
        onlyLord
    {
        _allocateGold(resource, goldAmount);
    }

    function applyRoundUpkeep(address player, uint256 roundId)
        external
        onlyController
        returns (bool eliminated)
    {
        require(player == lord, "wrong player");
        eliminated = _applyRoundUpkeep(roundId);
    }

    function applyRoundUpkeepWithDecaySkip(
        address player,
        uint256 roundId,
        bool skipDecay
    )
        external
        onlyController
        returns (bool eliminated)
    {
        require(player == lord, "wrong player");
        // Deprecated compatibility parameter: BUILD now affects effective support round.
        skipDecay;
        eliminated = _applyRoundUpkeep(roundId);
    }

    function applyRoundDecay(uint256 roundNumber)
        external
        onlyController
        returns (bool eliminated)
    {
        eliminated = _applyRoundUpkeep(roundNumber);
    }

    function applyBuildAction() external onlyController {
        supportCredits += 1;

        emit BuildSupportCreditStored(supportCredits);
    }

    function applyBattleLoss(uint256 armyLoss, uint256 populationLoss)
        external
        onlyController
    {
        populationLoss;
        uint256 actualArmyLoss = _reduceArmy(armyLoss);
        emit BattleLossApplied(actualArmyLoss);
    }

    function spendAttackWager(uint256 amount) external onlyController {
        _spendGold(amount);
        emit AttackWagerSpent(amount);
    }

    function spendDefenseWager(uint256 amount) external onlyController {
        _spendGold(amount);
        emit DefenseWagerSpent(amount);
    }

    function spendGold(uint256 amount) external onlyController {
        _spendGold(amount);
    }

    function awardGold(uint256 amount) external onlyController {
        resources.gold += amount;
        emit GoldAwarded(amount);
    }

    function transferGoldToWinner(address winnerLandLord, uint256 amount)
        external
        onlyController
        returns (uint256 transferred)
    {
        require(winnerLandLord != address(0), "invalid winner");

        transferred = amount > resources.gold ? resources.gold : amount;
        resources.gold -= transferred;

        emit GoldTransferred(winnerLandLord, transferred);
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
        if (supportCredits >= roundId) return 0;
        return roundId - supportCredits;
    }

    function isEliminatedByResources() public view returns (bool) {
        return (
            resources.gold == 0 ||
            resources.food == 0 ||
            resources.water == 0 ||
            resources.oxygen == 0 ||
            resources.shelter == 0 ||
            resources.army == 0
        );
    }

    function canSurviveNextRound() external view returns (bool) {
        uint256 pressure = _supportPressure(1);
        return (
            resources.gold > 0 &&
            resources.food > FOOD_UPKEEP * pressure &&
            resources.water > WATER_UPKEEP * pressure &&
            resources.oxygen > OXYGEN_UPKEEP * pressure &&
            resources.shelter > SHELTER_UPKEEP * pressure &&
            resources.army > ARMY_UPKEEP * pressure
        );
    }

    function getResourceStats(uint256 roundId) public view returns (ResourceStats memory) {
        return ResourceStats({
            population: populationForRound(effectiveRoundForSupport(roundId)),
            attackPower: resources.army,
            defensePower: resources.army
        });
    }

    function getCityStats() public view returns (ResourceStats memory) {
        return getResourceStats(0);
    }

    function getAttackPower() external view returns (uint256) {
        return resources.army;
    }

    function getDefensePower() external view returns (uint256) {
        return resources.army;
    }

    function canAfford(uint256 goldAmount) external view returns (bool) {
        return resources.gold >= goldAmount;
    }

    function _spendGold(uint256 amount) internal {
        require(amount > 0, "invalid amount");
        require(resources.gold >= amount, "insufficient gold");
        resources.gold -= amount;
        emit GoldSpent(amount);
    }

    function _allocateGold(ResourceType resource, uint256 goldAmount) internal {
        _spendGold(goldAmount);
        uint256 allocated = goldAmount * GOLD_ALLOCATION_RATE;

        if (resource == ResourceType.Food) resources.food += allocated;
        else if (resource == ResourceType.Water) resources.water += allocated;
        else if (resource == ResourceType.Oxygen) resources.oxygen += allocated;
        else if (resource == ResourceType.Shelter) resources.shelter += allocated;
        else if (resource == ResourceType.Army) resources.army += allocated;

        emit ResourceAllocated(resource, goldAmount, allocated);
    }

    function _applyRoundUpkeep(uint256 roundId)
        internal
        returns (bool eliminated)
    {
        uint256 pressure = _supportPressure(roundId);

        uint256 foodLoss;
        uint256 waterLoss;
        uint256 oxygenLoss;
        uint256 shelterLoss;
        uint256 armyLoss;

        foodLoss = _reduceFood(FOOD_UPKEEP * pressure);
        waterLoss = _reduceWater(WATER_UPKEEP * pressure);
        oxygenLoss = _reduceOxygen(OXYGEN_UPKEEP * pressure);
        shelterLoss = _reduceShelter(SHELTER_UPKEEP * pressure);
        armyLoss = _reduceArmy(ARMY_UPKEEP * pressure);

        eliminated = isEliminatedByResources();
        emit RoundUpkeepApplied(
            roundId,
            populationForRound(effectiveRoundForSupport(roundId)),
            foodLoss,
            waterLoss,
            oxygenLoss,
            shelterLoss,
            armyLoss,
            eliminated
        );
        emit RoundDecayApplied(
            roundId,
            foodLoss,
            waterLoss,
            oxygenLoss,
            shelterLoss,
            armyLoss
        );
    }

    function _supportPressure(uint256 roundId) internal view returns (uint256) {
        uint256 population = populationForRound(effectiveRoundForSupport(roundId));
        return 1 + (population / POPULATION_UPKEEP_INTERVAL);
    }

    function _reduceFood(uint256 amount) internal returns (uint256) {
        uint256 loss = amount > resources.food ? resources.food : amount;
        resources.food -= loss;
        return loss;
    }

    function _reduceWater(uint256 amount) internal returns (uint256) {
        uint256 loss = amount > resources.water ? resources.water : amount;
        resources.water -= loss;
        return loss;
    }

    function _reduceOxygen(uint256 amount) internal returns (uint256) {
        uint256 loss = amount > resources.oxygen ? resources.oxygen : amount;
        resources.oxygen -= loss;
        return loss;
    }

    function _reduceArmy(uint256 amount) internal returns (uint256) {
        uint256 loss = amount > resources.army ? resources.army : amount;
        resources.army -= loss;
        return loss;
    }

    function _reduceShelter(uint256 amount) internal returns (uint256) {
        uint256 loss = amount > resources.shelter ? resources.shelter : amount;
        resources.shelter -= loss;
        return loss;
    }
}

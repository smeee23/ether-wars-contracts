// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title LandLord
 * @notice Tournament city/resource state for one player.
 * @dev This contract intentionally has no Aave, ETH, aToken, or vault logic.
 *      Gold and the other resources are virtual tournament accounting.
 */
contract LandLord is Initializable {
    enum ResourceType {
        Food,
        Water,
        Shelter,
        Army
    }

    enum BuildingType {
        Farm,
        Well,
        Housing,
        Wall,
        Tower,
        Barracks
    }

    struct Resources {
        uint256 gold;
        uint256 food;
        uint256 water;
        uint256 shelter;
        uint256 army;
    }

    struct Buildings {
        uint256 farms;
        uint256 wells;
        uint256 housing;
        uint256 walls;
        uint256 towers;
        uint256 barracks;
    }

    struct CityStats {
        uint256 population;
        uint256 populationCapacity;
        uint256 attackPower;
        uint256 defensePower;
        uint256 foodProduction;
        uint256 waterProduction;
    }

    uint256 public constant FARM_FOOD_PRODUCTION = 8;
    uint256 public constant WELL_WATER_PRODUCTION = 8;
    uint256 public constant HOUSING_CAPACITY = 5;
    uint256 public constant WALL_DEFENSE = 8;
    uint256 public constant TOWER_DEFENSE = 12;
    uint256 public constant BARRACK_ATTACK = 10;
    uint256 public constant ARMY_ATTACK = 2;

    uint256 public constant STARTING_GOLD = 100;
    uint256 public constant STARTING_FOOD = 100;
    uint256 public constant STARTING_WATER = 100;
    uint256 public constant STARTING_SHELTER = 100;
    uint256 public constant STARTING_ARMY = 40;

    uint256 public constant FOOD_UPKEEP = 3;
    uint256 public constant WATER_UPKEEP = 3;
    uint256 public constant SHELTER_UPKEEP = 2;
    uint256 public constant ARMY_UPKEEP = 1;
    uint256 public constant POPULATION_BASE = 10;
    uint256 public constant POPULATION_GROWTH_PER_ROUND = 1;
    uint256 public constant POPULATION_UPKEEP_INTERVAL = 10;
    uint256 public constant REPLENISH_PER_GOLD = 10;
    uint256 public constant BUILD_FOOD_GAIN = 12;
    uint256 public constant BUILD_WATER_GAIN = 12;
    uint256 public constant BUILD_SHELTER_GAIN = 6;
    uint256 public constant BUILD_ARMY_GAIN = 2;

    address public lord;
    address public controller;

    Resources private resources;
    Buildings private buildings;

    event Initialized(address indexed lord, address indexed controller);
    event BuildingBuilt(address indexed lord, BuildingType indexed building, uint256 amount);
    event GoldSpent(uint256 amount);
    event GoldAwarded(uint256 amount);
    event GoldTransferred(address indexed winnerLandLord, uint256 amount);
    event ResourceReplenished(ResourceType indexed resource, uint256 goldSpent, uint256 amountAdded);
    event BuildActionApplied(uint256 food, uint256 water, uint256 shelter, uint256 army);
    event RoundUpkeepApplied(
        uint256 indexed round,
        uint256 population,
        uint256 foodLost,
        uint256 waterLost,
        uint256 shelterLost,
        uint256 armyLost,
        bool eliminated
    );
    event RoundDecayApplied(
        uint256 indexed round,
        uint256 foodLost,
        uint256 waterLost,
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

    function build(BuildingType building, uint256 amount) public onlyLord {
        require(amount > 0, "invalid amount");

        uint256 cost = _buildingGoldCost(building, amount);
        _spendGold(cost);

        if (building == BuildingType.Farm) buildings.farms += amount;
        else if (building == BuildingType.Well) buildings.wells += amount;
        else if (building == BuildingType.Housing) buildings.housing += amount;
        else if (building == BuildingType.Wall) buildings.walls += amount;
        else if (building == BuildingType.Tower) buildings.towers += amount;
        else if (building == BuildingType.Barracks) buildings.barracks += amount;

        emit BuildingBuilt(msg.sender, building, amount);
    }

    function buildFarm(uint256 amount) external {
        build(BuildingType.Farm, amount);
    }

    function buildWell(uint256 amount) external {
        build(BuildingType.Well, amount);
    }

    function buildHousing(uint256 amount) external {
        build(BuildingType.Housing, amount);
    }

    function buildWall(uint256 amount) external {
        build(BuildingType.Wall, amount);
    }

    function buildTower(uint256 amount) external {
        build(BuildingType.Tower, amount);
    }

    function buildBarracks(uint256 amount) external {
        build(BuildingType.Barracks, amount);
    }

    function spendGoldToReplenish(ResourceType resource, uint256 goldAmount)
        external
        onlyLord
    {
        _replenish(resource, goldAmount);
    }

    function replenishResource(ResourceType resource, uint256 goldAmount)
        external
        onlyLord
    {
        _replenish(resource, goldAmount);
    }

    function applyRoundUpkeep(address player, uint256 roundId)
        external
        onlyController
        returns (bool eliminated)
    {
        require(player == lord, "wrong player");
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
        resources.food += BUILD_FOOD_GAIN;
        resources.water += BUILD_WATER_GAIN;
        resources.shelter += BUILD_SHELTER_GAIN;
        resources.army += BUILD_ARMY_GAIN;

        emit BuildActionApplied(
            BUILD_FOOD_GAIN,
            BUILD_WATER_GAIN,
            BUILD_SHELTER_GAIN,
            BUILD_ARMY_GAIN
        );
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
        return getPopulationEstimate(0);
    }

    function getPopulationEstimate(uint256 roundId) public pure returns (uint256) {
        return POPULATION_BASE + (roundId * POPULATION_GROWTH_PER_ROUND);
    }

    function isEliminatedByResources() public view returns (bool) {
        return (
            resources.gold == 0 ||
            resources.food == 0 ||
            resources.water == 0 ||
            resources.shelter == 0 ||
            resources.army == 0
        );
    }

    function canSurviveNextRound() external view returns (bool) {
        uint256 pressure = 1 + (getPopulationEstimate(1) / POPULATION_UPKEEP_INTERVAL);
        return (
            resources.gold > 0 &&
            resources.food > FOOD_UPKEEP * pressure &&
            resources.water > WATER_UPKEEP * pressure &&
            resources.shelter > SHELTER_UPKEEP * pressure &&
            resources.army > ARMY_UPKEEP * pressure
        );
    }

    function getBuildings() external view returns (Buildings memory) {
        return buildings;
    }

    function getCityStats() public view returns (CityStats memory) {
        uint256 capacity = buildings.housing * HOUSING_CAPACITY;
        uint256 foodProduction = buildings.farms * FARM_FOOD_PRODUCTION;
        uint256 waterProduction = buildings.wells * WELL_WATER_PRODUCTION;
        uint256 attackPower =
            (buildings.barracks * BARRACK_ATTACK) +
            (resources.army * ARMY_ATTACK);
        uint256 defensePower =
            (buildings.walls * WALL_DEFENSE) +
            (buildings.towers * TOWER_DEFENSE) +
            getPopulationEstimate(0);

        return CityStats({
            population: getPopulationEstimate(0),
            populationCapacity: capacity,
            attackPower: attackPower,
            defensePower: defensePower,
            foodProduction: foodProduction,
            waterProduction: waterProduction
        });
    }

    function getAttackPower() external view returns (uint256) {
        return getCityStats().attackPower;
    }

    function getDefensePower() external view returns (uint256) {
        return getCityStats().defensePower;
    }

    function canAfford(BuildingType building, uint256 amount)
        external
        view
        returns (bool)
    {
        return resources.gold >= _buildingGoldCost(building, amount);
    }

    function canAfford(uint256 goldAmount) external view returns (bool) {
        return resources.gold >= goldAmount;
    }

    function _buildingGoldCost(BuildingType building, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        if (building == BuildingType.Farm) return 5 * amount;
        if (building == BuildingType.Well) return 5 * amount;
        if (building == BuildingType.Housing) return 8 * amount;
        if (building == BuildingType.Wall) return 10 * amount;
        if (building == BuildingType.Tower) return 14 * amount;
        if (building == BuildingType.Barracks) return 12 * amount;
        return 0;
    }

    function _spendGold(uint256 amount) internal {
        require(amount > 0, "invalid amount");
        require(resources.gold >= amount, "insufficient gold");
        resources.gold -= amount;
        emit GoldSpent(amount);
    }

    function _replenish(ResourceType resource, uint256 goldAmount) internal {
        _spendGold(goldAmount);
        uint256 replenished = goldAmount * REPLENISH_PER_GOLD;

        if (resource == ResourceType.Food) resources.food += replenished;
        else if (resource == ResourceType.Water) resources.water += replenished;
        else if (resource == ResourceType.Shelter) resources.shelter += replenished;
        else if (resource == ResourceType.Army) resources.army += replenished;

        emit ResourceReplenished(resource, goldAmount, replenished);
    }

    function _applyRoundUpkeep(uint256 roundId)
        internal
        returns (bool eliminated)
    {
        uint256 population = getPopulationEstimate(roundId);
        uint256 pressure = 1 + (population / POPULATION_UPKEEP_INTERVAL);

        resources.food += buildings.farms * FARM_FOOD_PRODUCTION;
        resources.water += buildings.wells * WELL_WATER_PRODUCTION;

        uint256 foodLoss = _reduceFood(FOOD_UPKEEP * pressure);
        uint256 waterLoss = _reduceWater(WATER_UPKEEP * pressure);
        uint256 shelterLoss = _reduceShelter(SHELTER_UPKEEP * pressure);
        uint256 armyLoss = _reduceArmy(ARMY_UPKEEP * pressure);

        eliminated = isEliminatedByResources();
        emit RoundUpkeepApplied(
            roundId,
            population,
            foodLoss,
            waterLoss,
            shelterLoss,
            armyLoss,
            eliminated
        );
        emit RoundDecayApplied(
            roundId,
            foodLoss,
            waterLoss,
            shelterLoss,
            armyLoss
        );
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

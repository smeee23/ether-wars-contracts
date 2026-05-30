// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LandLord} from "./LandLord.sol";
import {IYieldAdapter} from "./interfaces/protocol/IYieldAdapter.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ITournamentBattleManager {
    function startNextRound() external returns (uint256);
    function setRoundRandomness(uint256 roundId, uint256 randomness) external;
    function resolveBattle(address attacker, address defender) external;
    function currentRound() external view returns (uint256);
    function canEndRound() external view returns (bool);
    function getRoundRandomness(uint256 roundId) external view returns (uint256);
}

interface ITournamentVRFProvider {
    function requestRandomness(uint256 roundId) external returns (uint256 requestId);
}

/**
 * @title TournamentManager
 * @notice Scaffold for the tournament game architecture.
 * @dev This replaces the previous duplicate LandLord contract that lived in
 *      LandLordFactory.sol. The manager is intentionally minimal: it defines
 *      tournament ownership, equal-entry registration, LandLord deployment, and
 *      trusted hooks for BattleManager/VRF wiring. Detailed settlement logic
 *      should be added here rather than to legacy Reserve contracts.
 */
contract TournamentManager is ReentrancyGuard {
    uint256 public constant MAX_TABLE_SIZE = 9;
    uint256 public constant STARTING_GOLD = 100;
    uint256 public constant STARTING_FOOD = 100;
    uint256 public constant STARTING_WATER = 100;
    uint256 public constant STARTING_ARMY = 40;
    uint256 public constant STARTING_POPULATION = 10;

    enum TournamentState {
        Registration,
        Active,
        Complete
    }

    struct PlayerInfo {
        bool registered;
        bool active;
        address landLord;
        uint256 deposited;
        uint256 adapterShares;
        bool principalClaimed;
        uint256 tableId;
    }

    address public immutable admin;
    address public immutable landLordImplementation;
    uint256 public immutable tournamentId;
    uint256 public immutable entryDeposit;
    uint256 public totalPrincipal;
    uint256 public totalAdapterShares;
    bool public tournamentSettled;
    bool public yieldClaimed;
    uint256 public settledTotalAssets;
    uint256 public settledProfit;
    address public yieldAdapter;

    address public battleManager;
    address public vrfProvider;
    address public rewardManager;
    address public mapRegistry;

    TournamentState public state;
    uint256 public tableCount;
    uint256 public activePlayers;
    uint256 public lastStartedRound;
    uint256 public lastEndedRound;
    address[] public players;
    mapping(address => PlayerInfo) public playerInfo;
    mapping(uint256 => address[]) private tablePlayers;
    mapping(uint256 => mapping(address => bool)) public roundPlayerActive;
    mapping(uint256 => mapping(address => uint256)) public roundTableOf;
    mapping(uint256 => uint256) public vrfRequestToRound;

    event PlayerRegistered(address indexed player, address indexed landLord);
    event TournamentStarted();
    event TournamentCompleted();
    event BattleManagerSet(address indexed battleManager);
    event VrfProviderSet(address indexed vrfProvider);
    event RewardManagerSet(address indexed rewardManager);
    event MapRegistrySet(address indexed mapRegistry);
    event YieldAdapterSet(address indexed adapter);
    event DepositedToYieldAdapter(address indexed player, uint256 amount, uint256 shares);
    event WithdrawnFromYieldAdapter(address indexed to, uint256 amount);
    event TournamentSettled(uint256 totalAssets, uint256 totalPrincipal, uint256 profit);
    event RoundStarted(uint256 indexed roundId, uint256 indexed requestId);
    event RoundEnded(uint256 indexed roundId);
    event RoundRandomnessApproved(uint256 indexed roundId, uint256 randomness);
    event PlayerEliminated(address indexed player);
    event BattleSettled(
        address indexed attacker,
        address indexed defender,
        bool attackerWon,
        uint256 wager,
        uint256 goldTransferred
    );
    event BuildActionApplied(address indexed player, address indexed landLord);
    event TableCreated(uint256 indexed tableId);
    event TableAssigned(address indexed player, uint256 indexed tableId);
    event PlayerMovedTable(
        address indexed player,
        uint256 indexed fromTableId,
        uint256 indexed toTableId
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyBattleManager() {
        require(msg.sender == battleManager, "not battle manager");
        _;
    }

    modifier onlyVrfProvider() {
        require(msg.sender == vrfProvider, "not vrf provider");
        _;
    }

    modifier inState(TournamentState expected) {
        require(state == expected, "wrong state");
        _;
    }

    constructor(
        address _yieldAdapter,
        address _landLordImplementation,
        uint256 _tournamentId,
        uint256 _entryDeposit
    ) {
        require(_yieldAdapter != address(0), "invalid yield adapter");
        require(_landLordImplementation != address(0), "invalid landlord");
        require(_entryDeposit > 0, "invalid entry deposit");

        admin = msg.sender;
        yieldAdapter = _yieldAdapter;
        landLordImplementation = _landLordImplementation;
        tournamentId = _tournamentId;
        entryDeposit = _entryDeposit;
        state = TournamentState.Registration;
        emit YieldAdapterSet(_yieldAdapter);
    }

    function setYieldAdapter(address _yieldAdapter)
        external
        onlyAdmin
        inState(TournamentState.Registration)
    {
        require(players.length == 0, "deposits started");
        require(_yieldAdapter != address(0), "invalid yield adapter");
        yieldAdapter = _yieldAdapter;
        emit YieldAdapterSet(_yieldAdapter);
    }

    function setBattleManager(address _battleManager) external onlyAdmin {
        require(_battleManager != address(0), "invalid battle manager");
        battleManager = _battleManager;
        emit BattleManagerSet(_battleManager);
    }

    function setVrfProvider(address _vrfProvider) external onlyAdmin {
        require(_vrfProvider != address(0), "invalid vrf provider");
        vrfProvider = _vrfProvider;
        emit VrfProviderSet(_vrfProvider);
    }

    function setRewardManager(address _rewardManager) external onlyAdmin {
        require(_rewardManager != address(0), "invalid reward manager");
        rewardManager = _rewardManager;
        emit RewardManagerSet(_rewardManager);
    }

    function setMapRegistry(address _mapRegistry) external onlyAdmin {
        require(_mapRegistry != address(0), "invalid map registry");
        mapRegistry = _mapRegistry;
        emit MapRegistrySet(_mapRegistry);
    }

    function register(uint256 splitArmy)
        external
        payable
        nonReentrant
        inState(TournamentState.Registration)
    {
        require(msg.value == entryDeposit, "entry deposit required");
        require(!playerInfo[msg.sender].registered, "already registered");

        splitArmy;
        uint256 shares = IYieldAdapter(yieldAdapter).depositETH{value: msg.value}();
        totalPrincipal += msg.value;
        totalAdapterShares += shares;

        address landLordAddress = Clones.clone(landLordImplementation);
        LandLord.Resources memory startingResources = LandLord.Resources({
            gold: STARTING_GOLD,
            food: STARTING_FOOD,
            water: STARTING_WATER,
            population: STARTING_POPULATION,
            army: STARTING_ARMY
        });
        LandLord(landLordAddress).initialize(
            msg.sender,
            address(this),
            startingResources
        );

        playerInfo[msg.sender] = PlayerInfo({
            registered: true,
            active: true,
            landLord: landLordAddress,
            deposited: msg.value,
            adapterShares: shares,
            principalClaimed: false,
            tableId: 0
        });
        players.push(msg.sender);
        activePlayers++;
        _assignToOpenTable(msg.sender);

        emit PlayerRegistered(msg.sender, landLordAddress);
        emit DepositedToYieldAdapter(msg.sender, msg.value, shares);
    }

    function startTournament()
        external
        onlyAdmin
        inState(TournamentState.Registration)
    {
        require(players.length > 1, "not enough players");
        state = TournamentState.Active;
        emit TournamentStarted();
    }

    function completeTournament()
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        _completeTournament();
    }

    function startBattleRound()
        external
        onlyAdmin
        inState(TournamentState.Active)
        returns (uint256 roundId, uint256 requestId)
    {
        require(battleManager != address(0), "battle manager not set");
        require(vrfProvider != address(0), "vrf provider not set");
        require(
            lastStartedRound == lastEndedRound,
            "previous round not ended"
        );

        roundId = ITournamentBattleManager(battleManager).startNextRound();
        lastStartedRound = roundId;
        _snapshotTables(roundId);

        requestId = ITournamentVRFProvider(vrfProvider).requestRandomness(roundId);
        vrfRequestToRound[requestId] = roundId;

        emit RoundStarted(roundId, requestId);
    }

    function endBattleRound()
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        uint256 roundId = ITournamentBattleManager(battleManager).currentRound();
        require(roundId != 0, "no round");
        require(roundId == lastStartedRound, "round mismatch");
        require(lastEndedRound < roundId, "round already ended");
        require(ITournamentBattleManager(battleManager).canEndRound(), "round not over");

        uint256 randomness = ITournamentBattleManager(battleManager)
            .getRoundRandomness(roundId);
        require(randomness != 0, "randomness not set");

        lastEndedRound = roundId;
        emit RoundEnded(roundId);

        _applyRoundDecay(roundId);

        if (activePlayers <= 1) {
            _completeTournament();
            return;
        }

        _rebalanceTables(randomness);
    }

    function receiveRandomness(uint256 requestId, uint256 randomness)
        external
        onlyVrfProvider
    {
        uint256 roundId = vrfRequestToRound[requestId];
        require(roundId != 0, "unknown request");
        require(randomness != 0, "empty randomness");

        ITournamentBattleManager(battleManager).setRoundRandomness(
            roundId,
            randomness
        );

        emit RoundRandomnessApproved(roundId, randomness);
    }

    function eliminatePlayer(address player) external onlyBattleManager {
        _eliminatePlayer(player);
    }

    function settleBattle(
        address attacker,
        address defender,
        uint256 wager,
        bool attackerWon
    ) external onlyBattleManager returns (uint256 transferred) {
        require(wager > 0, "invalid wager");
        require(playerInfo[attacker].active, "attacker inactive");
        require(playerInfo[defender].active, "defender inactive");

        address attackerLandLord = playerInfo[attacker].landLord;
        address defenderLandLord = playerInfo[defender].landLord;
        require(attackerLandLord != address(0), "missing attacker city");
        require(defenderLandLord != address(0), "missing defender city");

        if (attackerWon) {
            uint256 defenderGold = LandLord(defenderLandLord).getGold();
            transferred = LandLord(defenderLandLord).transferGoldToWinner(
                attackerLandLord,
                wager
            );
            LandLord(attackerLandLord).awardGold(transferred);

            if (defenderGold < wager || LandLord(defenderLandLord).getGold() == 0) {
                _eliminatePlayer(defender);
            }
        } else {
            transferred = LandLord(attackerLandLord).transferGoldToWinner(
                defenderLandLord,
                wager
            );
            LandLord(defenderLandLord).awardGold(transferred);

            if (LandLord(attackerLandLord).getGold() == 0) {
                _eliminatePlayer(attacker);
            }
        }

        emit BattleSettled(attacker, defender, attackerWon, wager, transferred);
    }

    function applyBuildAction(address player) external onlyBattleManager {
        PlayerInfo memory info = playerInfo[player];
        require(info.active, "player inactive");
        require(info.landLord != address(0), "missing city");

        LandLord(info.landLord).applyBuildAction();
        emit BuildActionApplied(player, info.landLord);
    }

    function resolveBattle(address attacker, address defender)
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        ITournamentBattleManager(battleManager).resolveBattle(attacker, defender);
    }

    function settleTournament() external onlyAdmin inState(TournamentState.Complete) {
        require(!tournamentSettled, "already settled");
        uint256 assets = IYieldAdapter(yieldAdapter).totalAssets();
        uint256 profit = assets > totalPrincipal ? assets - totalPrincipal : 0;
        settledTotalAssets = assets;
        settledProfit = profit;
        tournamentSettled = true;
        emit TournamentSettled(assets, totalPrincipal, profit);
    }

    function claimPrincipal() external nonReentrant inState(TournamentState.Complete) {
        require(tournamentSettled, "not settled");
        PlayerInfo storage info = playerInfo[msg.sender];
        require(info.registered, "not registered");
        require(!info.principalClaimed, "principal claimed");

        uint256 amount = info.deposited;

        if (settledTotalAssets < totalPrincipal) {
            amount = (info.deposited * settledTotalAssets) / totalPrincipal;
        }

        info.principalClaimed = true;
        uint256 withdrawn = IYieldAdapter(yieldAdapter).withdrawETH(msg.sender, amount);
        emit WithdrawnFromYieldAdapter(msg.sender, withdrawn);
    }

    function claimYield(address winner) external onlyAdmin nonReentrant inState(TournamentState.Complete) {
        require(tournamentSettled, "not settled");
        require(!yieldClaimed, "yield claimed");
        require(playerInfo[winner].registered, "winner not registered");
        require(settledProfit > 0, "no profit");

        yieldClaimed = true;
        uint256 withdrawn = IYieldAdapter(yieldAdapter).withdrawETH(winner, settledProfit);
        emit WithdrawnFromYieldAdapter(winner, withdrawn);
    }

    function getYieldProfit() external view returns (uint256) {
        if (tournamentSettled) return settledProfit;
        uint256 assets = IYieldAdapter(yieldAdapter).totalAssets();
        if (assets <= totalPrincipal) return 0;
        return assets - totalPrincipal;
    }

    function _eliminatePlayer(address player) internal {
        PlayerInfo storage info = playerInfo[player];
        require(info.active, "not active");
        info.active = false;
        activePlayers--;
        emit PlayerEliminated(player);
    }

    function _completeTournament() internal {
        state = TournamentState.Complete;
        emit TournamentCompleted();
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }

    function activePlayerCount() external view returns (uint256) {
        return activePlayers;
    }

    function getPlayerTable(address player) external view returns (uint256) {
        return playerInfo[player].tableId;
    }

    function getTablePlayers(uint256 tableId)
        external
        view
        returns (address[] memory)
    {
        return tablePlayers[tableId];
    }

    function getActiveTablePlayers(uint256 tableId)
        public
        view
        returns (address[] memory)
    {
        address[] memory raw = tablePlayers[tableId];
        uint256 count;

        for (uint256 i = 0; i < raw.length; i++) {
            if (playerInfo[raw[i]].active) count++;
        }

        address[] memory active = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < raw.length; i++) {
            if (playerInfo[raw[i]].active) {
                active[cursor++] = raw[i];
            }
        }

        return active;
    }

    function getNeighbors(address player)
        external
        view
        returns (address[] memory)
    {
        PlayerInfo memory info = playerInfo[player];
        require(info.registered, "not registered");

        address[] memory active = getActiveTablePlayers(info.tableId);
        uint256 count;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] != player) count++;
        }

        address[] memory neighbors = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] != player) {
                neighbors[cursor++] = active[i];
            }
        }

        return neighbors;
    }

    function isSameTable(address a, address b) external view returns (bool) {
        return _isSameTable(a, b);
    }

    function isValidAttackForRound(
        uint256 _tournamentId,
        uint256 roundId,
        address attacker,
        address target,
        uint256 wager
    ) external view returns (bool) {
        if (_tournamentId != tournamentId) return false;
        if (attacker == target) return false;
        if (wager == 0) return false;
        if (!roundPlayerActive[roundId][attacker]) return false;
        if (!roundPlayerActive[roundId][target]) return false;
        if (roundTableOf[roundId][attacker] == 0) return false;
        if (roundTableOf[roundId][attacker] != roundTableOf[roundId][target]) {
            return false;
        }
        if (wager > getGold(attacker)) return false;

        return true;
    }

    function getAvailableResources(address player) public view returns (uint256) {
        return getGold(player);
    }

    function getGold(address player) public view returns (uint256) {
        PlayerInfo memory info = playerInfo[player];
        if (!info.active || info.landLord == address(0)) return 0;
        return LandLord(info.landLord).getGold();
    }

    function _isSameTable(address a, address b) internal view returns (bool) {
        PlayerInfo memory aInfo = playerInfo[a];
        PlayerInfo memory bInfo = playerInfo[b];

        return (
            aInfo.active &&
            bInfo.active &&
            aInfo.tableId != 0 &&
            aInfo.tableId == bInfo.tableId
        );
    }

    function _assignToOpenTable(address player) internal {
        if (
            tableCount == 0 ||
            tablePlayers[tableCount].length >= MAX_TABLE_SIZE
        ) {
            tableCount++;
            emit TableCreated(tableCount);
        }

        tablePlayers[tableCount].push(player);
        playerInfo[player].tableId = tableCount;
        emit TableAssigned(player, tableCount);
    }

    function _snapshotTables(uint256 roundId) internal {
        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            PlayerInfo memory info = playerInfo[player];
            if (!info.active) continue;

            roundPlayerActive[roundId][player] = true;
            roundTableOf[roundId][player] = info.tableId;
        }
    }

    function _applyRoundDecay(uint256 roundId) internal {
        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            PlayerInfo memory info = playerInfo[player];
            if (!info.active || info.landLord == address(0)) continue;

            LandLord(info.landLord).applyRoundDecay(roundId);
        }
    }

    /**
     * @dev Rebuilds tables between rounds. This is intentionally simple and
     *      bounded by total registered players. For very large tournaments this
     *      should become a batched rebalance using the same assignment rules.
     */
    function _rebalanceTables(uint256 seed) internal {
        address[] memory activeList = new address[](activePlayers);
        uint256 cursor;

        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            if (playerInfo[player].active) {
                activeList[cursor++] = player;
            }
        }

        for (uint256 i = activeList.length; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            address tmp = activeList[i - 1];
            activeList[i - 1] = activeList[j];
            activeList[j] = tmp;
        }

        uint256 oldTableCount = tableCount;
        for (uint256 i = 1; i <= oldTableCount; i++) {
            delete tablePlayers[i];
        }

        tableCount = (activeList.length + MAX_TABLE_SIZE - 1) / MAX_TABLE_SIZE;
        if (activeList.length <= MAX_TABLE_SIZE) {
            tableCount = 1;
        }

        for (uint256 tableId = 1; tableId <= tableCount; tableId++) {
            emit TableCreated(tableId);
        }

        for (uint256 i = 0; i < activeList.length; i++) {
            address player = activeList[i];
            uint256 previousTable = playerInfo[player].tableId;
            uint256 newTable = (i / MAX_TABLE_SIZE) + 1;

            tablePlayers[newTable].push(player);
            playerInfo[player].tableId = newTable;

            if (previousTable != newTable) {
                emit PlayerMovedTable(player, previousTable, newTable);
            } else {
                emit TableAssigned(player, newTable);
            }
        }
    }
}

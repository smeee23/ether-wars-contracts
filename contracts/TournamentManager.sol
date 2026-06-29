// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LandLord} from "./LandLord.sol";
import {IYieldAdapter} from "./interfaces/protocol/IYieldAdapter.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ITournamentBattleManager {
    enum Phase {
        Commit,
        Reveal,
        Resolve
    }

    function startNextRound() external returns (uint256);
    function setRoundRandomness(uint256 roundId, uint256 randomness) external;
    function resolveTableConflicts(uint256 tableId, uint256 roundId) external;
    function currentRound() external view returns (uint256);
    function getPhase() external view returns (Phase);
    function canEndRound() external view returns (bool);
    function getRoundRandomness(uint256 roundId) external view returns (uint256);
    function commits(uint256 roundId, address player) external view returns (bytes32);
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
    uint256 public constant STARTING_GOLD = 1000;
    uint256 public constant STARTING_FOOD = 0;
    uint256 public constant STARTING_WATER = 0;
    uint256 public constant STARTING_OXYGEN = 0;
    uint256 public constant STARTING_SHELTER = 0;
    uint256 public constant STARTING_ARMY = 0;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant ARMY_BONUS_BPS_STEP = 500;
    uint256 public constant MAX_ARMY_BONUS = 20;
    uint256 private constant INITIAL_COLONIES = 1;
    uint256 private constant MAX_COLONIES = 3;
    uint256 private constant EXPANSION_CLAIM_WINDOW_ROUNDS = 3;

    enum TournamentState {
        Registration,
        Active,
        Complete
    }

    struct PlayerInfo {
        bool registered;
        bool active;
        uint256 deposited;
        uint256 adapterShares;
        bool principalClaimed;
        uint256 tableId;
    }

    struct ColonyInfo {
        address owner;
        address landLord;
        bool active;
        uint256 createdRound;
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
    uint256 public initialPlayerCount;
    uint256 public nextColonyId;
    uint256 public lastStartedRound;
    uint256 public lastEndedRound;
    uint256 public expansionUnlockRound;
    address[] public players;
    mapping(address => PlayerInfo) public playerInfo;
    mapping(uint256 => ColonyInfo) public colonyInfo;
    mapping(address => uint256[]) private playerColonies;
    mapping(address => uint256) public activeColonyCount;
    mapping(address => uint256) public expansionsUsed;
    mapping(address => uint256) private expansionClaims;
    mapping(uint256 => address[]) private tablePlayers;
    mapping(uint256 => mapping(address => bool)) public roundPlayerActive;
    mapping(uint256 => mapping(address => uint256)) public roundTableOf;
    mapping(uint256 => mapping(uint256 => address[])) private roundTablePlayers;
    mapping(uint256 => uint256) public vrfRequestToRound;
    mapping(uint256 => uint256) private roundRandomnessRequestId;

    event PlayerRegistered(address indexed player);
    event ColonyCreated(
        uint256 indexed colonyId,
        address indexed owner,
        address indexed landLord,
        uint256 createdRound
    );
    event ColonyEliminated(uint256 indexed colonyId, address indexed owner);
    event ColonyGoldTransferred(
        address indexed owner,
        uint256 indexed fromColonyId,
        uint256 indexed toColonyId,
        uint256 amount
    );
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
    event RoundRandomnessRequested(uint256 indexed roundId, uint256 indexed requestId);
    event RoundEnded(uint256 indexed roundId);
    event RoundRandomnessApproved(uint256 indexed roundId, uint256 randomness);
    event PlayerEliminated(address indexed player);
    event ConflictGoldSettled(
        uint256 indexed roundId,
        address indexed winner,
        address indexed loser,
        uint256 groupStake,
        uint256 goldTransferred,
        bool loserEliminated
    );
    event BuildActionApplied(
        address indexed player,
        uint256 indexed colonyId,
        address indexed landLord
    );
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

    function register()
        external
        payable
        nonReentrant
        inState(TournamentState.Registration)
    {
        require(msg.value == entryDeposit, "deposit");
        require(!playerInfo[msg.sender].registered, "registered");

        uint256 shares = IYieldAdapter(yieldAdapter).depositETH{value: msg.value}();
        totalPrincipal += msg.value;
        totalAdapterShares += shares;

        for (uint256 i = 0; i < INITIAL_COLONIES; i++) {
            _createColony(msg.sender);
        }

        playerInfo[msg.sender] = PlayerInfo({
            registered: true,
            active: true,
            deposited: msg.value,
            adapterShares: shares,
            principalClaimed: false,
            tableId: 0
        });
        players.push(msg.sender);
        activePlayers++;
        _assignToOpenTable(msg.sender);

        emit PlayerRegistered(msg.sender);
        emit DepositedToYieldAdapter(msg.sender, msg.value, shares);
    }

    function startTournament()
        external
        onlyAdmin
        inState(TournamentState.Registration)
    {
        require(players.length > 1, "players");
        initialPlayerCount = players.length;
        state = TournamentState.Active;
        emit TournamentStarted();
    }

    function expand()
        external
        inState(TournamentState.Active)
        returns (uint256 colonyId)
    {
        require(playerInfo[msg.sender].active, "inactive");
        require(battleManager != address(0), "battle manager");
        require(
            ITournamentBattleManager(battleManager).getPhase() ==
                ITournamentBattleManager.Phase.Commit,
            "not commit phase"
        );
        require(
            ITournamentBattleManager(battleManager).commits(
                ITournamentBattleManager(battleManager).currentRound(),
                msg.sender
            ) == bytes32(0),
            "already committed"
        );
        uint256 expansionSlot = _claimableExpansionSlot(msg.sender);
        require(expansionSlot != 0, "expansion locked");
        require(activeColonyCount[msg.sender] < MAX_COLONIES, "max");

        expansionClaims[msg.sender] |= expansionSlot;
        expansionsUsed[msg.sender]++;
        colonyId = _createColony(msg.sender);
    }

    function maxUnlockedExpansions() public view returns (uint256) {
        if (state != TournamentState.Active || initialPlayerCount == 0) return 0;
        uint256 roundId = lastStartedRound;
        uint256 unlocked;

        if (roundId > 0 && roundId <= EXPANSION_CLAIM_WINDOW_ROUNDS) {
            unlocked++;
        }

        if (
            expansionUnlockRound != 0 &&
            roundId > expansionUnlockRound &&
            roundId <= expansionUnlockRound + EXPANSION_CLAIM_WINDOW_ROUNDS
        ) {
            unlocked++;
        }

        return unlocked;
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
        require(battleManager != address(0), "battle manager");
        require(vrfProvider != address(0), "vrf provider");
        require(
            lastStartedRound == lastEndedRound,
            "round active"
        );

        roundId = ITournamentBattleManager(battleManager).startNextRound();
        lastStartedRound = roundId;
        _snapshotTables(roundId);

        emit RoundStarted(roundId, requestId);
    }

    function requestRoundRandomness(uint256 roundId)
        external
        onlyAdmin
        inState(TournamentState.Active)
        returns (uint256 requestId)
    {
        require(vrfProvider != address(0), "vrf provider");
        require(roundId != 0, "round");
        require(roundId == lastStartedRound, "round mismatch");
        require(lastEndedRound < roundId, "round already ended");
        require(ITournamentBattleManager(battleManager).canEndRound(), "reveal still open");
        require(
            ITournamentBattleManager(battleManager).getRoundRandomness(roundId) == 0,
            "randomness set"
        );
        require(roundRandomnessRequestId[roundId] == 0, "randomness requested");

        requestId = ITournamentVRFProvider(vrfProvider).requestRandomness(roundId);
        vrfRequestToRound[requestId] = roundId;
        roundRandomnessRequestId[roundId] = requestId;

        emit RoundRandomnessRequested(roundId, requestId);
    }

    function endBattleRound()
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        uint256 roundId = ITournamentBattleManager(battleManager).currentRound();
        require(roundId != 0, "round");
        require(roundId == lastStartedRound, "round mismatch");
        require(lastEndedRound < roundId, "round ended");
        require(ITournamentBattleManager(battleManager).canEndRound(), "round not over");

        uint256 randomness = ITournamentBattleManager(battleManager)
            .getRoundRandomness(roundId);
        require(randomness != 0, "randomness");

        lastEndedRound = roundId;
        emit RoundEnded(roundId);

        _applyRoundSupportChecks(roundId);

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
        require(roundId != 0, "request");
        require(roundId == lastStartedRound, "round mismatch");
        require(lastEndedRound < roundId, "round ended");
        require(randomness != 0, "randomness");

        ITournamentBattleManager(battleManager).setRoundRandomness(
            roundId,
            randomness
        );

        emit RoundRandomnessApproved(roundId, randomness);
    }

    function eliminatePlayer(address player) external onlyBattleManager {
        _eliminatePlayer(player);
    }

    function settleConflictGroup(
        uint256 roundId,
        address winner,
        address[] calldata participants,
        uint256[] calldata paymentColonyIds,
        uint256 winnerColonyId,
        uint256 groupStake
    ) external onlyBattleManager returns (uint256 totalTransferred) {
        require(participants.length > 1, "invalid group");
        require(participants.length == paymentColonyIds.length, "colony length");
        require(groupStake > 0, "invalid stake");
        require(roundPlayerActive[roundId][winner], "winner not in round");
        require(playerInfo[winner].active, "winner inactive");

        uint256 resolvedWinnerColony = _resolveActionColony(winner, winnerColonyId);
        require(resolvedWinnerColony != 0, "missing winner colony");
        require(_isColonyAvailableForRound(resolvedWinnerColony, roundId), "pending");
        address winnerLandLord = colonyInfo[resolvedWinnerColony].landLord;

        for (uint256 i = 0; i < participants.length; i++) {
            address loser = participants[i];
            require(roundPlayerActive[roundId][loser], "participant not in round");

            if (loser == winner) continue;

            totalTransferred += _settleConflictLoser(
                roundId,
                winner,
                loser,
                winnerLandLord,
                paymentColonyIds[i],
                groupStake
            );
        }

    }

    function applyBuildAction(address player, uint256 roundId) external onlyBattleManager {
        require(playerInfo[player].active, "player inactive");
        require(activeColonyCount[player] > 0, "no active colony");

        uint256[] memory colonies = playerColonies[player];
        for (uint256 i = 0; i < colonies.length; i++) {
            uint256 activeColonyId = colonies[i];
            ColonyInfo memory colony = colonyInfo[activeColonyId];
            if (!colony.active) continue;
            if (!_isColonyAvailableForRound(activeColonyId, roundId)) continue;

            LandLord(colony.landLord).applyBuildAction();
            emit BuildActionApplied(player, activeColonyId, colony.landLord);
        }
    }

    function _settleConflictLoser(
        uint256 roundId,
        address winner,
        address loser,
        address winnerLandLord,
        uint256 paymentColonyId,
        uint256 groupStake
    ) internal returns (uint256 transferred) {
        uint256 loserColonyId = _resolveActionColony(loser, paymentColonyId);
        require(loserColonyId != 0, "missing loser colony");
        require(_isColonyAvailableForRound(loserColonyId, roundId), "pending");

        transferred = LandLord(colonyInfo[loserColonyId].landLord)
            .transferGoldTo(winnerLandLord, groupStake);
        if (transferred > 0) {
            LandLord(winnerLandLord).awardGold(transferred);
        }

        bool loserEliminated = false;
        if (
            colonyInfo[loserColonyId].active &&
            LandLord(colonyInfo[loserColonyId].landLord).isEliminatedByResources()
        ) {
            _eliminateColony(loserColonyId);
            loserEliminated = true;
        }

        emit ConflictGoldSettled(
            roundId,
            winner,
            loser,
            groupStake,
            transferred,
            loserEliminated
        );
    }

    function resolveTableConflicts(uint256 tableId, uint256 roundId)
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        require(
            ITournamentBattleManager(battleManager).getRoundRandomness(roundId) != 0,
            "randomness not ready"
        );
        ITournamentBattleManager(battleManager).resolveTableConflicts(
            tableId,
            roundId
        );
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

    function getPlayerColonies(address player)
        external
        view
        returns (uint256[] memory)
    {
        return playerColonies[player];
    }

    function getColonyGold(uint256 colonyId) public view returns (uint256) {
        ColonyInfo memory colony = colonyInfo[colonyId];
        if (!colony.active || colony.landLord == address(0)) return 0;
        return LandLord(colony.landLord).getGold();
    }

    function getActionArmy(address player, uint256 colonyId)
        external
        view
        returns (uint256)
    {
        uint256 resolvedColonyId = _resolveActionColony(player, colonyId);
        if (resolvedColonyId == 0) return 0;
        return LandLord(colonyInfo[resolvedColonyId].landLord).getResources().army;
    }

    function getActionArmyBonus(address player, uint256 colonyId)
        external
        view
        returns (uint256)
    {
        uint256 resolvedColonyId = _resolveActionColony(player, colonyId);
        if (resolvedColonyId == 0) return 0;

        LandLord.Resources memory resources = LandLord(
            colonyInfo[resolvedColonyId].landLord
        ).getResources();
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

    function allocateColonyGold(
        uint256 colonyId,
        LandLord.ResourceType resource,
        uint256 goldAmount
    ) external {
        require(_ownsActiveColony(msg.sender, colonyId), "invalid colony");
        require(_isColonyAvailableNow(colonyId), "pending");
        LandLord(colonyInfo[colonyId].landLord).allocateGoldByController(
            resource,
            goldAmount
        );
    }

    function transferGoldBetweenColonies(
        uint256 fromColonyId,
        uint256 toColonyId,
        uint256 amount
    ) external {
        require(amount > 0, "invalid amount");
        require(_ownsActiveColony(msg.sender, fromColonyId), "invalid source colony");
        require(_ownsActiveColony(msg.sender, toColonyId), "invalid target colony");
        require(_isColonyAvailableNow(fromColonyId), "pending");
        require(_isColonyAvailableNow(toColonyId), "pending");
        require(battleManager != address(0), "battle manager not set");
        require(
            ITournamentBattleManager(battleManager).getPhase() ==
                ITournamentBattleManager.Phase.Commit,
            "not commit phase"
        );

        uint256 transferred = LandLord(colonyInfo[fromColonyId].landLord)
            .transferGoldTo(colonyInfo[toColonyId].landLord, amount);
        LandLord(colonyInfo[toColonyId].landLord).awardGold(transferred);

        emit ColonyGoldTransferred(
            msg.sender,
            fromColonyId,
            toColonyId,
            transferred
        );
    }

    function _createColony(address owner) internal returns (uint256 colonyId) {
        require(owner != address(0), "invalid owner");

        colonyId = ++nextColonyId;
        address landLordAddress = Clones.clone(landLordImplementation);
        LandLord.Resources memory startingResources = LandLord.Resources({
            gold: STARTING_GOLD,
            food: STARTING_FOOD,
            water: STARTING_WATER,
            oxygen: STARTING_OXYGEN,
            shelter: STARTING_SHELTER,
            army: STARTING_ARMY
        });
        LandLord(landLordAddress).initialize(
            owner,
            address(this),
            startingResources
        );

        colonyInfo[colonyId] = ColonyInfo({
            owner: owner,
            landLord: landLordAddress,
            active: true,
            createdRound: lastStartedRound
        });
        playerColonies[owner].push(colonyId);
        activeColonyCount[owner]++;

        emit ColonyCreated(colonyId, owner, landLordAddress, lastStartedRound);
    }

    function _ownsActiveColony(address owner, uint256 colonyId)
        internal
        view
        returns (bool)
    {
        ColonyInfo memory colony = colonyInfo[colonyId];
        return colony.owner == owner && colony.active && colony.landLord != address(0);
    }

    function _firstActiveColony(address owner) internal view returns (uint256) {
        uint256[] memory colonies = playerColonies[owner];
        for (uint256 i = 0; i < colonies.length; i++) {
            if (colonyInfo[colonies[i]].active) return colonies[i];
        }
        return 0;
    }

    function _resolveActionColony(address owner, uint256 colonyId)
        internal
        view
        returns (uint256)
    {
        if (colonyId == 0) return _firstActiveColony(owner);
        if (!_ownsActiveColony(owner, colonyId)) return 0;
        return colonyId;
    }

    function _claimableExpansionSlot(address player) internal view returns (uint256) {
        uint256 roundId = lastStartedRound;
        uint256 claims = expansionClaims[player];

        if (
            roundId > 0 &&
            roundId <= EXPANSION_CLAIM_WINDOW_ROUNDS &&
            (claims & 1) == 0
        ) {
            return 1;
        }

        if (
            expansionUnlockRound != 0 &&
            roundId > expansionUnlockRound &&
            roundId <= expansionUnlockRound + EXPANSION_CLAIM_WINDOW_ROUNDS &&
            (claims & 2) == 0
        ) {
            return 2;
        }

        return 0;
    }

    function _isColonyAvailableNow(uint256 colonyId) internal view returns (bool) {
        return lastStartedRound == 0 ||
            _isColonyAvailableForRound(colonyId, lastStartedRound);
    }

    function _isColonyAvailableForRound(uint256 colonyId, uint256 roundId)
        internal
        view
        returns (bool)
    {
        return colonyInfo[colonyId].createdRound < roundId;
    }

    function _eliminateColony(uint256 colonyId) internal {
        ColonyInfo storage colony = colonyInfo[colonyId];
        require(colony.active, "colony inactive");

        colony.active = false;
        activeColonyCount[colony.owner]--;
        emit ColonyEliminated(colonyId, colony.owner);

        if (activeColonyCount[colony.owner] == 0 && playerInfo[colony.owner].active) {
            _eliminatePlayer(colony.owner);
        }
    }

    function _eliminatePlayer(address player) internal {
        PlayerInfo storage info = playerInfo[player];
        require(info.active, "not active");
        info.active = false;
        activePlayers--;
        emit PlayerEliminated(player);
        _unlockExpansionIfMilestoneReached();
    }

    function _unlockExpansionIfMilestoneReached() internal {
        if (expansionUnlockRound != 0) return;
        if (initialPlayerCount == 0) return;
        if (activePlayers * 2 > initialPlayerCount) return;

        uint256 roundId = ITournamentBattleManager(battleManager).currentRound();
        expansionUnlockRound = roundId;
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

    function getRoundTablePlayers(uint256 roundId, uint256 tableId)
        external
        view
        returns (address[] memory)
    {
        return roundTablePlayers[roundId][tableId];
    }

    function getRoundTableOf(uint256 roundId, address player)
        external
        view
        returns (uint256)
    {
        return roundTableOf[roundId][player];
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
        uint256 wager,
        uint256 sourceColonyId,
        uint256 targetColonyId
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
        if (!_ownsActiveColony(attacker, sourceColonyId)) return false;
        if (!_ownsActiveColony(target, targetColonyId)) return false;
        if (!_isColonyAvailableForRound(sourceColonyId, roundId)) return false;
        if (!_isColonyAvailableForRound(targetColonyId, roundId)) return false;
        if (wager > getColonyGold(sourceColonyId)) return false;

        return true;
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
            roundTablePlayers[roundId][info.tableId].push(player);
        }
    }

    function _applyRoundSupportChecks(uint256 roundId) internal {
        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            if (!playerInfo[player].active) continue;

            uint256[] memory colonies = playerColonies[player];
            for (uint256 j = 0; j < colonies.length; j++) {
                uint256 colonyId = colonies[j];
                ColonyInfo memory colony = colonyInfo[colonyId];
                if (!colony.active) continue;
                if (!_isColonyAvailableForRound(colonyId, roundId)) continue;

                bool eliminated = LandLord(colony.landLord).applyRoundUpkeep(
                    player,
                    roundId
                );
                if (eliminated && colonyInfo[colonyId].active) {
                    _eliminateColony(colonyId);
                }
            }
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

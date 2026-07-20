// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LandLord} from "./LandLord.sol";
import {IResourceLottery} from "./interfaces/protocol/IResourceLottery.sol";
import {IYieldAdapter} from "./interfaces/protocol/IYieldAdapter.sol";
import {GameTypes} from "./libraries/GameTypes.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ITournamentBattleManager {
    enum Phase {
        Commit,
        Reveal,
        Resolve
    }

    function startNextRound(uint256 requiredTableCount)
        external
        returns (uint256);
    function setRoundRandomness(uint256 roundId, uint256 randomness) external;
    function resolveTableConflicts(uint256 tableId, uint256 roundId) external;
    function currentRound() external view returns (uint256);
    function getPhase() external view returns (Phase);
    function canEndRound() external view returns (bool);
    function getRoundRandomness(uint256 roundId) external view returns (uint256);
    function tableConflictsResolved(uint256 roundId, uint256 tableId) external view returns (bool);
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
    uint256 public constant DEFAULT_VRF_REQUEST_TIMEOUT = 1 hours;
    uint256 public constant MAX_TABLE_SIZE = 9;
    uint256 public constant STARTING_GOLD = 1000;
    uint256 public constant STARTING_FOOD = 0;
    uint256 public constant STARTING_WATER = 0;
    uint256 public constant STARTING_OXYGEN = 0;
    uint256 public constant STARTING_SHELTER = 0;
    uint256 public constant STARTING_ARMY = 0;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_SUPPORT_BATCH_PLAYERS = 25;
    uint256 private constant MAX_PENALTY_BATCH_TABLES = 10;
    uint256 private constant MAX_COMPACTION_BATCH_TABLES = 25;
    uint256 private constant MAX_CONSOLIDATION_BATCH_WORK = 25;
    uint256 private constant MAX_BALANCE_SCAN_TABLES = 50;
    uint256 private constant INITIAL_COLONIES = 1;
    uint256 private constant MAX_COLONIES = 3;
    uint256 private constant EXPANSION_CLAIM_WINDOW_ROUNDS = 3;

    enum TournamentState {
        Registration,
        Active,
        Complete
    }

    enum FinalizationPhase {
        None,
        SupportChecks,
        ResourcePenalties,
        TableCompaction,
        TableConsolidation,
        BalanceScan,
        BalanceMove,
        ReadyToFinalize
    }

    struct PlayerInfo {
        bool registered;
        bool active;
        uint256 principalStETH;
        bool principalClaimed;
        uint256 tableId;
    }

    struct ColonyInfo {
        address owner;
        address landLord;
        bool active;
        uint256 createdRound;
    }

    struct RoundVrfState {
        uint256 activeRequestId;
        uint256 requestedAt;
        uint256 attempts;
        bool fulfilled;
    }

    struct RoundFinalization {
        FinalizationPhase phase;
        uint256 playerCursor;
        uint256 tableCursor;
        uint256 targetTableCount;
        uint256 sourceTableId;
        uint256 destinationTableId;
        uint256 balanceScanCursor;
        uint256 smallestTableId;
        uint256 smallestSize;
        uint256 largestTableId;
        uint256 largestSize;
    }

    error VrfConfigurationFrozen();
    error InvalidVrfProvider();
    error InvalidVrfRequestTimeout();
    error VrfProviderNotConfigured();
    error VrfRoundNotActive();
    error VrfRevealStillOpen();
    error VrfRandomnessAlreadyFulfilled();
    error VrfRequestAlreadyActive(uint256 requestId);
    error VrfRequestMissing();
    error VrfRequestNotExpired(uint256 retryEligibleAt);
    error InvalidVrfRequestId();
    error UnknownVrfRequest(uint256 requestId);
    error StaleVrfRequest(uint256 requestId);
    error InactiveVrfRequest(uint256 requestId);
    error VrfRequestRoundMismatch(uint256 expectedRound, uint256 actualRound);
    error InvalidVrfRandomness();
    error UnauthorizedVrfProvider();
    error WrongFinalizationPhase();
    error InvalidBatchSize();
    error InvalidLotteryResult();

    address public immutable admin;
    address public immutable landLordImplementation;
    IResourceLottery private immutable resourceLottery;
    uint256 public immutable tournamentId;
    uint256 public immutable entryDeposit;
    uint256 public totalPrincipalStETH;
    uint256 public outstandingPrincipalStETH;
    uint256 public totalPrincipalStETHClaimed;
    uint256 public totalYieldStETHClaimed;
    address public yieldAdapter;

    address public battleManager;
    address public vrfProvider;
    uint256 public vrfRequestTimeout;

    TournamentState public state;
    uint256 public tableCount;
    uint256 public activePlayers;
    uint256 public initialPlayerCount;
    uint256 public nextColonyId;
    uint256 public lastStartedRound;
    uint256 public lastEndedRound;
    uint256 public expansionUnlockRound;
    address public winner;
    address[] public players;
    mapping(address => PlayerInfo) public playerInfo;
    mapping(uint256 => ColonyInfo) public colonyInfo;
    mapping(address => uint256[]) private playerColonies;
    mapping(address => uint256) public activeColonyCount;
    mapping(address => uint256) public expansionsUsed;
    mapping(address => uint256) private expansionClaims;
    mapping(uint256 => address[]) private tablePlayers;
    mapping(uint256 => uint256) public vrfRequestToRound;
    mapping(uint256 => bool) public staleVrfRequest;
    mapping(uint256 => RoundVrfState) public roundVrfState;
    mapping(address => uint256) public planAppliedRound;
    RoundFinalization private roundFinalization;

    event PlayerRegistered(address indexed player);
    event ColonyCreated(
        uint256 indexed colonyId,
        address indexed owner,
        address indexed landLord,
        uint256 createdRound
    );
    event ColonyEliminated(uint256 indexed colonyId, address indexed owner);
    event TournamentStarted();
    event TournamentCompleted();
    event WinnerFinalized(address indexed winner);
    event BattleManagerSet(address indexed battleManager);
    event VrfProviderSet(address indexed vrfProvider);
    event YieldAdapterSet(address indexed adapter);
    event PrincipalDeposited(
        address indexed player,
        bool paidWithETH,
        uint256 inputAmount,
        uint256 principalStETH
    );
    event PrincipalClaimed(
        address indexed player,
        uint256 nominalPrincipalStETH,
        uint256 stETHTransferred,
        uint256 remainingPrincipalLiability
    );
    event YieldClaimed(
        address indexed winner,
        uint256 stETHTransferred,
        uint256 remainingPrincipalLiability
    );
    event RoundStarted(uint256 indexed roundId);
    event RoundRandomnessRequested(
        uint256 indexed roundId,
        uint256 indexed requestId,
        uint256 attempt,
        uint256 requestedAt
    );
    event RoundRandomnessRequestExpired(
        uint256 indexed roundId,
        uint256 indexed requestId
    );
    event RoundRandomnessRetried(
        uint256 indexed roundId,
        uint256 indexed previousRequestId,
        uint256 indexed newRequestId,
        uint256 attempt
    );
    event RoundRandomnessFulfilled(
        uint256 indexed roundId,
        uint256 indexed requestId,
        uint256 randomness
    );
    event RoundEnded(uint256 indexed roundId);
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
        if (msg.sender != vrfProvider) revert UnauthorizedVrfProvider();
        _;
    }

    modifier inState(TournamentState expected) {
        require(state == expected, "wrong state");
        _;
    }

    constructor(
        address _yieldAdapter,
        address _landLordImplementation,
        address _resourceLottery,
        uint256 _tournamentId,
        uint256 _entryDeposit
    ) {
        require(_yieldAdapter != address(0), "invalid yield adapter");
        require(_landLordImplementation != address(0), "invalid landlord");
        require(_resourceLottery != address(0), "invalid resource lottery");
        require(_entryDeposit > 0, "invalid entry deposit");

        admin = msg.sender;
        yieldAdapter = _yieldAdapter;
        landLordImplementation = _landLordImplementation;
        resourceLottery = IResourceLottery(_resourceLottery);
        tournamentId = _tournamentId;
        entryDeposit = _entryDeposit;
        state = TournamentState.Registration;
        vrfRequestTimeout = DEFAULT_VRF_REQUEST_TIMEOUT;
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
        if (state != TournamentState.Registration || players.length != 0) {
            revert VrfConfigurationFrozen();
        }
        if (_vrfProvider == address(0)) revert InvalidVrfProvider();
        vrfProvider = _vrfProvider;
        emit VrfProviderSet(_vrfProvider);
    }

    function setVrfRequestTimeout(uint256 timeout) external onlyAdmin {
        if (state != TournamentState.Registration || players.length != 0) {
            revert VrfConfigurationFrozen();
        }
        if (timeout == 0) revert InvalidVrfRequestTimeout();
        vrfRequestTimeout = timeout;
    }

    function registerWithETH()
        external
        payable
        nonReentrant
        inState(TournamentState.Registration)
    {
        require(msg.value == entryDeposit, "deposit");
        uint256 principal = IYieldAdapter(yieldAdapter).depositETH{
            value: msg.value
        }();
        _registerPlayer(msg.sender, principal);
        emit PrincipalDeposited(msg.sender, true, msg.value, principal);
    }

    function registerWithStETH(uint256 amount)
        external
        nonReentrant
        inState(TournamentState.Registration)
    {
        require(amount == entryDeposit, "deposit");
        uint256 principal = IYieldAdapter(yieldAdapter).depositAsset(
            msg.sender,
            amount
        );
        _registerPlayer(msg.sender, principal);
        emit PrincipalDeposited(msg.sender, false, amount, principal);
    }

    function _registerPlayer(address player, uint256 principal) internal {
        require(!playerInfo[player].registered, "registered");
        require(principal > 0, "zero principal");

        totalPrincipalStETH += principal;
        outstandingPrincipalStETH += principal;

        for (uint256 i = 0; i < INITIAL_COLONIES; i++) {
            _createColony(player);
        }

        playerInfo[player] = PlayerInfo({
            registered: true,
            active: true,
            principalStETH: principal,
            principalClaimed: false,
            tableId: 0
        });
        players.push(player);
        activePlayers++;
        _assignToOpenTable(player);

        emit PlayerRegistered(player);
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
        returns (uint256 roundId)
    {
        require(battleManager != address(0), "battle manager");
        require(vrfProvider != address(0), "vrf provider");
        require(
            lastStartedRound == lastEndedRound,
            "round active"
        );

        uint256 requiredTableCount = _requiredTableCount();
        roundId = ITournamentBattleManager(battleManager).startNextRound(
            requiredTableCount
        );
        lastStartedRound = roundId;

        emit RoundStarted(roundId);
    }

    function requestRoundRandomness()
        external
        nonReentrant
        inState(TournamentState.Active)
        returns (uint256 requestId)
    {
        uint256 roundId = _currentRoundExpectingRandomness();
        RoundVrfState storage requestState = roundVrfState[roundId];
        if (requestState.activeRequestId != 0) {
            revert VrfRequestAlreadyActive(requestState.activeRequestId);
        }
        requestId = _createRoundRandomnessRequest(roundId, requestState);
    }

    function retryRoundRandomness()
        external
        nonReentrant
        inState(TournamentState.Active)
        returns (uint256 requestId)
    {
        uint256 roundId = _currentRoundExpectingRandomness();
        RoundVrfState storage requestState = roundVrfState[roundId];
        uint256 previousRequestId = requestState.activeRequestId;
        if (previousRequestId == 0) revert VrfRequestMissing();

        uint256 retryEligibleAt = requestState.requestedAt + vrfRequestTimeout;
        if (block.timestamp < retryEligibleAt) {
            revert VrfRequestNotExpired(retryEligibleAt);
        }

        staleVrfRequest[previousRequestId] = true;
        emit RoundRandomnessRequestExpired(roundId, previousRequestId);

        requestId = _createRoundRandomnessRequest(roundId, requestState);
        emit RoundRandomnessRetried(
            roundId,
            previousRequestId,
            requestId,
            requestState.attempts
        );
    }

    function endBattleRound()
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        _beginRoundFinalization();
    }

    function _beginRoundFinalization() internal {
        uint256 roundId = ITournamentBattleManager(battleManager).currentRound();
        require(roundId == lastStartedRound, "round mismatch");
        require(lastEndedRound < roundId, "round ended");
        require(ITournamentBattleManager(battleManager).canEndRound(), "round not over");
        if (roundFinalization.phase != FinalizationPhase.None) {
            revert WrongFinalizationPhase();
        }

        roundFinalization = RoundFinalization({
            phase: FinalizationPhase.SupportChecks,
            playerCursor: 0,
            tableCursor: 0,
            targetTableCount: 0,
            sourceTableId: 0,
            destinationTableId: 0,
            balanceScanCursor: 0,
            smallestTableId: 0,
            smallestSize: 0,
            largestTableId: 0,
            largestSize: 0
        });

    }

    function processSupportBatch(uint256 maxPlayers)
        external
        nonReentrant
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.SupportChecks);
        _requireBatchSize(maxPlayers, MAX_SUPPORT_BATCH_PLAYERS);

        uint256 start = roundFinalization.playerCursor;
        uint256 end = start + maxPlayers;
        if (end > players.length) end = players.length;

        for (uint256 i = start; i < end; i++) {
            _applyPlayerSupportCheck(
                players[i],
                lastStartedRound
            );
        }
        roundFinalization.playerCursor = end;
        if (end != players.length) return;
        if (activePlayers <= 1) {
            uint256 roundId = lastStartedRound;
            lastEndedRound = roundId;
            emit RoundEnded(roundId);
            _completeTournament();
            return;
        }

        roundFinalization.phase = FinalizationPhase.ResourcePenalties;
        roundFinalization.tableCursor = 1;
    }

    function processPenaltyBatch(uint256 maxTables)
        external
        nonReentrant
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.ResourcePenalties);
        _requireBatchSize(maxTables, MAX_PENALTY_BATCH_TABLES);

        uint256 start = roundFinalization.tableCursor;
        uint256 end = start + maxTables;
        uint256 afterLastTable = tableCount + 1;
        if (end > afterLastTable) end = afterLastTable;

        uint256 randomness = ITournamentBattleManager(battleManager)
            .getRoundRandomness(lastStartedRound);
        for (uint256 tableId = start; tableId < end; tableId++) {
            _applyWeightedResourcePenaltyForTable(
                lastStartedRound,
                tableId,
                randomness
            );
        }
        roundFinalization.tableCursor = end;
        if (end != afterLastTable) return;
        roundFinalization.phase = FinalizationPhase.TableCompaction;
        roundFinalization.tableCursor = 1;
    }

    function processTableCompactionBatch(uint256 maxTables)
        external
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.TableCompaction);
        _requireBatchSize(maxTables, MAX_COMPACTION_BATCH_TABLES);

        uint256 start = roundFinalization.tableCursor;
        uint256 end = start + maxTables;
        uint256 afterLastTable = tableCount + 1;
        if (end > afterLastTable) end = afterLastTable;

        for (uint256 tableId = start; tableId < end; tableId++) {
            _compactTable(tableId);
        }
        roundFinalization.tableCursor = end;
        if (end != afterLastTable) return;
        roundFinalization.targetTableCount =
            (activePlayers + MAX_TABLE_SIZE - 1) / MAX_TABLE_SIZE;
        roundFinalization.sourceTableId = tableCount;
        roundFinalization.destinationTableId = 1;
        roundFinalization.phase = FinalizationPhase.TableConsolidation;
    }

    function processTableConsolidationBatch(uint256 maxWork)
        external
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.TableConsolidation);
        _requireBatchSize(maxWork, MAX_CONSOLIDATION_BATCH_WORK);

        uint256 workProcessed;
        while (
            workProcessed < maxWork &&
            roundFinalization.sourceTableId >
            roundFinalization.targetTableCount
        ) {
            uint256 sourceTableId = roundFinalization.sourceTableId;
            address[] storage sourcePlayers = tablePlayers[sourceTableId];
            if (sourcePlayers.length == 0) {
                roundFinalization.sourceTableId = sourceTableId - 1;
                workProcessed++;
                continue;
            }

            while (
                tablePlayers[roundFinalization.destinationTableId].length >=
                MAX_TABLE_SIZE
            ) {
                roundFinalization.destinationTableId++;
            }

            address player = sourcePlayers[sourcePlayers.length - 1];
            sourcePlayers.pop();
            uint256 destinationTableId =
                roundFinalization.destinationTableId;
            tablePlayers[destinationTableId].push(player);
            playerInfo[player].tableId = destinationTableId;
            emit PlayerMovedTable(
                player,
                sourceTableId,
                destinationTableId
            );
            workProcessed++;
        }

        if (
            roundFinalization.sourceTableId >
            roundFinalization.targetTableCount
        ) return;

        tableCount = roundFinalization.targetTableCount;
        _startBalanceScan();
    }

    function processBalanceScanBatch(uint256 maxTables)
        external
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.BalanceScan);
        _requireBatchSize(maxTables, MAX_BALANCE_SCAN_TABLES);

        uint256 start = roundFinalization.balanceScanCursor;
        uint256 end = start + maxTables;
        uint256 afterLastTable = tableCount + 1;
        if (end > afterLastTable) end = afterLastTable;

        for (uint256 tableId = start; tableId < end; tableId++) {
            uint256 size = tablePlayers[tableId].length;
            if (
                size < roundFinalization.smallestSize
            ) {
                roundFinalization.smallestSize = size;
                roundFinalization.smallestTableId = tableId;
            }
            if (
                size > roundFinalization.largestSize
            ) {
                roundFinalization.largestSize = size;
                roundFinalization.largestTableId = tableId;
            }
        }
        roundFinalization.balanceScanCursor = end;
        if (end != afterLastTable) return;
        if (
            roundFinalization.largestSize -
            roundFinalization.smallestSize <=
            3
        ) {
            roundFinalization.phase = FinalizationPhase.ReadyToFinalize;
        } else {
            roundFinalization.phase = FinalizationPhase.BalanceMove;
        }
    }

    function applyBalanceMove()
        external
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.BalanceMove);

        uint256 largestTableId = roundFinalization.largestTableId;
        uint256 smallestTableId = roundFinalization.smallestTableId;
        address[] storage largestTable = tablePlayers[largestTableId];
        address player = largestTable[largestTable.length - 1];
        largestTable.pop();
        tablePlayers[smallestTableId].push(player);
        playerInfo[player].tableId = smallestTableId;
        emit PlayerMovedTable(player, largestTableId, smallestTableId);

        _startBalanceScan();
    }

    function finalizeRound()
        external
        onlyAdmin
        inState(TournamentState.Active)
    {
        _requireFinalizationPhase(FinalizationPhase.ReadyToFinalize);
        uint256 roundId = lastStartedRound;
        lastEndedRound = roundId;
        delete roundFinalization;
        emit RoundEnded(roundId);
    }

    function receiveRandomness(uint256 requestId, uint256 randomness)
        external
        onlyVrfProvider
    {
        uint256 roundId = vrfRequestToRound[requestId];
        if (roundId == 0) revert UnknownVrfRequest(requestId);
        if (staleVrfRequest[requestId]) revert StaleVrfRequest(requestId);
        if (roundId != lastStartedRound) {
            revert VrfRequestRoundMismatch(lastStartedRound, roundId);
        }

        RoundVrfState storage requestState = roundVrfState[roundId];
        if (requestState.fulfilled) revert VrfRandomnessAlreadyFulfilled();
        if (requestState.activeRequestId != requestId) {
            revert InactiveVrfRequest(requestId);
        }
        if (state != TournamentState.Active || lastEndedRound >= roundId) {
            revert VrfRoundNotActive();
        }
        if (randomness == 0) revert InvalidVrfRandomness();

        requestState.fulfilled = true;

        ITournamentBattleManager(battleManager).setRoundRandomness(
            roundId,
            randomness
        );

        emit RoundRandomnessFulfilled(roundId, requestId, randomness);
    }

    function isRoundRandomnessRetryEligible(uint256 roundId)
        external
        view
        returns (bool)
    {
        RoundVrfState memory requestState = roundVrfState[roundId];
        return
            state == TournamentState.Active &&
            roundId == lastStartedRound &&
            lastEndedRound < roundId &&
            requestState.activeRequestId != 0 &&
            !requestState.fulfilled &&
            block.timestamp >= requestState.requestedAt + vrfRequestTimeout;
    }

    function _currentRoundExpectingRandomness()
        internal
        view
        returns (uint256 roundId)
    {
        if (vrfProvider == address(0)) revert VrfProviderNotConfigured();
        roundId = ITournamentBattleManager(battleManager).currentRound();
        if (
            roundId == 0 ||
            roundId != lastStartedRound ||
            lastEndedRound >= roundId
        ) revert VrfRoundNotActive();
        if (
            ITournamentBattleManager(battleManager).getPhase() !=
                ITournamentBattleManager.Phase.Resolve
        ) {
            revert VrfRevealStillOpen();
        }
        RoundVrfState storage requestState = roundVrfState[roundId];
        if (
            requestState.fulfilled ||
            ITournamentBattleManager(battleManager).getRoundRandomness(roundId) != 0
        ) revert VrfRandomnessAlreadyFulfilled();
    }

    function _createRoundRandomnessRequest(
        uint256 roundId,
        RoundVrfState storage requestState
    ) internal returns (uint256 requestId) {
        requestId = ITournamentVRFProvider(vrfProvider).requestRandomness(roundId);
        if (requestId == 0 || vrfRequestToRound[requestId] != 0) {
            revert InvalidVrfRequestId();
        }

        requestState.activeRequestId = requestId;
        requestState.requestedAt = block.timestamp;
        requestState.attempts++;
        vrfRequestToRound[requestId] = roundId;

        emit RoundRandomnessRequested(
            roundId,
            requestId,
            requestState.attempts,
            block.timestamp
        );
    }

    function eliminatePlayer(address player) external onlyBattleManager {
        _eliminatePlayer(player);
    }

    function settleConflictGroup(
        uint256 roundId,
        address conflictWinner,
        address[] calldata participants,
        uint256[] calldata paymentColonyIds,
        uint256 winnerColonyId,
        uint256 groupStake
    ) external onlyBattleManager returns (uint256 totalTransferred) {
        require(participants.length > 1, "invalid group");
        require(participants.length == paymentColonyIds.length, "colony length");
        require(groupStake > 0, "invalid stake");
        require(playerInfo[conflictWinner].active, "winner inactive");

        uint256 resolvedWinnerColony = _resolveActionColony(
            conflictWinner,
            winnerColonyId
        );
        require(resolvedWinnerColony != 0, "missing winner colony");
        require(_isColonyAvailableForRound(resolvedWinnerColony, roundId), "pending");
        address winnerLandLord = colonyInfo[resolvedWinnerColony].landLord;

        for (uint256 i = 0; i < participants.length; i++) {
            address loser = participants[i];
            require(playerInfo[loser].active, "participant inactive");

            if (loser == conflictWinner) continue;

            totalTransferred += _settleConflictLoser(
                roundId,
                conflictWinner,
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

    function validateRoundPlan(
        address player,
        uint256 roundId,
        GameTypes.RoundPlan calldata plan
    ) public view returns (bool) {
        if (state != TournamentState.Active) return false;
        if (!playerInfo[player].active) return false;
        if (roundId == 0 || roundId != lastStartedRound) return false;
        if (plan.allocations.length > MAX_COLONIES) return false;

        if (plan.claimExpansion) {
            if (_claimableExpansionSlot(player) == 0) return false;
            if (activeColonyCount[player] >= MAX_COLONIES) return false;
        }

        for (uint256 i = 0; i < plan.allocations.length; i++) {
            GameTypes.ColonyAllocation calldata allocation = plan.allocations[i];
            if (!_ownsActiveColony(player, allocation.colonyId)) return false;
            if (!_isColonyAvailableForRound(allocation.colonyId, roundId)) return false;

            for (uint256 j = 0; j < i; j++) {
                if (plan.allocations[j].colonyId == allocation.colonyId) {
                    return false;
                }
            }

            uint256 committedGold = allocation.food +
                allocation.water +
                allocation.oxygen +
                allocation.shelter +
                allocation.army;
            if (
                plan.action.actionType == GameTypes.ActionType.ATTACK &&
                plan.action.sourceColonyId == allocation.colonyId
            ) {
                committedGold += plan.action.amount;
            }
            if (committedGold > getColonyGold(allocation.colonyId)) return false;
        }

        return true;
    }

    function applyRoundPlan(
        address player,
        uint256 roundId,
        GameTypes.RoundPlan calldata plan
    ) external onlyBattleManager {
        require(planAppliedRound[player] != roundId, "plan applied");
        require(validateRoundPlan(player, roundId, plan), "invalid plan");

        planAppliedRound[player] = roundId;
        for (uint256 i = 0; i < plan.allocations.length; i++) {
            _applyColonyAllocation(plan.allocations[i]);
        }

        if (plan.claimExpansion) {
            uint256 expansionSlot = _claimableExpansionSlot(player);
            expansionClaims[player] |= expansionSlot;
            expansionsUsed[player]++;
            _createColony(player);
        }
    }

    function _applyColonyAllocation(
        GameTypes.ColonyAllocation calldata allocation
    ) internal {
        LandLord(colonyInfo[allocation.colonyId].landLord).allocateResources(
            allocation.food,
            allocation.water,
            allocation.oxygen,
            allocation.shelter,
            allocation.army
        );
    }

    function _settleConflictLoser(
        uint256 roundId,
        address conflictWinner,
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
            conflictWinner,
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
        ITournamentBattleManager(battleManager).resolveTableConflicts(
            tableId,
            roundId
        );
    }

    function claimPrincipal() external nonReentrant {
        PlayerInfo storage info = playerInfo[msg.sender];
        require(info.registered, "not registered");
        require(!info.principalClaimed, "principal claimed");
        require(!info.active || state == TournamentState.Complete, "principal locked");

        uint256 nominalPrincipal = info.principalStETH;
        uint256 assets = IYieldAdapter(yieldAdapter).totalAssets();
        uint256 amount = nominalPrincipal;
        if (assets < outstandingPrincipalStETH) {
            amount =
                (nominalPrincipal * assets) /
                outstandingPrincipalStETH;
        }

        info.principalClaimed = true;
        outstandingPrincipalStETH -= nominalPrincipal;
        totalPrincipalStETHClaimed += nominalPrincipal;

        uint256 withdrawn;
        if (amount > 0) {
            withdrawn = IYieldAdapter(yieldAdapter).withdrawAsset(
                msg.sender,
                amount
            );
        }
        emit PrincipalClaimed(
            msg.sender,
            nominalPrincipal,
            withdrawn,
            outstandingPrincipalStETH
        );
    }

    function claimYield() external nonReentrant inState(TournamentState.Complete) {
        require(winner != address(0), "winner not finalized");
        require(msg.sender == winner, "not winner");
        uint256 availableYield = getAvailableYield();
        require(availableYield > 0, "no yield");

        uint256 withdrawn = IYieldAdapter(yieldAdapter).withdrawAsset(
            msg.sender,
            availableYield
        );
        totalYieldStETHClaimed += withdrawn;
        emit YieldClaimed(
            msg.sender,
            withdrawn,
            outstandingPrincipalStETH
        );
    }

    function getAvailableYield() public view returns (uint256) {
        uint256 assets = IYieldAdapter(yieldAdapter).totalAssets();
        if (assets <= outstandingPrincipalStETH) return 0;
        return assets - outstandingPrincipalStETH;
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

        return LandLord(colonyInfo[resolvedColonyId].landLord).getArmyBonus();
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
        if (activePlayers == 1 && winner == address(0)) {
            for (uint256 i = 0; i < players.length; i++) {
                if (playerInfo[players[i]].active) {
                    winner = players[i];
                    emit WinnerFinalized(players[i]);
                    break;
                }
            }
        }
        delete roundFinalization;
        state = TournamentState.Complete;
        emit TournamentCompleted();
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }

    function finalizationPhase() external view returns (FinalizationPhase) {
        return roundFinalization.phase;
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
        uint256 wager,
        uint256 sourceColonyId,
        uint256 targetColonyId
    ) external view returns (bool) {
        if (_tournamentId != tournamentId) return false;
        if (attacker == target) return false;
        if (wager == 0) return false;
        if (!_isSameTable(attacker, target)) return false;
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

    function _requiredTableCount() internal view returns (uint256 requiredTableCount) {
        bool[] memory tableSeen = new bool[](tableCount + 1);

        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            PlayerInfo memory info = playerInfo[player];
            if (!info.active) continue;

            if (
                info.tableId != 0 &&
                info.tableId <= tableCount &&
                !tableSeen[info.tableId]
            ) {
                tableSeen[info.tableId] = true;
                requiredTableCount++;
            }
        }
    }

    function _applyPlayerSupportCheck(address player, uint256 roundId) internal {
        if (!playerInfo[player].active) return;

        uint256[] memory colonies = playerColonies[player];
        for (uint256 i = 0; i < colonies.length; i++) {
            uint256 colonyId = colonies[i];
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

    function _applyWeightedResourcePenaltyForTable(
        uint256 roundId,
        uint256 tableId,
        uint256 randomness
    ) internal {
        (uint256 resource, uint256 colonyId, uint256 penaltyAmount) =
            resourceLottery.calculatePenalty(
                address(this),
                roundId,
                tableId,
                randomness
            );
        if (colonyId == 0) return;

        ColonyInfo memory colony = colonyInfo[colonyId];
        PlayerInfo memory owner = playerInfo[colony.owner];
        if (
            resource >= uint256(LandLord.ResourceType.Army) ||
            !colony.active ||
            colony.landLord == address(0) ||
            colony.createdRound >= roundId ||
            !owner.active ||
            owner.tableId != tableId
        ) revert InvalidLotteryResult();

        LandLord.Resources memory balances =
            LandLord(colony.landLord).getResources();
        uint256 resourceBalance = _resourceBalance(
            balances,
            LandLord.ResourceType(resource)
        );
        if (
            penaltyAmount >
            (resourceBalance * 2_000 + BASIS_POINTS - 1) / BASIS_POINTS
        ) revert InvalidLotteryResult();

        LandLord(colony.landLord).applyResourcePenalty(
            roundId,
            colonyId,
            LandLord.ResourceType(resource),
            penaltyAmount
        );
    }

    function _resourceBalance(
        LandLord.Resources memory balances,
        LandLord.ResourceType resource
    ) internal pure returns (uint256) {
        if (resource == LandLord.ResourceType.Food) return balances.food;
        if (resource == LandLord.ResourceType.Water) return balances.water;
        if (resource == LandLord.ResourceType.Oxygen) return balances.oxygen;
        return balances.shelter;
    }

    function _compactTable(uint256 tableId) internal {
        address[] storage assignedPlayers = tablePlayers[tableId];
        uint256 activeCursor;

        for (uint256 i = 0; i < assignedPlayers.length; i++) {
            address player = assignedPlayers[i];
            if (!playerInfo[player].active) {
                playerInfo[player].tableId = 0;
                continue;
            }

            if (activeCursor != i) {
                assignedPlayers[activeCursor] = player;
            }
            activeCursor++;
        }

        while (assignedPlayers.length > activeCursor) {
            assignedPlayers.pop();
        }
    }

    function _startBalanceScan() internal {
        if (tableCount <= 1) {
            roundFinalization.phase = FinalizationPhase.ReadyToFinalize;
            return;
        }

        uint256 firstSize = tablePlayers[1].length;
        roundFinalization.balanceScanCursor = 2;
        roundFinalization.smallestTableId = 1;
        roundFinalization.smallestSize = firstSize;
        roundFinalization.largestTableId = 1;
        roundFinalization.largestSize = firstSize;
        roundFinalization.phase = FinalizationPhase.BalanceScan;
    }

    function _requireBatchSize(uint256 requested, uint256 maximum)
        internal
        pure
    {
        if (requested == 0 || requested > maximum) {
            revert InvalidBatchSize();
        }
    }

    function _requireFinalizationPhase(FinalizationPhase expected)
        internal
        view
    {
        if (roundFinalization.phase != expected) {
            revert WrongFinalizationPhase();
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LandLord} from "./LandLord.sol";
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
    uint256 public constant PENALTY_RATIO_SMOOTHING_BPS = 500;
    uint256 public constant PENALTY_WEIGHT_NUMERATOR = 100_000_000;
    uint256 public constant MIN_RESOURCE_PENALTY_BPS = 500;
    uint256 public constant MAX_RESOURCE_PENALTY_BPS = 2_000;
    uint256 private constant RESOURCE_PENALTY_DOMAIN =
        uint256(keccak256("weighted-resource-penalty"));
    uint256 private constant RESOURCE_PENALTY_SELECTION_DOMAIN =
        uint256(keccak256("weighted-resource-penalty-selection"));
    uint256 private constant RESOURCE_PENALTY_SIZE_DOMAIN =
        uint256(keccak256("weighted-resource-penalty-size"));
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

    struct PenaltyCandidate {
        uint256 totalResource;
        uint256 resourceBalance;
        uint256 weakestColonyId;
        uint256 weakestColonyBalance;
        uint256 weakestColonyTotal;
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

    address public immutable admin;
    address public immutable landLordImplementation;
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

        _applyWeightedResourcePenalties(roundId, randomness);

        _rebalanceTables();
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

    function _applyWeightedResourcePenalties(uint256 roundId, uint256 randomness)
        internal
    {
        LandLord.ResourceType selectedResource = LandLord.ResourceType(
            uint256(
                keccak256(
                    abi.encode(
                        randomness,
                        roundId,
                        RESOURCE_PENALTY_SELECTION_DOMAIN
                    )
                )
            ) % uint256(LandLord.ResourceType.Army)
        );

        for (uint256 tableId = 1; tableId <= tableCount; tableId++) {
            address[] memory assignedPlayers = tablePlayers[tableId];
            PenaltyCandidate[] memory candidates =
                new PenaltyCandidate[](assignedPlayers.length);
            uint256 candidateCount;

            for (uint256 i = 0; i < assignedPlayers.length; i++) {
                address player = assignedPlayers[i];
                if (!playerInfo[player].active) continue;

                PenaltyCandidate memory candidate =
                    _buildPenaltyCandidate(player, roundId, selectedResource);
                if (candidate.totalResource == 0) continue;
                candidates[candidateCount++] = candidate;
            }

            _applyWeightedResourcePenalty(
                roundId,
                tableId,
                randomness,
                selectedResource,
                candidates,
                candidateCount
            );
        }
    }

    function _buildPenaltyCandidate(address player, uint256 roundId, LandLord.ResourceType selectedResource)
        internal
        view
        returns (PenaltyCandidate memory candidate)
    {
        uint256[] memory colonies = playerColonies[player];

        for (uint256 i = 0; i < colonies.length; i++) {
            uint256 colonyId = colonies[i];
            ColonyInfo memory colony = colonyInfo[colonyId];
            if (
                !colony.active ||
                !_isColonyAvailableForRound(colonyId, roundId)
            ) continue;

            LandLord.Resources memory balances = LandLord(colony.landLord)
                .getResources();
            uint256 colonyTotal = _totalColonyResources(balances);
            candidate.totalResource += colonyTotal;

            uint256 balance = _resourceBalance(
                balances,
                selectedResource
            );
            candidate.resourceBalance += balance;

            uint256 weakestId = candidate.weakestColonyId;
            if (
                weakestId == 0 ||
                balance * candidate.weakestColonyTotal <
                    candidate.weakestColonyBalance * colonyTotal ||
                (
                    balance * candidate.weakestColonyTotal ==
                        candidate.weakestColonyBalance *
                            colonyTotal &&
                    colonyId < weakestId
                )
            ) {
                candidate.weakestColonyId = colonyId;
                candidate.weakestColonyBalance = balance;
                candidate.weakestColonyTotal = colonyTotal;
            }
        }
    }

    function _applyWeightedResourcePenalty(
        uint256 roundId,
        uint256 tableId,
        uint256 randomness,
        LandLord.ResourceType resource,
        PenaltyCandidate[] memory candidates,
        uint256 candidateCount
    ) internal {
        uint256[] memory weights = new uint256[](candidateCount);
        uint256 totalWeight;

        for (uint256 i = 0; i < candidateCount; i++) {
            uint256 ratioBps =
                candidates[i].resourceBalance * BASIS_POINTS /
                candidates[i].totalResource;
            uint256 weight = PENALTY_WEIGHT_NUMERATOR /
                (PENALTY_RATIO_SMOOTHING_BPS + ratioBps);
            weights[i] = weight;
            totalWeight += weight;
        }
        if (totalWeight == 0) return;

        uint256 roll = uint256(
            keccak256(
                abi.encode(
                    randomness,
                    roundId,
                    tableId,
                    resource,
                    RESOURCE_PENALTY_DOMAIN
                )
            )
        ) % totalWeight;
        uint256 selectedIndex;
        uint256 cumulativeWeight;
        for (uint256 i = 0; i < candidateCount; i++) {
            cumulativeWeight += weights[i];
            if (roll < cumulativeWeight) {
                selectedIndex = i;
                break;
            }
        }

        PenaltyCandidate memory selected = candidates[selectedIndex];
        uint256 colonyId = selected.weakestColonyId;
        if (colonyId == 0) return;

        uint256 penaltyBps = MIN_RESOURCE_PENALTY_BPS +
            (
                uint256(
                    keccak256(
                        abi.encode(
                            randomness,
                            roundId,
                            tableId,
                            resource,
                            colonyId,
                            RESOURCE_PENALTY_SIZE_DOMAIN
                        )
                    )
                ) %
                (MAX_RESOURCE_PENALTY_BPS - MIN_RESOURCE_PENALTY_BPS + 1)
            );
        uint256 penaltyAmount =
            (
                selected.weakestColonyBalance * penaltyBps +
                BASIS_POINTS -
                1
            ) / BASIS_POINTS;

        LandLord(colonyInfo[colonyId].landLord).applyResourcePenalty(
            roundId,
            colonyId,
            resource,
            penaltyAmount
        );
    }

    function _totalColonyResources(LandLord.Resources memory balances)
        internal
        pure
        returns (uint256)
    {
        return balances.gold + balances.food + balances.water + balances.oxygen +
            balances.shelter + balances.army;
    }

    function _resourceBalance(
        LandLord.Resources memory balances,
        LandLord.ResourceType resource
    ) internal pure returns (uint256) {
        if (resource == LandLord.ResourceType.Food) return balances.food;
        if (resource == LandLord.ResourceType.Water) return balances.water;
        if (resource == LandLord.ResourceType.Oxygen) return balances.oxygen;
        if (resource == LandLord.ResourceType.Shelter) return balances.shelter;
        return balances.army;
    }

    /**
     * @dev Keeps surviving players at their current tables whenever possible.
     *      Excess highest-numbered tables are dissolved, then tables are
     *      balanced only while the largest and smallest sizes differ by more
     *      than three players.
     */
    function _rebalanceTables() internal {
        _compactTables();

        uint256 targetTableCount =
            (activePlayers + MAX_TABLE_SIZE - 1) / MAX_TABLE_SIZE;
        _consolidateTables(targetTableCount);
        _balanceTables();
    }

    function _compactTables() internal {
        for (uint256 tableId = 1; tableId <= tableCount; tableId++) {
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
    }

    function _consolidateTables(uint256 targetTableCount) internal {
        if (targetTableCount >= tableCount) return;

        uint256 destinationTableId = 1;
        for (
            uint256 sourceTableId = tableCount;
            sourceTableId > targetTableCount;
            sourceTableId--
        ) {
            address[] storage sourcePlayers = tablePlayers[sourceTableId];
            while (sourcePlayers.length > 0) {
                while (
                    tablePlayers[destinationTableId].length >= MAX_TABLE_SIZE
                ) {
                    destinationTableId++;
                }

                address player = sourcePlayers[sourcePlayers.length - 1];
                sourcePlayers.pop();
                tablePlayers[destinationTableId].push(player);
                playerInfo[player].tableId = destinationTableId;
                emit PlayerMovedTable(
                    player,
                    sourceTableId,
                    destinationTableId
                );
            }
        }

        tableCount = targetTableCount;
    }

    function _balanceTables() internal {
        if (tableCount <= 1) return;

        while (true) {
            uint256 smallestTableId = 1;
            uint256 largestTableId = 1;
            uint256 smallestSize = tablePlayers[1].length;
            uint256 largestSize = smallestSize;

            for (uint256 tableId = 2; tableId <= tableCount; tableId++) {
                uint256 size = tablePlayers[tableId].length;
                if (size < smallestSize) {
                    smallestSize = size;
                    smallestTableId = tableId;
                }
                if (size > largestSize) {
                    largestSize = size;
                    largestTableId = tableId;
                }
            }

            if (largestSize - smallestSize <= 3) return;

            address[] storage largestTable = tablePlayers[largestTableId];
            address player = largestTable[largestTable.length - 1];
            largestTable.pop();
            tablePlayers[smallestTableId].push(player);
            playerInfo[player].tableId = smallestTableId;
            emit PlayerMovedTable(player, largestTableId, smallestTableId);
        }
    }
}

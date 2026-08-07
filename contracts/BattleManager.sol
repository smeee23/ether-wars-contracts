// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {GameTypes} from "./libraries/GameTypes.sol";

interface IBattleTournamentManager {
    function validateRoundPlan(
        address player,
        uint256 roundId,
        GameTypes.RoundPlan calldata plan
    ) external view returns (bool);

    function applyRoundPlan(
        address player,
        uint256 roundId,
        GameTypes.RoundPlan calldata plan
    ) external;

    function isValidAttackForRound(
        uint256 tournamentId,
        uint256 roundId,
        address attacker,
        address target,
        uint256 wager,
        uint256 sourceColonyId,
        uint256 targetColonyId
    ) external view returns (bool);

    function settleConflictGroup(
        uint256 roundId,
        address winner,
        address[] calldata participants,
        uint256[] calldata paymentColonyIds,
        uint256 winnerColonyId,
        uint256 groupStake
    ) external returns (uint256 totalTransferred);

    function applyBuildAction(address player, uint256 roundId) external;

    function getTablePlayers(uint256 tableId)
        external
        view
        returns (address[] memory);

    function getActionAttackPower(address player, uint256 colonyId) external view returns (uint256);
    function getActionDefensePower(address player, uint256 colonyId) external view returns (uint256);
}

/**
 * @title BattleManager
 * @notice Commit–reveal battle system with time-windowed rounds
 */
contract BattleManager is ReentrancyGuard {
    // =========================
    // CONFIG
    // =========================

    uint256 public constant COMMIT_DURATION = 4 hours;
    uint256 public constant REVEAL_DURATION = 2 hours;
    uint256 public constant BASE_SCORE = 100;
    uint256 public constant RANDOM_SCORE_RANGE = 100;
    uint256 public constant DEFEND_BONUS = 25;
    uint256 public constant BUILD_VULNERABILITY_BONUS = 50;
    uint256 public constant MAX_MILITARY_BONUS = 20;

    // =========================
    // ENUMS
    // =========================

    struct RevealData {
        address player;
        GameTypes.RoundPlan plan;
        bytes32 salt;
        bytes signature;
    }

    enum Phase {
        Commit,
        Reveal,
        Resolve
    }

    // =========================
    // STRUCTS
    // =========================

    struct RoundData {
        uint256 commitEnd;
        uint256 revealEnd;
        uint256 randomness; // VRF result
    }

    struct ConflictContext {
        uint256 roundId;
        uint256 tableId;
        bytes32 groupHash;
        address[] tablePlayers;
        GameTypes.Action[] actions;
        bool[] inGroup;
    }

    // =========================
    // STATE
    // =========================

    uint256 public currentRound;
    address public immutable tournamentManager;
    uint256 public immutable tournamentId;

    RoundData public currentRoundData;

    // active commit hash per user
    mapping(address => bytes32) public commits;
    mapping(address => uint256) public commitRound;

    // active revealed action per user
    mapping(address => GameTypes.Action) public revealed;
    mapping(address => uint256) public revealedRound;
    mapping(address => GameTypes.ColonyAllocation[]) private revealedAllocations;
    mapping(address => uint256) public successfulBuildRound;

    mapping(uint256 => uint256) public tableResolvedRound;
    mapping(uint256 => uint256) public roundRequiredTableCount;
    mapping(uint256 => uint256) public resolvedTableCount;

    // =========================
    // EVENTS
    // =========================

    event RoundStarted(uint256 roundId);
    event Committed(address indexed user, uint256 roundId);
    event Revealed(address indexed user, uint256 roundId);
    event AttackRevealed(
        uint256 indexed roundId,
        address indexed attacker,
        address indexed defender,
        uint256 sourceColonyId,
        uint256 targetColonyId,
        uint256 wager
    );
    event ConflictParticipant(
        uint256 indexed roundId,
        uint256 indexed tableId,
        bytes32 indexed groupHash,
        address player,
        GameTypes.ActionType actionType,
        address target,
        uint256 sourceColonyId,
        uint256 targetColonyId,
        uint256 wager,
        uint256 score
    );
    event ConflictWinner(
        uint256 indexed roundId,
        uint256 indexed tableId,
        bytes32 indexed groupHash,
        address winner,
        uint256 score
    );
    event ConflictGroupResolved(
        uint256 indexed roundId,
        uint256 indexed tableId,
        bytes32 indexed groupHash,
        uint256 participantCount,
        uint256 groupStake,
        uint256 totalGoldTransferred
    );
    event RoundRandomnessSet(uint256 indexed roundId, uint256 randomness);

    // =========================
    // MODIFIERS
    // =========================

    modifier inPhase(Phase p) {
        require(getPhase() == p, "wrong phase");
        _;
    }

    modifier onlyTournamentManager() {
        require(msg.sender == tournamentManager, "not tournament manager");
        _;
    }

    constructor(address _tournamentManager, uint256 _tournamentId) {
        require(_tournamentManager != address(0), "invalid tournament manager");
        tournamentManager = _tournamentManager;
        tournamentId = _tournamentId;
    }

    // =========================
    // ROUND CONTROL
    // =========================

    function startNextRound(uint256 requiredTableCount)
        external
        onlyTournamentManager
        returns (uint256 roundId)
    {
        require(requiredTableCount > 0, "no tables");
        currentRound++;
        roundRequiredTableCount[currentRound] = requiredTableCount;

        currentRoundData = RoundData({
            commitEnd: block.timestamp + COMMIT_DURATION,
            revealEnd: block.timestamp + COMMIT_DURATION + REVEAL_DURATION,
            randomness: 0
        });

        emit RoundStarted(currentRound);
        return currentRound;
    }

    function getPhase() public view returns (Phase) {
        if (block.timestamp < currentRoundData.commitEnd) {
            return Phase.Commit;
        } else if (block.timestamp < currentRoundData.revealEnd) {
            return Phase.Reveal;
        } else {
            return Phase.Resolve;
        }
    }

    function canEndRound() external view returns (bool) {
        return (
            currentRound != 0 &&
            getPhase() == Phase.Resolve &&
            currentRoundData.randomness != 0 &&
            resolvedTableCount[currentRound] ==
                roundRequiredTableCount[currentRound]
        );
    }

    function getRoundRandomness(uint256 roundId) external view returns (uint256) {
        if (roundId != currentRound) return 0;
        return currentRoundData.randomness;
    }

    function tableConflictsResolved(uint256 roundId, uint256 tableId)
        external
        view
        returns (bool)
    {
        return roundId == currentRound && tableResolvedRound[tableId] == roundId;
    }

    // =========================
    // COMMIT
    // =========================

    function commitPlan(bytes32 hash)
        external
        inPhase(Phase.Commit)
    {
        require(commitRound[msg.sender] != currentRound, "already committed");

        commits[msg.sender] = hash;
        commitRound[msg.sender] = currentRound;

        emit Committed(msg.sender, currentRound);
    }

    // =========================
    // REVEAL
    // =========================

    function revealPlan(GameTypes.RoundPlan calldata plan, bytes32 salt)
        external
        inPhase(Phase.Reveal)
    {
        bytes32 expected = computePlanCommitHash(
            msg.sender,
            plan,
            salt,
            currentRound
        );

        require(commitRound[msg.sender] == currentRound, "invalid reveal");
        require(expected == commits[msg.sender], "invalid reveal");
        _recordReveal(msg.sender, plan);
    }

    function _processReveal(RevealData calldata r) internal {
        bytes32 expected = computePlanCommitHash(
            r.player,
            r.plan,
            r.salt,
            currentRound
        );

        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(expected),
            r.signature
        );

        require(signer == r.player, "bad sig");

        require(commitRound[signer] == currentRound, "invalid reveal");
        require(expected == commits[signer], "invalid reveal");
        _recordReveal(signer, r.plan);
    }

    function batchReveal(RevealData[] calldata reveals)
        external
        inPhase(Phase.Reveal)
    {
        for (uint256 i = 0; i < reveals.length; i++) {
            _processReveal(reveals[i]);
        }
    }

    function setRoundRandomness(uint256 roundId, uint256 randomness)
        external
        onlyTournamentManager
    {
        require(roundId != 0 && roundId == currentRound, "invalid round");
        require(randomness != 0, "invalid randomness");
        require(currentRoundData.randomness == 0, "randomness already set");

        currentRoundData.randomness = randomness;
        emit RoundRandomnessSet(roundId, randomness);
    }

    // =========================
    // RESOLVE (LAZY)
    // =========================

    function resolveTableConflicts(uint256 tableId, uint256 roundId)
        public
        onlyTournamentManager
        inPhase(Phase.Resolve)
        nonReentrant
    {
        require(roundId == currentRound, "round mismatch");
        require(
            tableId > 0 && tableId <= roundRequiredTableCount[roundId],
            "invalid table"
        );
        require(tableResolvedRound[tableId] != roundId, "table resolved");
        require(
            resolvedTableCount[roundId] < roundRequiredTableCount[roundId],
            "all tables resolved"
        );

        uint256 randomness = currentRoundData.randomness;
        require(randomness != 0, "randomness not set");

        address[] memory players = IBattleTournamentManager(tournamentManager)
            .getTablePlayers(tableId);
        require(players.length > 0, "empty table");
        require(players.length <= 9, "table too large");

        GameTypes.Action[] memory actions = new GameTypes.Action[](players.length);
        for (uint256 i = 0; i < players.length; i++) {
            _applyRevealedPlan(roundId, players[i]);
            actions[i] = _getActionOrDefault(roundId, players[i]);
        }

        bool[] memory visited = new bool[](players.length);

        for (uint256 i = 0; i < players.length; i++) {
            if (visited[i]) continue;
            _resolveComponent(roundId, tableId, players, actions, visited, i);
        }

        _applyUncontestedBuilds(players, actions);
        tableResolvedRound[tableId] = roundId;
        resolvedTableCount[roundId]++;
    }

    // =========================
    // INTERNAL HELPERS
    // =========================

    function _recordReveal(address player, GameTypes.RoundPlan calldata plan) internal {
        require(revealedRound[player] != currentRound, "already revealed");
        require(
            IBattleTournamentManager(tournamentManager).validateRoundPlan(
                player,
                currentRound,
                plan
            ),
            "invalid plan"
        );

        GameTypes.Action calldata action = plan.action;

        if (action.actionType == GameTypes.ActionType.ATTACK) {
            _recordAttackReveal(player, action);
        } else if (action.actionType == GameTypes.ActionType.BUILD) {
            require(action.target == address(0), "build target");
            require(action.amount == 0, "build wager");
            require(action.sourceColonyId == 0, "build source colony");
            require(action.targetColonyId == 0, "build target colony");
        } else if (action.actionType == GameTypes.ActionType.DEFEND) {
            require(action.target == address(0), "defend target");
            require(action.amount == 0, "non-attack wager");
            require(action.sourceColonyId == 0, "defend source colony");
            require(action.targetColonyId == 0, "defend target colony");
        } else {
            revert("invalid action");
        }

        revealed[player] = action;
        delete revealedAllocations[player];
        for (uint256 i = 0; i < plan.allocations.length; i++) {
            revealedAllocations[player].push(plan.allocations[i]);
        }
        revealedRound[player] = currentRound;

        emit Revealed(player, currentRound);
    }

    function _recordAttackReveal(address attacker, GameTypes.Action calldata action)
        internal
    {
        require(
            IBattleTournamentManager(tournamentManager).isValidAttackForRound(
                tournamentId,
                currentRound,
                attacker,
                action.target,
                action.amount,
                action.sourceColonyId,
                action.targetColonyId
            ),
            "invalid attack"
        );

        emit AttackRevealed(
            currentRound,
            attacker,
            action.target,
            action.sourceColonyId,
            action.targetColonyId,
            action.amount
        );
    }

    function _applyRevealedPlan(uint256 roundId, address player) internal {
        if (revealedRound[player] != roundId) return;

        GameTypes.ColonyAllocation[] storage stored = revealedAllocations[player];
        GameTypes.ColonyAllocation[] memory allocations =
            new GameTypes.ColonyAllocation[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            allocations[i] = stored[i];
        }

        GameTypes.RoundPlan memory plan = GameTypes.RoundPlan({
            action: revealed[player],
            allocations: allocations
        });
        IBattleTournamentManager(tournamentManager).applyRoundPlan(
            player,
            roundId,
            plan
        );
    }

    function _resolveComponent(
        uint256 roundId,
        uint256 tableId,
        address[] memory players,
        GameTypes.Action[] memory actions,
        bool[] memory visited,
        uint256 start
    ) internal {
        uint256[] memory queue = new uint256[](players.length);
        bool[] memory inGroup = new bool[](players.length);
        uint256 cursor;
        uint256 count;

        queue[count++] = start;
        visited[start] = true;
        inGroup[start] = true;

        while (cursor < count) {
            uint256 current = queue[cursor++];
            for (uint256 i = 0; i < players.length; i++) {
                if (visited[i]) continue;
                if (
                    _hasAttackEdge(actions[current], players[i]) ||
                    _hasAttackEdge(actions[i], players[current])
                ) {
                    visited[i] = true;
                    inGroup[i] = true;
                    queue[count++] = i;
                }
            }
        }

        bool hasAttack;
        for (uint256 i = 0; i < players.length; i++) {
            if (
                inGroup[i] &&
                actions[i].actionType == GameTypes.ActionType.ATTACK
            ) {
                hasAttack = true;
                break;
            }
        }

        if (!hasAttack) return;

        ConflictContext memory ctx = ConflictContext({
            roundId: roundId,
            tableId: tableId,
            groupHash: _groupHash(roundId, tableId, players, inGroup),
            tablePlayers: players,
            actions: actions,
            inGroup: inGroup
        });

        _resolveConflictGroup(ctx, count);
    }

    function _resolveConflictGroup(
        ConflictContext memory ctx,
        uint256 participantCount
    ) internal {
        address[] memory participants = new address[](participantCount);
        uint256[] memory paymentColonyIds = new uint256[](participantCount);
        uint256[] memory scores = new uint256[](participantCount);
        (uint256[] memory militaryPowers, uint256 maxMilitaryPower) =
            _conflictMilitaryPowers(ctx);
        uint256 cursor;

        address winner;
        uint256 winnerScore;
        uint256 winnerColonyId;
        uint256 groupStake;

        for (uint256 i = 0; i < ctx.tablePlayers.length; i++) {
            if (!ctx.inGroup[i]) continue;

            uint256 score = _participantScore(
                ctx,
                i,
                militaryPowers[i],
                maxMilitaryPower
            );

            participants[cursor] = ctx.tablePlayers[i];
            paymentColonyIds[cursor] = _paymentColonyFor(ctx, i);
            if (
                ctx.actions[i].actionType == GameTypes.ActionType.ATTACK &&
                ctx.actions[i].amount > groupStake
            ) {
                groupStake = ctx.actions[i].amount;
            }
            scores[cursor] = score;

            if (
                winner == address(0) ||
                score > winnerScore ||
                (
                    score == winnerScore &&
                    _winsScoreTie(ctx, ctx.tablePlayers[i], winner)
                )
            ) {
                winner = ctx.tablePlayers[i];
                winnerScore = score;
                winnerColonyId = _paymentColonyFor(ctx, i);
            }

            cursor++;
        }

        uint256 transferred = IBattleTournamentManager(tournamentManager)
            .settleConflictGroup(
                ctx.roundId,
                winner,
                participants,
                paymentColonyIds,
                winnerColonyId,
                groupStake
            );

        _emitConflictParticipants(ctx, participants, scores);

        emit ConflictWinner(
            ctx.roundId,
            ctx.tableId,
            ctx.groupHash,
            winner,
            winnerScore
        );
        emit ConflictGroupResolved(
            ctx.roundId,
            ctx.tableId,
            ctx.groupHash,
            participants.length,
            groupStake,
            transferred
        );
    }

    function _emitConflictParticipants(
        ConflictContext memory ctx,
        address[] memory participants,
        uint256[] memory scores
    ) internal {
        for (uint256 i = 0; i < participants.length; i++) {
            GameTypes.Action memory action = _getActionOrDefault(
                ctx.roundId,
                participants[i]
            );
            emit ConflictParticipant(
                ctx.roundId,
                ctx.tableId,
                ctx.groupHash,
                participants[i],
                action.actionType,
                action.target,
                action.sourceColonyId,
                action.targetColonyId,
                action.actionType == GameTypes.ActionType.ATTACK
                    ? action.amount
                    : 0,
                scores[i]
            );
        }
    }

    function _conflictMilitaryPowers(ConflictContext memory ctx)
        internal
        view
        returns (uint256[] memory powers, uint256 maxPower)
    {
        powers = new uint256[](ctx.tablePlayers.length);
        for (uint256 i = 0; i < ctx.tablePlayers.length; i++) {
            if (!ctx.inGroup[i]) continue;
            uint256 power = _participantMilitaryPower(ctx, i);
            powers[i] = power;
            if (power > maxPower) maxPower = power;
        }
    }

    function _participantMilitaryPower(
        ConflictContext memory ctx,
        uint256 playerIndex
    ) internal view returns (uint256) {
        address player = ctx.tablePlayers[playerIndex];
        GameTypes.Action memory action = ctx.actions[playerIndex];
        uint256 militaryColonyId = action.sourceColonyId;
        if (
            action.actionType == GameTypes.ActionType.DEFEND ||
            action.actionType == GameTypes.ActionType.BUILD
        ) {
            uint256 incomingTargetColonyId = _incomingTargetColonyFor(ctx, player);
            if (incomingTargetColonyId != 0) {
                militaryColonyId = incomingTargetColonyId;
            }
        }

        if (action.actionType == GameTypes.ActionType.ATTACK) {
            return IBattleTournamentManager(tournamentManager).getActionAttackPower(
                player,
                militaryColonyId
            );
        }
        return IBattleTournamentManager(tournamentManager).getActionDefensePower(
            player,
            militaryColonyId
        );
    }

    function _participantScore(
        ConflictContext memory ctx,
        uint256 playerIndex,
        uint256 militaryPower,
        uint256 maxMilitaryPower
    )
        internal
        view
        returns (uint256)
    {
        address player = ctx.tablePlayers[playerIndex];
        GameTypes.Action memory action = ctx.actions[playerIndex];
        uint256 score = BASE_SCORE + (
            uint256(
                keccak256(
                    abi.encode(
                        currentRoundData.randomness,
                        ctx.roundId,
                        ctx.tableId,
                        ctx.groupHash,
                        player
                    )
                )
            ) % RANDOM_SCORE_RANGE
        );
        if (maxMilitaryPower > 0) {
            score += militaryPower * MAX_MILITARY_BONUS / maxMilitaryPower;
        }

        if (action.actionType == GameTypes.ActionType.ATTACK) {
            uint256 targetIndex = _indexOf(ctx.tablePlayers, action.target);
            if (targetIndex < ctx.tablePlayers.length) {
                if (
                    ctx.actions[targetIndex].actionType ==
                    GameTypes.ActionType.BUILD
                ) {
                    score += BUILD_VULNERABILITY_BONUS;
                }
            }
        } else if (action.actionType == GameTypes.ActionType.DEFEND) {
            if (_incomingAttackCount(
                player,
                ctx.tablePlayers,
                ctx.actions,
                ctx.inGroup
            ) > 0) {
                score += DEFEND_BONUS;
            }
        }

        return score;
    }

    function _incomingAttackCount(
        address player,
        address[] memory tablePlayers,
        GameTypes.Action[] memory actions,
        bool[] memory inGroup
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < tablePlayers.length; i++) {
            if (
                inGroup[i] &&
                actions[i].actionType == GameTypes.ActionType.ATTACK &&
                actions[i].target == player
            ) {
                count++;
            }
        }
    }

    function _applyUncontestedBuilds(
        address[] memory tablePlayers,
        GameTypes.Action[] memory actions
    ) internal {
        for (uint256 i = 0; i < tablePlayers.length; i++) {
            if (actions[i].actionType != GameTypes.ActionType.BUILD) continue;
            if (_hasIncomingAttack(tablePlayers[i], tablePlayers, actions)) continue;

            successfulBuildRound[tablePlayers[i]] = currentRound;
            IBattleTournamentManager(tournamentManager).applyBuildAction(
                tablePlayers[i],
                currentRound
            );
        }
    }

    function _hasIncomingAttack(
        address player,
        address[] memory tablePlayers,
        GameTypes.Action[] memory actions
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < tablePlayers.length; i++) {
            if (
                actions[i].actionType == GameTypes.ActionType.ATTACK &&
                actions[i].target == player
            ) {
                return true;
            }
        }

        return false;
    }

    function _hasAttackEdge(GameTypes.Action memory action, address target)
        internal
        pure
        returns (bool)
    {
        return
            action.actionType == GameTypes.ActionType.ATTACK &&
            action.target == target;
    }

    function _paymentColonyFor(ConflictContext memory ctx, uint256 playerIndex)
        internal
        pure
        returns (uint256)
    {
        GameTypes.Action memory action = ctx.actions[playerIndex];
        if (action.actionType == GameTypes.ActionType.ATTACK) {
            return action.sourceColonyId;
        }

        address player = ctx.tablePlayers[playerIndex];
        uint256 selectedColonyId = _incomingTargetColonyFor(ctx, player);
        if (selectedColonyId != 0) return selectedColonyId;

        return action.sourceColonyId;
    }

    function _incomingTargetColonyFor(ConflictContext memory ctx, address player)
        internal
        pure
        returns (uint256 selectedColonyId)
    {
        uint256 selectedWager;

        for (uint256 i = 0; i < ctx.tablePlayers.length; i++) {
            if (
                ctx.inGroup[i] &&
                ctx.actions[i].actionType == GameTypes.ActionType.ATTACK &&
                ctx.actions[i].target == player
            ) {
                uint256 attackWager = ctx.actions[i].amount;
                uint256 targetColonyId = ctx.actions[i].targetColonyId;
                if (
                    attackWager > selectedWager ||
                    (
                        attackWager == selectedWager &&
                        (
                            selectedColonyId == 0 ||
                            targetColonyId < selectedColonyId
                        )
                    )
                ) {
                    selectedWager = attackWager;
                    selectedColonyId = targetColonyId;
                }
            }
        }
    }

    function _indexOf(address[] memory players, address player)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == player) return i;
        }

        return players.length;
    }

    function _groupHash(
        uint256 roundId,
        uint256 tableId,
        address[] memory players,
        bool[] memory inGroup
    ) internal pure returns (bytes32 groupHash) {
        groupHash = keccak256(abi.encode(roundId, tableId));
        for (uint256 i = 0; i < players.length; i++) {
            if (inGroup[i]) {
                groupHash = keccak256(abi.encode(groupHash, players[i]));
            }
        }
    }

    function _winsScoreTie(
        ConflictContext memory ctx,
        address challenger,
        address incumbent
    ) internal view returns (bool) {
        return uint256(
            keccak256(
                abi.encode(
                    currentRoundData.randomness,
                    ctx.roundId,
                    ctx.tableId,
                    ctx.groupHash,
                    challenger,
                    incumbent
                )
            )
        ) % 2 == 1;
    }

    function _getActionOrDefault(uint256 roundId, address user)
        internal
        view
        returns (GameTypes.Action memory)
    {
        if (roundId == currentRound && revealedRound[user] == roundId) {
            return revealed[user];
        }

        // default fallback if not revealed
        return GameTypes.Action({
            actionType: GameTypes.ActionType.DEFEND,
            target: address(0),
            amount: 0,
            sourceColonyId: 0,
            targetColonyId: 0
        });
    }

    // =========================
    // HASH HELPER (FRONTEND)
    // =========================

    function computePlanCommitHash(
        address player,
        GameTypes.RoundPlan calldata plan,
        bytes32 salt,
        uint256 roundId
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                tournamentId,
                roundId,
                player,
                plan,
                salt,
                block.chainid,
                address(this)
            )
        );
    }
}

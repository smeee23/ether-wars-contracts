// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IBattleTournamentManager {
    function isValidAttackForRound(
        uint256 tournamentId,
        uint256 roundId,
        address attacker,
        address target,
        uint256 wager
    ) external view returns (bool);

    function settleBattle(
        address attacker,
        address defender,
        uint256 wager,
        bool attackerWon
    ) external returns (uint256 transferred);

    function settleConflictGroup(
        uint256 roundId,
        address winner,
        address[] calldata participants,
        uint256 groupStake
    ) external returns (uint256 totalTransferred);

    function applyBuildAction(address player) external;

    function getRoundTablePlayers(uint256 roundId, uint256 tableId)
        external
        view
        returns (address[] memory);

    function getRoundTableOf(uint256 roundId, address player)
        external
        view
        returns (uint256);

    function getPlayerArmy(address player) external view returns (uint256);
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
    uint256 public constant ATTACK_VS_BUILD_BONUS = 25;
    uint256 public constant ATTACK_VS_DEFEND_PENALTY = 15;
    uint256 public constant DEFEND_BONUS = 20;
    uint256 public constant ARMY_SCORE_DIVISOR = 10;

    // =========================
    // ENUMS
    // =========================

    struct RevealData {
        address player;
        Action action;
        bytes32 salt;
        bytes signature;
    }

    enum Phase {
        Commit,
        Reveal,
        Resolve
    }

    enum ActionType {
        NONE,
        ATTACK,
        DEFEND,
        BUILD
    }

    // =========================
    // STRUCTS
    // =========================

    struct Action {
        ActionType actionType;
        address target;
        uint256 amount; // gold wager for ATTACK; must be zero otherwise
    }

    struct BestAttack {
        address attacker;
        uint256 wager;
        bool resolved;
    }

    struct Round {
        uint256 commitEnd;
        uint256 revealEnd;
        Phase phase;
        uint256 randomness; // VRF result
    }

    struct ConflictContext {
        uint256 roundId;
        uint256 tableId;
        bytes32 groupHash;
        address[] tablePlayers;
        Action[] actions;
        bool[] inGroup;
    }

    // =========================
    // STATE
    // =========================

    uint256 public currentRound;
    address public immutable tournamentManager;
    uint256 public immutable tournamentId;

    mapping(uint256 => Round) public rounds;

    // commit hash per user per round
    mapping(uint256 => mapping(address => bytes32)) public commits;

    // revealed actions
    mapping(uint256 => mapping(address => Action)) public revealed;

    // track if revealed
    mapping(uint256 => mapping(address => bool)) public hasRevealed;
    mapping(uint256 => mapping(address => bool)) public hasAttacked;
    // Deprecated: grouped conflict resolution keeps every valid attack instead
    // of pruning to one highest-wager attack per defender.
    mapping(uint256 => mapping(address => BestAttack)) public bestAttackByDefender;
    mapping(uint256 => mapping(uint256 => bool)) public tableConflictsResolved;

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
        uint256 wager
    );
    // Deprecated: grouped conflicts no longer outbid lower-wager attackers.
    event AttackOutbid(
        uint256 indexed roundId,
        address indexed defender,
        address indexed outbidAttacker,
        address newLeader,
        uint256 outbidWager,
        uint256 newLeaderWager
    );
    // Deprecated: resolveBattle now resolves the attacker's whole round table.
    event BattleResolved(
        uint256 indexed roundId,
        address indexed attacker,
        address indexed defender,
        bool attackerWon,
        uint256 attackerWager,
        uint256 attackerWinChance,
        uint256 goldTransferred
    );
    event ConflictParticipant(
        uint256 indexed roundId,
        uint256 indexed tableId,
        bytes32 indexed groupHash,
        address player,
        ActionType actionType,
        address target,
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

    function startNextRound()
        external
        onlyTournamentManager
        returns (uint256 roundId)
    {
        currentRound++;

        rounds[currentRound] = Round({
            commitEnd: block.timestamp + COMMIT_DURATION,
            revealEnd: block.timestamp + COMMIT_DURATION + REVEAL_DURATION,
            phase: Phase.Commit,
            randomness: 0
        });

        emit RoundStarted(currentRound);
        return currentRound;
    }

    function getPhase() public view returns (Phase) {
        Round memory r = rounds[currentRound];

        if (block.timestamp < r.commitEnd) {
            return Phase.Commit;
        } else if (block.timestamp < r.revealEnd) {
            return Phase.Reveal;
        } else {
            return Phase.Resolve;
        }
    }

    function canEndRound() external view returns (bool) {
        return currentRound != 0 && getPhase() == Phase.Resolve;
    }

    function getRoundRandomness(uint256 roundId) external view returns (uint256) {
        return rounds[roundId].randomness;
    }

    function didBuild(uint256 roundId, address player) external view returns (bool) {
        return (
            hasRevealed[roundId][player] &&
            revealed[roundId][player].actionType == ActionType.BUILD
        );
    }

    // =========================
    // COMMIT
    // =========================

    function commit(bytes32 hash)
        external
        inPhase(Phase.Commit)
    {
        require(commits[currentRound][msg.sender] == bytes32(0), "already committed");

        commits[currentRound][msg.sender] = hash;

        emit Committed(msg.sender, currentRound);
    }

    // =========================
    // REVEAL
    // =========================

    function reveal(
        Action calldata action,
        bytes32 salt
    )
        external
        inPhase(Phase.Reveal)
    {
        bytes32 expected = computeCommitHash(
            msg.sender,
            action.actionType,
            action.target,
            action.amount,
            salt,
            currentRound
        );

        require(expected == commits[currentRound][msg.sender], "invalid reveal");
        _recordReveal(msg.sender, action);
    }

    function _processReveal(RevealData calldata r) internal {
        bytes32 expected = computeCommitHash(
            r.player,
            r.action.actionType,
            r.action.target,
            r.action.amount,
            r.salt,
            currentRound
        );

        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(expected),
            r.signature
        );

        require(signer == r.player, "bad sig");

        require(expected == commits[currentRound][signer], "invalid reveal");
        _recordReveal(signer, r.action);
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
        require(roundId != 0 && roundId <= currentRound, "invalid round");
        require(randomness != 0, "invalid randomness");
        require(rounds[roundId].randomness == 0, "randomness already set");

        rounds[roundId].randomness = randomness;
        emit RoundRandomnessSet(roundId, randomness);
    }

    // =========================
    // RESOLVE (LAZY)
    // =========================

    /// @dev Deprecated compatibility shim. Resolves every conflict in the
    /// attacker's frozen round table instead of resolving one pairwise duel.
    function resolveBattle(address attacker, address defender)
        external
        onlyTournamentManager
        inPhase(Phase.Resolve)
    {
        Action memory atk = _getActionOrDefault(currentRound, attacker);
        require(atk.actionType == ActionType.ATTACK, "attacker not attacking");
        require(atk.target == defender, "wrong target");

        uint256 tableId = IBattleTournamentManager(tournamentManager)
            .getRoundTableOf(currentRound, attacker);
        require(tableId != 0, "missing round table");
        resolveTableConflicts(tableId, currentRound);
    }

    function resolveTableConflicts(uint256 tableId, uint256 roundId)
        public
        onlyTournamentManager
        inPhase(Phase.Resolve)
        nonReentrant
    {
        require(roundId == currentRound, "round mismatch");
        require(!tableConflictsResolved[roundId][tableId], "table resolved");

        uint256 randomness = rounds[roundId].randomness;
        require(randomness != 0, "randomness not set");

        address[] memory players = IBattleTournamentManager(tournamentManager)
            .getRoundTablePlayers(roundId, tableId);
        require(players.length > 0, "empty table");
        require(players.length <= 9, "table too large");

        Action[] memory actions = new Action[](players.length);
        for (uint256 i = 0; i < players.length; i++) {
            actions[i] = _getActionOrDefault(roundId, players[i]);
        }

        bool[] memory visited = new bool[](players.length);
        tableConflictsResolved[roundId][tableId] = true;

        for (uint256 i = 0; i < players.length; i++) {
            if (visited[i]) continue;
            _resolveComponent(roundId, tableId, players, actions, visited, i);
        }
    }

    // =========================
    // INTERNAL HELPERS
    // =========================

    function _recordReveal(address player, Action calldata action) internal {
        require(!hasRevealed[currentRound][player], "already revealed");

        if (action.actionType == ActionType.ATTACK) {
            _recordAttackReveal(player, action);
        } else if (action.actionType == ActionType.BUILD) {
            require(action.target == address(0), "build target");
            require(action.amount == 0, "build wager");
            IBattleTournamentManager(tournamentManager).applyBuildAction(player);
        } else {
            require(action.target == address(0), "build target");
            require(action.amount == 0, "non-attack wager");
        }

        revealed[currentRound][player] = action;
        hasRevealed[currentRound][player] = true;

        emit Revealed(player, currentRound);
    }

    function _attackerWinChance(uint256 roundId, address defender)
        internal
        view
        returns (uint256)
    {
        Action memory defenderAction = _getActionOrDefault(roundId, defender);

        if (defenderAction.actionType == ActionType.BUILD) return 65;
        if (defenderAction.actionType == ActionType.DEFEND) return 35;
        if (defenderAction.actionType == ActionType.ATTACK) return 50;

        return 35;
    }

    function _recordAttackReveal(address attacker, Action calldata action)
        internal
    {
        require(!hasAttacked[currentRound][attacker], "already attacked");
        require(
            IBattleTournamentManager(tournamentManager).isValidAttackForRound(
                tournamentId,
                currentRound,
                attacker,
                action.target,
                action.amount
            ),
            "invalid attack"
        );

        hasAttacked[currentRound][attacker] = true;
        emit AttackRevealed(
            currentRound,
            attacker,
            action.target,
            action.amount
        );
    }

    function _winsTie(
        address challenger,
        address incumbent,
        address defender
    ) internal view returns (bool) {
        uint256 randomness = rounds[currentRound].randomness;
        bytes32 tieSeed;

        if (randomness != 0) {
            tieSeed = keccak256(
                abi.encode(randomness, currentRound, challenger, incumbent, defender)
            );
        } else {
            // Fallback is deterministic if VRF has not arrived by reveal time.
            tieSeed = keccak256(
                abi.encode(currentRound, challenger, incumbent, defender)
            );
        }

        return uint256(tieSeed) % 2 == 1;
    }

    function _resolveComponent(
        uint256 roundId,
        uint256 tableId,
        address[] memory players,
        Action[] memory actions,
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
            if (inGroup[i] && actions[i].actionType == ActionType.ATTACK) {
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
        uint256[] memory scores = new uint256[](participantCount);
        uint256 cursor;

        address winner;
        uint256 winnerScore;
        uint256 groupStake;

        for (uint256 i = 0; i < ctx.tablePlayers.length; i++) {
            if (!ctx.inGroup[i]) continue;

            uint256 score = _participantScore(ctx, i);

            participants[cursor] = ctx.tablePlayers[i];
            if (
                ctx.actions[i].actionType == ActionType.ATTACK &&
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
            }

            cursor++;
        }

        uint256 transferred = IBattleTournamentManager(tournamentManager)
            .settleConflictGroup(ctx.roundId, winner, participants, groupStake);

        for (uint256 i = 0; i < participants.length; i++) {
            Action memory action = _getActionOrDefault(ctx.roundId, participants[i]);
            emit ConflictParticipant(
                ctx.roundId,
                ctx.tableId,
                ctx.groupHash,
                participants[i],
                action.actionType,
                action.target,
                action.actionType == ActionType.ATTACK ? action.amount : 0,
                scores[i]
            );
        }

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

    function _participantScore(ConflictContext memory ctx, uint256 playerIndex)
        internal
        view
        returns (uint256)
    {
        address player = ctx.tablePlayers[playerIndex];
        Action memory action = ctx.actions[playerIndex];
        uint256 score = BASE_SCORE + (
            uint256(
                keccak256(
                    abi.encode(
                        rounds[ctx.roundId].randomness,
                        ctx.roundId,
                        ctx.tableId,
                        ctx.groupHash,
                        player
                    )
                )
            ) % RANDOM_SCORE_RANGE
        );
        uint256 army = IBattleTournamentManager(tournamentManager).getPlayerArmy(
            player
        );
        score += army / ARMY_SCORE_DIVISOR;

        if (action.actionType == ActionType.ATTACK) {
            score += action.amount;
            uint256 targetIndex = _indexOf(ctx.tablePlayers, action.target);
            if (targetIndex < ctx.tablePlayers.length) {
                if (ctx.actions[targetIndex].actionType == ActionType.BUILD) {
                    score += ATTACK_VS_BUILD_BONUS;
                } else if (ctx.actions[targetIndex].actionType == ActionType.DEFEND) {
                    score -= ATTACK_VS_DEFEND_PENALTY;
                }
            }
        } else if (action.actionType == ActionType.DEFEND) {
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
        Action[] memory actions,
        bool[] memory inGroup
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < tablePlayers.length; i++) {
            if (
                inGroup[i] &&
                actions[i].actionType == ActionType.ATTACK &&
                actions[i].target == player
            ) {
                count++;
            }
        }
    }

    function _hasAttackEdge(Action memory action, address target)
        internal
        pure
        returns (bool)
    {
        return action.actionType == ActionType.ATTACK && action.target == target;
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
                    rounds[ctx.roundId].randomness,
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
        returns (Action memory)
    {
        if (hasRevealed[roundId][user]) {
            return revealed[roundId][user];
        }

        // default fallback if not revealed
        return Action({
            actionType: ActionType.DEFEND,
            target: address(0),
            amount: 0
        });
    }

    // =========================
    // HASH HELPER (FRONTEND)
    // =========================

    function computeCommitHash(
        address player,
        ActionType actionType,
        address target,
        uint256 wager,
        bytes32 salt,
        uint256 roundId
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                tournamentId,
                roundId,
                player,
                actionType,
                target,
                wager,
                salt,
                block.chainid,
                address(this)
            )
        );
    }
}

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

    function applyBuildAction(address player) external;
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
    mapping(uint256 => mapping(address => BestAttack)) public bestAttackByDefender;

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
    event AttackOutbid(
        uint256 indexed roundId,
        address indexed defender,
        address indexed outbidAttacker,
        address newLeader,
        uint256 outbidWager,
        uint256 newLeaderWager
    );
    event BattleResolved(
        uint256 indexed roundId,
        address indexed attacker,
        address indexed defender,
        bool attackerWon,
        uint256 attackerWager,
        uint256 attackerWinChance,
        uint256 goldTransferred
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

    function resolveBattle(address attacker, address defender)
        external
        onlyTournamentManager
        inPhase(Phase.Resolve)
        nonReentrant
    {
        Action memory atk = _getActionOrDefault(attacker);
        BestAttack storage best = bestAttackByDefender[currentRound][defender];

        require(atk.actionType == ActionType.ATTACK, "attacker not attacking");
        require(atk.target == defender, "wrong target");
        require(best.attacker == attacker, "attacker was outbid");
        require(!best.resolved, "battle already resolved");

        uint256 randomness = rounds[currentRound].randomness;
        require(randomness != 0, "randomness not set");
        uint256 rand = uint256(
            keccak256(
                abi.encode(randomness, attacker, defender, currentRound)
            )
        ) % 100;

        uint256 winChance = _attackerWinChance(attacker, defender);

        bool attackerWon = rand < winChance;

        best.resolved = true;
        uint256 transferred = IBattleTournamentManager(tournamentManager)
            .settleBattle(attacker, defender, atk.amount, attackerWon);

        emit BattleResolved(
            currentRound,
            attacker,
            defender,
            attackerWon,
            atk.amount,
            winChance,
            transferred
        );
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

    function _attackerWinChance(address, address defender)
        internal
        view
        returns (uint256)
    {
        Action memory defenderAction = _getActionOrDefault(defender);

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

        BestAttack storage currentBest = bestAttackByDefender[currentRound][
            action.target
        ];

        if (currentBest.attacker == address(0)) {
            currentBest.attacker = attacker;
            currentBest.wager = action.amount;
            return;
        }

        if (
            action.amount > currentBest.wager ||
            (
                action.amount == currentBest.wager &&
                _winsTie(attacker, currentBest.attacker, action.target)
            )
        ) {
            address outbidAttacker = currentBest.attacker;
            uint256 outbidWager = currentBest.wager;

            currentBest.attacker = attacker;
            currentBest.wager = action.amount;

            emit AttackOutbid(
                currentRound,
                action.target,
                outbidAttacker,
                attacker,
                outbidWager,
                action.amount
            );
        } else {
            emit AttackOutbid(
                currentRound,
                action.target,
                attacker,
                currentBest.attacker,
                action.amount,
                currentBest.wager
            );
        }
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

    function _getActionOrDefault(address user)
        internal
        view
        returns (Action memory)
    {
        if (hasRevealed[currentRound][user]) {
            return revealed[currentRound][user];
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
        REINFORCE
    }

    // =========================
    // STRUCTS
    // =========================

    struct Action {
        ActionType actionType;
        address target;
        uint256 amount;
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

    mapping(uint256 => Round) public rounds;

    // commit hash per user per round
    mapping(uint256 => mapping(address => bytes32)) public commits;

    // revealed actions
    mapping(uint256 => mapping(address => Action)) public revealed;

    // track if revealed
    mapping(uint256 => mapping(address => bool)) public hasRevealed;

    // =========================
    // EVENTS
    // =========================

    event RoundStarted(uint256 roundId);
    event Committed(address indexed user, uint256 roundId);
    event Revealed(address indexed user, uint256 roundId);
    event BattleResolved(address attacker, address defender, bool attackerWon);

    // =========================
    // MODIFIERS
    // =========================

    modifier inPhase(Phase p) {
        require(getPhase() == p, "wrong phase");
        _;
    }

    // =========================
    // ROUND CONTROL
    // =========================

    function startNextRound() external {
        currentRound++;

        rounds[currentRound] = Round({
            commitEnd: block.timestamp + COMMIT_DURATION,
            revealEnd: block.timestamp + COMMIT_DURATION + REVEAL_DURATION,
            phase: Phase.Commit,
            randomness: 0
        });

        emit RoundStarted(currentRound);
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
        bytes32 expected = keccak256(
            abi.encode(action.actionType, action.target, action.amount, salt, currentRound)
        );

        require(expected == commits[currentRound][msg.sender], "invalid reveal");
        require(!hasRevealed[currentRound][msg.sender], "already revealed");

        revealed[currentRound][msg.sender] = action;
        hasRevealed[currentRound][msg.sender] = true;

        emit Revealed(msg.sender, currentRound);
    }

    function _processReveal(RevealData calldata r) internal {
        bytes32 expected = keccak256(
            abi.encode(
                r.action.actionType,
                r.action.target,
                r.action.amount,
                r.salt,
                currentRound
            )
        );

        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(digest),
            r.signature
        );

        require(signer == r.player, "bad sig");

        require(expected == commits[currentRound][signer], "invalid reveal");
        require(!hasRevealed[currentRound][signer], "already revealed");

        revealed[currentRound][signer] = r.action;
        hasRevealed[currentRound][signer] = true;

        emit Revealed(signer, currentRound);
    }

    function batchReveal(RevealData[] calldata reveals)
        external
        inPhase(Phase.Reveal)
    {
        for (uint256 i = 0; i < reveals.length; i++) {
            _processReveal(reveals[i]);
        }
    }

    // =========================
    // RESOLVE (LAZY)
    // =========================

    function resolveBattle(address attacker, address defender)
        external
        inPhase(Phase.Resolve)
        nonReentrant
    {
        Action memory atk = _getActionOrDefault(attacker);
        Action memory def = _getActionOrDefault(defender);

        require(atk.actionType == ActionType.ATTACK, "attacker not attacking");
        require(atk.target == defender, "wrong target");

        // simple power calc (replace with your LandLord reads)
        uint256 attackPower = atk.amount;
        uint256 defensePower = def.amount;

        // randomness fallback (pseudo if VRF not used)
        uint256 rand = uint256(
            keccak256(
                abi.encode(block.timestamp, attacker, defender)
            )
        ) % 100;

        bool attackerWon = (attackPower * (100 + rand)) >
            (defensePower * (100 + (100 - rand)));

        // TODO: call LandLord / GridManager hooks here
        // e.g.
        // IGridManager.applyBattle(attacker, defender, attackerWon);

        emit BattleResolved(attacker, defender, attackerWon);
    }

    // =========================
    // INTERNAL HELPERS
    // =========================

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
        ActionType actionType,
        address target,
        uint256 amount,
        bytes32 salt,
        uint256 roundId
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encode(actionType, target, amount, salt, roundId)
        );
    }
}
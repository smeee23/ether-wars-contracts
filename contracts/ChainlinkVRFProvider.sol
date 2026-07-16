// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IVRFCoordinatorV2} from "./interfaces/link/IVRFCoordinatorV2.sol";

interface ITournamentRandomnessReceiver {
    function receiveRandomness(uint256 requestId, uint256 randomness) external;
}

/**
 * @title ChainlinkVRFProvider
 * @notice Thin Chainlink VRF v2 adapter for tournament battle rounds.
 * @dev TournamentManager requests randomness and receives the fulfilled random
 *      word. BattleManager should only consume randomness forwarded by the
 *      TournamentManager.
 */
contract ChainlinkVRFProvider {
    error UnknownRequest(uint256 requestId);
    error MissingRandomWord();
    error RequestAlreadyForwarded(uint256 requestId);
    address public immutable tournamentManager;
    address public immutable coordinator;
    bytes32 public immutable keyHash;
    uint64 public immutable subscriptionId;
    uint16 public immutable requestConfirmations;
    uint32 public immutable callbackGasLimit;

    mapping(uint256 => uint256) public roundByRequestId;
    mapping(uint256 => bool) public requestForwarded;

    event RandomnessRequested(uint256 indexed roundId, uint256 indexed requestId);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomness);

    modifier onlyTournamentManager() {
        require(msg.sender == tournamentManager, "not tournament manager");
        _;
    }

    modifier onlyCoordinator() {
        require(msg.sender == coordinator, "not coordinator");
        _;
    }

    constructor(
        address _tournamentManager,
        address _coordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit
    ) {
        require(_tournamentManager != address(0), "invalid tournament manager");
        require(_coordinator != address(0), "invalid coordinator");
        require(_requestConfirmations > 0, "invalid confirmations");
        require(_callbackGasLimit > 0, "invalid callback gas");

        tournamentManager = _tournamentManager;
        coordinator = _coordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
    }

    function requestRandomness(uint256 roundId)
        external
        onlyTournamentManager
        returns (uint256 requestId)
    {
        require(roundId != 0, "invalid round");

        requestId = IVRFCoordinatorV2(coordinator).requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );

        roundByRequestId[requestId] = roundId;
        emit RandomnessRequested(roundId, requestId);
    }

    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external onlyCoordinator {
        if (roundByRequestId[requestId] == 0) revert UnknownRequest(requestId);
        if (randomWords.length == 0) revert MissingRandomWord();
        if (requestForwarded[requestId]) {
            revert RequestAlreadyForwarded(requestId);
        }

        uint256 randomness = randomWords[0];
        ITournamentRandomnessReceiver(tournamentManager).receiveRandomness(
            requestId,
            randomness
        );

        requestForwarded[requestId] = true;
        emit RandomnessFulfilled(requestId, randomness);
    }
}

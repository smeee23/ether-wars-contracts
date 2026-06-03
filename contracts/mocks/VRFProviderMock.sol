// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITournamentRandomnessReceiver {
    function receiveRandomness(uint256 requestId, uint256 randomness) external;
}

contract VRFProviderMock {
    address public immutable tournamentManager;
    uint256 public nextRequestId = 1;
    mapping(uint256 => uint256) public requestRound;

    constructor(address _tournamentManager) {
        tournamentManager = _tournamentManager;
    }

    function requestRandomness(uint256 roundId) external returns (uint256 requestId) {
        require(msg.sender == tournamentManager, "not manager");
        requestId = nextRequestId++;
        requestRound[requestId] = roundId;
    }

    function fulfill(uint256 requestId, uint256 randomness) external {
        require(requestRound[requestId] != 0, "unknown request");
        ITournamentRandomnessReceiver(tournamentManager).receiveRandomness(
            requestId,
            randomness
        );
    }
}

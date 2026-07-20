// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IResourceLottery {
    function calculatePenalty(
        address tournament,
        uint256 roundId,
        uint256 tableId,
        uint256 randomness
    )
        external
        view
        returns (uint256 resource, uint256 colonyId, uint256 penaltyAmount);
}

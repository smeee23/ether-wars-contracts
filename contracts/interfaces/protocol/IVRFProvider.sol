// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IVRFProvider {
    function requestRandomness(uint256 roundId) external returns (uint256 requestId);
}

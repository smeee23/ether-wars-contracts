// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IValidatorOracle {
    function getStatusAndAddrResponse(string memory _index) external returns (bytes32);
    function withdrawLink() external;
}
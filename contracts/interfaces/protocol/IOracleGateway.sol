// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IOracleGateway {
    function setReserve(address _reserve) external;
    function callOracle(string memory _index) external;
}
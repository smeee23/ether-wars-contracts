// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IFunctionsConsumer {
    function executeRequest(
        string calldata source,
        bytes calldata secrets,
        string[] calldata args,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external returns (bytes32);

    function updateOracleAddress(address oracle) external;

    function addSimulatedRequestId(address oracleAddress, bytes32 requestId) external;

    function setReserve(address _reserve) external;
}
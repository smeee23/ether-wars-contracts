// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IChainlinkClient {
  function setChainlinkToken(address _link) external;
  function setChainlinkOracle(address _oracle) external;
  function setChainlinkJobId(bytes32 _jobId) external;
  function setChainlinkFee(uint256 _fee) external;
  function setPublicChainlinkToken() external;
  function withdrawLink() external;
  function transferLINK(address _recipient, uint256 _amount) external returns (bool);
  function checkChainlinkFulfillment(bytes32 _requestId) external returns (bool);
  function cancelChainlinkRequest(bytes32 _requestId) external;
  function cancelChainlinkRequest(bytes32 _requestId, uint256 _callbackGasLimit, bytes4 _callbackFunctionId) external;
  function chainlinkRequest(
    bytes32 _id,
    address _callbackAddress,
    bytes4 _callbackFunction,
    address _payableContract,
    uint256 _wei,
    bytes memory _params
  ) external returns (bytes32 requestId);
  function requestOracleData(
    bytes32 _specId,
    address _callbackAddress,
    bytes4 _callbackFunction,
    uint256 _payment,
    bytes memory _params
  ) external returns (bytes32 requestId);
  function requestOracleDataAndSendEther(
    bytes32 _specId,
    address _callbackAddress,
    bytes4 _callbackFunction,
    address payable _payableContract,
    uint256 _payment,
    bytes memory _params
  ) external returns (bytes32 requestId);
  function requestOracleDataFrom(
    address _oracle,
    bytes32 _specId,
    address _callbackAddress,
    bytes4 _callbackFunction,
    uint256 _payment,
    bytes memory _params
  ) external returns (bytes32 requestId);
}

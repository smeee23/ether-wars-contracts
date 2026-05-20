// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITestToken {
  function mint(address _to, uint256 _amount) external;
  function burn(address _account, uint256 _amount) external;
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) external returns (bool);
}
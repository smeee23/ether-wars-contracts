// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IYieldAdapter {
    function depositETH() external payable returns (uint256 shares);
    function withdrawETH(address to, uint256 amount) external returns (uint256 withdrawn);
    function totalAssets() external view returns (uint256);
    function principalToken() external view returns (address);
    function yieldSourceName() external view returns (string memory);
}

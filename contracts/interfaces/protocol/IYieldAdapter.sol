// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IYieldAdapter {
    function depositETH() external payable returns (uint256 assetsReceived);
    function depositAsset(address from, uint256 amount) external returns (uint256 assetsReceived);
    function withdrawAsset(address to, uint256 amount) external returns (uint256 assetsTransferred);
    function totalAssets() external view returns (uint256);
    function principalAsset() external view returns (address);
    function yieldSourceName() external view returns (string memory);
}

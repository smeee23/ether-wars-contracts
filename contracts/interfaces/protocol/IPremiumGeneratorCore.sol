// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPremiumGeneratorCore {
    
    function _deposit(address _poolAddr) external payable;
    function _withdraw(address _poolAddr, address _aTokenAddress) external;
    function _withdrawInterest(address _poolAddr, address _aTokenAddress, uint _requested) external returns(uint256);
    function setPremiumDeposit(uint _premiumDeposit) external;
    function _getUnclaimedInterest(address _aTokenAddress) external view returns (uint256);
    function getClaimedInterest() external view returns (uint256);
    function _getATokenBalance(address _aTokenAddress) external view returns (uint256);
    function isBeneficiary(address beneficiary) external view returns(bool);
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPremiumGeneratorAaveV3 {

    function deposit() external payable;
    function withdraw() external;
    function withdrawInterest(uint _requested) external returns(uint256);
    function getLendingPoolAddress() external view returns(address poolAddr);
    function getATokenAddress() external view returns(address aTokenAddress);
    function getUnclaimedInterest() external view returns (uint256);
    function getATokenBalance() external view returns (uint256);
    function getReserveNormalizedIncome() external view returns(uint256);
    function getAaveLiquidityIndex() external view returns(uint256 liquidityIndex);

    /**
    * @notice Returns asset specific pool information
    * @return reserve address of reserve
    * @return interestWithdrawn amount of interest withdrawn
    * @return deposits amount of ETH/WETH deposited in contract
    * @return premiumDeposit amount of ETH required for a deposit
    * @return liquidityIndex reserve's liquidity index
    * @return normalizedIncome reserve's normalized income
    * @return aTokenBalance Pool balance of aToken for the asset
    * @return claimedInterest interest that has been claimed (no longer in contract)
    * @return unclaimedInterest accrued interest that has not yet been claimed
    * @return totalDeposit total assets deposited in pool
    * @return aTokenAddress address of Aave's aToken for asset
    */
    function getPoolInfo() external view returns(address, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, address);
}
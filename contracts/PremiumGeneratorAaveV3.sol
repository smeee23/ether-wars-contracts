// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IPool} from './interfaces/aave/IPool.sol';
import { IPoolAddressesProvider} from './interfaces/aave/IPoolAddressesProvider.sol';
import { PremiumGeneratorCore } from './PremiumGeneratorCore.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PremiumGenerator contract
 * @author smeee
 * This is a contract for lossless insurance premiums using Aave v3

   Aave is used to generate interest for insurance applications

   Beneficiaries deposit tokens into PremiumGenerator which deposit
   them into Aave lending protocol

   The interest earned is directed to the reserve associated with
   the PremiumGenerator

   Beneficiaries can claim their funds (and terminate their policy) at any time.

   Functions deposit(), withdraw() and withdrawInterest() handle Aave interaction.
 **/

contract PremiumGeneratorAaveV3 is ReentrancyGuard, PremiumGeneratorCore {

    address immutable poolAddressesProviderAddr;

    /**
   * @dev Constructor.
   */
    constructor(
        address _poolAddressesProviderAddr,
        address _multiSig,
        address _wethGatewayAddr,
        uint _premiumDeposit
    ) PremiumGeneratorCore(
        _multiSig,
        _wethGatewayAddr,
        _premiumDeposit
    ){
        poolAddressesProviderAddr = _poolAddressesProviderAddr;
    }

    /**
     * @dev Allows a user to deposit funds for a specific validator index.
     * @param _validatorIndex The index of the validator.
     */
    function deposit(uint _validatorIndex) nonReentrant external payable{
        address poolAddr = getLendingPoolAddress();
        _deposit(poolAddr, _validatorIndex);
    }

    /**
     * @dev Allows a user to withdraw funds for a specific validator index.
     * @param _validatorIndex The index of the validator.
     */
    function withdraw(uint _validatorIndex) external nonReentrant {
        address aTokenAddress = getATokenAddress();
        address poolAddr = getLendingPoolAddress();
        _withdraw(poolAddr, aTokenAddress, _validatorIndex);
    }

    /**
     * @dev Allows the contract to withdraw interest in the form of
     * aTokens to the reserve.
     * @return The amount of interest claimed.
     */
    function withdrawInterest()external onlyReserve returns(uint256){
        address aTokenAddress = getATokenAddress();
        return _withdrawInterest(aTokenAddress);
    }


    /**
     * @dev Returns the address of the Aave lending pool.
     * @return poolAddr The address of the lending pool.
     */
    function getLendingPoolAddress() public view returns(address poolAddr){
        return IPoolAddressesProvider(poolAddressesProviderAddr).getPool();
    }

    /**
     * @dev Returns the address of the Aave aToken associated with the WETH reserve.
     * @return aTokenAddress The address of the aToken.
     */
    function getATokenAddress() public view returns(address aTokenAddress){
        address poolAddr = IPoolAddressesProvider(poolAddressesProviderAddr).getPool();
        return IPool(poolAddr).getReserveData(wethAddress).aTokenAddress;
    }

    /**
     * @dev Returns the amount of unclaimed interest for the contract from the specified aToken.
     * @return unclaimed The amount of unclaimed interest.
     */
    function getUnclaimedInterest() public view returns (uint256){
        address aTokenAddress = getATokenAddress();
        return _getUnclaimedInterest(aTokenAddress);
    }

    function getStats() public view returns (uint256){
        address aTokenAddress = getATokenAddress();
        return _getUnclaimedInterest(aTokenAddress);
    }

    /**
     * @dev Returns the balance of aToken held by the contract.
     * @return balance The balance of aToken.
     */
    function getATokenBalance() public view returns (uint256){
        address aTokenAddress = getATokenAddress();
        return _getATokenBalance(aTokenAddress);
    }

    /**
     * @dev Returns the normalized income of the reserve.
     * @return normIncome The normalized income of the reserve.
     */
    function getReserveNormalizedIncome() public view returns(uint256){
        address poolAddr = IPoolAddressesProvider(poolAddressesProviderAddr).getPool();
        return IPool(poolAddr).getReserveNormalizedIncome(wethAddress);
    }

    /**
     * @dev Returns the Aave liquidity index of the reserve.
     * @return liquidityIndex The Aave liquidity index of the reserve.
     */
    function getAaveLiquidityIndex() public view returns(uint256 liquidityIndex){
        address poolAddr = IPoolAddressesProvider(poolAddressesProviderAddr).getPool();
        liquidityIndex = IPool(poolAddr).getReserveData(wethAddress).liquidityIndex;
    }

    /**
    * @notice Returns asset specific pool information
    * @return reserve address of reserve
    * @return deposits amount of ETH/WETH deposited in contract
    * @return premiumDeposit amount of ETH required for a deposit
    * @return liquidityIndex reserve's liquidity index
    * @return normalizedIncome reserve's normalized income
    * @return aTokenBalance Pool balance of aToken for the asset
    * @return unclaimedInterest accrued interest that has not yet been claimed
    * @return aTokenAddress address of Aave's aToken for asset
    */
    function getPoolInfo() external view returns(address, uint256, uint256, uint256, uint256, uint256, uint256, address){
        return(reserve, deposits, premiumDeposit, getAaveLiquidityIndex(),
                getReserveNormalizedIncome(), getATokenBalance(),
                getUnclaimedInterest(), getATokenAddress());
    }
}
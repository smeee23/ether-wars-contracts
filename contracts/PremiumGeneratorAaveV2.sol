// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ILendingPool} from './interfaces/aave/ILendingPool.sol';
import { ILendingPoolAddressesProvider} from './interfaces/aave/ILendingPoolAddressesProvider.sol';
import { IProtocolDataProvider } from './interfaces/aave/IProtocolDataProvider.sol';
import { PremiumGeneratorCore } from './PremiumGeneratorCore.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PremiumGenerator contract
 * @author smeee
 * This is a contract for lossless insurance premiums using Aave v2

   Aave is used to generate interest for insurance applications

   Beneficiaries deposit tokens into PremiumGenerator which deposit
   them into Aave lending protocol

   The interest earned is directed to the reserve associated with
   the PremiumGenerator

   Beneficiaries can claim their funds (and terminate their policy) at any time.

   Functions deposit(), withdraw() and withdrawInterest() handle Aave interaction.
 **/

contract PremiumGeneratorAaveV2 is ReentrancyGuard, PremiumGeneratorCore{

    address immutable lendingPoolAddressesProviderAddr;
    address immutable dataProviderAddr;

    /**
   * @dev Constructor.
   */
    constructor (
        //address _premiumDeposit,
        address _lendingPoolAddressesProviderAddr,
        address _dataProviderAddr,
        //address _reserve,
        address _multiSig,
        address _wethGatewayAddr,
        uint _premiumDeposit
    )PremiumGeneratorCore(
        _multiSig,
        _wethGatewayAddr,
        _premiumDeposit
    ){
        lendingPoolAddressesProviderAddr = _lendingPoolAddressesProviderAddr;
        dataProviderAddr = _dataProviderAddr;
    }

    /**
     * @dev Legacy-compatible deposit entrypoint. The index is ignored by the
     * neutral tournament adapter.
     * @param _validatorIndex Ignored legacy validator index.
     */
    function deposit(uint _validatorIndex) external payable nonReentrant {
        _validatorIndex;
        address poolAddr = getLendingPoolAddress();
        _deposit(poolAddr, msg.sender);
    }

    function depositFor(address owner) external payable nonReentrant {
        address poolAddr = getLendingPoolAddress();
        _deposit(poolAddr, owner);
    }

    /**
     * @dev Legacy-compatible withdraw entrypoint. The index is ignored by the
     * neutral tournament adapter.
     * @param _validatorIndex Ignored legacy validator index.
     */
    function withdraw(uint _validatorIndex) external nonReentrant {
        _validatorIndex;
        address aTokenAddress = getATokenAddress();
        address poolAddr = getLendingPoolAddress();
        _withdraw(poolAddr, aTokenAddress, msg.sender, premiumDeposit, msg.sender);
    }

    function withdrawPrincipal(
        address owner,
        uint256 amount,
        address to
    ) external onlyController nonReentrant {
        address aTokenAddress = getATokenAddress();
        address poolAddr = getLendingPoolAddress();
        _withdraw(poolAddr, aTokenAddress, owner, amount, to);
    }

    /**
     * @dev Allows the contract to withdraw interest in the form of
     * aTokens to the reserve.
     * @return The amount of interest claimed.
     */
    function withdrawInterest()external onlyReserve returns(uint256){
        address aTokenAddress = getATokenAddress();
        return _withdrawInterest(aTokenAddress, controller);
    }

    function withdrawInterestTo(address to) external onlyController returns(uint256){
        address aTokenAddress = getATokenAddress();
        return _withdrawInterest(aTokenAddress, to);
    }

    /**
     * @dev Returns the address of the Aave lending pool.
     * @return poolAddr The address of the lending pool.
     */
    function getLendingPoolAddress() public view returns(address poolAddr){
        return ILendingPoolAddressesProvider(lendingPoolAddressesProviderAddr).getLendingPool();
    }

    /**
     * @dev Returns the address of the Aave aToken associated with the WETH reserve.
     * @return The address of the aToken.
     */
    function getATokenAddress() public view returns(address){
        (address aTokenAddress,,) = IProtocolDataProvider(dataProviderAddr).getReserveTokensAddresses(wethAddress);
        return aTokenAddress;
    }

    /**
     * @dev Returns the amount of unclaimed interest for the contract from the specified aToken.
     * @return unclaimed The amount of unclaimed interest.
     */
    function getUnclaimedInterest() public view returns (uint256){
        address aTokenAddress = getATokenAddress();
        return _getUnclaimedInterest(aTokenAddress);
    }

    /**
     * @dev Returns the balance of aToken held by the contract.
     * @return The balance of aToken.
     */
    function getATokenBalance() public view returns (uint256){
        address aTokenAddress = getATokenAddress();
        return _getATokenBalance(aTokenAddress);
    }

    /**
     * @dev Returns the normalized income of the reserve.
     * @return The normalized income of the reserve.
     */
    function getReserveNormalizedIncome() public view returns(uint256){
        address lendingPoolAddr = ILendingPoolAddressesProvider(lendingPoolAddressesProviderAddr).getLendingPool();
        return ILendingPool(lendingPoolAddr).getReserveNormalizedIncome(wethAddress);
    }

    /**
     * @dev Returns the Aave liquidity index of the reserve.
     * @return liquidityIndex The Aave liquidity index of the reserve.
     */
    function getAaveLiquidityIndex() public view returns(uint256 liquidityIndex){
        (,,,,,,,liquidityIndex,,) = IProtocolDataProvider(dataProviderAddr).getReserveData(wethAddress);
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

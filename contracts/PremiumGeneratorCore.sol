// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20} from './interfaces/other/IERC20.sol';
import { IWETHGateway} from './interfaces/aave/IWETHGateway.sol';
import { SafeERC20 } from './libraries/SafeERC20.sol';
import { IReserve} from './interfaces/protocol/IReserve.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PremiumGenerator contract
 * @author smeee
 * This is a contract for lossless insurance premiums using Aave v2 and v3

   This contract acts as the core layer of interaction with Aave and
   is inherited by both the v2 and v3 PremiumGenerator contracts.

 * @dev To be covered by a proxy contract
 * @dev deposits, withdraws, withdrawInterest controlled by the Reserve contract
 **/

contract PremiumGeneratorCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint public deposits;
    uint public premiumDeposit;

    address immutable wethGatewayAddr;
    address immutable wethAddress;
    address public reserve;
    address immutable public multiSig;


    /**
    * @dev msg.value must be equal to the premiumDeposit.
    **/
    modifier correctValue(){
        require(msg.value == premiumDeposit, "value sent must be equal to premium deposit");
        _;
    }

    /**
    * @dev Only Reserve can call functions marked by this modifier.
    **/
    modifier onlyReserve(){
        require(reserve == msg.sender, "not the owner");
        _;
    }

     /**
  * @dev Only MultiSig can call functions marked by this modifier.
  **/
  modifier onlyMultiSig(){
      require(multiSig == msg.sender, "not the owner");
      _;
  }

    /**
   * @dev Constructor.
   */
    constructor (
        address _multiSig,
        address _wethGatewayAddr,
        uint _premiumDeposit
    ){
        multiSig = _multiSig;
        premiumDeposit = _premiumDeposit;
        wethGatewayAddr = _wethGatewayAddr;
        wethAddress = IWETHGateway(wethGatewayAddr).getWETHAddress();
        //lendingPoolAddressesProviderAddr = _lendingPoolAddressesProviderAddr;
        //dataProviderAddr = _dataProviderAddr;
    }

    /**
     * @dev Internal function to deposit funds to the lending pool.
     * @param _poolAddr The address of the lending pool.
     * @param _validatorIndex The index of the validator.
     */
    function _deposit(address _poolAddr, uint _validatorIndex) internal correctValue{
        deposits += premiumDeposit;
        IWETHGateway(wethGatewayAddr).depositETH{value: msg.value}(_poolAddr, address(this), 0);
        IReserve(reserve).addBeneficiary(msg.sender, _validatorIndex);
    }

    /**
     * @dev Internal function to withdraw funds from the lending pool.
     * @param _poolAddr The address of the lending pool.
     * @param _aTokenAddress The address of the aToken.
     * @param _validatorIndex The index of the validator.
     */
    function _withdraw(address _poolAddr, address _aTokenAddress, uint _validatorIndex) internal {
        deposits -= premiumDeposit;
        IERC20(_aTokenAddress).safeApprove(wethGatewayAddr, 0);
        IERC20(_aTokenAddress).safeApprove(wethGatewayAddr, premiumDeposit);
        IWETHGateway(wethGatewayAddr).withdrawETH(_poolAddr, premiumDeposit, msg.sender);
        IReserve(reserve).withdrawBeneficiary(msg.sender, _validatorIndex);
    }

    /**
     * @dev Internal function to withdraw accumulated interest to the Reserve.
     * @param _aTokenAddress The address of the aToken.
     * @return interestEarned The amount of interest earned and withdrawn.
     */
    function _withdrawInterest(address _aTokenAddress) internal returns(uint256){
        uint256 aTokenBalance = IERC20(_aTokenAddress).balanceOf(address(this));
        uint256 interestEarned = aTokenBalance - deposits;
        if(interestEarned > 0){
            IERC20(_aTokenAddress).safeTransfer(reserve, interestEarned);
        }
        return interestEarned;
    }

    /**
     * @dev Sets the reserve address.
     * @param _reserve The address of the reserve contract.
     * @dev Only the multi-signature wallet is allowed to call this function.
     * @dev This function can only be called once to set the reserve address.
     */
    function setReserve(address _reserve) external onlyMultiSig {
        require(reserve == address(0), "reserve already set");
        reserve = _reserve;
    }


    /**
     * @dev Returns the unclaimed interest for the given aToken address.
     * @param _aTokenAddress The address of the aToken contract.
     * @return The amount of unclaimed interest.
     */
    function _getUnclaimedInterest(address _aTokenAddress) internal view returns (uint256){
        uint256 aTokenBalance = IERC20(_aTokenAddress).balanceOf(address(this));
        if(aTokenBalance == 0) return 0;
        return aTokenBalance - deposits;
    }

    /**
     * @dev Returns the balance of aToken for the given aToken address.
     * @param _aTokenAddress The address of the aToken contract.
     * @return The balance of aToken.
     */
    function _getATokenBalance(address _aTokenAddress) public view returns (uint256){
        return IERC20(_aTokenAddress).balanceOf(address(this));
    }
}
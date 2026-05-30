// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20} from './interfaces/other/IERC20.sol';
import { IWETHGateway} from './interfaces/aave/IWETHGateway.sol';
import { SafeERC20 } from './libraries/SafeERC20.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PremiumGenerator contract
 * @author smeee
 * This is a neutral Aave ETH yield adapter shared by Aave v2 and v3
   generators.

   This contract acts as the core layer of interaction with Aave and
   is inherited by both the v2 and v3 PremiumGenerator contracts.

 * @dev The old SLI-specific beneficiary callbacks were removed. A controller
 *      such as TournamentManager should own game registration/accounting.
 **/

contract PremiumGeneratorCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint public deposits;
    uint public premiumDeposit;
    mapping(address => uint256) public principalOf;

    address immutable wethGatewayAddr;
    address immutable wethAddress;
    address public controller;
    address public reserve;
    address immutable public multiSig;


    /**
    * @dev msg.value must be equal to the configured deposit amount.
    **/
    modifier correctValue(){
        require(msg.value == premiumDeposit, "value sent must be equal to premium deposit");
        _;
    }

    /**
    * @dev Only the configured controller can call functions marked by this modifier.
    **/
    modifier onlyController(){
        require(controller == msg.sender, "not the controller");
        _;
    }

    modifier onlyReserve(){
        require(controller == msg.sender, "not the controller");
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

    function _deposit(address _poolAddr, address _owner) internal {
        require(msg.value > 0, "no value");
        deposits += msg.value;
        principalOf[_owner] += msg.value;
        IWETHGateway(wethGatewayAddr).depositETH{value: msg.value}(
            _poolAddr,
            address(this),
            0
        );
    }

    function _withdraw(
        address _poolAddr,
        address _aTokenAddress,
        address _owner,
        uint256 _amount,
        address _to
    ) internal {
        require(_amount > 0, "invalid amount");
        require(principalOf[_owner] >= _amount, "insufficient principal");

        principalOf[_owner] -= _amount;
        deposits -= _amount;
        IERC20(_aTokenAddress).safeApprove(wethGatewayAddr, 0);
        IERC20(_aTokenAddress).safeApprove(wethGatewayAddr, _amount);
        IWETHGateway(wethGatewayAddr).withdrawETH(_poolAddr, _amount, _to);
    }

    /**
     * @dev Internal function to withdraw accumulated interest to the Reserve.
     * @param _aTokenAddress The address of the aToken.
     * @return interestEarned The amount of interest earned and withdrawn.
     */
    function _withdrawInterest(address _aTokenAddress, address _to) internal returns(uint256){
        uint256 aTokenBalance = IERC20(_aTokenAddress).balanceOf(address(this));
        uint256 interestEarned = aTokenBalance - deposits;
        if(interestEarned > 0){
            IERC20(_aTokenAddress).safeTransfer(_to, interestEarned);
        }
        return interestEarned;
    }

    /**
     * @dev Sets the controller address.
     * @param _controller The address of the tournament manager or legacy reserve.
     * @dev Only the multi-signature wallet is allowed to call this function.
     * @dev This function can only be called once to set the controller address.
     */
    function setController(address _controller) public onlyMultiSig {
        require(controller == address(0), "controller already set");
        require(_controller != address(0), "invalid controller");
        controller = _controller;
        reserve = _controller;
    }

    function setReserve(address _reserve) external onlyMultiSig {
        setController(_reserve);
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

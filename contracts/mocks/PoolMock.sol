// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

import { IERC20} from '../interfaces/other/IERC20.sol';
import { ITestToken } from '../interfaces/test/ITestToken.sol';
import { DataTypes } from "../libraries/DataTypes.sol";

contract PoolMock {

  mapping(address => DataTypes.ReserveData) internal _reserves;

  address aWETHToken;
  address wETHToken;
  address[] aaveAcceptedTokens;
  address public sender;
  //uint256 constant INTEREST = 1000000000000000000;
  uint256 constant RESERVE_NORMALIZED_INCOME = 7755432354;

  function setTestTokens(address _wETHToken, address _aWETHToken) external {
    aaveAcceptedTokens.push(_wETHToken);

    wETHToken = _wETHToken;
    aWETHToken = _aWETHToken;

    _reserves[_wETHToken].liquidityIndex = 1234;
    _reserves[_wETHToken].currentLiquidityRate = 1478;
    _reserves[_wETHToken].variableBorrowIndex = 9087;
    _reserves[_wETHToken].currentVariableBorrowRate = 9087;
    _reserves[_wETHToken].currentStableBorrowRate = 9087;
    _reserves[_wETHToken].lastUpdateTimestamp = 9087;
    _reserves[_wETHToken].id = 9087;
    _reserves[_wETHToken].aTokenAddress = _aWETHToken;
    _reserves[_wETHToken].stableDebtTokenAddress = address(0);
    _reserves[_wETHToken].variableDebtTokenAddress = address(0);
    _reserves[_wETHToken].interestRateStrategyAddress = address(0);
    _reserves[_wETHToken].accruedToTreasury = 9087;
    _reserves[_wETHToken].unbacked = 9087;
    _reserves[_wETHToken].isolationModeTotalDebt = 9087;
  }
    /**
   * @dev Deposits an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
   * - E.g. User deposits 100 USDC and gets in return 100 aUSDC
   * @param asset The address of the underlying asset to deposit
   * @param amount The amount to be deposited
   * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
   *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
   *   is a different wallet
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   **/
    function deposit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external {
      require(asset != address(0x0), "asset cannot be burn address");
      require(referralCode == 0, "test referral code must be 0");
      ITestToken(aWETHToken).mint(onBehalfOf, amount);
  }

  function simulateInterest(
    uint256 amount,
    address onBehalfOf
  ) external {
    ITestToken(aWETHToken).mint(onBehalfOf, amount);
  }

    /**
   * @notice Withdraws an `amount` of underlying asset from the reserve, burning the equivalent aTokens owned
   * E.g. User has 100 aUSDC, calls withdraw() and receives 100 USDC, burning the 100 aUSDC
   * @param asset The address of the underlying asset to withdraw
   * @param amount The underlying amount to be withdrawn
   *   - Send the value type(uint256).max in order to withdraw the whole aToken balance
   * @param to The address that will receive the underlying, same as msg.sender if the user
   *   wants to receive it on his own wallet, or a different address if the beneficiary is a
   *   different wallet
   * @return The final amount withdrawn
   **/
  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) external returns (uint256){

    sender = msg.sender;

      require(asset != address(0x0), "asset cannot be burn address");
      ITestToken(asset).mint(to, amount);
      ITestToken(aWETHToken).burn(msg.sender, amount);
      return amount;
  }

  function getReservesList() external view returns (address[] memory){
    return aaveAcceptedTokens;
  }
  function getReserveData(address _asset) external view returns(DataTypes.ReserveData memory) {
    return _reserves[_asset];
  }

  function getReserveNormalizedIncome(address _asset) external pure returns(uint256) {
    require(_asset != address(0x0), "asset cannot be burn address");
    return RESERVE_NORMALIZED_INCOME;
  }
}

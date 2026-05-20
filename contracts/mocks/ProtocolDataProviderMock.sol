// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

contract ProtocolDataProviderMock {
  address aWETH;

  constructor(address _aWETH) {
    aWETH = _aWETH;
  }

  function getReserveData(address _asset) external view returns (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, uint256 liquidityRate, uint256 variableBorrowRate, uint256 stableBorrowRate, uint256 averageStableBorrowRate, uint256 liquidityIndex, uint256 variableBorrowIndex, uint40 lastUpdateTimestamp){
    _asset = address(this);
    availableLiquidity = 0;
    totalStableDebt =0;
    totalVariableDebt = 0;
    liquidityRate = 0;
    variableBorrowRate = 0;
    stableBorrowRate = 0;
    averageStableBorrowRate = 0;
    liquidityIndex = 1234;
    variableBorrowIndex = 0;
    lastUpdateTimestamp = 0;
}
function getReserveTokensAddresses(address _asset) external view returns(address, address, address) {
  _asset = address(this);
  return (aWETH, address(0), address(0));
}

}
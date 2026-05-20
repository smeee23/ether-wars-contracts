// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IReserve {

    event AddPool(address pool, string name, address receiver);
    event AddDeposit(address userAddr, address pool, address asset, uint256 amount);
    event WithdrawDeposit(address userAddr, address pool, address asset, uint256 amount);
    event Claim(address userAddr, address receiver, address pool, address asset, uint256 amount);

    function provideInsurance() external payable;
    function applyForCoverage(address _withdrawAddress, uint _validatorIndex) external;
    function addBeneficiary(address _withdrawAddress, uint _validatorIndex) external;
    function oracleResponse(uint _validatorIndex, uint8 _slashed, address _withdrawAddress, uint _loss) external;
    function withdrawBeneficiary(address _withdrawAddress, uint _validatorIndex)external;
    function harvestInterestAll() external;
    function harvestInterestAmount(uint _requested) external;
    function addGeneratorPool(address _pool) external;
    function removeGeneratorPool(uint8 index) external;
    function getMultiSig() external view returns(address);
    function getGeneratorPools() external view returns(address[] memory);
    function checkPool(address _pool) external view returns(bool);
    function getSlashingInsuranceETHAddress() external view returns(address);
    function getProtocolBalance() external view returns(uint);

}
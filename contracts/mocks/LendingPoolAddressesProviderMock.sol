// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

contract LendingPoolAddressesProviderMock {

    address poolAddress;

    constructor(address _poolAddress){
        poolAddress = _poolAddress;
    }

    function getLendingPool() external view returns (address) {
        return poolAddress;
    }

}
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

contract PoolAddressesProviderMock {

    address poolAddr;

     /**
   * @notice Returns the address of the Pool proxy.
   * @return The Pool proxy address
   **/
  function getPool()
    external
    view returns (address){
      return poolAddr;
  }

  /**
   * @notice Updates the implementation of the Pool, or creates a proxy
   * setting the new `pool` implementation when the function is called for the first time.
   * @param newPoolImpl The new Pool implementation
   **/
  function setPoolImpl(address newPoolImpl)
    external {
      poolAddr = newPoolImpl;
  }


}


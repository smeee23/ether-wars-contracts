// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract aTestToken is ERC20{
    constructor() ERC20 ("Test Token", "aTEST"){
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _account, uint256 _amount) external {
        _burn(_account, _amount);
    }
}
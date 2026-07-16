// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StETHMock is ERC20 {
    constructor() ERC20("Mock liquid staked Ether", "stETH") {}

    function submit(address) external payable returns (uint256) {
        _mint(msg.sender, msg.value);
        return msg.value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function sharesOf(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    function getSharesByPooledEth(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getPooledEthByShares(uint256 sharesAmount)
        external
        pure
        returns (uint256)
    {
        return sharesAmount;
    }
}

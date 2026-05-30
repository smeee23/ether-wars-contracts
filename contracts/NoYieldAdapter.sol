// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IYieldAdapter} from "./interfaces/protocol/IYieldAdapter.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title NoYieldAdapter
 * @notice Minimal ETH adapter for tournaments before the final yield source is chosen.
 * @dev Shares are 1:1 with ETH deposited. No yield is generated.
 */
contract NoYieldAdapter is IYieldAdapter, ReentrancyGuard {
    address public owner;
    address public controller;

    event Deposited(address indexed caller, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ControllerSet(address indexed controller);

    modifier onlyController() {
        require(msg.sender == controller, "not controller");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setController(address _controller) external onlyOwner {
        require(controller == address(0), "controller already set");
        require(_controller != address(0), "invalid controller");
        controller = _controller;
        emit ControllerSet(_controller);
    }

    function depositETH()
        external
        payable
        onlyController
        returns (uint256 shares)
    {
        require(msg.value > 0, "no value");
        emit Deposited(msg.sender, msg.value);
        return msg.value;
    }

    function withdrawETH(address to, uint256 amount)
        external
        onlyController
        nonReentrant
        returns (uint256 withdrawn)
    {
        require(to != address(0), "invalid recipient");
        require(amount > 0, "invalid amount");
        require(address(this).balance >= amount, "insufficient assets");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");

        emit Withdrawn(to, amount);
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    function principalToken() external pure returns (address) {
        return address(0);
    }

    function yieldSourceName() external pure returns (string memory) {
        return "NO_YIELD_ETH";
    }

    receive() external payable {}
}

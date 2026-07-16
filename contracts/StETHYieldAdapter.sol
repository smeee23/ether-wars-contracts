// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IStETH} from "./interfaces/lido/IStETH.sol";
import {IYieldAdapter} from "./interfaces/protocol/IYieldAdapter.sol";

contract StETHYieldAdapter is IYieldAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error NotController();
    error ControllerAlreadySet();
    error InvalidAddress();
    error InvalidAmount();
    error NoAssetsReceived();
    error InsufficientAssets();
    error DirectEthNotAccepted();

    address public immutable owner;
    IStETH public immutable stETH;
    address public immutable referral;
    address public controller;

    event ControllerSet(address indexed controller);
    event ETHDeposited(uint256 ethAmount, uint256 stEthReceived);
    event StETHDeposited(
        address indexed from,
        uint256 requestedAmount,
        uint256 stEthReceived
    );
    event StETHWithdrawn(
        address indexed to,
        uint256 requestedAmount,
        uint256 stEthTransferred
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(address stEthAddress, address referralAddress) {
        if (stEthAddress == address(0)) revert InvalidAddress();
        owner = msg.sender;
        stETH = IStETH(stEthAddress);
        referral = referralAddress;
    }

    function setController(address newController) external onlyOwner {
        if (controller != address(0)) revert ControllerAlreadySet();
        if (newController == address(0)) revert InvalidAddress();
        controller = newController;
        emit ControllerSet(newController);
    }

    function depositETH()
        external
        payable
        onlyController
        nonReentrant
        returns (uint256 assetsReceived)
    {
        if (msg.value == 0) revert InvalidAmount();
        uint256 balanceBefore = stETH.balanceOf(address(this));
        stETH.submit{value: msg.value}(referral);
        assetsReceived = stETH.balanceOf(address(this)) - balanceBefore;
        if (assetsReceived == 0) revert NoAssetsReceived();
        emit ETHDeposited(msg.value, assetsReceived);
    }

    function depositAsset(address from, uint256 amount)
        external
        onlyController
        nonReentrant
        returns (uint256 assetsReceived)
    {
        if (from == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        uint256 balanceBefore = stETH.balanceOf(address(this));
        IERC20(address(stETH)).safeTransferFrom(from, address(this), amount);
        assetsReceived = stETH.balanceOf(address(this)) - balanceBefore;
        if (assetsReceived == 0) revert NoAssetsReceived();
        emit StETHDeposited(from, amount, assetsReceived);
    }

    function withdrawAsset(address to, uint256 amount)
        external
        onlyController
        nonReentrant
        returns (uint256 assetsTransferred)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (stETH.balanceOf(address(this)) < amount) revert InsufficientAssets();

        uint256 recipientBalanceBefore = stETH.balanceOf(to);
        IERC20(address(stETH)).safeTransfer(to, amount);
        assetsTransferred = stETH.balanceOf(to) - recipientBalanceBefore;
        if (assetsTransferred == 0) revert NoAssetsReceived();
        emit StETHWithdrawn(to, amount, assetsTransferred);
    }

    function totalAssets() external view returns (uint256) {
        return stETH.balanceOf(address(this));
    }

    function principalAsset() external view returns (address) {
        return address(stETH);
    }

    function yieldSourceName() external pure returns (string memory) {
        return "LIDO_STETH";
    }

    receive() external payable {
        revert DirectEthNotAccepted();
    }
}

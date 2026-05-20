// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

import { IERC20} from '../interfaces/other/IERC20.sol';
import { ITestToken } from '../interfaces/test/ITestToken.sol';
import { IPool } from '../interfaces/aave/IPool.sol';

contract WethGatewayTest {

    address public wETH;
    address public aWETH;
    address public sender;
    mapping(address => uint256) depositors;

    event Test(address _to, uint256 amountToWithdraw);

    function setValues(address _wethAddress, address _aWethAddress) external {
        wETH = _wethAddress;
        aWETH = _aWethAddress;
    }

    function depositETH(
        address _pool,
        address _onBehalfOf,
        uint16 _referralCode
    ) external payable {
        IPool(_pool).deposit(address(wETH), msg.value, _onBehalfOf, _referralCode);
    }

    /**
    * @dev withdraws the WETH _reserves of msg.sender.
    * @param _pool address of the targeted underlying pool
    * @param _amount amount of aWETH to withdraw and receive native ETH
    * @param _to address of the user who will receive native ETH
    */
    function withdrawETH(
        address _pool,
        uint256 _amount,
        address _to
    ) external {

        sender = msg.sender;

        uint256 amountToWithdraw = _amount;
        ITestToken(aWETH).transferFrom(msg.sender, address(this), amountToWithdraw);
        IPool(_pool).withdraw(address(wETH), amountToWithdraw, address(this));
        ITestToken(wETH).burn(address(this), amountToWithdraw);
        _safeTransferETH(_to, amountToWithdraw);
        emit Test(_to, amountToWithdraw);
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function getWETHAddress() external view returns (address) {
        return address(wETH);
    }
}

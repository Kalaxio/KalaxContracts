// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "../interfaces/IETHHelper.sol";

contract ETHHelper {
    receive() external payable {
    }

    function withdrawETH(address _ethAddr, address _to, uint256 _amount) public {
        IETHHelper(_ethAddr).withdraw(_amount);
        (bool success,) = _to.call{value: _amount}(new bytes(0));
        require(success, 'ETHHelper: Withdraw ETH FAILED!!');
    }
}


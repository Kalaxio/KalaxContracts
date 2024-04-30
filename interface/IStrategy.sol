// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function asset() external view returns (IERC20);

    function beforeDeposit() external;

    function deposit(address, uint256) external;

    function depositNative(address) external payable;

    function withdraw(address, uint256) external;

    function withdrawNative(address, uint256) external payable;

    function balanceOf() external view returns (uint256);

    function earn() external view returns (uint256);

    function claim(address, address) external;
}

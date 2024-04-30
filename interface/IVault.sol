// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IVault {
    /// @notice Deposit assets to the vault
    /// @param _userAddr User address
    /// @param _amount Deposit amount
    function deposit(address _userAddr, uint256 _amount) external payable returns (uint256);

    /// @notice Withdraw assets from the vault
    /// @param _userAddr User Address
    /// @param _amount Withdrawal Amount
    /// @param _withdrawFee Withdrawal fee
    function withdraw(address _userAddr, uint256 _amount, uint256 _withdrawFee) external returns (uint256);

    /// @notice Return pool balance
    function balance() external view returns (uint256);
}

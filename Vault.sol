// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../comm/TransferHelper.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IStrategy.sol";
import "hardhat/console.sol";

/***
* @notice - This is the vault contract for the mainChef
**/
contract Vault is IVault, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // @dev Amount of underlying tokens provided by the user.
    struct UserInfo {
        uint256 amount;
    }

    // Vault strategy
    IStrategy public strategy;

    // Vault asset token
    IERC20 public assets; // WMNT

    // Total assets in the vault
    uint256 public totalAssets;

    // MainChef address
    address public mainChef;

    // WETH address
    address public WETH;  // MNT

    // User map
    mapping(address => UserInfo) public userInfoMap;

    // User list
    address[] public userList;

    // Total withdrawal fee
    uint256 public totalWithdrawFee;

    address public teamAddress;

    /// @notice Emitted when user deposit assets
    /// @param user Address that deposited
    /// @param amount Deposit amount from user
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when user withdraw assets
    /// @param user Address that withdraw
    /// @param amount Withdrawal amount by user
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Initialize the pool
    /// @param _assets The pool asset
    /// @param _weth The WETH address
    /// @param _mainChef The mainChef address
    function initialize(
        IERC20 _assets,
        address _weth,
        address _mainChef,
        address _addr
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        assets = _assets;
        WETH = _weth;
        mainChef = _mainChef;
        teamAddress = _addr;
    }

    /// @notice Set strategy
    /// @param _strategy Strategy address
    function setStrategy(IStrategy _strategy) external onlyOwner {
        strategy = _strategy;

        if (address(_strategy) != address(0)) {
            IERC20(assets).approve(address(_strategy), 0);
            IERC20(assets).approve(address(_strategy), type(uint256).max);

            transferETHToStrategy();
            transferERC20ToStrategy();
        }
    }

    /// @notice Set the mainChef
    /// @param _mainChef The mainChef address
    function setMainChef(address _mainChef) external onlyOwner {
        mainChef = _mainChef;
    }

    /// @notice Set WETH address
    /// @param _weth WETH address
    function setWETH(address _weth) external onlyOwner {
        WETH = _weth;
    }

    /// @notice Set the assets of the vault
    /// @param _assets The assets of the vault
    function setAssets(IERC20 _assets) external onlyOwner {
        assets = _assets;
    }

    /// @notice Set the team address
    /// @param _addr The team address
    function setTeamAddress(address _addr) external onlyOwner {
        require(_addr != address(0), "team address cannot be zero");
        teamAddress = _addr;
    }

    /// @notice Return vault pool balance only (strategy balance not included)
    function available() public view returns (uint256) {
        return assets.balanceOf(address(this));
    }

    /// @notice Return pool balance
    function balance() public view returns (uint256) {
        if (address(assets) == WETH) {
            if (address(strategy) != address(0)) {
                return address(this).balance + IStrategy(strategy).balanceOf();
            } else {
                return address(this).balance;
            }
        } else {
            if (address(strategy) != address(0)) {
                return assets.balanceOf(address(this)) + IStrategy(strategy).balanceOf();
            } else {
                return assets.balanceOf(address(this));
            }
        }
    }

    /// @notice Return users list that interact with the vault
    function getVaultUserList() public view returns (address[] memory) {
        return userList;
    }

    /// @notice Deposit assets to the vault
    /// @param _userAddr User address
    /// @param _amount Deposit amount
    function deposit(address _userAddr, uint256 _amount) public payable nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "user address cannot be zero address");

        if (address(strategy) != address(0)) {
            strategy.beforeDeposit();
        }

        uint256 _depositAmount;
        if (address(assets) == WETH) {
            console.log("msg.value = ", msg.value);
            _depositAmount = _depositETH(_userAddr, msg.value);
        } else {
            _depositAmount = _deposit(_userAddr, mainChef, _amount);
        }

        userList.push(_userAddr);
        emit Deposit(_userAddr, _depositAmount);

        return _depositAmount;
    }

    /// @dev Process ETH deposit
    function _depositETH(address _userAddr, uint256 _amount) private returns (uint256){
        UserInfo storage _userInfo = userInfoMap[_userAddr];

        _userInfo.amount = _userInfo.amount + _amount;
        totalAssets = totalAssets + _amount;

        // deposit to strategy if has
        if (address(strategy) != address(0)) {
            IStrategy(strategy).depositNative{value: _amount}(_userAddr);
        }

        return _amount;
    }

    /// @dev Process ERC20 deposit
    function _deposit(address _userAddr, address _mainChef, uint256 _amount) private returns (uint256){
        UserInfo storage _userInfo = userInfoMap[_userAddr];

        uint256 _poolBalance = balance();
        TransferHelper.safeTransferFrom(address(assets), _mainChef, address(this), _amount);

        uint256 _afterPoolBalance = balance();
        uint256 _depositAmount = _afterPoolBalance - _poolBalance;

        _userInfo.amount = _userInfo.amount + _depositAmount;
        totalAssets = totalAssets + _depositAmount;

        // deposit to strategy if has
        if (address(strategy) != address(0)) {
            IStrategy(strategy).deposit(address(this), _amount);
        }

        return _depositAmount;
    }

    /// @notice Withdraw assets from the vault
    /// @param _userAddr User Address
    /// @param _amount Withdrawal Amount
    /// @param _withdrawFee Withdrawal fee
    function withdraw(address _userAddr, uint256 _amount, uint256 _withdrawFee) public nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "User address cannot be zero address");

        UserInfo storage _userInfo = userInfoMap[_userAddr];
        require(_userInfo.amount >= _amount, "Insufficient balance");

        _userInfo.amount = _userInfo.amount - _amount;
        totalAssets = totalAssets - _amount;

        uint256 _fee = 0;
        if (_withdrawFee != 0) {
            require(teamAddress != address(0), "team address cannot be zero");
            _fee = _amount * _withdrawFee / 1000;
            totalWithdrawFee = totalWithdrawFee + _fee;
            _amount = _amount - _fee;
        }

        if (address(assets) == WETH) {
            // withdraw from strategy if has
            if (address(strategy) != address(0)) {
                IStrategy(strategy).withdrawNative(_userAddr, _amount);

                // Transfer the withdrawal fee to team
                if (_fee > 0) {
                    IStrategy(strategy).withdrawNative(teamAddress, _fee);
                }
            } else {
                TransferHelper.safeTransferETH(_userAddr, _amount);

                if (_fee > 0) {
                    TransferHelper.safeTransferETH(teamAddress, _fee);
                }
            }

            emit Withdraw(_userAddr, _amount);
            return _amount;
        } else {
            // withdraw from strategy if has
            if (address(strategy) != address(0)) {
                IStrategy(strategy).withdraw(_userAddr, _amount);

                // Transfer the withdrawal fee to team
                if (_fee > 0) {
                    IStrategy(strategy).withdraw(teamAddress, _fee);
                }
            } else {
                TransferHelper.safeTransfer(address(assets), _userAddr, _amount);

                if (_fee > 0) {
                    TransferHelper.safeTransfer(address(assets), teamAddress, _fee);
                }
            }

            emit Withdraw(_userAddr, _amount);
            return _amount;
        }
    }

    // @dev Transfer ETH to strategy
    function transferETHToStrategy() internal {
        if (address(this).balance > 0) {
            TransferHelper.safeTransferETH(address(strategy), address(this).balance);
        }
    }

    /// @dev Transfer ERC20 to strategy
    function transferERC20ToStrategy() internal {
        uint256 tokenBal = assets.balanceOf(address(this));
        if (tokenBal > 0) {
            assets.safeTransfer(address(strategy), tokenBal);
        }
    }

    receive() external payable {}
}

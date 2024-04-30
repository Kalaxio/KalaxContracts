// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IVault.sol";
import "../comm/ETHHelper.sol";
import "../comm/TransferHelper.sol";

/***
* @notice - This is the main multi-reward Farm contract
*/
contract KalaxMultiRewardV2Farm is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Bonus multiplier for farm
    uint256 public constant BONUS_MULTIPLIER = 1;

    // User info
    struct UserInfo {
        uint256 amount;
        mapping(IERC20 => uint256) rewardDebt;
    }

    // User's rewards
    struct UserRewardInfo {
        IERC20 token;
        uint256 debt;
    }

    // The user of pool info
    struct PoolUserInfo {
        uint256 pid;
        uint256 amount;
        UserRewardInfo[] rewards;
    }

    // Pool info
    struct PoolInfo {
        IERC20 assets;
        uint256 allocPoint;
        uint256 amount;
        uint256 withdrawFee;
        uint256 lastRewardTime;
        mapping(IERC20 => uint256) acctPerShare;
        IVault vault;
        RewardInfo[] rewards;
    }

    // Pool info for presentation
    struct PoolInfoPresentations {
        IERC20 assets;
        uint256 allocPoint;
        uint256 amount;
        uint256 withdrawFee;
        uint256 lastRewardTime;
        AcctPerShareInfo[] acctPerShare;
        IVault vault;
        RewardInfo[] rewards;
    }

    // Account per share
    struct AcctPerShareInfo {
        IERC20 token;
        uint256 acctPerShare;
    }

    // Reward info
    struct RewardInfo {
        IERC20 token;
        uint256 tokenPerBlock;
    }

    // Pool TVL
    struct PoolTvl {
        uint256 pid;
        IERC20 assets;
        uint256 tvl;
    }

    // User revenue info
    struct UserRevenueInfo {
        IERC20 token;
        uint256 totalUserRevenue;
    }

    // Farm start timestamp
    uint256 public startTimestamp;

    // Farm bonus end timestamp
    uint256 public bonusEndTime;

    // Wrapped ETH token address
    address public weth;

    // Total allocation points
    uint256 public totalAllocPoint;

    // Total user revenue
    mapping(IERC20 => uint256) public totalUserRevenue;

    // Reward tokens
    EnumerableSet.AddressSet private rewardTokenSet;

    // Pool info
    PoolInfo[] public poolInfoList;

    // Each user stake token
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // User list
    EnumerableSet.AddressSet private userAddrList;
    mapping(uint256 => EnumerableSet.AddressSet) private poolUserList;

    // ETH Transfer helper
    ETHHelper public wethHelper;

    // Paused status
    bool private _paused;

    /// @notice Emitted when user deposit assets
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    /// @notice Emitted when user withdraw assets
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    receive() external payable {}

    /// @notice Initialize the farm
    /// @param _weth The wrapped ETH token address
    function initialize(
        address _weth
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        weth = _weth;

        _paused = false;
        totalAllocPoint = 0;
        totalUserRevenue = 0;

        wethHelper = new ETHHelper();
    }

    /// @notice Set the token per block
    /// @param _pid The pool id
    /// @param _rewardIndex The reward token index
    /// @param _newTokenPerBlock Token yield per block
    function setPoolTokenPerBlock(uint256 _pid, uint256 _rewardIndex,
        uint256 _newTokenPerBlock) public onlyOwner {

        require(_pid >= 0, "Farm: invalid new pool pid");

        PoolInfo storage pool = poolInfoList[_pid];
        pool.rewards[_rewardIndex].tokenPerBlock = _newTokenPerBlock;

        // update the pool
        updateMassPools();
    }

    /// @notice Set the farm start timestamp
    /// @param _startTimestamp The farm start timestamp(seconds)
    function setStartTimestamp(uint256 _startTimestamp) public onlyOwner {
        require(startTimestamp == 0, "Farm: already started");
        startTimestamp = _startTimestamp;
    }

    /// @notice Set bonus end time
    /// @param _bonusEndTime the bonus end timestamp(seconds)
    function setBonusEndTime(uint256 _bonusEndTime) public onlyOwner {
        require(startTimestamp > 0, "Farm: not start");
        require(_bonusEndTime > startTimestamp, "Farm: end time must greater than start time");

        bonusEndTime = _bonusEndTime;
    }

    /// @notice Set wrapped ETH token address
    /// @param _weth The wrapped ETH
    function setWeth(address _weth) public onlyOwner {
        require(_weth != address(0), "Farm: invalid weth address");
        weth = _weth;
    }

    /// @notice Set total allocation points
    /// @param _totalAllocPoint The total allocation points
    function setTotalAllocPoint(uint256 _totalAllocPoint) public onlyOwner {
        totalAllocPoint = _totalAllocPoint;
    }

    /// @notice Get total user revenue
    function getTotalUserRevenue() public view returns (UserRevenueInfo[] memory) {

        address[] memory rewardTokenList = rewardTokenSet.values();

        UserRevenueInfo[] memory totalUserRevenueList = new UserRevenueInfo[](rewardTokenList.length);

        // get rewards
        for (uint256 i = 0; i < rewardTokenList.length; i++) {
            IERC20 token = IERC20(rewardTokenList[i]);

            totalUserRevenueList[i] = UserRevenueInfo({
                token: token,
                totalUserRevenue: totalUserRevenue[token]
            });
        }

        return totalUserRevenueList;
    }

    /// @notice Get user info
    /// @param _pid The pool id
    /// @param _user The user address
    /// @return The amount of user staked and user reward debt
    function getUserInfo(uint256 _pid, address _user) public view returns (uint256, UserRewardInfo[] memory){
        UserInfo storage user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfoList[_pid];

        uint256 amount = user.amount;

        UserRewardInfo[] memory userRewardInfo = new UserRewardInfo[](pool.rewards.length);

        for (uint i = 0; i < pool.rewards.length; i++) {
            userRewardInfo[i] = UserRewardInfo({
                token: pool.rewards[i].token,
                debt: user.rewardDebt[pool.rewards[i].token]
            });
        }

        return (amount, userRewardInfo);
    }

    /// @notice Get user in pools info
    /// @param _user The user address
    /// @return The pool user info
    function getPoolsUserInfo(address _user) public view returns (PoolUserInfo[] memory){
        PoolUserInfo[] memory poolUserInfoList = new PoolUserInfo[](poolInfoList.length);

        for (uint i = 0; i < poolInfoList.length; i++) {
            (uint256 _amount, UserRewardInfo[] memory _userRewardInfo) = getUserInfo(i, _user);
            poolUserInfoList[i] = PoolUserInfo({
                pid: i,
                amount: _amount,
                rewards: _userRewardInfo
            });
        }

        return poolUserInfoList;
    }

    /// @notice Get pool information
    /// @param _pid The pool id
    /// @return The pool presentation info
    function getPoolInfo(uint256 _pid) public view returns (PoolInfoPresentations memory){
        PoolInfo storage pool = poolInfoList[_pid];

        PoolInfoPresentations memory poolDisplay;

        poolDisplay.assets = pool.assets;
        poolDisplay.allocPoint = pool.allocPoint;
        poolDisplay.amount = pool.amount;
        poolDisplay.withdrawFee = pool.withdrawFee;
        poolDisplay.lastRewardTime = pool.lastRewardTime;
        poolDisplay.vault = pool.vault;
        poolDisplay.rewards = new RewardInfo[](pool.rewards.length);
        poolDisplay.acctPerShare = new AcctPerShareInfo[](pool.rewards.length);

        for (uint i = 0; i < pool.rewards.length; i++) {
            poolDisplay.rewards[i] = RewardInfo({
                token: pool.rewards[i].token,
                tokenPerBlock: pool.rewards[i].tokenPerBlock
            });

            poolDisplay.acctPerShare[i] = AcctPerShareInfo({
                token: pool.rewards[i].token,
                acctPerShare: pool.acctPerShare[pool.rewards[i].token]
            });
        }

        return poolDisplay;
    }

    /// @notice Get the pool length
    function getPoolLength() public view returns (uint256){
        return poolInfoList.length;
    }

    /// @notice Get pool users
    /// @param _pid The pool id
    function getActionUserList(uint256 _pid) external onlyOwner view returns (address[] memory){
        address[] memory userList = poolUserList[_pid].values();
        return userList;
    }

    /// @notice Get single pool TVL
    /// @param _pid The pool id
    function getPoolTvl(uint256 _pid) public view returns (uint256){
        PoolInfo storage pool = poolInfoList[_pid];
        return pool.vault.balance();
    }

    /// @notice Get total TVL
    function getPoolTotalTvl() public view returns (PoolTvl[] memory){
        uint256 _len = poolInfoList.length;
        PoolTvl[] memory _totalPoolTvl = new PoolTvl[](_len);

        for (uint256 pid = 0; pid < _len; pid++) {
            uint256 _tvl = getPoolTvl(pid);

            PoolTvl memory _pt = PoolTvl({
                pid: pid,
                assets: poolInfoList[pid].assets,
                tvl: _tvl
            });

            _totalPoolTvl[pid] = _pt;
        }
        return _totalPoolTvl;
    }

    /// @notice Start to farm
    function startMining() public onlyOwner {
        require(startTimestamp == 0, "Farm: mining already started");

        startTimestamp = block.timestamp;
        startBlock = block.number;
        bonusEndTime = startTimestamp + 30 days;
    }

    /// @notice Check the pool created or not
    function checkDuplicatePool(address _token) internal view {
        uint _existed = 0;

        for (uint256 i = 0; i < poolInfoList.length; i++) {
            if (address(poolInfoList[i].assets) == _token) {
                _existed = 1;
                break;
            }
        }

        require(_existed == 0, "Farm: pool already existed");
    }

    /// @notice Add new pool
    /// @param _allocPoints The allocation points
    /// @param _token The pool asset
    /// @param _withUpdate The updated pool flag
    /// @param _withdrawFee The withdrawal fee
    /// @param _vault The vault address
    /// @param _isEth Pool asset native token identifier
    /// @param _rewards The reward tokens
    function addPool(
        uint256 _allocPoints,
        address _token,
        bool _withUpdate,
        uint256 _withdrawFee,
        address _vault,
        bool _isEth,
        RewardInfo[] memory _rewards
    ) external onlyOwner {

        checkDuplicatePool(_token);

        if (_withUpdate) {
            updateMassPools();
        }

        uint256 lastRewardTime = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;

        // increase total alloc point
        totalAllocPoint += _allocPoints;

        if (_isEth == false) {
            IERC20(_token).approve(address(_vault), 0);
            IERC20(_token).approve(address(_vault), type(uint256).max);
        }

        PoolInfo storage newPool = poolInfoList.push();
        newPool.assets = IERC20(_token);
        newPool.allocPoint = _allocPoints;
        newPool.amount = 0;
        newPool.withdrawFee = _withdrawFee;
        newPool.lastRewardTime = lastRewardTime;
        newPool.vault = IVault(_vault);


        for (uint i = 0; i < _rewards.length; i++) {
            newPool.rewards.push(_rewards[i]);
            newPool.acctPerShare[_rewards[i].token] = 0;
            rewardTokenSet.add(address(_rewards[i].token));
        }
    }

    /// @notice Add new reward token to pool
    /// @param _pid The pool id
    /// @param _rewardToken The new reward token
    /// @param _tokenPerBlock Token yield per block
    function addRewardTokenToPool(uint256 _pid, IERC20 _rewardToken, uint256 _tokenPerBlock) public onlyOwner {
        require(address(_rewardToken) != address(0), "Invalid rewardToken");
        require(_tokenPerBlock > 0, "Invalid token per block");

        PoolInfo storage pool = poolInfoList[_pid];
        pool.rewards.push(RewardInfo({
            token: _rewardToken,
            tokenPerBlock: _tokenPerBlock
        }));
        rewardTokenSet.add(address(_rewardToken));
    }

    /// @notice Remove the reward token from pool
    /// @param _pid The pool id
    /// @param _rewardToken The reward token to remove
    function removeRewardTokenFromPool(uint256 _pid, IERC20 _rewardToken) public onlyOwner {
        require(address(_rewardToken) != address(0), "Invalid rewardToken");

        PoolInfo storage pool = poolInfoList[_pid];

        // calculate the removing token rewards and transfer to user
        address[] memory userList = poolUserList[_pid].values();
        for (uint256 i = 0; i < userList.length; i++) {
            address userAddr = userList[i];
            uint256 _pendingRemovingRewards = pendingRewardToken(_pid, userAddr, _rewardToken);
            if (_pendingRemovingRewards > 0) {
                safeTokenTransfer(_rewardToken, userAddr, _pendingRemovingRewards);
            }
        }

        // find the reward token and remove it
        uint256 rewardLength = pool.rewards.length;

        for (uint256 i = 0; i < rewardLength; i++) {
            if (pool.rewards[i].token == _rewardToken) {
                pool.rewards[i] = pool.rewards[rewardLength - 1];
                pool.rewards.pop();

                rewardTokenSet.remove(address(_rewardToken));
                break;
            }
        }

        // update the pool
        updatePool(_pid);
    }

    /// @notice Update the pool info
    /// @param _pid The pool id
    /// @param _allocPoints The allocation points
    /// @param _withUpdate The updated pool flag
    /// @param _withdrawFee The withdrawal fee
    function setPool(
        uint256 _pid,
        uint256 _allocPoints,
        bool _withUpdate,
        uint256 _withdrawFee
    ) external onlyOwner {

        if (_withUpdate) {
            updateMassPools();
        }

        totalAllocPoint = totalAllocPoint - poolInfoList[_pid].allocPoint + _allocPoints;

        poolInfoList[_pid].allocPoint = _allocPoints;
        poolInfoList[_pid].withdrawFee = _withdrawFee;
    }

    /// @notice Update the pools
    function updateMassPools() public {
        for (uint256 i = 0; i < poolInfoList.length; i++) {
            updatePool(i);
        }
    }

    /// @notice Update the pool
    /// @param _pid The pool id
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfoList[_pid];

        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        uint256 totalAmount = pool.amount;
        if (totalAmount <= 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }


        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);

        for (uint i = 0; i < pool.rewards.length; i++) {
            RewardInfo memory reward = pool.rewards[i];

            uint256 tokenReward = multiplier * (reward.tokenPerBlock) * (pool.allocPoint) / (totalAllocPoint);
            pool.acctPerShare[reward.token] = pool.acctPerShare[reward.token] + (tokenReward * 1e18 / totalAmount);
        }

        pool.lastRewardTime = block.timestamp;
    }

    /// @notice Return the user pending rewards
    /// @param _pid The pool id
    /// @param _user The user address
    /// @param _rewardToken The reward token
    function pendingRewardToken(uint256 _pid, address _user, IERC20 _rewardToken) public view returns (uint256) {
        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 acctPerShare = pool.acctPerShare[_rewardToken];
        uint256 totalAmount = pool.amount;

        if (block.timestamp > pool.lastRewardTime && totalAmount > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);

            uint256 tokenReward;
            for (uint i = 0; i < pool.rewards.length; i++) {
                if (pool.rewards[i].token == _rewardToken) {
                    RewardInfo memory rewardInfo = pool.rewards[i];
                    tokenReward = multiplier * (rewardInfo.tokenPerBlock) * (pool.allocPoint) / (totalAllocPoint);
                    acctPerShare = acctPerShare + (tokenReward * 1e18 / totalAmount);
                    break;
                }
            }
        }

        uint256 reward = user.amount * acctPerShare / 1e18;
        uint256 _pendingRewards = reward > user.rewardDebt[_rewardToken] ? reward - (user.rewardDebt[_rewardToken]) : 0;
        if (pool.withdrawFee == 0) {
            return _pendingRewards;
        } else {
            if (_pendingRewards > 0) {
                uint256 _fee = _pendingRewards * pool.withdrawFee / 1000;
                return _pendingRewards - _fee;
            } else {
                return 0;
            }
        }
    }

    /// @notice Return the user all pending rewards
    /// @param _pid The pool id
    /// @param _user The user address
    function getAllPendingRewardToken(uint256 _pid, address _user) public view returns (UserRewardInfo[] memory) {
        require(_user != address(0), "Invalid address");

        PoolInfo storage pool = poolInfoList[_pid];

        UserRewardInfo[] memory userPendingRewards = new UserRewardInfo[](pool.rewards.length);

        for (uint i = 0; i < pool.rewards.length; i++) {
            IERC20 rewardToken = pool.rewards[i].token;

            uint256 pendingRewards = pendingRewardToken(_pid, _user, rewardToken);

            userPendingRewards[i] = UserRewardInfo({
                token: rewardToken,
                debt: pendingRewards
            });
        }

        return userPendingRewards;
    }

    /// @notice Calculate the rewards and transfer to user
    /// @param _pid The pool id
    /// @param _user The user address
    function harvest(uint256 _pid, address _user) public {
        require(_paused == false, "Farm: Paused");
        require(startTimestamp > 0, "Farm: mining not start!!");
        require(_user != address(0), "Farm: invalid user address");

        UserInfo storage user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfoList[_pid];

        for (uint i = 0; i < pool.rewards.length; i++) {
            IERC20 rewardToken = pool.rewards[i].token;

            uint256 pendingRewards = pendingRewardToken(_pid, _user, rewardToken);

            if (pendingRewards > 0) {
                user.rewardDebt[rewardToken] = user.rewardDebt[rewardToken] + pendingRewards;
                totalUserRevenue[rewardToken] = totalUserRevenue[rewardToken] + pendingRewards;
                safeTokenTransfer(rewardToken, _user, pendingRewards);
            }
        }
    }

    /// @notice Deposit assets to the farm
    /// @param _pid The pool id
    /// @param _amount The amount of assets to deposit
    function deposit(uint256 _pid, uint256 _amount) external payable nonReentrant returns (uint){
        require(_paused == false, "Farm: Paused");
        require(startTimestamp > 0, "Farm: mining not start!!");

        PoolInfo storage pool = poolInfoList[_pid];

        for (uint i = 0; i < pool.rewards.length; i++) {
            require(address(pool.rewards[i].token) != address(0), "invalid pool reward token");
        }

        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        // process rewards
        if (user.amount > 0) {
            harvest(_pid, msg.sender);
        }

        // process WETH
        if (address(pool.assets) == weth) {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
                TransferHelper.safeTransfer(weth, address(wethHelper), _amount);
                wethHelper.withdrawETH(weth, address(this), _amount);
            }

            if (msg.value > 0) {
                _amount = _amount + msg.value;
            }
        } else {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
            }
        }

        if (_amount > 0) {
            pool.amount = pool.amount + _amount;
            user.amount = user.amount + _amount;
        }

        for (uint i = 0; i < pool.rewards.length; i++) {
            IERC20 rewardToken = pool.rewards[i].token;
            user.rewardDebt[rewardToken] = user.amount * (pool.acctPerShare[rewardToken]) / (1e18);
        }

        if (address(pool.assets) == weth) {
            _amount = pool.vault.deposit{value: _amount}(msg.sender, 0);
        } else {
            _amount = pool.vault.deposit(msg.sender, _amount);
        }

        poolUserList[_pid].add(msg.sender);

        emit Deposit(msg.sender, _pid, _amount);
        return 0;
    }

    /// @notice Withdraw assets from the farm
    /// @param _pid The pool id
    /// @param _amount The amount of assets to withdraw
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant returns (uint){
        require(_paused == false, "Farm: Paused");
        require(startTimestamp > 0, "Farm: mining not start!!");

        PoolInfo storage pool = poolInfoList[_pid];

        for (uint i = 0; i < pool.rewards.length; i++) {
            require(address(pool.rewards[i].token) != address(0), "invalid pool reward token");
        }


        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "Farm: withdraw amount exceeds balance");

        updatePool(_pid);

        // process rewards
        harvest(_pid, msg.sender);

        if (_amount > 0) {
            user.amount = user.amount - _amount;
            pool.amount = pool.amount - _amount;
        }

        for (uint i = 0; i < pool.rewards.length; i++) {
            IERC20 rewardToken = pool.rewards[i].token;
            user.rewardDebt[rewardToken] = user.amount * (pool.acctPerShare[rewardToken]) / (1e18);
        }

        pool.vault.withdraw(msg.sender, _amount, pool.withdrawFee);

        emit Withdraw(msg.sender, _pid, _amount);
        return 0;
    }

    /// @dev Get the farm pause status
    function getFarmPause() external view returns (bool){
        return _paused;
    }

    /// @dev Set the farm pause status
    /// @param _pause The pause status
    function setFarmPause(bool _pause) external onlyOwner {
        _paused = _pause;
    }

    /// @dev Get the multiplier
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256){
        if (_to <= bonusEndTime) {
            return _to - (_from) * (BONUS_MULTIPLIER);
        } else if (_from >= bonusEndTime) {
            return _to - (_from);
        } else {
            return bonusEndTime - (_from) * (BONUS_MULTIPLIER) + (
                _to - (bonusEndTime)
            );
        }
    }

    /// @notice Set the pool assets
    /// @param _pid The pool id
    /// @param _token The pool new assets
    function setPoolAsset(
        uint256 _pid,
        IERC20 _token
    ) external onlyOwner {

        poolInfoList[_pid].assets = _token;

        _token.approve(address(poolInfoList[_pid].vault), 0);
        _token.approve(address(poolInfoList[_pid].vault), type(uint256).max);
    }

    /// @notice Set the pool vault
    /// @param _pid The pool id
    /// @param _vault The vault address
    function setPoolVault(
        uint256 _pid,
        IVault _vault
    ) external onlyOwner {

        poolInfoList[_pid].vault = _vault;
        IERC20(poolInfoList[_pid].assets).approve(address(poolInfoList[_pid].vault), 0);
        IERC20(poolInfoList[_pid].assets).approve(address(poolInfoList[_pid].vault), type(uint256).max);
    }

    /// @dev Transfer the reward to user
    /// @param token The assets
    /// @param _user The user address
    /// @param _amount The amount of assets to transfer
    function safeTokenTransfer(IERC20 token, address _user, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            token.safeTransfer(_user, tokenBal);
        } else {
            token.safeTransfer(_user, _amount);
        }
    }
}

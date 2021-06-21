//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.0;

import "./utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./utils/ReentrancyGuard.sol";

import "./Token.sol";
// MasterGame is the master of game. He can make game and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once game is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterGame is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of PolyGames
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGamePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGamePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. PolyGames to distribute per block.
        uint256 lastRewardBlock; // Last block number that PolyGames distribution occurs.
        uint256 accGamePerShare; // Accumulated PolyGames per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    // The game token
    Token public game;
    // Dev address.
    address public devaddr;
    // game tokens created per block.
    uint256 public gamePerBlock = 400000000000000000;
    // Bonus muliplier for early game makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when game mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event ClaimRewards(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 gamePerBlock);

    constructor(
        Token _game,
        address _devaddr,
        address _feeAddress,
        uint256 _startBlock
    ) {
        game = _game;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_lpToken) {
        require(
            _depositFeeBP <= 10000,
            "add: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accGamePerShare: 0,
                depositFeeBP: _depositFeeBP
            })
        );
    }

    // Update the given pool's game allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner {
        require(
            _depositFeeBP <= 10000,
            "set: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending PolyGames on frontend.
    function pendingGame(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGamePerShare = pool.accGamePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 gameReward =
                multiplier.mul(gamePerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accGamePerShare = accGamePerShare.add(
                gameReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accGamePerShare).div(1e12).sub(user.rewardDebt);
    }

    // Claim function to claim pending PolyGames on.
    function claimRewards(uint256 _pid)
        public
        nonReentrant
        returns (uint256 amount)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accGamePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeGameTransfer(msg.sender, pending);
        }
        user.rewardDebt = user.amount.mul(pool.accGamePerShare).div(1e12);
        emit ClaimRewards(msg.sender, _pid, pending);
        return pending;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Reduces incoming supply after certain total supply is met
    function updategamePerBlock(uint256 gameSupply) internal {
        if (gameSupply >= 984375 ether && gamePerBlock > 6250000000000000) {
            return updateEmissionRate(6250000000000000);
        }

        if (gameSupply >= 968750 ether && gamePerBlock > 12500000000000000) {
            return updateEmissionRate(12500000000000000);
        }

        if (gameSupply >= 937500 ether && gamePerBlock > 25000000000000000) {
            return updateEmissionRate(25000000000000000);
        }

        if (gameSupply >= 875000 ether && gamePerBlock > 50000000000000000) {
            return updateEmissionRate(50000000000000000);
        }

        if (gameSupply >= 750000 ether && gamePerBlock > 100000000000000000) {
            return updateEmissionRate(100000000000000000);
        }

        if (gameSupply >= 500000 ether && gamePerBlock > 200000000000000000) {
            return updateEmissionRate(200000000000000000);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 gameSupply = game.totalSupply();
        uint256 gameMaxSupply = game.maxSupply();

        if (gameSupply >= gameMaxSupply) {
            pool.lastRewardBlock = block.number;
            return;
        }

        updategamePerBlock(gameSupply);
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 gameReward =
            multiplier.mul(gamePerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        if (gameReward.add(gameSupply) > gameMaxSupply) {
            uint256 gameRewardToDeduct =
                gameReward.add(gameSupply).sub(gameMaxSupply);
            gameReward = gameReward.sub(gameRewardToDeduct);
        }

        uint256 devReward = gameReward.div(10);

        game.mint(devaddr, devReward);
        game.mint(address(this), gameReward.sub(devReward));
        pool.accGamePerShare = pool.accGamePerShare.add(
            gameReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterGame for game allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accGamePerShare).div(1e12).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeGameTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accGamePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterGame.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accGamePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeGameTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGamePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe game transfer function, just in case if rounding error causes pool to not have enough PolyGames.
    function safeGameTransfer(address _to, uint256 _amount) internal {
        uint256 gameBal = game.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > gameBal) {
            transferSuccess = game.transfer(_to, gameBal);
        } else {
            transferSuccess = game.transfer(_to, _amount);
        }
        require(transferSuccess, "safeGameTransfer: transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _gamePerBlock) internal {
        gamePerBlock = _gamePerBlock;
        emit UpdateEmissionRate(msg.sender, _gamePerBlock);
    }
}

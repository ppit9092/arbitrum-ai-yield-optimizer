// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AIYieldAggregator
 * @notice AI椹卞姩鐨勬敹鐩婅仛鍚堝櫒 - Arbitrum Demo
 * @dev 婕旂ず鐗堟湰锛屾敮鎸佸鍗忚鏀剁泭浼樺寲
 */
contract AIYieldAggregator is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // 绛栫暐缁撴瀯
    struct Strategy {
        address protocol;
        string name;
        uint256 apy;        // APY * 100 (渚嬪 500 = 5%)
        uint256 riskScore;  // 1-10, 10鏈€楂橀闄?        uint256 tvl;
        bool active;
    }

    // 鐢ㄦ埛瀛樻淇℃伅
    struct UserDeposit {
        uint256 amount;
        uint256 strategyId;
        uint256 depositTime;
    }

    // 鐘舵€佸彉閲?    Strategy[] public strategies;
    mapping(address => mapping(address => UserDeposit)) public userDeposits; // user => token => deposit
    mapping(address => uint256) public totalDeposits;
    
    address public aiOracle;  // AI棰勮█鏈哄湴鍧€
    uint256 public constant MIN_DEPOSIT = 0.001 ether;
    uint256 public platformFee = 100; // 1% = 100 basis points

    // 浜嬩欢
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 strategyId);
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 yield);
    event StrategyAdded(uint256 indexed strategyId, address protocol, string name);
    event StrategyUpdated(uint256 indexed strategyId, uint256 newApy, uint256 newRisk);
    event Rebalanced(address indexed user, uint256 fromStrategy, uint256 toStrategy, uint256 amount);

    constructor(address _aiOracle) {
        aiOracle = _aiOracle;
        
        // 鍒濆鍖栨紨绀虹瓥鐣?        _addStrategy(address(0x1), "Aave Arbitrum", 450, 3, 1000000 ether);
        _addStrategy(address(0x2), "GMX GLP", 850, 5, 500000 ether);
        _addStrategy(address(0x3), "Camelot DEX", 1200, 7, 200000 ether);
    }

    /**
     * @notice 娣诲姞鏂扮瓥鐣?     */
    function _addStrategy(
        address _protocol,
        string memory _name,
        uint256 _apy,
        uint256 _risk,
        uint256 _tvl
    ) internal {
        strategies.push(Strategy({
            protocol: _protocol,
            name: _name,
            apy: _apy,
            riskScore: _risk,
            tvl: _tvl,
            active: true
        }));
        
        emit StrategyAdded(strategies.length - 1, _protocol, _name);
    }

    /**
     * @notice 瀛樻鍒版寚瀹氱瓥鐣?     */
    function deposit(
        address _token,
        uint256 _amount,
        uint256 _strategyId
    ) external nonReentrant {
        require(_amount >= MIN_DEPOSIT, "Amount too small");
        require(_strategyId < strategies.length, "Invalid strategy");
        require(strategies[_strategyId].active, "Strategy inactive");

        // 杞处
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // 璁板綍瀛樻
        userDeposits[msg.sender][_token] = UserDeposit({
            amount: _amount,
            strategyId: _strategyId,
            depositTime: block.timestamp
        });

        totalDeposits[_token] += _amount;

        emit Deposit(msg.sender, _token, _amount, _strategyId);
    }

    /**
     * @notice 鍙栨骞惰绠楁敹鐩?     */
    function withdraw(address _token) external nonReentrant {
        UserDeposit storage deposit = userDeposits[msg.sender][_token];
        require(deposit.amount > 0, "No deposit found");

        uint256 principal = deposit.amount;
        uint256 yield = _calculateYield(principal, deposit.strategyId, deposit.depositTime);
        uint256 totalAmount = principal + yield;
        uint256 fee = (yield * platformFee) / 10000;

        // 閲嶇疆瀛樻璁板綍
        deposit.amount = 0;
        totalDeposits[_token] -= principal;

        // 杞处缁欑敤鎴?        IERC20(_token).safeTransfer(msg.sender, totalAmount - fee);

        emit Withdraw(msg.sender, _token, principal, yield - fee);
    }

    /**
     * @notice 璁＄畻鏀剁泭
     */
    function _calculateYield(
        uint256 _principal,
        uint256 _strategyId,
        uint256 _depositTime
    ) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - _depositTime;
        uint256 apy = strategies[_strategyId].apy;
        
        // 绠€鍗曞埄鎭绠? principal * apy * time / (10000 * 365 days)
        return (_principal * apy * timeElapsed) / (10000 * 365 days);
    }

    /**
     * @notice AI鎺ㄨ崘鏈€浼樼瓥鐣?     */
    function getOptimalStrategy(uint256 _riskTolerance) external view returns (uint256) {
        uint256 bestStrategy = 0;
        uint256 bestScore = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active) continue;
            if (strategies[i].riskScore > _riskTolerance) continue;

            // 璇勫垎鍏紡: APY * 100 / (risk + 1)
            uint256 score = (strategies[i].apy * 100) / (strategies[i].riskScore + 1);
            
            if (score > bestScore) {
                bestScore = score;
                bestStrategy = i;
            }
        }

        return bestStrategy;
    }

    /**
     * @notice 鑾峰彇鐢ㄦ埛鎶曡祫缁勫悎
     */
    function getPortfolio(address _user, address _token) 
        external 
        view 
        returns (
            uint256 amount,
            uint256 strategyId,
            uint256 currentYield,
            string memory strategyName
        ) 
    {
        UserDeposit memory deposit = userDeposits[_user][_token];
        amount = deposit.amount;
        strategyId = deposit.strategyId;
        currentYield = deposit.amount > 0 
            ? _calculateYield(deposit.amount, deposit.strategyId, deposit.depositTime)
            : 0;
        strategyName = strategies[deposit.strategyId].name;
    }

    /**
     * @notice 鑾峰彇鎵€鏈夌瓥鐣?     */
    function getAllStrategies() external view returns (Strategy[] memory) {
        return strategies;
    }

    /**
     * @notice 鏇存柊绛栫暐APY (浠匒I Oracle)
     */
    function updateStrategyAPY(uint256 _strategyId, uint256 _newApy) external {
        require(msg.sender == aiOracle || msg.sender == owner(), "Not authorized");
        require(_strategyId < strategies.length, "Invalid strategy");
        
        strategies[_strategyId].apy = _newApy;
        
        emit StrategyUpdated(_strategyId, _newApy, strategies[_strategyId].riskScore);
    }

    /**
     * @notice 璁剧疆骞冲彴璐圭敤
     */
    function setPlatformFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee too high"); // Max 10%
        platformFee = _newFee;
    }

    /**
     * @notice 绱ф€ュ彇娆?(浠卭wner)
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner(), balance);
    }
}

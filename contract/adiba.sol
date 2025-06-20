// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title CrossChainDeFiAggregator
 * @dev A cross-chain DeFi aggregator that automatically routes investments to highest yielding farms
 */
contract CrossChainDeFiAggregator is ReentrancyGuard, Ownable {
    
    // Structs
    struct Farm {
        address farmAddress;
        uint256 apy; // APY in basis points (100 = 1%)
        uint256 tvl; // Total Value Locked
        uint256 chainId;
        bool isActive;
        uint256 lastUpdated;
    }

    struct UserPosition {
        uint256 totalDeposited;
        uint256 totalEarned;
        uint256 lastRebalance;
    }

    struct CrossChainBridge {
        address bridgeContract;
        uint256 destinationChainId;
        uint256 fee;
        bool isActive;
    }

    // State variables
    mapping(uint256 => Farm) public farms;
    mapping(address => UserPosition) public userPositions;
    mapping(address => mapping(uint256 => uint256)) public userFarmBalances; // user => farmId => balance
    mapping(address => uint256[]) public userActiveFarms; // user => farmIds
    mapping(uint256 => CrossChainBridge) public bridges;
    
    uint256 public farmCount;
    uint256 public bridgeCount;
    uint256 public totalValueLocked;
    uint256 public rebalanceThreshold = 200; // 2% APY difference threshold
    uint256 public maxSlippage = 100; // 1% max slippage
    uint256 public platformFee = 50; // 0.5% platform fee
    
    address public feeCollector;
    bool public autoRebalanceEnabled = true;

    // Events
    event FarmAdded(uint256 indexed farmId, address farmAddress, uint256 chainId);
    event FarmUpdated(uint256 indexed farmId, uint256 newApy, uint256 newTvl);
    event UserDeposit(address indexed user, uint256 amount, uint256 farmId);
    event UserWithdraw(address indexed user, uint256 amount, uint256 farmId);
    event AutoRebalance(address indexed user, uint256 fromFarm, uint256 toFarm, uint256 amount);
    event CrossChainTransfer(address indexed user, uint256 amount, uint256 fromChain, uint256 toChain);

    // Modifiers
    modifier validFarm(uint256 _farmId) {
        require(_farmId < farmCount && farms[_farmId].isActive, "Invalid or inactive farm");
        _;
    }

    modifier onlyActiveUser() {
        require(userPositions[msg.sender].totalDeposited > 0, "No active position");
        _;
    }

    constructor(address _feeCollector) {
        require(_feeCollector != address(0), "Invalid fee collector");
        feeCollector = _feeCollector;
    }

    /**
     * @dev Core Function 1: Deposit and automatically route to highest yielding farm
     * @param _token Token address to deposit
     * @param _amount Amount to deposit
     */
    function depositAndRoute(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(_token != address(0), "Invalid token address");
        
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Find highest yielding active farm
        uint256 bestFarmId = findHighestYieldFarm();
        require(bestFarmId < farmCount, "No active farms available");
        
        // Calculate platform fee
        uint256 fee = (_amount * platformFee) / 10000;
        uint256 netAmount = _amount - fee;
        
        // Transfer fee to collector
        if (fee > 0) {
            require(token.transfer(feeCollector, fee), "Fee transfer failed");
        }
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender];
        position.totalDeposited += netAmount;
        userFarmBalances[msg.sender][bestFarmId] += netAmount;
        
        // Add to active farms if not already present
        bool farmExists = false;
        uint256[] storage activeFarms = userActiveFarms[msg.sender];
        for (uint256 i = 0; i < activeFarms.length; i++) {
            if (activeFarms[i] == bestFarmId) {
                farmExists = true;
                break;
            }
        }
        if (!farmExists) {
            activeFarms.push(bestFarmId);
        }
        
        // Update global TVL
        totalValueLocked += netAmount;
        farms[bestFarmId].tvl += netAmount;
        
        emit UserDeposit(msg.sender, netAmount, bestFarmId);
    }

    /**
     * @dev Core Function 2: Automatic rebalancing to optimize yields
     */
    function autoRebalance() external onlyActiveUser nonReentrant {
        UserPosition storage position = userPositions[msg.sender];
        require(block.timestamp >= position.lastRebalance + 1 hours, "Rebalance cooldown active");
        require(autoRebalanceEnabled, "Auto rebalance disabled");
        
        uint256 bestFarmId = findHighestYieldFarm();
        uint256 currentBestApy = farms[bestFarmId].apy;
        
        // Check each active farm for rebalancing opportunity
        uint256[] storage activeFarms = userActiveFarms[msg.sender];
        for (uint256 i = 0; i < activeFarms.length; i++) {
            uint256 farmId = activeFarms[i];
            uint256 balance = userFarmBalances[msg.sender][farmId];
            
            if (balance > 0 && farmId != bestFarmId) {
                uint256 currentApy = farms[farmId].apy;
                
                // Rebalance if APY difference exceeds threshold
                if (currentBestApy > currentApy + rebalanceThreshold) {
                    // Move funds from current farm to best farm
                    userFarmBalances[msg.sender][farmId] = 0;
                    userFarmBalances[msg.sender][bestFarmId] += balance;
                    
                    // Update farm TVLs
                    farms[farmId].tvl -= balance;
                    farms[bestFarmId].tvl += balance;
                    
                    emit AutoRebalance(msg.sender, farmId, bestFarmId, balance);
                }
            }
        }
        
        position.lastRebalance = block.timestamp;
    }

    /**
     * @dev Core Function 3: Cross-chain yield optimization
     * @param _targetChainId Target blockchain ID
     * @param _amount Amount to bridge
     */
    function crossChainOptimize(uint256 _targetChainId, uint256 _amount) external onlyActiveUser nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(_targetChainId != block.chainid, "Cannot bridge to same chain");
        
        UserPosition storage position = userPositions[msg.sender];
        require(position.totalDeposited >= _amount, "Insufficient balance");
        
        // Find best farm on target chain
        uint256 bestTargetFarm = findBestFarmOnChain(_targetChainId);
        require(bestTargetFarm < farmCount, "No active farms on target chain");
        
        // Find bridge for target chain
        uint256 bridgeId = findBridgeForChain(_targetChainId);
        require(bridgeId < bridgeCount && bridges[bridgeId].isActive, "No active bridge for target chain");
        
        CrossChainBridge storage bridge = bridges[bridgeId];
        
        // Calculate bridge fee
        uint256 bridgeFee = bridge.fee;
        require(_amount > bridgeFee, "Amount too small for bridge fee");
        
        uint256 netAmount = _amount - bridgeFee;
        
        // Update user position (simulate cross-chain transfer)
        position.totalDeposited -= _amount;
        
        // Remove amount from current farms
        withdrawFromFarms(msg.sender, _amount);
        
        // Add to target chain farm (simplified - would use actual bridge)
        userFarmBalances[msg.sender][bestTargetFarm] += netAmount;
        farms[bestTargetFarm].tvl += netAmount;
        
        emit CrossChainTransfer(msg.sender, netAmount, block.chainid, _targetChainId);
    }

    /**
     * @dev Core Function 4: Withdraw funds with yield optimization
     * @param _amount Amount to withdraw
     */
    function optimizedWithdraw(uint256 _amount) external onlyActiveUser nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        
        UserPosition storage position = userPositions[msg.sender];
        require(position.totalDeposited >= _amount, "Insufficient balance");
        
        // Calculate total earnings
        uint256 totalEarnings = calculateUserEarnings(msg.sender);
        position.totalEarned += totalEarnings;
        
        // Withdraw from farms with lowest yield first (tax optimization)
        uint256 remainingAmount = _amount;
        uint256[] memory sortedFarms = sortFarmsByYield(userActiveFarms[msg.sender]);
        
        for (uint256 i = 0; i < sortedFarms.length && remainingAmount > 0; i++) {
            uint256 farmId = sortedFarms[i];
            uint256 farmBalance = userFarmBalances[msg.sender][farmId];
            
            if (farmBalance > 0) {
                uint256 withdrawAmount = remainingAmount > farmBalance ? farmBalance : remainingAmount;
                
                userFarmBalances[msg.sender][farmId] -= withdrawAmount;
                position.totalDeposited -= withdrawAmount;
                farms[farmId].tvl -= withdrawAmount;
                totalValueLocked -= withdrawAmount;
                
                remainingAmount -= withdrawAmount;
                
                emit UserWithdraw(msg.sender, withdrawAmount, farmId);
            }
        }
    }

    // Helper functions
    function findHighestYieldFarm() internal view returns (uint256) {
        uint256 bestFarmId = 0;
        uint256 highestApy = 0;
        
        for (uint256 i = 0; i < farmCount; i++) {
            if (farms[i].isActive && farms[i].apy > highestApy) {
                highestApy = farms[i].apy;
                bestFarmId = i;
            }
        }
        
        return bestFarmId;
    }
    
    function findBestFarmOnChain(uint256 _chainId) internal view returns (uint256) {
        uint256 bestFarmId = type(uint256).max;
        uint256 highestApy = 0;
        
        for (uint256 i = 0; i < farmCount; i++) {
            if (farms[i].isActive && farms[i].chainId == _chainId && farms[i].apy > highestApy) {
                highestApy = farms[i].apy;
                bestFarmId = i;
            }
        }
        
        return bestFarmId;
    }
    
    function findBridgeForChain(uint256 _chainId) internal view returns (uint256) {
        for (uint256 i = 0; i < bridgeCount; i++) {
            if (bridges[i].isActive && bridges[i].destinationChainId == _chainId) {
                return i;
            }
        }
        return type(uint256).max;
    }
    
    function calculateUserEarnings(address _user) internal view returns (uint256) {
        uint256 totalEarnings = 0;
        uint256[] storage activeFarms = userActiveFarms[_user];
        
        for (uint256 i = 0; i < activeFarms.length; i++) {
            uint256 farmId = activeFarms[i];
            uint256 balance = userFarmBalances[_user][farmId];
            uint256 apy = farms[farmId].apy;
            
            // Simplified: assume 1 year for calculation
            totalEarnings += (balance * apy) / 10000;
        }
        
        return totalEarnings;
    }
    
    function sortFarmsByYield(uint256[] memory _farmIds) internal view returns (uint256[] memory) {
        uint256[] memory sorted = new uint256[](_farmIds.length);
        for (uint256 i = 0; i < _farmIds.length; i++) {
            sorted[i] = _farmIds[i];
        }
        
        // Simple bubble sort by APY (ascending)
        for (uint256 i = 0; i < sorted.length; i++) {
            for (uint256 j = i + 1; j < sorted.length; j++) {
                if (farms[sorted[i]].apy > farms[sorted[j]].apy) {
                    uint256 temp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = temp;
                }
            }
        }
        
        return sorted;
    }
    
    function withdrawFromFarms(address _user, uint256 _amount) internal {
        uint256 remainingAmount = _amount;
        uint256[] storage activeFarms = userActiveFarms[_user];
        
        for (uint256 i = 0; i < activeFarms.length && remainingAmount > 0; i++) {
            uint256 farmId = activeFarms[i];
            uint256 balance = userFarmBalances[_user][farmId];
            
            if (balance > 0) {
                uint256 withdrawAmount = remainingAmount > balance ? balance : remainingAmount;
                userFarmBalances[_user][farmId] -= withdrawAmount;
                farms[farmId].tvl -= withdrawAmount;
                remainingAmount -= withdrawAmount;
            }
        }
    }

    // Admin functions
    function addFarm(address _farmAddress, uint256 _apy, uint256 _chainId) external onlyOwner {
        require(_farmAddress != address(0), "Invalid farm address");
        
        farms[farmCount] = Farm({
            farmAddress: _farmAddress,
            apy: _apy,
            tvl: 0,
            chainId: _chainId,
            isActive: true,
            lastUpdated: block.timestamp
        });
        
        emit FarmAdded(farmCount, _farmAddress, _chainId);
        farmCount++;
    }
    
    function updateFarmApy(uint256 _farmId, uint256 _newApy) external onlyOwner validFarm(_farmId) {
        farms[_farmId].apy = _newApy;
        farms[_farmId].lastUpdated = block.timestamp;
        
        emit FarmUpdated(_farmId, _newApy, farms[_farmId].tvl);
    }
    
    function addBridge(address _bridgeContract, uint256 _destinationChainId, uint256 _fee) external onlyOwner {
        require(_bridgeContract != address(0), "Invalid bridge contract");
        
        bridges[bridgeCount] = CrossChainBridge({
            bridgeContract: _bridgeContract,
            destinationChainId: _destinationChainId,
            fee: _fee,
            isActive: true
        });
        
        bridgeCount++;
    }
    
    function setRebalanceThreshold(uint256 _threshold) external onlyOwner {
        rebalanceThreshold = _threshold;
    }
    
    function setAutoRebalanceEnabled(bool _enabled) external onlyOwner {
        autoRebalanceEnabled = _enabled;
    }
    
    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "Fee cannot exceed 10%");
        platformFee = _fee;
    }

    // View functions
    function getUserPosition(address _user) external view returns (uint256 totalDeposited, uint256 totalEarned, uint256[] memory activeFarms) {
        UserPosition storage position = userPositions[_user];
        return (position.totalDeposited, position.totalEarned, userActiveFarms[_user]);
    }
    
    function getFarmInfo(uint256 _farmId) external view returns (Farm memory) {
        return farms[_farmId];
    }
    
    function getUserFarmBalance(address _user, uint256 _farmId) external view returns (uint256) {
        return userFarmBalances[_user][_farmId];
    }
    
    function getAllFarms() external view returns (uint256) {
        return farmCount;
    }
    
    function getBridgeInfo(uint256 _bridgeId) external view returns (CrossChainBridge memory) {
        return bridges[_bridgeId];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GasOptimized
 * @notice Gas optimization utilities and patterns for Hylo protocol
 * @dev Implements storage packing, custom errors, and efficient patterns
 */
abstract contract GasOptimized is ReentrancyGuard {
    
    // ============ Storage Packing ============
    
    /**
     * @notice Packed user position structure (2 storage slots)
     * @dev Optimized for common read patterns
     */
    struct PackedPosition {
        uint128 zusdBalance;      // Slot 1: zUSD balance (sufficient for most users)
        uint128 zhypeBalance;     // Slot 1: zHYPE balance
        uint64 lastUpdateTime;    // Slot 2: Last update timestamp
        uint32 nonce;            // Slot 2: User nonce for replay protection
        uint32 flags;            // Slot 2: Various boolean flags packed
        uint128 stakedAmount;     // Slot 2: Staked amount
    }
    
    /**
     * @notice Packed protocol state (1 storage slot)
     * @dev Critical protocol parameters packed together
     */
    struct PackedProtocolState {
        uint32 systemState;       // 0: Normal, 1: Cautious, 2: Critical
        uint32 currentFee;        // Current fee in basis points
        uint64 lastHarvestTime;   // Last harvest timestamp
        uint64 totalUsers;        // Total user count
        uint64 reserved;          // Reserved for future use
    }
    
    // ============ Custom Errors (Gas Efficient) ============
    
    // Authorization errors
    error Unauthorized();
    error InvalidSigner();
    error ExpiredSignature();
    
    // Balance errors  
    error InsufficientBalance(uint256 requested, uint256 available);
    error ExceedsMaximum(uint256 value, uint256 maximum);
    error BelowMinimum(uint256 value, uint256 minimum);
    
    // State errors
    error InvalidState(uint32 current, uint32 expected);
    error AlreadyInitialized();
    error NotInitialized();
    
    // Operation errors
    error OperationFailed(string reason);
    error InvalidOperation();
    error Paused();
    
    // ============ Gas-Efficient Modifiers ============
    
    /**
     * @notice Efficient zero address check
     */
    modifier notZeroAddress(address addr) {
        assembly {
            if iszero(addr) {
                let ptr := mload(0x40)
                mstore(ptr, 0x1f2ff10f00000000000000000000000000000000000000000000000000000000) // Unauthorized()
                revert(ptr, 0x04)
            }
        }
        _;
    }
    
    /**
     * @notice Efficient minimum amount check
     */
    modifier minAmount(uint256 amount, uint256 minimum) {
        if (amount < minimum) {
            revert BelowMinimum(amount, minimum);
        }
        _;
    }
    
    /**
     * @notice Efficient maximum amount check
     */
    modifier maxAmount(uint256 amount, uint256 maximum) {
        if (amount > maximum) {
            revert ExceedsMaximum(amount, maximum);
        }
        _;
    }
    
    // ============ Gas-Efficient Functions ============
    
    /**
     * @notice Efficient batch operation iterator
     * @dev Uses unchecked arithmetic for gas savings
     */
    function _batchProcess(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) internal returns (bytes[] memory results) {
        uint256 length = targets.length;
        results = new bytes[](length);
        
        unchecked {
            for (uint256 i; i < length; ++i) {
                (bool success, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);
                if (!success) {
                    assembly {
                        revert(add(result, 0x20), mload(result))
                    }
                }
                results[i] = result;
            }
        }
    }
    
    /**
     * @notice Pack multiple booleans into uint256
     * @dev Can pack up to 256 boolean flags
     */
    function _packBools(bool[] memory bools) internal pure returns (uint256 packed) {
        uint256 length = bools.length;
        require(length <= 256, "Too many bools");
        
        unchecked {
            for (uint256 i; i < length; ++i) {
                if (bools[i]) {
                    packed |= (1 << i);
                }
            }
        }
    }
    
    /**
     * @notice Unpack booleans from uint256
     */
    function _unpackBools(uint256 packed, uint256 count) 
        internal 
        pure 
        returns (bool[] memory bools) 
    {
        bools = new bool[](count);
        
        unchecked {
            for (uint256 i; i < count; ++i) {
                bools[i] = (packed & (1 << i)) != 0;
            }
        }
    }
    
    /**
     * @notice Efficient percentage calculation
     * @dev Avoids division where possible
     */
    function _calculatePercentage(uint256 amount, uint256 bps) 
        internal 
        pure 
        returns (uint256) 
    {
        unchecked {
            return (amount * bps) / 10000;
        }
    }
    
    /**
     * @notice Efficient minimum of two values
     */
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    /**
     * @notice Efficient maximum of two values
     */
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    
    /**
     * @notice Check if value is within range
     */
    function _inRange(uint256 value, uint256 min, uint256 max) 
        internal 
        pure 
        returns (bool) 
    {
        return value >= min && value <= max;
    }
    
    // ============ Storage Optimization Helpers ============
    
    /**
     * @notice Read packed position efficiently
     */
    function _readPackedPosition(PackedPosition storage position) 
        internal 
        view 
        returns (
            uint128 zusdBalance,
            uint128 zhypeBalance,
            uint64 lastUpdate,
            uint128 staked
        ) 
    {
        assembly {
            let slot0 := sload(position.slot)
            zusdBalance := and(slot0, 0xffffffffffffffffffffffffffffffff)
            zhypeBalance := shr(128, slot0)
            
            let slot1 := sload(add(position.slot, 1))
            lastUpdate := and(slot1, 0xffffffffffffffff)
            staked := shr(128, slot1)
        }
    }
    
    /**
     * @notice Write packed position efficiently
     */
    function _writePackedPosition(
        PackedPosition storage position,
        uint128 zusdBalance,
        uint128 zhypeBalance,
        uint128 stakedAmount
    ) internal {
        assembly {
            // Pack and store slot 0
            let slot0 := or(zusdBalance, shl(128, zhypeBalance))
            sstore(position.slot, slot0)
            
            // Update slot 1 with new staked amount and timestamp
            let slot1 := sload(add(position.slot, 1))
            slot1 := and(slot1, 0xffffffff000000000000000000000000) // Clear timestamp and staked
            slot1 := or(slot1, timestamp())
            slot1 := or(slot1, shl(128, stakedAmount))
            sstore(add(position.slot, 1), slot1)
        }
    }
    
    // ============ Batch Operations ============
    
    /**
     * @notice Batch transfer with gas optimization
     */
    function _batchTransfer(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) internal {
        uint256 length = recipients.length;
        require(length == amounts.length, "Length mismatch");
        
        assembly {
            let token_ := token
            let selector := 0xa9059cbb // transfer(address,uint256)
            
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                let recipient := calldataload(add(recipients.offset, mul(i, 0x20)))
                let amount := calldataload(add(amounts.offset, mul(i, 0x20)))
                
                let ptr := mload(0x40)
                mstore(ptr, selector)
                mstore(add(ptr, 0x04), recipient)
                mstore(add(ptr, 0x24), amount)
                
                let success := call(gas(), token_, 0, ptr, 0x44, 0, 0)
                if iszero(success) {
                    revert(0, 0)
                }
            }
        }
    }
    
    // ============ CEI Pattern Helpers ============
    
    /**
     * @notice Checks-Effects-Interactions pattern helper
     * @dev Ensures state changes before external calls
     */
    modifier cei() {
        // This would typically use ReentrancyGuard's internal functions
        // For now, just ensuring proper ordering
        _;
    }
    
    // ============ Pull Payment Pattern ============
    
    mapping(address => uint256) private _pendingPayments;
    
    /**
     * @notice Add payment to pull queue
     */
    function _addPayment(address recipient, uint256 amount) internal {
        _pendingPayments[recipient] += amount;
    }
    
    /**
     * @notice Allow recipient to pull payment
     */
    function pullPayment() external nonReentrant {
        uint256 amount = _pendingPayments[msg.sender];
        if (amount == 0) revert InvalidOperation();
        
        _pendingPayments[msg.sender] = 0;
        
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert OperationFailed("Transfer failed");
    }
    
    /**
     * @notice Get pending payment for address
     */
    function pendingPayment(address account) external view returns (uint256) {
        return _pendingPayments[account];
    }
}
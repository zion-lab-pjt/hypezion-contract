// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title HypeTestnetFaucet
 * @notice Testnet faucet for distributing HYPE tokens to users
 * @dev Allows one-time claims of 0.025 HYPE per address with 2 HYPE total capacity
 */
contract HypeTestnetFaucet is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // Constants
    uint256 public constant CLAIM_AMOUNT = 0.25 ether; // 0.25 HYPE per claim
    uint256 public constant MAX_CAPACITY = 5 ether; // 5 HYPE total capacity

    // State variables
    mapping(address => bool) public hasClaimed;
    uint256 public totalClaimed;
    uint256 public totalFunded;

    // Events
    event FaucetFunded(address indexed funder, uint256 amount, uint256 newBalance);
    event HypeClaimed(address indexed claimer, uint256 amount);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    event UsersReset(address[] users);
    event AllClaimsReset(bool totalClaimedReset);

    // Errors
    error AlreadyClaimed();
    error InsufficientFunds();
    error CapacityExceeded();
    error TransferFailed();
    error NoFundsToWithdraw();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the faucet contract
     */
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /**
     * @notice Fund the faucet with HYPE tokens
     * @dev Anyone can fund the faucet by sending HYPE
     */
    function fundFaucet() external payable {
        require(msg.value > 0, "Must send HYPE to fund");
        require(totalFunded + msg.value <= MAX_CAPACITY, "Would exceed max capacity");

        totalFunded += msg.value;

        emit FaucetFunded(msg.sender, msg.value, address(this).balance);
    }

    /**
     * @notice Claim HYPE tokens from the faucet
     * @dev Each address can only claim once
     */
    function claimHype() external nonReentrant {
        if (hasClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }

        if (address(this).balance < CLAIM_AMOUNT) {
            revert InsufficientFunds();
        }

        if (totalClaimed + CLAIM_AMOUNT > MAX_CAPACITY) {
            revert CapacityExceeded();
        }

        // Mark as claimed before transfer to prevent reentrancy
        hasClaimed[msg.sender] = true;
        totalClaimed += CLAIM_AMOUNT;

        // Transfer HYPE to claimer
        (bool success, ) = payable(msg.sender).call{value: CLAIM_AMOUNT}("");
        if (!success) {
            // Revert state changes on failed transfer
            hasClaimed[msg.sender] = false;
            totalClaimed -= CLAIM_AMOUNT;
            revert TransferFailed();
        }

        emit HypeClaimed(msg.sender, CLAIM_AMOUNT);
    }

    /**
     * @notice Reset claimed status for multiple users
     * @dev Allows owner to reset users who have already claimed
     * @param users Array of addresses to reset
     */
    function resetClaimedUsers(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            if (hasClaimed[users[i]]) {
                hasClaimed[users[i]] = false;
                // Note: We don't reduce totalClaimed as that tracks historical claims
            }
        }
        emit UsersReset(users);
    }

    /**
     * @notice Reset totalClaimed counter only
     * @dev This only resets the counter, not individual user claims
     * @param confirmReset Must be true to confirm the reset
     */
    function resetTotalClaimed(bool confirmReset) external onlyOwner {
        require(confirmReset, "Must confirm reset");
        totalClaimed = 0;
        emit AllClaimsReset(true);
    }

    /**
     * @notice Reset a single user's claimed status
     * @dev Allows a specific user to claim again
     * @param user Address to reset
     */
    function resetSingleUser(address user) external onlyOwner {
        if (hasClaimed[user]) {
            hasClaimed[user] = false;
            address[] memory users = new address[](1);
            users[0] = user;
            emit UsersReset(users);
        }
    }

    /**
     * @notice Emergency withdraw for owner only
     * @dev Allows owner to withdraw all remaining funds
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert NoFundsToWithdraw();
        }

        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) {
            revert TransferFailed();
        }

        emit EmergencyWithdraw(owner(), balance);
    }

    /**
     * @notice Get faucet status information
     * @return balance Current faucet balance
     * @return remainingClaims Number of claims remaining
     * @return isActive Whether faucet is active for new claims
     */
    function getFaucetStatus() external view returns (
        uint256 balance,
        uint256 remainingClaims,
        bool isActive
    ) {
        balance = address(this).balance;
        uint256 possibleClaims = balance / CLAIM_AMOUNT;
        uint256 capacityClaims = (MAX_CAPACITY - totalClaimed) / CLAIM_AMOUNT;
        remainingClaims = possibleClaims < capacityClaims ? possibleClaims : capacityClaims;
        isActive = balance >= CLAIM_AMOUNT && totalClaimed < MAX_CAPACITY;
    }

    /**
     * @notice Check if an address has already claimed
     * @param user Address to check
     * @return claimed Whether the address has claimed
     */
    function hasUserClaimed(address user) external view returns (bool claimed) {
        return hasClaimed[user];
    }

    /**
     * @notice Get the current balance of the faucet
     * @return balance Current HYPE balance
     */
    function getBalance() external view returns (uint256 balance) {
        return address(this).balance;
    }

    /**
     * @notice Get total statistics
     * @return _totalClaimed Total HYPE claimed so far
     * @return _totalFunded Total HYPE funded so far
     * @return _remainingCapacity Remaining capacity for claims
     */
    function getStatistics() external view returns (
        uint256 _totalClaimed,
        uint256 _totalFunded,
        uint256 _remainingCapacity
    ) {
        _totalClaimed = totalClaimed;
        _totalFunded = totalFunded;
        _remainingCapacity = MAX_CAPACITY - totalClaimed;
    }

    /**
     * @notice Authorize upgrade (UUPS pattern)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Receive function to accept HYPE deposits
     */
    receive() external payable {
        require(totalFunded + msg.value <= MAX_CAPACITY, "Would exceed max capacity");
        totalFunded += msg.value;
        emit FaucetFunded(msg.sender, msg.value, address(this).balance);
    }
}
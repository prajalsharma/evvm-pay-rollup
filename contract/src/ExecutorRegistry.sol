// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title ExecutorRegistry
/// @notice Authorised executors call executeIntent which burns credits and emits IntentExecuted.
/// @dev This contract integrates with VirtualChainLedger and IntentManager.

import "@openzeppelin/contracts/access/AccessControl.sol";

interface IVirtualChainLedger {
    function burnCredits(address user, uint256 amount, uint256 intentId) external;
}

interface IIntentManager {
    enum IntentStatus {
        None,
        Pending,
        Verified,
        Executed,
        Settled,
        Cancelled
    }
    function getIntent(uint256 intentId)
        external
        view
        returns (
            uint256 id,
            address user,
            uint16 destChainId,
            address destAddress,
            uint256 amount,
            uint64 nonce,
            bytes32 srcTx,
            IIntentManager.IntentStatus status,
            uint256 createdAt
        );
    function updateIntentStatus(uint256 intentId, IntentStatus status) external;
}

contract ExecutorRegistry is AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IVirtualChainLedger public ledger;
    IIntentManager public intentManager;

    event IntentExecuted(
        uint256 indexed intentId,
        address indexed executor,
        address indexed user,
        uint256 amount,
        uint16 destChainId,
        bytes32 srcTx
    );

    constructor(address admin, address _ledger, address _intentManager) {
        require(admin != address(0), "admin-zero");
        require(_ledger != address(0), "ledger-zero");
        require(_intentManager != address(0), "intentMgr-zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        ledger = IVirtualChainLedger(_ledger);
        intentManager = IIntentManager(_intentManager);
    }

    /// @notice Register executors (admin can add)
    function grantExecutor(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(EXECUTOR_ROLE, who);
    }

    /// @notice Execute an intent: burns credits and mark status Executed; emit IntentExecuted
    /// @dev Only authorized executors may call.
    function executeIntent(uint256 intentId) external onlyRole(EXECUTOR_ROLE) {
        // fetch intent details via intentManager.getIntent (tuple return)
        (
            uint256 id,
            address user,
            uint16 destChainId,
            address destAddress,
            uint256 amount,,
            bytes32 srcTx,
            IIntentManager.IntentStatus status,
        ) = intentManager.getIntent(intentId);

        require(id == intentId, "intent-not-found");
        require(
            status == IIntentManager.IntentStatus.Pending || status == IIntentManager.IntentStatus.Verified,
            "bad-status"
        );
        // burn credits on ledger (will revert on insufficient balance)
        ledger.burnCredits(user, amount, intentId);

        // mark executed
        intentManager.updateIntentStatus(intentId, IIntentManager.IntentStatus.Executed);

        emit IntentExecuted(intentId, msg.sender, user, amount, destChainId, srcTx);
    }
}

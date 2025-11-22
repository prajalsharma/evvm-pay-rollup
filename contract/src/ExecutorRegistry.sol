// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title ExecutorRegistry
/// @notice Authorised executors call executeIntent which burns credits and emits IntentExecuted.
/// @dev This version is aligned to the IntentManager and VirtualChainLedger contracts you provided:
///      - IntentManager.getIntent(...) returns the full tuple (id,user,destChainId,destAddress,amount,nonce,srcTx,status,createdAt,signatureHash)
///      - VirtualChainLedger.burnCredits(address user, uint256 amount, uint256 intentId)
/// Notes:
///  - After deployment you MUST grant EXECUTOR_ROLE to this contract (or to the executor EOA) in VirtualChainLedger
///  - Also ensure IntentManager allows this contract to call updateIntentStatus (see notes in README/deploy script)
///  - The admin who deploys should call grantExecutor(...) to add executors (EOAs) if you want EOA executors rather than the Registry itself

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

    /// NOTE: this must match the returned tuple in your IntentManager.getIntent implementation
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
            uint256 createdAt,
            bytes32 signatureHash
        );

    function updateIntentStatus(uint256 intentId, IntentStatus status) external;
}

contract ExecutorRegistry is AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IVirtualChainLedger public immutable ledger;
    IIntentManager public immutable intentManager;

    event ExecutorGranted(address indexed who);
    event ExecutorRevoked(address indexed who);

    event IntentExecuted(
        uint256 indexed intentId,
        address indexed executor,
        address indexed user,
        uint256 amount,
        uint16 destChainId,
        bytes32 srcTx
    );

    /// @param admin initial admin (DEFAULT_ADMIN_ROLE) — a deployer/operator address
    /// @param _ledger address of VirtualChainLedger
    /// @param _intentManager address of IntentManager
    constructor(address admin, address _ledger, address _intentManager) {
        require(admin != address(0), "admin-zero");
        require(_ledger != address(0), "ledger-zero");
        require(_intentManager != address(0), "intentMgr-zero");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // By design, admin is not auto-granted EXECUTOR_ROLE — admin can add executors via grantExecutor

        ledger = IVirtualChainLedger(_ledger);
        intentManager = IIntentManager(_intentManager);
    }

    /// @notice Admin registers an executor EOA or contract that may call executeIntent().
    function grantExecutor(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(who != address(0), "zero");
        grantRole(EXECUTOR_ROLE, who);
        emit ExecutorGranted(who);
    }

    /// @notice Admin revokes executor
    function revokeExecutor(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(who != address(0), "zero");
        revokeRole(EXECUTOR_ROLE, who);
        emit ExecutorRevoked(who);
    }

    /// @notice Execute an intent: burns credits and mark status Executed; emit IntentExecuted
    /// @dev Only callers with EXECUTOR_ROLE can call.
    ///      This function expects IntentManager.getIntent to return the tuple matching IIntentManager above.
    function executeIntent(uint256 intentId) external onlyRole(EXECUTOR_ROLE) {
        // fetch intent details via intentManager.getIntent (tuple return)
        (
            uint256 id,
            address user,
            uint16 destChainId,
            address destAddress,
            uint256 amount,
            uint64 nonce,
            bytes32 srcTx,
            IIntentManager.IntentStatus status,
            uint256 createdAt,
            bytes32 signatureHash
        ) = intentManager.getIntent(intentId);

        require(id == intentId, "intent-not-found");
        require(user != address(0), "user-zero");
        require(destAddress != address(0), "dest-zero");
        require(amount > 0, "amount-zero");

        // only allow execution from Pending or Verified (adjust if you want other allowed states)
        require(
            status == IIntentManager.IntentStatus.Pending || status == IIntentManager.IntentStatus.Verified,
            "bad-status"
        );

        // Burn credits on the ledger. This will revert on insufficient balance.
        // Note: burnCredits is protected by EXECUTOR_ROLE on the ledger; make sure the ledger grants EXECUTOR_ROLE
        // to either this contract address OR the caller. Recommended: grant EXECUTOR_ROLE on ledger to this ExecutorRegistry contract.
        ledger.burnCredits(user, amount, intentId);

        // Mark the intent executed on the IntentManager.
        // Important: IntentManager.updateIntentStatus must allow this contract (or the executor) to call this.
        intentManager.updateIntentStatus(intentId, IIntentManager.IntentStatus.Executed);

        emit IntentExecuted(intentId, msg.sender, user, amount, destChainId, srcTx);
    }
}

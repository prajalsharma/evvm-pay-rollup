// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title VirtualChainLedger
/// @notice EVVM-compatible virtual-credit ledger with EIP-191 signature support and async nonce tracking.
/// @dev Supports both role-based and signature-based operations following EVVM patterns.
///      Use BRIDGE_ROLE to mint credits (bridge/relayer), EXECUTOR_ROLE to burn (executor/agent).
///      Implements EVVM async nonce pattern for replay protection.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract VirtualChainLedger is AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    mapping(address => uint256) private _balances;

    // EVVM async nonce tracking per user for credit operations
    mapping(address => uint64) public asyncNonces;

    // Track used signature hashes to prevent replay attacks
    mapping(bytes32 => bool) public usedSignatures;

    event CreditMinted(address indexed user, uint256 amount, bytes32 indexed srcTx, uint64 nonce);
    event CreditBurned(address indexed user, uint256 amount, uint256 intentId, uint64 nonce);
    event AsyncNonceUpdated(address indexed user, uint64 oldNonce, uint64 newNonce);

    constructor(address admin) {
        require(admin != address(0), "admin-zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint virtual credits for `user` via role-based access (called by bridge after deposit confirmation).
    function mintCredits(address user, uint256 amount, bytes32 srcTx) external onlyRole(BRIDGE_ROLE) {
        _mintCredits(user, amount, srcTx, 0);
    }

    /// @notice Mint credits with EIP-191 signature (EVVM-compatible pattern).
    /// @dev User signs mint request off-chain, bridge submits with signature.
    /// @param user The user receiving credits
    /// @param amount Amount to mint
    /// @param srcTx Source transaction hash
    /// @param nonce Async nonce (must be > current asyncNonces[user])
    /// @param signature EIP-191 signature from user
    function mintCreditsWithSignature(
        address user,
        uint256 amount,
        bytes32 srcTx,
        uint64 nonce,
        bytes calldata signature
    ) external {
        require(user != address(0), "user-zero");
        require(amount > 0, "amount-zero");
        require(nonce > asyncNonces[user], "nonce-too-low");

        // Build EIP-191 message hash for mint operation
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(this), "mintCredits", user, amount, srcTx, nonce))
            )
        );

        // Verify signature
        address signer = messageHash.recover(signature);
        require(signer == user, "invalid-signature");

        // Check for replay attacks
        require(!usedSignatures[messageHash], "signature-used");
        usedSignatures[messageHash] = true;

        // Update async nonce
        uint64 oldNonce = asyncNonces[user];
        asyncNonces[user] = nonce;
        emit AsyncNonceUpdated(user, oldNonce, nonce);

        _mintCredits(user, amount, srcTx, nonce);
    }

    /// @notice Internal function to mint credits (shared logic).
    function _mintCredits(address user, uint256 amount, bytes32 srcTx, uint64 nonce) internal {
        require(user != address(0), "user-zero");
        require(amount > 0, "amount-zero");
        _balances[user] += amount;
        emit CreditMinted(user, amount, srcTx, nonce);
    }

    /// @notice Burn credits when an intent is executed via role-based access (called by authorized executor).
    function burnCredits(address user, uint256 amount, uint256 intentId) external onlyRole(EXECUTOR_ROLE) {
        _burnCredits(user, amount, intentId, 0);
    }

    /// @notice Burn credits with EIP-191 signature (EVVM-compatible pattern).
    /// @dev User signs burn request off-chain, executor submits with signature.
    /// @param user The user whose credits are burned
    /// @param amount Amount to burn
    /// @param intentId Associated intent ID
    /// @param nonce Async nonce (must be > current asyncNonces[user])
    /// @param signature EIP-191 signature from user
    function burnCreditsWithSignature(
        address user,
        uint256 amount,
        uint256 intentId,
        uint64 nonce,
        bytes calldata signature
    ) external {
        require(user != address(0), "user-zero");
        require(amount > 0, "amount-zero");
        require(nonce > asyncNonces[user], "nonce-too-low");

        // Build EIP-191 message hash for burn operation
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(this), "burnCredits", user, amount, intentId, nonce))
            )
        );

        // Verify signature
        address signer = messageHash.recover(signature);
        require(signer == user, "invalid-signature");

        // Check for replay attacks
        require(!usedSignatures[messageHash], "signature-used");
        usedSignatures[messageHash] = true;

        // Update async nonce
        uint64 oldNonce = asyncNonces[user];
        asyncNonces[user] = nonce;
        emit AsyncNonceUpdated(user, oldNonce, nonce);

        _burnCredits(user, amount, intentId, nonce);
    }

    /// @notice Internal function to burn credits (shared logic).
    function _burnCredits(address user, uint256 amount, uint256 intentId, uint64 nonce) internal {
        require(user != address(0), "user-zero");
        require(amount > 0, "amount-zero");
        uint256 bal = _balances[user];
        require(bal >= amount, "insufficient-balance");
        unchecked {
            _balances[user] = bal - amount;
        }
        emit CreditBurned(user, amount, intentId, nonce);
    }

    /// @notice Read virtual balance (EVVM credit balance).
    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    /// @notice Get current async nonce for a user (EVVM pattern).
    function getAsyncNonce(address user) external view returns (uint64) {
        return asyncNonces[user];
    }

    /// @notice Compute EIP-191 message hash for mint operation (for off-chain signing).
    function computeMintHash(address user, uint256 amount, bytes32 srcTx, uint64 nonce)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(this), "mintCredits", user, amount, srcTx, nonce))
            )
        );
    }

    /// @notice Compute EIP-191 message hash for burn operation (for off-chain signing).
    function computeBurnHash(address user, uint256 amount, uint256 intentId, uint64 nonce)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(this), "burnCredits", user, amount, intentId, nonce))
            )
        );
    }

    /// @notice Add or revoke bridge role (admin only).
    function grantBridgeRole(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(BRIDGE_ROLE, who);
    }

    function revokeBridgeRole(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(BRIDGE_ROLE, who);
    }

    /// @notice Add or revoke executor role (admin only).
    function grantExecutorRole(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(EXECUTOR_ROLE, who);
    }

    function revokeExecutorRole(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(EXECUTOR_ROLE, who);
    }
}

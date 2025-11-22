// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title IntentManager
/// @notice EVVM-compatible intent registry for cross-chain transfers with EIP-191 signature support.
/// @dev Each intent gets an incrementing id. Supports both role-based and signature-based creation.
///      Follows EVVM patterns for async nonce handling and replay protection.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract IntentManager is AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    // EVVM async nonce tracking per user
    mapping(address => uint64) public asyncNonces;

    // Track used signature hashes to prevent replay attacks
    mapping(bytes32 => bool) public usedSignatures;

    enum IntentStatus {
        None,
        Pending,
        Verified,
        Executed,
        Settled,
        Cancelled
    }

    struct Intent {
        uint256 id;
        address user; // source user who owns credits
        uint16 destChainId;
        address destAddress;
        uint256 amount; // amount in token units or credits
        uint64 nonce;
        bytes32 srcTx; // optional source tx hash
        IntentStatus status;
        uint256 createdAt;
        bytes32 signatureHash; // EIP-191 signature hash for verification
    }

    uint256 public nextIntentId;
    mapping(uint256 => Intent) public intents;
    mapping(address => uint256[]) public intentsByUser;

    event IntentCreated(
        uint256 indexed intentId,
        address indexed user,
        uint16 destChainId,
        address destAddress,
        uint256 amount,
        uint64 nonce,
        bytes32 srcTx
    );
    event IntentStatusUpdated(uint256 indexed intentId, IntentStatus status);
    event AsyncNonceUpdated(address indexed user, uint64 oldNonce, uint64 newNonce);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CREATOR_ROLE, admin);
    }

    /// @notice Create a new intent via role-based access (for trusted contracts/relayers).
    /// @dev Caller must be in CREATOR_ROLE (typically the dApp or user via meta-tx).
    function createIntent(
        address user,
        uint16 destChainId,
        address destAddress,
        uint256 amount,
        uint64 nonce,
        bytes32 srcTx
    ) external onlyRole(CREATOR_ROLE) returns (uint256) {
        return _createIntent(user, destChainId, destAddress, amount, nonce, srcTx, bytes32(0));
    }

    /// @notice Create intent with EIP-191 signature (EVVM-compatible pattern).
    /// @dev User signs the intent payload off-chain, relayer submits with signature.
    ///      Follows EVVM signature-based authorization pattern.
    /// @param user The user creating the intent
    /// @param destChainId Destination chain ID
    /// @param destAddress Destination address
    /// @param amount Amount to transfer
    /// @param nonce Async nonce (must be > current asyncNonces[user])
    /// @param srcTx Optional source transaction hash
    /// @param signature EIP-191 signature from user
    function createIntentWithSignature(
        address user,
        uint16 destChainId,
        address destAddress,
        uint256 amount,
        uint64 nonce,
        bytes32 srcTx,
        bytes calldata signature
    ) external returns (uint256) {
        require(user != address(0), "user-zero");
        require(destAddress != address(0), "dest-zero");
        require(amount > 0, "amount-zero");
        require(nonce > asyncNonces[user], "nonce-too-low");

        // Build EIP-191 message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(block.chainid, address(this), user, destChainId, destAddress, amount, nonce, srcTx)
                )
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

        return _createIntent(user, destChainId, destAddress, amount, nonce, srcTx, messageHash);
    }

    /// @notice Internal function to create intent (shared logic).
    function _createIntent(
        address user,
        uint16 destChainId,
        address destAddress,
        uint256 amount,
        uint64 nonce,
        bytes32 srcTx,
        bytes32 signatureHash
    ) internal returns (uint256) {
        require(user != address(0), "user-zero");
        require(destAddress != address(0), "dest-zero");
        require(amount > 0, "amount-zero");

        uint256 id = ++nextIntentId;
        Intent memory it = Intent({
            id: id,
            user: user,
            destChainId: destChainId,
            destAddress: destAddress,
            amount: amount,
            nonce: nonce,
            srcTx: srcTx,
            status: IntentStatus.Pending,
            createdAt: block.timestamp,
            signatureHash: signatureHash
        });
        intents[id] = it;
        intentsByUser[user].push(id);
        emit IntentCreated(id, user, destChainId, destAddress, amount, nonce, srcTx);
        emit IntentStatusUpdated(id, IntentStatus.Pending);
        return id;
    }

    /// @notice Get intent details by ID.
    function getIntent(uint256 intentId) external view returns (Intent memory) {
        return intents[intentId];
    }

    /// @notice Get current async nonce for a user (EVVM pattern).
    function getAsyncNonce(address user) external view returns (uint64) {
        return asyncNonces[user];
    }

    /// @notice Update intent status (admin/executor only).
    function updateIntentStatus(uint256 intentId, IntentStatus status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(intents[intentId].id != 0, "no-intent");
        intents[intentId].status = status;
        emit IntentStatusUpdated(intentId, status);
    }

    /// @notice Get all intent IDs for a user.
    function getIntentsByUser(address user) external view returns (uint256[] memory) {
        return intentsByUser[user];
    }

    /// @notice Helper: owner can add CREATOR_ROLE to other contract (for UI backend or meta-tx relayer).
    function grantCreatorRole(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CREATOR_ROLE, who);
    }

    /// @notice Compute EIP-191 message hash for intent creation (for off-chain signing).
    /// @dev This helps frontends/agents construct the correct message to sign.
    function computeIntentHash(
        address user,
        uint16 destChainId,
        address destAddress,
        uint256 amount,
        uint64 nonce,
        bytes32 srcTx
    ) external view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(block.chainid, address(this), user, destChainId, destAddress, amount, nonce, srcTx)
                )
            )
        );
    }
}

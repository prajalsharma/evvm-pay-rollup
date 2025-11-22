// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title BridgeReceiver
/// @notice Destination-side contract to settle hyperlane messages by releasing pre-funded ERC20 to recipient.
/// @dev Relayer or Hyperlane mailbox should be authorized to call settleFunds.

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract BridgeReceiver is AccessControl {
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    IERC20 public token; // pre-funded token (e.g., USDC on destination)
    mapping(uint256 => bool) public settled;

    event Settled(uint256 indexed intentId, address indexed user, uint256 amount, bytes32 srcTx);

    constructor(address admin, address tokenAddr) {
        require(admin != address(0), "admin-zero");
        require(tokenAddr != address(0), "token-zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        token = IERC20(tokenAddr);
    }

    /// @notice settleFunds is called by an authorized relayer (Hyperlane mailbox or relayer service)
    function settleFunds(uint256 intentId, address user, uint256 amount, bytes32 srcTx)
        external
        onlyRole(RELAYER_ROLE)
    {
        require(!settled[intentId], "already-settled");
        require(user != address(0), "user-zero");
        require(amount > 0, "amount-zero");
        settled[intentId] = true;
        // transfer token to the user. The contract must be pre-funded with tokens.
        bool ok = token.transfer(user, amount);
        require(ok, "transfer-failed");
        emit Settled(intentId, user, amount, srcTx);
    }

    /// owner/admin can fund contract by transferring tokens directly.
    function grantRelayer(address who) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(RELAYER_ROLE, who);
    }
}

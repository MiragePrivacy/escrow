// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice The first eligible delivery block is the block after this escrow was deployed.
/// @dev The existing circuits call their exclusive payment lower bound `bondStartBlock`.
/// The actual reservation block remains separate and the witness must still follow it.
abstract contract ZkPaymentWindow {
    uint64 public immutable paymentStartBlock = uint64(block.number);
}

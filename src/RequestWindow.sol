// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Funding starts one request clock. Reservations and retries cannot
/// extend the payment or redemption windows.
/// @dev The existing circuits authenticate payment block numbers, not payment
/// timestamps. The 75-block payment cutoff remains part of their statement;
/// timestamp admission and a separate redemption cutoff are checked on-chain.
abstract contract RequestWindow {
    error RequestAlreadyStarted();
    error PaymentWindowClosed();
    error CollectionWindowClosed();
    error RedemptionWindowActive();

    uint256 public constant PAYMENT_WINDOW = 15 minutes;
    uint256 public constant COLLECTION_WINDOW = 30 minutes;
    uint256 public constant PAYMENT_WINDOW_BLOCKS = 75;
    uint256 public constant COLLECTION_WINDOW_BLOCKS = 150;

    // Reserve five slots beyond the legacy layout. A short literal keeps the
    // constructor and runtime storage accesses visible to the obfuscator.
    // Prefix 0x01 plus the domain hash's first 128 bits, aligned to eight slots.
    uint256 private constant WINDOW_SLOT = 0x014ac5509487808893ddf697b19b08bdb0;

    struct Window {
        uint256 requestStartedAt;
        uint256 paymentDeadline;
        uint256 collectionDeadline;
        uint256 paymentBlockDeadline;
        uint256 collectionBlockDeadline;
    }

    function _window() private pure returns (Window storage state) {
        uint256 slot = WINDOW_SLOT;
        assembly {
            state.slot := slot
        }
    }

    function requestStartedAt() public view returns (uint256) {
        return _window().requestStartedAt;
    }

    function paymentDeadline() public view returns (uint256) {
        return _window().paymentDeadline;
    }

    function collectionDeadline() public view returns (uint256) {
        return _window().collectionDeadline;
    }

    function paymentBlockDeadline() public view returns (uint256) {
        return _window().paymentBlockDeadline;
    }

    function collectionBlockDeadline() public view returns (uint256) {
        return _window().collectionBlockDeadline;
    }

    /// Legacy plaintext escrows retain their original lease policy.
    function _usesRequestWindow() internal pure virtual returns (bool) {
        return false;
    }

    function _hasRequestWindow() internal view returns (bool) {
        return collectionDeadline() != 0;
    }

    function _initializeRequestWindow() internal {
        if (!_usesRequestWindow()) return;
        Window storage state = _window();
        if (state.collectionDeadline != 0) revert RequestAlreadyStarted();
        state.requestStartedAt = block.timestamp;
        state.paymentDeadline = block.timestamp + PAYMENT_WINDOW;
        state.collectionDeadline = block.timestamp + COLLECTION_WINDOW;
        state.paymentBlockDeadline = block.number + PAYMENT_WINDOW_BLOCKS;
        state.collectionBlockDeadline = block.number + COLLECTION_WINDOW_BLOCKS;
    }

    function _requirePaymentWindow() internal view {
        if (_hasRequestWindow() && (block.timestamp >= paymentDeadline() || block.number > paymentBlockDeadline())) {
            revert PaymentWindowClosed();
        }
    }

    function _requireCollectionWindow() internal view {
        if (
            _hasRequestWindow() && (block.timestamp >= collectionDeadline() || block.number > collectionBlockDeadline())
        ) revert CollectionWindowClosed();
    }

    /// Refunds wait for the wall-clock redemption cutoff even when a fast
    /// chain has already passed the conservative collection block bound.
    function _requireRefundWindow() internal view {
        if (_hasRequestWindow() && block.timestamp < collectionDeadline()) revert RedemptionWindowActive();
    }
}

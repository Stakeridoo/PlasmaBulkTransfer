// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PlasmaBulkSender
 * @notice Batch-sends native XPL or ERC-20 with a percentage fee (same asset).
 *         Fee = ceil(total * feeBps / 10_000)  (rounds up).
 *
 * Security & features:
 * - nonReentrant guard
 * - zero-address checks
 * - SafeERC20-lite (supports non-standard ERC20 returning no/false)
 * - Timelocked fee updates (two-step, configurable min delay)
 * - Fee-on-transfer handling via token whitelist (if marked, balance-delta check)
 * - MAX_RECIPIENTS cap + configurable maxRecipients (≤ cap)
 * - Two modes:
 *    1) Atomic: reverts on any failure (predictable UX)
 *    2) AllowFailures: continues; refunds failed amounts + excess fee
 */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/* ---------- SafeERC20-lite: robust & gas-reasonable ---------- */
library SafeERC20Lite {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory ret) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "SafeERC20: transferFrom failed");
    }

    // non-reverting try-variant for allowFailures
    function tryTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}

contract PlasmaBulkSenderPercentFeeV3 {
    using SafeERC20Lite for IERC20;

    /* ---------------- Constants ---------------- */
    uint16  public constant MAX_FEE_BPS      = 500;     // 5%
    uint256 public constant FEE_DENOMINATOR  = 10_000;
    uint256 public constant MIN_DELAY_FLOOR  = 1 hours;
    uint256 public constant MAX_DELAY_CEIL   = 7 days;
    uint256 public constant MAX_RECIPIENTS   = 400;

    /* ---------------- Ownership ---------------- */
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    /* ---------------- Reentrancy ---------------- */
    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    /* ---------------- Pause ---------------- */
    bool public paused;
    modifier whenNotPaused() { require(!paused, "paused"); _; }

    /* ---------------- Fee config ---------------- */
    uint16  public feeBps;             // e.g. 10 => 0.10%
    address public feeRecipient;

    // Two-step with timelock
    uint16  public pendingFeeBps;
    address public pendingFeeRecipient;
    uint256 public feeChangeEta;
    uint256 public minFeeDelay;        // configurable (e.g., 24h)

    /* ---------------- Limits ---------------- */
    uint256 public maxRecipients;       // must be ≤ MAX_RECIPIENTS

    /* ---------------- Fee-on-transfer whitelist ---------------- */
    mapping(address => bool) public isFeeOnTransferToken;

    /* ---------------- Events ---------------- */
    event FeesUpdated(uint16 feeBps, address indexed feeRecipient);
    event FeeUpdateStarted(uint16 newFeeBps, address indexed newFeeRecipient, uint256 eta);
    event LimitsUpdated(uint256 maxRecipients);
    event Paused();
    event Unpaused();

    event ERC20BatchSent(
        address indexed token,
        address indexed from,
        uint256 recipients,
        uint256 totalAmount,
        uint256 feeAmount
    );
    event ERC20BatchSentPartial(
        address indexed token,
        address indexed from,
        uint256 requestedRecipients,
        uint256 sentRecipients,
        uint256 sentTotal,
        uint256 feeCharged,
        uint256 refunded
    );
    event FailedTransfer(address indexed to, uint256 amount);

    event NativeBatchSent(
        address indexed from,
        uint256 recipients,
        uint256 totalAmountWei,
        uint256 feeWei
    );

    event EmergencyTokenSweep(address indexed token, address indexed to, uint256 amount);
    event EmergencyNativeSweep(address indexed to, uint256 amount);

    /* ---------------- Constructor ---------------- */
    constructor(
        uint16 _feeBps,
        address _feeRecipient,
        uint256 _maxRecipients,
        uint256 _minFeeDelay
    ) {
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_feeBps <= MAX_FEE_BPS, "fee too high");
        require(_maxRecipients > 0 && _maxRecipients <= MAX_RECIPIENTS, "maxRecipients invalid");
        require(_minFeeDelay >= MIN_DELAY_FLOOR && _minFeeDelay <= MAX_DELAY_CEIL, "feeDelay out of range");

        owner         = msg.sender;
        feeBps        = _feeBps;
        feeRecipient  = _feeRecipient;
        maxRecipients = _maxRecipients;
        minFeeDelay   = _minFeeDelay;

        emit FeesUpdated(feeBps, feeRecipient);
        emit LimitsUpdated(maxRecipients);
    }

    /* ---------------- Views ---------------- */
    /// @notice Returns the fee with ceil rounding: ceil(total*feeBps/10_000)
    function quoteFeeOnAmount(uint256 totalAmount) public view returns (uint256) {
        if (totalAmount == 0 || feeBps == 0) return 0;
        return (totalAmount * feeBps + (FEE_DENOMINATOR - 1)) / FEE_DENOMINATOR;
    }

    /* ---------------- Admin ---------------- */
    function pause() external onlyOwner { paused = true; emit Paused(); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(); }

    function setMaxRecipients(uint256 _maxRecipients) external onlyOwner {
        require(_maxRecipients > 0 && _maxRecipients <= MAX_RECIPIENTS, "maxRecipients invalid");
        maxRecipients = _maxRecipients;
        emit LimitsUpdated(maxRecipients);
    }

    function setFeeOnTransferToken(address token, bool isFoT) external onlyOwner {
        require(token != address(0), "token=0");
        isFeeOnTransferToken[token] = isFoT;
    }

    // two-step fee update with timelock
    function startFeeUpdate(uint16 _feeBps, address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_feeBps <= MAX_FEE_BPS, "fee too high");
        pendingFeeBps       = _feeBps;
        pendingFeeRecipient = _feeRecipient;
        feeChangeEta        = block.timestamp + minFeeDelay;
        emit FeeUpdateStarted(pendingFeeBps, pendingFeeRecipient, feeChangeEta);
    }

    function finalizeFeeUpdate() external onlyOwner {
        require(feeChangeEta != 0 && block.timestamp >= feeChangeEta, "not ready");
        feeBps       = pendingFeeBps;
        feeRecipient = pendingFeeRecipient;
        pendingFeeBps = 0;
        pendingFeeRecipient = address(0);
        feeChangeEta = 0;
        emit FeesUpdated(feeBps, feeRecipient);
    }

    /* ---------------- Core: Native (atomic) ---------------- */
    function sendNative(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external payable whenNotPaused nonReentrant {
        uint256 n = recipients.length;
        require(n == amounts.length && n > 0, "len mismatch");
        require(n <= maxRecipients, "too many recipients");

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            address to = recipients[i];
            require(to != address(0), "zero address");
            total += amounts[i];
        }

        uint256 fee = quoteFeeOnAmount(total);
        require(msg.value == total + fee, "msg.value != total+fee");

        // fee out
        if (fee > 0) {
            (bool okFee, ) = payable(feeRecipient).call{value: fee}("");
            require(okFee, "fee transfer failed");
        }

        // distribute
        for (uint256 i = 0; i < n; ++i) {
            (bool ok, ) = payable(recipients[i]).call{value: amounts[i]}("");
            require(ok, "native transfer failed");
        }

        emit NativeBatchSent(msg.sender, n, total, fee);
    }

    /* ---------------- Core: ERC-20 (atomic) ---------------- */
    function sendERC20(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant {
        require(token != address(0), "token=0");
        uint256 n = recipients.length;
        require(n == amounts.length && n > 0, "len mismatch");
        require(n <= maxRecipients, "too many recipients");

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            address to = recipients[i];
            require(to != address(0), "zero address");
            total += amounts[i];
        }

        uint256 fee = quoteFeeOnAmount(total);
        IERC20 erc = IERC20(token);

        if (isFeeOnTransferToken[token]) {
            uint256 beforeBal = erc.balanceOf(address(this));
            erc.safeTransferFrom(msg.sender, address(this), total + fee);
            uint256 got = erc.balanceOf(address(this)) - beforeBal;
            require(got >= total + fee, "fee-on-transfer token");
        } else {
            erc.safeTransferFrom(msg.sender, address(this), total + fee);
        }

        if (fee > 0) {
            erc.safeTransfer(feeRecipient, fee);
        }

        for (uint256 i = 0; i < n; ++i) {
            erc.safeTransfer(recipients[i], amounts[i]);
        }

        emit ERC20BatchSent(token, msg.sender, n, total, fee);
    }

    /* ---------------- Core: ERC-20 (allow failures + fair refund) ----------------
       - Pull max: total + feeMax (feeMax based on requested total).
       - Try sends; accumulate 'failedTotal' and 'sentCount/sentTotal'.
       - Compute feeActual on sentTotal; pay that; refund (failedTotal + (feeMax - feeActual)) to sender.
    ------------------------------------------------------------------------------*/
    function sendERC20AllowFailures(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant {
        require(token != address(0), "token=0");
        uint256 n = recipients.length;
        require(n == amounts.length && n > 0, "len mismatch");
        require(n <= maxRecipients, "too many recipients");

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            address to = recipients[i];
            require(to != address(0), "zero address");
            total += amounts[i];
        }

        IERC20 erc = IERC20(token);
        uint256 feeMax = quoteFeeOnAmount(total);

        if (isFeeOnTransferToken[token]) {
            uint256 beforeBal = erc.balanceOf(address(this));
            erc.safeTransferFrom(msg.sender, address(this), total + feeMax);
            uint256 got = erc.balanceOf(address(this)) - beforeBal;
            require(got >= total + feeMax, "fee-on-transfer token");
        } else {
            erc.safeTransferFrom(msg.sender, address(this), total + feeMax);
        }

        uint256 failedTotal = 0;
        uint256 sentTotal   = 0;
        uint256 sentCount   = 0;

        for (uint256 i = 0; i < n; ++i) {
            uint256 amt = amounts[i];
            if (erc.tryTransfer(recipients[i], amt)) {
                sentTotal += amt;
                unchecked { sentCount++; }
            } else {
                failedTotal += amt;
                emit FailedTransfer(recipients[i], amt);
            }
        }

        // Fee nur auf tatsächlich gesendete Summe
        uint256 feeActual = quoteFeeOnAmount(sentTotal);
        if (feeActual > 0) {
            erc.safeTransfer(feeRecipient, feeActual);
        }

        // Refund: (total + feeMax) - (sentTotal + feeActual)
        uint256 refund = (total + feeMax) - (sentTotal + feeActual);
        if (refund > 0) {
            erc.safeTransfer(msg.sender, refund);
        }

        emit ERC20BatchSentPartial(token, msg.sender, n, sentCount, sentTotal, feeActual, refund);
    }

    /* ---------------- Emergencies ---------------- */
    function emergencySweepToken(address token, address to) external onlyOwner {
        require(to != address(0), "to=0");
        IERC20 erc = IERC20(token);
        uint256 bal = erc.balanceOf(address(this));
        if (bal > 0) {
            erc.safeTransfer(to, bal);
            emit EmergencyTokenSweep(token, to, bal);
        }
    }

    function emergencySweepNative(address payable to) external onlyOwner {
        require(to != address(0), "to=0");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = to.call{value: bal}("");
            require(ok, "sweep native failed");
            emit EmergencyNativeSweep(to, bal);
        }
    }

    /* ---------------- Pause receive ---------------- */
    receive() external payable {}
}

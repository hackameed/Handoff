// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/* -------------------------------------------------------------------------- */
/*                                Interfaces                                  */
/* -------------------------------------------------------------------------- */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Mezo signature-authorised entrypoint (EIP-712).
///      Live at 0xD757e3646AF370b15f32EB557F0F8380Df7D639e on Mezo Testnet.
interface IBorrowerOperationsSignatures {
    function closeTroveWithSignature(
        address _borrower,
        address _recipient,
        bytes memory _signature,
        uint256 _deadline
    ) external;

    function openTroveWithSignature(
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint,
        address _borrower,
        address _recipient,
        bytes memory _signature,
        uint256 _deadline
    ) external payable;
}

interface ITroveManager {
    function getTroveColl(address _borrower) external view returns (uint256);
    function getTroveDebt(address _borrower) external view returns (uint256);
    /// @return 0 = non-existent, 1 = active, 2 = closed, 3 = liquidated
    function getTroveStatus(address _borrower) external view returns (uint256);
    /// @notice Applies accrued interest so `getTroveDebt` is current. Anyone may call.
    function updateSystemAndTroveInterest(address _borrower) external;
}

interface IPoolFactory {
    function getFee(address pool, bool stable) external view returns (uint256);
}

/// @dev Tigris is Uniswap-V2 shaped, NOT Basin. Callback is `hook`, not
///      `uniswapV2Call`. Verified against mezo-org/tigris solidity/contracts/Pool.sol.
interface ITigrisPool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external;

    function getReserves()
        external
        view
        returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

    function stable() external view returns (bool);
}

interface IPoolCallee {
    function hook(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/**
 * @title HandoffRouter
 * @notice Moves a native MUSD loan between two wallets the same borrower controls,
 *         atomically, without the borrower ever holding the MUSD needed to close
 *         the position first.
 *
 * @dev Mechanism (one flash, three protocol calls)
 *      1. Flash-borrow MUSD from the Tigris MUSD/mUSDC pool into this router.
 *      2. In the callback: `closeTroveWithSignature` on Wallet A, naming this
 *         router as BTC recipient. Mezo debits the MUSD from *this contract*,
 *         because the Signatures contract forwards itself as `_caller`.
 *      3. `openTroveWithSignature` on Wallet B, forwarding the released BTC,
 *         naming this router as MUSD recipient.
 *      4. Repay principal + fee to the pool; return the surplus to Wallet A.
 *
 *      The router computes the borrow amount and fee itself from live trove
 *      state. Callers cannot under- or over-state either, which removes an
 *      entire class of staleness bugs: Mezo settles the close against
 *      interest-accrued debt, so any off-chain quote is already stale.
 *
 *      Binding: the destination wallet's EIP-712 signature commits to the exact
 *      `assetAmount` (= `msg.value` in Mezo's OPEN_TROVE_TYPEHASH). Neither the
 *      router nor a relayer can redirect the collateral downstream.
 */
contract HandoffRouter is IPoolCallee {
    /* ---------------------------------------------------------------------- */
    /*                                 Errors                                 */
    /* ---------------------------------------------------------------------- */

    error NotPool();
    error NotCallbackPhase();
    error Reentrant();
    error SourceNotActive();
    error DestinationOccupied();
    error DuplicateWallets();
    error WrongChain(uint256 actual);
    error InsufficientLiquidity();
    error BtcMismatch();
    error SourceStillActive();
    error DestinationNotActive();
    error PrincipalNotReturned();
    error DeadlineTooFar();
    error QuoteExpired();
    error NothingToMove();
    error DrawTooSmall();
    error NativeFromUnexpectedSource();
    error ResidualValue();
    error TransferFailed();

    /* ---------------------------------------------------------------------- */
    /*                                 Events                                 */
    /* ---------------------------------------------------------------------- */

    event LoanMoved(
        address indexed sourceWallet,
        address indexed destinationWallet,
        uint256 collateral,
        uint256 payoff,
        uint256 replacementDebt,
        uint256 flashFee,
        uint256 changeToSource
    );

    /* ---------------------------------------------------------------------- */
    /*                                Constants                               */
    /* ---------------------------------------------------------------------- */

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DEADLINE_WINDOW = 1 hours;
    uint256 public constant TROVE_STATUS_ACTIVE = 1;
    // Mezo/Liquity trove states: 0 non-existent, 1 active, 2 closed by owner,
    // 3 closed by liquidation, 4 closed by redemption.
    /// @dev Mezo reserves this much MUSD per trove; it is never repayable.
    uint256 public constant GAS_COMPENSATION = 200e18;
    /// @dev Head-room over measured debt to absorb interest accrued inside the
    ///      flash transaction. 0.5% + 1 MUSD costs a fraction of a basis point
    ///      of flash fee, and is refunded to the source wallet as change.
    uint256 public constant BUFFER_BPS = 50;

    /* ---------------------------------------------------------------------- */
    /*                              Immutables                                */
    /* ---------------------------------------------------------------------- */

    uint256 public immutable EXPECTED_CHAIN_ID;
    address public immutable MUSD;
    address public immutable BORROWER_OPERATIONS_SIGNATURES;
    address public immutable TROVE_MANAGER;
    address public immutable ACTIVE_POOL;
    address public immutable POOL;
    address public immutable POOL_FACTORY;

    /* ---------------------------------------------------------------------- */
    /*                             Callback state                             */
    /* ---------------------------------------------------------------------- */

    struct Plan {
        address sourceWallet;
        address destinationWallet;
        uint256 collateral; // BTC released by the close and re-pledged
        uint256 payoff; // MUSD Mezo will debit (debt minus gas reserve)
        uint256 principal; // MUSD flash-borrowed
        uint256 fee;
        uint256 replacementDebt; // MUSD drawn on the destination
        uint256 deadline;
    }

    Plan private _plan;
    uint256 private _supplied; // optional BTC top-up from the caller
    uint8 private _phase; // 0 = idle, 1 = inside callback
    bool private _entered;

    /* ---------------------------------------------------------------------- */
    /*                              Constructor                               */
    /* ---------------------------------------------------------------------- */

    constructor(
        uint256 expectedChainId,
        address musd,
        address borrowerOperationsSignatures,
        address troveManager,
        address activePool,
        address pool,
        address poolFactory
    ) {
        EXPECTED_CHAIN_ID = expectedChainId;
        MUSD = musd;
        BORROWER_OPERATIONS_SIGNATURES = borrowerOperationsSignatures;
        TROVE_MANAGER = troveManager;
        ACTIVE_POOL = activePool;
        POOL = pool;
        POOL_FACTORY = poolFactory;
    }

    /// @dev BTC is only accepted from Mezo's ActivePool, and only mid-callback.
    receive() external payable {
        if (msg.sender != ACTIVE_POOL || _phase != 1) revert NativeFromUnexpectedSource();
    }

    /* ---------------------------------------------------------------------- */
    /*                              Entry point                               */
    /* ---------------------------------------------------------------------- */

    /**
     * @notice Move `msg.sender`'s loan to `destinationWallet`.
     * @param destinationWallet  Wallet B — must hold no trove, must have signed.
     * @param collateralToMove   BTC re-pledged. For a pure migration this is the
     *                           entire released collateral. Bound by Wallet B's
     *                           signature.
     * @param replacementDebt    MUSD drawn on Wallet B. Must cover the payoff,
     *                           the flash fee, and any change you want returned.
     * @param deadline           EIP-712 deadline shared by both signatures.
     */
    function moveLoan(
        address destinationWallet,
        uint256 collateralToMove,
        uint256 replacementDebt,
        uint256 deadline,
        bytes calldata closeSignature,
        bytes calldata openSignature
    ) external payable {
        if (_entered) revert Reentrant();
        _entered = true;

        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert QuoteExpired();
        if (deadline > block.timestamp + MAX_DEADLINE_WINDOW) revert DeadlineTooFar();
        if (destinationWallet == msg.sender) revert DuplicateWallets();
        if (collateralToMove == 0) revert NothingToMove();
        if (_phase != 0) revert NotCallbackPhase();

        ITroveManager tm = ITroveManager(TROVE_MANAGER);
        if (tm.getTroveStatus(msg.sender) != TROVE_STATUS_ACTIVE) revert SourceNotActive();
        // The destination must not hold a live loan. A previously-closed trove
        // is fine: the protocol only forbids opening over an active one.
        if (tm.getTroveStatus(destinationWallet) == TROVE_STATUS_ACTIVE) {
            revert DestinationOccupied();
        }

        // Measure repayable debt from live state. Mezo's close settles against
        // interest-accrued debt, so we apply interest first and then add buffer.
        tm.updateSystemAndTroveInterest(msg.sender);
        uint256 trueDebt = tm.getTroveDebt(msg.sender);
        uint256 payoff = trueDebt > GAS_COMPENSATION ? trueDebt - GAS_COMPENSATION : 0;
        uint256 principal = payoff + (payoff * BUFFER_BPS) / BPS + 1e18;
        uint256 fee = flashFeeFor(principal);

        // The draw must at least service the payoff and the flash fee, else the
        // pool cannot be made whole and the whole call would revert later.
        if (replacementDebt < payoff + fee) revert DrawTooSmall();

        _plan = Plan({
            sourceWallet: msg.sender,
            destinationWallet: destinationWallet,
            collateral: collateralToMove,
            payoff: payoff,
            principal: principal,
            fee: fee,
            replacementDebt: replacementDebt,
            deadline: deadline
        });

        _supplied = msg.value;

        (uint256 r0,,) = ITigrisPool(POOL).getReserves();
        if (r0 < principal) revert InsufficientLiquidity();

        ITigrisPool(POOL).swap(
            principal, 0, address(this), abi.encode(closeSignature, openSignature)
        );

        // ---- Post-conditions after the callback completed. ------------------
        if (tm.getTroveStatus(msg.sender) == TROVE_STATUS_ACTIVE) revert SourceStillActive();
        if (tm.getTroveStatus(destinationWallet) != TROVE_STATUS_ACTIVE) {
            revert DestinationNotActive();
        }
        if (address(this).balance != 0) revert ResidualValue();
        if (IERC20(MUSD).balanceOf(address(this)) != 0) revert PrincipalNotReturned();

        delete _plan;
        _entered = false;
        _phase = 0;
    }

    /* ---------------------------------------------------------------------- */
    /*                              Pool callback                             */
    /* ---------------------------------------------------------------------- */

    function hook(address, uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (msg.sender != POOL) revert NotPool();
        if (_phase != 0) revert NotCallbackPhase();
        if (amount1 != 0) revert BtcMismatch();
        if (amount0 != _plan.principal) revert BtcMismatch();

        (bytes memory closeSignature, bytes memory openSignature) =
            abi.decode(data, (bytes, bytes));

        Plan memory p = _plan;
        uint256 supplied = _supplied;
        _supplied = 0;
        _phase = 1;

        // ---- Step 2: close the source. Mezo debits MUSD from this router,
        //              and sends the collateral here. --------------------------
        uint256 btcBefore = address(this).balance;
        IBorrowerOperationsSignatures(BORROWER_OPERATIONS_SIGNATURES).closeTroveWithSignature(
            p.sourceWallet, address(this), closeSignature, p.deadline
        );
        uint256 btcReceived = address(this).balance - btcBefore;
        if (btcReceived != p.collateral) revert BtcMismatch();

        // ---- Step 3: open the destination with the released collateral. -----
        // Pure migration: destValue == released collateral. Top-up mode: the
        // caller's msg.value is added. The destination's signature commits to
        // this exact amount, so it cannot be altered downstream.
        uint256 destValue = p.collateral + supplied;

        IBorrowerOperationsSignatures(BORROWER_OPERATIONS_SIGNATURES).openTroveWithSignature{
            value: destValue
        }(
            p.replacementDebt,
            address(0),
            address(0),
            p.destinationWallet,
            address(this),
            openSignature,
            p.deadline
        );

        // ---- Step 4: repay the pool; return surplus to the source. ----------
        _phase = 0;

        uint256 owed = p.principal + p.fee;
        uint256 musdBalance = IERC20(MUSD).balanceOf(address(this));
        if (musdBalance < owed) revert PrincipalNotReturned();

        if (!IERC20(MUSD).transfer(POOL, owed)) revert TransferFailed();

        uint256 change = musdBalance - owed;
        if (change > 0) {
            if (!IERC20(MUSD).transfer(p.sourceWallet, change)) revert TransferFailed();
        }

        emit LoanMoved(
            p.sourceWallet,
            p.destinationWallet,
            destValue,
            p.payoff,
            p.replacementDebt,
            p.fee,
            change
        );
    }

    /* ---------------------------------------------------------------------- */
    /*                                 Views                                  */
    /* ---------------------------------------------------------------------- */

    /// @notice Tigris charges ceil(principal * r / (BPS - r)); matches the pool's
    ///         own rounding so repayment is never a wei short.
    function flashFeeFor(uint256 principal) public view returns (uint256) {
        uint256 r = IPoolFactory(POOL_FACTORY).getFee(POOL, ITigrisPool(POOL).stable());
        if (r == 0) return 0;
        return (principal * r + (BPS - r) - 1) / (BPS - r);
    }

    function poolFeeBps() external view returns (uint256) {
        return IPoolFactory(POOL_FACTORY).getFee(POOL, ITigrisPool(POOL).stable());
    }

    /// @notice What a migration would cost right now, without executing it.
    function preview(address sourceWallet, uint256 replacementDebt)
        external
        view
        returns (
            uint256 collateral,
            uint256 payoff,
            uint256 principal,
            uint256 fee,
            uint256 changeToSource
        )
    {
        collateral = ITroveManager(TROVE_MANAGER).getTroveColl(sourceWallet);
        uint256 debt = ITroveManager(TROVE_MANAGER).getTroveDebt(sourceWallet);
        payoff = debt > GAS_COMPENSATION ? debt - GAS_COMPENSATION : 0;
        principal = payoff + (payoff * BUFFER_BPS) / BPS + 1e18;
        fee = flashFeeFor(principal);
        changeToSource = replacementDebt > payoff + fee ? replacementDebt - payoff - fee : 0;
    }

    function sourceCollateral(address wallet) external view returns (uint256) {
        return ITroveManager(TROVE_MANAGER).getTroveColl(wallet);
    }

    function troveStatus(address wallet) external view returns (uint256) {
        return ITroveManager(TROVE_MANAGER).getTroveStatus(wallet);
    }
}

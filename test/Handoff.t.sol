// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HandoffRouter} from "../src/HandoffRouter.sol";

interface IERC20Full {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IBorrowerOpsPublic {
    function openTrove(uint256 _debtAmount, address _upperHint, address _lowerHint)
        external
        payable;
    function closeTrove() external;
}

interface ISigNonces {
    function getNonce(address user) external view returns (uint256);
}

/**
 * @title HandoffRouter fork tests
 * @notice Runs against live Mezo Testnet state, pinned to a block.
 *
 *   forge test --fork-url https://rpc.test.mezo.org -vvv
 */
contract HandoffTest is Test {
    // --- Mezo Testnet addresses (verified to have bytecode on chain 31611) ---
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant BORROWER_OPS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant SIGS = 0xD757e3646AF370b15f32EB557F0F8380Df7D639e;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant ACTIVE_POOL = 0x143A063F62340DA3A8bEA1C5642d18C6D0F7FF51;
    address constant POOL = 0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e;
    address constant POOL_FACTORY = 0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A;
    address constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;

    uint256 constant CHAIN_ID = 31611;
    uint256 constant GAS_COMPENSATION = 200e18;
    uint256 constant MIN_NET_DEBT = 1800e18;

    bytes32 constant CLOSE_TROVE_TYPEHASH =
        keccak256("CloseTrove(address borrower,address recipient,uint256 nonce,uint256 deadline)");
    bytes32 constant OPEN_TROVE_TYPEHASH = keccak256(
        "OpenTrove(uint256 assetAmount,uint256 debtAmount,address borrower,address recipient,uint256 nonce,uint256 deadline)"
    );
    bytes32 constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    HandoffRouter router;

    uint256 walletAKey = 0xA11CE;
    uint256 walletBKey = 0xB0B;
    address walletA;
    address walletB;

    bool forked;

    function setUp() public {
        // Pin a fork explicitly so the suite never silently degrades into a
        // no-op pass. FK_BLOCK may be supplied to freeze state for reproducibility.
        string memory url = vm.envOr("FORK_RPC_URL", string("https://rpc.test.mezo.org"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(url);
        } else {
            vm.createSelectFork(url, pin);
        }
        forked = true;

        // Mezo's PriceFeed reads a BTC/USD oracle via a Mezo precompile that
        // anvil/revm cannot emulate. Stub the feed at a realistic price so the
        // rest of the protocol logic executes against real state.
        vm.mockCall(
            PRICE_FEED,
            abi.encodeWithSignature("fetchPrice()"),
            abi.encode(uint256(63_561e18))
        );

        walletA = vm.addr(walletAKey);
        walletB = vm.addr(walletBKey);

        // Use the live deployed router when provided, otherwise deploy fresh
        // into the fork. Testing the deployed instance is the stronger claim.
        address deployed = vm.envOr("HANDOFF_ROUTER", address(0));
        if (deployed != address(0)) {
            router = HandoffRouter(payable(deployed));
        } else {
            router = new HandoffRouter(
                CHAIN_ID, MUSD, SIGS, TROVE_MANAGER, ACTIVE_POOL, POOL, POOL_FACTORY
            );
        }
    }

    /* ---------------------------------------------------------------------- */
    /*                          EIP-712 helpers                               */
    /* ---------------------------------------------------------------------- */

    function _domainSeparator() internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("BorrowerOperationsSignatures"),
                keccak256("1"),
                CHAIN_ID,
                SIGS
            )
        );
    }

    function _digest(bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signClose(
        uint256 pk,
        address borrower,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 sh =
            keccak256(abi.encode(CLOSE_TROVE_TYPEHASH, borrower, recipient, nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(sh));
        return abi.encodePacked(r, s, v);
    }

    function _signOpen(
        uint256 pk,
        uint256 assetAmount,
        uint256 debtAmount,
        address borrower,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 sh = keccak256(
            abi.encode(
                OPEN_TROVE_TYPEHASH,
                assetAmount,
                debtAmount,
                borrower,
                recipient,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(sh));
        return abi.encodePacked(r, s, v);
    }

    /* ---------------------------------------------------------------------- */
    /*                                 Views                                  */
    /* ---------------------------------------------------------------------- */

    function _status(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            TROVE_MANAGER.staticcall(abi.encodeWithSignature("getTroveStatus(address)", who));
        require(ok, "status call failed");
        return abi.decode(ret, (uint256));
    }

    function _coll(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            TROVE_MANAGER.staticcall(abi.encodeWithSignature("getTroveColl(address)", who));
        require(ok, "coll call failed");
        return abi.decode(ret, (uint256));
    }

    function _debt(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            TROVE_MANAGER.staticcall(abi.encodeWithSignature("getTroveDebt(address)", who));
        require(ok, "debt call failed");
        return abi.decode(ret, (uint256));
    }

    function _nonce(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            SIGS.staticcall(abi.encodeWithSignature("getNonce(address)", who));
        require(ok, "nonce call failed");
        return abi.decode(ret, (uint256));
    }

    /* ---------------------------------------------------------------------- */
    /*                            Happy path                                  */
    /* ---------------------------------------------------------------------- */

    function test_Fork_RealMigration() public {
        if (!forked) return;

        // --- 1. Wallet A opens a real native MUSD loan ----------------------
        uint256 collAmount = 0.1 ether; // 0.1 BTC
        uint256 borrowAmount = 2000e18; // net draw

        vm.deal(walletA, 1 ether);
        vm.prank(walletA);
        IBorrowerOpsPublic(BORROWER_OPS).openTrove{value: collAmount}(borrowAmount, address(0), address(0));

        assertEq(_status(walletA), 1, "A trove should be active");
        assertEq(_status(walletB), 0, "B trove should not exist");

        uint256 aColl = _coll(walletA);
        uint256 aDebt = _debt(walletA);
        uint256 aMusd = IERC20Full(MUSD).balanceOf(walletA);
        emit log_named_uint("A collateral (wei)", aColl);
        emit log_named_uint("A debt (MUSD 1e18)", aDebt);
        emit log_named_uint("A MUSD received", aMusd);
        assertEq(aColl, collAmount, "collateral recorded");

        // --- 2. Quote the migration ----------------------------------------
        // The router measures the payoff itself. We only choose the draw.
        (uint256 qColl, uint256 payoff, uint256 principal, uint256 flashFee,) =
            router.preview(walletA, 2200e18);
        uint256 replacementDebt = 2200e18;

        emit log_named_uint("quoted collateral", qColl);
        emit log_named_uint("payoff", payoff);
        emit log_named_uint("principal", principal);
        emit log_named_uint("flashFee", flashFee);
        assertGt(flashFee, 0, "tigris must charge something");

        // --- 3. Build both EIP-712 signatures -------------------------------
        uint256 deadline = block.timestamp + 20 minutes;

        bytes memory closeSig =
            _signClose(walletAKey, walletA, address(router), _nonce(walletA), deadline);
        bytes memory openSig = _signOpen(
            walletBKey, collAmount, replacementDebt, walletB, address(router), _nonce(walletB), deadline
        );

        // --- 4. Execute ----------------------------------------------------
        vm.prank(walletA);
        router.moveLoan(walletB, collAmount, replacementDebt, deadline, closeSig, openSig);

        // --- 5. Assert the move --------------------------------------------
        assertTrue(_status(walletA) != 1, "source trove closed");
        assertEq(_status(walletB), 1, "destination trove active");
        assertEq(_coll(walletB), collAmount, "same BTC collateral");
        assertEq(address(router).balance, 0, "router holds no BTC");
        assertEq(IERC20Full(MUSD).balanceOf(address(router)), 0, "router holds no MUSD");

        emit log_named_uint("B debt", _debt(walletB));
        emit log_named_uint("B MUSD received", IERC20Full(MUSD).balanceOf(walletB));
    }

    /* ---------------------------------------------------------------------- */
    /*                            Failure paths                               */
    /* ---------------------------------------------------------------------- */

    function test_Revert_SourceNotActive() public {
        if (!forked) return;
        vm.deal(walletA, 1 ether);
        uint256 deadline = block.timestamp + 20 minutes;
        bytes memory s1 = _signClose(walletAKey, walletA, address(router), 0, deadline);
        bytes memory s2 = _signOpen(walletBKey, 0.1 ether, 2100e18, walletB, address(router), 0, deadline);

        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.SourceNotActive.selector);
        router.moveLoan(walletB, 0.1 ether, 2100e18, deadline, s1, s2);
    }

    function test_Revert_DuplicateWallets() public {
        if (!forked) return;
        uint256 deadline = block.timestamp + 20 minutes;
        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.DuplicateWallets.selector);
        router.moveLoan(walletA, 0.1 ether, 2100e18, deadline, "", "");
    }

    function test_Revert_QuoteExpired() public {
        if (!forked) return;
        uint256 deadline = block.timestamp - 1;
        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.QuoteExpired.selector);
        router.moveLoan(walletB, 0.1 ether, 2100e18, deadline, "", "");
    }

    function test_Revert_DeadlineTooFar() public {
        if (!forked) return;
        uint256 deadline = block.timestamp + 2 days;
        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.DeadlineTooFar.selector);
        router.moveLoan(walletB, 0.1 ether, 2100e18, deadline, "", "");
    }

    function test_Revert_DrawTooSmall() public {
        if (!forked) return;
        vm.deal(walletA, 1 ether);
        vm.prank(walletA);
        IBorrowerOpsPublic(BORROWER_OPS).openTrove{value: 0.1 ether}(2000e18, address(0), address(0));

        uint256 deadline = block.timestamp + 20 minutes;
        bytes memory s1 =
            _signClose(walletAKey, walletA, address(router), _nonce(walletA), deadline);
        bytes memory s2 = _signOpen(
            walletBKey, 0.1 ether, 1000e18, walletB, address(router), _nonce(walletB), deadline
        );

        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.DrawTooSmall.selector);
        // A 1000 MUSD draw cannot service ~2200 MUSD of debt.
        router.moveLoan(walletB, 0.1 ether, 1000e18, deadline, s1, s2);
    }

    function test_Revert_NativeFromUnexpectedSource() public {
        if (!forked) return;
        vm.deal(address(0xdead), 1 ether);
        vm.prank(address(0xdead));
        (bool ok,) = address(router).call{value: 0.1 ether}("");
        assertFalse(ok, "router must reject stray BTC");
    }

    function test_Revert_DestinationOccupied() public {
        if (!forked) return;

        // Give B a trove of its own first.
        vm.deal(walletB, 1 ether);
        vm.prank(walletB);
        IBorrowerOpsPublic(BORROWER_OPS).openTrove{value: 0.1 ether}(2000e18, address(0), address(0));
        assertEq(_status(walletB), 1);

        uint256 deadline = block.timestamp + 20 minutes;
        vm.deal(walletA, 1 ether);
        vm.prank(walletA);
        IBorrowerOpsPublic(BORROWER_OPS).openTrove{value: 0.1 ether}(2000e18, address(0), address(0));

        vm.prank(walletA);
        vm.expectRevert(HandoffRouter.DestinationOccupied.selector);
        router.moveLoan(walletB, 0.1 ether, 2100e18, deadline, "", "");
    }

    /* ---------------------------------------------------------------------- */
    /*                       Authorization and rollback                       */
    /* ---------------------------------------------------------------------- */

    uint256 constant TEST_COLLATERAL = 0.1 ether;
    uint256 constant REPLACEMENT_DRAW = 2200e18;

    function _openSourceLoan() internal {
        vm.deal(walletA, 1 ether);
        vm.prank(walletA);
        IBorrowerOpsPublic(BORROWER_OPS).openTrove{value: TEST_COLLATERAL}(
            2000e18, address(0), address(0)
        );
    }

    function _closeSignature(uint256 deadline) internal view returns (bytes memory) {
        return _signClose(walletAKey, walletA, address(router), _nonce(walletA), deadline);
    }

    function _openSignature(uint256 collateral, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signOpen(
            walletBKey, collateral, REPLACEMENT_DRAW, walletB,
            address(router), _nonce(walletB), deadline
        );
    }

    function test_Revert_TamperedDrawRollsBackTheSourceCloseAndFlashBorrow() public {
        _openSourceLoan();
        uint256 deadline = block.timestamp + 20 minutes;
        uint256 originalDebt = _debt(walletA);
        uint256 sourceNonce = _nonce(walletA);
        uint256 destinationNonce = _nonce(walletB);
        uint256 poolBalance = IERC20Full(MUSD).balanceOf(POOL);
        bytes memory closeSig = _closeSignature(deadline);
        bytes memory openSig = _openSignature(TEST_COLLATERAL, deadline);

        vm.expectRevert();
        vm.prank(walletA);
        router.moveLoan(walletB, TEST_COLLATERAL, REPLACEMENT_DRAW + 1e18, deadline, closeSig, openSig);

        assertEq(_status(walletA), 1, "source loan remains active");
        assertEq(_coll(walletA), TEST_COLLATERAL, "source keeps its BTC");
        assertEq(_debt(walletA), originalDebt, "source debt is restored");
        assertEq(_status(walletB), 0, "destination stays empty");
        assertEq(_nonce(walletA), sourceNonce, "source authorization remains unused");
        assertEq(_nonce(walletB), destinationNonce, "destination authorization remains unused");
        assertEq(IERC20Full(MUSD).balanceOf(POOL), poolBalance, "pool keeps its MUSD");
        assertEq(IERC20Full(MUSD).balanceOf(address(router)), 0, "router keeps no MUSD");
        assertEq(address(router).balance, 0, "router keeps no BTC");

        vm.prank(walletA);
        router.moveLoan(walletB, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, closeSig, openSig);
        assertEq(_status(walletB), 1, "the same signature authorizes the original draw");
    }

    function test_Revert_WrongSourceSignerThenAcceptTheCorrectOne() public {
        _openSourceLoan();
        uint256 deadline = block.timestamp + 20 minutes;
        bytes memory wrongClose =
            _signClose(walletBKey, walletA, address(router), _nonce(walletA), deadline);
        bytes memory openSig = _openSignature(TEST_COLLATERAL, deadline);

        vm.expectRevert();
        vm.prank(walletA);
        router.moveLoan(walletB, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, wrongClose, openSig);
        assertEq(_status(walletA), 1, "wrong signer cannot close the source loan");
        assertEq(_status(walletB), 0, "wrong signer cannot open the destination loan");

        bytes memory closeSig = _closeSignature(deadline);
        vm.prank(walletA);
        router.moveLoan(walletB, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, closeSig, openSig);
        assertEq(_status(walletB), 1, "identified source signer can authorize the move");
    }

    function test_Revert_QuotedCollateralDoesNotMatchReleasedCollateral() public {
        _openSourceLoan();
        uint256 deadline = block.timestamp + 20 minutes;
        uint256 quotedCollateral = TEST_COLLATERAL - 1;
        bytes memory closeSig = _closeSignature(deadline);
        bytes memory openSig = _openSignature(quotedCollateral, deadline);

        vm.expectRevert(HandoffRouter.BtcMismatch.selector);
        vm.prank(walletA);
        router.moveLoan(walletB, quotedCollateral, REPLACEMENT_DRAW, deadline, closeSig, openSig);
        assertEq(_status(walletA), 1);
        assertEq(_coll(walletA), TEST_COLLATERAL);
        assertEq(address(router).balance, 0);
    }

    function test_Revert_ConsumedSignatureAfterTheSourceOpensAnotherLoan() public {
        _openSourceLoan();
        uint256 deadline = block.timestamp + 20 minutes;
        bytes memory usedClose = _closeSignature(deadline);
        bytes memory openSig = _openSignature(TEST_COLLATERAL, deadline);
        vm.prank(walletA);
        router.moveLoan(walletB, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, usedClose, openSig);

        _openSourceLoan();
        uint256 freshWalletKey = 0xCAFE;
        address freshWallet = vm.addr(freshWalletKey);
        bytes memory freshOpen = _signOpen(
            freshWalletKey, TEST_COLLATERAL, REPLACEMENT_DRAW, freshWallet,
            address(router), _nonce(freshWallet), deadline
        );

        vm.expectRevert();
        vm.prank(walletA);
        router.moveLoan(freshWallet, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, usedClose, freshOpen);
        assertEq(_status(walletA), 1, "replayed signature leaves the new source loan active");
        assertEq(_status(freshWallet), 0, "replayed signature leaves destination empty");

        bytes memory freshClose = _closeSignature(deadline);
        vm.prank(walletA);
        router.moveLoan(freshWallet, TEST_COLLATERAL, REPLACEMENT_DRAW, deadline, freshClose, freshOpen);
        assertEq(_status(freshWallet), 1, "a new signature authorizes the second move");
    }

    function test_Revert_FlashCallbackFromOutsideThePool() public {
        vm.expectRevert(HandoffRouter.NotPool.selector);
        vm.prank(walletB);
        router.hook(walletA, 1e18, 0, "");
    }

    /* ---------------------------------------------------------------------- */
    /*                              Unit checks                               */
    /* ---------------------------------------------------------------------- */

    function test_FlashFeeRounding() public {
        if (!forked) return;
        uint256 principal = 2500e18;
        uint256 fee = router.flashFeeFor(principal);
        uint256 bps = router.poolFeeBps();
        emit log_named_uint("pool fee bps", bps);
        emit log_named_uint("fee on 2500 MUSD", fee);
        assertGt(fee, 0);
        // Fee must be at least the floor of principal * bps / 10_000
        assertGe(fee, (principal * bps) / 10_000);
    }
}

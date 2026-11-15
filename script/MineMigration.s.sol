// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HandoffRouter} from "../src/HandoffRouter.sol";

interface IBO {
    function openTrove(uint256 _debtAmount, address _upperHint, address _lowerHint)
        external
        payable;
}

interface ITMStatus {
    function getTroveStatus(address) external view returns (uint256);
}

/**
 * @notice Produces one mined, publicly verifiable migration on Mezo Testnet.
 *
 *   1. Opens a real trove on Wallet A (skipped if it already has one)
 *   2. Signs both EIP-712 messages (A closes, B opens)
 *   3. Calls the deployed router — one transaction moves the whole loan
 *
 *   HANDOFF_SOURCE_KEY=0x... HANDOFF_DEST_KEY=0x... \
 *   forge script script/MineMigration.s.sol:MineMigration \
 *     --rpc-url https://rpc.test.mezo.org --broadcast -vv
 */
contract MineMigration is Script {
    address constant ROUTER = 0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762;
    address constant BORROWER_OPS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant SIGS = 0xD757e3646AF370b15f32EB557F0F8380Df7D639e;

    uint256 constant CHAIN_ID = 31611;
    uint256 constant DRAW = 1800e18; // Mezo's minNetDebt
    uint256 constant COLLATERAL = 0.06 ether; // covers MCR 110% with room

    bytes32 constant CLOSE_TROVE_TYPEHASH =
        keccak256("CloseTrove(address borrower,address recipient,uint256 nonce,uint256 deadline)");
    bytes32 constant OPEN_TROVE_TYPEHASH = keccak256(
        "OpenTrove(uint256 assetAmount,uint256 debtAmount,address borrower,address recipient,uint256 nonce,uint256 deadline)"
    );
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function run() external {
        uint256 srcKey = vm.envUint("HANDOFF_SOURCE_KEY");
        uint256 dstKey = vm.envUint("HANDOFF_DEST_KEY");
        address a = vm.addr(srcKey);
        address b = vm.addr(dstKey);

        HandoffRouter router = HandoffRouter(payable(ROUTER));
        ITMStatus tm = ITMStatus(TROVE_MANAGER);

        console.log("Wallet A (source):", a);
        console.log("Wallet B (dest)  :", b);
        console.log("A balance (BTC)  :", a.balance);

        // ---- 1. Ensure Wallet A holds an active loan -----------------------
        if (tm.getTroveStatus(a) != 1) {
            require(a.balance > COLLATERAL, "Wallet A needs more testnet BTC");
            console.log("Opening trove on A with", COLLATERAL, "BTC");
            vm.startBroadcast(srcKey);
            IBO(BORROWER_OPS).openTrove{value: COLLATERAL}(DRAW, address(0), address(0));
            vm.stopBroadcast();
        } else {
            console.log("A already has an active trove - skipping open");
        }
        require(tm.getTroveStatus(a) == 1, "A trove not active");

        uint256 coll = router.sourceCollateral(a);
        (, uint256 principal, uint256 fee) = _preview(router, a);

        // Draw enough on the destination to service payoff + flash fee.
        uint256 replacementDebt = 1800e18 + 300e18; // minNetDebt + margin
        uint256 deadline = block.timestamp + 30 minutes;

        // ---- 2. Both signatures -------------------------------------------
        bytes memory closeSig = _signClose(srcKey, a, ROUTER, _nonce(a), deadline);
        bytes memory openSig = _signOpen(dstKey, coll, replacementDebt, b, ROUTER, _nonce(b), deadline);

        console.log("Collateral to move:", coll);
        console.log("Flash principal  :", principal);
        console.log("Expected flash fee:", fee);

        // ---- 3. The migration: one transaction ----------------------------
        vm.startBroadcast(srcKey);
        router.moveLoan(b, coll, replacementDebt, deadline, closeSig, openSig);
        vm.stopBroadcast();

        // ---- 4. Verify on chain -------------------------------------------
        require(tm.getTroveStatus(a) != 1, "A should be closed");
        require(tm.getTroveStatus(b) == 1, "B should be active");
        console.log("MIGRATION MINED");
        console.log("A trove status:", tm.getTroveStatus(a));
        console.log("B trove status:", tm.getTroveStatus(b));
        console.log("B collateral  :", router.sourceCollateral(b));
    }

    function _preview(HandoffRouter r, address who)
        internal
        view
        returns (uint256 payoff, uint256 principal, uint256 fee)
    {
        (uint256 coll, uint256 po, uint256 pr, uint256 fe,) = r.preview(who, 2100e18);
        coll;
        payoff = po;
        principal = pr;
        fee = fe;
    }

    /* ---------------------------- EIP-712 ------------------------------- */

    function _domainSeparator() internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
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

    function _nonce(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            SIGS.staticcall(abi.encodeWithSignature("getNonce(address)", who));
        require(ok, "nonce read failed");
        return abi.decode(ret, (uint256));
    }

    function _signClose(uint256 pk, address borrower, address recipient, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
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
            abi.encode(OPEN_TROVE_TYPEHASH, assetAmount, debtAmount, borrower, recipient, nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(sh));
        return abi.encodePacked(r, s, v);
    }
}

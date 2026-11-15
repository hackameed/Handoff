// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HandoffRouter} from "../src/HandoffRouter.sol";

/**
 * @notice Deploys HandoffRouter bound to Mezo Testnet.
 *
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url https://rpc.test.mezo.org \
 *     --private-key $HANDOFF_TESTNET_PRIVATE_KEY \
 *     --broadcast
 *
 * Never commit the key. Pass it privately to the process.
 */
contract Deploy is Script {
    // Mezo Testnet (chain 31611) — all verified to hold bytecode.
    uint256 constant CHAIN_ID = 31611;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant BORROWER_OPS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant SIGS = 0xD757e3646AF370b15f32EB557F0F8380Df7D639e;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant ACTIVE_POOL = 0x143A063F62340DA3A8bEA1C5642d18C6D0F7FF51;
    address constant POOL = 0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e;
    address constant POOL_FACTORY = 0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A;

    function run() external returns (HandoffRouter router) {
        require(block.chainid == CHAIN_ID, "wrong chain");

        vm.startBroadcast();
        router = new HandoffRouter(
            CHAIN_ID, MUSD, SIGS, TROVE_MANAGER, ACTIVE_POOL, POOL, POOL_FACTORY
        );
        vm.stopBroadcast();

        console.log("HandoffRouter deployed at:", address(router));
        console.log("Pool fee (bps):", router.poolFeeBps());
        console.log("Fee on 2500 MUSD:", router.flashFeeFor(2500e18));
    }
}

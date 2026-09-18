// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FeeTiers} from "../contracts/FeeTiers.sol";

/**
 * Deploy the fee-tier registry, then pass its address to Deploy.s.sol as FEE_TIERS.
 *
 *   TIERS_OWNER=<the key that will write tiers> \
 *     forge script script/DeployFeeTiers.s.sol --tc DeployFeeTiers --rpc-url <rpc> --broadcast
 *
 * ⚠️ ORDER MATTERS: CrazyGame takes the registry address as an IMMUTABLE, so this has to exist
 *    before the game is deployed. Deploying the game with FEE_TIERS unset is a valid choice — every
 *    uncurated coin then pays the default forever — but it cannot be changed afterwards.
 *
 * ⚠️ THE OWNER IS A HOT KEY that will sign one small transaction per pad launch. It can do exactly
 *    one thing: discount a coin's fee on its NEXT game, within [MIN_FEE_BPS, platformFeeBps]. It
 *    cannot raise a fee, touch money, or reach a game that already exists. Do not make it the
 *    treasury.
 */
contract DeployFeeTiers is Script {
    function run() external {
        address owner = vm.envOr("TIERS_OWNER", msg.sender);
        require(owner != address(0), "TIERS_OWNER cannot be the zero address");

        vm.startBroadcast();
        FeeTiers tiers = new FeeTiers(owner);
        vm.stopBroadcast();

        console.log("FeeTiers deployed :", address(tiers));
        console.log("owner             :", owner);
        console.log("pass this as FEE_TIERS when deploying CrazyGame");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrazyGame, IVRFV2PlusWrapper} from "../contracts/CrazyGame.sol";

/**
 * Deploy CrazyGame.
 *
 * Local Anvil (no oracle — mode 3 games will be refused, which is the correct behaviour):
 *   anvil &
 *   forge script script/Deploy.s.sol --tc Deploy --rpc-url http://127.0.0.1:8545 --broadcast \
 *     --private-key <anvil key 0>
 *
 * BSC, with Insanity enabled:
 *   VRF_WRAPPER=0x471506e6ADED0b9811D05B8cAc8Db25eE839Ac94 \
 *     forge script script/Deploy.s.sol --tc Deploy --rpc-url <bsc rpc> --broadcast --verify
 *
 * That address is Chainlink's VRF v2.5 WRAPPER (direct funding) on BNB Chain mainnet.
 * ⚠️ It is the wrapper, NOT the coordinator (0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9). Passing
 * the coordinator would sail through the probe below — it is a real contract — and then fail at the
 * first salvation, so the two are worth keeping straight.
 *
 * ⚠️ NEVER point --broadcast at BSC mainnet from here. Mainnet deployment is a deliberate,
 * separately-reviewed act, not something a script run does by accident.
 */
contract Deploy is Script {
    // ─── THE PLATFORM FEE, IN THREE TIERS, AS ON SOLANA ──────────────────────────────────────
    // Solana charges PER TOKEN: 5% for a self-serve onboarded coin, 3% for the curated ones
    // (lib.rs: ONBOARD_FEE_BPS = 500, with the curated set by the operator). The first port of this
    // contract flattened that to a single 3% — the CURATED tier — and charged it to everything.
    //
    // 500 is the DEFAULT and also the CEILING: neither the curated list below nor the registry can
    // take a coin above it, and neither can go under MIN_FEE_BPS.
    uint256 constant PLATFORM_FEE_BPS = 500;
    uint256 constant CURATED_FEE_BPS = 300;

    function run() external {
        address treasury = vm.envOr("TREASURY", msg.sender);
        address wrapper = vm.envOr("VRF_WRAPPER", address(0));

        // ⭐ PROVE THE ORACLE ADDRESS RATHER THAN TRUST IT.
        // The wrapper address is per-chain and is the one deploy parameter that is easy to get
        // wrong and impossible to notice: a wrong-but-plausible address deploys fine, creates
        // Insanity games fine, and only fails at the first salvation — with real money in the pot.
        if (wrapper != address(0)) {
            require(wrapper.code.length > 0, "VRF_WRAPPER has no code - wrong address or wrong chain");

            // ⚠️ The coordinator (0xd691f04b...) is a REAL CONTRACT, so a code-length check waves it
            // straight through — it simply has no calculateRequestPriceNative, so the call reverts
            // with nothing useful attached. Catch it and say which mistake it almost certainly is,
            // because "EvmError: Revert" halfway through a mainnet deploy is a dead end.
            uint256 fee;
            try IVRFV2PlusWrapper(wrapper).calculateRequestPriceNative(CrazyGameFeeProbe.GAS, 1) returns (uint256 quoted) {
                fee = quoted;
            } catch {
                revert(
                    "VRF_WRAPPER does not answer calculateRequestPriceNative. It is a contract, but "
                    "not the wrapper. The most likely mistake is using the COORDINATOR "
                    "(0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9). BSC mainnet wrapper is "
                    "0x471506e6ADED0b9811D05B8cAc8Db25eE839Ac94."
                );
            }
            console.log("vrf wrapper       :", wrapper);
            console.log("vrf fee (wei)     :", fee);
            console.log("tx.gasprice (wei) :", tx.gasprice);

            // ⚠️ DO NOT require(fee > 0) unconditionally. Chainlink's price is derived from
            // tx.gasprice, and a simulated call with no gas price set returns EXACTLY ZERO from a
            // perfectly good wrapper. Requiring a non-zero fee would then block a correct deploy
            // and, worse, teach whoever hits it that the oracle is broken when it is not.
            if (tx.gasprice > 0) {
                require(fee > 0, "wrapper quoted a zero fee at a non-zero gas price - wrong address");
            } else {
                console.log("note: gas price is zero here, so a zero quote is expected, not a fault");
            }
        } else {
            console.log("vrf wrapper       : NONE - Insanity (salvador mode 3) will be REFUSED");
        }

        // ─── PRICE SOURCES for the real-money min-bet floor ──────────────────────────────────
        // BSC mainnet defaults, every one VERIFIED ON CHAIN 2026-08-29. Overridable by env so that
        // another chain is a DEPLOY, not a port - which is the whole reason they are constructor
        // arguments rather than constants.
        //
        // ⚠️ ALL FOUR address(0) is a VALID configuration, not a broken one: no price source means
        //    every token is unpriceable and the ratio gates apply, exactly as before floors existed.
        //    That is the correct first deploy on a chain with no curve and no DEX yet.
        address flap    = vm.envOr("FLAP_PORTAL",    address(0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0));
        address factory = vm.envOr("DEX_FACTORY",    address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73)); // PancakeSwap V2
        address router  = vm.envOr("DEX_ROUTER",     address(0x10ED43C718714eb63d5aA57B78B54704E256024E)); // PancakeSwap V2
        address wnative = vm.envOr("WRAPPED_NATIVE", address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c)); // WBNB
        // ⭐ CAN THIS CHAIN'S GAS ASSET BE WRAPPED? Defaults to the pricing asset, which is right
        //    wherever the two are the same contract — BSC, Base, Arbitrum, anywhere with a WETH9.
        //    Set it to zero on a chain where the gas asset IS an ERC-20 already and there is
        //    nothing to wrap; Arc is that chain. The constructor refuses any other value.
        address nwrap = vm.envOr("NATIVE_WRAPPER", wnative);
        console.log("flap portal       :", flap);
        console.log("dex factory       :", factory);
        console.log("dex router        :", router);
        console.log("wrapped native    :", wnative);
        console.log("native wrapper    :", nwrap);
        if (nwrap == address(0)) {
            console.log("note: gas asset cannot be wrapped here - a payable bet reverts by name,");
            console.log("      and players stake the ERC-20 directly, which is the same money.");
        }
        if (flap == address(0) && router == address(0)) {
            // 🩸 This used to end "...and the ratio gates apply". INSANITY_MIN_POOL_RATIO is
            //    deleted, so on such a chain NOTHING gates a game at all. That is a louder fact
            //    than the one it replaced, and it belongs on the deploy console rather than in a
            //    comment nobody reads at 2am.
            console.log("note: NO price source - every token is unpriceable, so NO floor is enforced");
            console.log("      on this chain at all. Setting WRAPPED_NATIVE alone fixes it for the");
            console.log("      chain's own coin, which is the coin most games get played in.");
        }

        // ─── FEE TIERS ───────────────────────────────────────────────────────────────────────
        // Curated coins are fixed HERE, at deployment, and can never be changed afterwards: the
        // game contract has no setter for them and never will.
        // ⚠️ VERIFIED ON CHAIN 2026-09-12: USDT on BSC is 18 decimals, not the 6 it has on
        //    Ethereum, and WBNB is the same address this script already passes as wrappedNative.
        //    On another chain pass CURATED_STABLE for that chain's stablecoin (Arc: USDC), or
        //    address(0) to curate nothing at all.
        address stable = vm.envOr("CURATED_STABLE", address(0x55d398326f99059fF775485246999027B3197955));
        uint256 curatedCount = (wnative != address(0) ? 1 : 0) + (stable != address(0) ? 1 : 0);
        address[] memory curated = new address[](curatedCount);
        uint256[] memory curatedFees = new uint256[](curatedCount);
        uint256 k;
        if (wnative != address(0)) { curated[k] = wnative; curatedFees[k] = CURATED_FEE_BPS; k++; }
        if (stable != address(0))  { curated[k] = stable;  curatedFees[k] = CURATED_FEE_BPS; k++; }
        for (uint256 i; i < curatedCount; i++) console.log("curated (3%)      :", curated[i]);

        // The middle tier — coins launched at our own pad — is the ONE thing the chain cannot see
        // for itself: our launches mark themselves with a commissionReceiver, and neither flap's
        // Portal nor the token it deploys exposes it. So it comes from a registry we write.
        // address(0) = no middle tier, and every uncurated coin pays the default.
        address tiersAddr = vm.envOr("FEE_TIERS", address(0));
        console.log("fee tiers registry:", tiersAddr);

        // ⛔⛔ THE FLOORS ARE A CHAIN-SPECIFIC VALUE AND ARE NOW READ LIKE ONE. They used to be
        //    `constant` inside the contract, which is what made this a BSC deploy script rather
        //    than a deploy script. The defaults are BSC's own, so an unset environment deploys
        //    exactly what BSC runs today; any other chain sets all three.
        //
        // ⚠️ IN `wnative`'s UNITS, NOT IN NATIVE WEI — identical on BSC, where WBNB is 18dp just
        //    like BNB, and not identical on a chain whose ERC-20 view of its gas asset carries
        //    different decimals. Arc is exactly that: the same money at 18dp native and 6dp
        //    ERC-20, so its floors are six-figure numbers and 18dp ones would overstate by 1e12.
        //
        // ⚠️ THE DERIVATION PORTS, THE NUMBERS DO NOT: min bet = 10x what a placeBet costs in gas
        //    on THIS chain (20x for Insanity, whose salvations the operator also pays to trigger),
        //    and the pool floor is where the expected bounty covers a VRF trigger with 3x margin.
        //    Price them from that chain's live gas, never from BSC's by analogy.
        uint256[3] memory floors = [
            vm.envOr("MIN_BET_FLOOR",          uint256(0.0002 ether)),
            vm.envOr("MIN_BET_FLOOR_INSANITY", uint256(0.0004 ether)),
            vm.envOr("INSANITY_POOL_FLOOR",    uint256(0.04 ether))
        ];
        console.log("min bet floor     :", floors[0]);
        console.log("  insanity        :", floors[1]);
        console.log("insanity pool     :", floors[2]);

        // ⛔ REQUIRED, NO DEFAULT. Whether games open at creation or minutes later is a property of the
        //    chain (Arc: 300, TOLLY's anti-snipe window), and a default would pick one silently.
        uint256 openDelay = vm.envUint("OPEN_DELAY");
        console.log("open delay (s)    :", openDelay);

        vm.startBroadcast();
        CrazyGame game = new CrazyGame(
            treasury, PLATFORM_FEE_BPS, wrapper, flap, factory, router, wnative, nwrap,
            curated, curatedFees, tiersAddr, floors, openDelay);
        vm.stopBroadcast();

        // The probe above is only meaningful if it used the same callback gas the game will ask
        // for. Assert that rather than trusting the two constants to have been kept in step.
        require(game.VRF_CALLBACK_GAS() == CrazyGameFeeProbe.GAS, "probe gas != VRF_CALLBACK_GAS");

        console.log("CrazyGame deployed:", address(game));
        console.log("treasury          :", treasury);
        console.log("platformFeeBps    :", PLATFORM_FEE_BPS);
    }
}

/// Kept beside the deployer so the probe uses the SAME callback gas the contract will request with;
/// probing at a different gas limit would quote a fee the game never actually pays. The deployer
/// asserts these match, so changing VRF_CALLBACK_GAS without changing this fails loudly.
library CrazyGameFeeProbe {
    uint32 internal constant GAS = 200_000;
}

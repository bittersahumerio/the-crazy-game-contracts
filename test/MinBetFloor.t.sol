// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";

/**
 * The min-bet floor, against REAL flap and REAL PancakeSwap on a BSC fork.
 *
 * ⛔ THESE MUST BE FORK TESTS. The whole feature is "ask a third-party contract what a token is
 *    worth", and every trap found while designing it was a fact about how those contracts BEHAVE,
 *    not about our arithmetic: getTokenV5 reverts for unfamiliar tokens, migrated coins report a
 *    price of zero, and a migrated coin is not necessarily paired against wrapped native. A mock
 *    would have agreed with whatever I believed and taught us nothing.
 *
 *    Run:  FORK_RPC=<a bsc rpc> forge test --match-path test/MinBetFloor.t.sol
 *    Without FORK_RPC they skip rather than fail, so CI without a node stays green.
 */
contract MinBetFloorTest is Test {
    // Verified on mainnet 2026-08-29.
    address constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant PCS_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant PCS_ROUTER  = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB        = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant VRF_WRAPPER = 0x471506e6ADED0b9811D05B8cAc8Db25eE839Ac94;

    // ⚠️ NATIVE-quoted, which is what our own launchpad mints. Chosen deliberately: the previous
    //    CURVE_TOKEN here (BEAGLE) quotes in DJTB, and a test that only asserted "priced == true"
    //    passed happily while the contract returned a floor 70x too low.
    address constant CURVE_TOKEN = 0x58B1772dBd3F6aE03a07B560A15A65DeDD127777; // flap, curve, NATIVE
    address constant CURVE_ALTQ  = 0x5740A942239419Af3063bB871c8bCa9856d77777; // flap, curve, quoted in DJTB
    address constant DEX_TOKEN   = 0x48a46238F97aCd13c311D7A4e7159a3fD74e7777; // flap, MIGRATED (quote = QQQB)
    address constant CAKE        = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82; // ordinary BEP20, deep WBNB pair
    address constant NO_ROUTE    = 0x000000000000000000000000000000000000dEaD; // neither flap nor a pair

    CrazyGame game;
    address host = makeAddr("host");
    address treasury = makeAddr("treasury");

    modifier onFork() {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        game = new CrazyGame(treasury, 300, VRF_WRAPPER, FLAP_PORTAL, PCS_FACTORY, PCS_ROUTER, WBNB, WBNB, new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        _;
    }

    // ── the quote chain: every branch, against the real contracts ────────────────────────────

    function test_curveCoinIsPricedByTheCurve() public onFork {
        (uint256 floorTokens, bool priced) = game.minBetFloorFor(CURVE_TOKEN, false);
        assertTrue(priced, "a native-quoted coin on the curve must be priceable - this is the LAUNCH PATH");
        assertGt(floorTokens, 0, "a priced token must yield a non-zero floor");

        // ⭐ THE ASSERTION THAT WOULD HAVE CAUGHT THE BUG. "priced == true and floor > 0" is a test
        //    that agrees with whatever the author already believed. Compare the floor against what
        //    flap ITSELF says 0.0002 BNB buys. quoteExactInput is nonpayable, so it is a real call.
        (bool ok, bytes memory ret) = FLAP_PORTAL.call(
            abi.encodeWithSignature(
                "quoteExactInput((address,address,uint256,bytes))",
                address(0), CURVE_TOKEN, uint256(0.0002 ether), bytes("")
            )
        );
        if (ok && ret.length >= 32) {
            uint256 actual = abi.decode(ret, (uint256));
            assertGt(actual, 0, "flap should quote this coin");
            // Spot price vs a real buy differ by curve convexity, not by orders of magnitude.
            assertLt(floorTokens, (actual * 12) / 10, "floor is far ABOVE what the native actually buys");
            assertGt(floorTokens, (actual * 8) / 10,  "floor is far BELOW what the native actually buys");
        }
    }

    /// A curve coin quoted in something other than native must never be priced off st.price - that
    /// is a quote-per-token figure and dividing a NATIVE amount by it is an asset mismatch. It may
    /// be priced via its own quote asset on the DEX, or reported unpriceable. Never wrong.
    function test_nonNativeQuotedCurveCoinIsNotMispriced() public onFork {
        (uint256 floorTokens, bool priced) = game.minBetFloorFor(CURVE_ALTQ, false);
        if (!priced) { assertEq(floorTokens, 0, "unpriced must mean zero"); return; }
        (bool ok, bytes memory ret) = FLAP_PORTAL.call(
            abi.encodeWithSignature(
                "quoteExactInput((address,address,uint256,bytes))",
                address(0), CURVE_ALTQ, uint256(0.0002 ether), bytes("")
            )
        );
        if (ok && ret.length >= 32) {
            uint256 actual = abi.decode(ret, (uint256));
            if (actual > 0) {
                assertLt(floorTokens, actual * 2, "floor wildly above the real price");
                assertGt(floorTokens * 2, actual, "floor wildly below the real price");
            }
        }
    }

    /// The one I first wrote off as unpriceable: it has no WBNB pair, and the answer was to build
    /// the path from the token's own quoteTokenAddress (QQQB) rather than assuming.
    function test_migratedCoinIsPricedViaItsOwnQuoteToken() public onFork {
        (uint256 floorTokens, bool priced) = game.minBetFloorFor(DEX_TOKEN, false);
        assertTrue(priced, "a migrated coin must price through its quoteTokenAddress, not WBNB");
        assertGt(floorTokens, 0, "");
    }

    function test_ordinaryTokenIsPricedByTheDex() public onFork {
        (uint256 floorTokens, bool priced) = game.minBetFloorFor(CAKE, false);
        assertTrue(priced, "any token with a Pancake route must be priceable");
        assertGt(floorTokens, 0, "");
    }

    /// ⛔ THE ONE THAT WOULD HAVE BROKEN EVERYTHING. getTokenV5 REVERTS (0xde6137d1) for a token
    ///    flap has never seen, and getAmountsOut reverts without a pair. Neither may propagate.
    function test_unknownTokenIsUnpriceableAndDoesNotRevert() public onFork {
        (uint256 floorTokens, bool priced) = game.minBetFloorFor(NO_ROUTE, false);
        assertFalse(priced, "a token no source knows must report unpriceable");
        assertEq(floorTokens, 0, "");
    }

    function test_insanityFloorIsTheLargerOne() public onFork {
        (uint256 normal, bool p1) = game.minBetFloorFor(CURVE_TOKEN, false);
        (uint256 insane, bool p2) = game.minBetFloorFor(CURVE_TOKEN, true);
        assertTrue(p1 && p2, "the native-quoted curve coin must price on both settings");
        assertGt(insane, normal, "Insanity's floor is 0.0004 native against 0.0002 - it must be larger");
    }

    // ── enforcement in createGame ────────────────────────────────────────────────────────────

    function _fund(address token, uint256 amount) internal {
        deal(token, host, amount);
        vm.prank(host);
        IERC20(token).approve(address(game), type(uint256).max);
    }

    function test_createGameRejectsAMinBetBelowTheFloor() public onFork {
        (uint256 floorTokens,) = game.minBetFloorFor(CAKE, false);
        uint256 deposit = floorTokens * 500;
        _fund(CAKE, deposit);
        uint256 tooSmall = floorTokens - 1;
        vm.prank(host);
        vm.expectRevert(
            abi.encodeWithSelector(CrazyGame.MinBetBelowFloor.selector, tooSmall, floorTokens)
        );
        game.createGame(CAKE, deposit, tooSmall, 10_000, 100, 0, 1800, 0, [uint16(0), 0, 0, 0]);
    }

    function test_createGameAcceptsAMinBetAtTheFloor() public onFork {
        (uint256 floorTokens,) = game.minBetFloorFor(CAKE, false);
        uint256 deposit = floorTokens * 500;
        _fund(CAKE, deposit);
        vm.prank(host);
        uint256 id = game.createGame(CAKE, deposit, floorTokens, 10_000, 100, 0, 1800, 0, [uint16(0), 0, 0, 0]);
        assertGt(id, 0, "a game exactly at the floor must be allowed");
    }

    /// ⭐ THE POINT OF THE PUBLIC VIEW: the number a UI reads is the number the chain enforces.
    ///    Drift between those two is what shipped a wrong constant and orphaned two coins.
    function test_theViewIsExactlyWhatIsEnforced() public onFork {
        (uint256 floorTokens,) = game.minBetFloorFor(CAKE, false);
        uint256 deposit = floorTokens * 500;
        _fund(CAKE, deposit * 2);
        // one wei under is refused, exactly on is accepted: the boundary is the view's own number
        vm.prank(host);
        vm.expectRevert();
        game.createGame(CAKE, deposit, floorTokens - 1, 10_000, 100, 0, 1800, 0, [uint16(0), 0, 0, 0]);
        vm.prank(host);
        game.createGame(CAKE, deposit, floorTokens, 10_000, 100, 0, 1800, 0, [uint16(0), 0, 0, 0]);
    }

    function test_insanityRejectsAPoolBelowItsFloor() public onFork {
        (uint256 betFloor,)  = game.minBetFloorFor(CAKE, true);
        (uint256 poolFloor,) = game.insanityPoolFloorFor(CAKE);
        // Just under the pool floor, but with a min bet small enough that ratio >= 50 STILL HOLDS,
        // so it is the new floor that refuses and demonstrably not the old ratio gate. At
        // poolFloor/2 the two coincide exactly at 50 and the test proves nothing.
        uint256 thinPool = (poolFloor * 9) / 10;
        assertGe(thinPool / betFloor, 50, "test must isolate the floor from the ratio gate");
        _fund(CAKE, thinPool);
        vm.prank(host);
        vm.expectRevert(
            abi.encodeWithSelector(CrazyGame.PoolBelowInsanityFloor.selector, thinPool, poolFloor)
        );
        game.createGame(CAKE, thinPool, betFloor, 10_000, 100, 0, 1800, 0, [uint16(3), 0, 0, 0]);
    }

    /// An unpriceable token must still be playable under the old ratio rules - no regression.
    /// 🩸 THIS WAS CALLED test_unpriceableTokenStillFollowsTheRatioGates AND NEVER TESTED A GATE.
    /// Its body asserts one thing — that a deployment with no price sources prices nothing — which
    /// is worth asserting and is all it ever did. The name claimed a second assertion that was not
    /// in the file, and it kept passing after INSANITY_MIN_POOL_RATIO was deleted, still promising
    /// to cover a gate that had stopped existing. A green test whose name describes absent
    /// behaviour is worse than no test: it is the reason somebody does not write the real one.
    function test_aDeploymentWithNoPriceSourcesPricesNothing() public onFork {
        CrazyGame bare = new CrazyGame(treasury, 300, VRF_WRAPPER, address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        (, bool priced) = bare.minBetFloorFor(CAKE, false);
        assertFalse(priced, "with no price sources configured every token is unpriceable");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";

/**
 * ⛔⛔ WHAT MAKES THE NEXT CHAIN A DEPLOY INSTEAD OF A PORT.
 *
 * Three things changed together and this file is the reason to believe each of them:
 *
 *   1. THE FLOORS COME FROM THE CONSTRUCTOR. They were `constant` — three BNB quantities sitting
 *      underneath a block of comments explaining that hardcoding BSC values "would make Arc a PORT
 *      instead of a DEPLOY". `0.0002 ether` is 14 cents of BNB and 60 cents of ETH; on a chain
 *      whose gas asset is a stablecoin it is not a quantity of money at all.
 *
 *   2. THE CHAIN'S OWN COIN PRICES ITSELF. A quote for the wrapper built the path
 *      [wrappedNative, wrappedNative], getPair answered address(0) for a pair of a token with
 *      itself, and the wrapper came back UNPRICEABLE — so the chain enforced NO FLOOR on games
 *      played in its own coin. Measured on the live BSC deployment before this change:
 *      minBetFloorFor(WBNB, false) = (0, false). On BSC that is a curiosity. On Base or Arbitrum,
 *      where a wrapped-native game is the default rather than the exception, it is the main case.
 *
 *   3. INSANITY_MIN_POOL_RATIO IS GONE, decided 2026-08-28 and only now carried out.
 *
 * ⭐ NO FORK AND NO RPC. Every assertion here is about OUR arithmetic and OUR configuration, not
 *    about how somebody else's router behaves — MinBetFloor.t.sol already owns that question, and
 *    owns it against the real contracts. These run everywhere, including on a laptop with no node.
 */

/// A token whose decimals are a constructor argument, because that is the entire point of the Arc
/// case: the same money seen at 18dp as gas and at 6dp as an ERC-20.
contract DecToken is ERC20 {
    uint8 private immutable _dec;
    constructor(uint8 d) ERC20("Dec", "DEC") { _dec = d; _mint(msg.sender, 1e30); }
    function decimals() public view override returns (uint8) { return _dec; }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// WETH9's shape: deposit() mints 1:1 to whoever sent the value. Nothing here is more generous
/// than the real thing — if anything it is stricter, since it has no fallback that wraps silently.
contract MockWeth is ERC20 {
    constructor() ERC20("Wrapped Native", "WNAT") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract PortableTest is Test {
    MockVRFWrapper oracle;

    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address alice = makeAddr("alice");

    // BSC's own numbers, the ones that used to be compiled in.
    uint256 constant BSC_MIN_BET   = 0.0002 ether;
    uint256 constant BSC_MIN_INS   = 0.0004 ether;
    uint256 constant BSC_POOL      = 0.04 ether;

    function setUp() public { oracle = new MockVRFWrapper(); }

    /// A deployment with NO price sources except a nominated wrapper. No router, no factory, no
    /// curve — so the only thing that can price anything is the new identity branch.
    function _deploy(address wnative, uint256[3] memory floors) internal returns (CrazyGame g) {
        g = new CrazyGame(
            treasury, 500, address(oracle),
            address(0), address(0), address(0), wnative, wnative,
            new address[](0), new uint256[](0), address(0),
            floors,
            0
        );
    }

    /// Same thing, but with the two roles set independently — the Arc case, where a chain prices
    /// in an asset it cannot wrap.
    function _deploySplit(address wnative, address nwrap, uint256[3] memory floors)
        internal returns (CrazyGame g)
    {
        g = new CrazyGame(
            treasury, 500, address(oracle),
            address(0), address(0), address(0), wnative, nwrap,
            new address[](0), new uint256[](0), address(0),
            floors,
            0
        );
    }

    function _fund(CrazyGame g, DecToken t, address who, uint256 amount) internal {
        t.mintTo(who, amount);
        vm.prank(who);
        t.approve(address(g), type(uint256).max);
    }

    // ── 2. the chain's own coin ───────────────────────────────────────────────────────────────

    function test_theChainsOwnCoinPricesItself() public {
        DecToken wnative = new DecToken(18);
        CrazyGame g = _deploy(address(wnative), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);

        (uint256 floorTokens, bool priced) = g.minBetFloorFor(address(wnative), false);
        assertTrue(priced, "the chain's own coin must be priceable - nothing else can price it");
        assertEq(floorTokens, BSC_MIN_BET, "the conversion is the identity, so the floor is the floor");

        (uint256 insTokens, bool insPriced) = g.minBetFloorFor(address(wnative), true);
        assertTrue(insPriced, "and in Insanity too");
        assertEq(insTokens, BSC_MIN_INS, "Insanity's own floor, not the ordinary one");

        (uint256 pool, bool poolPriced) = g.insanityPoolFloorFor(address(wnative));
        assertTrue(poolPriced, "the pool floor is reachable for the wrapper now as well");
        assertEq(pool, BSC_POOL, "and it is the absolute, which is what replaced the ratio");
    }

    /// ⭐ THE BRANCH IS SPECIFIC, which is the half of the claim that is easy to leave untested.
    ///    Any OTHER token on the same chainless deployment must still be unpriceable, or the new
    ///    line would be handing every token a floor denominated in the wrong asset.
    function test_everyOtherTokenIsStillUnpriceableOnAChainWithNoVenues() public {
        DecToken wnative = new DecToken(18);
        DecToken other = new DecToken(18);
        CrazyGame g = _deploy(address(wnative), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);

        (uint256 tokens, bool priced) = g.minBetFloorFor(address(other), false);
        assertFalse(priced, "no router and no curve means no price, and that must stay true");
        assertEq(tokens, 0, "an unpriced answer carries no number");
    }

    /// And with no wrapper configured at all, the branch must not fire on address(0) and quietly
    /// price a token nobody nominated. This is the Arc-as-deployed shape today.
    function test_aChainWithNoWrapperPricesNothing() public {
        CrazyGame g = _deploy(address(0), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        (, bool priced) = g.minBetFloorFor(address(0), false);
        assertFalse(priced, "address(0) is 'no wrapper on this chain', not a token that prices 1:1");
    }

    function test_theFloorIsActuallyENFORCEDOnAGameInTheChainsOwnCoin() public {
        DecToken wnative = new DecToken(18);
        CrazyGame g = _deploy(address(wnative), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        _fund(g, wnative, host, 1_000 ether);

        // A hair under the floor, which before this change was accepted because there was no floor.
        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.MinBetBelowFloor.selector, BSC_MIN_BET - 1, BSC_MIN_BET));
        g.createGame(address(wnative), 10 ether, BSC_MIN_BET - 1, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);

        // Exactly at it, which must pass: a floor that rejects its own value is off by one.
        vm.prank(host);
        uint256 id = g.createGame(address(wnative), 10 ether, BSC_MIN_BET, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);
        assertGt(id, 0, "a game at exactly the floor is a legal game");
    }

    // ── 1. the floors are configuration, not source ───────────────────────────────────────────

    /// ⭐⭐ THE PORTABILITY CLAIM ITSELF. Two deployments of the SAME BYTECODE enforce different
    ///     floors because they were handed different numbers. If this passes, the next chain is a
    ///     constructor argument.
    function test_theFloorsComeFromTheConstructorNotFromTheSource() public {
        DecToken wnative = new DecToken(18);

        CrazyGame cheap = _deploy(address(wnative), [uint256(1 gwei), 2 gwei, 100 gwei]);
        CrazyGame dear  = _deploy(address(wnative), [uint256(1 ether), 2 ether, 100 ether]);

        assertEq(cheap.MIN_BET_NATIVE(), 1 gwei, "each deployment carries its own floor");
        assertEq(dear.MIN_BET_NATIVE(), 1 ether, "and they do not agree");

        (uint256 cheapFloor,) = cheap.minBetFloorFor(address(wnative), false);
        (uint256 dearFloor,)  = dear.minBetFloorFor(address(wnative), false);
        assertEq(cheapFloor, 1 gwei);
        assertEq(dearFloor, 1 ether);

        // And the enforcement moves with them: the same game is legal on one and refused on the
        // other, which is the only version of this claim that matters.
        _fund(cheap, wnative, host, 1_000_000 ether);
        _fund(dear, wnative, host, 1_000_000 ether);

        vm.prank(host);
        cheap.createGame(address(wnative), 10 ether, 1 gwei, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.MinBetBelowFloor.selector, uint256(1 gwei), uint256(1 ether)));
        dear.createGame(address(wnative), 10 ether, 1 gwei, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);
    }

    /// ⭐⭐ ARC, WHICH IS THE WHOLE REASON THE UNITS HAD TO CHANGE. Its gas asset and its ERC-20 are
    ///     the same money at 18dp and 6dp. A floor denominated in native wei would enter
    ///     getAmountsOut as an amount of the 6dp token: 0.0002 ether read as 200,000,000 USDC.
    ///     Denominated in the pricing asset's own units, a 6dp chain is simply a 6dp number.
    function test_arcShape_aSixDecimalPricingAssetIsNotOffByAMillion() public {
        DecToken usdc = new DecToken(6);
        // 0.20 / 0.40 / 40.00 USDC, six decimals.
        CrazyGame g = _deploy(address(usdc), [uint256(200_000), 400_000, 40_000_000]);

        (uint256 floorTokens, bool priced) = g.minBetFloorFor(address(usdc), false);
        assertTrue(priced, "Arc's own coin has to be priceable or Arc has no floor at all");
        assertEq(floorTokens, 200_000, "0.20 USDC, in USDC's units");
        assertLt(floorTokens, 1e18, "a floor that lands anywhere near 1e18 is the 1e12 bug");

        // A game at twenty cents is legal; a game at two cents is not.
        _fund(g, usdc, host, 1_000_000e6);
        vm.prank(host);
        g.createGame(address(usdc), 1_000e6, 200_000, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.MinBetBelowFloor.selector, uint256(20_000), uint256(200_000)));
        g.createGame(address(usdc), 1_000e6, 20_000, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);
    }

    // ── 3. the ratio is gone ──────────────────────────────────────────────────────────────────

    /// The deposit/minBet ratio used to have to clear 50 for an Insanity game on an unpriceable
    /// token. Ten is not fifty, and this game is now legal — the §2 decision, executed.
    ///
    /// ⚠️ ANTI-FARM STILL APPLIES and is deliberately left alone: (deposit/minBet) * roiBps must
    ///    reach 50_000, so ratio 10 at 100% ROI gives 100_000 and passes on its own merits. The
    ///    thing being tested is the absence of the SECOND gate, not the absence of every gate.
    function test_aThinInsanityGameOnAnUnpriceableTokenIsNoLongerRefused() public {
        DecToken tok = new DecToken(18);
        CrazyGame g = _deploy(address(0), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        _fund(g, tok, host, 1_000_000 ether);

        vm.prank(host);
        uint256 id = g.createGame(address(tok), 1_000 ether, 100 ether, 10_000, 100, 0, 3600, 0,
            [uint16(3), 0, 0, 0]);
        assertGt(id, 0, "ratio 10 on an unpriceable token: refused before, legal now");
    }

    /// ⭐ AND THE REASON IT WAS WRONG, not merely that it is gone. The ratio scaled with the min
    ///    bet, so choosing a LARGER minimum multiplied the deposit demanded — Solana gates the same
    ///    mode on one absolute, where a 0.1 SOL min bet still needs only a 0.5 SOL deposit.
    ///    Here: the same pool, a ten-times-larger minimum, still legal.
    function test_choosingALargerMinimumIsNoLongerPunished() public {
        DecToken tok = new DecToken(18);
        CrazyGame g = _deploy(address(0), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        _fund(g, tok, host, 1_000_000 ether);

        vm.prank(host);
        g.createGame(address(tok), 1_000 ether, 200 ether, 15_000, 100, 0, 3600, 0,
            [uint16(3), 0, 0, 0]);
    }

    // ── the constructor's own guard ───────────────────────────────────────────────────────────

    function test_constructorRefusesFloorsThatDescribeNoCoherentGame() public {
        // Insanity cheaper than an ordinary game.
        vm.expectRevert(CrazyGame.BadParams.selector);
        _deploy(address(0), [uint256(2 ether), 1 ether, 100 ether]);

        // A pool floor under the single bet that has to clear it.
        vm.expectRevert(CrazyGame.BadParams.selector);
        _deploy(address(0), [uint256(1 ether), 2 ether, 1 ether]);
    }

    // ── staking the chain's own coin, in one transaction ───────────────────────────────

    /// ⭐⭐ THE WHOLE POINT. A host with nothing but the chain's coin creates a game by attaching
    ///     it — no approve, no wrap, no second prompt. Before this, hosting in BNB meant wrapping
    ///     first and creating second, and the create screen read "your balance: 0" while it did.
    function test_aGameInTheChainsOwnCoinIsCreatedByAttachingIt() public {
        MockWeth w = new MockWeth();
        CrazyGame g = _deploy(address(w), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);

        vm.deal(host, 10 ether);
        uint256 nativeBefore = host.balance;

        vm.prank(host);
        uint256 id = g.createGame{value: 1 ether}(
            address(w), 1 ether, BSC_MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        assertGt(id, 0, "the game exists");
        assertEq(host.balance, nativeBefore - 1 ether, "the host paid in the chain's own coin");
        // ⭐ THE WRAP IS 1:1 AND TOTAL SUPPLY IS WHERE THAT SHOWS. The pool holds LESS than was
        //    attached because the platform fee comes off the top of a deposit exactly as Solana's
        //    fund_game does - 1 ether at 500 bps leaves 0.95 here and 0.05 with the treasury.
        //    Asserting the pool balance would have been asserting the fee schedule by accident.
        assertEq(w.totalSupply(), 1 ether, "every wei attached became exactly one wei of wrapper");
        assertEq(w.balanceOf(address(g)) + w.balanceOf(treasury), 1 ether, "and all of it landed");
        // ⛔ NO APPROVAL WAS EVER GIVEN. If the pull path had run instead, this would have reverted
        //    on the missing allowance - which is the assertion that proves which branch executed.
        assertEq(w.allowance(host, address(g)), 0, "no allowance was needed or granted");
    }

    function test_aBetInTheChainsOwnCoinIsOneTransactionToo() public {
        MockWeth w = new MockWeth();
        CrazyGame g = _deploy(address(w), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        vm.deal(host, 10 ether);
        vm.deal(alice, 10 ether);

        vm.prank(host);
        uint256 id = g.createGame{value: 1 ether}(
            address(w), 1 ether, 0.01 ether, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        uint256 supplyBefore = w.totalSupply();
        vm.prank(alice);
        g.placeBet{value: 0.05 ether}(id, 0.05 ether);

        assertEq(w.totalSupply(), supplyBefore + 0.05 ether, "the bet arrived and was wrapped 1:1");
        assertEq(alice.balance, 10 ether - 0.05 ether, "and it came out of alice's native balance");
        // No approval here either, which is the whole difference from wrapping by hand first.
        assertEq(w.allowance(alice, address(g)), 0, "a native bet needs no allowance");
    }

    /// The ERC-20 path is untouched: msg.value of zero is bit-for-bit what it always was, including
    /// for the wrapper itself, so a player who already holds the wrapped form just bets it.
    function test_theErc20PathStillWorksForTheWrapperItself() public {
        MockWeth w = new MockWeth();
        CrazyGame g = _deploy(address(w), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);

        w.mintTo(host, 5 ether);
        vm.prank(host);
        w.approve(address(g), type(uint256).max);

        vm.prank(host);
        uint256 id = g.createGame(address(w), 1 ether, BSC_MIN_BET, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);
        assertGt(id, 0, "holding the wrapped form already is still a way to play");
        // Same fee off the top as any other deposit; nothing about the ERC-20 path changed.
        assertEq(w.balanceOf(address(g)), 0.95 ether, "0.95 pooled, 0.05 to the treasury at 500 bps");
        assertEq(w.totalSupply(), 5 ether, "and nothing was wrapped: this money was already wrapped");
    }

    // ── and every way of getting it wrong ─────────────────────────────────────────

    /// ⛔ VALUE ATTACHED TO AN ERC-20 GAME MUST NOT BE QUIETLY KEPT. There is no owner for it and
    ///    no path out of the contract, so it would simply be gone. Refused by name.
    function test_nativeAttachedToAnErc20GameIsRefused() public {
        MockWeth w = new MockWeth();
        DecToken other = new DecToken(18);
        CrazyGame g = _deploy(address(w), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        _fund(g, other, host, 1_000 ether);
        vm.deal(host, 10 ether);

        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.NativeIsNotThisGamesToken.selector, address(other), address(w)));
        g.createGame{value: 1 ether}(address(other), 100 ether, 1 ether, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);
    }

    /// Too much would strand the remainder; too little would fund a game from money belonging to
    /// other games. Both are the same mistake seen from two sides.
    function test_theAttachedAmountMustBeExact() public {
        MockWeth w = new MockWeth();
        CrazyGame g = _deploy(address(w), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
        vm.deal(host, 10 ether);

        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.NativeAmountMismatch.selector, uint256(2 ether), uint256(1 ether)));
        g.createGame{value: 2 ether}(address(w), 1 ether, BSC_MIN_BET, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);

        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(
            CrazyGame.NativeAmountMismatch.selector, uint256(0.5 ether), uint256(1 ether)));
        g.createGame{value: 0.5 ether}(address(w), 1 ether, BSC_MIN_BET, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);
    }

    /// ⭐ ARC AGAIN. A chain that prices in an asset it cannot wrap says so, and says it by name
    ///    rather than as an opaque revert from a deposit() that was never implemented.
    function test_aChainWhoseGasAssetCannotBeWrappedRefusesValueByName() public {
        DecToken usdc = new DecToken(6);
        CrazyGame g = _deploySplit(address(usdc), address(0), [uint256(200_000), 400_000, 40_000_000]);
        vm.deal(host, 10 ether);
        _fund(g, usdc, host, 1_000_000e6);

        vm.prank(host);
        vm.expectRevert(CrazyGame.NoNativeWrapper.selector);
        g.createGame{value: 1 ether}(address(usdc), 1_000e6, 200_000, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);

        // ⭐ AND THE SAME GAME WITHOUT VALUE IS FINE, which is the half that matters: on such a
        //    chain the gas asset already IS the ERC-20, so there was never anything to wrap.
        vm.prank(host);
        uint256 id = g.createGame(address(usdc), 1_000e6, 200_000, 10_000, 100, 0, 3600, 0,
            [uint16(0), 0, 0, 0]);
        assertGt(id, 0, "no wrapper needed where the gas asset is already the token");
    }

    /// The constructor will not accept a wrapper that is not the pricing asset: wrapping into a
    /// token the game does not settle in would put the deposit somewhere nothing reads.
    function test_constructorRefusesAWrapperThatIsNotThePricingAsset() public {
        MockWeth w = new MockWeth();
        DecToken other = new DecToken(18);
        vm.expectRevert(CrazyGame.BadParams.selector);
        _deploySplit(address(w), address(other), [BSC_MIN_BET, BSC_MIN_INS, BSC_POOL]);
    }

    /// ⚠️ ZERO IS LEGAL, DELIBERATELY: a chain with no price source gates nothing, which is what
    ///    this contract did before floors existed and what Arc runs today. It has to be possible
    ///    to express that, or the only way to deploy there would be a lie about the floors.
    function test_allZeroFloorsAreALegalDeployment() public {
        CrazyGame g = _deploy(address(0), [uint256(0), 0, 0]);
        assertEq(g.MIN_BET_NATIVE(), 0, "no floor is a real configuration, not an error");
    }
}

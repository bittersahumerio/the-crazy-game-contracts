// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {FeeTiers} from "../contracts/FeeTiers.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";

contract Tok is ERC20 {
    constructor(string memory s) ERC20(s, s) { _mint(msg.sender, 1_000_000_000 ether); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// A registry that cannot answer. The game must fall through to its default rather than revert —
/// a broken tier list is not a reason nobody can start a game.
contract RevertingTiers {
    function feeFor(address) external pure returns (uint256) { revert("nope"); }
}

/**
 * The platform fee, in three tiers — and the two bounds this port invented and has now given back
 * to Solana's numbers.
 *
 * Every fee assertion here is made on MONEY THAT MOVED (the treasury's balance), not on a getter.
 * The fee is charged in two different places, at creation and on every bet, and a snapshot that
 * only the getter respects would be exactly the bug this is defending against.
 */
contract FeeTiersTest is Test {
    CrazyGame game;
    FeeTiers tiers;
    MockVRFWrapper oracle;
    Tok plain;      // no tier: pays the default
    Tok curated;    // curated at deployment
    Tok padded;     // given a tier by the registry

    address treasury = makeAddr("treasury");
    address owner = makeAddr("tiersOwner");
    address host = makeAddr("host");
    address alice = makeAddr("alice");

    uint256 constant DEFAULT_BPS = 500;   // 5%, matching Solana's self-serve tier
    uint256 constant CURATED_BPS = 300;   // 3%, matching Solana's curated tier
    uint256 constant PAD_BPS     = 400;   // 4%, coins launched at our own pad

    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant MIN_BET = 100 ether;

    function setUp() public {
        oracle = new MockVRFWrapper();
        plain = new Tok("PLAIN");
        curated = new Tok("CURATED");
        padded = new Tok("PADDED");
        tiers = new FeeTiers(owner);

        address[] memory ct = new address[](1);
        uint256[] memory cf = new uint256[](1);
        ct[0] = address(curated);
        cf[0] = CURATED_BPS;

        game = new CrazyGame(treasury, DEFAULT_BPS, address(oracle),
            address(0), address(0), address(0), address(0), address(0), ct, cf, address(tiers),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);

        address[2] memory who = [host, alice];
        Tok[3] memory toks = [plain, curated, padded];
        for (uint256 i; i < who.length; i++) {
            for (uint256 j; j < toks.length; j++) {
                toks[j].mintTo(who[i], 10_000_000 ether);
                vm.prank(who[i]);
                toks[j].approve(address(game), type(uint256).max);
            }
        }
    }

    function _newGame(Tok t) internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(t), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);
    }

    // ── the three tiers ───────────────────────────────────────────────────────────────────────

    function test_defaultIsFivePercent() public view {
        assertEq(game.platformFeeBps(), DEFAULT_BPS);
        assertEq(game.feeForToken(address(plain)), DEFAULT_BPS);
    }

    function test_curatedPaysThree_onTheDepositAndOnEveryBet() public {
        assertEq(game.feeForToken(address(curated)), CURATED_BPS);

        uint256 before = curated.balanceOf(treasury);
        uint256 id = _newGame(curated);
        assertEq(curated.balanceOf(treasury) - before, DEPOSIT * CURATED_BPS / 10_000,
            "the deposit must pay the curated rate");

        before = curated.balanceOf(treasury);
        vm.prank(alice);
        game.placeBet(id, MIN_BET);
        assertEq(curated.balanceOf(treasury) - before, MIN_BET * CURATED_BPS / 10_000,
            "and so must every bet");
    }

    function test_registryLowersToFour() public {
        vm.prank(owner);
        tiers.setFee(address(padded), PAD_BPS);
        assertEq(game.feeForToken(address(padded)), PAD_BPS);

        uint256 before = padded.balanceOf(treasury);
        _newGame(padded);
        assertEq(padded.balanceOf(treasury) - before, DEPOSIT * PAD_BPS / 10_000);
    }

    /// ⛔ THE CLAMP. A registry can only ever discount, and only down to the floor.
    function test_registryCannotRaiseAboveTheDefault() public {
        vm.prank(owner);
        tiers.setFee(address(padded), 900);
        assertEq(game.feeForToken(address(padded)), DEFAULT_BPS, "900 must be ignored, not charged");
    }

    function test_registryCannotGoBelowTheFloor() public {
        vm.prank(owner);
        tiers.setFee(address(padded), 100);
        assertEq(game.feeForToken(address(padded)), DEFAULT_BPS, "under the floor falls back");
        // Read the floor BEFORE the prank: vm.prank arms the very next call, and an argument that
        // is itself a call would eat it.
        uint256 floor = game.MIN_FEE_BPS();
        vm.prank(owner);
        tiers.setFee(address(padded), floor);
        assertEq(game.feeForToken(address(padded)), floor, "the floor itself is allowed");
    }

    function test_curatedBeatsTheRegistry() public {
        vm.prank(owner);
        tiers.setFee(address(curated), 499);
        assertEq(game.feeForToken(address(curated)), CURATED_BPS, "a deployment-time tier wins");
    }

    /// A registry that reverts must not be able to stop anyone hosting a game.
    function test_aBrokenRegistryFallsThroughToTheDefault() public {
        CrazyGame g2 = new CrazyGame(treasury, DEFAULT_BPS, address(oracle),
            address(0), address(0), address(0), address(0), address(0),
            new address[](0), new uint256[](0), address(new RevertingTiers()),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        assertEq(g2.feeForToken(address(plain)), DEFAULT_BPS);
    }

    function test_noRegistryAtAll() public {
        CrazyGame g2 = new CrazyGame(treasury, DEFAULT_BPS, address(oracle),
            address(0), address(0), address(0), address(0), address(0),
            new address[](0), new uint256[](0), address(0),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        assertEq(g2.feeForToken(address(plain)), DEFAULT_BPS);
    }

    /// ⭐ THE ONE THAT MATTERS MOST: a tier change must never move a game that already exists. Its
    /// ROI target and its solvency were set against the fee it was created with.
    function test_theFeeIsSnapshottedAtCreation() public {
        uint256 id = _newGame(padded);                   // created at the 5% default

        vm.prank(owner);
        tiers.setFee(address(padded), PAD_BPS);          // the registry drops it to 4% afterwards
        assertEq(game.feeForToken(address(padded)), PAD_BPS, "new games would get 4%");

        uint256 before = padded.balanceOf(treasury);
        vm.prank(alice);
        game.placeBet(id, MIN_BET);
        assertEq(padded.balanceOf(treasury) - before, MIN_BET * DEFAULT_BPS / 10_000,
            "the running game must keep charging the fee it was created with");
    }

    // ── what the constructor refuses ──────────────────────────────────────────────────────────

    function test_constructorRefusesBadCuratedEntries() public {
        address[] memory ct = new address[](1);
        uint256[] memory cf = new uint256[](1);

        ct[0] = address(curated);
        cf[0] = DEFAULT_BPS + 1;                       // a curated coin may never pay MORE
        vm.expectRevert(CrazyGame.BadParams.selector);
        new CrazyGame(treasury, DEFAULT_BPS, address(oracle), address(0), address(0), address(0), address(0), address(0), ct, cf, address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);

        cf[0] = 100;                                   // nor less than the floor
        vm.expectRevert(CrazyGame.BadParams.selector);
        new CrazyGame(treasury, DEFAULT_BPS, address(oracle), address(0), address(0), address(0), address(0), address(0), ct, cf, address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);

        ct[0] = address(0);
        cf[0] = CURATED_BPS;
        vm.expectRevert(CrazyGame.BadParams.selector);
        new CrazyGame(treasury, DEFAULT_BPS, address(oracle), address(0), address(0), address(0), address(0), address(0), ct, cf, address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);

        vm.expectRevert(CrazyGame.BadParams.selector);   // lengths must match
        new CrazyGame(treasury, DEFAULT_BPS, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](2), cf, address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);

        vm.expectRevert(CrazyGame.BadParams.selector);   // a default under the floor makes the clamp a lie
        new CrazyGame(treasury, 200, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
    }

    // ── the registry's own rules ──────────────────────────────────────────────────────────────

    function test_onlyTheOwnerSetsFees() public {
        vm.expectRevert(FeeTiers.NotOwner.selector);
        tiers.setFee(address(padded), PAD_BPS);

        vm.prank(owner);
        vm.expectRevert(FeeTiers.BadParams.selector);
        tiers.setFee(address(padded), 1_001);          // the game's own ceiling, enforced here too

        vm.prank(owner);
        vm.expectRevert(FeeTiers.BadParams.selector);
        tiers.transferOwnership(address(0));           // renouncing would freeze every tier forever

        vm.prank(owner);
        tiers.transferOwnership(alice);
        assertEq(tiers.owner(), alice);
    }

    function test_setFeesInABatch() public {
        address[] memory t = new address[](2);
        uint256[] memory b = new uint256[](2);
        t[0] = address(padded); b[0] = PAD_BPS;
        t[1] = address(plain);  b[1] = PAD_BPS;
        vm.prank(owner);
        tiers.setFees(t, b);
        assertEq(game.feeForToken(address(padded)), PAD_BPS);
        assertEq(game.feeForToken(address(plain)), PAD_BPS);
    }

    // ── the two bounds that were this port's invention ────────────────────────────────────────

    function test_timerFloorIsSixtySecondsLikeSolana() public {
        vm.prank(host);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 0, 60, 0, [uint16(0), 0, 0, 0]);

        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 0, 59, 0, [uint16(0), 0, 0, 0]);
    }

    /// ⭐ THE SLOW BURN CASE. A 20-minute timer that gains 2 hours per bet is a SHIPPED preset on
    /// Solana, and the old `timeIncrement <= timerDuration` bound made it impossible here.
    function test_theIncrementMayOutrunTheTimer() public {
        vm.prank(host);
        uint256 id = game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 1, 1200, 7200, [uint16(0), 0, 0, 0]);
        assertGt(id, 0);
    }

    function test_incrementBoundsAreSolanasOwn() public {
        vm.startPrank(host);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 60, [uint16(0), 0, 0, 0]);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 7200, [uint16(0), 0, 0, 0]);

        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 59, [uint16(0), 0, 0, 0]);

        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 7201, [uint16(0), 0, 0, 0]);

        vm.expectRevert(CrazyGame.BadParams.selector);   // a vanilla timer still takes no increment
        game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 60, [uint16(0), 0, 0, 0]);
        vm.stopPrank();
    }
}

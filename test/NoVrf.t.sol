// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * ⛔⛔ THE ARC DEPLOYMENT, TESTED AS A DEPLOYMENT: the same bytecode with NO ORACLE BEHIND IT.
 *
 * Arc has no Chainlink VRF v2.5 (it joined Chainlink's Scale programme, which is not the same
 * thing), so Insanity cannot run there at launch. The contract already carries the answer — the
 * constructor's own words: "Not validated, and not dereferenced: address(0) is the meaningful
 * 'this chain has no oracle' value, and createGame refuses mode 3 on it."
 *
 * ⭐ SO THERE IS NO SECOND VERSION OF THIS CONTRACT, AND THERE MUST NOT BE. The difference between
 *    the Arc build and the BNB build is ONE CONSTRUCTOR ARGUMENT. Two source files would mean two
 *    copies of a 1,560-line money contract, and a fix applied to one would silently miss the other
 *    — the divergence this project has already paid for more than once. The saving would have been
 *    about one cent of deploy gas: a full deploy on Arc is ~$0.09 at 25 gwei.
 *
 * ⚠️ AND UNTIL NOW NOTHING EXERCISED IT. Every other test in this suite deploys a live
 *    MockVRFWrapper, so the deployment Arc will actually run had never been instantiated once. An
 *    argument that is only ever passed as a non-zero address is not a tested argument.
 */

/// Plain 18-decimal token. Local by convention: every test file in this suite defines its own
/// mocks rather than importing across test files.
contract NoVrfToken is ERC20 {
    constructor() ERC20("NoVrf", "NV") { _mint(msg.sender, 1_000_000_000 ether); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract NoVrfTest is Test {
    CrazyGame game;
    NoVrfToken tok;

    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant MIN_BET = 100 ether;

    /// ⛔ THE ONLY DIFFERENCE FROM THE REST OF THE SUITE IS THE THIRD ARGUMENT. No oracle is
    ///    deployed in this file at all — not a mock, not a stub. If any path reached for one, it
    ///    would be reaching for address(0).
    function setUp() public {
        game = new CrazyGame(
            treasury, 500, address(0),
            address(0), address(0), address(0), address(0), address(0),
            new address[](0), new uint256[](0), address(0),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether],
            0
        );
        tok = new NoVrfToken();
        address[4] memory all = [host, alice, bob, carol];
        for (uint256 i; i < 4; i++) {
            tok.mintTo(all[i], 10_000_000 ether);
            vm.prank(all[i]);
            tok.approve(address(game), type(uint256).max);
        }
    }

    function _game(uint16 mode, uint16 bps, uint16 step, uint16 cap) internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [mode, bps, step, cap]);
    }

    // ── what every other service reads ────────────────────────────────────────────────────────

    /// ⭐ THIS IS THE FLAG THE WHOLE STACK KEYS OFF. The indexer reads `vrfWrapper` (actor.js) and
    /// the wallet bot turns it into `rules.insanity`, which is what makes the launch form say
    /// "Insanity needs a randomness oracle, and this chain has none". One read, three services.
    function test_theDeploymentArcWillRun_reportsNoOracle() public view {
        assertEq(address(game.vrfWrapper()), address(0), "an Arc deployment must report no oracle");
    }

    // ── the refusal ───────────────────────────────────────────────────────────────────────────

    /// ⛔ REFUSED AT CREATION, AND — THE PART THAT MATTERS — BEFORE ANY MONEY MOVES. The contract's
    /// own comment claims exactly this: "refuse at creation, when it is still free to choose
    /// another mode, instead of at the first salvation when there is money in the pot." A revert
    /// AFTER the deposit was pulled would still be a revert, and the claim would still be false.
    function test_insanityRefusedAtCreation_beforeAnyMoneyMoves() public {
        uint256 balBefore = tok.balanceOf(host);
        uint256 gameBefore = tok.balanceOf(address(game));

        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(3), 0, 0, 0]);

        assertEq(tok.balanceOf(host), balBefore, "a refused Insanity game must not cost the host a token");
        assertEq(tok.balanceOf(address(game)), gameBefore, "and nothing may be left sitting in the contract");
    }

    /// Not one unlucky value: the whole ROI band Insanity is legal at (50%-150%) is refused, so the
    /// refusal is about the ORACLE and not about some other parameter happening to be out of range.
    function test_insanityRefusedAcrossItsWholeRoiBand() public {
        for (uint256 roi = 5_000; roi <= 15_000; roi += 2_500) {
            vm.prank(host);
            vm.expectRevert(CrazyGame.BadParams.selector);
            game.createGame(address(tok), DEPOSIT, MIN_BET, roi, 100, 0, 3600, 0, [uint16(3), 0, 0, 0]);
        }
    }

    /// The fallback path exists for a salvation whose oracle never answered. With no oracle, no
    /// mode-3 game can exist, so no salvation can stall — and poking it must not find anything.
    function test_theStalledSalvationPathHasNothingToSettle() public {
        vm.expectRevert();
        game.settleStalledSalvation(0);
        vm.expectRevert();
        game.settleStalledSalvation(1);
    }

    // ── and everything else still works ───────────────────────────────────────────────────────

    /// ⭐ THE OTHER HALF OF THE CLAIM. Refusing Insanity is only correct if the rest of the product
    /// is untouched — otherwise "no oracle" would quietly mean "no game".
    function test_everyOtherModeCreates() public {
        uint256 off = _game(0, 0, 0, 0);
        uint256 fixed_ = _game(1, 200, 0, 0);
        uint256 progressive = _game(2, 100, 20, 250);
        // Sequential, not zero-based: ids come from a counter whose first value is 1. Asserting the
        // RELATIONSHIP rather than the literals keeps this about the modes, which is what it tests.
        assertEq(fixed_, off + 1);
        assertEq(progressive, off + 2);
        uint256[3] memory ids = [off, fixed_, progressive];
        for (uint256 i; i < 3; i++) {
            (uint256 pool,) = game.balancesOf(ids[i]);
            assertGt(pool, 0, "every non-Insanity mode must fund its pool normally");
        }
    }

    function _findSaviour(uint256 id, uint256 betId) internal view returns (uint256) {
        uint256 threshold = game.maturityThresholdOf(id, betId);
        uint256 n = game.betCountOf(id);
        for (uint256 i = betId + 1; i < n; i++) {
            (,,,, uint256 cumAtJoin,,,,) = game.bets(id, i);
            if (cumAtJoin >= threshold) return i;
        }
        revert("no saviour: bet has not matured");
    }

    function _runUntilMatured(uint256 id, uint256 betId) internal {
        for (uint256 i; i < 60; i++) {
            (,, uint256 target,,,,,,) = game.bets(id, betId);
            if (game.accumulatedOf(id, betId) >= target) return;
            vm.prank(i % 2 == 0 ? bob : carol);
            game.placeBet(id, 5_000 ether);
        }
        revert("never matured");
    }

    /// ⛔ A SALVATION SETTLING WITH NO ORACLE IN THE WORLD. Modes 1 and 2 draw their rate from the
    /// host's own configuration, never from randomness — so this is the path that proves the
    /// feature survives the port, rather than merely failing to crash.
    function test_fixedSalvationPaysWithNoOracle() public {
        uint256 id = _game(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        uint256 saviour = _findSaviour(id, a);
        (address who,,,,, uint256 owedBefore,,,) = game.bets(id, saviour);
        uint256 balBefore = tok.balanceOf(who);

        game.reserveRoiWithSalvation(id, a, saviour);

        (,,,,, uint256 owedAfter,,,) = game.bets(id, saviour);
        uint256 paid = (tok.balanceOf(who) - balBefore) + (owedAfter - owedBefore);
        assertGt(paid, 0, "the saviour must be paid a bounty on a chain with no oracle");

        (uint256 pool, uint256 reserved) = game.balancesOf(id);
        assertLe(reserved, pool, "INSOLVENT: reserved exceeds pool");
    }

    /// A whole game, start to jackpot, on the Arc deployment.
    function test_aGameRunsToItsJackpotWithNoOracle() public {
        uint256 id = _game(0, 0, 0, 0);
        vm.prank(alice);
        game.placeBet(id, 1_000 ether);
        vm.prank(bob);
        game.placeBet(id, 2_000 ether);

        // Past the timer, then past the claim delay the contract imposes on the winner.
        vm.warp(block.timestamp + 3_600 + 1);
        vm.warp(block.timestamp + game.JACKPOT_DELAY() + 1);

        uint256 before = tok.balanceOf(bob);
        vm.prank(bob);
        game.claimJackpot(id);
        assertGt(tok.balanceOf(bob), before, "the last bettor must be able to claim with no oracle present");
    }
}

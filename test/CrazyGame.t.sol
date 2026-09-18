// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";

/// Exposes the internal rate table so it can be asserted directly at its boundaries, rather than
/// inferred from a handful of end-to-end runs.
contract ExposedGame is CrazyGame {
    constructor(address t, uint256 f, address e)
        // No price sources: every token is unpriceable, so no floor is ever consulted and this
        // harness behaves exactly as it did before floors existed. The numbers are BSC's, and are
        // passed rather than zeroed so that a harness which later DOES configure a price source
        // inherits a real floor instead of a silently permissive one.
        CrazyGame(t, f, e, address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0) {}
    function randomBps(uint256 r) external pure returns (uint16) { return _randomBps(r); }
}

/// Plain 18-decimal token.
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") { _mint(msg.sender, 1_000_000_000 ether); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// Taxes EVERY transfer. This is the case the measured-balance code exists for — NOT four.meme's
/// tax tokens, which only charge on LP-pair trades. Arbitrary BSC tokens do this.
contract TaxToken is ERC20 {
    uint256 public immutable taxBps;
    constructor(uint256 _taxBps) ERC20("Tax", "TAX") { taxBps = _taxBps; _mint(msg.sender, 1_000_000_000 ether); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && taxBps > 0) {
            uint256 fee = (value * taxBps) / 10_000;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract CrazyGameTest is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    MockToken tok;
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant MIN_BET = 100 ether;

    function setUp() public {
        oracle = new MockVRFWrapper();
        game = new CrazyGame(treasury, 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0); // 3% platform fee
        tok = new MockToken();
        address[4] memory all = [host, alice, bob, carol];
        for (uint256 i; i < 4; i++) {
            address who = all[i];
            tok.mintTo(who, 10_000_000 ether);
            vm.prank(who);
            tok.approve(address(game), type(uint256).max);
        }
    }

    function _newGame() internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0),0,0,0]);
    }

    // ── THE INVARIANT THAT MATTERS ────────────────────────────────────────────────────────────
    // The contract must never owe more than it holds. Every other guarantee rests on this one:
    // if reserved ever exceeds pool, a matured bet is being paid with another player's money.
    function _assertSolvent(uint256 id) internal view {
        (uint256 pool, uint256 reserved) = game.balancesOf(id);
        assertLe(reserved, pool, "INSOLVENT: reserved exceeds pool");
    }

    function test_hostDepositIsBetZeroNetOfFee() public {
        uint256 id = _newGame();
        uint256 fee = (DEPOSIT * 300) / 10_000;      // 3% platform fee
        uint256 net = DEPOSIT - fee;

        (address player, uint256 betNet,,,,,,,) = game.bets(id, 0);
        assertEq(player, host);
        // The host's deposit pays the platform fee like any other bet, matching Solana's fund_game.
        assertEq(betNet, net, "bet 0 must be the deposit NET of the platform fee");
        // The lesson from the Solana side: money that entered a game is SUM(bets) alone. Adding the
        // deposit to it double-counts, because the deposit IS bet 0.
        (uint256 pool,) = game.balancesOf(id);
        assertEq(pool, net, "only the net deposit is in the pool");
    }

    /// ⭐ The create fee is what the off-chain points ledger credits a host for STARTING a game, and
    /// what the 2x/3x action multipliers scale. If it stops reaching the treasury, hosts silently
    /// stop earning Seeds and nothing else breaks loudly enough to notice.
    function test_createChargesPlatformFeeToTreasury() public {
        uint256 before = tok.balanceOf(treasury);
        uint256 id = _newGame();
        uint256 fee = (DEPOSIT * 300) / 10_000;
        assertEq(tok.balanceOf(treasury) - before, fee, "create fee must reach the treasury");

        // And the contract holds exactly what it says it holds.
        (uint256 pool,) = game.balancesOf(id);
        assertEq(tok.balanceOf(address(game)), pool);
    }

    /// The events ARE the ledger's input, so their numbers must reconcile without re-derivation:
    /// gross = net + platformFee + hostFee, exactly, with no rounding gap to guess at.
    function test_eventsCarryReconcilableFeeAmounts() public {
        uint256 id = _newGame();

        vm.recordLogs();
        vm.prank(alice);
        game.placeBet(id, 1_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != keccak256("BetPlaced(uint256,uint256,address,uint256,uint256,uint256,uint256,uint256)")) continue;
            (uint256 gross, uint256 net, uint256 pFee, uint256 hFee,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertEq(gross, 1_000 ether, "gross must be what actually arrived");
            assertEq(net + pFee + hFee, gross, "the three parts must sum to the gross exactly");
            assertEq(pFee, (gross * 300) / 10_000);
            found = true;
        }
        assertTrue(found, "BetPlaced was not emitted with the expected signature");
    }

    function test_betNeverEarnsFromItself() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 b = game.placeBet(id, 1_000 ether);
        assertEq(game.accumulatedOf(id, b), 0, "a fresh bet must start at zero accumulation");
    }

    function test_roiMaturesAndPaysExactly() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);

        // Push money in until Alice matures.
        for (uint256 i; i < 40; i++) {
            vm.prank(i % 2 == 0 ? bob : carol);
            game.placeBet(id, 5_000 ether);
            _assertSolvent(id);
        }

        (,, uint256 target,,,,,,) = game.bets(id, a);
        assertGe(game.accumulatedOf(id, a), target, "alice should have matured");

        uint256 before = tok.balanceOf(alice);
        vm.prank(alice);
        game.withdraw(id, a);
        assertEq(tok.balanceOf(alice) - before, target, "must pay exactly the ROI target");
        _assertSolvent(id);
    }

    /**
     * ⭐ NEITHER STEP MOVES THE JACKPOT, AND THAT IS THE CHANGE OF 2026-08-16.
     *
     * This test used to be called test_reserveMovesJackpot_withdrawDoesNot and asserted that
     * reserving made the jackpot FALL by exactly the ROI target. That was true and it was the
     * problem: it meant a matured bet's ROI counted as jackpot right up until somebody happened to
     * call reserveRoi, so the displayed pot included money that was already owed — and both the
     * Salvador bounty and claimJackpot spent it.
     *
     * jackpotOf now subtracts already-matured, not-yet-reserved ROI, so the money leaves the pot the
     * moment it is EARNED rather than the moment it is noticed. Reserving is then pure bookkeeping
     * and moves nothing, which is also better for the UI: the pot no longer drops when a stranger
     * calls a permissionless function.
     *
     * The old ordering trap this test was written for still applies, just inverted — if either
     * assertion below ever starts failing by exactly one ROI target, someone has put the
     * matured-but-unreserved money back into the jackpot's column.
     */
    function test_reserveRoiPaysThePlayerAndMovesTheJackpotOnce() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        for (uint256 i; i < 40; i++) {
            vm.prank(i % 2 == 0 ? bob : carol);
            game.placeBet(id, 5_000 ether);
        }

        (,, uint256 target,,,,,,) = game.bets(id, a);
        assertGe(game.accumulatedOf(id, a), target, "setup: the bet must have matured");
        uint256 jackpotBefore = game.jackpotOf(id);
        uint256 aliceBefore = tok.balanceOf(alice);

        // ⭐ CALLED BY THE TEST CONTRACT, NOT BY ALICE. That is the whole change: a stranger — the
        // indexer, a bot, another player — settles her ROI and the tokens land in HER wallet. She
        // never has to show up, which is what stops matured money sitting in the pool waiting to be
        // swept into the jackpot.
        game.reserveRoi(id, a);

        assertEq(tok.balanceOf(alice) - aliceBefore, target, "the player must be paid, by anyone");
        assertEq(game.jackpotOf(id), jackpotBefore - target, "and the pot falls by exactly that once");
        _assertSolvent(id);

        // There is no second step left to take. `withdraw` survives as an alias, so it reverts the
        // same way a repeat reserve does rather than paying twice.
        vm.prank(alice);
        vm.expectRevert(CrazyGame.AlreadyDone.selector);
        game.withdraw(id, a);
        assertEq(tok.balanceOf(alice) - aliceBefore, target, "and never pays twice");
    }

    function test_lastBettorTakesJackpotAfterDelay() public {
        uint256 id = _newGame();
        vm.prank(alice);
        game.placeBet(id, 1_000 ether);
        vm.prank(bob);
        game.placeBet(id, 2_000 ether);

        uint256 timerEnd = game.timerEndOf(id);

        vm.warp(timerEnd + 1);
        vm.prank(bob);
        vm.expectRevert(CrazyGame.NotYet.selector);
        game.claimJackpot(id);      // delay not elapsed

        vm.warp(timerEnd + 301);
        vm.prank(alice);
        vm.expectRevert(CrazyGame.NotYours.selector);
        game.claimJackpot(id);      // alice was not last

        uint256 before = tok.balanceOf(bob);
        vm.prank(bob);
        game.claimJackpot(id);
        assertGt(tok.balanceOf(bob) - before, 0);
        _assertSolvent(id);
    }

    /**
     * ⭐ A BET THAT MATURED BEFORE THE GAME ENDED IS STILL PAID AFTER IT — and the theft path that
     * used to make this impossible is now closed by arithmetic instead of by a flat refusal.
     *
     * This test was test_cannotReserveAfterJackpot and asserted GameOver. The refusal existed because
     * claimJackpot took everything unreserved, so afterwards `pool == reserved` and any further
     * reserve drew on other players' money — the Solana review's theft path. The cost of that
     * defence was that a matured player who simply did nothing lost their ROI to the last bettor.
     *
     * Now claimJackpot leaves exactly the matured-but-unreserved total behind, so `pool - reserved`
     * afterwards is precisely what those bets are owed, and the solvency floor refuses anything
     * past it. The refusal is unnecessary and the loss is gone.
     *
     * ⚠️ The important half is the second one: an UNMATURED bet must still get nothing. Their money
     * genuinely did go to the winner — that is the game.
     */
    function test_maturedBetIsStillPayableAfterTheJackpotIsClaimed() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);       // small: matures easily
        for (uint256 i; i < 40; i++) {
            vm.prank(bob);
            game.placeBet(id, 5_000 ether);
        }
        vm.prank(carol);
        uint256 late = game.placeBet(id, 50_000 ether);   // huge: cannot mature before the end

        (,, uint256 target,,,,,,) = game.bets(id, a);
        assertGe(game.accumulatedOf(id, a), target, "setup: alice's bet must have matured");
        (,, uint256 lateTarget,,,,,,) = game.bets(id, late);
        assertLt(game.accumulatedOf(id, late), lateTarget, "setup: carol's bet must NOT have matured");

        // ⭐ THE SWEEP, which is the indexer's whole job and now pays as it goes. One permissionless
        // pass before the claim and every earned token is in its owner's wallet.
        uint256 aliceBefore = tok.balanceOf(alice);
        for (uint256 b; b < game.betCountOf(id); b++) {
            (,, uint256 t,,,, bool res,,) = game.bets(id, b);
            if (res) continue;
            if (game.accumulatedOf(id, b) >= t) game.reserveRoi(id, b);
        }
        assertEq(tok.balanceOf(alice) - aliceBefore, target, "alice is paid without ever showing up");

        vm.warp(game.timerEndOf(id) + 301);
        address winner = game.lastBettorOf(id);
        uint256 winnerBefore = tok.balanceOf(winner);
        vm.prank(winner);
        game.claimJackpot(id);
        assertGt(tok.balanceOf(winner) - winnerBefore, 0, "and the winner still gets the pot");
        _assertSolvent(id);

        // Carol never matured, so she gets nothing — her stake went to the winner, which is the game.
        vm.expectRevert(CrazyGame.RoiNotReached.selector);
        game.reserveRoi(id, late);
    }

    /**
     * ⚠️ THE COST OF THE TRADE, PINNED SO IT IS A DECISION AND NOT A DRIFT.
     *
     * Auto-payout means a matured bet is settled by ONE permissionless call — but somebody still has
     * to make it. If nobody does before claimJackpot, that ROI is swept to the last bettor and it is
     * gone, exactly as on Solana, where `checkAndReserveRois` is what prevents it.
     *
     * This was briefly closed on-chain (jackpotOf subtracted matured-but-unpaid ROI) and the cure was
     * worse: O(betCount) on the one function that must work at end of game, which made a pot
     * permanently unclaimable for about $1,900 of gas at ~15,800 bets.
     *
     * ⇒ The defence is operational: reserve.js sweeps after every bet, JACKPOT_DELAY gives 300s of
     * grace, and the call is permissionless so any player or bot can do it. If that ever proves
     * insufficient, the fix is a maturity heap — NOT a loop in jackpotOf.
     */
    function test_characterize_maturedButUnsweptRoiIsStillLostToTheJackpot() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        (,, uint256 target,,,,,,) = game.bets(id, a);
        assertGe(game.accumulatedOf(id, a), target, "setup: matured");
        assertGe(game.jackpotOf(id), target, "and the pot still contains what she is owed");

        // Nobody sweeps. The game ends.
        vm.warp(game.timerEndOf(id) + 301);
        vm.prank(game.lastBettorOf(id));
        game.claimJackpot(id);

        vm.expectRevert();   // NotYet from the solvency floor: the money left with the winner
        game.reserveRoi(id, a);
    }

    function test_betAfterExpiryReverts() public {
        uint256 id = _newGame();
        uint256 timerEnd = game.timerEndOf(id);
        vm.warp(timerEnd + 1);
        vm.prank(alice);
        vm.expectRevert(CrazyGame.TimerExpired.selector);
        game.placeBet(id, 1_000 ether);
    }

    /// A token that taxes every transfer must still leave the contract solvent — the amount credited
    /// has to be what ARRIVED, not what was asked for.
    function test_feeOnTransferTokenStaysSolvent() public {
        TaxToken tt = new TaxToken(500); // 5% on every transfer
        address[3] memory who = [host, alice, bob];
        for (uint256 i; i < 3; i++) {
            tt.mintTo(who[i], 10_000_000 ether);
            vm.prank(who[i]);
            tt.approve(address(game), type(uint256).max);
        }
        vm.prank(host);
        uint256 id = game.createGame(address(tt), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0),0,0,0]);

        (uint256 pool,) = game.balancesOf(id);
        assertLt(pool, DEPOSIT, "a taxed deposit must be credited at what arrived, not what was sent");
        assertGe(tt.balanceOf(address(game)), pool, "contract must hold at least what it credits");

        for (uint256 i; i < 20; i++) {
            vm.prank(i % 2 == 0 ? alice : bob);
            game.placeBet(id, 5_000 ether);
            _assertSolvent(id);
            (uint256 p,) = game.balancesOf(id);
            assertGe(tt.balanceOf(address(game)), p, "credited more than held");
        }
    }

    // ── FUZZ: the accumulator under arbitrary traffic ────────────────────────────────────────
    function testFuzz_solventUnderArbitraryBets(uint96[10] memory amounts) public {
        uint256 id = _newGame();
        for (uint256 i; i < amounts.length; i++) {
            uint256 amt = uint256(amounts[i]);
            if (amt < MIN_BET || amt > 1_000_000 ether) continue;
            address[3] memory pool3 = [alice, bob, carol];
            address who = pool3[i % 3];
            vm.prank(who);
            game.placeBet(id, amt);
            _assertSolvent(id);
        }
        // And the contract must actually hold what it says it does.
        (uint256 pool,) = game.balancesOf(id);
        assertGe(tok.balanceOf(address(game)), pool, "contract holds less than its pool balance");
    }

    // ═══ SALVADOR (modes 1 and 2 — deterministic, no oracle) ═════════════════════════════════

    /// What an indexer would do off-chain: find the bet that pushed betId over its ROI target.
    /// The contract then VERIFIES this in O(1) rather than trusting it — which is what removes the
    /// operator that the Solana version needs.
    function _findSaviour(uint256 id, uint256 betId) internal view returns (uint256) {
        uint256 threshold = game.maturityThresholdOf(id, betId);
        uint256 n = game.betCountOf(id);
        for (uint256 i = betId + 1; i < n; i++) {
            (,,,, uint256 cumAtJoin,,,,) = game.bets(id, i);
            if (cumAtJoin >= threshold) return i;
        }
        revert("no saviour: bet has not matured");
    }

    function _salvadorGame(uint16 mode, uint16 bps, uint16 step, uint16 cap) internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [mode, bps, step, cap]);
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

    function test_salvadorFixed_paysExactPercentOfUnreserved() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);   // fixed 2%
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        uint256 saviour = _findSaviour(id, a);
        (,, uint256 roiTarget,,,,,,) = game.bets(id, a);
        // ⚠️ The `- roiTarget` is back, and the round trip is worth understanding. jackpotOf briefly
        // subtracted matured-but-unpaid ROI itself, so this line dropped the subtraction; auto-payout
        // made that unnecessary (the money leaves the pool instead of being accounted around), so the
        // base is once again the pot BEFORE the salvation pays the matured bet out of it.
        uint256 expected = ((game.jackpotOf(id) - roiTarget) * 200) / 10_000;

        uint256 paidOut = _salvage(IERC20(address(tok)), id, a, saviour);
        assertEq(paidOut, expected, "fixed-mode bounty must be exactly bps of the unreserved pool");
        // ⭐ And in mode 1 it must have been PAID, not merely credited — nothing left to claim.
        assertEq(_bountyOf(id, saviour), 0, "a mode-1 bounty is transferred, not left owing");
        _assertSolvent(id);
    }

    /**
     * ⭐ AUDIT FINDING #7 — the salvation window closes with the game, not with the jackpot claim.
     *
     * `isActive` stays true until claimJackpot RUNS; it is not the clock. So salvations used to stay
     * openable after the timer expired, when the pot is frozen at its maximum and no further bets can
     * dilute it — making "wait until play stops" strictly the best time to fire one. Measured on a
     * tidy 60-bet mode-1 game at Solana's own 300 bps ceiling: sixty post-expiry salvations moved
     * 8,391 bps of the pot after the game was already decided, and the winner had no counter-move.
     *
     * ⚠️ THE PAYOUT MUST STILL WORK. This closes the bounty, not the ROI — a matured bet is settled
     * by reserveRoi at any time, and that distinction is the whole reason this is safe to add.
     */
    function test_regression_salvationsCloseWithTheTimerNotTheJackpot() public {
        // At the top of the fixed band, which is 2% since 2026-09-16 (it was Solana's 3% when this was found).
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        vm.warp(game.timerEndOf(id));           // exactly at expiry: betting has stopped
        vm.expectRevert(CrazyGame.TimerExpired.selector);
        game.reserveRoiWithSalvation(id, a, saviour);

        // ...and again inside JACKPOT_DELAY, which is the window the harvest actually used.
        vm.warp(game.timerEndOf(id) + game.JACKPOT_DELAY() - 1);
        vm.expectRevert(CrazyGame.TimerExpired.selector);
        game.reserveRoiWithSalvation(id, a, saviour);

        // ⭐ But alice is still paid. Anyone can settle her, after expiry, with no bounty involved.
        uint256 before = tok.balanceOf(alice);
        (,, uint256 target,,,,,,) = game.bets(id, a);
        game.reserveRoi(id, a);
        assertEq(tok.balanceOf(alice) - before, target, "the ROI path must stay open after expiry");
        _assertSolvent(id);
    }

    /// The view the indexer reads must not disagree with the contract — it returned double for any
    /// settled bet, because payout writes accumulatedBase without rebasing cumulativeAtJoin.
    function test_regression_accumulatedOfDoesNotDoubleCountAfterPayout() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        uint256 accBefore = game.accumulatedOf(id, a);
        (,, uint256 target,,,,,,) = game.bets(id, a);
        assertGe(accBefore, target, "setup: matured");

        game.reserveRoi(id, a);
        assertEq(game.accumulatedOf(id, a), accBefore, "settling must freeze it, not double it");
    }

    /// ⭐ The verification is what replaces the operator. A wrong saviour must be impossible to pass.
    function test_salvadorRejectsWrongSaviour() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        // Too early — its predecessor had already crossed.
        if (saviour > a + 1) {
            vm.expectRevert(CrazyGame.BadParams.selector);
            game.reserveRoiWithSalvation(id, a, saviour - 1);
        }
        // Too late — this one did not do the saving.
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.reserveRoiWithSalvation(id, a, saviour + 1);
        // The bet cannot save itself.
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.reserveRoiWithSalvation(id, a, a);
    }

    function test_salvadorProgressive_escalatesAndCaps() public {
        // start 1%, +0.2% each (the new step ceiling), cap 1.2% — so the THIRD save hits the cap. The old
        // version (+0.5%, cap 3%) never reached its cap in three saves, so "AndCaps" was untested.
        uint256 id = _salvadorGame(2, 100, 20, 120);
        uint256[] memory rates = new uint256[](3);
        for (uint256 k; k < 3; k++) {
            vm.prank(alice);
            uint256 b = game.placeBet(id, 1_000 ether);
            _runUntilMatured(id, b);
            uint256 sav = _findSaviour(id, b);
            (,, uint256 tgt2,,,,,,) = game.bets(id, b);
            uint256 unreservedAfter = game.jackpotOf(id) - tgt2;
            rates[k] = (_salvage(IERC20(address(tok)), id, b, sav) * 10_000) / unreservedAfter;
            _assertSolvent(id);
        }
        assertEq(rates[0], 100, "first salvation should be the starting rate");
        assertEq(rates[1], 120, "second should step up");
        assertEq(rates[2], 120, "third should stop at the cap");
    }

    function test_bountyIsClaimableAndKeepsSolvency() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 sav = _findSaviour(id, a);

        // ⭐ REWRITTEN FOR AUTO-PAY. This used to reserve, then claim, then assert the balance moved
        // on the SECOND transaction. In modes 1/2 there is no second transaction any more: the
        // saviour is paid inside reserveRoiWithSalvation. What still needs proving is that the money
        // actually arrives, that nothing is left owing, and that claimBounty cannot then double-pay.
        (address saviourPlayer,,,,,,,,) = game.bets(id, sav);
        uint256 before = tok.balanceOf(saviourPlayer);
        game.reserveRoiWithSalvation(id, a, sav);
        uint256 gained = tok.balanceOf(saviourPlayer) - before;
        assertGt(gained, 0, "a mode-1 saviour must be paid in the same transaction");
        assertEq(_bountyOf(id, sav), 0, "and nothing may be left owing afterwards");
        _assertSolvent(id);

        vm.prank(saviourPlayer);
        vm.expectRevert(CrazyGame.AlreadyDone.selector);
        game.claimBounty(id, sav);   // already paid: there is nothing to claim
    }

    // ─── SALVADOR MODE 3 — INSANITY ──────────────────────────────────────────────────────────

    function _insanityGame() internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(3), 0, 0, 0]);
    }

    /// Trigger a mode-3 salvation and return (salvationId, saviourBetId, jackpotAtTrigger).
    function _trigger(uint256 id, uint256 betId)
        internal
        returns (uint256 sid, uint256 saviour, uint256 unreserved)
    {
        saviour = _findSaviour(id, betId);
        // ⚠️ Read the fee BEFORE the prank. oracle.fee() is an external call, and any external call
        // between vm.prank and the target CONSUMES the prank — the caller silently becomes the test
        // contract, which is not who we are trying to test.
        uint256 fee = oracle.fee();
        // ⚠️ THE BASE IS NEITHER THE VALUE BEFORE NOR THE VALUE AFTER — it is the value in between,
        // and both naive readings are wrong for different reasons. `_openSalvation` snapshots
        // jackpotOf AFTER the saved bet has been paid out (so the base is lower by its roiTarget) but
        // BEFORE the pending ceiling is claimed (so reading afterwards returns roughly half). Compute
        // it rather than sample it.
        (,, uint256 savedTarget,,,,,,) = game.bets(id, betId);
        unreserved = game.jackpotOf(id) - savedTarget;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        game.reserveRoiWithSalvation{value: fee}(id, betId, saviour);
        sid = game.salvationCount();
    }

    function _bountyOf(uint256 id, uint256 betId) internal view returns (uint256 owed) {
        (,,,,, owed,,,) = game.bets(id, betId);
    }

    /**
     * Run a salvation and return what it actually awarded the saviour, WHICHEVER ROUTE IT TOOK.
     *
     * ⭐ A mode 1/2 bounty is now TRANSFERRED inside reserveRoiWithSalvation and leaves `bountyOwed`
     * at zero; mode 3 still credits it for a later claimBounty, because it settles inside the VRF
     * callback where a reverting token would burn the randomness. Summing the balance delta and the
     * credited delta covers both, so a test asserting the ECONOMICS does not have to know which
     * plumbing ran. Six tests failed on exactly that distinction when auto-pay landed.
     *
     * ⚠️ The balance delta is only clean because _runUntilMatured places the later bets from bob and
     * carol while the matured bet is alice's — so the saviour is never also the player receiving the
     * ROI in the same transaction. Do not reuse this where one address is both.
     */
    function _salvage(IERC20 t, uint256 id, uint256 betId, uint256 saviourBetId) internal returns (uint256) {
        (address who,,,,, uint256 owedBefore,,,) = game.bets(id, saviourBetId);
        uint256 balBefore = t.balanceOf(who);
        game.reserveRoiWithSalvation(id, betId, saviourBetId);
        (,,,,, uint256 owedAfter,,,) = game.bets(id, saviourBetId);
        return (t.balanceOf(who) - balBefore) + (owedAfter - owedBefore);
    }

    /// The v14 table, asserted at every boundary. These five rates and their cut-points are the
    /// economics of the whole mode; an off-by-one here silently changes the game's EV.
    function test_insanity_rateTableMatchesSolanaExactly() public {
        ExposedGame x = new ExposedGame(treasury, 300, address(oracle));
        assertEq(x.randomBps(0), 20);
        assertEq(x.randomBps(49_999), 20);
        assertEq(x.randomBps(50_000), 50);
        assertEq(x.randomBps(79_999), 50);
        assertEq(x.randomBps(80_000), 150);
        assertEq(x.randomBps(94_999), 150);
        assertEq(x.randomBps(95_000), 1_000);
        assertEq(x.randomBps(99_899), 1_000);
        assertEq(x.randomBps(99_900), 5_000);
        assertEq(x.randomBps(99_999), 5_000);
        // And it wraps on the modulus, so a full-width random number is still in-table.
        assertEq(x.randomBps(100_000), 20);
        assertEq(x.randomBps(type(uint256).max % 100_000 == 0 ? 0 : 100_000), 20);
    }

    /// The fallback must be worth about what the roll is worth, or someone has a reason to stall.
    /// EV = .5*20 + .3*50 + .15*150 + .049*1000 + .001*5000 = 101.5bps vs a 100bps fallback.
    function test_insanity_fallbackApproximatesTableEV() public view {
        uint256 evMilliBps = 500 * 20 + 300 * 50 + 150 * 150 + 49 * 1_000 + 1 * 5_000;
        assertEq(evMilliBps, 101_500, "table EV drifted from 101.5 bps");
        uint256 fallbackMilli = uint256(game.SALVADOR_FALLBACK_BPS()) * 1_000;
        assertApproxEqRel(fallbackMilli, evMilliBps, 0.02e18, "fallback no longer tracks EV");
    }

    function test_insanity_rejectsHostSuppliedRate() public {
        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(3), 200, 0, 0]);
    }

    /// Refused at creation, while switching mode is still free — not at the first salvation, when
    /// there is already money in the pot.
    function test_insanity_refusedWhenNoOracleConfigured() public {
        CrazyGame noOracle = new CrazyGame(treasury, 300, address(0), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        vm.startPrank(host);
        tok.approve(address(noOracle), type(uint256).max);
        vm.expectRevert(CrazyGame.BadParams.selector);
        noOracle.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(3), 0, 0, 0]);
        vm.stopPrank();
    }

    /// ⭐ The liveness rule that matters most: the matured bet is reserved in the trigger tx. Only
    /// the bounty waits on the oracle. A player's own ROI never depends on a third party.
    function test_insanity_reservesTheBetBeforeAnyRandomness() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        (,, uint256 target,,,, bool reservedBefore,,) = game.bets(id, a);
        assertFalse(reservedBefore);
        uint256 jackpotBefore = game.jackpotOf(id);

        _trigger(id, a);

        (,,,,,, bool reservedAfter,,) = game.bets(id, a);
        assertTrue(reservedAfter, "the bet must be reserved without waiting for the oracle");

        // ⭐ TWO SEPARATE EFFECTS, AND ONLY ONE OF THEM IS THE PAYOUT.
        // The trigger pays alice her roiTarget out of the pool, so the pot drops by that. THEN the
        // pending salvation holds its own ceiling out of what remains — until a rate arrives,
        // INSANITY_MAX_BPS of the base is spoken for, which is what stops two salvations opened
        // together from spending the same money twice.
        uint256 baseAtOpen = jackpotBefore - target;
        uint256 ceiling = (baseAtOpen * game.INSANITY_MAX_BPS()) / 10_000;
        assertEq(game.jackpotOf(id), baseAtOpen - ceiling, "the pending ceiling must be held out");

        // ...and handed back when the salvation resolves. Roll the smallest band so almost all of
        // the ceiling is released rather than spent.
        oracle.fulfill(1, 0);   // 20 bps
        uint256 paid = _bountyOf(id, _findSaviour(id, a));
        assertEq(paid, (baseAtOpen * 20) / 10_000, "and the rate applies to the base at trigger");
        assertEq(game.jackpotOf(id), baseAtOpen - paid, "the unspent ceiling must come back");
        _assertSolvent(id);
    }

    function test_insanity_callbackPaysTheRolledRate() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (uint256 sid, uint256 saviour, uint256 unreserved) = _trigger(id, a);
        assertEq(sid, 1);

        // 96_000 lands in the 4.9% band -> 1000 bps.
        oracle.fulfill(1, 96_000);

        assertEq(_bountyOf(id, saviour), (unreserved * 1_000) / 10_000, "bounty must be the rolled rate");
        _assertSolvent(id);
    }

    /// The callback is the one place a forged call could set a bounty rate of the caller's choosing,
    /// so the sender check is the single rejection here that MUST revert rather than return quietly.
    function test_insanity_forgedCallbackIsRejected() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (, uint256 saviour, ) = _trigger(id, a);

        uint256[] memory words = new uint256[](1);
        words[0] = 99_999;              // the 50% jackpot band, if it were ever honoured
        vm.prank(alice);
        vm.expectRevert();
        game.rawFulfillRandomWords(1, words);

        assertEq(_bountyOf(id, saviour), 0, "a forged callback must not accrue anything");
        assertEq(game.salvationsPendingOf(id), 1, "and must not resolve the salvation");
    }

    /// A malformed fulfilment must NOT revert: reverting burns the randomness and strands the
    /// salvation on the slow path. It should fall through to the fallback instead.
    function test_insanity_emptyRandomWordsFallsThroughToFallback() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (uint256 sid, uint256 saviour, uint256 unreserved) = _trigger(id, a);

        oracle.fulfillEmpty(1);         // must be survived, not thrown on
        assertEq(_bountyOf(id, saviour), 0, "nothing rolled, so nothing owed yet");
        assertEq(game.salvationsPendingOf(id), 1, "salvation still open");

        vm.warp(block.timestamp + 361);
        game.settleStalledSalvation(sid);
        assertEq(_bountyOf(id, saviour), (unreserved * 100) / 10_000, "fallback still clears it");
        _assertSolvent(id);
    }

    /// nativePayment must be encoded the way VRFV2PlusClient encodes it. If this tag or flag were
    /// wrong the wrapper would try to bill in LINK, which we hold none of — and it would only show
    /// up on mainnet. The mock records what we actually sent.
    function test_insanity_requestAsksForNativePaymentAndOurGasLimit() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        _trigger(id, a);

        assertEq(oracle.callbackGasOf(1), game.VRF_CALLBACK_GAS(), "callback gas must be ours");
        assertEq(
            oracle.extraArgsOf(1),
            abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true),
            "extraArgs must say nativePayment = true"
        );
    }
    function test_insanity_stallFallbackPaysFixedRate() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (uint256 sid, uint256 saviour, uint256 unreserved) = _trigger(id, a);

        // Too early: the armed window is what stops anyone forcing the cheap rate.
        vm.expectRevert(CrazyGame.NotYet.selector);
        game.settleStalledSalvation(sid);

        vm.warp(block.timestamp + game.SALVATION_FALLBACK_TIMEOUT());
        game.settleStalledSalvation(sid);   // permissionless — any player can unstick it

        assertEq(_bountyOf(id, saviour), (unreserved * 100) / 10_000, "fallback must pay 1%");
        _assertSolvent(id);
    }

    /// The race that must never double-pay: the fallback settles, then the oracle answers late.
    function test_insanity_lateCallbackAfterFallbackIsDiscarded() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (uint256 sid, uint256 saviour,) = _trigger(id, a);

        vm.warp(block.timestamp + game.SALVATION_FALLBACK_TIMEOUT());
        game.settleStalledSalvation(sid);
        uint256 afterFallback = _bountyOf(id, saviour);

        // A 50%-band roll arriving late must change nothing at all.
        oracle.fulfill(1, 99_999);
        assertEq(_bountyOf(id, saviour), afterFallback, "late callback must not pay a second time");
        _assertSolvent(id);
    }

    /// ⭐ The ORAO scenario, made survivable: the oracle cannot even be asked. The salvation must
    /// still be RECORDED and must still clear, or a dead oracle would freeze the game forever.
    function test_insanity_oracleCompletelyDownStillClears() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        oracle.setBroken(false, true);   // fee readable, requests reverting

        uint256 saviour = _findSaviour(id, a);
        uint256 fee = oracle.fee();          // before the prank — see _trigger
        vm.deal(alice, 1 ether);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        game.reserveRoiWithSalvation{value: fee}(id, a, saviour);
        uint256 sid = game.salvationCount();

        assertEq(sid, 1, "the salvation must exist even though the request failed");
        assertEq(alice.balance, balBefore, "a failed request must cost the caller nothing");

        // No timer was armed, so this window is anchored to openedAt instead — and it is the SAME
        // 360s, not a longer "emergency" one. Not open yet:
        uint256 openedAt = block.timestamp;
        vm.warp(openedAt + game.SALVATION_FALLBACK_TIMEOUT() - 1);
        vm.expectRevert(CrazyGame.NotYet.selector);
        game.settleStalledSalvation(sid);

        // ...and open one second later.
        vm.warp(openedAt + game.SALVATION_FALLBACK_TIMEOUT());
        game.settleStalledSalvation(sid);
        assertGt(_bountyOf(id, saviour), 0, "the never-armed path must still pay the saviour");
        _assertSolvent(id);
    }

    /**
     * ⭐ AND IT MUST CLEAR BEFORE THE POT DOES — the fix for audit finding #6.
     *
     * The window above used to be a 3600s SALVATION_EMERGENCY_TIMEOUT, ten times the armed one,
     * while claimJackpot unblocks at salvationLastActivity + SALVATION_JACKPOT_EXTRA (420s). So the
     * escape hatch opened 3,180 seconds after the pool it was guarding had already been swept, and
     * the loss was UNCONDITIONAL for any game with under ~55 minutes left when the request failed —
     * timerDuration is legal down to 300s. Every actor here behaves perfectly and settles at the
     * earliest instant the contract permits; before the fix the saviour still got zero.
     *
     * The test the suite already had passed only because nothing ever claimed the jackpot during the
     * 3,961 seconds it warped through.
     */
    function test_regression_failedRequestBountySurvivesTheJackpotSweep() public {
        // A short-timer game, which is the exposed shape. 600s is well inside the legal 300..86400.
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 600, 0, [uint16(3),0,0,0]);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        oracle.setBroken(false, true);            // fee readable, the request itself reverts
        uint256 saviour = _findSaviour(id, a);
        uint256 fee = oracle.fee();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        game.reserveRoiWithSalvation{value: fee}(id, a, saviour);
        uint256 sid = game.salvationCount();
        uint256 openedAt = block.timestamp;

        // ⭐ THE ASSERTION THAT IS THE WHOLE FINDING: the earliest instant anyone may settle must
        // come before the earliest instant the pot may be swept. It was 360 vs 900 after the fix,
        // 3600 vs 900 before it.
        uint256 earliestSettle = openedAt + game.SALVATION_FALLBACK_TIMEOUT();
        uint256 earliestClaim  = game.timerEndOf(id) + game.JACKPOT_DELAY();
        assertLt(earliestSettle, earliestClaim, "the hatch must open before the pot does");

        vm.warp(earliestSettle);
        game.settleStalledSalvation(sid);
        uint256 owed = _bountyOf(id, saviour);
        assertGt(owed, 0, "a dead VRF must not cost the saviour their bounty");

        // The pot then pays out normally, and the bounty is money the winner never sees.
        vm.warp(earliestClaim);
        vm.prank(game.lastBettorOf(id));
        game.claimJackpot(id);
        _assertSolvent(id);

        // And the saviour can still take it out after the game is over.
        (address who,,,,,,,,) = game.bets(id, saviour);
        uint256 before = tok.balanceOf(who);
        vm.prank(who);
        game.claimBounty(id, saviour);
        assertEq(tok.balanceOf(who) - before, owed, "the bounty must actually be payable");
    }

    /// A pending salvation has an unknown claim on the pool, so the pot cannot be swept out from
    /// under it.
    function test_insanity_jackpotBlockedWhileSalvationPending() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        // ⚠️ Timing matters, and getting it wrong makes this test vacuous: the block only lasts
        // SALVATION_JACKPOT_EXTRA (7 min) past the last salvation activity, while the timer runs
        // for an hour. Trigger it late enough that the window is still open when the pot opens.
        //
        // ⚠️ AND IT MUST NOW BE BEFORE timerEnd — finding #7 closed the salvation window at the
        // timer rather than at the jackpot claim, so the original "warp past expiry, then trigger"
        // ordering reverts TimerExpired. Fire at expiry minus 5s: the pot opens at +300, the
        // salvation block runs to +415, so there is a real 115-second overlap to assert on.
        vm.warp(game.timerEndOf(id) - 5);
        _trigger(id, a);
        vm.warp(game.timerEndOf(id) + game.JACKPOT_DELAY() + 1);

        address winner = game.lastBettorOf(id);
        assertEq(game.salvationsPendingOf(id), 1);
        vm.prank(winner);
        vm.expectRevert(CrazyGame.NotYet.selector);
        game.claimJackpot(id);

        oracle.fulfill(1, 10);   // 0.2% band
        assertEq(game.salvationsPendingOf(id), 0);

        vm.prank(winner);
        game.claimJackpot(id);                     // now clear
        _assertSolvent(id);
    }

    /**
     * ⭐ THE ACCEPTED TRADE-OFF, made explicit so nobody "fixes" it later.
     *
     * The jackpot block is a BOUNDED delay, not a lock. If a salvation never clears, the pot still
     * pays out once SALVATION_JACKPOT_EXTRA passes, and that salvation's bounty is forgone. This is
     * the same escape hatch Solana has: a stuck oracle must never be able to freeze a game's money
     * permanently, and stranding one bounty is strictly better than stranding the whole pot.
     * A saviour is protected by settleStalledSalvation, which anyone can call long before this.
     */
    function test_insanity_jackpotIsNotBlockedForever() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (, uint256 saviour,) = _trigger(id, a);

        // The oracle never answers and nobody ever calls the stall settler.
        vm.warp(game.timerEndOf(id) + game.JACKPOT_DELAY() + game.SALVATION_JACKPOT_EXTRA() + 1);

        address winner = game.lastBettorOf(id);
        assertEq(game.salvationsPendingOf(id), 1, "still pending, deliberately");
        vm.prank(winner);
        game.claimJackpot(id);                     // the pot is NOT held hostage

        assertEq(_bountyOf(id, saviour), 0, "the stuck bounty is forgone, by design");
        _assertSolvent(id);
    }

    /// And a late settle after the game is over must pay nothing rather than reach into money that
    /// is now owed to other players — the theft path reserveRoi already guards against.
    function test_insanity_settleAfterGameOverPaysNothing() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (uint256 sid, uint256 saviour,) = _trigger(id, a);

        vm.warp(game.timerEndOf(id) + game.JACKPOT_DELAY() + game.SALVATION_JACKPOT_EXTRA() + 1);
        vm.prank(game.lastBettorOf(id));
        game.claimJackpot(id);

        game.settleStalledSalvation(sid);          // allowed, but must be a no-op for money
        assertEq(_bountyOf(id, saviour), 0);
        _assertSolvent(id);
    }

    function test_insanity_refundsExcessAndRejectsUnderpayment() public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        uint256 fee = oracle.fee();
        vm.deal(alice, 1 ether);

        // Underpaying is refused rather than silently proceeding without randomness.
        vm.prank(alice);
        vm.expectRevert(CrazyGame.InsufficientFee.selector);
        game.reserveRoiWithSalvation{value: fee - 1}(id, a, saviour);

        // Entropy keeps overpayment, so we must hand it back ourselves.
        uint256 before = alice.balance;
        vm.prank(alice);
        game.reserveRoiWithSalvation{value: fee * 10}(id, a, saviour);
        assertEq(before - alice.balance, fee, "caller must be charged the exact fee, no more");
        assertEq(oracle.feesCollected(), fee, "oracle must not receive the excess either");
    }

    /// Solvency under the mode that can pay 50% of the pool in one roll — the invariant everything
    /// else rests on, checked against the most aggressive branch of the table.
    function testFuzz_insanityStaysSolvent(uint16 roll) public {
        uint256 id = _insanityGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        (, uint256 saviour,) = _trigger(id, a);

        // Bias hard toward the rare high bands so the 10% and 50% rolls are actually exercised.
        oracle.fulfill(1, 95_000 + (uint256(roll) % 5_000));
        _assertSolvent(id);

        vm.prank(bets_player(id, saviour));
        game.claimBounty(id, saviour);
        _assertSolvent(id);
    }

    function bets_player(uint256 id, uint256 betId) internal view returns (address p) {
        (p,,,,,,,,) = game.bets(id, betId);
    }
    // ─── REGRESSIONS FROM THE 2026-08-13 ADVERSARIAL REVIEW ──────────────────────────────────
    // Each of these FAILS against the pre-fix contract. That is the point: the existing suite
    // passed with every one of these bugs present, so a fix without a test that would have caught
    // it is just a claim.

    /// FINDING 2 — the salvation race. reserveRoiWithSalvation used to call reserveRoi
    /// unconditionally, so ANY earlier reserve killed the bounty permanently. reserveRoi is
    /// permissionless, so our own indexer doing routine bookkeeping would have destroyed every
    /// bounty it touched. This is that exact sequence.
    function test_regression_bountyStillPayableAfterSomeoneElseReservedFirst() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        // An indexer, a bot, anyone at all — reserves the matured bet as housekeeping.
        game.reserveRoi(id, a);
        (,,,,,, bool isReserved,,) = game.bets(id, a);
        assertTrue(isReserved, "precondition: the bet is already reserved");

        uint256 unreserved = game.jackpotOf(id);
        // pre-fix this reverted AlreadyDone; the bounty is now also PAID here rather than credited,
        // so measure it the way that works on both routes.
        uint256 paidOut = _salvage(IERC20(address(tok)), id, a, saviour);

        assertEq(paidOut, (unreserved * 200) / 10_000, "saviour must still be paid");
        assertEq(_bountyOf(id, saviour), 0, "and in mode 1 it must have been transferred, not owed");
        _assertSolvent(id);
    }

    /// And the bounty is payable exactly once, whichever route reserved the bet.
    function test_regression_salvationCannotBePaidTwiceForTheSameBet() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        game.reserveRoiWithSalvation(id, a, saviour);
        uint256 owed = _bountyOf(id, saviour);

        vm.expectRevert();
        game.reserveRoiWithSalvation(id, a, saviour);
        assertEq(_bountyOf(id, saviour), owed, "a second attempt must not accrue more");
    }

    /// A withdrawn bet has, by definition, matured — so the saviour earned their bounty and
    /// the owner cashing out first must not take it away from them.
    function test_regression_bountyStillPayableAfterTheMaturedBetWithdrew() public {
        uint256 id = _salvadorGame(1, 200, 0, 0);
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);
        uint256 saviour = _findSaviour(id, a);

        vm.prank(alice);
        game.withdraw(id, a);           // the cheapest path, and the one alice actually wants

        uint256 unreserved = game.jackpotOf(id);
        uint256 paidOut = _salvage(IERC20(address(tok)), id, a, saviour);
        assertEq(paidOut, (unreserved * 200) / 10_000, "saviour keeps their bounty");
        assertEq(_bountyOf(id, saviour), 0, "and in mode 1 it is transferred, not left owing");
        _assertSolvent(id);
    }

    /// FINDING 3 — timeIncrement was unbounded and is added to timerEnd on every bet in cumulative
    /// mode. Years locks the jackpot forever; near the ceiling bricks the game on the first bet.
    function test_regression_timeIncrementIsBounded() public {
        vm.startPrank(host);

        vm.expectRevert();              // absurd: the timer would never expire
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 3650 days, [uint16(0),0,0,0]);

        vm.expectRevert();              // overflow on the first bet, deposit trapped
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, type(uint256).max, [uint16(0),0,0,0]);

        vm.expectRevert();              // cumulative mode with no increment is not cumulative
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 0, [uint16(0),0,0,0]);

        vm.expectRevert();              // reset mode ignores it, so refuse rather than mislead
        game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 60, [uint16(0),0,0,0]);

        // The sane case still works: one bet extends the clock by at most the chosen duration.
        uint256 ok = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 1, 3600, 480, [uint16(0),0,0,0]);
        vm.stopPrank();
        assertGt(ok, 0, "a reasonable increment must still be accepted");
    }

    /// FINDING 4, RETRACTED — I claimed outbound fee-on-transfer drifted the accounting. It does
    /// not: a fee-on-transfer token takes its cut OUT of the transferred amount, so the contract
    /// loses exactly what it debits and the recipient simply receives less. Outbound was merely
    /// untested, so this is the missing coverage rather than a fix.
    function test_feeOnTransferStaysSolventOnTheWayOutToo() public {
        TaxToken tt = new TaxToken(500);   // 5% on every transfer, both directions
        address[3] memory who = [host, alice, bob];
        for (uint256 i; i < 3; i++) {
            tt.mintTo(who[i], 10_000_000 ether);
            vm.prank(who[i]);
            tt.approve(address(game), type(uint256).max);
        }
        vm.prank(host);
        // 20% ROI, not 100%: with a 5% tax on every transfer a 100% target takes more traffic than
        // this test wants to simulate, and the point here is the OUTBOUND path, not maturity speed.
        uint256 id = game.createGame(address(tt), DEPOSIT, MIN_BET, 2_000, 100, 0, 3600, 0, [uint16(1),200,0,0]);

        vm.prank(alice);
        uint256 a = game.placeBet(id, 100_000 ether);
        for (uint256 i; i < 40; i++) {
            vm.prank(i % 2 == 0 ? bob : host);
            game.placeBet(id, 50_000 ether);
            (,, uint256 tgt,,,,,,) = game.bets(id, a);
            if (game.accumulatedOf(id, a) >= tgt) break;
        }

        (,, uint256 aTarget,,,,,,) = game.bets(id, a);
        assertGe(game.accumulatedOf(id, a), aTarget, "precondition: the bet matured");

        uint256 saviour = _findSaviour(id, a);
        // Outbound #1 happens INSIDE this call now — the salvation settles alice's ROI and the tax
        // is taken on the way out, which is the path this test exists to cover.
        game.reserveRoiWithSalvation(id, a, saviour);
        (uint256 p1,) = game.balancesOf(id);
        assertGe(tt.balanceOf(address(game)), p1, "still holds at least what it credits");

        // ⭐ OUTBOUND #2 ALSO HAPPENED INSIDE THAT CALL. A mode-1 bounty is paid to the saviour in
        // the same transaction now, so this taxed token takes its cut on TWO outbound transfers in
        // one call — the matured player's ROI and the saviour's bounty — which is a strictly harder
        // case for solvency than the old one-at-a-time version, and the point of this test.
        (address sp,,,,,,,,) = game.bets(id, saviour);
        assertEq(_bountyOf(id, saviour), 0, "the bounty was paid, not credited");
        vm.prank(sp);
        vm.expectRevert(CrazyGame.AlreadyDone.selector);
        game.claimBounty(id, saviour);                          // nothing left to collect
        (uint256 p2,) = game.balancesOf(id);
        assertGe(tt.balanceOf(address(game)), p2, "still holds at least what it credits");

        address winner = game.lastBettorOf(id);
        vm.warp(block.timestamp + 3600 + 301);
        vm.prank(winner);
        game.claimJackpot(id);                                  // outbound #3
        (uint256 p3, uint256 r3) = game.balancesOf(id);
        assertGe(tt.balanceOf(address(game)), p3, "still holds at least what it credits");
        assertGe(p3, r3, "and never promises more than it holds");
    }

    /**
     * ⭐ FINDING 1 — CLOSED 2026-08-16. This was a CHARACTERIZATION test asserting the loss.
     *
     * It used to end with `vm.expectRevert(); game.withdraw(id, a);` and a comment reading "her ROI
     * left with the winner; nothing on-chain undoes that". A bet that reached its ROI target but
     * that nobody reserved was not in reservedBalance, so claimJackpot paid it to the last bettor,
     * permanently. The live Solana program does the same and closes it off-chain, with the indexer
     * calling reserve_roi for every matured bet (checkAndReserveRois in listener.js), and this port
     * inherited that arrangement — meaning a player's money depended on our process being up. That
     * is the class of failure that cost 5 SOL on Solana.
     *
     * ⚠️ AND THE FIX IS NOT THE ONE THAT WAS REVERTED. A permissionless batched sweepMatured() was
     * built here once and taken back out because it made claiming two transactions. The version that
     * landed writes nothing at all: jackpotOf simply stops COUNTING already-earned ROI, so the money
     * is never swept in the first place. One O(betCount) read, about a cent, one transaction.
     *
     * The right way to read this test now: the winner's pot is smaller by exactly what was never
     * theirs, and it stays claimable by its owner with the game over and nothing running.
     */
    function test_regression_anyoneCanSettleAMaturedBetAndTheMoneyReachesItsOwner() public {
        uint256 id = _newGame();
        vm.prank(alice);
        uint256 a = game.placeBet(id, 1_000 ether);
        _runUntilMatured(id, a);

        (,, uint256 target,,,,,,) = game.bets(id, a);
        uint256 before = tok.balanceOf(alice);

        // carol has no relationship to this bet. She settles it anyway, and alice gets the tokens.
        vm.prank(carol);
        game.reserveRoi(id, a);

        assertEq(tok.balanceOf(alice) - before, target, "paid to the OWNER, not the caller");
        _assertSolvent(id);

        vm.warp(block.timestamp + 3600 + 301);
        vm.prank(game.lastBettorOf(id));
        game.claimJackpot(id);
        _assertSolvent(id);
    }

}
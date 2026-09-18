// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// STATEFUL INVARIANT HARNESS
//
// A stateful invariant harness with betId as a fuzzed input and three invariants. It exists because
// of a specific, measured failure of the rest of the suite:
//
//   • activeBetCount is the divisor of the entire economy and NOTHING watched it. It had no getter
//     and no assertion anywhere. That is the single reason the phantom-betId bug — permissionless,
//     free, and able to over-credit every bet in a game 2x — survived 51 passing tests.
//   • testFuzz_solventUnderArbitraryBets fuzzes AMOUNTS. Nothing ever fuzzed IDS.
//
// The three invariants, in the order they matter:
//   1. reservedBalance <= poolBalance          — the contract never owes more than it holds
//   2. activeBetCount == #{bets : !reserved}   — the divisor is a countable fact, not a running total
//   3. token.balanceOf(game) == Σ poolBalance  — no game can be paid out of another game's money
//
// Invariant 2 is the one that would have caught the phantom-betId bug on the first sequence, and it
// is the reason to keep this harness even after that bug is fixed: it converts "this counter drifted"
// from a thing you discover when withdrawals start reverting into a red test.
//
// ⚠️ TWO GAMES ON PURPOSE. Invariant 3 is vacuous with one — poolBalance and the ERC20 balance move
// together by construction. Only a second game sharing the same token makes "pays out of someone
// else's money" expressible at all.
//
// ⚠️ MODES 1 AND 2 ONLY, AND BOTH AT THEIR MAXIMUM LEGAL RATE. Mode 3 (Insanity) is out of scope for
// this harness.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract InvToken is ERC20 {
    constructor() ERC20("Inv", "INV") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/**
 * The only contract the fuzzer is allowed to call. Every action wraps its call in try/catch, so an
 * illegal input advances the sequence instead of ending it — which is the whole point, because the
 * illegal inputs are what we are hunting.
 */
contract Handler is Test {
    CrazyGame public immutable game;
    InvToken public immutable tok;

    uint256 public constant DEPOSIT = 100_000 ether;
    uint256 public constant MIN_BET = 100 ether;

    uint256[2] public ids;
    address[4] public actors;

    // ── Ghost counters ────────────────────────────────────────────────────────────────────────
    // Not decoration. A handler whose every call reverts satisfies every invariant perfectly, and
    // that is the single most common way an invariant suite lies to you. afterInvariant() asserts
    // on these.
    uint256 public okBet;
    uint256 public okReserve;
    uint256 public okWithdraw;
    uint256 public okSalvage;
    uint256 public okBounty;
    uint256 public outOfRangeTried;

    constructor(CrazyGame g, InvToken t) {
        game = g;
        tok = t;
        for (uint256 i; i < 4; i++) {
            address a = address(uint160(uint256(0xACC0) + i));
            actors[i] = a;
            tok.mintTo(a, 1e12 ether);
            vm.prank(a);
            t.approve(address(g), type(uint256).max);
        }
        // Both at the maximum rate this contract permits, because finding #2's arithmetic scales directly
        // with bps — if there is anything left in that class below mode 3, this is where it shows.
        // (Solana's 3% / +0.5% / 5% until 2026-09-16; the reduced bands' ceilings now.)
        vm.prank(actors[0]);
        ids[0] = g.createGame(address(t), DEPOSIT, MIN_BET, 10_000, 100, 0, 86_400, 0, [uint16(1), 200, 0, 0]);
        vm.prank(actors[0]);
        ids[1] = g.createGame(address(t), DEPOSIT, MIN_BET, 10_000, 100, 0, 86_400, 0, [uint16(2), 100, 20, 250]);
    }

    function gameIds() external view returns (uint256, uint256) { return (ids[0], ids[1]); }

    function _id(uint256 s) internal view returns (uint256) { return ids[s % 2]; }
    function _actor(uint256 s) internal view returns (address) { return actors[s % 4]; }

    /// Near-boundary ids: mostly valid, sometimes exactly past the end. `betCount` itself is the
    /// off-by-one that the phantom bug lived on, so it must be in range of the generator.
    function _nearId(uint256 id, uint256 seed) internal view returns (uint256) {
        return seed % (game.betCountOf(id) + 3);
    }

    // ── Actions ───────────────────────────────────────────────────────────────────────────────

    function placeBet(uint256 gs, uint256 as_, uint256 amount) external {
        uint256 id = _id(gs);
        amount = bound(amount, MIN_BET, 20_000 ether);
        vm.prank(_actor(as_));
        try game.placeBet(id, amount) { okBet++; } catch {}
    }

    /// ⭐ A SEPARATE MINIMUM-BET ACTION, AND IT IS LOAD-BEARING. roiTarget scales with your own
    /// size while accumulation is an equal ABSOLUTE share, so small bets mature in a couple of
    /// blocks and large ones may never mature at all. With only a uniform 100..20,000 ether
    /// generator the first version of this harness placed 553 bets and reserved NOTHING across 4,096
    /// calls — every invariant passed and proved exactly nothing. afterInvariant() caught that.
    ///
    /// It is also the real-world shape: an agent playing a game bets the minimum, every time.
    function placeMinBet(uint256 gs, uint256 as_) external {
        vm.prank(_actor(as_));
        try game.placeBet(_id(gs), MIN_BET) { okBet++; } catch {}
    }

    /// ⭐ THE POINT OF THE HARNESS, half one: ids clustered around the valid range.
    function reserveRoiNear(uint256 gs, uint256 seed) external {
        uint256 id = _id(gs);
        uint256 betId = _nearId(id, seed);
        if (betId >= game.betCountOf(id)) outOfRangeTried++;
        try game.reserveRoi(id, betId) { okReserve++; } catch {}
    }

    /// ⭐ THE POINT OF THE HARNESS, half two: a raw uint256. This is the exact call that used to
    /// decrement activeBetCount for free — reserveRoi(id, 2**200) — and it must now always revert.
    function reserveRoiWild(uint256 gs, uint256 betId) external {
        uint256 id = _id(gs);
        if (betId >= game.betCountOf(id)) outOfRangeTried++;
        try game.reserveRoi(id, betId) { okReserve++; } catch {}
    }

    function withdraw(uint256 gs, uint256 seed) external {
        uint256 id = _id(gs);
        uint256 betId = _nearId(id, seed);
        if (betId >= game.betCountOf(id)) return;
        (address who,,,,,,,,) = game.bets(id, betId);
        if (who == address(0)) return;
        vm.prank(who);
        try game.withdraw(id, betId) { okWithdraw++; } catch {}
    }

    /// Modes 1 and 2 need no oracle and no msg.value, so a salvation here is a plain call.
    function salvage(uint256 gs, uint256 seed, uint256 saviourSeed) external {
        uint256 id = _id(gs);
        uint256 betId = _nearId(id, seed);
        uint256 saviour = betId + 1 + (saviourSeed % 6);
        if (saviour >= game.betCountOf(id)) outOfRangeTried++;
        try game.reserveRoiWithSalvation(id, betId, saviour) { okSalvage++; } catch {}
    }

    function claimBounty(uint256 gs, uint256 seed) external {
        uint256 id = _id(gs);
        uint256 betId = _nearId(id, seed);
        if (betId >= game.betCountOf(id)) return;
        (address who,,,,,,,,) = game.bets(id, betId);
        if (who == address(0)) return;
        vm.prank(who);
        try game.claimBounty(id, betId) { okBounty++; } catch {}
    }

    /// Bounded well under the 86,400s timer so the games stay LIVE. Every open money bug in this
    /// contract lives in the live state; a sequence that lets the timer lapse spends its remaining
    /// depth on calls that all revert with GameOver.
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 600));
    }
}

contract Invariants is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    InvToken tok;
    Handler handler;

    function setUp() public {
        oracle = new MockVRFWrapper();
        tok = new InvToken();
        game = new CrazyGame(makeAddr("treasury"), 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        handler = new Handler(game, tok);
        targetContract(address(handler));
    }

    /// The contract must never owe more than it holds.
    function invariant_reservedNeverExceedsPool() public view {
        for (uint256 i; i < 2; i++) {
            (uint256 pool, uint256 reserved) = game.balancesOf(handler.ids(i));
            assertLe(reserved, pool, "INSOLVENT: reserved exceeds pool");
        }
    }

    /// ⭐ The one that catches the whole phantom-betId class, and the one nothing watched before.
    function invariant_activeBetCountMatchesUnreservedBets() public view {
        for (uint256 i; i < 2; i++) {
            uint256 id = handler.ids(i);
            uint256 n = game.betCountOf(id);
            uint256 unreserved;
            for (uint256 b; b < n; b++) {
                (,,,,,, bool reserved,,) = game.bets(id, b);
                if (!reserved) unreserved++;
            }
            assertEq(game.activeBetCountOf(id), unreserved, "activeBetCount drifted from reality");
        }
    }

    /// No game may be paid out of another game's money. Equality, not >=: fees leave the contract
    /// the moment they are taken, so any surplus would mean value is stuck here unaccounted for and
    /// any deficit means someone has been overpaid.
    function invariant_tokenBalanceEqualsSumOfPools() public view {
        uint256 sum;
        for (uint256 i; i < 2; i++) {
            (uint256 pool,) = game.balancesOf(handler.ids(i));
            sum += pool;
        }
        assertEq(tok.balanceOf(address(game)), sum, "contract balance has drifted from the pools");
    }

    /**
     * ⭐ THE ANTI-VACUITY PROOF, and it is a SCRIPTED test rather than an assertion inside
     * afterInvariant() — for a reason worth keeping.
     *
     * Foundry resets to the post-setUp snapshot between runs, so a ghost counter measures ONE
     * sequence, not the campaign. Asserting "something was reserved" in afterInvariant() therefore
     * demands it of every run including the unlucky short ones, and it duly failed — while the same
     * handler driven deterministically reserves 19 times out of 40 bets. The counter was right; the
     * place I was asserting on it was wrong.
     *
     * So: this test proves the handler CAN reach every state it claims to reach, deterministically.
     * afterInvariant() then guards only the two things every run must do.
     *
     * ⚠️ If a contract change ever makes one of these unreachable, the invariants above go quietly
     * vacuous — still green, still proving nothing. This is the test that tells you.
     */
    function test_theHandlerReachesEveryStateItClaimsTo() public {
        for (uint256 i; i < 25; i++) {
            handler.placeMinBet(0, i);
            handler.placeBet(0, i, 3_000 ether);
        }
        // ⚠️ DISJOINT RANGES, and that is now forced. `withdraw` is an alias for `reserveRoi` since
        // reserving pays the player itself, so whichever runs first settles the bet and the other
        // can only answer AlreadyDone. Running them over the same indices zeroes one counter or the
        // other — I hit both halves of that before splitting the ranges.
        for (uint256 i; i < 15; i++) handler.withdraw(0, i);
        for (uint256 i = 15; i < 45; i++) handler.reserveRoiNear(0, i);
        // A grid rather than a lucky guess: the saviour of bet b is some small offset above b.
        for (uint256 b; b < 20; b++) {
            for (uint256 s; s < 6; s++) handler.salvage(0, b, s);
        }
        // ⚠️ In modes 1 and 2 a bounty is now PAID inside reserveRoiWithSalvation, so claimBounty
        // has nothing to collect and this loop can no longer be the proof that bounties work. It
        // stays because the harness runs both modes and the call must still be exercised (it should
        // answer AlreadyDone rather than do something surprising); the PROOF moved to okSalvage
        // plus the solvency invariants, which now cover the transfer as well as the accounting.
        for (uint256 i; i < 30; i++) handler.claimBounty(0, i);
        handler.reserveRoiWild(0, 2 ** 200);

        assertGt(handler.okBet(), 0, "no bet ever succeeded");
        assertGt(handler.okReserve(), 0, "nothing ever matured and reserved");
        assertGt(handler.okSalvage(), 0, "no salvation ever paid");
        assertGt(handler.okWithdraw(), 0, "no matured bet ever cashed out");
        assertGt(handler.outOfRangeTried(), 0, "the out-of-range path was never exercised");
        console.log("bets %s reserves %s withdraws %s", handler.okBet(), handler.okReserve(), handler.okWithdraw());
        console.log("salvations %s bounties %s", handler.okSalvage(), handler.okBounty());
    }

    /// ⚠️ THE ANTI-VACUITY GUARD, per run. Three invariants over a sequence where every call
    /// reverted are three invariants that proved nothing, and that failure mode is invisible — the
    /// suite is green either way.
    ///
    /// Only the two things EVERY run must do are asserted here; anything rarer belongs in the
    /// scripted test above, because this fires on each run individually and an unlucky short
    /// sequence is not a bug.
    function afterInvariant() public view {
        assertGt(handler.okBet(), 0, "vacuous run: no bet was ever placed");
        assertGt(handler.outOfRangeTried(), 0, "vacuous run: no out-of-range betId was ever tried");
    }
}

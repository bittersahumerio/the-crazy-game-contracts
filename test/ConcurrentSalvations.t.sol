// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// CONCURRENT SALVATIONS MUST NOT OVERSPEND THE POOL, PROVED IN THREE CALLS.
//
// The claim: mode-3 salvations snapshot `jackpotOf` at OPEN (`baseAtOpen`), and opening one does not
// change `jackpotOf` — it reserves the saved bet, which drops `slack` and `U` by the identical
// roiTarget, leaving `slack - U` untouched. So N salvations opened before any of them settles all
// capture the SAME base, and then settle independently against it. The instant the rates sum past
// 10000 bps, the payouts exceed the money that base described.
//
// Three is enough to show it: at 5000 bps each, THREE top-band rolls sum to 15000 bps and would
// overspend by half the base. `pendingBountyMax` is what stops it, and these tests prove it does.
//
// Why the snapshot needs that guard: priced against the CURRENT slack, serial settles would compound
// downward — 50%, then 50% of the remainder — and never outrun the pool. Snapshotting the base at open
// fixes the mispricing against U, and removes that compounding at the same time.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ConcToken is ERC20 {
    constructor() ERC20("Conc", "CNC") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract ConcurrentSalvations is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    ConcToken tok;
    address host = makeAddr("host");
    address player = makeAddr("player");

    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant MIN_BET = 2_000 ether;   // ratio 50 = INSANITY_MIN_POOL_RATIO

    function setUp() public {
        oracle = new MockVRFWrapper();
        tok = new ConcToken();
        game = new CrazyGame(makeAddr("treasury"), 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok.mintTo(host, 1e12 ether);
        tok.mintTo(player, 1e12 ether);
        vm.prank(host);   tok.approve(address(game), type(uint256).max);
        vm.prank(player); tok.approve(address(game), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    /// Find a matured, unsalvaged bet and the bet that truly matured it, using the contract's own
    /// verification rule: threshold = cumulativeAtJoin + roiTarget, saviour is the first later bet
    /// whose own snapshot is at or above it.
    function _target(uint256 id, uint256 b) internal view returns (uint256 t) { (,, t,,,,,,) = game.bets(id, b); }

    function _pair(uint256 id, uint256 from) internal view returns (bool ok, uint256 b, uint256 s) {
        uint256 n = game.betCountOf(id);
        for (b = from; b < n; b++) {
            (,, uint256 target,, uint256 joinedAt,,,, bool salvaged) = game.bets(id, b);
            if (salvaged) continue;
            if (game.accumulatedOf(id, b) < target) continue;
            uint256 threshold = joinedAt + target;
            for (s = b + 1; s < n; s++) {
                (,,,, uint256 sJoin,,,,) = game.bets(id, s);
                if (sJoin >= threshold) return (true, b, s);
            }
        }
        return (false, 0, 0);
    }

    function test_F1_threeConcurrentTopBandRollsOverspendTheBase() public {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 86_400, 0, [uint16(3), 0, 0, 0]);
        for (uint256 i; i < 60; i++) {
            vm.prank(player);
            game.placeBet(id, MIN_BET);
        }

        uint256 baseBeforeOpens = game.jackpotOf(id);
        emit log_named_uint("jackpotOf before any open     ", baseBeforeOpens);

        // ⭐ Open three salvations WITHOUT settling any of them, checking after each that the base
        // available to the NEXT one has fallen by the ceiling this one just claimed.
        uint256 fee = oracle.fee();
        uint256 cursor;
        for (uint256 k; k < 3; k++) {
            (bool ok, uint256 b, uint256 s) = _pair(id, cursor);
            assertTrue(ok, "setup: needed three matured, unsalvaged bets");
            // ⚠️ TWO deductions per open, and conflating them made this assertion wrong once: the
            // call first PAYS the saved bet its roiTarget out of the pool, and only then snapshots
            // the base and claims the ceiling against what is left.
            uint256 base = game.jackpotOf(id) - _target(id, b);
            // ⭐ The ceiling is claimed on the BOUNTY base, which leaves out the saviour bet's own stake
            //    (CrazyGame._bountyBase); the pot itself only drops by the payout and that ceiling.
            (, uint256 savNet,,,,,,,) = game.bets(id, s);
            game.reserveRoiWithSalvation{value: fee}(id, b, s);
            cursor = b + 1;
            uint256 held = ((base - savNet) * game.INSANITY_MAX_BPS()) / 10_000;
            assertEq(game.jackpotOf(id), base - held, "each pending salvation must hold its ceiling");
            emit log_named_uint("base available after open     ", game.jackpotOf(id));
        }
        // Roughly halving each time. Before the fix it did not move at all across the three.
        assertLt(game.jackpotOf(id), baseBeforeOpens / 4, "the base must fall away geometrically");

        // Three 0.1%-band rolls: 5000 bps each, 15000 bps in total against ONE base.
        uint256 reservedBefore;
        (, reservedBefore) = game.balancesOf(id);
        oracle.fulfill(1, 99_950);
        oracle.fulfill(2, 99_950);
        oracle.fulfill(3, 99_950);
        (uint256 pool, uint256 reserved) = game.balancesOf(id);
        uint256 paid = reserved - reservedBefore;

        emit log_named_uint("total bounty paid             ", paid);
        emit log_named_uint("  ...against a base of         ", baseBeforeOpens);
        emit log_named_uint("FINAL pool                    ", pool);
        emit log_named_uint("FINAL reserved                ", reserved);

        // What is left owed to matured bets that were never reserved.
        uint256 owed;
        for (uint256 b; b < game.betCountOf(id); b++) {
            (,, uint256 t,,,, bool res, bool wd,) = game.bets(id, b);
            if (res || wd) continue;
            if (game.accumulatedOf(id, b) >= t) owed += t;
        }
        emit log_named_uint("still owed to matured bets    ", owed);
        emit log_named_uint("pool left after reserved       ", pool - reserved);

        // ⭐ THE FIX, ASSERTED. Three top-band rolls are the worst case the table allows, and they
        // must still fit inside the money the first of them was priced against.
        // Measured before the fix: 200,680 paid against a base of 185,320, stranding 15,360 of other
        // players' earned ROI and leaving the winner a jackpot of zero.
        assertLe(paid, baseBeforeOpens, "concurrent salvations must not outspend their shared base");
        assertLe(reserved, pool, "and the contract must never owe more than it holds");
        assertLe(owed, pool - reserved, "with every matured bet still covered");
    }

    /// The other half of the mechanism: a ceiling that is CLAIMED must be GIVEN BACK. Roll the
    /// smallest band three times — 20 bps each, so almost the whole reservation is unused — and the
    /// pot must return to very nearly what it started at. If a release is ever dropped, this game
    /// quietly loses half its pot to a counter nobody can see.
    function test_unusedCeilingIsReleasedOnSettle() public {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 86_400, 0, [uint16(3), 0, 0, 0]);
        for (uint256 i; i < 60; i++) {
            vm.prank(player);
            game.placeBet(id, MIN_BET);
        }

        uint256 baseBefore = game.jackpotOf(id);
        uint256 fee = oracle.fee();
        uint256 cursor;
        for (uint256 k; k < 3; k++) {
            (bool ok, uint256 b, uint256 s) = _pair(id, cursor);
            assertTrue(ok, "setup");
            game.reserveRoiWithSalvation{value: fee}(id, b, s);
            cursor = b + 1;
        }
        assertLt(game.jackpotOf(id), baseBefore / 4, "held while pending");

        uint256 heldBack = game.jackpotOf(id);
        oracle.fulfill(1, 0);       // 20 bps
        oracle.fulfill(2, 0);
        oracle.fulfill(3, 0);
        (uint256 pool, uint256 reserved) = game.balancesOf(id);

        // ⚠️ Asserted against the RAW slack, not against baseBefore: the three opens also paid three
        // matured bets out of the pool, so baseBefore is no longer a number this can be compared to.
        // What must hold is that every ceiling came back — i.e. nothing is still held in reserve for
        // a salvation that has resolved. A dropped release would silently cost this game half its
        // pot, with no event and no revert to point at.
        assertEq(game.jackpotOf(id), pool - reserved, "every unspent ceiling must be released");
        assertGt(game.jackpotOf(id), heldBack, "and the pot must be larger than while they were pending");
        assertLe(reserved, pool);
        assertGt(baseBefore, 0);
    }
}

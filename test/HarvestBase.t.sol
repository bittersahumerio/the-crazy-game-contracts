// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// THE SAVIOUR IS NEVER PAID OUT OF THEIR OWN STAKE (CrazyGame._bountyBase).
//
// The rule: a bounty is counted on the pot as it stood BEFORE the saviour's bet joined it. Measured against the
// realistic harvest below: 90% of the pot drained at a cohort of 60 without it, 36% with it (at 300 bps).
//
// THE HARVEST, against a REALISTIC game rather than a contrived one: parameters from the live $GATE
// game #34, scaled. deposit:minBet = 247, ROI 100%, host fee 1%, platform 3%, mode 1 at 200 bps (the
// worst case for the pot: mode 3's table averages 101.5 bps). The cohort bets are 1x minBet, exactly
// what real players bet there, so the cohort is indistinguishable from ordinary play. The attacker
// places K of them, one bet big enough to mature them all, then names that big bet as the saviour of
// every one.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test, console} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract HarvestToken is ERC20 {
    constructor() ERC20("Harvest", "HRV") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract HarvestBaseTest is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    HarvestToken tok;
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");

    uint256 constant MIN_BET = 269 ether;
    uint256 constant DEPOSIT = 66_470 ether;   // ratio 247, as live
    uint256 constant ROI_BPS = 10_000;         // 100%, as live
    uint256 constant BPS = 10_000;

    function setUp() public {
        oracle = new MockVRFWrapper();
        tok = new HarvestToken();
        game = new CrazyGame(treasury, 300, address(oracle), address(0), address(0), address(0), address(0), address(0),
            new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        address[3] memory all = [host, attacker, alice];
        for (uint256 i; i < 3; i++) {
            tok.mintTo(all[i], 1e30);
            vm.prank(all[i]);
            tok.approve(address(game), type(uint256).max);
        }
        vm.deal(attacker, 10 ether);
    }

    // games(id) by position: 11 cumulativePerBet, 12 activeBetCount, 13 betCount.
    function _word(uint256 id, uint256 i) internal view returns (uint256 v) {
        (bool ok, bytes memory r) = address(game).staticcall(abi.encodeWithSignature("games(uint256)", id));
        require(ok, "games()");
        assembly { v := mload(add(r, add(32, mul(i, 32)))) }
    }
    function _net(uint256 id, uint256 b) internal view returns (uint256 n) { (, n,,,,,,,) = game.bets(id, b); }

    /// The bet that would carry the accumulator past `threshold`, net of the 4% fees.
    function _grossToReach(uint256 id, uint256 threshold) internal view returns (uint256) {
        uint256 cum = _word(id, 11);
        uint256 active = _word(id, 12);
        return threshold <= cum ? MIN_BET : ((threshold - cum) * active * BPS) / 9_600 + 1 ether;
    }

    function _harvest(uint256 K, uint256 honest) internal returns (uint256 drainedPct, int256 profit) {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, ROI_BPS, 100, 0, 3600, 0, [uint16(1), 200, 0, 0]);

        // Honest traffic: bets of ~1x minBet, each matured one paid out as the reserver would.
        for (uint256 i = 0; i < honest; i++) {
            address p = makeAddr(string(abi.encodePacked("p", vm.toString(i))));
            tok.mintTo(p, 1e26);
            vm.prank(p); tok.approve(address(game), type(uint256).max);
            vm.prank(p); game.placeBet(id, MIN_BET + (i % 3) * 1 ether);
            uint256 n = _word(id, 13);
            for (uint256 b = 0; b < n; b++) {
                if (_word(id, 11) >= game.maturityThresholdOf(id, b)) { try game.reserveRoi(id, b) {} catch {} }
            }
        }

        uint256 potBefore = game.jackpotOf(id);
        uint256 attStart = tok.balanceOf(attacker);
        uint256 firstDust = _word(id, 13);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < K; i++) game.placeBet(id, MIN_BET);
        uint256 maxT;
        for (uint256 b = firstDust; b < firstDust + K; b++) {
            uint256 t = game.maturityThresholdOf(id, b);
            if (t > maxT) maxT = t;
        }
        game.placeBet(id, _grossToReach(id, maxT));
        uint256 saviour = _word(id, 13) - 1;
        uint256 landed;
        for (uint256 b = firstDust; b < firstDust + K; b++) {
            try game.reserveRoiWithSalvation(id, b, saviour) { landed++; } catch {}
        }
        vm.stopPrank();

        uint256 potAfter = game.jackpotOf(id);
        drainedPct = potBefore == 0 ? 0 : (100 * (potBefore - (potAfter < potBefore ? potAfter : potBefore))) / potBefore;
        profit = int256(tok.balanceOf(attacker)) - int256(attStart);
        console.log("--- cohort K, salvations landed ---", K, landed);
        console.log("  pot before / after ", potBefore / 1e18, potAfter / 1e18);
        console.log("  pot drained pct    ", drainedPct);
        if (profit >= 0) console.log("  attacker PROFIT    ", uint256(profit) / 1e18);
        else console.log("  attacker LOSS      ", uint256(-profit) / 1e18);
        assertEq(landed, K, "every cohort bet is still salvageable - the +EV salvation stays");
    }

    /// ⭐ At today's fixed-mode ceiling (200 bps), K = 60: 69% of the pot drained on the deployed contract
    ///    (attacker +46,576), 24% with the rule (+15,012). K = 30: 32% → 13%. (August, at 300 bps: 90% → 36%.)
    function test_harvest_K60_drainsAQuarter_notTwoThirds() public {
        (uint256 drained,) = _harvest(60, 30);
        assertLe(drained, 30, "the saviour's own stake is out of the base");
        assertGe(drained, 15, "and the salvations still pay: no cap");
    }

    function test_harvest_K10_and_K30_logged() public {
        _harvest(10, 30);
        setUp();
        _harvest(30, 30);
    }

    /// Modes 1 and 2: the bounty is the rate times (jackpot − the saviour bet's own net), to the wei.
    function test_mode1_bountyLeavesOutTheSavioursOwnStake() public {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, ROI_BPS, 100, 0, 3600, 0, [uint16(1), 200, 0, 0]);
        vm.prank(alice); game.placeBet(id, MIN_BET);                     // bet 1, to be saved
        uint256 big = _grossToReach(id, game.maturityThresholdOf(id, 1));
        vm.prank(attacker); game.placeBet(id, big);                      // bet 2, the saviour
        game.reserveRoi(id, 1);                                          // paid first, as the reserver may
        uint256 base = game.jackpotOf(id) - _net(id, 2);
        vm.expectEmit(true, true, true, true, address(game));
        emit CrazyGame.BountyAccrued(id, 2, attacker, 1, (base * 200) / BPS);
        game.reserveRoiWithSalvation(id, 1, 2);
    }

    /// Two salvations by ONE saviour: X% and then X% of what is left, each without the saviour's stake.
    function test_mode1_consecutiveSalvationsTakeOfWhatIsLeft() public {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, ROI_BPS, 100, 0, 3600, 0, [uint16(1), 200, 0, 0]);
        vm.prank(alice); game.placeBet(id, MIN_BET);                     // bet 1
        vm.prank(alice); game.placeBet(id, MIN_BET);                     // bet 2
        // ⚠️ Sized BEFORE the prank: _grossToReach makes external calls, and vm.prank binds to the first one.
        uint256 big = _grossToReach(id, game.maturityThresholdOf(id, 2));
        vm.prank(attacker); game.placeBet(id, big);                      // bet 3 matures both
        uint256 own = _net(id, 3);
        game.reserveRoi(id, 1);
        game.reserveRoi(id, 2);
        uint256 j1 = game.jackpotOf(id);
        game.reserveRoiWithSalvation(id, 1, 3);
        uint256 first = (j1 - own) * 200 / BPS;
        uint256 j2 = game.jackpotOf(id);
        assertEq(j2, j1 - first, "the first bounty left the pot");
        vm.expectEmit(true, true, true, true, address(game));
        emit CrazyGame.BountyAccrued(id, 3, attacker, 2, ((j2 - own) * 200) / BPS);
        game.reserveRoiWithSalvation(id, 2, 3);
    }

    /// Mode 3 (Insanity): the snapshotted base leaves out the saviour's stake, and the roll pays off it.
    function test_mode3_baseAtOpenLeavesOutTheSavioursOwnStake() public {
        vm.prank(host);
        uint256 id = game.createGame(address(tok), DEPOSIT, MIN_BET, ROI_BPS, 100, 0, 3600, 0, [uint16(3), 0, 0, 0]);
        vm.prank(alice); game.placeBet(id, MIN_BET);
        uint256 big = _grossToReach(id, game.maturityThresholdOf(id, 1));
        vm.prank(attacker); game.placeBet(id, big);
        game.reserveRoi(id, 1);
        uint256 base = game.jackpotOf(id) - _net(id, 2);
        uint256 fee = oracle.fee();
        vm.prank(attacker);
        game.reserveRoiWithSalvation{value: fee}(id, 1, 2);
        uint256 sid = game.salvationCount();
        (,,,, uint256 baseAtOpen,,) = game.salvations(sid);
        assertEq(baseAtOpen, base, "Insanity is priced on the same base as modes 1 and 2");
        // r = 0 rolls the 0.2% band.
        vm.expectEmit(true, true, true, true, address(game));
        emit CrazyGame.BountyAccrued(id, 2, attacker, 1, (base * 20) / BPS);
        oracle.fulfill(oracle.reqCount(), 0);
    }
}

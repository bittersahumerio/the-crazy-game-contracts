// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// THE HOST DEPOSIT STARTS WITH ITSELF ALREADY COUNTED.
//
// This was a PORT BUG, and it shipped on every BNB game ever created (1, 2 and 3). Bet #0 was
// written with `cumulativeAtJoin: g.cumulativePerBet`, which had just been seeded to netDeposit —
// so the deposit's accrued opened at ZERO against a principal+ROI target, and the host's own money
// had to accumulate a SECOND time before it could ever mature. Twice the growth Solana asks for.
//
// Solana does `accumulated_base = netDeposit, cumulative_at_join = 0`: the deposit is already
// counted, and only the ROI portion has to arrive. Measured on THE BENJAMIN (game 19, 50% ROI):
//     bet 0: amount 100_000000, roi_target 145_500000, cumulative_at_join 0, accumulated_base 97_000000
// so it needed 48.5 of growth — the ROI portion — not 145.5.
//
// ⛔ WHY THE FIX IS `cumulativeAtJoin: 0` AND NOT SOLANA'S FIELD LAYOUT: this contract relies on
//    accumulatedBase being zero until reserveRoi writes it. maturityThresholdOf and the salvation
//    threshold both compute `cumulativeAtJoin + roiTarget` with NO base term. Seeding the base at
//    creation would make those views disagree with the contract and every salvation naming bet #0
//    would revert BadParams — a silent failure that just stops paying bounties.
//
// ⚠️ WHY IT HID FOR SO LONG: normal bets are completely unaffected. The accumulator AND every later
//    bet's cumulativeAtJoin were both shifted up by netDeposit, so all their deltas were identical
//    and every number on the page "tied out". Only bet #0 was wrong, and only against Solana.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DepToken is ERC20 {
    constructor() ERC20("Dep", "DEP") { _mint(msg.sender, type(uint128).max); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract HostDepositAccrualTest is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    DepToken tok;
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address player = makeAddr("player");

    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant NET_DEPOSIT = 97_000 ether;   // 3% platform fee, no host fee on your own deposit
    uint256 constant MIN_BET = 1_000 ether;

    function setUp() public {
        oracle = new MockVRFWrapper();
        game = new CrazyGame(treasury, 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok = new DepToken();
        tok.mintTo(host, type(uint96).max);
        tok.mintTo(player, type(uint96).max);
        vm.prank(host);   tok.approve(address(game), type(uint256).max);
        vm.prank(player); tok.approve(address(game), type(uint256).max);
    }

    /// 100% ROI, fixed timer, Salvador off — the shape of BNB game 3.
    function _create() internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 1800, 0, [uint16(0), 0, 0, 0]);
    }

    /// ⭐ THE FIX. Before it, this was 0.
    function test_depositAccruesItsOwnPrincipalFromTheStart() public {
        uint256 id = _create();
        assertEq(
            game.accumulatedOf(id, 0), NET_DEPOSIT,
            "the deposit must start with itself already counted, not from zero"
        );
    }

    /// At 100% ROI that is exactly halfway — which is what the bets table should show.
    function test_depositStartsAtHalfwayNotAtZero() public {
        uint256 id = _create();
        (, , uint256 roiTarget, , , , , , ) = _bet(id, 0);
        assertEq(roiTarget, NET_DEPOSIT * 2, "target is principal + 100% ROI");
        assertEq(game.accumulatedOf(id, 0) * 2, roiTarget, "so accrued opens at 50% of target");
    }

    /// ⭐ THE ECONOMIC POINT: only the ROI PORTION has to arrive, not the principal a second time.
    function test_depositMaturesOnRoiPortionOfGrowth() public {
        uint256 id = _create();
        // One bet big enough to cover the ROI portion in a single hop. activeBetCount is 1, so the
        // whole net lands on bet #0.
        // The ROI portion is 97_000, and a bet loses 4% (3% platform + 1% host) on the way in, so
        // the gross has to be 97_000 / 0.96 = 101_042 at least. 100_000 nets 96_000 and lands 1_000
        // SHORT — which is what this assertion caught the first time it ran.
        uint256 gross = 101_100 ether;                        // nets 97_056
        vm.prank(player);
        game.placeBet(id, gross);

        assertGe(
            game.accumulatedOf(id, 0), NET_DEPOSIT * 2,
            "after ROI-portion growth the deposit must be AT its target, not half way to it"
        );
    }

    /// ⛔ The invariant the one-line fix exists to protect.
    function test_accumulatedBaseStaysZeroUntilReserve() public {
        uint256 id = _create();
        (, , , uint256 accumulatedBase, uint256 cumulativeAtJoin, , , , ) = _bet(id, 0);
        assertEq(accumulatedBase, 0, "a non-zero base at creation breaks maturityThresholdOf and salvations");
        assertEq(cumulativeAtJoin, 0, "the deposit joins at 0; the accumulator is what carries netDeposit");
    }

    /// The threshold view must agree with the contract's own maturity condition for bet #0.
    function test_thresholdViewAgreesWithTheContractForTheDeposit() public {
        uint256 id = _create();
        (, , uint256 roiTarget, uint256 base, uint256 join, , , , ) = _bet(id, 0);
        // Contract matures when: base + (cpb - join) >= roiTarget  =>  cpb >= join + roiTarget - base
        assertEq(
            game.maturityThresholdOf(id, 0), join + roiTarget - base,
            "the published threshold must be the real one, or an indexer names saviours the contract rejects"
        );
    }

    /// Normal bets are untouched by the fix — this is why it hid.
    function test_normalBetsAreUnaffected() public {
        uint256 id = _create();
        vm.prank(player);
        game.placeBet(id, MIN_BET);
        (, uint256 netAmount, uint256 roiTarget, uint256 base, , , , , ) = _bet(id, 1);
        assertEq(netAmount, 960 ether, "1000 less 3% platform and 1% host");
        assertEq(roiTarget, 1_920 ether, "principal + 100% ROI");
        assertEq(base, 0, "a normal bet still starts from zero, and still must accrue its full target");
        assertEq(game.accumulatedOf(id, 1), 0, "it has accrued nothing yet");
    }

    /// The public `bets` mapping getter. Nine fields, in declaration order.
    function _bet(uint256 id, uint256 betId)
        internal view
        returns (address, uint256, uint256, uint256, uint256, uint256, bool, bool, bool)
    {
        return game.bets(id, betId);
    }
}

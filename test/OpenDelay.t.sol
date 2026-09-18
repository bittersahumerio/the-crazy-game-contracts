// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * ⭐ THE OPENING DELAY, FOR A COIN STILL INSIDE ITS LAUNCH WINDOW — deployed the way Arc runs it:
 *    OPEN_DELAY = 300, no oracle.
 *
 * TOLLY caps every wallet, this contract included, at 3% of a new coin's supply until the coin's
 * antiSnipeDeadline(). A game created before then opens max(creation + OPEN_DELAY, deadline + 1); every
 * other game opens at creation. Operator, 2026-09-16: "a mandatory delay, not max", then "we only need
 * it on launched tokens".
 *
 * ⚠️ The other half matters as much: a plain token, a closed window, and a coin that answers badly must
 *    all open at creation and must never make the host's createGame revert.
 */
contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PL") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// A TOLLY-shaped coin: the deadline is the token's own view.
contract WindowToken is ERC20 {
    uint256 public antiSnipeDeadline;
    constructor() ERC20("Window", "WN") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    function setDeadline(uint256 d) external { antiSnipeDeadline = d; }
}

contract RevertingWindowToken is ERC20 {
    constructor() ERC20("Revert", "RV") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    function antiSnipeDeadline() external pure returns (uint256) { revert("nope"); }
}

/// Answers with ONE byte. try/catch would not catch the decode failure; the contract must.
contract ShortWindowToken is ERC20 {
    constructor() ERC20("Short", "SH") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    fallback() external {
        assembly { mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000) return(0, 1) }
    }
}

/// Burns whatever gas it is given.
contract GreedyWindowToken is ERC20 {
    constructor() ERC20("Greedy", "GR") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    function antiSnipeDeadline() external view returns (uint256 x) { while (gasleft() > 0) { x++; } }
}

contract OpenDelayTest is Test {
    CrazyGame game;

    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address alice = makeAddr("alice");

    uint256 constant DELAY = 300;
    uint256 constant DEPOSIT = 100_000 ether;
    uint256 constant MIN_BET = 100 ether;
    uint256 constant DURATION = 3600;
    uint256 constant T0 = 1_800_000_000;

    event GameOpensAt(uint256 indexed gameId, uint256 opensAt);

    function setUp() public {
        vm.warp(T0);
        game = _deploy(DELAY);
    }

    function _deploy(uint256 delay) internal returns (CrazyGame g) {
        g = new CrazyGame(
            treasury, 500, address(0),
            address(0), address(0), address(0), address(0), address(0),
            new address[](0), new uint256[](0), address(0),
            [uint256(0.0002 ether), 0.0004 ether, 0.04 ether],
            delay
        );
    }

    function _fund(CrazyGame g, address tok) internal {
        address[2] memory who = [host, alice];
        for (uint256 i; i < 2; i++) {
            PlainToken(tok).mintTo(who[i], 10_000_000 ether);
            vm.prank(who[i]);
            PlainToken(tok).approve(address(g), type(uint256).max);
        }
    }

    function _create(CrazyGame g, address tok, uint256 timerMode, uint256 increment) internal returns (uint256 id) {
        _fund(g, tok);
        vm.prank(host);
        id = g.createGame(tok, DEPOSIT, MIN_BET, 10_000, 100, timerMode, DURATION, increment, [uint16(1), 100, 0, 0]);
    }

    function _window(uint256 deadline) internal returns (address) {
        WindowToken w = new WindowToken();
        w.setDeadline(deadline);
        return address(w);
    }

    function _bet(CrazyGame g, uint256 id) internal {
        vm.prank(alice);
        g.placeBet(id, MIN_BET);
    }

    // ── the deployment ────────────────────────────────────────────────────────────────────────

    function test_theDelayIsPartOfTheDeployment() public view {
        assertEq(game.OPEN_DELAY(), DELAY);
    }

    function test_aDelayPastTheTimerCeilingIsADeployTypo() public {
        vm.expectRevert(CrazyGame.BadParams.selector);
        _deploy(1_440 * 60 + 1);
        assertEq(_deploy(1_440 * 60).OPEN_DELAY(), 1_440 * 60, "the ceiling itself is allowed");
    }

    // ── a coin inside its launch window ───────────────────────────────────────────────────────

    /// The launch case: created ~20 s after launch, 280 s of window left. Opens at creation + 300.
    function test_insideTheWindow_theGameOpensAfterTheDelay() public {
        address tok = _window(T0 + 280);
        _fund(game, tok);
        // expectEmit binds to the NEXT call, so the funding (mint, approve) has to happen before it.
        vm.expectEmit(true, false, false, true, address(game));
        emit GameOpensAt(1, T0 + DELAY);
        vm.prank(host);
        uint256 id = game.createGame(tok, DEPOSIT, MIN_BET, 10_000, 100, 0, DURATION, 0, [uint16(1), 100, 0, 0]);
        assertEq(10_000_000 ether - PlainToken(tok).balanceOf(host), DEPOSIT, "the pot is taken at creation");
        assertEq(game.opensAtOf(id), T0 + DELAY);
        assertEq(game.timerEndOf(id), T0 + DELAY + DURATION, "the timer runs from the opening");
    }

    /// A pad with a LONGER window than our delay: the game still cannot open inside it.
    function test_aWindowLongerThanTheDelay_opensTheSecondAfterIt() public {
        uint256 id = _create(game, _window(T0 + 900), 0, 0);
        assertEq(game.opensAtOf(id), T0 + 901, "the deadline second is still capped (<=)");
    }

    /// The deadline second itself is inside the window.
    function test_createdOnTheDeadlineSecond_isStillDelayed() public {
        uint256 id = _create(game, _window(T0), 0, 0);
        assertEq(game.opensAtOf(id), T0 + DELAY);
    }

    function test_aBetBeforeTheOpeningRevertsWithTheOpening() public {
        uint256 id = _create(game, _window(T0 + 280), 0, 0);
        uint256 opensAt = game.opensAtOf(id);

        vm.expectRevert(abi.encodeWithSelector(CrazyGame.NotOpenYet.selector, opensAt));
        _bet(game, id);

        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(CrazyGame.NotOpenYet.selector, opensAt));
        _bet(game, id);

        vm.warp(opensAt);
        _bet(game, id);
        assertEq(game.betCountOf(id), 2, "open means open, to the second");
    }

    function test_cumulativeModeCountsFromTheOpening() public {
        uint256 id = _create(game, _window(T0 + 280), 1, 120);
        uint256 opensAt = game.opensAtOf(id);
        assertEq(game.timerEndOf(id), opensAt + DURATION);
        vm.warp(opensAt);
        _bet(game, id);
        assertEq(game.timerEndOf(id), opensAt + DURATION + 120);
    }

    /// The host cannot take the pot back out through bet #0 while nobody can bet against it.
    function test_theHostDepositCannotMatureBeforeTheOpening() public {
        uint256 id = _create(game, _window(T0 + 280), 0, 0);
        vm.prank(host);
        vm.expectRevert(CrazyGame.RoiNotReached.selector);
        game.withdraw(id, 0);
    }

    function test_theJackpotWaitsForTheDelayedTimer() public {
        uint256 id = _create(game, _window(T0 + 280), 0, 0);
        vm.warp(T0 + DURATION + game.JACKPOT_DELAY());   // what an undelayed game would allow
        vm.prank(host);
        vm.expectRevert(CrazyGame.NotYet.selector);
        game.claimJackpot(id);
    }

    /// A deployment with no delay still keeps a game out of the window: it opens the second after.
    function test_zeroDelayDeployment_stillWaitsOutAWindow() public {
        CrazyGame plain = _deploy(0);
        uint256 id = _create(plain, _window(T0 + 280), 0, 0);
        assertEq(plain.opensAtOf(id), T0 + 281);
    }

    /// Not a launch window: a coin claiming one longer than a day is refused rather than trusted.
    function test_aWindowPastTheTimerCeilingIsRefused() public {
        address tok = _window(T0 + 1_440 * 60 + 1);
        _fund(game, tok);
        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(tok, DEPOSIT, MIN_BET, 10_000, 100, 0, DURATION, 0, [uint16(1), 100, 0, 0]);
    }

    // ── every other game opens at creation, and nothing about the check can stop one ─────────

    function _assertOpensAtCreation(address tok) internal {
        vm.recordLogs();
        uint256 id = _create(game, tok, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != GameOpensAt.selector, "no GameOpensAt without a window");
        }
        assertEq(game.opensAtOf(id), 0, "0 means open from creation");
        assertEq(game.timerEndOf(id), block.timestamp + DURATION, "the timer is unchanged");
        _bet(game, id);
        assertEq(game.betCountOf(id), 2, "a bet in the same second as creation is accepted");
    }

    function test_aTokenWithNoWindow_opensAtCreation() public {
        _assertOpensAtCreation(address(new PlainToken()));
    }

    function test_aClosedWindow_opensAtCreation() public {
        _assertOpensAtCreation(_window(T0 - 1));
    }

    function test_aNeverSetDeadline_opensAtCreation() public {
        _assertOpensAtCreation(_window(0));
    }

    function test_aCoinWhoseViewReverts_opensAtCreation() public {
        _assertOpensAtCreation(address(new RevertingWindowToken()));
    }

    function test_aCoinAnsweringOneByte_opensAtCreation() public {
        _assertOpensAtCreation(address(new ShortWindowToken()));
    }

    function test_aCoinBurningItsGas_opensAtCreation() public {
        _assertOpensAtCreation(address(new GreedyWindowToken()));
    }
}

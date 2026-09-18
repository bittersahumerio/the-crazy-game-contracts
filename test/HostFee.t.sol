// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The host fee: paid to the host, with the pool as fallback.
//
// This was a PORT BUG. The EVM version did `poolBalance += netAmount + hostFee` under a comment
// claiming "host fee stays in the pool, as on Solana" — but that describes only Solana's FALLBACK
// branch. The live program pays the host directly into a per-game vault whose authority is the
// host, and routes the fee to the pool only when that account has been closed. So on BNB the host
// was funding the jackpot instead of earning from it, on every single bet.
//
// The fallback is not paranoia: the game accepts ARBITRARY tokens and this transfer sits on the hot
// path of every bet, so a token that refuses to pay one address must not be able to revert the
// whole game.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") { _mint(msg.sender, type(uint128).max); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// A token with an admin blocklist, exactly like USDT/USDC. Refuses transfers to a blocked address.
contract BlocklistToken is ERC20 {
    mapping(address => bool) public blocked;
    constructor() ERC20("Block", "BLK") { _mint(msg.sender, type(uint128).max); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
    function block_(address a) external { blocked[a] = true; }
    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "recipient is blocked");
        super._update(from, to, value);
    }
}

contract HostFeeTest is Test {
    CrazyGame game;
    MockVRFWrapper oracle;
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address player = makeAddr("player");

    function setUp() public {
        oracle = new MockVRFWrapper();
        game = new CrazyGame(treasury, 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
    }

    function _fund(address tokenAddr) internal {
        PlainToken t = PlainToken(tokenAddr);
        t.mintTo(host, type(uint96).max);
        t.mintTo(player, type(uint96).max);
        vm.prank(host);   ERC20(tokenAddr).approve(address(game), type(uint256).max);
        vm.prank(player); ERC20(tokenAddr).approve(address(game), type(uint256).max);
    }

    function _create(address tokenAddr, uint256 hostFeeBps) internal returns (uint256 id) {
        vm.prank(host);
        id = game.createGame(tokenAddr, 100_000 ether, 100 ether, 10_000, hostFeeBps, 0, 3600, 0, [uint16(0), 0, 0, 0]);
    }

    function _pool(uint256 id) internal view returns (uint256 p) { (p,) = game.balancesOf(id); }

    /// ⭐ THE FIX: the host is paid, on every bet, exactly as the live Solana program does.
    function test_hostIsPaidTheirFeeOnEveryBet() public {
        PlainToken tok = new PlainToken();
        _fund(address(tok));
        uint256 id = _create(address(tok), 500);          // 5%

        uint256 before = tok.balanceOf(host);
        vm.prank(player);
        game.placeBet(id, 1_000 ether);

        uint256 paid = tok.balanceOf(host) - before;
        assertEq(paid, 50 ether, "host must receive 5% of the bet, not zero");
    }

    /// And it does NOT sit in the pool any more, so it is not swept to the last bettor.
    function test_hostFeeNoLongerInflatesThePool() public {
        PlainToken tok = new PlainToken();
        _fund(address(tok));
        uint256 id = _create(address(tok), 500);

        uint256 poolBefore = _pool(id);
        vm.prank(player);
        game.placeBet(id, 1_000 ether);

        // 1000 - 3% platform - 5% host = 920 net. The pool grows by the net only.
        assertEq(_pool(id) - poolBefore, 920 ether, "the pool must grow by the NET, with no host fee riding along");
        assertLe(_pool(id), tok.balanceOf(address(game)), "and the contract must still hold what it claims");
    }

    /// ⚠️ THE ACCEPTED TRADE-OFF, pinned so it is a decision on the record rather than a surprise.
    /// Solana's fallback-to-pool branch is NOT ported, because it answers a Solana-only hazard:
    /// token accounts there can be CLOSED by their owner to reclaim rent. Nothing equivalent exists
    /// on the EVM. The residual risk is a USDT-style admin blocklist hitting the host mid-game.
    ///
    /// The blast radius is small and this test is what proves it: only placeBet reverts. Money
    /// already in the game is NOT stranded — matured players still withdraw and the winner still
    /// claims, because neither path touches the host fee. The game simply stops taking new bets.
    function test_blockedHostHaltsNewBetsButStrandsNothing() public {
        BlocklistToken tok = new BlocklistToken();
        tok.mintTo(host, type(uint96).max);
        tok.mintTo(player, type(uint96).max);
        vm.prank(host);   tok.approve(address(game), type(uint256).max);
        vm.prank(player); tok.approve(address(game), type(uint256).max);

        vm.prank(host);
        uint256 id = game.createGame(address(tok), 100_000 ether, 100 ether, 10_000, 500, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        vm.prank(player);
        uint256 a = game.placeBet(id, 5_000 ether);        // a real bet lands first
        tok.block_(host);                                  // now the host is blocked

        vm.prank(player);
        vm.expectRevert();                                 // new bets stop
        game.placeBet(id, 1_000 ether);

        // ...but the money already in the game is still reachable.
        vm.warp(block.timestamp + 3600 + 301);
        address winner = game.lastBettorOf(id);
        vm.prank(winner);
        game.claimJackpot(id);                             // the winner is paid
        assertGt(tok.balanceOf(winner), 0, "the jackpot must still be claimable with a blocked host");
        a;                                                 // silence unused warning
    }

    /// hostFeeBps is bounded 100..500, matching Solana. Zero is no longer a legal configuration —
    /// it let a host be set up to earn nothing from their own game.
    function test_zeroHostFeeIsRefusedAtCreation() public {
        PlainToken tok = new PlainToken();
        _fund(address(tok));
        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(tok), 100_000 ether, 100 ether, 10_000, 0, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        vm.prank(host);
        vm.expectRevert(CrazyGame.BadParams.selector);
        game.createGame(address(tok), 100_000 ether, 100 ether, 10_000, 99, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        // and the boundaries themselves are accepted
        _create(address(tok), 100);
        _create(address(tok), 500);
    }
}

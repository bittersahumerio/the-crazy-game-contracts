// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// placeBetWithPermit — betting in ONE transaction on an EIP-2612 token.
//
// The interesting test here is not the happy path, it is the FRONT-RUN. A permit signature sits in
// the mempool in plain sight, and anyone can lift it and submit `permit` themselves. The nonce is
// then spent and our own permit call reverts — so an entrypoint that REQUIRED the permit to succeed
// could be griefed on every single bet, for the price of gas, by an observer who gains nothing.
// The permit is therefore attempted and its failure ignored: by then the allowance exists either
// way, and if it does not, the pull reverts a moment later anyway.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "./MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract PermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Permit", "PRM") ERC20Permit("Permit") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// A token with no permit at all — the majors on BSC are all like this (measured 2026-08-19).
contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {}
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

contract PermitTest is Test {
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    CrazyGame game;
    PermitToken tok;
    MockVRFWrapper oracle;

    uint256 constant PK = 0xA11CE;
    address player;
    address host = makeAddr("host");
    address treasury = makeAddr("treasury");

    uint256 constant DEPOSIT = 1_000_000 ether;
    uint256 constant MIN_BET = 10_000 ether;

    function setUp() public {
        player = vm.addr(PK);
        oracle = new MockVRFWrapper();
        game = new CrazyGame(treasury, 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok = new PermitToken();

        tok.mintTo(host, 100_000_000 ether);
        tok.mintTo(player, 100_000_000 ether);
        vm.prank(host);
        tok.approve(address(game), type(uint256).max);
    }

    function _newGame() internal returns (uint256) {
        vm.prank(host);
        return game.createGame(address(tok), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);
    }

    /// Build a real EIP-712 permit signature for `player`, the way a wallet would.
    function _sign(uint256 value, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, player, address(game), value, tok.nonces(player), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tok.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(PK, digest);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// ⭐ THE POINT OF THE WHOLE FEATURE: a bet with NO prior allowance, in one transaction.
    function test_betsWithNoPriorApproval() public {
        uint256 id = _newGame();
        assertEq(tok.allowance(player, address(game)), 0, "precondition: nothing approved");

        (uint8 v, bytes32 r, bytes32 s) = _sign(MIN_BET, block.timestamp + 1 hours);
        vm.prank(player);
        uint256 betId = game.placeBetWithPermit(id, MIN_BET, block.timestamp + 1 hours, v, r, s);

        (address who,,,,,,,,) = game.bets(id, betId);
        assertEq(who, player, "the bet must be recorded against the signer");
        assertEq(game.betCountOf(id), 2, "host deposit is bet 0, this is bet 1");
    }

    /**
     * ⛔ THE GRIEFING CASE. A watcher lifts the signature out of the mempool and submits `permit`
     * themselves. The nonce is consumed, so the game's own permit call now reverts — and if the
     * entrypoint required it to succeed, every bet on a permit token could be blocked by anyone
     * willing to pay gas. The allowance is already in place, so the bet must go through regardless.
     */
    function test_frontRunPermitDoesNotBlockTheBet() public {
        uint256 id = _newGame();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(MIN_BET, deadline);

        // Anyone at all, not the player.
        vm.prank(makeAddr("mempoolWatcher"));
        IERC20Permit(address(tok)).permit(player, address(game), MIN_BET, deadline, v, r, s);
        assertEq(tok.allowance(player, address(game)), MIN_BET, "the watcher set our allowance for us");

        // The same signature is now dead. The bet still lands.
        vm.prank(player);
        uint256 betId = game.placeBetWithPermit(id, MIN_BET, deadline, v, r, s);
        (address who,,,,,,,,) = game.bets(id, betId);
        assertEq(who, player, "a spent permit must not cost the player their bet");
    }

    /// A signature that is not valid AND no allowance to fall back on must still fail — the
    /// permissive catch must not become a way to bet without paying.
    function test_garbageSignatureWithNoAllowanceStillReverts() public {
        uint256 id = _newGame();
        vm.prank(player);
        vm.expectRevert();   // the pull is the judge: no allowance, no bet
        game.placeBetWithPermit(id, MIN_BET, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    /// An expired deadline is just a failed permit. Same rule: no allowance behind it, no bet.
    function test_expiredDeadlineWithNoAllowanceStillReverts() public {
        uint256 id = _newGame();
        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = _sign(MIN_BET, deadline);
        vm.warp(deadline + 1);

        vm.prank(player);
        vm.expectRevert();
        game.placeBetWithPermit(id, MIN_BET, deadline, v, r, s);
    }

    /// ...but an expired signature over a standing allowance is harmless, which is the same
    /// permissiveness seen from the other side.
    function test_expiredDeadlineIsFineWhenAlreadyApproved() public {
        uint256 id = _newGame();
        vm.prank(player);
        tok.approve(address(game), type(uint256).max);

        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = _sign(MIN_BET, deadline);
        vm.warp(deadline + 1);

        vm.prank(player);
        uint256 betId = game.placeBetWithPermit(id, MIN_BET, deadline, v, r, s);
        (address who,,,,,,,,) = game.bets(id, betId);
        assertEq(who, player, "a standing allowance is enough on its own");
    }

    /// ⚠️ A NON-PERMIT TOKEN MUST NOT BRICK THE ENTRYPOINT — none of USDT, USDC, WBNB, BUSD or CAKE
    /// on BSC implements permit, so this is the common case, not the exotic one. The try/catch has
    /// to swallow "function does not exist" exactly as it swallows a bad signature.
    function test_nonPermitTokenFallsBackToTheAllowance() public {
        PlainToken plain = new PlainToken();
        plain.mintTo(host, 100_000_000 ether);
        plain.mintTo(player, 100_000_000 ether);
        vm.prank(host);
        plain.approve(address(game), type(uint256).max);
        vm.prank(host);
        uint256 id = game.createGame(address(plain), DEPOSIT, MIN_BET, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);

        vm.prank(player);
        plain.approve(address(game), type(uint256).max);

        vm.prank(player);
        uint256 betId = game.placeBetWithPermit(id, MIN_BET, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        (address who,,,,,,,,) = game.bets(id, betId);
        assertEq(who, player, "a token without permit must still be bettable through this door");
    }

    /// The refactor that made room for the permit entrypoint moved placeBet's body into a private
    /// function. This is the regression guard for that move.
    function test_plainPlaceBetStillWorks() public {
        uint256 id = _newGame();
        vm.prank(player);
        tok.approve(address(game), type(uint256).max);
        vm.prank(player);
        uint256 betId = game.placeBet(id, MIN_BET);
        (address who,,,,,,,,) = game.bets(id, betId);
        assertEq(who, player, "the ordinary path must be untouched");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {MockVRFWrapper} from "../test/MockVRFWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract InsToken is ERC20 {
    constructor() ERC20("Ins", "INS") { _mint(msg.sender, 1_000_000_000 ether); }
}

/**
 * A full INSANITY game, played through real broadcast transactions against a real node.
 *
 * The unit tests prove the maths inside the EVM harness with cheatcodes. This proves the same path
 * the way it will actually run: real approvals, real broadcasts, a real oracle callback arriving in
 * its own separate transaction. Things that pass under `vm.prank` and fail over RPC — the consumed
 * prank in the test suite was exactly one — are what this catches.
 *
 *   anvil &
 *   forge script script/Insanity.s.sol --tc Insanity --rpc-url http://127.0.0.1:8545 --broadcast \
 *     --private-key <anvil key 0>
 */
contract Insanity is Script {
    function run() external {
        vm.startBroadcast();

        MockVRFWrapper oracle = new MockVRFWrapper();
        InsToken tok = new InsToken();
        CrazyGame game = new CrazyGame(msg.sender, 300, address(oracle), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok.approve(address(game), type(uint256).max);

        // Salvador mode 3 — the host sets NO rate; the table decides it.
        uint256 id = game.createGame(
            address(tok), 100_000 ether, 100 ether, 10_000, 100, 0, 3600, 0,
            [uint16(3), 0, 0, 0]
        );
        console.log("game id             :", id);
        console.log("pool after create   :", _pool(game, id));

        uint256 victim = game.placeBet(id, 1_000 ether);
        uint256 target = _target(game, id, victim);
        uint256 i;
        while (game.accumulatedOf(id, victim) < target && i < 60) {
            game.placeBet(id, 5_000 ether);
            i++;
        }
        console.log("bets to mature it   :", i);

        uint256 threshold = game.maturityThresholdOf(id, victim);
        uint256 saviour;
        for (uint256 j = victim + 1; j < game.betCountOf(id); j++) {
            if (_cumAtJoin(game, id, j) >= threshold) { saviour = j; break; }
        }

        uint256 jackpotBefore = game.jackpotOf(id);
        console.log("jackpot before      :", jackpotBefore);

        // ── Trigger. Pays the oracle fee; the matured bet is reserved in THIS tx. ──
        uint256 fee = oracle.calculateRequestPriceNative(200_000, 1);
        game.reserveRoiWithSalvation{value: fee}(id, victim, saviour);
        console.log("salvations pending  :", game.salvationsPendingOf(id));
        console.log("bounty owed (pre)   :", _bounty(game, id, saviour));
        console.log("  ^ zero is CORRECT - the rate is not known yet");

        // ── The callback, in its own transaction, exactly as the VRF wrapper delivers it. ──
        // 96_500 lands in the 4.9% band -> 1000 bps (10%).
        oracle.fulfill(1, 96_500);
        console.log("salvations pending  :", game.salvationsPendingOf(id));
        console.log("bounty owed (post)  :", _bounty(game, id, saviour));
        console.log("expected @10%%       :", (game.jackpotOf(id) + _bounty(game, id, saviour)) / 10);

        game.claimBounty(id, saviour);
        console.log("jackpot after       :", game.jackpotOf(id));
        console.log("contract holds      :", tok.balanceOf(address(game)));
        console.log("pool says           :", _pool(game, id));
        console.log("solvent (pool>=res) :", _pool(game, id) >= _reserved(game, id));

        vm.stopBroadcast();
    }

    function _pool(CrazyGame g, uint256 id) internal view returns (uint256 p) { (p,) = g.balancesOf(id); }
    function _reserved(CrazyGame g, uint256 id) internal view returns (uint256 r) { (, r) = g.balancesOf(id); }
    function _target(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 t) { (,, t,,,,,,) = g.bets(id, b); }
    function _cumAtJoin(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 c) { (,,,, c,,,,) = g.bets(id, b); }
    function _bounty(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 o) { (,,,,, o,,,) = g.bets(id, b); }
}

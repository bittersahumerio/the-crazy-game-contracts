// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LifeToken is ERC20 {
    constructor() ERC20("Life", "LIFE") { _mint(msg.sender, 1_000_000_000 ether); }
}

/**
 * A full game, played through real transactions against a real node.
 *
 * The unit tests already prove the maths, but they run inside the EVM harness with cheatcodes. This
 * exercises the same path the way a player would: real approvals, real broadcasts, real block
 * timestamps. Things that pass under `vm.prank` and fail over RPC are exactly what this catches.
 */
contract Lifecycle is Script {
    function run() external {
        vm.startBroadcast();

        LifeToken tok = new LifeToken();
        CrazyGame game = new CrazyGame(msg.sender, 300, vm.envOr("ENTROPY", address(0)), address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok.approve(address(game), type(uint256).max);

        // Salvador mode 1, fixed 2%.
        uint256 id = game.createGame(
            address(tok), 100_000 ether, 100 ether, 10_000, 100, 0, 3600, 0,
            [uint16(1), 200, 0, 0]
        );
        console.log("game id            :", id);
        console.log("pool after create  :", _pool(game, id));

        // Bet 1 — the one we will mature and get saved.
        uint256 victim = game.placeBet(id, 1_000 ether);

        // Push money in until it matures.
        uint256 target = _target(game, id, victim);
        uint256 i;
        while (game.accumulatedOf(id, victim) < target && i < 60) {
            game.placeBet(id, 5_000 ether);
            i++;
        }
        console.log("bets to mature it  :", i);
        console.log("jackpot before     :", game.jackpotOf(id));

        // Find the saviour the way an indexer would, then let the contract verify it.
        uint256 threshold = game.maturityThresholdOf(id, victim);
        uint256 saviour;
        for (uint256 j = victim + 1; j < game.betCountOf(id); j++) {
            if (_cumAtJoin(game, id, j) >= threshold) { saviour = j; break; }
        }
        console.log("saviour bet        :", saviour);

        game.reserveRoiWithSalvation(id, victim, saviour);
        console.log("jackpot after      :", game.jackpotOf(id));
        console.log("bounty owed        :", _bounty(game, id, saviour));

        game.withdraw(id, victim);
        game.claimBounty(id, saviour);
        console.log("solvent (pool>=res):", _pool(game, id) >= _reserved(game, id));
        console.log("contract holds     :", tok.balanceOf(address(game)));
        console.log("pool says          :", _pool(game, id));

        vm.stopBroadcast();
    }

    // Small helpers so the script reads as a story rather than as tuple destructuring.
    function _pool(CrazyGame g, uint256 id) internal view returns (uint256 p) { (p,) = g.balancesOf(id); }
    function _reserved(CrazyGame g, uint256 id) internal view returns (uint256 r) { (, r) = g.balancesOf(id); }
    function _target(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 t) { (,, t,,,,,,) = g.bets(id, b); }
    function _cumAtJoin(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 c) { (,,,, c,,,,) = g.bets(id, b); }
    function _bounty(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 o) { (,,,,, o,,,) = g.bets(id, b); }
}

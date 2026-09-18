// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrazyGame, IVRFV2PlusWrapper} from "../contracts/CrazyGame.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ForkToken is ERC20 {
    constructor() ERC20("Fork", "FORK") { _mint(msg.sender, 1_000_000_000 ether); }
}

/**
 * ⭐ THE PRE-MAINNET ORACLE PROOF: open a real Insanity salvation against the REAL Chainlink VRF
 * v2.5 wrapper, on a fork of BSC mainnet. No money, no mainnet transaction, real oracle contract.
 *
 *   anvil --port 8546 --fork-url https://bsc-mainnet.public.blastapi.io &
 *   VRF_WRAPPER=0x471506e6ADED0b9811D05B8cAc8Db25eE839Ac94 \
 *     forge script script/ForkVrf.s.sol --tc ForkVrf --rpc-url http://127.0.0.1:8546 \
 *     --broadcast --private-key <a throwaway funded with anvil_setBalance>
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
 *
 * Every Insanity test to date runs against test/MockVRFWrapper.sol. A mock proves our state machine;
 * it cannot prove that the REAL wrapper accepts what we send it. Four things have only ever been
 * checked against ourselves:
 *
 *   • the wrapper ADDRESS is the wrapper and not the coordinator,
 *   • `extraArgs` is `abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)` — get the
 *     native-payment flag wrong and the wrapper bills in LINK, which we do not hold,
 *   • VRF_CALLBACK_GAS and VRF_CONFIRMATIONS are inside the wrapper's accepted bounds,
 *   • the fee we forward as msg.value is what it actually wants.
 *
 * ⛔ AND THE FAILURE WOULD BE SILENT. `_openSalvation` wraps the oracle call in try/catch on purpose,
 * so that a dead oracle records-and-clears instead of freezing the game. That means a REVERT here
 * does not revert the transaction — it emits SalvationRequestFailed and leaves armedAt == 0, and
 * the fixed fallback rate quietly carries the whole feature. That is the ORAO failure exactly: on
 * Solana the VRF never worked for months and the fallback covered for it.
 *
 * ⇒ So this script does not merely "not revert". It ASSERTS armedAt != 0, which is the only
 *   observable difference between "the real wrapper accepted our request" and "the real wrapper
 *   rejected it and nobody noticed".
 *
 * The callback itself never arrives — there is no Chainlink node watching a private fork — and that
 * is fine: fulfilment is Chainlink's side and the stall path is already covered by the suite.
 */
contract ForkVrf is Script {
    function run() external {
        address wrapper = vm.envAddress("VRF_WRAPPER");
        require(wrapper.code.length > 0, "VRF_WRAPPER has no code - not a BSC fork, or wrong address");

        uint256 quoted = IVRFV2PlusWrapper(wrapper).calculateRequestPriceNative(200_000, 1);
        console.log("wrapper            :", wrapper);
        console.log("quoted fee (wei)   :", quoted);
        console.log("tx.gasprice (wei)  :", tx.gasprice);
        require(quoted > 0, "the real wrapper quoted a ZERO fee - wrong address, or gasprice is 0");

        vm.startBroadcast();

        ForkToken tok = new ForkToken();
        CrazyGame game = new CrazyGame(msg.sender, 300, wrapper, address(0), address(0), address(0), address(0), address(0), new address[](0), new uint256[](0), address(0), [uint256(0.0002 ether), 0.0004 ether, 0.04 ether], 0);
        tok.approve(address(game), type(uint256).max);
        require(game.VRF_CALLBACK_GAS() == 200_000, "probe gas != VRF_CALLBACK_GAS");

        // Mode 3. If the wrapper address were address(0) this would revert at creation, which is the
        // designed behaviour on a chain with no oracle — so reaching the next line already proves
        // the contract believes it has one.
        uint256 id = game.createGame(
            address(tok), 100_000 ether, 100 ether, 10_000, 100, 0, 3600, 0,
            [uint16(3), 0, 0, 0]
        );

        uint256 victim = game.placeBet(id, 1_000 ether);
        uint256 target = _target(game, id, victim);
        uint256 i;
        while (game.accumulatedOf(id, victim) < target && i < 60) {
            game.placeBet(id, 5_000 ether);
            i++;
        }
        require(game.accumulatedOf(id, victim) >= target, "the victim never matured");

        uint256 threshold = game.maturityThresholdOf(id, victim);
        uint256 saviour;
        for (uint256 j = victim + 1; j < game.betCountOf(id); j++) {
            if (_cumAtJoin(game, id, j) >= threshold) { saviour = j; break; }
        }
        require(saviour != 0, "no saviour found");

        // ── The moment of truth. Real wrapper, real fee, real request. ──
        uint256 fee = IVRFV2PlusWrapper(wrapper).calculateRequestPriceNative(200_000, 1);
        game.reserveRoiWithSalvation{value: fee}(id, victim, saviour);

        vm.stopBroadcast();

        uint256 salvationId = game.salvationCount();
        // ⚠️ POSITIONAL, so it breaks silently-ish when PendingSalvation gains a field — baseAtOpen
        // was inserted after openedAt on 2026-08-16 and this line stopped compiling. Compiling is the
        // good outcome; the dangerous version of this edit is one that still compiles and reads
        // armedAt out of the wrong slot, which would turn the assert below into a coin flip.
        (, , , uint256 openedAt, , uint256 armedAt, bool resolved) = game.salvations(salvationId);

        console.log("salvation id       :", salvationId);
        console.log("openedAt           :", openedAt);
        console.log("armedAt            :", armedAt);
        console.log("resolved           :", resolved);
        console.log("pending on game    :", game.salvationsPendingOf(id));

        // ⭐ THE ASSERTION THIS WHOLE SCRIPT EXISTS FOR.
        require(
            armedAt != 0,
            "THE REAL WRAPPER REJECTED THE REQUEST. armedAt == 0 means _openSalvation's try/catch "
            "swallowed a revert and emitted SalvationRequestFailed. Insanity would fall back to the "
            "fixed rate on mainnet and nothing would look broken. Check the wrapper address, the "
            "extraArgs native-payment encoding, the callback gas and the confirmations."
        );

        console.log("");
        console.log("PASS - the real Chainlink VRF v2.5 wrapper ACCEPTED the request.");
        console.log("       fee, extraArgs (native payment), callback gas and confirmations are all");
        console.log("       acceptable to the deployed wrapper. Fulfilment is Chainlink's side and");
        console.log("       does not happen on a private fork; the stall path covers that.");
    }

    function _target(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 t) { (,, t,,,,,,) = g.bets(id, b); }
    function _cumAtJoin(CrazyGame g, uint256 id, uint256 b) internal view returns (uint256 c) { (,,,, c,,,,) = g.bets(id, b); }
}

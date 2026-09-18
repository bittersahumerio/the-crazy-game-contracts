// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrazyGame} from "../contracts/CrazyGame.sol";

interface IAntiSnipeToken { function antiSnipeDeadline() external view returns (uint256); }

/**
 * ⛔⛔ THE PAD IS THE RISK, NOT OUR CONTRACT. Our game contract is the one already running on BNB;
 *    what is unknown on Arc is the launchpad we would depend on. This file interrogates the REAL
 *    deployed TOLLY on a fork of Arc mainnet, because reading their source only tells you what they
 *    meant, and a launch is not a thing you get to retry.
 *
 * ⭐ AND IT COSTS NOTHING. USDC *is* Arc's native gas asset, so a forked account is funded in the
 *    only currency the pad accepts. No bridge, no purchase, no waiting for the 16th.
 *
 * Run:  ARC_RPC=https://rpc.arc-scan.org forge test --match-path test/ArcTollyFork.t.sol -vv
 * Skipped automatically when ARC_RPC is unset, so the offline suite stays offline.
 *
 * The four questions, in the order that would kill the integration soonest:
 *   1. Can the coin's fee share be pointed at an address WE choose? (our whole bot economy)
 *   2. Can we know the token's address BEFORE launching? (the metadata and the bot are baked in)
 *   3. Does the token tax or block transfers? (the game contract moves the entire pot)
 *   4. ⛔ Does the anti-snipe max-wallet REVERT our game deposit? (this one strands a paid coin)
 */
interface ITollyPad {
    struct TokenMeta { string imageURI; string website; string twitter; string telegram; }
    function createToken(
        string calldata name,
        string calldata symbol,
        TokenMeta calldata meta,
        bytes32 salt,
        uint256 devBuyQuote
    ) external returns (address token);
    function quote() external view returns (address);
    function antiSnipeSeconds() external view returns (uint256);
    function MAX_WALLET() external view returns (uint256);
    function TOTAL_SUPPLY() external view returns (uint256);
    function tokens(address token) external view returns (address creator, address pool, uint256 lpTokenId);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// Their router wraps Arc's shared SwapRouter02 and adds a 0.2% toll — which `tollFor` waives
/// entirely for tokens the pad itself launched, so our own coins trade toll-free either way.
interface ITollyRouter { function SWAP_ROUTER() external view returns (address); }

interface ITollyLocker {
    function setPayout(address to) external;
    function payoutOf(address creator) external view returns (address);
}

/// Stands in for Arc's blocklist precompile, which REVM does not implement. Answers false to
/// anything asked of it: "this address is not blocklisted".
contract NotBlocklisted {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(false);
    }
}

interface IVmDeal { function deal(address who, uint256 newBalance) external; }

/// Stands in for Arc's NATIVE TRANSFER precompile — the one USDC's ERC-20 layer delegates the actual
/// value movement to, after scaling 6 decimals up to the 18-decimal native view.
/// ⭐ It moves real balance rather than reporting success: a stub that lied here would leave every
///    later assertion describing a chain that does not exist.
contract NativeTransferStub {
    IVmDeal constant CHEAT = IVmDeal(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function transfer(address from, address to, uint256 amount) external returns (bool) {
        // Underflows and reverts when `from` cannot cover it, which is the behaviour being emulated.
        CHEAT.deal(from, from.balance - amount);
        CHEAT.deal(to, to.balance + amount);
        return true;
    }
}

/**
 * A per-coin launcher. One transaction: create the token, point the creator fee at this coin's bot,
 * and buy the pot into as many holder addresses as the 3% cap requires.
 *
 * ⭐ PER COIN, NOT SHARED — and that is not fussiness. `payoutOf` is keyed on the CREATOR, so a
 *    launcher reused across coins would force every coin's fees to one destination. One launcher per
 *    coin means one creator per coin, which is what lets each coin fund its own bot.
 * ⚠️ The router sends each purchase DIRECTLY to its holder (`recipient`), so this contract never
 *    holds more than its own dev buy and never trips the cap itself.
 */
contract PerCoinLauncher {
    function launchAndAccumulate(
        ITollyPad pad,
        ISwapRouter02 router,
        IERC20 usdcToken,
        ITollyLocker locker,
        address coinBot,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        uint256 devBuyQuote,
        uint256 chunkQuote,
        address[] calldata holders
    ) external returns (address token) {
        usdcToken.approve(address(pad), devBuyQuote);
        token = pad.createToken(
            name, symbol,
            ITollyPad.TokenMeta({imageURI: "ipfs://x", website: "https://thecrazygame.fun", twitter: "", telegram: ""}),
            salt, devBuyQuote
        );
        // The creator is THIS contract, so this is the call that binds the coin's fees to its bot.
        locker.setPayout(coinBot);

        usdcToken.approve(address(router), chunkQuote * holders.length);
        for (uint256 i; i < holders.length; i++) {
            router.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(usdcToken),
                    tokenOut: token,
                    fee: 10_000,
                    recipient: holders[i],      // straight to the holder: we never hold it ourselves
                    amountIn: chunkQuote,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    receive() external payable {}
}

contract ArcTollyForkTest is Test {
    /// Arc's blocklist precompile. Real on mainnet, absent in every simulator.
    address constant BLOCKLIST = 0x1800000000000000000000000000000000000001;
    /// Arc's native-transfer precompile, which USDC's ERC-20 layer calls to move the money.
    address constant NATIVE_TRANSFER = 0x1800000000000000000000000000000000000000;
    ITollyPad constant PAD = ITollyPad(0xCAD7ee36Ac193BF2Eddb7B3E2736C5bdB8269C8B);
    ITollyLocker constant LOCKER = ITollyLocker(0xE20E4297759597Da75c8998EE76Ec900600aD920);

    address creator = makeAddr("creator");
    address coinBot = makeAddr("coinBot");     // stands in for the per-coin bot wallet
    address stranger = makeAddr("stranger");

    IERC20 usdc;
    uint256 antiSnipe;
    uint256 maxWallet;

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        // ⛔ WITHOUT THIS, NOTHING INVOLVING USDC RUNS. Arc's USDC calls isBlocklisted() on every
        //    transfer; on a fork that address has no code and the whole transfer reverts with
        //    OpcodeNotFound. Etching a stub is what makes local Arc testing possible at all.
        vm.etch(BLOCKLIST, address(new NotBlocklisted()).code);
        vm.etch(NATIVE_TRANSFER, address(new NativeTransferStub()).code);
        // An etched contract needs explicit permission before it may call cheatcodes.
        vm.allowCheatcodes(NATIVE_TRANSFER);

        usdc = IERC20(PAD.quote());
        antiSnipe = PAD.antiSnipeSeconds();
        maxWallet = PAD.MAX_WALLET();
    }

    modifier onlyForked() {
        // ⛔ SKIPPED, NOT PASSED. Without a fork these assert nothing, and a green tick that means
        //    "did not run" is the most expensive kind of green there is.
        if (!forked) { vm.skip(true); }
        _;
    }

    /// ⭐ THE FUNDING QUESTION, FIRST. On Arc the native balance and USDC.balanceOf are one asset at
    /// two precisions (18 vs 6 decimals). If that holds on a fork, `vm.deal` funds a test account in
    /// USDC and the entire "we need to buy USDC to test" problem disappears.
    function test_nativeBalanceIsUsdcBalance() public onlyForked {
        vm.deal(creator, 5_000 ether);
        uint256 erc20 = usdc.balanceOf(creator);
        emit log_named_uint("native (18dp)", creator.balance);
        emit log_named_uint("usdc.balanceOf (6dp)", erc20);
        assertEq(erc20, creator.balance / 1e12, "one asset, two decimal views: 10^12 apart");
    }

    function _launch(string memory name, string memory symbol, uint256 devBuyQuote)
        internal
        returns (address token)
    {
        vm.deal(creator, 5_000 ether);
        vm.startPrank(creator);
        if (devBuyQuote > 0) usdc.approve(address(PAD), devBuyQuote);
        token = PAD.createToken(
            name, symbol,
            ITollyPad.TokenMeta({
                imageURI: "ipfs://placeholder",
                website: "https://thecrazygame.fun",
                twitter: "",
                telegram: ""
            }),
            keccak256(abi.encodePacked(name, block.timestamp)),
            devBuyQuote
        );
        vm.stopPrank();
    }

    /// A launch that reaches the chain at all, plus the shape of what comes back.
    function test_aLaunchSucceedsAndTheDevBuyLands() public onlyForked {
        address token = _launch("Crazy Fork", "CFORK", 25e6);   // 25 USDC, 6 decimals
        assertTrue(token != address(0), "no token address returned");

        (address who, address pool,) = PAD.tokens(token);
        assertEq(who, creator, "the CREATOR is msg.sender - which is why our bot must be the launcher");
        assertTrue(pool != address(0), "a launch must leave a pool behind");

        uint256 got = IERC20(token).balanceOf(creator);
        emit log_named_uint("dev buy tokens", got);
        assertGt(got, 0, "25 USDC of dev buy must land tokens on the launcher");
    }

    /// ⛔ QUESTION 1 — THE ONE THAT DECIDES EVERYTHING. Our model is one coin, one bot wallet, and
    /// the coin's trading fees must fund THAT bot. TOLLY keys the payout on the CREATOR, and there
    /// is no owner on the locker to override it.
    /// ⚠️ Keyed per CREATOR, not per token: one launcher address cannot route two coins to two
    ///    different bots. That is the finding, and it forces the Solana shape — the coin's own bot
    ///    is the launcher.
    function test_theCreatorCanPointFeesAtOurBot_andNobodyCanOverrideIt() public onlyForked {
        _launch("Crazy Fork Two", "CFORK2", 10e6);

        vm.prank(creator);
        LOCKER.setPayout(coinBot);
        assertEq(LOCKER.payoutOf(creator), coinBot, "the creator must be able to name the destination");

        // Nobody else can move it. There is no owner() on the locker at all; a stranger only ever
        // writes their OWN row.
        vm.prank(stranger);
        LOCKER.setPayout(stranger);
        assertEq(LOCKER.payoutOf(creator), coinBot, "a third party must not be able to redirect our share");
    }

    /// ⭐ THE CAP BOUNDS A STANDING BALANCE, NOT THROUGHPUT — so a wallet can pass ANY amount through
    /// itself, in one transaction, as long as it never ENDS a transfer holding more than 3%.
    /// Blocks are irrelevant: the check runs per transfer, on the recipient's balance afterwards.
    function test_theCapBoundsStandingBalanceNotThroughput() public onlyForked {
        address token = _launch("Crazy Fork Five", "CFORK5", 10e6);
        address relay = makeAddr("relay");
        // ⚠️ A FRESH SINK EACH LEG. 0xdEaD is not address(0), so it is checked like any other
        //    recipient - my first version failed here, on the SINK, not on the relay.

        uint256 chunk = maxWallet - 1e18;        // just under the cap, three times over
        uint256 moved;
        for (uint256 i; i < 3; i++) {
            deal(token, relay, 0);               // relay starts each leg empty
            deal(token, creator, chunk);
            vm.prank(creator);
            IERC20(token).transfer(relay, chunk);          // lands: relay ends under the cap
            assertLe(IERC20(token).balanceOf(relay), maxWallet, "never ENDS a transfer over the cap");
            vm.prank(relay);
            IERC20(token).transfer(makeAddr(string(abi.encodePacked("sink", i))), chunk);  // straight out
            moved += chunk;
        }
        assertGt(moved, maxWallet * 2, "far more than the cap passed through one address in one test");
    }

    /// ⛔⛔ AND THE TURNAROUND DOES NOT SAVE US, WHICH IS THE POINT. Our pot is a STANDING balance in
    /// the game contract, so the transfer that pushes it past 3% reverts — and no number of wallets
    /// helps, because the deposit has to arrive in ONE contract. The options are therefore: keep the
    /// pot under 3% of supply, or wait out the 300-second window before createGame.
    function test_aPotOverThreePercentIsRefusedUntilTheWindowPasses() public onlyForked {
        address token = _launch("Crazy Fork Six", "CFORK6", 10e6);
        address pot = makeAddr("gameContract");   // stands in for CrazyGame holding the pot

        uint256 half = (maxWallet * 2) / 3;       // two of these exceed the cap
        deal(token, creator, half * 2);

        vm.prank(creator);
        IERC20(token).transfer(pot, half);        // first half lands
        assertEq(IERC20(token).balanceOf(pot), half);

        vm.prank(creator);
        vm.expectRevert();                        // the second pushes it over: MaxWalletExceeded
        IERC20(token).transfer(pot, half);

        // The fix that needs no product change: wait out the window.
        vm.warp(block.timestamp + antiSnipe + 1);
        vm.prank(creator);
        IERC20(token).transfer(pot, half);
        assertEq(IERC20(token).balanceOf(pot), half * 2, "after 300s the pot can be any size");
    }

    /// ⛔ CAN THE LAUNCH SIMPLY BUY MORE? The dev buy's tokens land on the CREATOR inside
    /// createToken, and the creator is not exempt — so the cap is enforced on the launch itself.
    /// This is what decides whether a "buy more at launch" path exists at all.
    function test_aDevBuyOverTheCapIsRefusedByTheLaunchItself() public onlyForked {
        vm.deal(creator, 5_000 ether);
        vm.startPrank(creator);
        usdc.approve(address(PAD), 400e6);
        // 25 USDC bought 0.49% of supply, so 400 USDC aims well past the 3% cap.
        try PAD.createToken(
            "Crazy Fork Big", "CFBIG",
            ITollyPad.TokenMeta({imageURI: "ipfs://x", website: "", twitter: "", telegram: ""}),
            keccak256("big"), 400e6
        ) returns (address token) {
            uint256 got = IERC20(token).balanceOf(creator);
            emit log_named_uint("400 USDC dev buy landed", got);
            emit log_named_uint("as a share of maxWallet (x100)", (got * 100) / maxWallet);
            assertLe(got, maxWallet, "if a big dev buy succeeds it must still be under the cap");
        } catch {
            emit log("400 USDC dev buy REVERTED - the cap binds the launch transaction itself");
        }
        vm.stopPrank();
    }

    /// ⛔⛔ AND THE ONE THAT CORRECTS THE ADVICE: BETS ACCUMULATE AGAINST THE SAME CAP. A game that
    /// opens inside the window with a modest pot still dies later, when the bet that pushes the
    /// contract past 3% reverts - which would present as a random failure to a player, minutes in.
    /// ⇒ The safe rule is not "keep the pot small", it is "do not open the game inside the window".
    function test_betsIntoAnOpenGameHitTheCapToo() public onlyForked {
        address token = _launch("Crazy Fork Seven", "CFORK7", 10e6);
        address pot = makeAddr("gameContract2");

        uint256 start = maxWallet / 2;           // a modest pot: 1.5% of supply
        deal(token, creator, start);
        vm.prank(creator);
        IERC20(token).transfer(pot, start);

        // Players bet in. Each bet is a transfer INTO the same contract.
        address player = makeAddr("player");
        uint256 bet = maxWallet / 8;
        uint256 placed;
        for (uint256 i; i < 8; i++) {
            deal(token, player, bet);
            vm.prank(player);
            try IERC20(token).transfer(pot, bet) { placed++; }
            catch { break; }
        }
        emit log_named_uint("bets that landed before the cap bit", placed);
        assertLt(placed, 8, "the cap must stop bets once the pot passes 3% inside the window");
        assertLe(IERC20(token).balanceOf(pot), maxWallet);
    }

    /// ⭐ THE PRICE OF SIZE, MEASURED. Chunk 1 is the dev buy, which is atomic with the launch and
    /// therefore unbeatable — the token does not exist until that transaction. Every later chunk
    /// walks up the same 1% V3 position, and this is how fast it walks.
    /// ⚠️ ON A FORK WE ARE THE ONLY TRADER. This measures OUR OWN size impact and nothing else; real
    ///    snipers in those 300 seconds are additional, and unknowable from here.
    function test_whatStackingSizeCosts() public onlyForked {
        address token = _launch("Crazy Fork Slip", "CSLIP", 25e6);
        address router = ITollyRouter(0xceBC2e409A85CFA82B086674e6bc5bEd51692777).SWAP_ROUTER();
        emit log_named_address("SwapRouter02", router);

        uint256 first = IERC20(token).balanceOf(creator);
        emit log_named_uint("chunk 1  (dev buy, atomic)", first / 1e18);

        uint256 total = first;
        for (uint256 i = 2; i <= 6; i++) {
            address holder = makeAddr(string(abi.encodePacked("holder", i)));
            vm.deal(holder, 1_000 ether);
            vm.startPrank(holder);
            usdc.approve(router, 25e6);
            uint256 out = ISwapRouter02(router).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: token,
                    fee: 10_000,             // TOLLY launches into the 1% tier
                    recipient: holder,
                    amountIn: 25e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            vm.stopPrank();
            total += out;
            emit log_named_uint("chunk N tokens", out / 1e18);
            emit log_named_uint("  ... % of chunk 1", (out * 100) / first);
        }
        emit log_named_uint("total tokens for 150 USDC", total / 1e18);
        emit log_named_uint("total as % of supply (x100)", (total * 10_000) / PAD.TOTAL_SUPPLY());
        emit log_named_uint("vs 6x the first chunk (%)", (total * 100) / (first * 6));
        assertGt(total, 0);
    }

    /// ⭐⭐ THE ANSWER TO "HOW DO WE BUY MORE THAN 3%": one transaction, several recipients.
    /// Nothing can front-run it, because the token does not exist until this transaction runs — so
    /// the whole pot is bought at launch prices no matter how big it is.
    function test_aLauncherContractBuysPastTheCapInOneTransaction() public onlyForked {
        PerCoinLauncher launcher = new PerCoinLauncher();
        vm.deal(address(launcher), 5_000 ether);      // native IS usdc on Arc

        address[] memory holders = new address[](4);
        for (uint256 i; i < 4; i++) holders[i] = makeAddr(string(abi.encodePacked("hold", i)));

        address token = launcher.launchAndAccumulate(
            PAD, ISwapRouter02(ITollyRouter(0xceBC2e409A85CFA82B086674e6bc5bEd51692777).SWAP_ROUTER()),
            usdc, LOCKER, coinBot,
            "Crazy Fork Big Pot", "CBIG", keccak256("bigpot"),
            120e6,        // dev buy: under the 3% cap that binds this contract
            120e6,        // and four more chunks, each landing on its own holder
            holders
        );

        uint256 total = IERC20(token).balanceOf(address(launcher));
        for (uint256 i; i < 4; i++) {
            uint256 h = IERC20(token).balanceOf(holders[i]);
            assertGt(h, 0, "every holder must have been filled");
            assertLe(h, maxWallet, "and each must stay under the cap");
            total += h;
        }

        emit log_named_uint("acquired in ONE tx (% of supply x100)", (total * 10_000) / PAD.TOTAL_SUPPLY());
        assertGt(total, maxWallet, "the whole point: more than 3% of supply, in one transaction");

        // And the coin's fees are already bound to its own bot, by the same transaction.
        assertEq(LOCKER.payoutOf(address(launcher)), coinBot, "this coin's 64% funds this coin's bot");

        // After the window the holders consolidate freely — the cap is a timestamp check, not a rule.
        vm.warp(block.timestamp + antiSnipe + 1);
        address pot = makeAddr("gamePot");
        for (uint256 i; i < 4; i++) {
            // ⚠️ Read the balance BEFORE the prank: vm.prank applies to the next CALL, and a
            //    balanceOf inside the argument list would consume it, sending as the test contract.
            uint256 bal = IERC20(token).balanceOf(holders[i]);
            vm.prank(holders[i]);
            IERC20(token).transfer(pot, bal);
        }
        assertGt(IERC20(token).balanceOf(pot), maxWallet, "the pot consolidates past 3% once the window closes");
    }

    /// ⭐ THE EXACT CALL THE BOT'S V3 LEG BUILDS: exactInputSingle, 1% tier, 6-decimal amountIn,
    /// recipient set. If the fee tier were read as basis points, or the decimals crossed the wrong
    /// way, this is where it shows up — as a revert or as an absurd amount, rather than in
    /// production.
    function test_theRouterAcceptsTheCallShapeTheBotBuilds() public onlyForked {
        address token = _launch("Crazy Fork Shape", "CSHAPE", 10e6);
        address router = ITollyRouter(0xceBC2e409A85CFA82B086674e6bc5bEd51692777).SWAP_ROUTER();
        address buyer = makeAddr("shapeBuyer");
        vm.deal(buyer, 100 ether);

        uint256 spend = 10_000;                    // 0.01 USDC in the ERC-20's 6 decimals
        vm.startPrank(buyer);
        usdc.approve(router, spend);
        uint256 out = ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: token,
                fee: 10_000,                       // Uniswap units: the 1% tier
                recipient: buyer,
                amountIn: spend,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        emit log_named_uint("0.01 USDC bought (raw, 18dp)", out);
        assertGt(out, 0, "the router must accept this shape");
        assertEq(IERC20(token).balanceOf(buyer), out, "and deliver to the recipient we named");
        // An 18-decimal token bought with 6-decimal USDC: a decimals slip either way would land
        // this outside any sane band by a factor of 1e12.
        assertGt(out, 1e18, "a cent should buy more than one whole token on a fresh curve");
        assertLt(out, 1e27, "and nowhere near the entire supply");
    }

    /// ⛔ QUESTION 3 — no tax. The game contract moves the whole pot; a fee-on-transfer token would
    /// change every number the contract accounts for.
    function test_theTokenTakesNoCutOfATransfer() public onlyForked {
        address token = _launch("Crazy Fork Three", "CFORK3", 25e6);
        uint256 held = IERC20(token).balanceOf(creator);
        uint256 send = held / 4;

        vm.prank(creator);
        IERC20(token).transfer(stranger, send);
        assertEq(IERC20(token).balanceOf(stranger), send, "exactly what was sent must arrive: no transfer tax");
    }

    /// ⛔⛔ QUESTION 4 — THE ONE THAT STRANDS A PAID-FOR COIN. For `antiSnipeSeconds` after launch,
    /// no non-exempt address may END a transfer holding more than 3% of supply. Our flow hands the
    /// ENTIRE dev buy to the game contract as the pot, in the minutes after launch — and the game
    /// contract is not on anyone's exempt list.
    /// ⇒ Either the deposit stays under 3% of supply, or createGame waits out the window. This test
    ///   exists to prove which, on the real token, rather than reasoning about it.
    function test_theAntiSnipeWindowBoundsWhatOurGameContractCanHold() public onlyForked {
        address token = _launch("Crazy Fork Four", "CFORK4", 25e6);
        emit log_named_uint("antiSnipeSeconds", antiSnipe);
        emit log_named_uint("maxWallet (3% of supply)", maxWallet);

        // ⭐ WHAT THE DEV BUY ACTUALLY BOUGHT, measured against the cap — this is the number our
        //    launch flow has to stay under, because the game contract receives the whole pot.
        uint256 bought = IERC20(token).balanceOf(creator);
        emit log_named_uint("dev buy tokens for 25 USDC", bought);
        emit log_named_uint("cap headroom (maxWallet/bought)", maxWallet / bought);
        assertLt(bought, maxWallet, "a 25 USDC dev buy must not itself breach the anti-snipe cap");

        // ⚠️ The pad keeps only dust after a launch (the supply is all in the LP position), so the
        //    over-cap balance is set directly. The TRANSFER is still real, which is what matters:
        //    the token's _update hook is the thing under test.
        uint256 over = maxWallet + 1e18;
        deal(token, creator, over);

        vm.startPrank(creator);
        vm.expectRevert();                            // MaxWalletExceeded
        IERC20(token).transfer(stranger, over);
        vm.stopPrank();

        // After the window it is a plain ERC-20 again.
        vm.warp(block.timestamp + antiSnipe + 1);
        vm.prank(creator);
        IERC20(token).transfer(stranger, over);
        assertEq(IERC20(token).balanceOf(stranger), over, "past the deadline the cap is a no-op");
    }

    /// ⭐⭐ THE OPENING DELAY, ON THE REAL COIN (2026-09-16). The new CrazyGame, deployed on this fork with
    ///    Arc's arguments, asks the coin for its antiSnipeDeadline() inside a 30,000-gas cap. This proves
    ///    the real TOLLY token answers within it: a game created the moment after launch waits out the
    ///    window by itself, refuses a bet before its opening and takes one after — while a USDC game on
    ///    the same contract opens at creation.
    function test_aGameCreatedRightAfterLaunchOpensAfterTheWindow() public onlyForked {
        address[] memory curated = new address[](1);
        curated[0] = address(usdc);
        uint256[] memory fees = new uint256[](1);
        fees[0] = 300;
        CrazyGame game = new CrazyGame(
            makeAddr("treasury"), 500, address(0),
            address(0), address(0), address(0), address(usdc), address(0),
            curated, fees, address(0),
            [uint256(270000), 540000, 54000000],
            300
        );

        address token = _launch("Crazy Fork Five", "CFORK5", 25e6);
        uint256 deadline = IAntiSnipeToken(token).antiSnipeDeadline();
        emit log_named_uint("seconds of window left at creation", deadline + 1 - block.timestamp);
        assertGe(deadline, block.timestamp, "setup: the launch window must still be running");

        uint256 deposit = IERC20(token).balanceOf(creator);
        uint256 minBet = deposit / 100;
        vm.startPrank(creator);
        IERC20(token).approve(address(game), type(uint256).max);
        uint256 id = game.createGame(token, deposit, minBet, 10_000, 100, 0, 3600, 0, [uint16(1), 100, 0, 0]);
        vm.stopPrank();

        uint256 opensAt = game.opensAtOf(id);
        uint256 expected = block.timestamp + 300 > deadline ? block.timestamp + 300 : deadline + 1;
        assertEq(opensAt, expected, "the real coin's window, read inside the gas cap");
        assertGt(opensAt, deadline, "never inside the window");
        assertEq(game.timerEndOf(id), opensAt + 3600, "the timer runs from the opening");

        deal(token, stranger, minBet * 3);
        vm.startPrank(stranger);
        IERC20(token).approve(address(game), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CrazyGame.NotOpenYet.selector, opensAt));
        game.placeBet(id, minBet);
        vm.warp(opensAt);
        game.placeBet(id, minBet);
        vm.stopPrank();
        assertEq(game.betCountOf(id), 2, "the game takes bets from its opening");

        // The chain's own coin has no launch window: a USDC game opens at creation.
        address usdcHost = makeAddr("usdcHost");
        vm.deal(usdcHost, 100 ether);
        vm.startPrank(usdcHost);
        usdc.approve(address(game), type(uint256).max);
        uint256 plain = game.createGame(address(usdc), 10e6, 270000, 10_000, 100, 0, 3600, 0, [uint16(0), 0, 0, 0]);
        vm.stopPrank();
        assertEq(game.opensAtOf(plain), 0, "a USDC game opens at creation");
    }
}

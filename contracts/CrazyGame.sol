// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
/**
 * The two Chainlink VRF v2.5 wrapper calls we make, and nothing else.
 *
 * Signatures verified against smartcontractkit/chainlink-brownie-contracts
 * (contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol), not reconstructed from docs.
 *
 * ⚠️ We deliberately do NOT inherit VRFV2PlusWrapperConsumerBase. Its constructor calls
 * `wrapper.link()`, which (a) would revert for a zero address and so destroy our "no oracle on this
 * chain" sentinel, and (b) drags in a LINK token dependency we never use — we pay in native only.
 */
interface IVRFV2PlusWrapper {
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords)
        external view returns (uint256);
    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);
}

/**
 * CrazyGame — the EVM version of the Solana last-bettor-wins game.
 *
 * Ported from crazy_game-v14 (Anchor).  The economic model is deliberately IDENTICAL — the same
 * cumulative-per-bet accumulator, the same ROI target, the same reserved/jackpot split — because
 * that maths is live, understood, and its invariants are what keep the contract solvent.  What
 * changes is everything the account model forced on Solana.
 *
 * ─── WHAT THE EVM DELETES ────────────────────────────────────────────────────────────────────
 *  • THE CRANK.  On Solana `place_bet` must be read-only on `game` so two simultaneous bets do not
 *    contend on the same account, which forced a two-step queue → `process_bet` design, an escrow
 *    account per bet, an `is_pending` flag, and an operator to run it.  A wedged pending bet is the
 *    exact failure that cost 5 SOL.  On the EVM a transaction already holds exclusive state access
 *    for its block, so bets are atomic: no queue, no escrow, no pending flag, no operator.
 *  • PER-BET ACCOUNTS + RENT.  Bets are struct entries in a mapping.  No rent, no ATAs, no
 *    `close_bet` sweep to reclaim it, no 890,880-lamport minimums.
 *  • THE SEPARATE FUND STEP.  `initialize_game` + `fund_game` collapse into one call, so a game can
 *    never exist unfunded — a state that needed a `funded` flag to defend against.
 *
 * ─── WHAT THE EVM ADDS, THAT SOLANA DID NOT HAVE ─────────────────────────────────────────────
 *  • FEE-ON-TRANSFER TOKENS.  Every amount here is MEASURED from the balance delta, never assumed
 *    from the argument.  ⚠️ NOTE, because the obvious reason is the WRONG one: four.meme's tax
 *    tokens charge on BUYS AND SELLS ONLY — transactions involving the liquidity pair — so a plain
 *    transfer into this contract is NOT taxed by them.  The reason to measure is that the game
 *    accepts ARBITRARY tokens, and a great many BSC tokens do tax every transfer.  Measuring costs
 *    one extra balanceOf and is a no-op when there is no tax; assuming would silently over-credit
 *    the bet and leave the pool promising more than it holds.
 *  • REENTRANCY.  Solana has no fallback functions; the EVM does, and a malicious token can call
 *    back into us mid-transfer.  Guarded, and state is written before any external call.
 *
 * SALVADOR: ALL THREE MODES ARE PORTED.  1 (fixed) and 2 (progressive) are deterministic.  3
 * (INSANITY) is VRF-driven and runs on Pyth Entropy — see the SALVADOR MODE 3 section below.
 * Insanity is the product's headline feature, so a BNB launch without it was never on the table.
 * NOT PORTED (deliberate):  referrals, the points/Seeds ledger (off-chain on Solana anyway), and
 * multi-token onboarding config.  ⚠️ The ledger being off-chain is exactly why GameCreated and
 * BetPlaced emit gross amounts AND every fee explicitly — those events ARE the ledger's input, so
 * they are interface, not diagnostics.  Do not slim them down.
 *
 * ─── SALVADOR MODE 3 (INSANITY) ──────────────────────────────────────────────────────────────
 * The bounty RATE is drawn from a fixed table rather than set by the host.  The table and its EV
 * are copied from crazy_game-v14 exactly:
 *      50.0% -> 0.2%      30.0% -> 0.5%      15.0% -> 1.5%      4.9% -> 10%      0.1% -> 50%
 * EV = 101.5 bps, which is why the stall fallback pays 100 bps: a stalled oracle costs a saviour
 * essentially nothing in expectation, so nobody has an incentive to stall one.
 *
 * ⚠️ WHY ORAO'S FAILURE CANNOT RECUR HERE.  On Solana the request was made wallet-direct by the
 * indexer, and ORAO only ever fulfils requests that originate as a CPI from a client PROGRAM — so
 * ours sat unfulfilled and the fixed-% fallback silently carried the entire feature for months.
 * The wrapper here only ever calls back into a contract, so there is no wallet-direct mode to get
 * wrong — but note that the ORAO lesson is really about ASSUMPTIONS ABOUT THE ORACLE going
 * unchecked, and this contract has now been bitten by that twice (see below).
 *
 * ─── WHY CHAINLINK VRF AND NOT PYTH ENTROPY ──────────────────────────────────────────────────
 * This was written against Pyth Entropy first.  Then, in review, Pyth's own deployment list turned
 * out NOT to include BNB Smart Chain — 24 mainnets, no BSC.  No Entropy address was configured
 * anywhere in the repo and every test ran against a mock, so nothing could have surfaced it before
 * deployment: exactly the ORAO shape again, an unchecked assumption about an oracle's availability.
 * Chainlink VRF v2.5 IS on BSC, so the oracle was swapped and the whole salvation state machine
 * below — pending record, armed timer, fallback window, emergency window — is UNCHANGED, because
 * it was written oracle-shaped rather than Pyth-shaped.
 *
 * We use DIRECT FUNDING paid in NATIVE currency, so the caller who triggers a salvation pays for
 * that request out of their own msg.value.  Deliberately not a subscription: a pre-funded balance
 * is one more thing that must be kept alive off-chain, and a subscription running dry would stall
 * salvations silently — the failure mode this contract exists to avoid.
 *
 * THREE LIVENESS RULES, ported from v13 because each one exists for a reason:
 *  • The matured bet is reserved IMMEDIATELY.  Only the bounty rate waits on the oracle — a bet's
 *    own ROI must never depend on a third party being up.
 *  • The fallback timer is armed at REQUEST time, so a caller can DELAY a request but can never
 *    force the cheap fixed rate early by sitting on it.
 *  • Both oracle calls are wrapped in try/catch.  If Entropy is unreachable the salvation is still
 *    RECORDED and clears through the emergency window, so a dead oracle delays a bounty rather than
 *    freezing the game — the EVM equivalent of v13's un-armable-CPI escape hatch.
 */
/**
 * flap.sh's Portal. VERIFIED ON BSC MAINNET 2026-08-29 (selector 0x5c4bc504).
 *
 * The struct is EXACT and the field order matters: it is returned as a static tuple, one word per
 * field, and we read status/price/quoteTokenAddress by name rather than by index.
 *
 * @dev status and tokenVersion are uint8, NOT enums, ON PURPOSE. A real token returned
 *      tokenVersion = 5 while flap documents only four values, and decoding an out-of-range value
 *      into an enum REVERTS. Reading them as uint8 cannot.
 * @dev getTokenV5 REVERTS (0xde6137d1) for any token flap has never seen - CAKE, USDT and a garbage
 *      address all confirmed. Every call site must be try/catch or the whole of createGame breaks
 *      for ordinary BEP20s.
 */
struct TokenStateV5 {
    uint8   status;                  // Invalid=0 Tradable=1 InDuel=2 Killed=3 DEX=4
    uint256 reserve;
    uint256 circulatingSupply;
    uint256 price;                   // quote per token, 18dp. ZERO once migrated.
    uint8   tokenVersion;
    uint256 r;
    uint256 h;
    uint256 k;
    uint256 dexSupplyThresh;
    address quoteTokenAddress;       // 0 = native. NOT always the wrapped native token.
    bool    nativeToQuoteSwapEnabled;
    bytes32 extensionID;
}

interface IFlapPortal {
    function getTokenV5(address token) external view returns (TokenStateV5 memory);
}

/**
 * A registry of coins that pay LESS than the default platform fee.
 *
 * ⛔ IT CANNOT RAISE A FEE, TOUCH MONEY, OR REACH A GAME THAT ALREADY EXISTS. CrazyGame clamps
 *    whatever this returns to [MIN_FEE_BPS, platformFeeBps] and snapshots the result into the game
 *    at creation. That clamp is the whole reason the tiers live out here instead of putting an
 *    owner on this contract: the worst a compromised registry can do is hand somebody a discount
 *    on a new game.
 */
interface IFeeTiers {
    function feeFor(address token) external view returns (uint256);
}

interface IUniV2Factory {
    function getPair(address a, address b) external view returns (address);
}

interface IUniV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory);
}

/// WETH9's deposit half, and only that half. Unwrapping is NOT here and is not an oversight: it
/// happens in the client, where a failure costs the person who asked for it and nobody else.
interface IWrappedNative {
    function deposit() external payable;
}

contract CrazyGame is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Config ──────────────────────────────────────────────────────────────────────────────
    uint256 public constant BPS = 10_000;
    /// Mirrors the Solana rule: (deposit/minBet) * roiBps must clear this, so a game cannot be set
    /// up to be farmed by its own host. Verified against the live formula, not re-derived.
    uint256 public constant ANTI_FARM_MIN = 50_000;
    /// Gap between the timer expiring and the jackpot becoming claimable. Mirrors the 300s on Solana:
    /// it gives a late-but-valid bet time to land before the pot is swept.
    uint256 public constant JACKPOT_DELAY = 300;

    /// 🩸 INSANITY_MIN_POOL_RATIO = 50 WAS HERE AND IS DELETED. Decided 2026-08-28, carried out
    /// only now. It guarded a state that cannot occur: a salvation cannot fire until a bet has
    /// accrued its whole ROI target, and the accumulator advances by netAmount/activeBetCount per
    /// bet — so by the time ANY roll is possible, many bets have landed and the pot is not thin.
    /// The thin pool and the 50% band cannot coexist. What it did reach was the host who chose it,
    /// spending their own money on a game nobody else had entered: taste enforced as safety.
    ///
    /// ⚠️ It also SCALED WITH THE MIN BET, which is the opposite of what a floor should do. Solana
    /// gates mode 3 on one absolute (`initial_deposit >= random_min_pool`, lib.rs:450), so a 0.1 SOL
    /// min bet still needs only a 0.5 SOL deposit. This demanded FIFTY TIMES whatever minimum you
    /// picked — 5 SOL for the same game. Choosing a larger minimum was punished for it.
    ///
    /// ⚠️ And its last living use was the one it suited least. The wrapper was unpriceable, so a
    /// game in the chain's OWN COIN fell through to this ratio and needed 0.05 BNB where the
    /// absolute asks 0.04. Step 0 of _quoteNativeToToken is what makes deleting this safe.

    /// 🩸 MAX_DEPOSIT_TO_MIN_BET = 1_000 WAS HERE AND IS DELETED, not merely unenforced. Leaving a
    /// public constant that no longer bounds anything is how this file has repeatedly ended up with
    /// comments asserting protections that were removed. It had no derivation — "generous", no
    /// source, unlike every other constant here — and the guard that actually stops the accumulator
    /// freeze lives in _placeBet: `if (netAmount < g.activeBetCount) revert BelowMinBet();`

    /// ─── REAL-MONEY FLOORS, denominated in the NATIVE asset ───────────────────────────────────
    /// WHY THESE EXIST, because it is not what it looks like: a game with dust bets does not merely
    /// annoy its own players, it shifts cost ONTO THE OPERATOR. Our reserver wallet pays the gas for
    /// every reserveRoi and the Chainlink VRF fee for every salvation, whatever the pot is worth.
    /// That is an involuntary loss to a party that did not opt in - the same category as farming,
    /// and the reason this belongs on chain rather than in a form.
    ///
    /// Denominated in the native asset DELIBERATELY: gas is priced in gwei, so what a transaction
    /// costs in BNB does not move when BNB's price does. A dollar figure would drift for a reason
    /// that has nothing to do with the economics. Same argument as Solana denominating in SOL.
    ///
    /// minBet = 10x a placeBet fee (20x for Insanity, whose salvations we also pay to trigger).
    /// The pool floor is where the expected bounty (101.5 bps) covers the VRF trigger cost with 3x
    /// margin: derived at 0.0377, rounded UP to 0.04, which only widens the margin. BSC deploys
    /// 0.0002 / 0.0004 / 0.04 — the exact numbers this file used to hardcode.
    ///
    /// ⛔⛔ THESE WERE `constant`, AND THEY WERE THE LAST THING HERE NAILED TO ONE CHAIN. Every
    ///    price source above is already a constructor argument, on the stated grounds that
    ///    "hardcoding BSC addresses would make Arc a PORT instead of a DEPLOY" — and then three BNB
    ///    quantities sat underneath them as constants. `0.0002 ether` is 14 cents of BNB, 60 cents
    ///    of ETH on Base, and on a chain whose gas asset is a stablecoin it is not a quantity of
    ///    money at all. What ports is the DERIVATION above. The numbers belong at the deploy site,
    ///    priced from that chain's own gas.
    ///
    /// ⚠⚠ DENOMINATED IN `wrappedNative`'s OWN UNITS, NOT IN NATIVE WEI — a distinction that is
    ///    invisible on BSC, where WBNB is 18dp exactly like BNB, and invisible nowhere else. It has
    ///    to be the ERC-20's units because that is what every consumer of these numbers expects:
    ///    _quoteViaDex hands the figure straight to getAmountsOut as an amount of `path[0]`, and
    ///    path[0] IS wrappedNative. On Arc — where the gas asset and the ERC-20 are the same money
    ///    seen at 18dp and at 6dp — native wei would have entered that call as 200,000,000 USDC.
    ///    A million times the intended floor, silently, with no revert anywhere to catch it.
    uint256 public immutable MIN_BET_NATIVE;
    uint256 public immutable MIN_BET_NATIVE_INSANITY;
    uint256 public immutable INSANITY_MIN_POOL_NATIVE;

    /// ─── THE OPENING DELAY, FOR A COIN STILL INSIDE ITS LAUNCH WINDOW ─────────────────────────
    /// A game created on a coin whose launch anti-snipe window is still running opens OPEN_DELAY
    /// seconds after creation, or one second after the window closes if that is later. Every other game
    /// opens at creation, exactly as before. Until the opening the pot is in, bets revert
    /// NotOpenYet(opensAt), and the timer runs from the opening.
    ///
    /// ⭐ WHY. Arc's TOLLY launchpad caps every wallet at 3% of a coin's supply for 300 s after launch,
    ///    and this contract is a wallet. A game opened inside that window takes the host's pot and then
    ///    refuses the bets that would carry it over the cap, so a launch had to wait out the window
    ///    before its game could exist, with the host still at the page to sign. Now launch and game are
    ///    signed in one sitting and the game opens itself once the cap has lifted. Operator, 2026-09-16:
    ///    "a mandatory delay, not max", and then "we only need it on launched tokens".
    /// ⛔ MANDATORY, AND NOT THE HOST'S CALL: the coin says whether it is in a window, never an argument.
    /// ⭐ THE COIN IS ASKED, NOT A PAD REGISTRY: `antiSnipeDeadline()` is the TOLLY token's own view, and
    ///    the rule "no wallet above 3% until then" lives in the same token. A coin with no such view,
    ///    with its window closed, or answering nonsense opens at creation (see _openingFor).
    /// ⭐ A CONSTRUCTOR ARGUMENT, like the floors: Arc deploys 300. With 0 a game inside a window still
    ///    opens only after the window closes, because a game inside it cannot work.
    uint256 public immutable OPEN_DELAY;
    /// Gas a coin may use to answer antiSnipeDeadline(). A TOLLY token answers in a few thousand; the cap
    /// only stops a token that burns gas from making its own host's createGame fail.
    uint256 private constant ANTI_SNIPE_READ_GAS = 30_000;

    uint8 private constant FLAP_TRADABLE = 1;   // still on the bonding curve
    uint8 private constant FLAP_DEX      = 4;   // migrated; price is 0, quote via the DEX instead

    uint256 public constant MODE_RESET = 0;      // timer restarts from now on every bet
    uint256 public constant MODE_CUMULATIVE = 1; // timer extends by a fixed increment per bet

    // ─── Salvador mode 3 (Insanity) ───
    /// 1.0% of the unreserved pool when the oracle stalls. Deliberately ~= the random table's
    /// 101.5 bps EV, so stalling is worth nothing to anyone.
    uint16  public constant SALVADOR_FALLBACK_BPS = 100;
    /// The top band of the table below, and the ceiling a pending salvation reserves against the
    /// pool while it waits for a rate. ⚠️ MUST stay equal to the largest value _randomBps can
    /// return: if the table's top ever rises above this, concurrent salvations can overspend their
    /// shared base again — that was a CRITICAL, and this constant is the thing holding it shut.
    uint256 public constant INSANITY_MAX_BPS = 5_000;
    /// How long after a request is ARMED before the fixed fallback unlocks. Armed at request time
    /// precisely so a caller cannot force the fallback early.
    ///
    /// ⚠️ IT IS ALSO THE WINDOW WHEN NO REQUEST EVER WENT OUT, and that is deliberate. There used to
    /// be a separate SALVATION_EMERGENCY_TIMEOUT of 3600s for that case ("10x the normal window,
    /// mirroring v13") and it was backwards — see settleStalledSalvation. Do not reintroduce it: any
    /// value above SALVATION_JACKPOT_EXTRA deterministically destroys the bounty it looks like it
    /// is protecting.
    uint256 public constant SALVATION_FALLBACK_TIMEOUT = 360;   // 6 min
    /// ⭐ THE GAP IS NOW A NAMED CHOICE, NOT AN ARITHMETIC ACCIDENT. Previously this file declared
    /// 360 and 420 independently; only their ORDERING was ever justified ("longer than
    /// FALLBACK_TIMEOUT so serial clearing keeps the pot blocked"), so the 60 seconds between them —
    /// the entire window in which a stalled salvation can be settled before the jackpot becomes
    /// claimable — was whatever the subtraction happened to give. Nobody picked 60.
    /// ⚠️ It is load-bearing: the jackpot winner profits from the window lapsing, and can watch for
    /// a settler in the public mempool. Sixty seconds is preserved here to change nothing today, but
    /// it is now a number to review on purpose rather than one to discover.
    uint256 public constant SALVATION_SETTLE_WINDOW = 60;
    /// The jackpot waits this long after the last salvation activity while any salvation is in
    /// flight. Derived, so the two can never drift apart.
    uint256 public constant SALVATION_JACKPOT_EXTRA = SALVATION_FALLBACK_TIMEOUT + SALVATION_SETTLE_WINDOW;
    /// Gas handed to fulfillRandomWords. It settles the salvation: ~6 SSTOREs and two events.
    /// Sized with margin over the ~80k that costs, because the fee scales with it in cents while
    /// an out-of-gas callback would strand the salvation on the slow fallback for nothing.
    /// BSC's wrapper caps this at 2,500,000.
    uint32  public constant VRF_CALLBACK_GAS = 200_000;
    /// Chainlink's minimum. Fulfilment therefore lags a few blocks — far inside the 360s fallback.
    uint16  public constant VRF_CONFIRMATIONS = 3;
    uint32  public constant VRF_NUM_WORDS = 1;
    /// VRFV2PlusClient.EXTRA_ARGS_V1_TAG. Inlined rather than importing the library for one constant.
    bytes4  private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    address public immutable operatorTreasury;

    /// ⭐ THE DEFAULT FEE IS ALSO THE CEILING: nothing below may take a coin above it.
    ///    Solana charges PER TOKEN — 5% self-serve, 3% for the curated ones — from a config the
    ///    operator sets (`set_token_fee`, capped at 10%). This port flattened that to one number
    ///    and shipped the CURATED tier to every coin. The three fields here put the tiers back.
    uint256 public immutable platformFeeBps;

    /// The floor no tier may undercut, so a registry cannot discount a coin to nothing.
    uint256 public constant MIN_FEE_BPS = 300;

    /// Curated coins, written ONCE in the constructor. There is no setter and there never will be:
    /// this is immutable in everything but the keyword, which Solidity does not allow on a mapping.
    mapping(address => uint256) public curatedFeeBps;

    /// OPTIONAL. address(0) means no tiers at all and every coin pays the default. See IFeeTiers.
    address public immutable feeTiers;
    /// address(0) = no oracle configured on this chain, in which case mode 3 games are REFUSED at
    /// creation rather than created and then found to be unplayable.
    IVRFV2PlusWrapper public immutable vrfWrapper;

    /// ─── PRICE SOURCES. All four are CONSTRUCTOR ARGUMENTS, never hardcoded ───────────────────
    /// ⛔ CHAIN-AGNOSTIC ON PURPOSE. Hardcoding BSC addresses would make Arc a PORT instead of a
    ///    DEPLOY, and Arc is the whole point of keeping this contract portable.
    /// address(0) on any of them simply disables that step of the chain: a chain with no curve and
    /// no router prices nothing, every token is unpriceable, and the ratio gates below carry on
    /// exactly as they do today. That is a safe default, not a broken one.
    address public immutable flapPortal;
    address public immutable dexFactory;
    address public immutable dexRouter;
    address public immutable wrappedNative;

    /// ⭐ THE SAME ADDRESS AS `wrappedNative` ON A CHAIN WHERE THE GAS ASSET CAN BE WRAPPED, AND
    ///    address(0) WHERE IT CANNOT. The two are separate because they answer different questions:
    ///    `wrappedNative` is what this chain PRICES in, and this is what implements WETH9's
    ///    deposit(). Arc is the case that forces the distinction — USDC is both the gas asset and
    ///    the ERC-20 at one system address, the same money at 18dp and 6dp, so it prices everything
    ///    and there is nothing to wrap. Zero here makes a payable call fail by NAME rather than as
    ///    an opaque revert from a deposit() that does not exist.
    address public immutable nativeWrapper;

    // ─── State ───────────────────────────────────────────────────────────────────────────────
    struct Game {
        address host;
        address token;
        uint256 minBet;
        uint256 roiBps;
        uint256 hostFeeBps;
        uint256 timerMode;
        uint256 timerDuration;
        uint256 timeIncrement;
        uint256 timerEnd;
        uint256 poolBalance;      // everything the contract holds for this game
        uint256 reservedBalance;  // the slice already owed to matured bets
        uint256 cumulativePerBet; // the accumulator every bet's progress is measured against
        uint256 activeBetCount;   // bets still accumulating (excludes matured ones)
        uint256 betCount;
        address lastBettor;
        bool isActive;
        bool jackpotClaimed;
        // ─── Salvador ───
        // 0 = off, 1 = fixed %, 2 = progressive %, 3 = Insanity (random, oracle-driven).
        uint8 salvadorMode;
        uint16 salvadorBps;      // mode 1: the rate. mode 2: the STARTING rate. mode 3: unused.
        uint16 salvadorStepBps;  // mode 2 only: added per salvation
        uint16 salvadorCapBps;   // mode 2 only: ceiling
        uint256 salvadorCount;   // salvations paid so far, drives the mode-2 escalation
        // ─── Mode 3 bookkeeping ───
        uint256 salvationPendingNum;   // salvations awaiting a rate; blocks the jackpot while > 0
        uint256 salvationLastActivity; // stamped on open and on settle; anchors the jackpot block
        /// ⭐ The sum of the MAXIMUM each pending mode-3 salvation could still pay — its snapshotted
        /// base times the table's top band. jackpotOf subtracts it, which is what stops concurrent
        /// salvations from spending the same base more than once. Added on open, released on settle,
        /// and zeroed by claimJackpot (a settle after the game is over pays nothing anyway).
        uint256 pendingBountyMax;
        /// ⭐ THE FEE THIS GAME CHARGES, snapshotted at creation exactly as Solana stores
        /// `game.platform_fee_bps`. A tier that changes later must never move the economics of a
        /// game already running: its ROI target and its solvency were set against THIS number.
        uint256 platformFeeBps;
    }

    /// A salvation whose RATE is not known yet. Created when a mode-3 bounty is triggered and
    /// closed either by the Entropy callback or by the stall fallback — never both.
    struct PendingSalvation {
        uint256 gameId;
        uint256 savedBetId;     // the matured bet that triggered this
        uint256 saviourBetId;   // who gets paid
        uint256 openedAt;       // anchors the window when no request ever went out
        /// ⭐ jackpotOf at the moment the salvation was TRIGGERED, and it is snapshotted rather than
        /// re-read for two independent reasons.
        ///
        /// GAS: jackpotOf is O(betCount), and for mode 3 the rate arrives in the VRF callback, which
        /// runs under VRF_CALLBACK_GAS (200,000). Pricing there would cap a game at roughly 140 bets
        /// before the callback ran out of gas and stranded the salvation on the fallback — a
        /// self-inflicted version of the exact oracle failure this state machine exists to survive.
        /// Snapshotting moves the loop into reserveRoiWithSalvation, an ordinary transaction with
        /// ordinary gas, and leaves the callback O(1).
        ///
        /// ECONOMICS: it also fixes the base at the moment the bounty was EARNED rather than
        /// whenever the oracle happens to answer, which removes the "wait for the pot to peak"
        /// incentive that audit finding #7 turns on.
        uint256 baseAtOpen;
        // Anchors the normal window. 0 means the request never went out — and that zero is also the
        // ONLY on-chain proof that the oracle really accepted us, which script/ForkVrf.s.sol asserts
        // on against the live Chainlink wrapper. ⛔ Never write it in the catch arms to shorten a
        // timeout: it would still compile, still pass the timing tests, and quietly turn the ORAO
        // detector into a function that always says yes.
        uint256 armedAt;
        bool resolved;
    }

    struct Bet {
        address player;
        uint256 netAmount;
        uint256 roiTarget;
        uint256 accumulatedBase;
        uint256 cumulativeAtJoin;
        uint256 bountyOwed;   // salvation bounties reserved for this bet's player, claimed separately
        bool reserved;
        bool withdrawn;
        /// One salvation per matured bet, ever. Tracked HERE rather than inferred from `reserved`,
        /// because a bet can be reserved by any of three routes and only one of them is a salvation
        /// — see reserveRoiWithSalvation. Packs into the same slot as the two bools above, so this
        /// costs no extra storage.
        bool salvaged;
    }

    uint256 public gameCount;
    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(uint256 => Bet)) public bets; // gameId => betId => Bet
    /// ⭐ WHEN BETTING OPENS, for a game created inside its coin's launch window; 0 (never written) for
    /// every other game, which is "open from creation". Read it with opensAtOf.
    /// ⛔⛔ A MAPPING, NOT A FIELD ON Game, AND THAT IS AN INTERFACE DECISION. The site, the wallet bot
    ///    and the indexer each read BSC's deployment and Arc's with ONE ABI. A field on Game would make
    ///    games() return 27 words here and 26 on BSC, and a decoder expecting 27 THROWS on 26: every
    ///    BSC read would break the moment the ABI was regenerated. Same storage cost either way (one
    ///    slot per game), and games() stays byte-identical to every deployment before it.
    mapping(uint256 => uint256) private _opensAt;

    /// Salvation ids start at 1, so 0 reliably means "not one of ours" in requestToSalvation.
    uint256 public salvationCount;
    mapping(uint256 => PendingSalvation) public salvations;      // salvationId => data
    mapping(uint256 => uint256) public requestToSalvation;       // VRF requestId => salvationId

    // ⚠️ Fee amounts are emitted EXPLICITLY, not left to be re-derived. An indexer cannot recover
    // them from netAmount alone: integer division is lossy, and with a fee-on-transfer token the
    // amount that ARRIVED is not the amount that was asked for. The off-chain points ledger is
    // built from these numbers, so they are part of the contract's interface, not a nicety.
    event GameCreated(
        uint256 indexed gameId, address indexed host, address indexed token,
        uint256 grossDeposit, uint256 netDeposit, uint256 platformFee, uint256 minBet, uint256 roiBps
    );
    /// Emitted with GameCreated when the game waits for its opening. ⭐ A SEPARATE EVENT on purpose:
    /// GameCreated keeps its exact signature, so its topic and every decoder already reading it stay valid.
    event GameOpensAt(uint256 indexed gameId, uint256 opensAt);
    event BetPlaced(
        uint256 indexed gameId, uint256 indexed betId, address indexed player,
        uint256 grossAmount, uint256 netAmount, uint256 platformFee, uint256 hostFee, uint256 timerEnd
    );
    event RoiReserved(uint256 indexed gameId, uint256 indexed betId, address indexed player, uint256 roiTarget);
    event Withdrawn(uint256 indexed gameId, uint256 indexed betId, address indexed player, uint256 amount);
    event JackpotClaimed(uint256 indexed gameId, address indexed winner, uint256 amount);
    event BountyAccrued(uint256 indexed gameId, uint256 indexed saviourBetId, address indexed saviour, uint256 savedBetId, uint256 amount);
    event BountyClaimed(uint256 indexed gameId, uint256 indexed betId, address indexed player, uint256 amount);
    event SalvationRequested(uint256 indexed gameId, uint256 indexed salvationId, uint256 requestId, uint256 saviourBetId);
    /// Emitted when the oracle could not be reached at all. The salvation still exists; it clears
    /// through the emergency window. An indexer should treat this as "needs watching", not "lost".
    event SalvationRequestFailed(uint256 indexed gameId, uint256 indexed salvationId, uint256 saviourBetId);
    event SalvationSettled(uint256 indexed gameId, uint256 indexed salvationId, uint16 bps, uint256 amount, bool viaFallback);

    error BadParams();
    error GameOver();
    error TimerExpired();
    error BelowMinBet();
    error NotYet();
    error NotYours();
    error AlreadyDone();
    error RoiNotReached();
    error InsufficientFee();
    error RefundFailed();
    /// ⭐ NAMED, not BadParams(). This contract's own comment complains that one undifferentiated
    ///    revert "leaves a host to guess which of eleven rules they broke". Custom errors are free.
    error MinBetBelowFloor(uint256 given, uint256 floorRequired);
    /// Native was attached on a chain whose gas asset cannot be wrapped, or to a game that does not
    /// settle in it, or in an amount that does not match what was asked for. All three are the
    /// caller's mistake and all three are worth being able to tell apart.
    error NoNativeWrapper();
    error NativeIsNotThisGamesToken(address token, address wrapper);
    error NativeAmountMismatch(uint256 sent, uint256 required);
    error PoolBelowInsanityFloor(uint256 given, uint256 floorRequired);
    /// A bet before the game opens. Carries the opening, so a client can say when to come back.
    error NotOpenYet(uint256 opensAt);

    constructor(
        address _operatorTreasury,
        uint256 _platformFeeBps,
        address _vrfWrapper,
        address _flapPortal,
        address _dexFactory,
        address _dexRouter,
        address _wrappedNative,
        address _nativeWrapper,
        address[] memory _curatedTokens,
        uint256[] memory _curatedFees,
        address _feeTiers,
        /// [minBet, minBetInsanity, insanityMinPool], in wrappedNative's units. One array rather
        /// than three more positional arguments: fourteen addresses and numbers in a row is how a
        /// deploy script transposes two of them and nobody finds out until a game is created.
        uint256[3] memory _floors,
        /// Seconds between creating a game and it accepting bets. See OPEN_DELAY.
        uint256 _openDelay
    ) {
        if (_operatorTreasury == address(0) || _platformFeeBps > 1_000) revert BadParams();
        // The default is the ceiling AND must clear the floor, or the clamp in feeForToken would
        // describe a range that does not exist.
        if (_platformFeeBps < MIN_FEE_BPS) revert BadParams();
        if (_curatedTokens.length != _curatedFees.length) revert BadParams();
        operatorTreasury = _operatorTreasury;
        platformFeeBps = _platformFeeBps;
        feeTiers = _feeTiers;
        for (uint256 i; i < _curatedTokens.length; i++) {
            // A curated entry is only ever a DISCOUNT, and never below the floor. Zero means "not
            // curated", so it cannot be used to express one either.
            if (_curatedTokens[i] == address(0)) revert BadParams();
            if (_curatedFees[i] < MIN_FEE_BPS || _curatedFees[i] > _platformFeeBps) revert BadParams();
            curatedFeeBps[_curatedTokens[i]] = _curatedFees[i];
        }
        // None are validated and none are dereferenced here: address(0) is the meaningful
        // "this chain has no such price source" value. See the immutables above.
        flapPortal = _flapPortal;
        dexFactory = _dexFactory;
        dexRouter = _dexRouter;
        wrappedNative = _wrappedNative;
        // ⛔ IT IS THE PRICING ASSET OR IT IS NOTHING. Letting these two differ would mean wrapping
        //    native into a token that is not the one the game settles in — a deposit that vanishes
        //    into a balance nothing reads. A chain that genuinely needs them split can have it, but
        //    deliberately and with a test, not by a deploy script passing the wrong address.
        if (_nativeWrapper != address(0) && _nativeWrapper != _wrappedNative) revert BadParams();
        nativeWrapper = _nativeWrapper;
        // ⛔ ZERO IS A LEGITIMATE FLOOR — a chain with no price source gates nothing, which is what
        //    this contract did before floors existed — but the ORDER is not negotiable: Insanity
        //    cannot ask less than an ordinary game, and a pool cannot sit below the single bet that
        //    has to clear it, or the three numbers describe no coherent game.
        if (_floors[1] < _floors[0] || _floors[2] < _floors[1]) revert BadParams();
        MIN_BET_NATIVE           = _floors[0];
        MIN_BET_NATIVE_INSANITY  = _floors[1];
        INSANITY_MIN_POOL_NATIVE = _floors[2];
        // Bounded by the timer's own ceiling (createGame: timerDuration <= 24 h), not by a new number.
        // A delay past it is a deploy typo, and every launch game's pot would sit idle for it.
        if (_openDelay > 1_440 * 60) revert BadParams();
        OPEN_DELAY = _openDelay;
        // Not validated, and not dereferenced: address(0) is the meaningful "this chain has no
        // oracle" value, and createGame refuses mode 3 on it.
        vrfWrapper = IVRFV2PlusWrapper(_vrfWrapper);
    }

    /**
     * Measure what actually arrived. A fee-on-transfer token delivers less than `amount`, and every
     * downstream number — the pool, the accumulator, the ROI target — must be built from the real
     * figure or the contract promises more than it holds.
     */
    /**
     * A transfer that reports failure instead of reverting.
     *
     * ⭐ WHY NOT SafeERC20. safeTransfer REVERTS on failure, which is right everywhere else in this
     * contract because the recipient is the caller — if you cannot receive your own money, only your
     * own transaction fails. A BOUNTY is different: the recipient is the SAVIOUR, a third party, and
     * it is paid inside the same transaction that settles somebody else's ROI. A saviour on a token
     * blacklist, or a contract that rejects transfers, would otherwise block a matured player's
     * payout. So the bounty path degrades to the old accrue-and-claim instead of failing.
     *
     * ⚠️ Handles the tokens that return nothing as well as the ones returning bool — the whole reason
     * SafeERC20 exists. `ret.length == 0` is a well-behaved non-standard token, not a failure.
     * ⛔ Not a general-purpose helper: use safeTransfer anywhere the recipient IS the caller, so
     * failures stay loud.
     */
    function _tryPay(IERC20 token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _pullMeasured(IERC20 token, address from, uint256 amount) private returns (uint256) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        return token.balanceOf(address(this)) - before;
    }

    /**
     * ⭐⭐ THE CHAIN'S OWN COIN, STAKED IN ONE TRANSACTION.
     *
     * placeBet and createGame settle in ERC-20 and cannot do otherwise — so a game "in BNB" is a
     * game in WBNB, and every player had to wrap first and bet second. Two wallet prompts, two gas
     * fees, and a first screen that read "your balance: 0" to somebody holding nothing but BNB.
     * Attaching the value instead collapses that to one call: the contract wraps what it was sent
     * and measures what arrived, exactly as the pull path does.
     *
     * ⚠️ MEASURED, not assumed, for the same reason _pullMeasured is. WETH9 mints 1:1 and always
     *    has, but this contract's rule is that the pool is built from what ACTUALLY arrived, and a
     *    rule with an exception is a rule somebody edits out later.
     *
     * ⚠️ EXACT AMOUNT. Accepting more than was asked would strand the remainder in the contract
     *    with no owner and no path out; accepting less would fund a game from a balance that
     *    belongs to other games. Both are refused by name.
     */
    function _wrapMeasured(address token, uint256 amount) private returns (uint256) {
        if (nativeWrapper == address(0)) revert NoNativeWrapper();
        if (token != nativeWrapper) revert NativeIsNotThisGamesToken(token, nativeWrapper);
        if (msg.value != amount) revert NativeAmountMismatch(msg.value, amount);
        uint256 before = IERC20(token).balanceOf(address(this));
        IWrappedNative(nativeWrapper).deposit{value: amount}();
        return IERC20(token).balanceOf(address(this)) - before;
    }

    /**
     * One seam for both ways money enters a game. `msg.value == 0` is the ordinary ERC-20 path and
     * is bit-for-bit what it always was; anything attached means the caller is staking the chain's
     * own coin and _wrapMeasured decides whether that is allowed here.
     *
     * ⚠️ A STRAY msg.value CANNOT BE SILENTLY KEPT. Value attached to an ERC-20 game reverts in
     *    _wrapMeasured rather than sitting in the contract forever — which is why the branch is on
     *    msg.value and not on the token: "did you send me money" is the question that must never go
     *    unanswered, and "is this the wrapper" is only how it gets answered.
     */
    function _pullOrWrap(address token, address from, uint256 amount) private returns (uint256) {
        if (msg.value == 0) return _pullMeasured(IERC20(token), from, amount);
        return _wrapMeasured(token, amount);
    }

    /**
     * Create and fund in ONE call. On Solana these are two instructions and the gap between them is
     * a state that needed defending against; here it cannot exist.
     * The host's deposit becomes bet #0 — the same as Solana, and the reason "money that entered a
     * game" is SUM(bets) alone and never deposit + bets (adding them double-counts this).
     */
    /**
     * What THIS coin pays. Curated first (fixed at deployment), then the optional registry, and the
     * default if neither has anything to say.
     * ⛔ The registry's answer is CLAMPED and anything it cannot answer falls through to the
     *    default — a revert, an out-of-range number, or an address with no code all end up here.
     */
    function feeForToken(address token) public view returns (uint256) {
        uint256 curated = curatedFeeBps[token];
        if (curated != 0) return curated;
        if (feeTiers == address(0)) return platformFeeBps;
        try IFeeTiers(feeTiers).feeFor(token) returns (uint256 quoted) {
            if (quoted >= MIN_FEE_BPS && quoted < platformFeeBps) return quoted;
        } catch { /* a registry that cannot answer is a registry with nothing to say */ }
        return platformFeeBps;
    }

    function createGame(
        address token,
        uint256 deposit,
        uint256 minBet,
        uint256 roiBps,
        uint256 hostFeeBps,
        uint256 timerMode,
        uint256 timerDuration,
        uint256 timeIncrement,
        uint16[4] calldata salvador   // [mode, bps, stepBps, capBps] — packed to keep the stack shallow
    ) external payable nonReentrant returns (uint256 gameId) {
        if (token == address(0) || deposit == 0 || minBet == 0) revert BadParams();
        // ⚠️ MODE 3 HAS ITS OWN ROI BAND ON SOLANA AND THE PORT DROPPED IT — a missing [v13] fix,
        // found 2026-08-15 by diffing the port against the live program after the host-fee bug
        // turned out to be pre-v14 behaviour.
        //
        // The floor is an ECONOMIC bound, not taste. Solana's own note: fees are taken off the top,
        // so net profit needs (1-fee)(1+roi) > 1, i.e. roi > fee/(1-fee). This contract allows up to
        // 10% platform + 5% host = 15%, giving a break-even of ~17.6% — so a game below that pays
        // its winners a LOSS. 20% clears it with margin. Insanity is a premium tier at 50-150%.
        if (salvador[0] == 3) {
            if (roiBps < 5_000 || roiBps > 15_000) revert BadParams();   // Insanity: 50%-150%
        } else {
            if (roiBps < 2_000 || roiBps > 10_000) revert BadParams();   // 20%-100%
        }
        // Matches Solana exactly: `require!(host_fee_bps >= 100 && host_fee_bps <= 500)`. The port
        // accepted 0, which let a host be configured to earn nothing at all from their own game —
        // and, before the fix below, to pay the fee into the pot for the last bettor to take.
        if (hostFeeBps < 100 || hostFeeBps > 500) revert BadParams();
        if (timerMode > MODE_CUMULATIVE) revert BadParams();
        // 🩸 THIS FLOOR WAS 300, AND 300 CAME FROM NOWHERE. Solana's program takes
        //    `timer_duration >= 60` and has since v1; the five minutes here had no derivation, no
        //    comment, and no counterpart — it was simply a number this port chose. A port copies.
        if (timerDuration < 60 || timerDuration > 1_440 * 60) revert BadParams();
        // ⚠️ timeIncrement is added to timerEnd on EVERY bet in cumulative mode, and Solana does
        // not bound it on chain AT ALL (it stores the argument and adds it, lib.rs:509/814) — the
        // 1 min - 2 h range lives only in the client. Bounding it here is right: unbounded, a host
        // can set it to years so the timer never expires and the jackpot is locked forever, or near
        // the integer ceiling so the first bet overflow-reverts and the game is bricked with the
        // deposit inside.
        // 🩸 BUT THE BOUND USED TO BE `<= timerDuration`, WHICH WAS THIS PORT'S OWN INVENTION and
        //    stricter than anything Solana enforces anywhere. It made a SHIPPED preset impossible:
        //    'Slow burn' is a 20-minute timer with +2 h per bet, which is the entire point of it.
        //    The bound is now Solana's own client range, so the protection stands and the preset
        //    works.
        if (timerMode == MODE_CUMULATIVE) {
            if (timeIncrement < 60 || timeIncrement > 7_200) revert BadParams();
        } else {
            // Unused in reset mode. Refuse a non-zero value rather than silently ignore it — same
            // reasoning as rejecting a host-supplied rate on mode 3: a host who thinks they set an
            // increment and got none would have been misled about their own game.
            if (timeIncrement != 0) revert BadParams();
        }
        // Salvador bounds, mirroring the on-chain Solana requires.
        if (salvador[0] > 3) revert BadParams();
        // ⭐⭐ REDUCED 2026-09-16, on the operator's numbers: fixed 0.5-2% (was 3%), progressive step
        //    0.1-0.2% (was 0.5%) and cap 1-2.5% (was 2-5%); the progressive base stays 0.5-1%. Decided
        //    months earlier from real games (HELLO WORLD: 21 saves averaging 1.50%, one every ~3 bets, the
        //    pool bleeding to bounties as much as to ROI) and missed by three deploys, because these are
        //    literals and can only move with one.
        // ⚠️ SOLANA AND BSC v3 STILL ENFORCE THE OLD BANDS until their own next deploys, so the clients
        //    carry the bands PER CHAIN. The narrower bands are inside the old ones, so nothing a client
        //    offers under them can be refused by an older contract.
        // (History: the port once allowed mode 1 at 10-500 and mode 2's base at 10-500, wider than
        //  Solana; the 2026-08-15 audit's solvency finding scales with bps, which is why the ceilings
        //  matter at all.)
        if (salvador[0] == 1 && (salvador[1] < 50 || salvador[1] > 200)) revert BadParams();  // fixed 0.5%-2%
        if (salvador[0] == 2) {
            if (salvador[1] < 50 || salvador[1] > 100) revert BadParams();    // base 0.5%-1%
            if (salvador[2] < 10 || salvador[2] > 20) revert BadParams();     // step 0.1%-0.2%
            if (salvador[3] < 100 || salvador[3] > 250) revert BadParams();   // cap 1%-2.5%
        }
        if (salvador[0] == 3) {
            // Insanity draws its rate from a fixed table, so the host configures nothing. Reject a
            // non-zero rate rather than accept and ignore it — a host who thinks they set 5% and
            // silently got the table would have been misled about their own game.
            if (salvador[1] != 0 || salvador[2] != 0 || salvador[3] != 0) revert BadParams();
            // No oracle on this chain: refuse at creation, when it is still free to choose another
            // mode, instead of at the first salvation when there is money in the pot.
            if (address(vrfWrapper) == address(0)) revert BadParams();
        }

        uint256 grossDeposit = _pullOrWrap(token, msg.sender, deposit);
        if (grossDeposit == 0) revert BadParams();
        // Gate on the MEASURED GROSS. Gross matches Solana, which checks initial_deposit before the
        // fee split; measured keeps a taxed token from sneaking a game under the gate.
        if ((grossDeposit / minBet) * roiBps < ANTI_FARM_MIN) revert BadParams();

        // ⚠️ The anti-farm gate bounds deposit/minBet from BELOW; nothing bounded it from above, so
        // a tiny minBet passed trivially and was even rewarded. At minBet = 1 both fees floor to
        // zero and `cumulativePerBet += netAmount / activeBetCount` floors to zero too — the
        // accumulator FREEZES while the timer keeps extending, so no bet can ever mature and the pot
        // is locked. (The 2026-08-15 audit found this independently; it is Solana's min_bet_floor.)
        // 🩸 MAX_DEPOSIT_TO_MIN_BET USED TO BE ENFORCED HERE AND IS GONE. It bounded
        //    deposit/minBet from ABOVE at 1000 — a number with no derivation anywhere; the commit
        //    that added it called it "generous" and cited no source, unlike every other constant in
        //    this file. It was justified as stopping the accumulator freeze, but the SAME commit
        //    added the guard that actually stops it, in _placeBet:
        //        if (netAmount < g.activeBetCount) revert BelowMinBet();
        //    which guarantees the accumulator advances by at least 1 on every accepted bet. The
        //    ceiling only additionally stopped a host CONFIGURING a game nobody could bet into —
        //    their own game, their own loss, and not this contract's business.
        //    ⚠️ It also silently set the worst case for an adversarial review: an attack modelled at
        //    exactly ratio 1000 looked far worse than anything a real host would ever create.

        // ─── REAL-MONEY FLOORS ────────────────────────────────────────────────────────────────
        // Ratios are scale-free: ratio 100 is ratio 100 whether a bet is worth a dollar or a
        // millionth of one, so they cannot express "this bet must out-earn the gas WE pay to settle
        // it". Where the token has a price, use it. Where it has none, fall through to the ratio,
        // which is exactly what this contract did before.
        bool insanity = salvador[0] == 3;
        (uint256 betFloor, bool priced) =
            _quoteNativeToToken(token, insanity ? MIN_BET_NATIVE_INSANITY : MIN_BET_NATIVE);
        if (priced) {
            if (minBet < betFloor) revert MinBetBelowFloor(minBet, betFloor);
            if (insanity) {
                (uint256 poolFloor, bool poolPriced) =
                    _quoteNativeToToken(token, INSANITY_MIN_POOL_NATIVE);
                if (poolPriced && grossDeposit < poolFloor) {
                    revert PoolBelowInsanityFloor(grossDeposit, poolFloor);
                }
            }
        }
        // ⚠️ AND NOTHING AT ALL WHERE THE TOKEN HAS NO PRICE. The ratio that used to stand here is
        //    gone (its tombstone is above): a scale-free ratio cannot express "this bet must
        //    out-earn the gas WE pay to settle it", which is the only thing these floors are for.
        //    A chain with no price source now gates nothing, visibly and on purpose, rather than
        //    gating on a number that looked like protection and was not.

        // The host's deposit pays the platform fee too, exactly as Solana's fund_game does. This is
        // NOT incidental revenue: it is the fee the points ledger credits a host for STARTING a
        // game, and the one the 2x/3x action multipliers are applied to. Without it a host earns
        // nothing for hosting and the whole host-side incentive quietly disappears.
        uint256 feeBps = feeForToken(token);
        uint256 depositFee = (grossDeposit * feeBps) / BPS;
        uint256 netDeposit = grossDeposit - depositFee;
        if (netDeposit == 0) revert BadParams();

        gameId = ++gameCount;
        Game storage g = games[gameId];
        g.host = msg.sender;
        g.token = token;
        g.platformFeeBps = feeBps;
        g.minBet = minBet;
        g.roiBps = roiBps;
        g.hostFeeBps = hostFeeBps;
        g.timerMode = timerMode;
        g.timerDuration = timerDuration;
        g.timeIncrement = timeIncrement;
        // ⭐ THE TIMER RUNS FROM THE OPENING, not from creation, so a delayed game keeps every second
        //    of the duration its host chose. Only a coin inside its launch window has an opening.
        uint256 opensAt = _openingFor(token);
        g.timerEnd = (opensAt == 0 ? block.timestamp : opensAt) + timerDuration;
        if (opensAt != 0) _opensAt[gameId] = opensAt;
        g.poolBalance = netDeposit;
        g.cumulativePerBet = netDeposit; // no active bets yet, so the first bet absorbs full value
        g.activeBetCount = 1;
        g.betCount = 1;
        g.lastBettor = msg.sender;
        g.isActive = true;
        g.salvadorMode = uint8(salvador[0]);
        g.salvadorBps = salvador[1];
        g.salvadorStepBps = salvador[0] == 2 ? salvador[2] : 0;
        g.salvadorCapBps = salvador[0] == 2 ? salvador[3] : 0;

        // Bet #0 is the host's NET deposit — the fee is already out, same as every other bet.
        //
        // ⛔ cumulativeAtJoin IS 0 HERE, NOT g.cumulativePerBet, AND THAT IS THE WHOLE POINT.
        //    The deposit STARTS WITH ITSELF ALREADY COUNTED. g.cumulativePerBet was just seeded to
        //    netDeposit above, so joining at 0 makes this bet's accrued open at netDeposit — half
        //    of a 100%-ROI target — and it matures once the accumulator grows by the ROI PORTION.
        //    That is what Solana does (`accumulated_base = netDeposit, cumulative_at_join = 0`).
        //
        // 🩸 IT WAS `cumulativeAtJoin: g.cumulativePerBet`, WHICH IS THE SAME BUG WEARING THE
        //    OPPOSITE SIGN: accrued opened at ZERO against a full principal+ROI target, so the
        //    host's deposit had to accrue its own principal a SECOND time before it could ever
        //    mature — twice the growth Solana asks for, on every BNB game ever created (1, 2, 3).
        //    Normal bets hid it perfectly: the accumulator and their cumulativeAtJoin were both
        //    shifted up by netDeposit, so every later delta was identical and the maths "tied out".
        //
        // ⛔ DO NOT "FIX" THIS BY COPYING SOLANA'S FIELD LAYOUT (accumulatedBase = netDeposit,
        //    cumulativeAtJoin = 0). It gives the right maturity but BREAKS SALVATIONS: this
        //    contract relies on accumulatedBase being zero until reserveRoi writes it, and both
        //    maturityThresholdOf and the salvation threshold compute `cumulativeAtJoin + roiTarget`
        //    with no base term. A non-zero base at creation makes those views disagree with the
        //    contract, and every salvation naming this bet reverts BadParams. Joining at 0 gets the
        //    same maturity while keeping the invariant — which is why it is the one-line fix.
        bets[gameId][0] = Bet({
            player: msg.sender,
            netAmount: netDeposit,
            roiTarget: netDeposit + (netDeposit * roiBps) / BPS,
            accumulatedBase: 0,
            cumulativeAtJoin: 0,
            bountyOwed: 0,
            reserved: false,
            withdrawn: false,
            salvaged: false
        });

        if (depositFee > 0) IERC20(token).safeTransfer(operatorTreasury, depositFee);

        emit GameCreated(gameId, msg.sender, token, grossDeposit, netDeposit, depositFee, minBet, roiBps);
        if (_opensAt[gameId] != 0) emit GameOpensAt(gameId, _opensAt[gameId]);
    }

    /**
     * ATOMIC. No queue, no escrow, no operator — the whole reason this port is simpler than the
     * original. Fees come off the top exactly as on Solana, so the accumulator sees net amounts.
     */
    function placeBet(uint256 gameId, uint256 amount) external payable nonReentrant returns (uint256 betId) {
        return _placeBet(gameId, amount);
    }

    /**
     * Bet in ONE transaction, on a token that implements EIP-2612 — no separate approve.
     *
     * ⭐ WHY THIS EXISTS AND WHAT IT DOES NOT FIX. On Solana the signature on the transaction IS the
     * authorisation to move your tokens. On EVM the game calls transferFrom on the TOKEN, which
     * never sees your transaction and checks only a standing allowance — so an approval must exist
     * first. That is structural, not a design choice, and it is why the first live session cost a
     * signature per bet.
     * ⚠️ MEASURED 2026-08-19: NONE of the majors on BSC support permit — not USDT, USDC, WBNB or
     * BUSD, and CAKE has `nonces()` but no `DOMAIN_SEPARATOR`, so a detector checking only nonces
     * would build a signature that reverts. Our own launchpad tokens DO support it. So this helps
     * the tokens we launch (the main case for the game) and does nothing for a USDT game — where the
     * answer is one blanket approval, not this.
     *
     * ⛔ THE PERMIT IS TRIED, NOT REQUIRED, AND THAT IS A SECURITY PROPERTY. Anyone watching the
     * mempool can lift the signature and submit `permit` themselves; the nonce is then consumed and
     * OUR permit call reverts, so a required permit would let any observer grief every bet. The
     * allowance is already set at that point, so the bet must simply proceed. If the permit failed
     * for a real reason instead, `_pullMeasured` reverts a moment later on the missing allowance —
     * so nothing is lost by being permissive here.
     */
    function placeBetWithPermit(
        uint256 gameId, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant returns (uint256 betId) {
        try IERC20Permit(games[gameId].token).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
        catch { /* front-run, already approved, or not a permit token — the pull below is the judge */ }
        return _placeBet(gameId, amount);
    }

    function _placeBet(uint256 gameId, uint256 amount) private returns (uint256 betId) {
        Game storage g = games[gameId];
        if (!g.isActive || g.jackpotClaimed) revert GameOver();
        // Before the opening nothing is accepted. Nothing else needs the check: the host's bet #0 cannot
        // mature, be salvaged or win without other bets, and the jackpot waits on timerEnd, which is
        // already past the opening.
        uint256 opensAt = _opensAt[gameId];
        if (block.timestamp < opensAt) revert NotOpenYet(opensAt);
        if (block.timestamp >= g.timerEnd) revert TimerExpired();
        if (amount < g.minBet) revert BelowMinBet();

        uint256 received = _pullOrWrap(g.token, msg.sender, amount);
        if (received < g.minBet) revert BelowMinBet();

        uint256 platformFee = (received * g.platformFeeBps) / BPS;
        uint256 hostFee = (received * g.hostFeeBps) / BPS;
        uint256 netAmount = received - platformFee - hostFee;

        // ⭐ EVERY ACCEPTED BET MUST ACTUALLY MOVE THE ACCUMULATOR. The line below divides by
        // activeBetCount, so a bet smaller than the number of active bets contributes ZERO and the
        // economy silently stops advancing while the timer keeps extending — bets stop maturing,
        // withdraw stops working, and the pot is frozen. minBet is checked against the GROSS at
        // creation, which does not prevent this once fees and a large field are involved.
        // ⚠️ This is the guarantee, not the ratio bound in createGame: that one stops a dust minBet
        // being configured, this one stops a dust bet being accepted whatever the config says.
        if (netAmount < g.activeBetCount) revert BelowMinBet();

        // The accumulator: every existing active bet gains an equal share of this one. This single
        // line is what makes ROI self-funding — a bet only matures once enough OTHER money has
        // arrived to cover it, which is why the pot can never be drained by maturity.
        if (g.activeBetCount > 0) {
            g.cumulativePerBet += netAmount / g.activeBetCount;
        } else {
            g.cumulativePerBet += netAmount;
        }

        // ⚠️⚠️ THE HOST FEE IS THE HOST'S. The line here used to be
        //     g.poolBalance += netAmount + hostFee;   // "host fee stays in the pool, as on Solana"
        // and that comment was FALSE — it described only Solana's FALLBACK branch. The live program
        // pays the host directly on every bet, into a per-game host_fee_vault whose authority is the
        // host, and routes the fee to the pool ONLY when that token account has been closed:
        //     if (host_vault.lamports() > 0) { transfer(-> host_vault) }
        //     else                           { transfer(-> game_vault); pool_balance += host_fee; }
        // So the port silently dropped the host's income — on BNB the host was funding the jackpot
        // instead of earning from it — and the comment is what would have stopped anyone noticing.
        // Solana also REQUIRES host_fee_bps in 100..500; this port accepts 0, so a BNB host could
        // additionally be set to earn nothing at all. Found 2026-08-15; the user caught the false
        // comparison, having checked the live behaviour themselves.
        g.poolBalance += netAmount;
        g.activeBetCount += 1;

        if (g.timerMode == MODE_CUMULATIVE) {
            g.timerEnd += g.timeIncrement;
        } else {
            g.timerEnd = block.timestamp + g.timerDuration;
        }

        betId = g.betCount++;
        g.lastBettor = msg.sender;

        bets[gameId][betId] = Bet({
            player: msg.sender,
            netAmount: netAmount,
            roiTarget: netAmount + (netAmount * g.roiBps) / BPS,
            accumulatedBase: 0,
            // AFTER the increment, so a bet never earns from itself.
            cumulativeAtJoin: g.cumulativePerBet,
            bountyOwed: 0,
            reserved: false,
            withdrawn: false,
            salvaged: false
        });

        if (platformFee > 0) IERC20(g.token).safeTransfer(operatorTreasury, platformFee);

        // ⭐ THE HOST IS PAID, DIRECTLY, ON EVERY BET — Solana's normal path.
        //
        // ⛔ SOLANA'S FALLBACK BRANCH IS DELIBERATELY NOT PORTED, and this is the reasoning so it is
        // not "restored" later by someone comparing the two files. Solana routes the fee to the pool
        // when the host's token account is CLOSED — a routine, user-initiated action there, because
        // closing an ATA reclaims rent. THE EVM HAS NO EQUIVALENT: an address can always receive an
        // ERC20 unless that specific token blocks it. The fallback answers a hazard that does not
        // exist here, so porting the mechanism instead of the intent would add a branch, an extra
        // external call on the hot path of every bet, and two events, for nothing.
        //
        // The residual risk is a token with an admin blocklist (USDT-style) blocking the host
        // mid-game. Accepted, and the blast radius is small: only placeBet reverts. withdraw and
        // claimJackpot never touch this path, so matured players still exit and the winner still
        // claims — the game simply stops taking new bets and settles. Pausable tokens are excluded
        // by policy at the UI. ⚠️ Note the CONTRACT has no token whitelist, so that exclusion holds
        // only for games created through our own front end.
        //
        // hostFeeBps is bounded 100..500 at creation, so hostFee is never zero here and there is no
        // zero-value transfer to guard against.
        IERC20(g.token).safeTransfer(g.host, hostFee);

        emit BetPlaced(gameId, betId, msg.sender, received, netAmount, platformFee, hostFee, g.timerEnd);
    }

    // ─── Views ───────────────────────────────────────────────────────────────────────────────
    // Named getters rather than making callers positionally destructure a 17-field struct — which
    // is unreadable, and silently wrong the moment a field is inserted anywhere but the end.

    /**
     * What the last bettor would take right now, and identically the base every Salvador bounty is a
     * percentage of. One definition of "unspoken-for money", used everywhere. O(1).
     *
     * ⭐ IT WAS BRIEFLY O(betCount) AND THAT WAS A MISTAKE — the history is worth keeping, because
     * the reasoning that led there is seductive.
     *
     * `reservedBalance` is what the contract has NOTICED it owes. A bet that matured but that nobody
     * has called reserveRoi on yet is owed and unnoticed, so its ROI sat inside `pool - reserved`
     * looking exactly like jackpot — and both the bounty and the jackpot spent it. The fix looked
     * obvious: walk the bets and subtract it. It cost more than it bought:
     *   • `claimJackpot` became O(betCount) with nothing bounding betCount, so ~15,800 bets made a
     *     pot PERMANENTLY unclaimable for about $1,900 of gas — against a stranger's game;
     *   • `eth_call` broke at ~5,630 bets on a default 50M node gascap, killing the pot display and
     *     the wallet's Claim button while the transaction itself would still have worked;
     *   • and the gas I justified it with was measured WARM (the probe placed the bets and read the
     *     loop in one transaction). Cold is 8,860/bet, 10.2x higher.
     *
     * ⇒ AUTO-PAYOUT REMOVES THE PROBLEM INSTEAD OF ACCOUNTING FOR IT. `_reserveRoi` now transfers the
     * ROI the instant it is recognised, so "matured but unnoticed" lasts exactly as long as it takes
     * anyone — the indexer, another player, a bot — to make one permissionless call. There is no
     * standing balance to enumerate, and this can go back to arithmetic.
     */
    function jackpotOf(uint256 gameId) public view returns (uint256) {
        Game storage g = games[gameId];
        uint256 slack = g.poolBalance - g.reservedBalance;
        // The ceiling of every mode-3 bounty already triggered but not yet settled. A pending
        // salvation holds a SNAPSHOT of this number, and opening one does not otherwise move it — so
        // without this term, N salvations opened before any of them settles all capture the same base
        // and spend it N times over. Measured at three 5000 bps rolls: 200,680 paid against a base of
        // 185,320, the 15,360 difference coming straight out of matured players' ROI. Subtracting the
        // ceiling makes the bases fall away geometrically — J/2, J/4, J/8 — so the sum never reaches J.
        uint256 spokenFor = g.pendingBountyMax;
        // ⚠️ Clamped rather than allowed to underflow. An underflow here would brick claimJackpot.
        return spokenFor >= slack ? 0 : slack - spokenFor;
    }

    function balancesOf(uint256 gameId) external view returns (uint256 pool, uint256 reserved) {
        Game storage g = games[gameId];
        return (g.poolBalance, g.reservedBalance);
    }

    /**
     * When a game created now on `token` would open: 0 for "at creation".
     *
     * ⛔ EVERY FAILURE MEANS "NO WINDOW", NEVER A REVERT, because this runs inside every createGame on
     *    every token: a coin without the view (USDC, WBNB, a flap coin), one that reverts, one that
     *    burns its gas cap, or one returning fewer than 32 bytes. A low-level staticcall rather than
     *    try/catch on purpose: try/catch does NOT catch a return it cannot decode, so a short answer
     *    would have reverted the host's createGame.
     * ⛔ THE ONE REVERT: a "window" longer than the timer's own 24 h ceiling is not a launch window. It
     *    would lock the host's pot for as long as the coin says; a TOLLY window is 300 s.
     * ⚠️ `<=`, like the token: the deadline second itself is still capped, so the earliest opening is
     *    deadline + 1.
     */
    function _openingFor(address token) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: ANTI_SNIPE_READ_GAS}(abi.encodeWithSignature("antiSnipeDeadline()"));
        if (!ok || ret.length < 32) return 0;
        uint256 deadline = abi.decode(ret, (uint256));
        if (block.timestamp > deadline) return 0;
        if (deadline - block.timestamp > 1_440 * 60) revert BadParams();
        uint256 opens = block.timestamp + OPEN_DELAY;
        return opens > deadline ? opens : deadline + 1;
    }

    /// When betting opens; 0 means it was open from creation.
    function opensAtOf(uint256 gameId) external view returns (uint256) {
        return _opensAt[gameId];
    }

    function timerEndOf(uint256 gameId) external view returns (uint256) {
        return games[gameId].timerEnd;
    }

    function betCountOf(uint256 gameId) external view returns (uint256) {
        return games[gameId].betCount;
    }

    function lastBettorOf(uint256 gameId) external view returns (address) {
        return games[gameId].lastBettor;
    }

    /// ⭐ THE DIVISOR THE WHOLE ECONOMY RESTS ON — `cumulativePerBet += netAmount / activeBetCount`.
    /// It had no getter, no assertion anywhere in the suite, and it was the one field the phantom-
    /// betId bug corrupted, which is exactly why that bug survived every existing test. Its meaning
    /// is a countable fact, not a running total: it must always equal the number of bets with
    /// `reserved == false`. test/Invariants.t.sol asserts that on every fuzzed sequence.
    function activeBetCountOf(uint256 gameId) external view returns (uint256) {
        return games[gameId].activeBetCount;
    }

    /// Salvations awaiting a rate. While this is non-zero the jackpot is blocked, but only for
    /// SALVATION_JACKPOT_EXTRA past the last activity — see claimJackpot.
    function salvationsPendingOf(uint256 gameId) external view returns (uint256) {
        return games[gameId].salvationPendingNum;
    }

    /// The accumulator value at which this bet became claimable — the number an indexer needs to
    /// identify the saviour off-chain before submitting it for on-chain verification.
    /**
     * Convert a NATIVE-denominated floor into token units, or report the token as unpriceable.
     *
     * ⛔ EVERY external call here is try/catch. A missing, hostile or simply unfamiliar price
     *    source must only ever make a token UNPRICEABLE - it must never revert createGame. Both
     *    sources revert readily: getTokenV5 with 0xde6137d1 for a token flap has never seen, and
     *    getAmountsOut whenever a hop has no pair. Both confirmed on mainnet.
     */
    function _quoteNativeToToken(address token, uint256 nativeWei)
        internal view returns (uint256 amountOut, bool priced)
    {
        // ⭐⭐ 0. THE CHAIN'S OWN ASSET, WHICH NOTHING ELSE CAN PRICE AND NOTHING ELSE NEEDS TO.
        //    A quote for the wrapper builds the path [wrappedNative, wrappedNative]; getPair answers
        //    address(0) for a pair of a token with itself, so the wrapper came back UNPRICEABLE and
        //    the chain enforced NO FLOOR on games played in its own coin. Measured on the live BSC
        //    deployment: minBetFloorFor(WBNB, false), minBetFloorFor(WBNB, true) and
        //    insanityPoolFloorFor(WBNB) all answered (0, false).
        //    The figure is already denominated in these units, so the conversion is the identity —
        //    and being the identity is precisely why no DEX could ever express it.
        if (wrappedNative != address(0) && token == wrappedNative) return (nativeWei, true);

        // 1. The bonding curve. THIS IS THE LAUNCH PATH and the reason the curve is checked first:
        //    a coin seconds old has no DEX pair at all, so the curve is the only price in existence.
        if (flapPortal != address(0)) {
            try IFlapPortal(flapPortal).getTokenV5(token) returns (TokenStateV5 memory st) {
                // 🩸 st.price is QUOTE per token, and the quote asset is st.quoteTokenAddress —
                //    which is NOT always native. Dividing a native amount by it is an asset-mismatch
                //    that silently understates the floor: a real coin (BEAGLE) quotes in DJTB and
                //    came out 70x low. The DEX branch below already honours quoteTokenAddress; this
                //    one used to ignore it while the struct comment three lines up said not to.
                //    So: trust st.price ONLY when the quote really is native. Anything else goes to
                //    the DEX path, which prices through the token's own quote asset correctly.
                bool nativeQuoted = st.quoteTokenAddress == address(0)
                    || st.quoteTokenAddress == wrappedNative;
                if (st.status == FLAP_TRADABLE && st.price > 0 && nativeQuoted) {
                    // price is quote-per-token at 18dp. It is the SPOT price, not the average a buy
                    // of this size would actually get - the curve moves as you buy. That is correct
                    // for a floor and must not be "fixed" into a quoteExactInput call: that one is
                    // nonpayable, so it would be an external state-changing call from createGame.
                    return ((nativeWei * 1e18) / st.price, true);
                }
                // Migrated (price is 0), or on the curve but quoted in something other than native.
                // Either way the token's own quote asset is the route: a real migrated coin paired
                // against QQQB, not WBNB, which is why the path is built from it rather than assumed.
                // ⚠️ A curve-phase coin quoted in a non-native asset may have no DEX pair yet, in
                //    which case this returns unpriced and the ratio gates apply — correct, and far
                //    better than a confidently wrong floor.
                return _quoteViaDex(token, nativeWei, st.quoteTokenAddress);
            } catch {
                // Not a token this curve knows. Fall through to the DEX.
            }
        }
        return _quoteViaDex(token, nativeWei, address(0));
    }

    function _quoteViaDex(address token, uint256 nativeWei, address quoteToken)
        internal view returns (uint256 amountOut, bool priced)
    {
        if (dexRouter == address(0) || dexFactory == address(0) || wrappedNative == address(0)) {
            return (0, false);
        }
        address[] memory path;
        if (quoteToken == address(0) || quoteToken == wrappedNative || quoteToken == token) {
            path = new address[](2);
            path[0] = wrappedNative;
            path[1] = token;
        } else {
            path = new address[](3);
            path[0] = wrappedNative;
            path[1] = quoteToken;
            path[2] = token;
        }
        // ⚠️ getAmountsOut REVERTS on a missing pair rather than returning zero, so every hop is
        //    checked before it is walked.
        for (uint256 i; i + 1 < path.length; ++i) {
            try IUniV2Factory(dexFactory).getPair(path[i], path[i + 1]) returns (address pair) {
                if (pair == address(0)) return (0, false);
            } catch {
                return (0, false);
            }
        }
        try IUniV2Router(dexRouter).getAmountsOut(nativeWei, path) returns (uint256[] memory amts) {
            uint256 got = amts[amts.length - 1];
            return (got, got > 0);
        } catch {
            return (0, false);
        }
    }

    /**
     * Exactly what createGame will demand of this token, so no UI ever computes it independently.
     *
     * ⭐ ONE SOURCE OF TRUTH. The form and the chain cannot drift apart, which is precisely the
     *    failure that shipped a wrong min-bet constant and left two coins launched with no game
     *    attached. A caller that wants a number should read it here, not derive it.
     *
     * priced == false means no configured source knows this token, and the ratio gates apply
     * instead - the behaviour this contract had before floors existed.
     */
    function minBetFloorFor(address token, bool insanity)
        external view returns (uint256 tokens, bool priced)
    {
        return _quoteNativeToToken(token, insanity ? MIN_BET_NATIVE_INSANITY : MIN_BET_NATIVE);
    }

    function insanityPoolFloorFor(address token)
        external view returns (uint256 tokens, bool priced)
    {
        return _quoteNativeToToken(token, INSANITY_MIN_POOL_NATIVE);
    }

    function maturityThresholdOf(uint256 gameId, uint256 betId) external view returns (uint256) {
        Bet storage b = bets[gameId][betId];
        // ⚠️⚠️ MUST MATCH reserveRoiWithSalvation EXACTLY — it did not, and that is a real bug the
        // 2026-08-15 audit caught (two lenses, independently).
        //
        // This view is documented as the input an indexer uses to FIND the saviour off-chain, and
        // the contract then re-derives the threshold itself to verify the answer. It used to
        // subtract accumulatedBase while the verifier did not. That field is zero on an un-reserved
        // bet, so the two agreed until the salvation-race fix made this function work for bets that
        // are ALREADY reserved — after which accumulatedBase is non-zero and the two thresholds
        // diverge. An indexer following this view would then name a saviour the contract rejects,
        // and every such salvation would revert BadParams.
        //
        // ⛔ THE FAILURE IS SILENT IN THE WAY THAT MATTERS: nobody loses money, bounties simply stop
        // being paid, and Insanity quietly becomes a feature that does not fire — which is exactly
        // how ORAO went unnoticed here for months. Keep these two expressions identical.
        return b.cumulativeAtJoin + b.roiTarget;
    }

    function accumulatedOf(uint256 gameId, uint256 betId) public view returns (uint256) {
        Bet storage b = bets[gameId][betId];
        // ⚠️ A SETTLED BET IS FROZEN AT WHAT IT ACCUMULATED, not still counting. `_reserveRoi` writes
        // `accumulatedBase = acc` on payout without rebasing `cumulativeAtJoin`, so the general form
        // below adds the same delta a second time and this returned roughly DOUBLE for any settled
        // bet — measured 3,147.40 -> 6,294.80 the instant it was paid.
        //
        // Harmless on the money paths (they all reject settled bets before reading this) but this is
        // interface: the indexer and the points ledger read it, and it is the exact sibling of the
        // maturityThresholdOf divergence above — a view that quietly disagrees with the contract.
        if (b.reserved) return b.accumulatedBase;
        return b.accumulatedBase + (games[gameId].cumulativePerBet - b.cumulativeAtJoin);
    }

    /**
     * ⭐ AUTO-PAYOUT. Permissionless, and it PAYS THE PLAYER — the money leaves in this transaction.
     *
     * On Solana this has to be two steps: pushing tokens needs the recipient's ATA to exist and be
     * passed in, and a player who closed theirs to reclaim rent would strand an operator-pushed
     * transfer. `pay_bounty`'s own v11 comment gives that as the reason ("nothing operator-pushed to
     * strand"). On the EVM a transfer to an address just works, so the split buys nothing and costs
     * the thing that matters: a matured player had to show up to be paid, and money nobody claimed
     * before claimJackpot went to the last bettor.
     *
     * Now one permissionless call — by the indexer, another player, anyone — settles it. About 50k
     * gas. ~$0.0035 on BSC at the 0.05 gwei measured 2026-08-20 (an earlier note here said $0.03 at
     * "1 gwei, the floor validators accept" — that floor claim was never verified and is wrong).
     * We pay it rather than deduct it: sizing a gas-denominated fee
     * would need an on-chain price for an arbitrary game token, which does not exist, and a bps fee
     * would make the payout stop being exactly the roiTarget the game advertises.
     *
     * ⚠️ nonReentrant, and the internal callers must use `_reserveRoi` instead — OpenZeppelin's guard
     * is contract-wide, so an already-guarded caller reaching this wrapper would revert.
     */
    function reserveRoi(uint256 gameId, uint256 betId) public nonReentrant {
        _reserveRoi(gameId, betId);
    }

    /**
     * Kept so existing callers and ABIs still work. It is now exactly `reserveRoi` — anyone may
     * trigger a payout and it always goes to the bet's own player, so there is nothing left for an
     * ownership check to protect.
     */
    function withdraw(uint256 gameId, uint256 betId) external nonReentrant {
        _reserveRoi(gameId, betId);
    }

    function _reserveRoi(uint256 gameId, uint256 betId) private {
        Game storage g = games[gameId];
        // ⚠️⚠️ BOUND betId. A mapping read past betCount returns an ALL-ZERO Bet, and every guard
        // below then passes it: reserved and withdrawn are false, roiTarget is 0, and accumulatedOf
        // returns cumulativePerBet — which is never less than 0, so RoiNotReached cannot fire. The
        // call sails through to `activeBetCount -= 1` and decrements the count for a bet that does
        // not exist.
        //
        // That counter is the ACCUMULATOR'S DIVISOR (`cumulativePerBet += netAmount / activeBetCount`),
        // so poisoning it over-credits every real bet: one call measured a 2x over-credit
        // (test_AUDIT_phantomBetIdOverCreditsEveryRealBet). It breaks the invariant the whole game
        // rests on — that a bet only matures once enough OTHER money has actually arrived — and it
        // is permissionless and free.
        //
        // Found 2026-08-15 by the adversarial audit, INDEPENDENTLY by two lenses. Nothing else
        // needed changing: reserveRoiWithSalvation bounds saviourBetId and requires
        // saviourBetId > betId, so its betId is transitively bounded; withdraw and claimBounty
        // compare b.player against msg.sender, which a zero Bet fails.
        if (betId >= g.betCount) revert BadParams();
        Bet storage b = bets[gameId][betId];
        if (b.reserved || b.withdrawn) revert AlreadyDone();

        uint256 acc = accumulatedOf(gameId, betId);
        if (acc < b.roiTarget) revert RoiNotReached();

        // ⭐⭐ NO isActive REFUSAL HERE ANY MORE — READ THIS BEFORE PUTTING ONE BACK.
        //
        // There used to be `if (!g.isActive) revert GameOver();`, and a long comment arguing it was
        // both necessary and unavoidable: a matured-but-unreserved bet's ROI was swept to the last
        // bettor by claimJackpot, and this refusal then made that loss permanent. The comment said
        // closing it "needs per-bet enumeration — exactly what this accumulator design exists to
        // avoid. That is a design decision, not a patch."
        //
        // The enumeration objection was inherited from Solana, where walking every bet is an
        // account-limit wall. On the EVM it is only gas, and gas on BSC is cents: jackpotOf now
        // subtracts matured-but-unreserved ROI for $0.01 at realistic game sizes. So the jackpot no
        // longer sweeps that money, it stays in the pool, and refusing to reserve it afterwards
        // would strand it for no reason.
        //
        // ⚠️ THE REFUSAL WAS ALSO GUARDING A REAL THEFT PATH, and that is now guarded by arithmetic
        // instead. The danger was that after a claim `pool == reserved`, so any further reserve drew
        // on money already promised to other players. Two things make that unreachable now:
        //   • claimJackpot leaves exactly the matured-but-unreserved total behind, so afterwards
        //     `pool - reserved` equals precisely what those bets are owed — no more, no less;
        //   • the SOLVENCY FLOOR below refuses anything beyond it, whatever the game's state.
        // A bet that had not matured by the end cannot slip through either: `cumulativePerBet` stops
        // moving when betting stops, so `accumulatedOf` gives the same answer an hour later as it did
        // at claim time, and the RoiNotReached check above still holds it out. No snapshot needed.
        //
        // ⇒ The upshot is the one that matters operationally: a matured player is paid whether or
        //   not our indexer is up. The contract stops depending on off-chain liveness for
        //   correctness — the same win as deleting the crank.

        // ⭐⭐ THE SOLVENCY FLOOR — audit finding #2, and the one thing that makes `reserved <= pool`
        // true BY CONSTRUCTION rather than by argument.
        //
        // Reserving is normally self-funding: a bet only matures once enough OTHER money arrived, so
        // reserving can never outrun the pool. The Salvador bounty is the one operation that spends
        // the slack ITSELF, and it prices that slack as `pool - reserved` — which still contains the
        // ROI of every bet that has MATURED but that nobody has reserved yet. reservedBalance is
        // what the contract has NOTICED it owes, not what it owes. So a bounty can pay away money
        // already promised, and the reserve that follows overshoots the pool.
        //
        // Insolvency needs U * bps > F * (10000 - bps), writing U for matured-unreserved ROI and F
        // for genuinely free slack. Solana's real caps put modes 1 and 2 at U > 32F and U > 19F,
        // out of reach. Insanity's table reaches 5000 bps, where it is just U > F — and MEASURED at
        // the constructed ratio (U/F ~= 32) the 1000 bps band breaks it too, so the trigger is 5.0%
        // per attempt, not 0.1%. See test/AuditSolvency.t.sol and test/InsanityProbe.t.sol.
        //
        // Refusing converts an UNRECOVERABLE insolvency (jackpotOf and claimJackpot both underflow
        // forever, no admin path, no upgrade path) into a temporary refusal that clears as soon as
        // more money arrives, and at worst degrades into the matured-but-unreserved loss documented
        // above. NotYet, not a hard error: the correct action really is to try again later.
        //
        // ⚠️ It is meant to be INERT on honest traffic — the slack after each reserve returns to
        // exactly netDeposit. Verified, not assumed: the full suite and 200k+ fuzzed calls of honest
        // play are unchanged by it. If this ever starts firing in a real game, something upstream is
        // wrong; do not "fix" it by removing the line.
        if (b.roiTarget > g.poolBalance - g.reservedBalance) revert NotYet();

        // Effects before the transfer. `withdrawn` is set alongside `reserved` because there is no
        // longer a gap between the two — it is kept rather than deleted so the Bet layout and every
        // consumer that reads it keep working.
        uint256 amount = b.roiTarget;
        b.reserved = true;
        b.withdrawn = true;
        b.accumulatedBase = acc;
        g.activeBetCount -= 1;
        g.poolBalance -= amount;

        // ⚠️ BOTH EVENTS, DELIBERATELY. This one call does what reserveRoi + withdraw used to do in
        // two transactions, and every off-chain consumer — the points ledger above all — was written
        // against that pair. Emitting one would silently drop half the ledger's input.
        emit RoiReserved(gameId, betId, b.player, amount);
        emit Withdrawn(gameId, betId, b.player, amount);

        // ⚠️ A player who cannot receive (blacklisted on a USDC-like, or a contract that reverts)
        // makes THIS bet unpayable and nothing else. That is why the indexer's sweep must be
        // per-bet rather than batched-atomic — one bad recipient must not stall everyone else's.
        IERC20(g.token).safeTransfer(b.player, amount);
    }

    /**
     * SALVADOR — reserve a matured bet AND pay the bounty to whoever's bet matured it, in one call.
     *
     * ⭐ NO OPERATOR. On Solana `pay_bounty` is operator-called: something off-chain works out who
     * the saviour was and submits an amount the contract can only sanity-check, and mode 2's
     * escalation is computed off-chain entirely. Here the CALLER NAMES the saviour and the contract
     * VERIFIES it in O(1), then computes the amount itself. Nothing is trusted and nobody has to be
     * running for a salvation to happen — the same class of win as deleting the crank.
     *
     * How the verification works: `cumulativeAtJoin` is the accumulator's value immediately after
     * each bet, and it only ever rises. Bet `betId` matured the instant the accumulator first
     * reached `threshold`. So bet `saviourBetId` is the one that did it precisely when its own
     * snapshot is at or above the threshold and its predecessor's is below. Two SLOADs, no iteration.
     */
    function reserveRoiWithSalvation(uint256 gameId, uint256 betId, uint256 saviourBetId)
        external payable nonReentrant
    {
        Game storage g = games[gameId];
        if (g.salvadorMode == 0) revert BadParams();
        // New salvations only while the game is live. After it ends the unreserved pool is empty,
        // so a bounty would be zero — and on mode 3 the caller would burn a VRF fee for nothing.
        if (!g.isActive || g.jackpotClaimed) revert GameOver();
        // ⭐ AND THE TIMER, NOT JUST isActive — audit finding #7. `isActive` stays true from creation
        // until claimJackpot executes; it is not the clock. Betting stops at timerEnd, but salvations
        // remained openable through JACKPOT_DELAY and for however long the winner took to claim — with
        // the pool frozen at its maximum and no further bets able to dilute it. Every saviour was
        // therefore strictly better off waiting until play had stopped.
        //
        // MEASURED: a tidy mode-1 game at Solana's own 300 bps ceiling, 60 bets, every matured bet
        // already reserved, jackpot 1,534,480 at expiry. Sixty salvations fired AFTER the timer
        // expired took it to 246,754 — 8,391 bps of the pot, moved after the game was decided. The
        // winner has no counter-move: they cannot out-bet it and claimJackpot blocks them for 300s.
        //
        // ⚠️ This blocks the BOUNTY, not the payout. reserveRoi is still open, so a matured bet is
        // still settled after expiry — only the salvation reward closes with the game.
        if (block.timestamp >= g.timerEnd) revert TimerExpired();

        Bet storage y = bets[gameId][betId];
        if (y.salvaged) revert AlreadyDone();   // one bounty per matured bet, ever

        // Threshold: the accumulator value at which this bet's ROI target was met.
        // ⚠️ NOT `- y.accumulatedBase`. That field is only ever written by reserveRoi, so it is zero
        // for any un-reserved bet and the subtraction was always a no-op — but it is NOT zero once
        // reserved, and this function must now work for bets that were already reserved (below).
        // Using the un-mutated form keeps the threshold the ORIGINAL maturity point either way.
        uint256 threshold = y.cumulativeAtJoin + y.roiTarget;

        // The saviour must be a LATER bet, must have crossed the line, and its predecessor must not
        // have — that triple is what makes it unique and unfakeable.
        if (saviourBetId <= betId || saviourBetId >= g.betCount) revert BadParams();
        if (bets[gameId][saviourBetId].cumulativeAtJoin < threshold) revert BadParams();
        if (bets[gameId][saviourBetId - 1].cumulativeAtJoin >= threshold) revert BadParams();

        // ⭐ THE BOUNTY IS DECOUPLED FROM RESERVING, and that is the whole point of this block.
        //
        // Previously this called reserveRoi unconditionally, which reverts on an already-reserved
        // bet — so whoever reserved FIRST destroyed the saviour's bounty permanently. And the
        // matured player has every incentive to get there first: withdraw() reserves as a side
        // effect and costs a quarter of the gas. Worse, reserveRoi is permissionless, so our own
        // indexer doing routine bookkeeping would have wiped out every bounty it touched.
        //
        // A bet that is already reserved or withdrawn has, by definition, matured — so the saviour
        // earned the bounty and there is simply nothing left to reserve.
        if (!y.reserved && !y.withdrawn) {
            // ⚠️ _reserveRoi, not reserveRoi — this function is already nonReentrant and the guard is
            // contract-wide, so calling the public wrapper would revert every mode-1/2 salvation.
            _reserveRoi(gameId, betId);   // reverts if not matured; pays the player
        }
        y.salvaged = true;

        // ─── Mode 3: the rate is unknowable in this transaction. ───
        // Note what has ALREADY happened above: the matured bet is reserved. Only the BOUNTY waits
        // on the oracle. A player's own ROI never depends on a third party being up.
        if (g.salvadorMode == 3) {
            _refund(_openSalvation(gameId, betId, saviourBetId));
            return;
        }
        _refund(0);   // modes 1/2 charge no fee; hand back anything sent by mistake

        // Rate: fixed, or escalating by step per salvation up to the cap. Computed ON-CHAIN — the
        // Solana version could only bound an operator-supplied number.
        uint256 bps = g.salvadorBps;
        if (g.salvadorMode == 2) {
            uint256 escalated = uint256(g.salvadorBps) + g.salvadorCount * uint256(g.salvadorStepBps);
            bps = escalated > g.salvadorCapBps ? g.salvadorCapBps : escalated;
        }

        // ⭐ Priced off jackpotOf, NOT `poolBalance - reservedBalance` — that difference IS audit
        // finding #2. The raw slack still contains the ROI of every bet that matured before anyone
        // reserved it, so pricing against it paid away money that was already someone's. Same rule
        // as the jackpot because it is now literally the same number.
        uint256 bounty = (jackpotOf(gameId) * bps) / BPS;
        if (bounty > 0) {
            address saviour = bets[gameId][saviourBetId].player;
            g.salvadorCount += 1;
            emit BountyAccrued(gameId, saviourBetId, saviour, betId, bounty);

            // ⭐ PAY IT NOW, like _reserveRoi does. A bounty used to be credited and left for a
            // SECOND transaction (claimBounty) — the same two-step that auto-payout was introduced
            // to remove for ROI, left in place on bounties by oversight when the port was made. The
            // first live game found it the obvious way: the user pressed the button, paid gas, and
            // nothing moved, because nothing was supposed to.
            //
            // ⛔ MODES 1 AND 2 ONLY, AND THAT ASYMMETRY IS DELIBERATE. Mode 3 settles inside the
            // Chainlink VRF callback under VRF_CALLBACK_GAS, where a token that reverts would burn
            // the randomness and strand the salvation on the fallback path — the exact failure this
            // state machine exists to survive. So Insanity keeps accrue-then-claim. Any UI must show
            // that difference rather than let a mode-3 saviour wait for money that is not coming.
            //
            // Effects before the interaction; the failure path puts it back and accrues instead.
            g.poolBalance -= bounty;
            if (_tryPay(IERC20(g.token), saviour, bounty)) {
                emit BountyClaimed(gameId, saviourBetId, saviour, bounty);
            } else {
                g.poolBalance += bounty;
                g.reservedBalance += bounty;
                bets[gameId][saviourBetId].bountyOwed += bounty;
            }
        }
    }

    // ─── Salvador mode 3 (Insanity) ──────────────────────────────────────────────────────────

    /**
     * The v14 table, copied value for value. EV = 0.5*20 + 0.3*50 + 0.15*150 + 0.049*1000 +
     * 0.001*5000 = 101.5 bps, which SALVADOR_FALLBACK_BPS deliberately approximates.
     */
    function _randomBps(uint256 rand) internal pure returns (uint16) {
        uint256 r = rand % 100_000;
        if (r < 50_000) return 20;     // 50.0%  -> 0.2%
        if (r < 80_000) return 50;     // 30.0%  -> 0.5%
        if (r < 95_000) return 150;    // 15.0%  -> 1.5%
        if (r < 99_900) return 1_000;  //  4.9%  -> 10%
        return 5_000;                  //  0.1%  -> 50%  (the jackpot roll)
    }

    /**
     * Record the salvation, then try to get a rate for it. Returns the fee actually spent so the
     * caller's excess can be handed back — Entropy does NOT refund overpayment itself.
     *
     * Both oracle calls are wrapped. The salvation row is written BEFORE either, so a dead oracle
     * leaves a settleable record rather than a lost bounty.
     */
    function _openSalvation(uint256 gameId, uint256 savedBetId, uint256 saviourBetId)
        private
        returns (uint256 feePaid)
    {
        Game storage g = games[gameId];
        uint256 sid = ++salvationCount;
        // Read ONCE: jackpotOf is O(betCount) and this is the only place the base is established.
        uint256 base = jackpotOf(gameId);
        salvations[sid] = PendingSalvation({
            gameId: gameId,
            savedBetId: savedBetId,
            saviourBetId: saviourBetId,
            openedAt: block.timestamp,
            baseAtOpen: base,
            armedAt: 0,
            resolved: false
        });
        // ⭐ Claim the ceiling immediately, so the NEXT salvation opened before this one settles sees
        // a base with this one's worst case already taken out of it. Without this the two snapshots
        // are identical and both get spent in full.
        g.pendingBountyMax += (base * INSANITY_MAX_BPS) / BPS;
        g.salvationPendingNum += 1;
        g.salvationLastActivity = block.timestamp;

        uint256 fee;
        try vrfWrapper.calculateRequestPriceNative(VRF_CALLBACK_GAS, VRF_NUM_WORDS) returns (uint256 f) {
            fee = f;
        } catch {
            emit SalvationRequestFailed(gameId, sid, saviourBetId);
            return 0;
        }
        if (msg.value < fee) revert InsufficientFee();

        // nativePayment: true — the wrapper is told explicitly, rather than inferred from which
        // function was called, because that is how VRFV2PlusClient encodes it.
        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, true);
        try vrfWrapper.requestRandomWordsInNative{value: fee}(
            VRF_CALLBACK_GAS, VRF_CONFIRMATIONS, VRF_NUM_WORDS, extraArgs
        ) returns (uint256 requestId) {
            requestToSalvation[requestId] = sid;
            // Armed HERE, not at maturity: the window a caller must wait out starts when the
            // request genuinely went out, so sitting on a request only delays their own bounty.
            salvations[sid].armedAt = block.timestamp;
            emit SalvationRequested(gameId, sid, requestId, saviourBetId);
            return fee;
        } catch {
            emit SalvationRequestFailed(gameId, sid, saviourBetId);
            return 0;   // the call reverted, so no value left the contract
        }
    }

    /**
     * The VRF wrapper's callback.
     *
     * ⚠️ MUST NOT REVERT on a rejection: a revert here burns fulfilled randomness and would strand
     * the salvation on the slow fallback for no reason, so an unknown or already-settled request is
     * a quiet return rather than a throw. The SENDER check is the one exception — a callback from
     * anyone else is forged, and accepting it would let a caller pick their own bounty rate.
     */
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != address(vrfWrapper)) revert NotYours();
        uint256 sid = requestToSalvation[requestId];
        if (sid == 0) return;                    // not a request we issued
        if (salvations[sid].resolved) return;    // the fallback got there first — never double-pay
        if (randomWords.length == 0) return;     // nothing to roll with; let the fallback clear it
        _settleSalvation(sid, _randomBps(randomWords[0]), false);
    }

    /**
     * The stall watchdog, and it is permissionless on purpose: if the oracle never answers, ANY
     * player can unstick the game and the pot. Nobody has to be running for it to clear.
     */
    function settleStalledSalvation(uint256 salvationId) external {
        PendingSalvation storage p = salvations[salvationId];
        if (p.gameId == 0 || p.resolved) revert AlreadyDone();

        // Normal: the request went out and has been unanswered for the timeout.
        bool armedReady = p.armedAt != 0 && block.timestamp >= p.armedAt + SALVATION_FALLBACK_TIMEOUT;
        // Never armed: the oracle could not be called AT ALL, so nothing was ever requested.
        // Anchored to this salvation's OWN openedAt rather than the game's last activity (as v13
        // does), so a busy game cannot keep resetting an unrelated stuck salvation's escape hatch.
        //
        // ⚠️ THIS WAS A LONGER "EMERGENCY" WINDOW (3600s) AND THAT WAS BACKWARDS. claimJackpot
        // unblocks at salvationLastActivity + SALVATION_JACKPOT_EXTRA (420s), so the hatch opened
        // 3,180s AFTER the pool it guards had already been swept. Every actor could behave
        // perfectly — call this at the earliest instant the contract permitted — and the bounty was
        // still destroyed: _settleSalvation sees !isActive, pays 0, and emits a SalvationSettled
        // event that reads as success. Unconditional for any game with under ~55 min of life left
        // when the request failed, and timerDuration is legal down to 300s.
        //
        // If the request never went out there is no oracle to wait for, so waiting LONGER than the
        // normal window protects nobody. 360 < 420 means this always clears before the pot opens,
        // exactly as the armed path does. Nothing to game either: forcing a failure buys the caller
        // the flat 100 bps against the table's 101.5 bps EV.
        bool neverArmedReady = p.armedAt == 0 && block.timestamp >= p.openedAt + SALVATION_FALLBACK_TIMEOUT;
        if (!armedReady && !neverArmedReady) revert NotYet();

        _settleSalvation(salvationId, SALVADOR_FALLBACK_BPS, true);
    }

    /// Closes a salvation exactly once and accrues the bounty. Rate comes from the oracle or the
    /// fallback; everything downstream is identical either way.
    function _settleSalvation(uint256 sid, uint16 bps, bool viaFallback) private {
        PendingSalvation storage p = salvations[sid];
        p.resolved = true;

        Game storage g = games[p.gameId];
        if (g.salvationPendingNum > 0) g.salvationPendingNum -= 1;
        g.salvationLastActivity = block.timestamp;

        // Release this salvation's claim on the pool. The released ceiling is always >= what is
        // actually paid below, so settling can only ever give headroom back.
        // ⚠️ Floored, not subtracted blindly: claimJackpot zeroes the running total, and a stall
        // settle or a late VRF callback can still arrive after that. An underflow here would revert
        // the callback, which burns the randomness and strands the salvation on the slow path — the
        // failure mode this whole state machine exists to avoid.
        uint256 held = (p.baseAtOpen * INSANITY_MAX_BPS) / BPS;
        g.pendingBountyMax = held >= g.pendingBountyMax ? 0 : g.pendingBountyMax - held;

        // If the game already ended, every token left is spoken for and there is no unreserved pool
        // to draw from. Resolve it anyway so nothing dangles, but pay nothing — accruing here would
        // take money already owed to other players. Same theft path reserveRoi guards against.
        uint256 amount = 0;
        if (g.isActive && !g.jackpotClaimed) {
            // Priced off the base snapshotted when the bounty was EARNED — see baseAtOpen. This
            // must stay O(1): it runs inside the VRF callback under VRF_CALLBACK_GAS.
            amount = (p.baseAtOpen * uint256(bps)) / BPS;
            // ⚠️ Then capped at what is actually free right now. The base is correct as of the
            // trigger, but other salvations can settle in between and take their own cut, so the
            // snapshot can outlive the money. O(1) on purpose — the raw slack, not jackpotOf; the
            // solvency floor in reserveRoi is the backstop for the rest.
            uint256 avail = g.poolBalance - g.reservedBalance;
            if (amount > avail) amount = avail;
            if (amount > 0) {
                g.reservedBalance += amount;
                // Counted only when a bounty actually accrued, matching modes 1/2 and the field's
                // own definition ("salvations paid so far"). It was unconditional here, so a
                // salvation that paid nothing still escalated a mode-2 game's rate.
                g.salvadorCount += 1;
                bets[p.gameId][p.saviourBetId].bountyOwed += amount;
                emit BountyAccrued(p.gameId, p.saviourBetId, bets[p.gameId][p.saviourBetId].player, p.savedBetId, amount);
            }
        }
        emit SalvationSettled(p.gameId, sid, bps, amount, viaFallback);
    }

    /// Entropy keeps any overpayment, so we compute the exact fee and return the rest ourselves.
    /// ⚠️ A failed refund REVERTS the whole salvation rather than silently pocketing the change.
    /// That is deliberate: the amount sent is entirely the caller's choice, and a caller who sends
    /// exactly getFeeV2() is never refunded at all, so a contract with no receive() can still
    /// trigger salvations. Loudly refusing beats quietly keeping someone's money.
    function _refund(uint256 spent) private {
        uint256 back = msg.value - spent;
        if (back > 0) {
            (bool ok, ) = msg.sender.call{value: back}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Bounties are reserved onto the saviour's bet and pulled by the player, never pushed — nothing
    /// can strand because a recipient could not receive.
    function claimBounty(uint256 gameId, uint256 betId) external nonReentrant {
        Bet storage b = bets[gameId][betId];
        if (b.player != msg.sender) revert NotYours();
        uint256 amount = b.bountyOwed;
        if (amount == 0) revert AlreadyDone();

        Game storage g = games[gameId];
        b.bountyOwed = 0;
        g.poolBalance -= amount;
        g.reservedBalance -= amount;

        IERC20(g.token).safeTransfer(msg.sender, amount);
        emit BountyClaimed(gameId, betId, msg.sender, amount);
    }

    /**
     * One call instead of Solana's reserve-then-withdraw pair — the kind of friction the account
     * model imposed and the EVM does not.
     *
     * ⭐ AND NOW IT IS ZERO CALLS — see _reserveRoi. The reserve/withdraw pair collapsed entirely
     * when reserving started paying; `withdraw` survives above only as an alias so existing ABIs and
     * front-ends keep working.
     */

    /**
     * The last bettor takes whatever is not spoken for. The delay exists so a bet broadcast just
     * before expiry still has time to land.
     */
    function claimJackpot(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        if (!g.isActive || g.jackpotClaimed) revert GameOver();
        if (block.timestamp < g.timerEnd + JACKPOT_DELAY) revert NotYet();
        // A salvation in flight has an unknown claim on the unreserved pool, so sweeping now could
        // pay the jackpot money a saviour is owed. Blocks until it clears or the window lapses.
        if (g.salvationPendingNum > 0 && block.timestamp < g.salvationLastActivity + SALVATION_JACKPOT_EXTRA) revert NotYet();
        if (msg.sender != g.lastBettor) revert NotYours();

        // Any salvation still pending at this point has already outlived its window (the check above
        // only holds the pot for SALVATION_JACKPOT_EXTRA) and _settleSalvation pays nothing once the
        // game is over — so its reserved ceiling is dead money. Release it BEFORE pricing the pot, or
        // it would be stranded in the contract with nobody able to claim it, ever.
        g.pendingBountyMax = 0;

        // ⚠️⚠️ READ THIS BEFORE TRUSTING THE LINE BELOW. The comment that stood here claimed that
        // "ROI already earned but not yet reserved stays in the pool for its owner", and called this
        // "the one O(betCount) read in this function". BOTH STATEMENTS WERE FALSE. They described the
        // enumerating jackpotOf that was reverted in b172e53; the comment survived the revert and
        // documented a protection the code no longer had — found 2026-08-19, after the first live
        // mainnet game.
        //
        // What actually happens: jackpotOf is O(1) (`pool - reserved - pendingBountyMax`), so a bet
        // that has MATURED but not yet been reserved is swept to the last bettor here, and
        // afterwards `poolBalance == reservedBalance`, so its own reserveRoi fails the solvency floor
        // FOREVER. Not a delay — a loss.
        //
        // ⭐ THAT IS A DELIBERATE TRADE, TAKEN 2026-08-19, AND ITS PRICE IS A LIVENESS DEPENDENCY.
        // Enumerating here would make the loss impossible, but the loop grows with betCount and near
        // ~10k bets it approaches the block gas limit — turning a rare, bounded loss into a pot that
        // can never be claimed at all. We keep O(1) and cover the gap OFF chain instead:
        //   • auto-payout means a matured bet is settled by any permissionless call, instantly;
        //   • JACKPOT_DELAY (300s) is the grace window — a bet maturing one second before timerEnd
        //     still has five minutes before anyone may claim;
        //   • indexer/reserve.js sweeps expired games FIRST and alerts high-severity if it cannot.
        // ⛔ SO THE CRANK IS LOAD-BEARING FOR PLAYER MONEY. If it stops for longer than the delay
        // while a game ends, players lose ROI. It must run on the box, funded and monitored — not on
        // someone's laptop. This is the same dependency shape that cost 5 SOL on Solana; the
        // difference is that here it is written down and alerted on rather than assumed.
        uint256 jackpot = jackpotOf(gameId);
        g.jackpotClaimed = true;
        g.isActive = false;      // set BEFORE the transfer: no reserve or bet can slip in behind it
        g.poolBalance -= jackpot;

        if (jackpot > 0) IERC20(g.token).safeTransfer(msg.sender, jackpot);
        emit JackpotClaimed(gameId, msg.sender, jackpot);
    }
}

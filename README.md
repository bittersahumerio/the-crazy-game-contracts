# The Crazy Game: contracts

The on-chain game behind [The Crazy Game](https://thecrazygame.fun): a last-bettor-wins pot game, live on Arc.

Anyone can open a pot on any ERC-20 token. Every bet resets the clock, adds to the pot and accrues ROI to the bets
placed before it. A bet that reaches its ROI target is paid out. When the clock runs out, the last bettor takes the
pot. Nobody takes the other side: players play each other, and the contract takes a platform fee.

**`CrazyGame` has no owner, no admin functions and no upgrade path.** Once deployed, nobody can pause it, change a
running game or move players' money. The only privileged callers are the VRF oracle's callback and a game's own last
bettor claiming the pot.

## Deployment

| Chain | Contract | Address |
|---|---|---|
| Arc mainnet | `CrazyGame` v3, current (2026-10-12) | [`0x5d127e4aA215f86089Edd52D107c3dA83e3519e2`](https://arc-scan.org/address/0x5d127e4aA215f86089Edd52D107c3dA83e3519e2) |
| Arc mainnet | `CrazyGame` v2 (2026-09-16 to 2026-10-12) | [`0x003912feB558f0dFB687B57020fad10f47c6a27f`](https://arc-scan.org/address/0x003912feB558f0dFB687B57020fad10f47c6a27f) |

v2's games are finished. They stay on chain, and the site keeps them under their own links
(`thecrazygame.fun/arc/v2/<id>`). Its source is the previous commit of this repository, `65f2d34`.

A game's pot is in the token it is hosted on. On Arc that can be any coin, or USDC itself. The same contract runs on
other EVM chains, configured through its constructor.

### Check that this source is what is deployed

```bash
forge build
node verify-deployed.mjs https://<an Arc mainnet RPC URL>
```

The script compares the compiled runtime code with the code at the current address above (pass another
address as a second argument: v2's, with `65f2d34` checked out). It masks two things that
legitimately differ: the constructor's immutable values, and the compiler's metadata hash at the very end (the
published files carry a different licence header from the build that was deployed). Everything that executes must
match byte for byte.

## What changed in v3

A Salvador bounty is now counted on the pot as it stood **before the saviour's own bet joined it**
(`_bountyBase` in `CrazyGame.sol`), in all three modes. Before, the saviour's stake was part of the pot that its
bounty was a percentage of. So one large bet could mature a cohort of small ones and take a share of its own
money back each time. `test/HarvestBase.t.sol` replays that on a realistic game: with a cohort of 60 minimum bets
at 200 bps, 69% of the pot could be drained before the change and 24% after.

Every other constructor argument is the same as v2's. The same source runs on HyperEVM.

## What is here

- `contracts/CrazyGame.sol`: the game. Pots, bets, the timer, ROI accrual and payout, the jackpot, host fees and
  Salvador bounties: a bettor whose bet carries an earlier bet to its target is paid a bounty, fixed, progressive,
  or random in Insanity mode.
- `contracts/FeeTiers.sol`: the per-coin platform-fee discounts. It can only lower a fee, never raise one. It holds
  no funds, and it cannot touch a game that already exists.
- `test/`: Foundry tests, including fuzzing and invariant tests, and `HarvestBase.t.sol` for the v3 change.
- `script/`: Foundry deploy and lifecycle scripts.

Randomness for Insanity mode comes from Chainlink VRF v2.5. On a chain without VRF, such as Arc, `createGame`
refuses Insanity mode rather than run it without a fair source of randomness.

## Build and test

Requires [Foundry](https://book.getfoundry.sh).

```bash
forge install foundry-rs/forge-std@c179529c064588ede54a0661ec3cc98219460d07 OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git
forge build
forge test --no-match-path test/ArcTollyFork.t.sol
```

Compiler settings are in `foundry.toml`: solc 0.8.24, via-IR, optimizer at 200 runs. `test/ArcTollyFork.t.sol` runs
against a fork of Arc mainnet and needs an RPC URL, so it is left out above.

## What is not here

This repository holds the contracts as deployed on Arc: first published on 2026-09-18 (v2), updated on
2026-10-12 (v3). The rest of the product
lives in private repositories: the indexer that runs games on Arc, the Telegram wallet
([@tcgwalletbot](https://t.me/tcgwalletbot)), the website and its API. So does the full development history.

## Licence

[Business Source License 1.1](LICENSE). You may read, copy, modify and test this code, and use it in non-production
settings. Production use needs a licence from us until **2028-09-18**, when this version becomes available under
the GNU General Public License v2.0 or later.

Found a problem? Please report it privately to [@thecraziestgame](https://x.com/thecraziestgame) on X before
disclosing it anywhere public.

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * FeeTiers — which coins pay less than CrazyGame's default platform fee.
 *
 * Solana charges the platform fee PER TOKEN: 5% for a self-serve onboarded coin, 3% for the curated
 * ones, set by the operator in the token's config. The EVM port flattened that to a single
 * immutable number. Two of the three tiers need no help from anybody — the default is the
 * constructor argument, and the curated coins are a list fixed at deployment — but the middle tier,
 * "launched at our own pad", is not something the chain can see: our launches mark themselves with
 * a `commissionReceiver`, and neither flap's Portal nor the token it deploys exposes it. So one
 * per-coin record has to be written by us, and this is the smallest thing that can hold it.
 *
 * ⛔ WHAT THIS CONTRACT CANNOT DO, WHICH IS THE POINT OF IT BEING SEPARATE:
 *    · It cannot RAISE a fee. CrazyGame clamps the answer to [MIN_FEE_BPS, platformFeeBps].
 *    · It cannot touch money, pause anything, or alter a game. It holds no funds and the game
 *      contract exposes nothing to it.
 *    · It cannot reach a game that already exists: createGame snapshots the fee into the game, so a
 *      change here only ever affects the NEXT game on that coin.
 *    Which leaves exactly one thing a stolen owner key can do: give somebody a discount. That is
 *    the trade for keeping CrazyGame itself free of an owner.
 *
 * ⚠️ An unset coin returns 0, meaning "no tier" — CrazyGame reads that as the default. Zero is not
 *    a free game and cannot be made into one; the clamp refuses anything under the floor.
 */
contract FeeTiers {
    address public owner;

    /// token => fee in basis points. 0 = no tier.
    mapping(address => uint256) public feeBps;

    event FeeSet(address indexed token, uint256 bps);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error BadParams();

    constructor(address _owner) {
        if (_owner == address(0)) revert BadParams();
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// The one function CrazyGame calls. Deliberately total: every address has an answer.
    function feeFor(address token) external view returns (uint256) {
        return feeBps[token];
    }

    function setFee(address token, uint256 bps) public onlyOwner {
        // 10_000 is the same ceiling CrazyGame's own constructor enforces on itself. Anything the
        // game will not accept is refused here too, so a mistake is caught where it is made rather
        // than silently ignored at the next createGame.
        if (token == address(0) || bps > 1_000) revert BadParams();
        feeBps[token] = bps;
        emit FeeSet(token, bps);
    }

    /// A launch writes one entry; onboarding a list writes several. Same rules either way.
    function setFees(address[] calldata tokens, uint256[] calldata bps) external onlyOwner {
        if (tokens.length != bps.length) revert BadParams();
        for (uint256 i; i < tokens.length; i++) setFee(tokens[i], bps[i]);
    }

    /**
     * Hand the registry to a new key. ⛔ address(0) is REFUSED: renouncing would freeze every tier
     * as it stands forever, and a registry nobody can correct is worse than one somebody can — the
     * clamp already bounds what "somebody" is able to do.
     */
    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert BadParams();
        emit OwnerChanged(owner, to);
        owner = to;
    }
}

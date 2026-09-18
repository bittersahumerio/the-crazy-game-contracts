// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IConsumerCallback {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

/**
 * A stand-in for the Chainlink VRF v2.5 wrapper (direct funding, native payment).
 *
 * It implements only the two methods CrazyGame actually calls, which is enough: a Solidity
 * interface is just a call encoding, so casting this address to IVRFV2PlusWrapper works at runtime.
 * Implementing the full wrapper would be a lot of dead code to maintain for no extra coverage.
 *
 * ⚠️ The `breakFee` / `breakRequest` switches are the most important thing in this file. They test
 * an oracle that is DOWN — the exact condition under which ORAO quietly stopped working on Solana
 * for months, and the reason the fallback and emergency windows exist at all. This mock replaced a
 * Pyth Entropy mock when Pyth turned out not to be deployed on BNB Chain; the switches came with it
 * unchanged, because the failure they model has nothing to do with which vendor is behind them.
 */
contract MockVRFWrapper {
    uint256 public reqCount;
    uint256 public fee = 0.0001 ether;
    bool public breakFee;
    bool public breakRequest;

    mapping(uint256 => address) public requester;
    /// What the consumer asked for, so tests can assert we pass the right callback gas through.
    mapping(uint256 => uint32) public callbackGasOf;
    mapping(uint256 => bytes)  public extraArgsOf;

    function setFee(uint256 f) external { fee = f; }
    function setBroken(bool feeDown, bool requestDown) external {
        breakFee = feeDown;
        breakRequest = requestDown;
    }

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        require(!breakFee, "vrf: price unavailable");
        return fee;
    }

    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16,
        uint32,
        bytes calldata extraArgs
    ) external payable returns (uint256) {
        require(!breakRequest, "vrf: requests down");
        require(msg.value >= fee, "vrf: underpaid");
        // Ids start at 1: the consumer treats 0 as "not a request of ours", and a real wrapper's
        // ids are large and non-sequential, so zero can never legitimately appear.
        reqCount += 1;
        requester[reqCount] = msg.sender;
        callbackGasOf[reqCount] = callbackGasLimit;
        extraArgsOf[reqCount] = extraArgs;
        return reqCount;
    }

    /// Test hook — deliver a callback exactly the way the real wrapper does, from this address, so
    /// the consumer's `msg.sender == vrfWrapper` check is genuinely exercised.
    function fulfill(uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IConsumerCallback(requester[requestId]).rawFulfillRandomWords(requestId, words);
    }

    /// Deliver an EMPTY word array — a malformed fulfilment the consumer must survive rather than
    /// revert on, since reverting would burn the randomness and strand the salvation.
    function fulfillEmpty(uint256 requestId) external {
        IConsumerCallback(requester[requestId]).rawFulfillRandomWords(requestId, new uint256[](0));
    }

    /// How much native currency this mock has taken in fees — used to assert we never overpay.
    function feesCollected() external view returns (uint256) { return address(this).balance; }
}

//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

/// @dev Settable Chainlink V3-style aggregator for tests and testnet.
///      Reports a fresh `updatedAt` (now) by default so time-warping tests
///      don't trip staleness; pin it explicitly to simulate a stale feed.
contract MockAggregator {
    int256 public answer;
    uint256 public fixedUpdatedAt;
    bool public useFixedUpdatedAt;
    uint8 public immutable decimals;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
    }

    function set(int256 _answer) external {
        answer = _answer;
        useFixedUpdatedAt = false;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        fixedUpdatedAt = _updatedAt;
        useFixedUpdatedAt = true;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        uint256 updatedAt = useFixedUpdatedAt
            ? fixedUpdatedAt
            : block.timestamp;
        return (1, answer, updatedAt, updatedAt, 1);
    }

    /// @dev Legacy interface, for parity checks against upstream oracles.
    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// New contract (no upstream counterpart). Fixed-price sale of
// treasury-curated premium .hawk names.
//
// Custody model: the contract OWNS the listed names — they are registered
// straight to it by the deploy batch, so no approvals or multisig ceremony
// are needed to open the shop. Buyers pay in USDC (exact, 6 decimals,
// ceil-rounded from the attoUSD list price) or ETH (Chainlink-priced with
// the same staleness bound as HawkPriceOracle). Proceeds forward to the
// Safe within the buy transaction — the contract never custodies funds.
// The Safe (and only the Safe) can reprice, relist, or pull any name.
//
// Names held here still expire on their registrar schedule; renewal is
// permissionless via the controller, so the treasury can renew without
// touching this contract.
//
// Reentrancy: all state (priceOf) zeroes before any external call; ERC-721
// moves use transferFrom (no receiver callback); USDC has no hooks.

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IERC721Minimal {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IAggregatorMinimal {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

contract HawkPremiumSale {
    address public immutable safe;
    IERC721Minimal public immutable registrar;
    IERC20Minimal public immutable usdc;
    IAggregatorMinimal public immutable feed;
    uint256 public immutable maxFeedAge;

    /// @notice List price in attoUSD (1e18 = $1) by token id; 0 = not for sale.
    mapping(uint256 => uint256) public priceOf;

    event Listed(string label, uint256 priceAttoUSD);
    event Purchased(
        string label,
        address indexed buyer,
        uint256 priceAttoUSD,
        bool paidInUSDC,
        uint256 amountPaid
    );
    event Delisted(string label, address to);

    error NotSafe();
    error NotForSale();
    error InsufficientPayment();
    error StaleFeed();
    error LengthMismatch();

    modifier onlySafe() {
        if (msg.sender != safe) revert NotSafe();
        _;
    }

    struct Config {
        address safe;
        IERC721Minimal registrar;
        IERC20Minimal usdc;
        IAggregatorMinimal feed;
        uint256 maxFeedAge;
        string[] labels;
        uint256[] pricesAttoUSD;
    }

    constructor(Config memory cfg) {
        if (cfg.labels.length != cfg.pricesAttoUSD.length) {
            revert LengthMismatch();
        }
        safe = cfg.safe;
        registrar = cfg.registrar;
        usdc = cfg.usdc;
        feed = cfg.feed;
        maxFeedAge = cfg.maxFeedAge;
        for (uint256 i = 0; i < cfg.labels.length; i++) {
            priceOf[tokenId(cfg.labels[i])] = cfg.pricesAttoUSD[i];
            emit Listed(cfg.labels[i], cfg.pricesAttoUSD[i]);
        }
    }

    /// @notice The ERC-721 token id (labelhash) for a .hawk second-level name.
    function tokenId(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    /// @notice USDC amount (6 decimals) to buy `label`, ceil-rounded.
    function priceInUSDC(string memory label) public view returns (uint256) {
        uint256 p = priceOf[tokenId(label)];
        if (p == 0) revert NotForSale();
        return (p + 1e12 - 1) / 1e12;
    }

    /// @notice Wei amount to buy `label` at the current feed price.
    function priceInWei(string memory label) public view returns (uint256) {
        uint256 p = priceOf[tokenId(label)];
        if (p == 0) revert NotForSale();
        return _toWei(p);
    }

    function buyWithUSDC(string calldata label) external {
        uint256 id = tokenId(label);
        uint256 p = priceOf[id];
        if (p == 0) revert NotForSale();
        uint256 amount = (p + 1e12 - 1) / 1e12;
        priceOf[id] = 0;
        require(usdc.transferFrom(msg.sender, safe, amount), "usdc transfer");
        registrar.transferFrom(address(this), msg.sender, id);
        emit Purchased(label, msg.sender, p, true, amount);
    }

    function buyWithETH(string calldata label) external payable {
        uint256 id = tokenId(label);
        uint256 p = priceOf[id];
        if (p == 0) revert NotForSale();
        uint256 weiAmount = _toWei(p);
        if (msg.value < weiAmount) revert InsufficientPayment();
        priceOf[id] = 0;
        registrar.transferFrom(address(this), msg.sender, id);
        _send(safe, weiAmount);
        if (msg.value > weiAmount) _send(msg.sender, msg.value - weiAmount);
        emit Purchased(label, msg.sender, p, false, weiAmount);
    }

    /// @notice Set (or reinstate) a list price. Safe-only.
    function setPrice(
        string calldata label,
        uint256 priceAttoUSD
    ) external onlySafe {
        priceOf[tokenId(label)] = priceAttoUSD;
        emit Listed(label, priceAttoUSD);
    }

    /// @notice Pull a name out of the shop (delists it). Safe-only.
    function withdrawName(string calldata label, address to) external onlySafe {
        uint256 id = tokenId(label);
        priceOf[id] = 0;
        registrar.transferFrom(address(this), to, id);
        emit Delisted(label, to);
    }

    /// @notice Sweep any stray ETH. Safe-only.
    function recoverETH(address to) external onlySafe {
        _send(to, address(this).balance);
    }

    function _toWei(uint256 attoUSD) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > maxFeedAge) {
            revert StaleFeed();
        }
        // answer is USD/ETH with 8 decimals → wei = attoUSD * 1e8 / answer.
        return (attoUSD * 1e8 + uint256(answer) - 1) / uint256(answer);
    }

    function _send(address to, uint256 value) internal {
        (bool ok, ) = to.call{value: value}("");
        require(ok, "eth send");
    }
}

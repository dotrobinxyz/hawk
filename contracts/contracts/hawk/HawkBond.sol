// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {HawkMulDiv} from "./HawkMulDiv.sol";

// New contract (no upstream counterpart). Bonded operators — measurable
// skin in the game behind a fleet.
//
// An operator locks USDC or $HAWK behind their 2LD name. Every agent under
// that name can then show "bonded: $X" in the directory and verify API —
// a credibility signal nobody can fake, withdrawable only through a public
// 7-day window (the request itself is an on-chain event, so a fleet whose
// bond is on the way out is visibly on the way out).
//
// Fees (locked with the operator): 2% one-time on USDC deposits — half
// accrues toward the public HAWK buyback-and-burn, half to the treasury
// Safe — and 1% on $HAWK deposits, burned directly. Bond value is always
// reported in USD: USDC 1:1, HAWK via the live pool price × the ETH/USD
// feed.
//
// The USDC→HAWK buyback route (a Uniswap v4 path) is set once by the
// owner; until then USDC fee-halves simply accumulate here. The owner has
// no other power — bonds themselves are untouchable by anyone but the
// name's current owner.

interface IRegistrarBond {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IWrapperBond {
    function ownerOf(uint256 id) external view returns (address);
}

interface IERC20Bond {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IAggregatorBond {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

interface IStateViewBond {
    function getSlot0(
        bytes32 poolId
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IUniversalRouterBond {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

contract HawkBond {
    using HawkMulDiv for uint256;

    /// @dev Uniswap v4 PoolKey, stored unpacked for the buyback route.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    uint256 public constant MIN_BOND_ATTOUSD = 100e18; // $100 minimum, net of fee
    uint256 public constant USDC_FEE_BPS = 200; // 2% one-time on USDC bonds
    uint256 public constant HAWK_FEE_BPS = 100; // 1% one-time on HAWK bonds
    uint256 public constant WITHDRAW_DELAY = 7 days;
    uint256 public constant MIN_BUYBACK_USDC = 25e6; // crank threshold: $25

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IRegistrarBond public immutable registrar;
    IWrapperBond public immutable wrapper;
    bytes32 public immutable baseNode;
    IERC20Bond public immutable usdc;
    IERC20Bond public immutable hawk;
    IAggregatorBond public immutable feed;
    uint256 public immutable maxFeedAge;
    IStateViewBond public immutable stateView;
    bytes32 public immutable hawkPoolId; // HAWK/ETH pool, for USD pricing
    address public immutable treasury;
    IUniversalRouterBond public immutable router;

    struct Bond {
        address asset; // usdc or hawk; one asset per name
        uint256 amount; // active bonded amount (net of fees)
        uint64 since;
        uint256 pendingAmount; // requested for withdrawal
        uint64 unlockAt; // when pendingAmount becomes claimable
    }

    /// @notice Bond per operator name (2LD node).
    mapping(bytes32 => Bond) public bonds;

    /// @notice USDC fee-halves accumulated toward the public buyback.
    uint256 public buybackPool;
    uint256 public totalHawkBurned;

    address public owner;
    // Buyback route: USDC -> ETH -> HAWK through Uniswap v4.
    PoolKey public routeUsdcEth;
    PoolKey public routeEthHawk;
    bool public routeSet;

    uint256 private _entered = 1;

    event Bonded(
        bytes32 indexed node,
        address indexed asset,
        uint256 amountNet,
        uint256 fee,
        address by
    );
    event WithdrawRequested(bytes32 indexed node, uint256 amount, uint64 unlockAt);
    event Withdrawn(bytes32 indexed node, address to, uint256 amount);
    event BuybackExecuted(address indexed caller, uint256 usdcIn, uint256 hawkBurned);
    event RouteSet(bytes32 usdcEthId, bytes32 ethHawkId);
    event OwnerChanged(address owner);

    error NotOwner();
    error NotNameOwner();
    error WrongAsset();
    error BondTooSmall();
    error NothingPending();
    error StillLocked();
    error StaleFeed();
    error RouteNotSet();
    error PotTooSmall();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @dev Bundled so the constructor stays within stack limits.
    struct Config {
        address owner;
        IRegistrarBond registrar;
        IWrapperBond wrapper;
        bytes32 baseNode;
        IERC20Bond usdc;
        IERC20Bond hawk;
        IAggregatorBond feed;
        uint256 maxFeedAge;
        IStateViewBond stateView;
        bytes32 hawkPoolId;
        address treasury;
        IUniversalRouterBond router;
    }

    constructor(Config memory cfg) {
        owner = cfg.owner;
        registrar = cfg.registrar;
        wrapper = cfg.wrapper;
        baseNode = cfg.baseNode;
        usdc = cfg.usdc;
        hawk = cfg.hawk;
        feed = cfg.feed;
        maxFeedAge = cfg.maxFeedAge;
        stateView = cfg.stateView;
        hawkPoolId = cfg.hawkPoolId;
        treasury = cfg.treasury;
        router = cfg.router;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // Bonding
    // ------------------------------------------------------------------

    /// @notice The effective owner of a name: the registrar holder, looked
    ///         through the wrapper when the name is wrapped.
    function nameOwner(uint256 labelhash) public view returns (address o) {
        o = registrar.ownerOf(labelhash);
        if (o == address(wrapper)) {
            o = wrapper.ownerOf(uint256(_node(labelhash)));
        }
    }

    /// @notice Bond USDC behind `labelhash`'s name. 2% fee: half accrues to
    ///         the public buyback, half goes to the treasury.
    function bondUSDC(uint256 labelhash, uint256 amount) external nonReentrant {
        bytes32 node = _requireOwner(labelhash);
        Bond storage b = bonds[node];
        if (b.amount + b.pendingAmount > 0 && b.asset != address(usdc)) revert WrongAsset();

        uint256 fee = (amount * USDC_FEE_BPS) / 10_000;
        uint256 net = amount - fee;
        if (_usdcToUsd(b.amount + net) < MIN_BOND_ATTOUSD) revert BondTooSmall();

        require(usdc.transferFrom(msg.sender, address(this), amount), "usdc in");
        uint256 half = fee / 2;
        buybackPool += half;
        if (fee - half > 0) {
            require(usdc.transfer(treasury, fee - half), "usdc treasury");
        }

        b.asset = address(usdc);
        b.amount += net;
        if (b.since == 0) b.since = uint64(block.timestamp);
        emit Bonded(node, address(usdc), net, fee, msg.sender);
    }

    /// @notice Bond $HAWK behind `labelhash`'s name — half the fee (1%),
    ///         and the fee burns directly.
    function bondHAWK(uint256 labelhash, uint256 amount) external nonReentrant {
        bytes32 node = _requireOwner(labelhash);
        Bond storage b = bonds[node];
        if (b.amount + b.pendingAmount > 0 && b.asset != address(hawk)) revert WrongAsset();

        uint256 fee = (amount * HAWK_FEE_BPS) / 10_000;
        uint256 net = amount - fee;
        if (_hawkToUsd(b.amount + net) < MIN_BOND_ATTOUSD) revert BondTooSmall();

        require(hawk.transferFrom(msg.sender, address(this), amount), "hawk in");
        if (fee > 0) {
            require(hawk.transfer(DEAD, fee), "hawk burn");
            totalHawkBurned += fee;
        }

        b.asset = address(hawk);
        b.amount += net;
        if (b.since == 0) b.since = uint64(block.timestamp);
        emit Bonded(node, address(hawk), net, fee, msg.sender);
    }

    /// @notice Start the public 7-day exit for part or all of a bond. The
    ///         event is the point: a leaving bond is visibly leaving.
    function requestWithdraw(uint256 labelhash, uint256 amount) external {
        bytes32 node = _requireOwner(labelhash);
        Bond storage b = bonds[node];
        require(amount > 0 && amount <= b.amount, "bad amount");
        b.amount -= amount;
        b.pendingAmount += amount;
        b.unlockAt = uint64(block.timestamp + WITHDRAW_DELAY);
        emit WithdrawRequested(node, amount, b.unlockAt);
    }

    /// @notice Claim a matured withdrawal — paid to the name's CURRENT
    ///         owner (bonds ride with the name, like everything else).
    function claimWithdraw(uint256 labelhash) external nonReentrant {
        bytes32 node = _requireOwner(labelhash);
        Bond storage b = bonds[node];
        if (b.pendingAmount == 0) revert NothingPending();
        if (block.timestamp < b.unlockAt) revert StillLocked();
        uint256 amount = b.pendingAmount;
        b.pendingAmount = 0;
        b.unlockAt = 0;
        if (b.amount == 0 && amount > 0) b.since = 0;
        require(IERC20Bond(b.asset).transfer(msg.sender, amount), "payout");
        emit Withdrawn(node, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Valuation
    // ------------------------------------------------------------------

    /// @notice Bond state for a name, with its live USD value (18 dec).
    function bondOf(
        bytes32 node
    )
        external
        view
        returns (
            address asset,
            uint256 amount,
            uint256 usdValue,
            uint64 since,
            uint256 pendingAmount,
            uint64 unlockAt
        )
    {
        Bond storage b = bonds[node];
        uint256 usd = 0;
        if (b.amount > 0) {
            usd = b.asset == address(usdc) ? _usdcToUsd(b.amount) : _hawkToUsd(b.amount);
        }
        return (b.asset, b.amount, usd, b.since, b.pendingAmount, b.unlockAt);
    }

    function _usdcToUsd(uint256 amount) internal pure returns (uint256) {
        return amount * 1e12; // 6 dec -> attoUSD
    }

    /// @dev HAWK -> ETH via pool spot, ETH -> USD via the feed.
    function _hawkToUsd(uint256 amount) internal view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = stateView.getSlot0(hawkPoolId);
        // HAWK is currency1: price token1/token0 = HAWK per ETH (both 18 dec).
        uint256 hawkPerEthWad = uint256(sqrtPriceX96)
            .mulDiv(uint256(sqrtPriceX96), 1 << 96)
            .mulDiv(1e18, 1 << 96);
        if (hawkPerEthWad == 0) return 0;
        uint256 ethWad = amount.mulDiv(1e18, hawkPerEthWad);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > maxFeedAge) revert StaleFeed();
        return ethWad.mulDiv(uint256(answer), 1e8);
    }

    // ------------------------------------------------------------------
    // Buyback — public crank once the route exists
    // ------------------------------------------------------------------

    /// @notice Set the USDC→ETH→HAWK route. Owner-only, and the owner's
    ///         ONLY power besides handing itself over.
    function setRoute(PoolKey calldata usdcEth, PoolKey calldata ethHawk) external onlyOwner {
        routeUsdcEth = usdcEth;
        routeEthHawk = ethHawk;
        routeSet = true;
        emit RouteSet(_poolId(usdcEth), _poolId(ethHawk));
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerChanged(_owner);
    }

    /// @dev Mirrors the v4 periphery PathKey for exact-in multi-hop swaps.
    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    uint256 public constant BUYBACK_SLIPPAGE_BPS = 500; // 5% off spot

    /// @notice Swap the accumulated USDC fee pool into $HAWK and burn it.
    ///         Callable by anyone once the pool holds $25. A spot-derived
    ///         minimum-out makes sandwiching the public crank unprofitable.
    function buyback() external nonReentrant returns (uint256 burned) {
        if (!routeSet) revert RouteNotSet();
        uint256 usdcIn = buybackPool;
        if (usdcIn < MIN_BUYBACK_USDC) revert PotTooSmall();
        buybackPool = 0;

        uint256 minOut = (quoteHawkForUsdc(usdcIn) * (10_000 - BUYBACK_SLIPPAGE_BPS)) / 10_000;

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(address(0), routeUsdcEth.fee, routeUsdcEth.tickSpacing, routeUsdcEth.hooks, "");
        path[1] = PathKey(address(hawk), routeEthHawk.fee, routeEthHawk.tickSpacing, routeEthHawk.hooks, "");

        // Actions: SWAP_EXACT_IN (0x07), SETTLE (0x0b, router pays from its
        // own balance, open delta), TAKE (0x0e, full output to this contract).
        bytes memory actions = hex"070b0e";
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputParams({
                currencyIn: address(usdc),
                path: path,
                amountIn: uint128(usdcIn),
                amountOutMinimum: uint128(minOut)
            })
        );
        params[1] = abi.encode(address(usdc), uint256(0), false); // OPEN_DELTA, router pays
        params[2] = abi.encode(address(hawk), address(this), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        require(usdc.transfer(address(router), usdcIn), "usdc to router");
        router.execute(hex"10", inputs, block.timestamp);

        burned = hawk.balanceOf(address(this));
        if (burned < minOut) revert PotTooSmall();
        require(hawk.transfer(DEAD, burned), "hawk burn");
        totalHawkBurned += burned;
        emit BuybackExecuted(msg.sender, usdcIn, burned);
    }

    /// @notice HAWK received for `usdcAmount` at spot (USDC→USD→ETH→HAWK).
    function quoteHawkForUsdc(uint256 usdcAmount) public view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > maxFeedAge) revert StaleFeed();
        uint256 ethWad = _usdcToUsd(usdcAmount).mulDiv(1e8, uint256(answer));
        (uint160 sqrtPriceX96, , , ) = stateView.getSlot0(hawkPoolId);
        uint256 hawkPerEthWad = uint256(sqrtPriceX96)
            .mulDiv(uint256(sqrtPriceX96), 1 << 96)
            .mulDiv(1e18, 1 << 96);
        return ethWad.mulDiv(hawkPerEthWad, 1e18);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _requireOwner(uint256 labelhash) internal view returns (bytes32 node) {
        if (nameOwner(labelhash) != msg.sender) revert NotNameOwner();
        node = _node(labelhash);
    }

    function _node(uint256 labelhash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(baseNode, bytes32(labelhash)));
    }

    function _poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}

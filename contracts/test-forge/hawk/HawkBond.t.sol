//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {HawkBond, IRegistrarBond, IWrapperBond, IERC20Bond, IAggregatorBond, IStateViewBond, IUniversalRouterBond} from "../../contracts/hawk/HawkBond.sol";
import {MockHawkToken} from "../../contracts/hawk/mocks/MockHawkToken.sol";
import {MockStateView} from "../../contracts/hawk/mocks/MockStateView.sol";
import {MockUniversalRouter, IERC20BalanceOnly} from "../../contracts/hawk/mocks/MockUniversalRouter.sol";

contract HawkBondTest is HawkFixture {
    // sqrtPriceX96 for HAWK-per-ETH = 1e8 → sqrt(1e8) = 1e4, Q96.
    // With ETH at the fixture's $2,000: HAWK = $0.00002; $100 = 5M HAWK.
    uint160 constant SQRT_PRICE = uint160(10_000 * 2 ** 96);
    uint256 constant HAWK_PER_ETH_WAD = 1e8 * 1e18;
    uint256 constant MIN_HAWK = 5_000_000e18; // $100 at test prices

    address bondTreasury = makeAddr("bondTreasury");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockHawkToken hawkToken;
    MockStateView stateView;
    MockUniversalRouter router;
    HawkBond bond;

    function setUp() public override {
        super.setUp();
        hawkToken = new MockHawkToken();
        stateView = new MockStateView(SQRT_PRICE);
        router = new MockUniversalRouter(
            hawkToken,
            IERC20BalanceOnly(address(usdc)),
            // HAWK per USDC at test prices: $1 / $0.00002 = 50,000 HAWK.
            50_000e18
        );
        bond = new HawkBond(
            HawkBond.Config({
                owner: address(this),
                registrar: IRegistrarBond(address(registrar)),
                wrapper: IWrapperBond(address(wrapper)),
                baseNode: HAWK_NODE,
                usdc: IERC20Bond(address(usdc)),
                hawk: IERC20Bond(address(hawkToken)),
                feed: IAggregatorBond(address(feed)),
                maxFeedAge: MAX_FEED_AGE,
                stateView: IStateViewBond(address(stateView)),
                hawkPoolId: keccak256("hawk-pool"),
                treasury: bondTreasury,
                router: IUniversalRouterBond(address(router))
            })
        );

        hawkToken.mint(alice, 100_000_000e18);
        vm.startPrank(alice);
        usdc.approve(address(bond), type(uint256).max);
        hawkToken.approve(address(bond), type(uint256).max);
        vm.stopPrank();
    }

    function _name(address who, string memory label) internal returns (uint256 id) {
        _registerETH(who, label, 365 days);
        id = uint256(keccak256(bytes(label)));
    }

    function _node(uint256 labelhash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(HAWK_NODE, bytes32(labelhash)));
    }

    // ------------------------------------------------------------------
    // USDC bonds
    // ------------------------------------------------------------------

    function test_bondUSDC_splits_fee_and_records() public {
        uint256 id = _name(alice, "acme");
        vm.prank(alice);
        bond.bondUSDC(id, 200e6); // $200, fee $4

        (address asset, uint256 amount, uint256 usd, uint64 since, , ) = bond.bondOf(_node(id));
        assertEq(asset, address(usdc));
        assertEq(amount, 196e6); // net of 2%
        assertEq(usd, 196e18);
        assertGt(since, 0);
        assertEq(bond.buybackPool(), 2e6); // half the fee
        assertEq(usdc.balanceOf(bondTreasury), 2e6); // other half
    }

    function test_bondUSDC_minimum_is_net() public {
        uint256 id = _name(alice, "acme");
        // $101 gross → $98.98 net < $100 → refused.
        vm.prank(alice);
        vm.expectRevert(HawkBond.BondTooSmall.selector);
        bond.bondUSDC(id, 101e6);

        // $103 gross → $100.94 net ≥ $100 → ok.
        vm.prank(alice);
        bond.bondUSDC(id, 103e6);
    }

    function test_bondUSDC_requires_name_owner() public {
        uint256 id = _name(alice, "acme");
        vm.prank(bob);
        vm.expectRevert(HawkBond.NotNameOwner.selector);
        bond.bondUSDC(id, 200e6);
    }

    function test_topup_accumulates() public {
        uint256 id = _name(alice, "acme");
        vm.startPrank(alice);
        bond.bondUSDC(id, 200e6);
        bond.bondUSDC(id, 100e6); // top-ups have no own minimum
        vm.stopPrank();
        (, uint256 amount, , , , ) = bond.bondOf(_node(id));
        assertEq(amount, 196e6 + 98e6);
    }

    function test_asset_switch_refused() public {
        uint256 id = _name(alice, "acme");
        vm.startPrank(alice);
        bond.bondUSDC(id, 200e6);
        vm.expectRevert(HawkBond.WrongAsset.selector);
        bond.bondHAWK(id, MIN_HAWK * 2);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // HAWK bonds
    // ------------------------------------------------------------------

    function test_bondHAWK_burns_fee_directly() public {
        uint256 id = _name(alice, "acme");
        uint256 amount = 20_000_000e18; // $400 gross at test prices
        vm.prank(alice);
        bond.bondHAWK(id, amount);

        uint256 fee = amount / 100; // 1%
        assertEq(hawkToken.balanceOf(DEAD), fee);
        assertEq(bond.totalHawkBurned(), fee);
        (address asset, uint256 net, uint256 usd, , , ) = bond.bondOf(_node(id));
        assertEq(asset, address(hawkToken));
        assertEq(net, amount - fee);
        // $400 × 0.99 = $396
        assertEq(usd, 396e18);
    }

    function test_bondHAWK_minimum_in_usd() public {
        uint256 id = _name(alice, "acme");
        // $99 worth net → refused.
        vm.prank(alice);
        vm.expectRevert(HawkBond.BondTooSmall.selector);
        bond.bondHAWK(id, 5_000_000e18); // $100 gross → $99 net

        vm.prank(alice);
        bond.bondHAWK(id, 5_100_000e18); // $102 gross → $100.98 net
    }

    // ------------------------------------------------------------------
    // Withdrawals
    // ------------------------------------------------------------------

    function test_withdraw_flow_seven_days() public {
        uint256 id = _name(alice, "acme");
        vm.startPrank(alice);
        bond.bondUSDC(id, 200e6);
        bond.requestWithdraw(id, 100e6);
        vm.stopPrank();

        (, uint256 active, , , uint256 pending, uint64 unlockAt) = bond.bondOf(_node(id));
        assertEq(active, 96e6);
        assertEq(pending, 100e6);
        assertEq(unlockAt, block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(HawkBond.StillLocked.selector);
        bond.claimWithdraw(id);

        vm.warp(block.timestamp + 7 days);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        bond.claimWithdraw(id);
        assertEq(usdc.balanceOf(alice) - before, 100e6);
    }

    function test_bond_rides_with_the_name() public {
        uint256 id = _name(alice, "acme");
        vm.startPrank(alice);
        bond.bondUSDC(id, 200e6);
        bond.requestWithdraw(id, 196e6);
        vm.stopPrank();

        vm.prank(alice);
        registrar.transferFrom(alice, bob, id);

        vm.warp(block.timestamp + 7 days);
        // Old owner can no longer claim; the buyer of the name can.
        vm.prank(alice);
        vm.expectRevert(HawkBond.NotNameOwner.selector);
        bond.claimWithdraw(id);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        bond.claimWithdraw(id);
        assertEq(usdc.balanceOf(bob) - before, 196e6);
    }

    function test_claim_nothing_pending_reverts() public {
        uint256 id = _name(alice, "acme");
        vm.prank(alice);
        bond.bondUSDC(id, 200e6);
        vm.prank(alice);
        vm.expectRevert(HawkBond.NothingPending.selector);
        bond.claimWithdraw(id);
    }

    // ------------------------------------------------------------------
    // Buyback
    // ------------------------------------------------------------------

    function _route() internal view returns (HawkBond.PoolKey memory a, HawkBond.PoolKey memory b) {
        a = HawkBond.PoolKey(address(0), address(usdc), 500, 10, address(0));
        b = HawkBond.PoolKey(address(0), address(hawkToken), 0, 200, address(0));
    }

    function test_buyback_requires_route() public {
        vm.expectRevert(HawkBond.RouteNotSet.selector);
        bond.buyback();
    }

    function test_buyback_requires_threshold() public {
        (HawkBond.PoolKey memory a, HawkBond.PoolKey memory b) = _route();
        bond.setRoute(a, b);
        uint256 id = _name(alice, "acme");
        vm.prank(alice);
        bond.bondUSDC(id, 200e6); // buybackPool = $2 < $25
        vm.expectRevert(HawkBond.PotTooSmall.selector);
        bond.buyback();
    }

    function test_buyback_swaps_and_burns() public {
        (HawkBond.PoolKey memory a, HawkBond.PoolKey memory b) = _route();
        bond.setRoute(a, b);
        uint256 id = _name(alice, "acme");
        vm.prank(alice);
        bond.bondUSDC(id, 3000e6); // fee $60 → pool $30

        uint256 pool = bond.buybackPool();
        assertEq(pool, 30e6);
        uint256 burned = bond.buyback();

        // $30 at 50,000 HAWK per USDC.
        assertEq(burned, 1_500_000e18);
        assertEq(hawkToken.balanceOf(DEAD), burned);
        assertEq(bond.buybackPool(), 0);
        assertEq(bond.totalHawkBurned(), burned);
    }

    function test_buyback_reverts_under_slippage_floor() public {
        (HawkBond.PoolKey memory a, HawkBond.PoolKey memory b) = _route();
        bond.setRoute(a, b);
        uint256 id = _name(alice, "acme");
        vm.prank(alice);
        bond.bondUSDC(id, 3000e6);
        router.setRate(40_000e18); // 20% under spot; floor is 5%
        vm.expectRevert(HawkBond.PotTooSmall.selector);
        bond.buyback();
    }

    function test_setRoute_onlyOwner() public {
        (HawkBond.PoolKey memory a, HawkBond.PoolKey memory b) = _route();
        vm.prank(alice);
        vm.expectRevert(HawkBond.NotOwner.selector);
        bond.setRoute(a, b);
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    function test_quote_and_stale_feed() public {
        assertEq(bond.quoteHawkForUsdc(1e6), 50_000e18);
        feed.setUpdatedAt(block.timestamp - MAX_FEED_AGE - 1);
        vm.expectRevert(HawkBond.StaleFeed.selector);
        bond.quoteHawkForUsdc(1e6);
    }
}

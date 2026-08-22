// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {HawkPremiumSale, IERC721Minimal, IERC20Minimal, IAggregatorMinimal} from "../../contracts/hawk/HawkPremiumSale.sol";
import {IETHRegistrarController} from "../../contracts/ethregistrar/IETHRegistrarController.sol";

contract HawkPremiumSaleTest is HawkFixture {
    HawkPremiumSale sale;
    address treasury = makeAddr("treasury");
    uint256 constant YEAR = 365 days;
    uint256 constant PRICE = 1500e18; // $1,500 in attoUSD

    function setUp() public override {
        super.setUp();
        string[] memory labels = new string[](2);
        labels[0] = "vitalik";
        labels[1] = "saylor";
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE;
        prices[1] = PRICE;
        sale = new HawkPremiumSale(
            HawkPremiumSale.Config({
                safe: treasury,
                registrar: IERC721Minimal(address(registrar)),
                usdc: IERC20Minimal(address(usdc)),
                feed: IAggregatorMinimal(address(feed)),
                maxFeedAge: MAX_FEED_AGE,
                labels: labels,
                pricesAttoUSD: prices
            })
        );
        // Register both names with the SALE CONTRACT as owner (payer: alice),
        // mirroring the mainnet batch.
        _registerTo(address(sale), "vitalik");
        _registerTo(address(sale), "saylor");
    }

    function _registerTo(address owner, string memory label) internal {
        IETHRegistrarController.Registration memory r = _makeRegistration(
            label,
            owner,
            YEAR,
            keccak256(bytes(label)),
            address(0),
            0
        );
        vm.prank(alice);
        controller.commit(controller.makeCommitment(r));
        vm.warp(block.timestamp + MIN_COMMIT_AGE);
        uint256 paid = controller.rentPrice(label, YEAR).base;
        hoax(alice, paid + 1 ether);
        controller.register{value: paid}(r);
    }

    function test_setup_namesHeldAndListed() public view {
        assertEq(registrar.ownerOf(sale.tokenId("vitalik")), address(sale));
        assertEq(sale.priceOf(sale.tokenId("vitalik")), PRICE);
        assertEq(sale.priceInUSDC("vitalik"), 1500e6);
        // $1,500 at $2,000/ETH = 0.75 ETH
        assertEq(sale.priceInWei("vitalik"), 0.75 ether);
    }

    function test_buyWithUSDC() public {
        usdc.mint(bob, 1500e6);
        vm.startPrank(bob);
        usdc.approve(address(sale), 1500e6);
        sale.buyWithUSDC("vitalik");
        vm.stopPrank();
        assertEq(registrar.ownerOf(sale.tokenId("vitalik")), bob);
        assertEq(usdc.balanceOf(treasury), 1500e6);
        assertEq(sale.priceOf(sale.tokenId("vitalik")), 0);
    }

    function test_buyWithETH_forwardsAndRefunds() public {
        hoax(bob, 1 ether);
        sale.buyWithETH{value: 1 ether}("saylor");
        assertEq(registrar.ownerOf(sale.tokenId("saylor")), bob);
        assertEq(treasury.balance, 0.75 ether);
        assertEq(bob.balance, 0.25 ether); // refunded excess
        assertEq(address(sale).balance, 0);
    }

    function test_buy_revertsWhenNotForSale() public {
        usdc.mint(bob, 3000e6);
        vm.startPrank(bob);
        usdc.approve(address(sale), 3000e6);
        sale.buyWithUSDC("vitalik");
        vm.expectRevert(HawkPremiumSale.NotForSale.selector);
        sale.buyWithUSDC("vitalik");
        vm.stopPrank();
    }

    function test_buyWithETH_revertsUnderpaid() public {
        hoax(bob, 1 ether);
        vm.expectRevert(HawkPremiumSale.InsufficientPayment.selector);
        sale.buyWithETH{value: 0.74 ether}("vitalik");
    }

    function test_buyWithETH_revertsOnStaleFeed() public {
        feed.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + MAX_FEED_AGE + 2 days);
        hoax(bob, 1 ether);
        vm.expectRevert(HawkPremiumSale.StaleFeed.selector);
        sale.buyWithETH{value: 1 ether}("vitalik");
    }

    function test_safeCanRepriceAndWithdraw() public {
        vm.prank(treasury);
        sale.setPrice("vitalik", 2000e18);
        assertEq(sale.priceInUSDC("vitalik"), 2000e6);

        vm.prank(treasury);
        sale.withdrawName("vitalik", treasury);
        assertEq(registrar.ownerOf(sale.tokenId("vitalik")), treasury);
        assertEq(sale.priceOf(sale.tokenId("vitalik")), 0);
    }

    function test_nonSafeCannotAdminister() public {
        vm.startPrank(bob);
        vm.expectRevert(HawkPremiumSale.NotSafe.selector);
        sale.setPrice("vitalik", 1);
        vm.expectRevert(HawkPremiumSale.NotSafe.selector);
        sale.withdrawName("vitalik", bob);
        vm.expectRevert(HawkPremiumSale.NotSafe.selector);
        sale.recoverETH(bob);
        vm.stopPrank();
    }
}

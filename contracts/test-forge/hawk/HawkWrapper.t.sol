//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {INameWrapper, CANNOT_UNWRAP, CANNOT_TRANSFER, PARENT_CANNOT_CONTROL, CAN_DO_EVERYTHING, IS_DOT_ETH} from "../../contracts/wrapper/INameWrapper.sol";

contract HawkWrapperTest is HawkFixture {
    uint256 constant YEAR = 365 days;
    string constant LABEL = "goldfinch";

    function _wrap(address who, string memory label) internal returns (bytes32 node) {
        uint256 id = uint256(keccak256(bytes(label)));
        node = _hawkNode(label);
        vm.startPrank(who);
        registrar.setApprovalForAll(address(wrapper), true);
        wrapper.wrapETH2LD(label, who, uint16(CAN_DO_EVERYTHING), address(0));
        vm.stopPrank();
        assertEq(wrapper.ownerOf(uint256(node)), who);
        assertEq(registrar.ownerOf(id), address(wrapper));
    }

    function test_identity() public view {
        assertEq(wrapper.name(), "Hawk Wrapped Names");
    }

    function test_wrapUnwrapRoundtrip() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 node = _wrap(alice, LABEL);
        uint256 id = uint256(keccak256(bytes(LABEL)));

        // wrapper stores the DNS-encoded name under .hawk
        bytes memory stored = wrapper.names(node);
        assertEq(stored, abi.encodePacked(uint8(9), "goldfinch", uint8(4), "hawk", uint8(0)));

        // 2LD carries IS_DOT_ETH and expiry = registrar expiry + grace
        (, uint32 fuses, uint64 expiry) = wrapper.getData(uint256(node));
        assertTrue(fuses & IS_DOT_ETH != 0);
        assertEq(expiry, uint64(registrar.nameExpires(id) + GRACE));

        vm.prank(alice);
        wrapper.unwrapETH2LD(bytes32(id), alice, alice);
        assertEq(registrar.ownerOf(id), alice);
        assertEq(wrapper.ownerOf(uint256(node)), address(0));
    }

    function test_wrapViaSafeTransfer() public {
        _registerETH(alice, LABEL, YEAR);
        uint256 id = uint256(keccak256(bytes(LABEL)));
        vm.prank(alice);
        registrar.safeTransferFrom(
            alice,
            address(wrapper),
            id,
            abi.encode(LABEL, alice, uint16(0), address(0))
        );
        assertEq(wrapper.ownerOf(uint256(_hawkNode(LABEL))), alice);
    }

    function test_subdomainsAreTradeableERC1155() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 parentNode = _wrap(alice, LABEL);

        // issue holder.goldfinch.hawk to bob
        vm.prank(alice);
        bytes32 subNode = wrapper.setSubnodeOwner(
            parentNode,
            "holder",
            bob,
            0,
            0
        );
        assertEq(wrapper.ownerOf(uint256(subNode)), bob);

        // bob trades it to alice — a real ERC-1155 transfer
        vm.prank(bob);
        wrapper.safeTransferFrom(bob, alice, uint256(subNode), 1, "");
        assertEq(wrapper.ownerOf(uint256(subNode)), alice);
    }

    function test_emancipatedSubdomainCannotBeRetaken() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 parentNode = _wrap(alice, LABEL);

        // parent must burn CANNOT_UNWRAP before it can emancipate children
        vm.startPrank(alice);
        wrapper.setFuses(parentNode, uint16(CANNOT_UNWRAP));
        (, , uint64 parentExpiry) = wrapper.getData(uint256(parentNode));
        bytes32 subNode = wrapper.setSubnodeOwner(
            parentNode,
            "agent",
            bob,
            uint32(PARENT_CANNOT_CONTROL),
            parentExpiry
        );
        // parent can no longer replace the child's owner
        vm.expectRevert();
        wrapper.setSubnodeOwner(parentNode, "agent", alice, 0, parentExpiry);
        vm.stopPrank();

        assertEq(wrapper.ownerOf(uint256(subNode)), bob);
    }

    function test_renewViaControllerSyncsWrappedExpiry() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 node = _wrap(alice, LABEL);
        uint256 id = uint256(keccak256(bytes(LABEL)));

        (, , uint64 expiryBefore) = wrapper.getData(uint256(node));

        uint256 price = controller.rentPrice(LABEL, YEAR).base;
        vm.prank(alice);
        controller.renew{value: price}(LABEL, YEAR, bytes32(0));

        (, , uint64 expiryAfter) = wrapper.getData(uint256(node));
        assertEq(expiryAfter, expiryBefore + YEAR);
        assertEq(expiryAfter, uint64(registrar.nameExpires(id) + GRACE));

        // ownership intact well past the original expiry
        vm.warp(uint256(expiryBefore) - 1 days);
        assertEq(wrapper.ownerOf(uint256(node)), alice);
    }

    function test_expiredWrappedNameClearsOwner() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 node = _wrap(alice, LABEL);
        (, , uint64 expiry) = wrapper.getData(uint256(node));

        vm.warp(uint256(expiry) + 1);
        assertEq(wrapper.ownerOf(uint256(node)), address(0));
    }

    function test_transferLockedByFuse() public {
        _registerETH(alice, LABEL, YEAR);
        bytes32 node = _wrap(alice, LABEL);
        vm.startPrank(alice);
        wrapper.setFuses(node, uint16(CANNOT_UNWRAP | CANNOT_TRANSFER));
        vm.expectRevert();
        wrapper.safeTransferFrom(alice, bob, uint256(node), 1, "");
        vm.stopPrank();
    }
}
